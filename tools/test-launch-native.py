#!/usr/bin/env python3
"""No-network checks for the bounded Codex app-server transport."""
import importlib.util
import json
from pathlib import Path
import queue
import runpy
import shlex
import sys
import tempfile
import time
from unittest.mock import patch

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-native.py'
spec = importlib.util.spec_from_file_location('launch_native', SCRIPT)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
runtime = runpy.run_path(str(SCRIPT.with_name('launch-runtime.py')))

# Real native envelopes preserve the exact lifecycle contract and raw event correlation.
for shell in ('/bin/zsh', '/bin/bash', '/bin/sh'):
    for flag in ('-lc', '-c'):
        for script in ('printf ok', 'git diff --stat -- .'):
            command = f'{shell} {flag} {shlex.quote(script)}'
            worker = native.Codex('.', {}, None, None, 'unused',
                synchronous=lambda value: runtime['synchronous_shell'](value, [script]))
            worker._observe_item({'id': 'cmd', 'type': 'commandExecution', 'command': command, 'status': 'inProgress'})
            worker._observe_item({'id': 'cmd', 'type': 'commandExecution', 'status': 'completed', 'exitCode': 0})
            assert not worker.unresolved, command
            assert worker.items['cmd']['command'] == command

for script in ('printf ok', "bash -c 'printf ok'", 'eval printf ok', 'source task.sh',
               'printf ok &', 'docker compose up -d'):
    commands = [f'/bin/zsh -lc {shlex.quote(script)}'] if script != 'printf ok' else [
        "/other/zsh -lc 'printf ok'", "/bin/zsh -x 'printf ok'",
        "/bin/zsh -lc 'printf ok' extra", "/bin/zsh -lc 'printf ok';evil",
        "/bin/zsh -lc 'printf ok'&", "/bin/zsh -lc 'printf ok'>out",
        "/bin/zsh -lc 'printf ok' # comment", "/bin/zsh -lc 'printf ok"]
    for command in commands:
        worker = native.Codex('.', {}, None, None, 'unused',
            synchronous=lambda value: runtime['synchronous_shell'](value, [script]))
        worker._observe_item({'id': 'cmd', 'type': 'commandExecution', 'command': command, 'status': 'completed', 'exitCode': 0})
        assert 'unclassified-shell:cmd' in worker.unresolved, command


class Stream:
    def __init__(self): self.q = queue.Queue()
    def readline(self, size=-1):
        line = self.q.get()
        if line is None: return ''
        return line


class In:
    def __init__(self, owner): self.owner = owner
    def write(self, text):
        data = json.loads(text)
        if 'error' in data: return len(text)
        if 'id' not in data: return len(text)
        ident, method = data['id'], data['method']
        self.owner.requests.append(data)
        if method == 'initialize': self.owner.emit({'id': ident, 'result': {}})
        elif method == 'turn/steer':
            case = self.owner.checkpoint_case
            if case == 'timeout': return len(text)
            if case in ('rejected', 'finished_rejected'):
                self.owner.emit({'id': ident, 'error': {'code': -32600, 'message': 'no active turn'}})
            else:
                self.owner.emit({'id': ident, 'result': {'turnId': 'wrong' if case == 'wrong' else 'turn-1'}})
            if case == 'inflight':
                self.owner.emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1',
                    'item': {'id': 'cmd', 'type': 'commandExecution', 'status': 'completed', 'exitCode': 0}}})
            if case in ('before', 'inflight'): self.owner.emit(self.owner.pending)
        elif method == 'thread/start': self.owner.emit({'id': ident, 'result': {'thread': {'id': 'thread-1'}, 'model': 'fake', 'modelProvider': 'test',
            'activePermissionProfile': {'id': self.owner.profile or data['params'].get('permissions')}}})
        elif method == 'mcpServerStatus/list':
            self.owner.emit({'id': ident, 'result': {'data': [{'name': 'disabled', 'tools': self.owner.tools}],
                'nextCursor': 'next' if self.owner.unfinished or not data['params'].get('cursor') else None}})
        elif method == 'thread/read':
            self.owner.emit({'id': ident, 'result': {'thread': readback()[data['params']['threadId']]}})
        elif method == 'turn/start':
            self.owner.emit({'id': ident, 'result': {'turn': {'id': 'turn-1'}}})
            if self.owner.checkpoint_case == 'inflight':
                self.owner.emit({'method': 'item/started', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1',
                    'item': {'id': 'cmd', 'type': 'commandExecution', 'status': 'inProgress',
                             'command': "/bin/zsh -lc 'printf ok'"}}})
            if self.owner.foreign:
                self.owner.emit({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'foreign', 'turnId': 'turn-1', 'tokenUsage': {'last': {'totalTokens': 1}, 'modelContextWindow': 100}}})
            self.owner.emit({'method': 'thread/tokenUsage/updated', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1', 'tokenUsage': {'last': {'totalTokens': 65 if self.owner.checkpoint_case else 42}, 'total': {'totalTokens': 99}, 'modelContextWindow': 100}}})
            self.owner.pending = {'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed', 'items': [{'id': 'msg', 'type': 'agentMessage', 'text': '{"goal":"ok"}'}, {'id': 'cmd', 'type': 'commandExecution', 'command': "/bin/zsh -lc 'printf ok'", 'status': 'completed', 'processId': None, 'exitCode': 0}]}}}
            if self.owner.checkpoint_case not in ('before', 'inflight', 'rejected', 'timeout'):
                self.owner.emit(self.owner.pending)
        return len(text)
    def flush(self): pass


class Fake:
    pid = None
    profile, tools, unfinished = None, {}, False
    def __init__(self, *args, **kwargs):
        self.stdout, self.stdin, self.returncode, self.foreign = Stream(), In(self), None, False
        self.requests, self.command = [], args[0] if args else None
        self.checkpoint_case = None
    def emit(self, message): self.stdout.q.put(json.dumps(message) + '\n')
    def poll(self): return self.returncode
    def terminate(self): self.returncode = 0; self.stdout.q.put(None)
    def wait(self, timeout=None): self.returncode = 0; return 0


with tempfile.TemporaryDirectory(prefix='native-threshold-bounds-') as temporary:
    for index, threshold in enumerate((60, 65, 70, 59, 71, True, 65.0, '65')):
        adapter = native.Codex(temporary, {}, None, None, Path(temporary) / f'{index}.log',
                               synchronous=lambda command: runtime['synchronous_shell'](command, ['printf ok']))
        with patch.object(native.subprocess, 'Popen', Fake):
            adapter.start()
            adapter.checkpoint_threshold = threshold
            try:
                if type(threshold) is int and 60 <= threshold <= 70:
                    adapter.turn('work', {})
                    assert any(r['method'] == 'turn/start' for r in adapter.proc.requests)
                else:
                    try:
                        adapter.turn('work', {})
                        raise AssertionError('invalid threshold accepted: ' + repr(threshold))
                    except native.NativeError as error:
                        assert str(error) == 'checkpoint threshold must be 60..70 percent'
                    assert not any(r['method'] == 'turn/start' for r in adapter.proc.requests)
            finally:
                adapter.proc.terminate()
                adapter.close()

# A matching mid-turn usage update must request checkpointing before turn/completed.
# Removing the active observer trigger leaves this test with no steer request.
with tempfile.TemporaryDirectory(prefix='native-threshold-') as temporary:
    adapter = native.Codex(temporary, {}, None, None, Path(temporary) / 'native.log')
    with patch.object(native.subprocess, 'Popen', Fake):
        adapter.start()
        adapter.turn_id = 'active-turn'
        adapter.checkpoint_threshold = 65
        def usage(current, thread='thread-1', turn='active-turn'):
            return {'method': 'thread/tokenUsage/updated', 'params': {
                'threadId': thread, 'turnId': turn,
                'tokenUsage': {'last': {'totalTokens': current}, 'total': {'totalTokens': current},
                               'modelContextWindow': 100}}}
        adapter._observe(usage(64))
        assert not any(r['method'] == 'turn/steer' for r in adapter.proc.requests)
        adapter._observe(usage(65))
        requests = [r for r in adapter.proc.requests if r['method'] == 'turn/steer']
        assert len(requests) == 1, 'threshold must steer the active turn before it finishes'
        assert requests[0]['params']['threadId'] == 'thread-1'
        assert requests[0]['params']['expectedTurnId'] == 'active-turn'
        adapter._observe(usage(66))
        assert len([r for r in adapter.proc.requests if r['method'] == 'turn/steer']) == 1
        adapter.proc.terminate()
        adapter.close()


# Mid-turn native compaction has no threshold claim, but must still stop the work phase
# for fallback notes instead of letting the turn run until its deadline.
with tempfile.TemporaryDirectory(prefix='native-compaction-steer-') as temporary:
    for signal in ('item', 'method'):
        adapter = native.Codex(temporary, {}, None, None, Path(temporary) / (signal + '.log'))
        with patch.object(native.subprocess, 'Popen', Fake):
            adapter.start()
            adapter.turn_id = 'active-turn'
            adapter.checkpoint_threshold = 65
            adapter._observe(usage(40))
            adapter._observe({'method': 'item/started', 'params': {'threadId': 'thread-1', 'turnId': 'active-turn',
                'item': {'id': 'compact', 'type': 'contextCompaction'}}} if signal == 'item' else
                {'method': 'thread/compacted', 'params': {'threadId': 'thread-1', 'turnId': 'active-turn'}})
            steers = [r for r in adapter.proc.requests if r['method'] == 'turn/steer']
            assert adapter.compacted and len(steers) == 1, 'compaction must request fallback notes once'
            text = steers[0]['params']['input'][0]['text']
            assert 'compaction' in text and 'threshold reached' not in text
            adapter._observe(usage(70))
            assert len([r for r in adapter.proc.requests if r['method'] == 'turn/steer']) == 1
            if signal == 'item':
                # Native compaction took 55s in the 2026-09-22 proof. Its duration is not the
                # model's notes window: the deadline starts only once compaction completes.
                adapter.checkpoint_deadline = native.time.monotonic() - 1
                adapter._check()
                adapter._observe({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'turnId': 'active-turn',
                    'item': {'id': 'compact', 'type': 'contextCompaction'}}})
                assert adapter.checkpoint_deadline >= native.time.monotonic() + 59
                adapter.checkpoint_deadline = native.time.monotonic() - 1
                try:
                    adapter._check()
                    raise AssertionError('expired post-compaction notes window was accepted')
                except native.NativeError:
                    pass
                # A compaction that never completes cannot suspend the notes deadline forever.
                adapter._observe({'method': 'item/started', 'params': {'threadId': 'thread-1', 'turnId': 'active-turn',
                    'item': {'id': 'compact-2', 'type': 'contextCompaction'}}})
                adapter.checkpoint_deadline = native.time.monotonic() - 1
                adapter._check()
                adapter.compaction_started -= adapter.MAX_COMPACTION + 1
                try:
                    adapter._check()
                    raise AssertionError('unfinished native compaction suspended the deadline indefinitely')
                except native.NativeError as exc:
                    assert 'compaction' in str(exc)
            adapter.proc.terminate()
            adapter.close()
    # Before the controller enables work checkpoints (e.g. during load), compaction only records.
    adapter = native.Codex(temporary, {}, None, None, Path(temporary) / 'load.log')
    with patch.object(native.subprocess, 'Popen', Fake):
        adapter.start()
        adapter.turn_id = 'active-turn'
        adapter._observe({'method': 'item/started', 'params': {'threadId': 'thread-1', 'turnId': 'active-turn',
            'item': {'id': 'compact', 'type': 'contextCompaction'}}})
        assert adapter.compacted and not any(r['method'] == 'turn/steer' for r in adapter.proc.requests)
        adapter.proc.terminate()
        adapter.close()


with tempfile.TemporaryDirectory(prefix='native-threshold-race-') as temporary:
    for case in ('before', 'inflight', 'after', 'finished_rejected', 'rejected', 'wrong', 'timeout'):
        adapter = native.Codex(temporary, {}, None, None, Path(temporary) / (case + '.log'),
                               timeout=.1 if case == 'timeout' else 2, synchronous=lambda c: c == 'printf ok')
        adapter.POLL = .01
        with patch.object(native.subprocess, 'Popen', Fake):
            adapter.start()
            adapter.proc.checkpoint_case = case
            adapter.checkpoint_threshold = 65
            try:
                result = adapter.turn('work', {'type': 'object'})
                assert case in ('before', 'inflight', 'after', 'finished_rejected'), case
                assert result['payload'] == {'goal': 'ok'} and not result['unresolved_operations']
            except native.NativeError as exc:
                assert case in ('rejected', 'wrong', 'timeout'), (case, str(exc))
            finally:
                adapter.proc.terminate()
                adapter.close()


with tempfile.TemporaryDirectory(prefix='launch-native-test-') as tmp:
    log = Path(tmp) / 'native.log'
    with patch.object(native.subprocess, 'Popen', Fake):
        worker = native.Codex(tmp, {}, None, lambda: True, log, synchronous=lambda command: command == 'printf ok')
        assert worker.start()['thread_id'] == 'thread-1'
        started = []
        worker.on_turn_started = started.append
        result = worker.turn('continue', {'type': 'object'})
        assert started == ['turn-1']
        assert result['payload'] == {'goal': 'ok'}
        assert result['usage'] == {'current': 42, 'window': 100, 'total': 99}
        assert result['peak_fraction'] == .42
        assert result['tool_item_count'] == 1
        assert result['unresolved_operations'] == []
        worker._observe({'method': 'thread/tokenUsage/updated', 'params': {
            'threadId': 'thread-1', 'turnId': 'old-turn', 'tokenUsage': {
                'last': {'totalTokens': 99}, 'modelContextWindow': 100}}})
        assert 'stale-telemetry' in worker.unresolved
        worker.unresolved.clear()
        worker._observe_item({'id': 'opaque', 'type': 'commandExecution',
                              'status': 'completed', 'processId': 'opaque-handle', 'exitCode': None})
        assert 'command:opaque' in worker.unresolved
        worker._observe_item({'id': 'service', 'type': 'commandExecution', 'command': 'docker compose up -d', 'status': 'completed', 'exitCode': 0})
        assert 'unclassified-shell:service' in worker.unresolved
        worker.proc.returncode = 0
        try:
            worker.close()
            raise AssertionError('null-exit command handle was accepted')
        except native.QuiescenceError:
            pass
    with patch.object(native.subprocess, 'Popen', Fake):
        worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'approval.log')
        worker.start()
        try:
            worker._observe({'id': 7, 'method': 'approval/request', 'params': {}})
            raise AssertionError('server approval request was allowed')
        except native.UnsupportedRequest:
            pass
    with patch.object(native.subprocess, 'Popen', Fake):
        worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'foreign.log')
        worker.start()
        worker.proc.foreign = True
        try:
            worker.turn('continue', {'type': 'object'})
            raise AssertionError('foreign lifecycle did not block completion')
        except native.NativeError as exc:
            assert 'foreign native lifecycle' in str(exc)
    # A completed phase beyond 60 seconds uses its persistent controller allowance.
    with patch.object(native.subprocess, 'Popen', Fake):
        worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'long.log', timeout=120, synchronous=lambda command: command == 'printf ok')
        worker.start()
        original_raw = worker._raw
        elapsed, calls = [0], [0]
        def delayed_raw(timeout):
            calls[0] += 1
            if calls[0] == 2:
                elapsed[0] = 70
                return None
            return original_raw(timeout)
        with patch.object(worker, '_raw', delayed_raw), patch.object(native.time, 'monotonic', lambda: elapsed[0]):
            result = worker.turn('long declared phase', {'type': 'object'})
        assert result['payload'] == {'goal': 'ok'} and elapsed[0] == 70
        worker.proc.terminate()
        worker.close()
    assert 'continue' not in log.read_text()  # metadata only, never raw prompts/settings

with tempfile.TemporaryDirectory(prefix='launch-native-log-') as tmp:
    tmp = Path(tmp)
    existing = tmp / 'existing.log'
    existing.write_text('old')
    try:
        native.Codex(tmp, {}, None, lambda: True, existing).start()
        raise AssertionError('existing log was appended')
    except native.NativeError:
        pass
    target = tmp / 'target'
    target.mkdir()
    (tmp / 'link').symlink_to(target, target_is_directory=True)
    try:
        native.Codex(tmp, {}, None, lambda: True, tmp / 'link' / 'native.log').start()
        raise AssertionError('symlink log ancestor was accepted')
    except native.NativeError:
        pass

with tempfile.TemporaryDirectory(prefix='launch-native-line-') as tmp:
    worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'line.log')
    worker.proc = Fake()
    worker.proc.stdout.q.put('x' * (worker.MAX_LINE + 1))
    import threading
    threading.Thread(target=worker._reader, daemon=True).start()
    try:
        worker._raw(1)
        raise AssertionError('oversized stdout line was accepted')
    except native.NativeError as exc:
        assert 'exceeds limit' in str(exc)

# LC-030 live run (2026-10-17): Codex runs a command from a working directory, not a `cd x &&`
# prefix. A worktree subdirectory classifies as that prefix; anything outside stays unclassified.
with tempfile.TemporaryDirectory(prefix='launch-native-cwd-') as tmp:
    root = Path(tmp).resolve()
    (root / 'app').mkdir()
    seen = []
    worker = native.Codex(root, {}, None, None, root / 'cwd.log', synchronous=lambda s: seen.append(s) or True)
    for ident, cwd in (('a', root / 'app'), ('b', root), ('c', None)):
        item = {'id': ident, 'type': 'commandExecution', 'command': 'cmd', 'status': 'completed', 'exitCode': 0}
        worker._observe_item({**item, 'cwd': str(cwd)} if cwd else item)
    assert seen == ['cd app && cmd', 'cmd', 'cmd'], seen
    worker._observe_item({'id': 'd', 'type': 'commandExecution', 'command': 'cmd', 'cwd': tmp + '/../elsewhere',
                          'status': 'completed', 'exitCode': 0})
    assert 'unclassified-shell:d' in worker.unresolved and len(seen) == 3
    # A completed event without cwd keeps the started event's directory.
    worker._observe_item({'id': 'e', 'type': 'commandExecution', 'command': 'cmd', 'cwd': str(root / 'app'), 'status': 'inProgress'}, started=True)
    worker._observe_item({'id': 'e', 'type': 'commandExecution', 'command': 'cmd', 'status': 'completed', 'exitCode': 0})
    assert seen[-1] == 'cd app && cmd', seen
    for bad in ({'cwd': 'app'}, {'cwd': {'path': 'x'}}):  # Only an absolute string directory is rooted.
        worker._observe_item({'id': 'f', 'type': 'commandExecution', 'command': 'cmd', 'status': 'completed', 'exitCode': 0, **bad})
        assert 'unclassified-shell:f' in worker.unresolved
        worker.unresolved.discard('unclassified-shell:f')
    # The reviewer child classifies from its own working directory too.
    child_seen = []
    worker.reviewer_synchronous = lambda s: child_seen.append(s) or True
    worker._observe_child_item('child', {'id': 'g', 'type': 'commandExecution', 'command': 'cmd', 'cwd': str(root / 'app'), 'status': 'inProgress'}, 'parent')
    worker._observe_child_item('child', {'id': 'g', 'type': 'commandExecution', 'command': 'cmd', 'status': 'completed', 'exitCode': 0}, 'parent')
    worker._observe_child_item('child', {'id': 'h', 'type': 'commandExecution', 'command': 'cmd', 'cwd': '/elsewhere', 'status': 'completed', 'exitCode': 0}, 'parent')
    assert child_seen == ['cd app && cmd'] and 'child-command:child:h' in worker.unresolved, (child_seen, worker.unresolved)

# LC-030 live run (2026-10-16): the controller drains about 0.4 s per message (binding check and
# ps scans each loop), so a streamed final answer filled the queue; the reader's put timed out,
# put_nowait failed on the same full queue and the reader exited silently. The app-server then
# blocked writing turn/completed and the controller waited on an empty queue until its deadline.
with tempfile.TemporaryDirectory(prefix='launch-native-backpressure-') as tmp:
    worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'slow.log')
    worker.proc = Fake()
    worker.messages = native.queue.Queue(maxsize=2)
    for index in range(6):
        worker.proc.emit({'method': 'item/agentMessage/delta', 'params': {'n': index}})
    threading.Thread(target=worker._reader, daemon=True).start()
    time.sleep(worker.POLL * 1.6)  # A consumer slower than the reader's old put timeout.
    received = [worker._raw(2) for _ in range(6)]
    assert [m['params']['n'] for m in received if m] == list(range(6)), received
    worker.proc.stdout.q.put(None)
    started = time.monotonic()
    try:  # Output closed while the process lives: fail the wait now, never sit out the deadline.
        worker._wait(lambda msg: False, timeout=60)
        raise AssertionError('closed app-server output was not detected')
    except native.NativeError as exc:
        assert 'app-server output closed while the process runs' in str(exc), exc
    assert time.monotonic() - started < 10
    try:  # And so does every later wait; the closed marker is never consumed away.
        worker._wait(lambda msg: False, timeout=60)
        raise AssertionError('second wait after closed output hung or passed')
    except native.NativeError as exc:
        assert 'app-server output closed while the process runs' in str(exc), exc
    assert time.monotonic() - started < 10
    # A reader error behind a full queue still reaches the consumer, and keeps failing later reads.
    worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'error.log')
    worker.proc = Fake()
    worker.messages = native.queue.Queue(maxsize=2)
    worker.proc.emit({'method': 'a'}); worker.proc.emit({'method': 'b'})
    worker.proc.stdout.q.put('x' * (worker.MAX_LINE + 1))
    threading.Thread(target=worker._reader, daemon=True).start()
    time.sleep(worker.POLL * 1.6)
    assert [worker._raw(2)['method'], worker._raw(2)['method']] == ['a', 'b']
    for _ in range(2):
        try:
            worker._raw(2)
            raise AssertionError('reader error behind a full queue was lost')
        except native.NativeError as exc:
            assert 'exceeds limit' in str(exc), exc
    # Output closed after the process exited reports the exit code.
    worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'exit.log')
    worker.proc = Fake()
    worker.proc.returncode = 3
    worker.proc.stdout.q.put(None)
    threading.Thread(target=worker._reader, daemon=True).start()
    try:
        worker._raw(2)
        raise AssertionError('closed output after exit was accepted')
    except native.NativeError as exc:
        assert str(exc) == 'app-server exited: 3', exc
    # The binding check and ps scans run once per POLL, not once per message: a streamed answer
    # of 80 deltas behind a 50 ms check drains in about a second instead of four.
    worker = native.Codex(tmp, {}, None, None, Path(tmp) / 'fast.log')
    worker.proc = Fake()
    calls = []
    worker.check = lambda: calls.append(time.sleep(.05)) or True
    for index in range(80):
        worker.proc.emit({'method': 'item/agentMessage/delta', 'params': {'n': index}})
    worker.proc.emit({'id': 99, 'result': {}})
    threading.Thread(target=worker._reader, daemon=True).start()
    started = time.monotonic()
    worker._wait(lambda msg: msg.get('id') == 99, timeout=30)
    assert len(calls) <= 3 and time.monotonic() - started < 2, (len(calls), time.monotonic() - started)
    # A new wait checks before its first message even right after the previous wait's check.
    worker.check = lambda: False
    worker.proc.emit({'id': 100, 'result': {}})
    try:
        worker._wait(lambda msg: msg.get('id') == 100, timeout=30)
        raise AssertionError('a wait skipped its first binding check')
    except native.NativeError:
        pass

# Exercise real process-group termination without contacting a model or app-server.
with tempfile.TemporaryDirectory(prefix='launch-native-kill-') as tmp:
    worker = native.Codex(tmp, {}, None, lambda: True, Path(tmp) / 'kill.log')
    child = Path(tmp) / 'child.pid'
    code = 'import pathlib,subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)'
    with patch.object(native.Codex, 'COMMAND', (sys.executable, '-c', code, str(child))):
        worker.proc = native.subprocess.Popen(worker.COMMAND, stdin=native.subprocess.PIPE,
            stdout=native.subprocess.PIPE, stderr=native.subprocess.DEVNULL, text=True,
            start_new_session=True)
        worker.pgid = worker.proc.pid
        for _ in range(50):
            if child.exists(): break
            native.time.sleep(.01)
        assert child.exists()
        child_pid = int(child.read_text())
        assert worker.close()['group'] == 'gone'
        assert worker.proc.poll() is not None
        assert not worker._alive(child_pid)

print('launch native transport checks passed')

import os
import signal
import subprocess

PARENT, TURN, CHILD, CHILD_TURN = 'parent', 'parent-turn', 'child', 'child-turn'


def event(method, thread, turn_id, item=None, **extra):
    params = {'threadId': thread, 'turnId': turn_id}
    if item is not None:
        params['item'] = item
    params.update(extra)
    return {'method': method, 'params': params}


def readback(status='completed', child_items=None):
    return {
        PARENT: {'turns': [{'id': TURN, 'status': 'completed', 'items': []}]},
        CHILD: {
            'source': {'subAgent': {'thread_spawn': {'parent_thread_id': PARENT, 'depth': 1, 'agent_path': '/root/reviewer'}}},
            'turns': [{'id': CHILD_TURN, 'status': status, 'items': child_items or [
                {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'ship'},
                {'id': 'parent-message', 'type': 'subAgentActivity', 'kind': 'interacted',
                 'agentThreadId': PARENT, 'agentPath': '/root'}]}],
        },
    }


def worker(data, required=False):
    result = native.Codex('.', {}, None, None, 'unused',
        synchronous=lambda command: command == 'printf readonly',
        reviewer_synchronous=lambda command: command == 'printf readonly',
        reviewer_reconciliation=True, reviewer_readback=lambda: data,
        reviewer_required=required, reviewer_path='/root/reviewer')
    result.thread_id, result.turn_id = PARENT, TURN
    return result


data = readback()
item = {'id': 'spawn', 'type': 'subAgentActivity', 'kind': 'started', 'agentThreadId': CHILD,
        'agentPath': '/root/reviewer'}
w = worker(data)
w._observe(event('item/started', PARENT, TURN, item))
w._observe(event('item/completed', PARENT, TURN, item))  # actual activity snapshot repeats
w._observe(event('turn/started', CHILD, CHILD_TURN))
w._observe(event('thread/tokenUsage/updated', CHILD, CHILD_TURN,
    tokenUsage={'last': {'totalTokens': 1}, 'total': {'totalTokens': 3}, 'modelContextWindow': 10}))
w._observe(event('item/completed', PARENT, TURN,
    {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}))
w._observe(event('item/started', CHILD, CHILD_TURN,
    {'id': 'cmd', 'type': 'commandExecution', 'command': "/bin/zsh -lc 'printf readonly'", 'status': 'inProgress'}))
w._observe(event('item/completed', CHILD, CHILD_TURN,
    {'id': 'cmd', 'type': 'commandExecution', 'status': 'completed', 'exitCode': 0}))
w._observe(event('item/completed', CHILD, CHILD_TURN,
    {'id': 'parent-message', 'type': 'subAgentActivity', 'kind': 'interacted',
     'agentThreadId': PARENT, 'agentPath': '/root'}))
w._observe(event('turn/completed', CHILD, CHILD_TURN, turn={'id': CHILD_TURN, 'status': 'completed'}))
w._observe(event('item/completed', PARENT, TURN,
    {'id': 'wait', 'type': 'collabAgentToolCall', 'tool': 'wait', 'status': 'completed',
     'senderThreadId': PARENT, 'receiverThreadIds': []}))
# turn/completed replays the same activities after their live item events.
for final_item in [item, {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD},
                   {'id': 'wait', 'type': 'collabAgentToolCall', 'tool': 'wait', 'status': 'completed',
                    'senderThreadId': PARENT, 'receiverThreadIds': []}]:
    w._observe_item(final_item)
assert w.reconcile_reviewer()['reviewer_children'] == [CHILD]
assert w.reviewer_telemetry[CHILD]['current'] == 1

# The interruptible clock.sleep display item is in-turn: unresolved only while it runs.
nap = {'id': 'call_sleep', 'type': 'sleep', 'durationMs': 30000}
napper = worker(readback())
napper._observe(event('item/started', PARENT, TURN, nap))
assert napper.unresolved == {'sleep:call_sleep'}, napper.unresolved
napper._observe(event('item/completed', PARENT, TURN, nap))
assert not napper.unresolved, napper.unresolved
napper._observe_item(nap)  # turn/completed replay of a finished sleep
assert not napper.unresolved, napper.unresolved
assert w.reviewer_telemetry[CHILD]['total'] == 3
assert w.reviewer_history[-1]['verdict'] == 'ship'
approved_review = w.reviewer_snapshot
assert approved_review['parent_thread_id'] == PARENT and approved_review['parent_turn_id'] == TURN

# Only the exact parent interaction is accounted for; it cannot replace a verdict.
interaction = {'id': 'parent-message', 'type': 'subAgentActivity', 'kind': 'interacted',
               'agentThreadId': PARENT, 'agentPath': '/root'}
for changed in ({'kind': 'started'}, {'kind': 'completed'}, {'kind': 'unknown'},
                {'agentThreadId': CHILD}, {'agentThreadId': 'foreign'},
                {'agentThreadId': None}, {'agentPath': '/root/other'}, {'agentPath': None},
                {'id': None}, {'id': ''}, {'id': 3}):
    bad = {**interaction, **changed}
    w = worker(readback())
    w._observe_child_item(CHILD, bad, PARENT)
    assert 'child-tool:subAgentActivity:' + CHILD in w.unresolved, bad
try:
    worker(readback())._review_verdict(readback(child_items=[interaction]), PARENT, TURN, CHILD, CHILD_TURN)
    raise AssertionError('parent interaction supplied a review verdict')
except native.QuiescenceError as exc:
    assert 'no final verdict' in str(exc)

# A normal phase does not require a reviewer; the higher-level final phase owns that gate.
w = worker(data)
assert w.reconcile_reviewer(required=False) is None

# Empty wait receivers are allowed, but cannot create ownership.
w = worker(data)
w._observe(event('item/completed', PARENT, TURN,
    {'id': 'wait', 'type': 'collabAgentToolCall', 'tool': 'wait', 'status': 'completed',
     'senderThreadId': PARENT, 'receiverThreadIds': []}))
try:
    w.reconcile_reviewer()
    raise AssertionError('wait created reviewer ownership')
except native.QuiescenceError as exc:
    assert 'no observed reviewer child' in str(exc)

for bad_item, reason in [
    ({'id': 'spawn', 'type': 'subAgentActivity', 'kind': 'started', 'agentThreadId': PARENT, 'agentPath': '/root/reviewer'}, 'recursive'),
    ({'id': 'spawn', 'type': 'subAgentActivity', 'kind': 'mystery', 'agentThreadId': CHILD, 'agentPath': '/root/reviewer'}, 'unknown'),
    ({'id': 'spawn', 'type': 'subAgentActivity', 'kind': 'started', 'agentThreadId': CHILD, 'agentPath': '/root/foreign'}, 'unexpected'),
]:
    w = worker(data)
    w._observe(event('item/started', PARENT, TURN, bad_item))
    assert any(reason in value for value in w.unresolved), (bad_item, w.unresolved)

w = worker(readback(child_items=[{'type': 'fileChange', 'status': 'completed'},
                                 {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'ship'}]))
w._observe(event('item/started', PARENT, TURN, item))
w._observe(event('turn/started', CHILD, CHILD_TURN))
w._observe(event('thread/tokenUsage/updated', CHILD, CHILD_TURN,
    tokenUsage={'last': {'totalTokens': 1}, 'modelContextWindow': 10}))
w._observe(event('item/completed', PARENT, TURN,
    {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}))
w._observe(event('turn/completed', CHILD, CHILD_TURN, turn={'id': CHILD_TURN, 'status': 'completed'}))
try:
    w.reconcile_reviewer()
    raise AssertionError('child file change accepted')
except native.QuiescenceError as exc:
    assert 'child-tool:fileChange' in str(exc)


# turn() reconciles an observed optional reviewer, while an ordinary no-child phase stays allowed.
class Running:
    pid = None
    def poll(self): return None

w = worker(data, required=False)
w.proc = Running()
w._send = lambda method, params: 1
events = [
    {'id': 1, 'result': {'turn': {'id': TURN}}},
    event('item/started', PARENT, TURN, item),
    event('turn/started', CHILD, CHILD_TURN),
    event('thread/tokenUsage/updated', CHILD, CHILD_TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'total': {'totalTokens': 3}, 'modelContextWindow': 10}),
    event('item/completed', PARENT, TURN,
          {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}),
    event('turn/completed', CHILD, CHILD_TURN, turn={'id': CHILD_TURN, 'status': 'completed'}),
    event('thread/tokenUsage/updated', PARENT, TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'modelContextWindow': 10}),
    event('turn/completed', PARENT, TURN, turn={'id': TURN, 'status': 'completed', 'items': [
        item, {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD},
        {'id': 'msg', 'type': 'agentMessage', 'text': '{"goal":"ok"}'}]}),
]
w._raw = lambda timeout: events.pop(0) if events else None
result = w.turn('review', {'type': 'object'})
assert result['reviewer']['reviewer_children'] == [CHILD]

# WORK27: the parent turn completes before its reviewer child; drain the child lifecycle, then reconcile strictly.
w = worker(data, required=False)
w.proc = Running()
w._send = lambda method, params: 1
parent_done = event('turn/completed', PARENT, TURN, turn={'id': TURN, 'status': 'completed', 'items': [
    item, {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD},
    {'id': 'msg', 'type': 'agentMessage', 'text': '{"goal":"ok"}'}]})
events = [
    {'id': 1, 'result': {'turn': {'id': TURN}}},
    event('item/started', PARENT, TURN, item),
    event('turn/started', CHILD, CHILD_TURN),
    event('item/completed', PARENT, TURN,
          {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}),
    event('thread/tokenUsage/updated', PARENT, TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'modelContextWindow': 10}),
    parent_done,
    event('thread/tokenUsage/updated', CHILD, CHILD_TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'total': {'totalTokens': 3}, 'modelContextWindow': 10}),
    event('turn/completed', CHILD, CHILD_TURN, turn={'id': CHILD_TURN, 'status': 'completed'}),
]
w._raw = lambda timeout: events.pop(0) if events else None
result = w.turn('review', {'type': 'object'})
assert result['reviewer']['reviewer_children'] == [CHILD], 'parent-first reviewer lifecycle was not drained'
assert result['reviewer']['telemetry'][CHILD]['total'] == 3 and not events

# The child's usage update may follow its turn/completed; the drain waits for both.
w = worker(data, required=False)
w.proc = Running()
w._send = lambda method, params: 1
events = [
    {'id': 1, 'result': {'turn': {'id': TURN}}},
    event('item/started', PARENT, TURN, item),
    event('turn/started', CHILD, CHILD_TURN),
    event('item/completed', PARENT, TURN,
          {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}),
    event('thread/tokenUsage/updated', PARENT, TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'modelContextWindow': 10}),
    parent_done,
    event('turn/completed', CHILD, CHILD_TURN, turn={'id': CHILD_TURN, 'status': 'completed'}),
    event('thread/tokenUsage/updated', CHILD, CHILD_TURN,
          tokenUsage={'last': {'totalTokens': 1}, 'total': {'totalTokens': 5}, 'modelContextWindow': 10}),
]
w._raw = lambda timeout: events.pop(0) if events else None
result = w.turn('review', {'type': 'object'})
assert result['reviewer']['telemetry'][CHILD]['total'] == 5 and not events, 'late child usage was not drained'

# A reviewer child that never settles fails as a reviewer quiescence error, not a generic timeout.
w = worker(data, required=False)
w.proc = Running()
w._send = lambda method, params: 1
w.timeout = 0.3
events = [
    {'id': 1, 'result': {'turn': {'id': TURN}}},
    event('item/started', PARENT, TURN, item),
    event('turn/started', CHILD, CHILD_TURN),
    event('item/completed', PARENT, TURN,
          {'id': 'done', 'type': 'subAgentActivity', 'kind': 'completed', 'agentThreadId': CHILD}),
    parent_done,
]
w._raw = lambda timeout: events.pop(0) if events else None
try:
    w.turn('review', {'type': 'object'})
    raise AssertionError('unsettled reviewer child accepted')
except native.QuiescenceError as exc:
    assert str(exc) == 'reviewer child did not settle before the turn timeout'


def process_worker(child_seconds, reviewer=True, scan=True):
    tmp = tempfile.TemporaryDirectory(prefix='native-review-process-')
    child_file = Path(tmp.name) / 'child.pid'
    code = ('import pathlib,subprocess,sys,time; '
            'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(' + str(child_seconds) + ')"]'
            ', start_new_session=True); pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)')
    w = native.Codex(tmp.name, {}, None, None, Path(tmp.name) / 'native.log', reviewer_reconciliation=reviewer,
                     reviewer_readback=lambda: {})
    w.proc = subprocess.Popen([sys.executable, '-c', code, str(child_file)], start_new_session=True)
    w.pgid = w.proc.pid
    for _ in range(100):
        if child_file.exists():
            break
        native.time.sleep(.01)
    assert child_file.exists()
    child_pid = int(child_file.read_text())
    if scan:
        w._scan_descendants()
        assert child_pid in w.known_descendants
    return tmp, w, child_pid


# A same-group descendant still exiting when the leader stops (Codex 0.162's plugin marketplace
# git refresh) is drained, then killed, instead of failing closure.
with tempfile.TemporaryDirectory(prefix='native-group-drain-') as directory:
    child_file = Path(directory) / 'child.pid'
    code = ('import pathlib,signal,subprocess,sys,time; '
            'p=subprocess.Popen([sys.executable,"-c","import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"]); '
            'pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)')
    w = native.Codex(directory, {}, None, None, Path(directory) / 'native.log')
    w.proc = subprocess.Popen([sys.executable, '-c', code, str(child_file)], start_new_session=True)
    w.pgid = w.proc.pid
    for _ in range(200):
        if child_file.exists():
            break
        native.time.sleep(.01)
    lingering = int(child_file.read_text())
    started = native.time.monotonic()
    assert w.close()['group'] == 'gone'
    assert native.time.monotonic() - started < 10, 'group drain is bounded'
    try:
        os.kill(lingering, 0)
        raise AssertionError('same-group descendant survived closure')
    except ProcessLookupError:
        pass

# A separately grouped descendant that exits after its parent stops is accounted for and accepted.
tmp, w, child_pid = process_worker(.1)
try:
    assert w.close()['group'] == 'gone'
finally:
    if native.Codex._alive(child_pid):
        os.kill(child_pid, signal.SIGKILL)
    tmp.cleanup()

# A separately grouped descendant that survives is refused; cleanup belongs to this test only.
tmp, w, child_pid = process_worker(60)
try:
    try:
        w.close()
        raise AssertionError('surviving external-group descendant accepted')
    except native.QuiescenceError as exc:
        assert 'known native descendants remain' in str(exc)
finally:
    if native.Codex._alive(child_pid):
        os.kill(child_pid, signal.SIGKILL)
    tmp.cleanup()

# Ordinary workers must discover late separate-session helpers at close, without a prior scan.
tmp, w, child_pid = process_worker(60, reviewer=False, scan=False)
try:
    try:
        w.close()
        raise AssertionError('ordinary worker accepted an unscanned surviving helper')
    except native.QuiescenceError as exc:
        assert 'known native descendants remain' in str(exc)
        assert child_pid in w.known_descendants
finally:
    if native.Codex._alive(child_pid):
        os.kill(child_pid, signal.SIGKILL)
    tmp.cleanup()

# The non-reviewer path retains the original same-group descendant refusal.
class Finished:
    pid = None
    def poll(self): return 0

w = native.Codex('.', {}, None, None, 'unused')
w.proc, w.pgid, w.known_pids = Finished(), 1, {99}
w._terminate = lambda: None
w._group_alive = lambda: False
w._alive = lambda pid: True
try:
    w.close()
    raise AssertionError('default known-pid refusal regressed')
except native.QuiescenceError as exc:
    assert 'known native descendants remain: 99' in str(exc)

# Only ps's documented empty exit-1 result means a PID is absent; other failures stay unknown.
with patch.object(native.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'ps', output='', stderr='')):
    assert native.Codex._identity_alive(99, 'identity') is False
with patch.object(native.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(2, 'ps', output='', stderr='bad')):
    assert native.Codex._identity_alive(99, 'identity') is None

with patch.object(native.subprocess, 'check_output', return_value=''):
    assert native.Codex._identity_alive(99, 'identity') is None

print('review lifecycle checks passed')

# Parent completion authority is never inherited by the independent reviewer.
for command in ('git add tracked', 'git commit -m mutation', 'bash scripts/verify.sh checks', 'cat tracked > copy'):
    w = native.Codex('.', {}, None, None, 'unused', synchronous=lambda value: True,
                     reviewer_reconciliation=True, reviewer_readback=lambda: readback(),
                     reviewer_synchronous=lambda value: value == 'git status --short')
    w._observe_child_item(CHILD, {'type': 'commandExecution', 'id': 'mutating',
                                  'status': 'completed', 'command': command, 'exitCode': 0}, PARENT)
    assert w.unresolved, command

# LC-030 live run 3: a reviewer read that exits nonzero (`git rev-parse HEAD^2` on a non-merge) ran and ended.
for status, code, settled in (('failed', 128, True), ('completed', 1, True), ('failed', None, False), ('declined', 1, False)):
    w = native.Codex('.', {}, None, None, 'unused', synchronous=lambda value: True,
                     reviewer_reconciliation=True, reviewer_readback=lambda: readback(),
                     reviewer_synchronous=lambda value: value == 'git rev-parse HEAD^2')
    w._observe_child_item(CHILD, {'type': 'commandExecution', 'id': 'probe', 'status': status,
                                  'command': 'git rev-parse HEAD^2', 'exitCode': code}, PARENT)
    assert (not w.unresolved) is settled, (status, code, w.unresolved)

for failure in ('path', 'parent', 'terminal', 'mutation'):
    snapshot = readback()
    if failure in ('path', 'parent'):
        snapshot[CHILD]['source']['subAgent']['thread_spawn'][
            'agent_path' if failure == 'path' else 'parent_thread_id'] = 'foreign'
    elif failure == 'terminal':
        snapshot[CHILD]['turns'][0]['status'] = 'interrupted'
    else:
        snapshot[CHILD]['turns'][0]['items'].insert(0, {'type': 'commandExecution', 'id': 'bad',
            'command': 'git commit -m bad', 'status': 'completed', 'exitCode': 0})
    w = worker(snapshot)
    w.reviewer_children = {CHILD: {'started': True, 'completed': True, 'turn_id': CHILD_TURN, 'terminal': 'completed'}}
    w.reviewer_telemetry = {CHILD: {'current': 1, 'window': 10, 'total': 3}}
    try:
        w.reconcile_reviewer()
        raise AssertionError('bad terminal readback accepted: ' + failure)
    except native.QuiescenceError:
        pass

with tempfile.TemporaryDirectory(prefix='native-permissions-') as temporary:
    for failure in (None, 'profile', 'tools', 'pagination', 'startup', 'turn'):
        calls = []
        def check():
            calls.append('check')
            return failure != 'startup'
        adapter = native.Codex(temporary, {}, None, check, Path(temporary) / (str(failure) + '.log'),
                               command=['/pinned/codex', 'app-server'], permission_profile='restricted')
        with patch.object(native.subprocess, 'Popen', Fake), \
             patch.object(Fake, 'profile', 'wrong' if failure == 'profile' else None), \
             patch.object(Fake, 'tools', {'unapproved': {}} if failure == 'tools' else {}), \
             patch.object(Fake, 'unfinished', failure == 'pagination'):
            try:
                if failure in ('profile', 'tools', 'pagination', 'startup'):
                    try:
                        adapter.start()
                        raise AssertionError('unsafe startup accepted: ' + failure)
                    except native.NativeError:
                        if failure == 'startup': assert adapter.proc is None
                else:
                    settings = adapter.start()
                    assert settings['permission_profile'] == 'restricted'
                    assert adapter.proc.command == ['/pinned/codex', 'app-server']
                    assert len([r for r in adapter.proc.requests if r['method'] == 'mcpServerStatus/list']) == 2
                    if failure == 'turn':
                        adapter.check = lambda: False
                        try:
                            adapter.turn('must not dispatch', {'type': 'object'})
                            raise AssertionError('unapproved turn dispatched')
                        except native.NativeError:
                            assert not any(r['method'] == 'turn/start' for r in adapter.proc.requests)
                assert calls
            finally:
                if adapter.proc is not None: adapter.proc.terminate()
                adapter.close()
print('PASS: explicit native profile, pre-spawn/pre-turn refusal and complete empty tool inventory')

with tempfile.TemporaryDirectory(prefix='native-review-readback-') as temporary:
    reader = native.Codex(temporary, {}, None, lambda: True, Path(temporary) / 'readback.log')
    with patch.object(native.subprocess, 'Popen', Fake):
        try:
            reader.connect()
            assert reader.read_review(approved_review) == 'ship'
            assert [r['method'] for r in reader.proc.requests] == ['initialize', 'thread/read', 'thread/read']
            assert reader.thread_id is None and reader.turn_id is None
        finally:
            if reader.proc is not None: reader.proc.terminate()
            reader.close()
for failure in ('parent', 'path', 'terminal', 'mutation', 'verdict'):
    snapshot = readback()
    if failure in ('parent', 'path'):
        snapshot[CHILD]['source']['subAgent']['thread_spawn'][
            'parent_thread_id' if failure == 'parent' else 'agent_path'] = 'foreign'
    elif failure == 'terminal':
        snapshot[PARENT]['turns'][0]['status'] = 'interrupted'
    elif failure == 'mutation':
        snapshot[CHILD]['turns'][0]['items'].insert(0, {'type': 'fileChange', 'status': 'completed'})
    else:
        snapshot[CHILD]['turns'][0]['items'][0]['text'] = 'ship changed verdict'
    reader = native.Codex('.', {}, None, None, 'unused')
    reader._request = lambda method, params: {'thread': snapshot[params['threadId']]}
    try:
        reader.read_review(approved_review)
        raise AssertionError('changed historical review accepted: ' + failure)
    except native.QuiescenceError:
        pass
print('PASS: exact historical review readback creates no native thread or turn')


# Terminal command/file failures must stop the active turn, including final-only items.
# Codex 0.162 reports a nonzero exit as failed with its exitCode: ordinary work (observed RED,
# absent file) that stays resolved. A failure with no exit code still stops the turn below.
w = native.Codex('.', {}, None, None, 'unused', synchronous=lambda c: True)
for status in ('failed', 'completed'):
    w._observe_item({'id': 'red', 'type': 'commandExecution', 'command': 'python3 test_totals.py',
                     'status': status, 'exitCode': 1})
    assert 'command:red' not in w.unresolved and w.items['red']['status'] == status
for item in (
    {'id': 'broken', 'type': 'commandExecution', 'command': 'printf ok', 'status': 'failed'},
    {'id': 'broken', 'type': 'fileChange', 'status': 'failed'},
    {'id': 'broken', 'type': 'fileChange', 'status': 'declined'},
):
    w = native.Codex('.', {}, None, None, 'unused', synchronous=lambda c: True)
    try:
        w._observe_item(item)
        raise AssertionError('native failure accepted as successful work')
    except native.NativeError as exc:
        assert 'broken' in str(exc) and 'failed:' in str(exc)
    assert w.items['broken']['status'] == item['status']

# Unknown telemetry still refuses handoff, while retaining independently proved cleanup.
with tempfile.TemporaryDirectory(prefix='native-interrupted-') as tmp:
    w = native.Codex(tmp, {}, None, None, Path(tmp) / 'native.log')
    w.proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
    w.pgid = w.proc.pid
    w.unresolved.add('unknown-telemetry')
    try:
        try:
            w.close()
            raise AssertionError('unknown telemetry admitted handoff')
        except native.QuiescenceError as exc:
            assert 'unknown-telemetry' in str(exc)
        assert w.closure['group'] == 'gone' and w.proc.poll() is not None
        assert not w._group_alive()
    finally:
        w._terminate()

# An abrupt exit can orphan an unseen helper; absence of observations is not quiescence.
for scan in (False, True):
    tmp, w, child_pid = process_worker(60, reviewer=False, scan=scan)
    try:
        os.kill(w.pid, signal.SIGKILL)
        w.proc.wait(timeout=5)
        assert w._alive(child_pid)
        try:
            w.close()
            raise AssertionError('abrupt parent exit accepted with surviving helper')
        except native.QuiescenceError as exc:
            assert ('known native descendants remain' if scan else 'unobserved-process-exit') in str(exc)
        assert w._alive(child_pid), 'controller must not kill outside its owned group'
    finally:
        if w._alive(child_pid):
            os.kill(child_pid, signal.SIGKILL)
        end = native.time.monotonic() + 5
        while w._alive(child_pid) and native.time.monotonic() < end:
            native.time.sleep(.01)
        assert not w._alive(child_pid), 'fixture helper was not reaped'
        tmp.cleanup()
print('PASS: first native failures, interrupted telemetry closure, observed and unseen orphan refusal')


# An interrupted request with no acknowledged turn cannot inherit the previous turn ID.
with tempfile.TemporaryDirectory(prefix='native-unacknowledged-') as tmp:
    with patch.object(native.subprocess, 'Popen', Fake):
        w = native.Codex(tmp, {}, None, None, Path(tmp) / 'native.log', synchronous=lambda c: True)
        w.start()
        w.turn('first', {'type': 'object'})
        assert w.turn_id == 'turn-1'
        w.check = lambda: False
        try:
            w.turn('second', {'type': 'object'})
            raise AssertionError('stopped controller dispatched an acknowledged turn')
        except native.NativeError:
            assert w.turn_id is None and w.latest_usage is None
        finally:
            w.proc.terminate()
            try:
                w.close()
            except native.QuiescenceError as exc:
                assert 'unknown-telemetry' in str(exc)
print('PASS: unacknowledged interrupted turn retains unknown identity and usage')
