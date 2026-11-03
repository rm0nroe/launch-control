#!/usr/bin/env python3
"""Owned worker process: one child in its own process group, reaped with proof."""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time


class OwnedProcess:
    """Shared ownership of a worker process, its output reader and its descendants.

    Subclasses set Error, Quiescence and WORKER, call _own() from __init__, call _adopt() right
    after Popen, and provide _check(), the controller's binding check run from _tick().
    """
    Error = RuntimeError
    Quiescence = RuntimeError
    WORKER = 'worker'
    MAX_LINE = 1024 * 1024
    MAX_LOG = 1024 * 1024
    POLL = 1.0
    READER_EOF_EVENT = False

    def _own(self, log_path):
        self.log_path = Path(log_path)
        self.proc = None
        self.pgid = None
        self._process_start = None
        self._termination_requested = False
        self.closure = None
        self.messages = queue.Queue(maxsize=256)
        self._last_tick = float('-inf')
        self.reader_error = None
        self._reader_thread = None
        self.known_pids = set()
        self.known_descendants = {}
        self.unresolved = set()
        self._log = None
        self._log_bytes = 0

    def _adopt(self, proc):
        self.proc = proc
        self.pgid = proc.pid
        self._scan_descendants()
        self._reader_thread = threading.Thread(target=self._reader, daemon=True)
        self._reader_thread.start()

    def _before_reap(self):
        """Hook run by close() around termination, even when termination raises."""

    @property
    def pid(self):
        return None if self.proc is None else self.proc.pid

    def _record(self, event, **data):
        if self._log is None:
            return
        safe = {'event': event, **data}
        line = json.dumps(safe, sort_keys=True) + '\n'
        if self._log_bytes + len(line.encode()) > self.MAX_LOG:
            raise self.Error('native protocol metadata limit exceeded')
        self._log.write(line)
        self._log.flush()
        self._log_bytes += len(line.encode())

    @classmethod
    def _safe_log(cls, path):
        path = Path(path).absolute()
        current = Path(path.anchor)
        for part in path.parts[1:-1]:
            current /= part
            # macOS exposes its system temporary directory through /var (and some
            # hosts expose /tmp similarly); reject every caller-controlled link.
            if current.is_symlink() and str(current) not in ('/var', '/tmp'):
                raise cls.Error('unsafe native protocol log ancestor')
        if path.is_symlink() or path.exists():
            raise cls.Error('native protocol log already exists or is unsafe')
        return path

    def _reader(self):
        try:
            while True:
                raw = self.proc.stdout.readline(self.MAX_LINE + 1)
                if not raw:
                    if self.READER_EOF_EVENT:
                        self.messages.put({'_reader_closed': True})
                    return
                if len(raw) > self.MAX_LINE:
                    raise self.Error(self.WORKER + ' message exceeds limit')
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError as exc:
                    raise self.Error('invalid ' + self.WORKER + ' JSON') from exc
                if not isinstance(msg, dict):  # Every consumer reads messages as objects.
                    raise self.Error('invalid ' + self.WORKER + ' JSON')
                # Backpressure: a slow controller blocks the app-server's writes; nothing is dropped
                # and the reader never exits silently (LC-030 live run, 2026-10-16).
                self.messages.put(msg)
        except Exception as exc:  # wake a waiter; do not strand controller on stdout failure
            self.reader_error = exc
            self.messages.put({'_reader_error': True})

    def _scan_descendants(self):
        """Record owned OS descendants, including helpers in separate process groups."""
        if not isinstance(self.pid, int) or self.pid <= 0:
            return
        if self.proc.poll() is not None:
            if not self._termination_requested:
                self.unresolved.add('unobserved-process-exit')
            return
        try:
            start = subprocess.check_output(['ps', '-p', str(self.pid), '-o', 'lstart='], text=True, timeout=1).strip()
            rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,lstart='], text=True, timeout=1)
        except (OSError, subprocess.SubprocessError):
            self.unresolved.add('unknown-descendants')
            return
        if self._process_start is None:
            self._process_start = start
        elif not start or start != self._process_start:
            self.unresolved.add('process-identity-changed')
            return
        table = {}
        for row in rows.splitlines():
            fields = row.split(maxsplit=3)
            if len(fields) != 4 or not all(field.isdigit() for field in fields[:3]) or not fields[3]:
                continue
            pid, parent, group = map(int, fields[:3])
            table[pid] = (parent, group, fields[3].strip())
            if group == self.pgid and pid != self.pid:
                self.known_pids.add(pid)
        descendants, pending = set(), [self.pid]
        while pending:
            ancestor = pending.pop()
            for pid, (parent, group, identity) in table.items():
                if parent == ancestor and pid not in descendants:
                    descendants.add(pid)
                    pending.append(pid)
                    prior = self.known_descendants.get(pid)
                    if prior is not None and prior != identity:
                        self.unresolved.add('descendant-identity-changed:' + str(pid))
                    else:
                        self.known_descendants[pid] = identity

    def _tick(self):
        """Binding check and descendant scan, at most once per POLL rather than once per message."""
        now = time.monotonic()
        if now - self._last_tick >= self.POLL:
            self._check()
            self._scan_descendants()
            self._last_tick = now  # Only after both pass, so a caught failure is checked again.

    @staticmethod
    def _alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @staticmethod
    def _identity_alive(pid, identity):
        try:
            current = subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='], text=True,
                                              stderr=subprocess.PIPE, timeout=1).strip()
        except subprocess.CalledProcessError as exc:
            if exc.returncode == 1 and not exc.output and not exc.stderr:
                return False
            return None
        except (OSError, subprocess.SubprocessError):
            return None
        return current == identity if current else None

    def _group_alive(self):
        if not isinstance(self.pgid, int) or self.pgid <= 0:
            return False
        try:
            os.killpg(self.pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def close(self):
        if self.proc is None:
            return {'process': 'not-started', 'group': 'not-started', 'known_descendants': []}
        self._scan_descendants()
        try:
            try:
                self._terminate()
                # A same-group descendant can still be exiting after the leader is reaped (Codex 0.162
                # starts a plugin marketplace git refresh). Drain briefly, then kill the owned group.
                for sig, seconds in ((None, 5), (signal.SIGKILL, 2)):
                    if sig is not None and self._group_alive():
                        try:
                            os.killpg(self.pgid, sig)
                        except ProcessLookupError:
                            pass
                    end = time.monotonic() + seconds
                    while self._group_alive() and time.monotonic() < end:
                        time.sleep(.05)
            finally:
                self._before_reap()
            if self._group_alive():
                raise self.Quiescence('owned process group remains after reap')
            alive = sorted(pid for pid in self.known_pids if self._alive(pid))
            if alive:
                raise self.Quiescence('known native descendants remain: ' + ', '.join(map(str, alive)))
            end = time.monotonic() + 5
            while True:
                observed = {pid: self._identity_alive(pid, identity) for pid, identity in self.known_descendants.items()}
                if any(value is None for value in observed.values()):
                    raise self.Quiescence('unable to inspect known native descendants')
                alive = sorted(pid for pid, value in observed.items() if value)
                if not alive:
                    break
                if time.monotonic() >= end:
                    raise self.Quiescence('known native descendants remain: ' + ', '.join(map(str, alive)))
                time.sleep(.05)
            self.closure = {'process': 'exited', 'group': 'gone', 'known_descendants': []}
            if self.unresolved:
                raise self.Quiescence('unresolved native operations: ' + ', '.join(sorted(self.unresolved)))
            self._end_log()  # Recorded only once quiescence is proven, so a full log never hides why it failed.
            return self.closure
        finally:
            self._end_log(record=False)  # Every other outcome still closes the log.

    def _terminate(self):
        self._termination_requested = True
        if self.proc.poll() is None:
            try:
                os.killpg(self.pgid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            end = time.monotonic() + 5
            while self.proc.poll() is None and time.monotonic() < end:
                time.sleep(.05)
            if self.proc.poll() is None:
                os.killpg(self.pgid, signal.SIGKILL)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired as exc:
            raise self.Quiescence('owned ' + self.WORKER + ' would not reap') from exc

    def _end_log(self, record=True):
        if self._log is None:
            return
        try:
            if record:
                self._record('closed', returncode=self.proc.returncode)
        finally:
            self._log.close()
            self._log = None
