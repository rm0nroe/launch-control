#!/usr/bin/env python3
"""No-network checks for the shared owned-process base class."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-process.py'
assert SCRIPT.exists(), 'launch-process.py not found'
spec = importlib.util.spec_from_file_location('launch_process', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProbeError(RuntimeError):
    pass


class ProbeQuiescence(ProbeError):
    pass


class Probe(module.OwnedProcess):
    Error = ProbeError
    Quiescence = ProbeQuiescence
    WORKER = 'probe'
    READER_EOF_EVENT = True

    def __init__(self, log_path):
        self._own(log_path)

    def _check(self):
        pass


CLEAN = {'process': 'exited', 'group': 'gone', 'known_descendants': []}
live = []


def start(code, *args):
    proc = subprocess.Popen([sys.executable, '-c', code, *args], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            start_new_session=True)
    live.append(proc)
    return proc


def wait_for(path):
    for _ in range(500):
        if path.exists() and path.read_text():
            return int(path.read_text())
        time.sleep(.01)
    raise AssertionError('fixture did not report a pid')


def kill_pid(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def worker_for(directory, code, *args, adopt=True):
    probe = Probe(Path(directory) / 'probe.log')
    proc = start(code, *args)
    if adopt:
        probe._adopt(proc)
    else:
        probe.proc, probe.pgid = proc, proc.pid
    return probe


# Emit output, close stdout so the reader sees EOF, and keep the leader alive.
EOF_AFTER = 'import os,time\n%s\nos.close(1)\ntime.sleep(60)'
SPAWN = ('import pathlib,subprocess,sys,time; '
         'p=subprocess.Popen([sys.executable,"-c",sys.argv[2]],start_new_session=%s); '
         'pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)')
IDLE = 'import time; time.sleep(%s)'

try:
    # A clean exit reports the exact closure dict that three callers compare by equality.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, IDLE % 60)
        assert probe.close() == CLEAN
        assert probe.closure == CLEAN
        assert probe.proc.poll() is not None

    # The eof event is only emitted when the subclass asks for it, and the hook runs on close.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, EOF_AFTER % 'print("{}", flush=True)')
        assert probe.messages.get(timeout=5) == {}
        assert probe.messages.get(timeout=5) == {'_reader_closed': True}
        calls = []
        probe._before_reap = lambda: calls.append('reap')
        assert probe.close() == CLEAN and calls == ['reap']
    with tempfile.TemporaryDirectory() as tmp:
        class Quiet(Probe):
            READER_EOF_EVENT = False
        probe = Quiet(Path(tmp) / 'q.log')
        probe._adopt(start(EOF_AFTER % 'print("{}", flush=True)'))
        assert probe.messages.get(timeout=5) == {}
        probe._reader_thread.join(5)
        assert probe.messages.empty(), 'no eof event unless READER_EOF_EVENT'
        probe.close()

    # The before-reap hook runs even when termination raises, and a full log never replaces that error.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, IDLE % 60)
        probe._log, probe._log_bytes = (Path(tmp) / 'full.log').open('x', encoding='utf-8'), probe.MAX_LOG
        calls = []
        probe._before_reap = lambda: calls.append('reap')
        def boom():
            raise ProbeQuiescence('stuck')
        probe._terminate = boom
        try:
            probe.close()
            raise AssertionError('close swallowed a termination failure')
        except ProbeQuiescence as exc:
            assert str(exc) == 'stuck', exc
        assert calls == ['reap'] and probe._log is None
        os.killpg(probe.pgid, signal.SIGKILL)
        probe.proc.wait(timeout=5)

    # A same-group child still exiting when the leader stops is drained and accepted.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        child = ('import signal,sys,time; signal.signal(signal.SIGTERM, lambda *a: (time.sleep(1), sys.exit(0))); '
                 'time.sleep(60)')
        probe = worker_for(tmp, SPAWN % 'False', str(pidfile), child)
        pid = wait_for(pidfile)
        try:
            assert probe.close() == CLEAN
            assert not probe._alive(pid)
        finally:
            kill_pid(pid)

    # A same-group child that ignores SIGTERM is killed and accepted.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        child = 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
        probe = worker_for(tmp, SPAWN % 'False', str(pidfile), child)
        pid = wait_for(pidfile)
        try:
            started = time.monotonic()
            assert probe.close() == CLEAN
            assert time.monotonic() - started < 15
            assert not probe._alive(pid)
        finally:
            kill_pid(pid)

    # A separately grouped child that exits is accepted.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        probe = worker_for(tmp, SPAWN % 'True', str(pidfile), IDLE % 3)
        pid = wait_for(pidfile)
        try:
            probe._scan_descendants()
            assert pid in probe.known_descendants
            assert probe.close() == CLEAN
        finally:
            kill_pid(pid)

    # A separately grouped child that survives is refused and left alone.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        probe = worker_for(tmp, SPAWN % 'True', str(pidfile), IDLE % 60)
        pid = wait_for(pidfile)
        try:
            probe._scan_descendants()
            try:
                probe.close()
                raise AssertionError('surviving descendant accepted')
            except ProbeQuiescence as exc:
                assert 'known native descendants remain' in str(exc), str(exc)
            assert probe._alive(pid), 'controller must not kill outside its owned group'
        finally:
            kill_pid(pid)

    # A leader that exits before close() without _terminate is an unobserved exit.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, 'pass', adopt=False)
        probe.proc.wait(timeout=5)
        probe._adopt(probe.proc)
        assert 'unobserved-process-exit' in probe.unresolved
        try:
            probe.close()
            raise AssertionError('unobserved exit accepted')
        except ProbeQuiescence as exc:
            assert 'unobserved-process-exit' in str(exc)

    # The closing record is written only once quiescence is proven; a refused close never logs "closed".
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, 'pass', adopt=False)
        probe.proc.wait(timeout=5)
        probe._adopt(probe.proc)
        logfile = Path(tmp) / 'refused.log'
        probe._log, probe._log_bytes = logfile.open('x', encoding='utf-8'), 0
        try:
            probe.close()
            raise AssertionError('unobserved exit accepted')
        except ProbeQuiescence:
            pass
        assert probe._log is None and 'closed' not in logfile.read_text(), logfile.read_text()

    # A same-group process outside the parent tree (reparented orphan) is still recorded as owned.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, IDLE % 60)
        real = subprocess.check_output
        def fake_ps(argv, *a, **kw):
            if '-axo' in argv:
                return '999999 1 %d Mon Jan  1 00:00:00 2024\n' % probe.pgid
            return real(argv, *a, **kw)
        with patch('subprocess.check_output', side_effect=fake_ps):
            probe._scan_descendants()
        assert 999999 in probe.known_pids and 999999 not in probe.known_descendants, probe.known_pids
        probe.known_pids.discard(999999)
        probe.close()

    # An unreadable process table is unknown, not clean.
    with tempfile.TemporaryDirectory() as tmp:
        with patch('subprocess.check_output', side_effect=OSError('ps unavailable')):
            probe = worker_for(tmp, IDLE % 60)
            assert 'unknown-descendants' in probe.unresolved
            try:
                probe.close()
                raise AssertionError('unknown descendants accepted')
            except ProbeQuiescence as exc:
                assert 'unknown-descendants' in str(exc)

    # Backpressure: nothing is dropped while the consumer sleeps, and the reader does not fail.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, EOF_AFTER % 'import json\nfor i in range(600): print(json.dumps({"n": i}), flush=True)')
        time.sleep(2)
        seen = [probe.messages.get(timeout=5)['n'] for _ in range(600)]
        assert seen == list(range(600))
        assert probe.reader_error is None
        assert probe.messages.get(timeout=5) == {'_reader_closed': True}
        probe.close()

    # A full queue with no consumer must not stall close().
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, 'import json,time\nfor i in range(300): print(json.dumps({"n": i}), flush=True)\ntime.sleep(60)')
        for _ in range(500):
            if probe.messages.full():
                break
            time.sleep(.01)
        assert probe.messages.full()
        started = time.monotonic()
        assert probe.close() == CLEAN
        assert time.monotonic() - started < 10

    # Reader failures are reported, with the subclass worker name.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, EOF_AFTER % 'print("not json", flush=True)')
        assert probe.messages.get(timeout=5) == {'_reader_error': True}
        assert isinstance(probe.reader_error, ProbeError) and str(probe.reader_error) == 'invalid probe JSON'
        probe.close()

    # A JSON line that is not an object is invalid too, and fails through the same reader-error path.
    with tempfile.TemporaryDirectory() as tmp:
        probe = worker_for(tmp, EOF_AFTER % 'print("[1]", flush=True)')
        assert probe.messages.get(timeout=5) == {'_reader_error': True}
        assert isinstance(probe.reader_error, ProbeError) and str(probe.reader_error) == 'invalid probe JSON', probe.reader_error
        probe.close()

    # Logging never aborts the kill: a closing record past the metadata limit still drains and SIGKILLs
    # the owned group, and the log is closed whatever close() raises.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        child = 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
        probe = worker_for(tmp, SPAWN % 'False', str(pidfile), child)
        pid = wait_for(pidfile)
        try:
            log = probe._log = (Path(tmp) / 'full.log').open('x', encoding='utf-8')
            probe._log_bytes = probe.MAX_LOG
            try:
                probe.close()
                raise AssertionError('a closing record past the log limit was accepted')
            except ProbeError as exc:  # Quiesced, but the record does not fit: fail closed with the plain error.
                assert type(exc) is ProbeError and str(exc) == 'native protocol metadata limit exceeded', exc
            assert not probe._alive(pid), 'a logging failure stopped the group kill'
            assert probe._log is None and log.closed, 'close() left the protocol log open'
        finally:
            kill_pid(pid)

    # A full log never replaces a quiescence error: a surviving separately grouped child is still named.
    with tempfile.TemporaryDirectory() as tmp:
        pidfile = Path(tmp) / 'child.pid'
        probe = worker_for(tmp, SPAWN % 'True', str(pidfile), IDLE % 60)
        pid = wait_for(pidfile)
        try:
            probe._scan_descendants()
            log = probe._log = (Path(tmp) / 'full.log').open('x', encoding='utf-8')
            probe._log_bytes = probe.MAX_LOG
            try:
                probe.close()
                raise AssertionError('surviving descendant accepted')
            except ProbeQuiescence as exc:
                assert 'known native descendants remain' in str(exc), str(exc)
            assert probe._log is None and log.closed, 'close() left the protocol log open'
        finally:
            kill_pid(pid)

    # The protocol log path must be new and free of caller-controlled links.
    with tempfile.TemporaryDirectory() as tmp:
        real = Path(tmp).resolve()
        existing = real / 'exists.log'
        existing.write_text('x')
        try:
            Probe._safe_log(existing)
            raise AssertionError('existing log accepted')
        except ProbeError:
            pass
        (real / 'target').mkdir()
        (real / 'link').symlink_to(real / 'target')
        try:
            Probe._safe_log(real / 'link' / 'new.log')
            raise AssertionError('symlinked ancestor accepted')
        except ProbeError:
            pass
        (real / 'dangling.log').symlink_to(real / 'nowhere')
        try:
            Probe._safe_log(real / 'dangling.log')
            raise AssertionError('dangling symlink accepted')
        except ProbeError:
            pass
        assert Probe._safe_log(real / 'target' / 'new.log') == real / 'target' / 'new.log'

    # Zombie window: an exited, unreaped leader still owns its process group. macOS answers EPERM
    # to killpg there (the group is alive); Linux answers success until reaping. Assert on
    # _group_alive() directly, since close() reaps the leader before it ever probes the group.
    with tempfile.TemporaryDirectory() as tmp:
        probe = Probe(Path(tmp) / 'z.log')
        zombie = subprocess.Popen(['/usr/bin/true'], start_new_session=True)
        live.append(zombie)
        probe.proc, probe.pgid = zombie, zombie.pid
        if sys.platform == 'linux':
            os.waitid(os.P_PID, zombie.pid, os.WEXITED | os.WNOWAIT)  # Observe exit without reaping.
        else:
            time.sleep(.2)
        assert probe._group_alive(), 'an unreaped exited leader still owns its group'
        zombie.wait()
        assert not probe._group_alive(), 'group must read gone once the leader is reaped'
        probe._termination_requested = True
        assert probe.close() == CLEAN
finally:
    for proc in live:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

print('launch process ownership checks passed')
