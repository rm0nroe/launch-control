#!/usr/bin/env python3
"""Small, fail-closed Codex app-server transport for Launch controllers."""
import importlib.util
import json
import os
from pathlib import Path
import queue
import shlex
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('launch_process', Path(__file__).with_name('launch-process.py'))
_process = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_process)
OwnedProcess = _process.OwnedProcess


class NativeError(RuntimeError):
    pass


class UnsupportedRequest(NativeError):
    pass


class QuiescenceError(NativeError):
    pass


class Codex(OwnedProcess):
    """One owned app-server process. Queue/runtime state remains external."""
    Error = NativeError
    Quiescence = QuiescenceError
    WORKER = 'app-server'
    READER_EOF_EVENT = True
    COMMAND = ('codex', 'app-server')
    MAX_COMPACTION = 300  # observed native compaction took 50-55 s

    def __init__(self, cwd, env, lock_fd, check, log_path, timeout=3600, synchronous=None,
                 reviewer_reconciliation=False, reviewer_readback=None, reviewer_required=False,
                 reviewer_path='/root/reviewer', reviewer_synchronous=None,
                 command=None, permission_profile=None):
        if (command is None) != (permission_profile is None):
            raise NativeError('native command and permission profile must be supplied together')
        if command is not None and (not isinstance(command, (list, tuple)) or not command
                or not all(isinstance(arg, str) and arg for arg in command)
                or not isinstance(permission_profile, str) or not permission_profile):
            raise NativeError('invalid native command or permission profile')
        self.command = list(command) if command is not None else None
        self.permission_profile = permission_profile
        if not 0 < timeout <= 3600:
            raise NativeError('native phase timeout must be within one hour')
        self.timeout = timeout
        self.synchronous = synchronous or (lambda command: False)
        if reviewer_reconciliation and not callable(reviewer_readback):
            raise NativeError('reviewer reconciliation requires a readback callback')
        self.reviewer_synchronous = reviewer_synchronous or (lambda command: False)
        self.reviewer_reconciliation = reviewer_reconciliation
        self.reviewer_readback = reviewer_readback
        self.reviewer_required = reviewer_required
        if not isinstance(reviewer_path, str) or not reviewer_path:
            raise NativeError('reviewer path required')
        self.reviewer_path = reviewer_path
        self.reviewer_children = {}
        self.reviewer_activity_ids = {}
        self.reviewer_item_state = {}
        self.reviewer_telemetry = {}
        self.reviewer_snapshot = None
        self.reviewer_history = []
        self.cwd = str(Path(cwd).resolve())
        self.env = dict(env)
        self.lock_fd = lock_fd
        self.check = check
        self._own(log_path)
        self.next_id = 1
        self.thread_id = None
        self.model = None
        self.turn_id = None
        self.latest_usage = None
        self.peak_fraction = None
        self._turn_window = None
        self.compacted = False
        self.compacting = False
        self.items = {}
        self._deferred = []
        self.on_turn_started = None  # controller may durably receipt the native ID
        self.checkpoint_threshold = None  # enabled by the queue after no-tool load
        self.checkpoint_request = None
        self.checkpoint_reply = None
        self.checkpoint_deadline = None

    def _check(self):
        if self.compacting and time.monotonic() - self.compaction_started > self.MAX_COMPACTION:
            raise NativeError('native compaction did not complete within its bound')
        if (self.checkpoint_deadline is not None and not self.compacting
                and time.monotonic() >= self.checkpoint_deadline):
            raise NativeError('active context checkpoint deadline exceeded')
        if self.check is not None:
            result = self.check()
            if result is False:
                raise NativeError('external controller stopped native worker')

    def _send(self, method, params, request=True):
        if self.proc is None or self.proc.stdin is None:
            raise NativeError('app-server is not running')
        payload = {'method': method, 'params': params}
        ident = None
        if request:
            ident = self.next_id
            self.next_id += 1
            payload['id'] = ident
        encoded = json.dumps(payload, separators=(',', ':'))
        if len(encoded) > self.MAX_LINE:
            raise NativeError('app-server request exceeds limit')
        self.proc.stdin.write(encoded + '\n')
        self.proc.stdin.flush()
        self._record('send', method=method, request=bool(request))
        return ident

    def _deny(self, msg):
        # This preserves native approvals: the controller never approves a server request.
        self.proc.stdin.write(json.dumps({'id': msg['id'], 'error': {
            'code': -32601, 'message': 'Launch controller cannot approve native server request'}}) + '\n')
        self.proc.stdin.flush()
        self._record('unsupported_request', method=str(msg.get('method', ''))[:120])
        raise UnsupportedRequest('unsupported app-server request: ' + str(msg.get('method')))

    def _observe_item(self, item, started=False):
        if not isinstance(item, dict):
            self.unresolved.add('malformed-item')
            return
        ident = str(item.get('id', 'unknown'))
        typ = str(item.get('type', 'unknown'))
        status = item.get('status')
        command = item.get('command', self.items.get(ident, {}).get('command'))
        cwd = item.get('cwd', self.items.get(ident, {}).get('cwd'))
        if self.reviewer_reconciliation and typ == 'subAgentActivity':
            self._observe_reviewer_activity(item)
        elif self.reviewer_reconciliation and typ == 'collabAgentToolCall' and item.get('tool') == 'wait':
            # Receipt data shows wait may have no receivers. It is never ownership evidence.
            if item.get('senderThreadId') != self.thread_id or not isinstance(item.get('receiverThreadIds'), list):
                self.unresolved.add('invalid-reviewer-wait:' + ident)
        elif typ in ('mcpToolCall', 'subagent', 'backgroundTask') or 'mcp' in typ.lower() or 'subagent' in typ.lower():
            self.unresolved.add(typ + ':' + ident)
        elif typ == 'commandExecution':
            key = 'command:' + ident
            script = self._rooted(self._shell_script(command), cwd)
            if script is None or self.synchronous(script) is not True:
                self.unresolved.add('unclassified-shell:' + ident)
            if status not in ('completed', 'failed', 'declined') or (status == 'completed' and item.get('exitCode') is None):
                self.unresolved.add(key)
            else:
                self.unresolved.discard(key)
        elif typ == 'sleep':
            # Interruptible in-turn clock.sleep: no process or status, only its started/completed events.
            (self.unresolved.add if started else self.unresolved.discard)('sleep:' + ident)
        elif typ == 'fileChange':
            key = 'fileChange:' + ident
            if status not in ('completed', 'failed', 'declined', 'applied'):
                self.unresolved.add(key)
            else:
                self.unresolved.discard(key)
        elif typ not in ('userMessage', 'agentMessage', 'reasoning', 'plan', 'contextCompaction', 'todoList', 'webSearch'):
            self.unresolved.add(typ + ':' + ident)
        self.items[ident] = {'type': typ, 'status': status, 'command': command, 'cwd': cwd}
        if 'compact' in typ.lower():
            self.compacted = True
        # Codex reports a nonzero exit as failed with its exitCode. An exited command (RED test,
        # absent file) is ordinary work; checks rerun independently. Refusal or no process stays fatal.
        exited = typ == 'commandExecution' and status == 'failed' and type(item.get('exitCode')) is int
        if typ in ('commandExecution', 'fileChange') and status in ('failed', 'declined') and not exited:
            raise NativeError(f'native {typ} failed: {ident} status={status} exit={item.get("exitCode")}')

    def _rooted(self, script, cwd):
        """Codex runs a command from a working directory: a worktree subdirectory classifies as `cd <dir> && `."""
        if script is None or cwd is None:
            return script
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            return None
        root, here = Path(os.path.realpath(self.cwd)), Path(os.path.realpath(cwd))
        if here == root:
            return script
        if not here.is_relative_to(root):
            return None  # Outside the worktree: never classified.
        return 'cd ' + shlex.quote(str(here.relative_to(root))) + ' && ' + script

    @staticmethod
    def _shell_script(command):
        script = command
        if isinstance(command, str):
            try:
                lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
                lexer.commenters = ''
                words = list(lexer)
                # Decode one native transport envelope; nested shells stay classified.
                if len(words) == 3 and words[0] in ('/bin/zsh', '/bin/bash', '/bin/sh') and words[1] in ('-lc', '-c'):
                    script = words[2]
            except ValueError:
                script = None
        return script

    def _observe_reviewer_activity(self, item):
        ident, kind, child = str(item.get('id', 'unknown')), item.get('kind'), item.get('agentThreadId')
        if kind not in ('started', 'completed') or not isinstance(child, str) or not child:
            self.unresolved.add('unknown-reviewer-activity:' + ident)
            return
        signature = (kind, child, item.get('agentPath') if kind == 'started' else None)
        prior = self.reviewer_activity_ids.get(ident)
        if prior is not None:
            if prior != signature:
                self.unresolved.add('conflicting-reviewer-activity:' + ident)
            return
        self.reviewer_activity_ids[ident] = signature
        if child == self.thread_id:
            self.unresolved.add('recursive-reviewer:' + child)
            return
        if kind == 'started':
            if item.get('agentPath') != self.reviewer_path:
                self.unresolved.add('unexpected-reviewer-path:' + child)
                return
            if child in self.reviewer_children or len(self.reviewer_children) >= 1:
                self.unresolved.add('reviewer-limit-or-duplicate:' + child)
                return
            self.reviewer_children[child] = {'started': True, 'completed': False, 'turn_id': None, 'terminal': None}
        elif child not in self.reviewer_children:
            self.unresolved.add('unregistered-reviewer:' + child)
        else:
            self.reviewer_children[child]['completed'] = True

    def _observe_child_item(self, child, item, parent_id):
        typ, ident = str(item.get('type', 'unknown')), str(item.get('id', 'unknown'))
        if typ == 'commandExecution':
            key = (child, ident)
            prior = self.reviewer_item_state.get(key, {})
            command = item.get('command', prior.get('command'))
            cwd = item.get('cwd', prior.get('cwd'))
            status = item.get('status')
            self.reviewer_item_state[key] = {'command': command, 'status': status, 'cwd': cwd}
            script = self._rooted(self._shell_script(command), cwd)
            refusal = 'child-command:' + child + ':' + ident
            if status == 'inProgress':
                self.unresolved.add(refusal)
            # As for the parent: a read that ran and exited nonzero is ordinary; no exit code means no process.
            elif (script is None or self.reviewer_synchronous(script) is not True
                  or status not in ('completed', 'failed') or type(item.get('exitCode')) is not int):
                self.unresolved.add('child-command:' + child + ':' + ident)
            else:
                self.unresolved.discard(refusal)
        elif (typ == 'subAgentActivity' and item.get('kind') == 'interacted'
              and isinstance(item.get('id'), str) and item['id']
              and isinstance(parent_id, str) and parent_id
              and item.get('agentThreadId') == parent_id and item.get('agentPath') == '/root'):
            # Parent-directed interaction is not a verdict or another child admission.
            return
        elif typ in ('agentMessage', 'reasoning', 'plan', 'userMessage', 'contextCompaction'):
            return
        else:
            self.unresolved.add('child-tool:' + typ + ':' + child)

    def _observe_child(self, method, params):
        child = params.get('threadId')
        state = self.reviewer_children.get(child)
        if state is None:
            self.unresolved.add('foreign-lifecycle')
            return
        turn = params.get('turn') if isinstance(params.get('turn'), dict) else {}
        turn_id = params.get('turnId') or turn.get('id')
        if method == 'turn/started':
            if state['turn_id'] is not None or not isinstance(turn_id, str) or not turn_id:
                self.unresolved.add('invalid-child-turn:' + child)
            else:
                state['turn_id'] = turn_id
        elif turn_id != state['turn_id']:
            self.unresolved.add('foreign-child-turn:' + child)
        elif method == 'thread/tokenUsage/updated':
            usage = params.get('tokenUsage', {})
            last = usage.get('last', {}) if isinstance(usage, dict) else {}
            current, window = last.get('totalTokens'), usage.get('modelContextWindow', last.get('modelContextWindow'))
            if type(current) is not int or type(window) is not int or current < 0 or window <= 0:
                self.unresolved.add('unknown-child-telemetry:' + child)
            else:
                total = usage.get('total', {})
                total = total.get('totalTokens') if isinstance(total, dict) else None
                self.reviewer_telemetry[child] = {'current': current, 'window': window,
                                                  **({'total': total} if type(total) is int and total >= 0 else {})}
        elif method in ('item/started', 'item/completed'):
            self._observe_child_item(child, params.get('item', {}), self.thread_id)
        elif method == 'turn/completed':
            state['terminal'] = turn.get('status')

    def _reviewer_settled(self):
        # A completed child also needs its usage update; strict reconciliation requires both.
        return all(state['completed'] and state['terminal'] is not None
                   and (state['terminal'] != 'completed' or child in self.reviewer_telemetry)
                   for child, state in self.reviewer_children.items())

    def reconcile_reviewer(self, required=True):
        """Snapshot observed child evidence before the owned app-server is closed."""
        if not self.reviewer_reconciliation:
            return None
        if not required and not self.reviewer_children:
            return None
        if len(self.reviewer_children) != 1:
            raise QuiescenceError('no observed reviewer child')
        child, observed = next(iter(self.reviewer_children.items()))
        if not observed['completed'] or observed['terminal'] != 'completed' or child not in self.reviewer_telemetry:
            raise QuiescenceError('reviewer child did not reach observed terminal state')
        snapshot = self.reviewer_readback()
        verdict = self._review_verdict(snapshot, self.thread_id, self.turn_id, child, observed['turn_id'])
        self.reviewer_snapshot = {'reviewer_children': [child], 'turn_id': observed['turn_id'],
                                  'parent_thread_id': self.thread_id, 'parent_turn_id': self.turn_id,
                                  'telemetry': dict(self.reviewer_telemetry), 'verdict': verdict}
        self.reviewer_history.append(self.reviewer_snapshot)
        return self.reviewer_snapshot

    def read_review(self, expected):
        """Reconcile retained native evidence without creating a thread or turn."""
        self._check()
        children = expected.get('reviewer_children') if isinstance(expected, dict) else None
        if (not isinstance(children, list) or len(children) != 1
                or not all(isinstance(value, str) and value for value in
                    [*children, expected.get('parent_thread_id'), expected.get('parent_turn_id'),
                     expected.get('turn_id'), expected.get('verdict')])
                or children[0] == expected['parent_thread_id']):
            raise QuiescenceError('missing historical review identity')
        parent, child = expected['parent_thread_id'], children[0]
        records = {ident: self._request('thread/read', {'threadId': ident, 'includeTurns': True})['thread']
                   for ident in (parent, child)}
        verdict = self._review_verdict(records, parent, expected['parent_turn_id'], child, expected['turn_id'])
        if verdict != expected['verdict']:
            raise QuiescenceError('historical review verdict changed')
        return verdict

    def _review_verdict(self, snapshot, parent_id, parent_turn, child, child_turn):
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get(child), dict):
            raise QuiescenceError('reviewer readback missing observed child')
        parent = snapshot.get(parent_id)
        parent_turns = parent.get('turns') if isinstance(parent, dict) else None
        if not isinstance(parent_turns, list) or not any(turn.get('id') == parent_turn and turn.get('status') == 'completed'
                                                         for turn in parent_turns if isinstance(turn, dict)):
            raise QuiescenceError('reviewer readback parent terminal turn failed')
        record = snapshot[child]
        spawn = record.get('source', {}).get('subAgent', {}).get('thread_spawn', {}) if isinstance(record.get('source'), dict) else {}
        if (spawn.get('parent_thread_id') != parent_id or spawn.get('depth') != 1
                or spawn.get('agent_path') != self.reviewer_path):
            raise QuiescenceError('reviewer readback parent binding failed')
        turns = record.get('turns')
        if not isinstance(turns, list) or len(turns) != 1 or turns[0].get('id') != child_turn or turns[0].get('status') != 'completed':
            raise QuiescenceError('reviewer readback terminal turn failed')
        verdict = None
        for item in turns[0].get('items', []):
            self._observe_child_item(child, item, parent_id)
            if item.get('type') == 'agentMessage' and item.get('phase') == 'final_answer' and isinstance(item.get('text'), str) and item['text'].strip():
                verdict = item['text']
        if verdict is None:
            raise QuiescenceError('reviewer readback has no final verdict')
        if self.unresolved:
            raise QuiescenceError('unresolved native operations: ' + ', '.join(sorted(self.unresolved)))
        return verdict

    def _observe(self, msg):
        if msg.get('_reader_error'):
            raise NativeError(str(self.reader_error))
        if 'id' in msg and 'method' in msg:
            self._deny(msg)
        if self.checkpoint_request is not None and msg.get('id') == self.checkpoint_request:
            self.checkpoint_reply = msg
        method, params = msg.get('method'), msg.get('params', {})
        if not isinstance(params, dict):
            self.unresolved.add('malformed-lifecycle')
            return msg
        turn = params.get('turn')
        event_turn = params.get('turnId') or (turn.get('id') if isinstance(turn, dict) else None)
        lifecycle = ('thread/tokenUsage/updated', 'item/started', 'item/completed', 'turn/started', 'turn/completed')
        thread_id = params.get('threadId')
        matching = thread_id == self.thread_id and event_turn == self.turn_id
        child_lifecycle = self.reviewer_reconciliation and thread_id in self.reviewer_children
        if method in lifecycle and not matching:
            if child_lifecycle:
                self._observe_child(method, params)
            else:
                self.unresolved.add('foreign-lifecycle')
        if method == 'thread/tokenUsage/updated' and params.get('threadId') == self.thread_id and not matching:
            self.unresolved.add('stale-telemetry')
        if method == 'thread/tokenUsage/updated' and matching:
            usage = params.get('tokenUsage', {})
            last = usage.get('last', {}) if isinstance(usage, dict) else {}
            current = last.get('totalTokens')
            window = usage.get('modelContextWindow', last.get('modelContextWindow'))
            if type(current) is int and type(window) is int and current >= 0 and window > 0:
                total = usage.get('total', {})
                total = total.get('totalTokens') if isinstance(total, dict) else None
                self.latest_usage = {'current': current, 'window': window,
                                     **({'total': total} if type(total) is int and total >= 0 else {})}
                if self._turn_window is None:
                    self._turn_window = window
                elif self._turn_window != window:
                    self.unresolved.add('telemetry-window-changed')
                fraction = current / window
                self.peak_fraction = fraction if self.peak_fraction is None else max(self.peak_fraction, fraction)
                self.unresolved.discard('unknown-telemetry')
                self._record('usage', current=current, window=window)
                if (self.checkpoint_threshold is not None and self.checkpoint_request is None
                        and fraction >= self.checkpoint_threshold / 100
                        and not self.compacted and self._turn_window == window
                        and 'foreign-lifecycle' not in self.unresolved):
                    self._steer_checkpoint(
                        'Context checkpoint threshold reached. Finish only already-running operations. '
                        'Do not start another tool or work phase. Return the required complete semantic '
                        'checkpoint JSON now, preserving the exact next action and loaded_hash. '
                        'The controller will load it in a fresh session.',
                        current=current, window=window, threshold=self.checkpoint_threshold)
            else:
                self.latest_usage = None
                self.unresolved.add('unknown-telemetry')
        if method in ('item/started', 'item/completed') and params.get('threadId') == self.thread_id and not matching:
            self.unresolved.add('stale-item')
        if method in ('item/started', 'item/completed') and matching:
            self._observe_item(params.get('item', {}), started=method == 'item/started')
            if params.get('item', {}).get('type') == 'contextCompaction':
                # Native compaction time is not the model's notes window; restart it afterward.
                self.compacting = method == 'item/started'
                if self.compacting:
                    self.compaction_started = time.monotonic()
                if not self.compacting and self.checkpoint_request is not None:
                    self.checkpoint_deadline = time.monotonic() + 60
        if method and 'compact' in method.lower() and matching:
            self.compacted = True
        if (self.compacted and matching and self.checkpoint_threshold is not None
                and self.checkpoint_request is None):
            # Compaction is not a measured threshold; stop the phase for fallback notes only.
            self._steer_checkpoint(
                'Native context compaction occurred. Finish only already-running operations. '
                'Do not start another tool or work phase. Return the required complete semantic '
                'checkpoint JSON now, preserving the exact next action and loaded_hash. '
                'The controller will retain it as fallback evidence and stop for reconciliation.',
                reason='compaction')
        self._record('receive', method=str(method)[:120] if method else '', response='id' in msg)
        return msg

    def _steer_checkpoint(self, text, **data):
        # Do not nest _request here: its wait could consume turn/completed.
        self.checkpoint_request = self._send('turn/steer', {
            'threadId': self.thread_id, 'expectedTurnId': self.turn_id,
            'input': [{'type': 'text', 'text': text}]})
        self.checkpoint_deadline = time.monotonic() + 60
        self._record('checkpoint_requested', **data)

    def _raw(self, timeout):
        try:
            msg = self.messages.get(timeout=timeout)
        except queue.Empty:
            return None
        if msg.get('_reader_error') or msg.get('_reader_closed'):
            self.messages.put(msg)  # Every later wait fails the same way; the reader has exited.
        if msg.get('_reader_error'):
            raise NativeError(str(self.reader_error))
        if msg.get('_reader_closed'):
            raise NativeError('app-server exited: ' + str(self.proc.returncode) if self.proc.poll() is not None
                              else 'app-server output closed while the process runs')
        if 'id' in msg and 'method' in msg:
            self._deny(msg)
        return msg

    def _wait(self, predicate, timeout=60):
        end = time.monotonic() + timeout
        self._last_tick = float('-inf')  # Every wait checks first; only repeats within it are throttled.
        while True:
            self._tick()
            if self.proc is not None and self.proc.poll() is not None:
                raise NativeError('app-server exited: ' + str(self.proc.returncode))
            remain = end - time.monotonic()
            if remain <= 0:
                raise NativeError('app-server response deadline exceeded')
            msg = self._deferred.pop(0) if self._deferred else self._raw(min(self.POLL, remain))
            if msg is None:
                continue
            msg = self._observe(msg)
            if predicate(msg):
                return msg

    def _request(self, method, params, timeout=60):
        ident = self._send(method, params)
        result = self._wait(lambda msg: msg.get('id') == ident, timeout)
        if 'error' in result:
            raise NativeError(method + ' rejected: ' + str(result['error'])[:500])
        return result.get('result', {})

    def connect(self):
        """Open the owned transport only; historical readback admits no model work."""
        if self.proc is not None:
            raise NativeError('app-server already started')
        if self.permission_profile is not None:
            self._check()
        self.log_path = self._safe_log(self.log_path)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log_bytes = 0
        self._log = self.log_path.open('x', encoding='utf-8')
        pass_fds = () if self.lock_fd is None else (self.lock_fd,)
        self.proc = subprocess.Popen(self.command or self.COMMAND, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1, cwd=self.cwd,
                                     env=self.env, start_new_session=True, pass_fds=pass_fds)
        self._adopt(self.proc)
        self._request('initialize', {'clientInfo': {'name': 'launch', 'version': '1'},
                                     'capabilities': {'experimentalApi': True}})
        self._send('initialized', {}, request=False)

    def start(self):
        self.connect()
        params = {'cwd': self.cwd}
        if self.permission_profile is not None:
            params['permissions'] = self.permission_profile
        result = self._request('thread/start', params)
        if self.permission_profile is not None:
            active = result.get('activePermissionProfile')
            if not isinstance(active, dict) or active.get('id') != self.permission_profile:
                raise NativeError('native permission profile mismatch')
        thread = result.get('thread', {})
        if not isinstance(thread.get('id'), str) or not thread['id']:
            raise NativeError('thread/start returned no native thread ID')
        self.thread_id, self.model = thread['id'], result.get('model')
        if self.permission_profile is not None:
            cursor = None
            for _ in range(100):
                params = {'limit': 1, 'threadId': self.thread_id, 'detail': 'toolsAndAuthOnly'}
                if cursor is not None:
                    params['cursor'] = cursor
                page = self._request('mcpServerStatus/list', params)
                rows = page.get('data')
                if not isinstance(rows, list) or any(not isinstance(row, dict)
                        or not isinstance(row.get('tools'), dict) or row['tools'] for row in rows):
                    raise NativeError('native connected tools are not empty')
                cursor = page.get('nextCursor')
                if cursor is None:
                    break
                if not isinstance(cursor, str) or not cursor:
                    raise NativeError('invalid native tool inventory cursor')
            else:
                raise NativeError('native tool inventory pagination incomplete')
        self._record('thread_started', model=str(self.model)[:120])
        # Keep only controller-relevant server metadata. In particular, never persist
        # its unconstrained config object, environment, or any request contents.
        return {'thread_id': self.thread_id, 'pid': self.pid, 'model': self.model,
                'model_provider': result.get('modelProvider'), 'cwd': result.get('cwd'),
                'approval_policy': result.get('approvalPolicy'),
                'approvals_reviewer': result.get('approvalsReviewer'),
                'sandbox': result.get('sandbox'),
                'reasoning_effort': result.get('reasoningEffort'),
                'service_tier': result.get('serviceTier'),
                'cli_version': self.env.get('CODEX_VERSION'),
                **({'permission_profile': self.permission_profile} if self.permission_profile is not None else {})}

    def turn(self, prompt, output_schema):
        if not self.thread_id:
            raise NativeError('start before turn')
        if not isinstance(prompt, str) or not prompt or not isinstance(output_schema, dict):
            raise NativeError('prompt and output schema required')
        if self.checkpoint_threshold is not None and (type(self.checkpoint_threshold) is not int
                                                      or not 60 <= self.checkpoint_threshold <= 70):
            raise NativeError('checkpoint threshold must be 60..70 percent')
        self.checkpoint_request = self.checkpoint_reply = self.checkpoint_deadline = None
        if self.permission_profile is not None:
            self._check()
        # A previous turn's value is stale. The next ordinary dispatch needs a new
        # matching observation, and the controller fails closed if it never arrives.
        self.latest_usage = None
        self.peak_fraction = None
        self._turn_window = None
        self.compacted = False
        self.compacting = False
        self.items = {}
        self.reviewer_children = {}
        self.reviewer_telemetry = {}
        self.reviewer_snapshot = None
        self.reviewer_activity_ids = {}
        self.reviewer_item_state = {}
        self.unresolved.add('unknown-telemetry')
        self.turn_id = None
        request = self._send('turn/start', {'threadId': self.thread_id,
                                            'input': [{'type': 'text', 'text': prompt}],
                                            'outputSchema': output_schema})
        early, result = [], None
        end = time.monotonic() + 60
        self._last_tick = float('-inf')
        while result is None:
            self._tick()
            if self.proc.poll() is not None:
                raise NativeError('app-server exited: ' + str(self.proc.returncode))
            remain = end - time.monotonic()
            if remain <= 0:
                raise NativeError('turn/start response deadline exceeded')
            msg = self._raw(min(self.POLL, remain))
            if msg is None:
                continue
            if msg.get('id') == request:
                if 'error' in msg:
                    raise NativeError('turn/start rejected: ' + str(msg['error'])[:500])
                result = msg.get('result', {})
            else:
                if len(early) >= self.messages.maxsize:
                    raise NativeError('turn lifecycle buffer overflow')
                early.append(msg)
        turn = result.get('turn', {})
        if not isinstance(turn.get('id'), str) or not turn['id']:
            raise NativeError('turn/start returned no turn ID')
        self.turn_id = turn['id']
        if self.on_turn_started is not None:
            self.on_turn_started(self.turn_id)
        self._deferred.extend(early)
        completed = None
        def checkpoint_boundary(msg):
            nonlocal completed
            if (msg.get('method') == 'turn/completed'
                    and msg.get('params', {}).get('threadId') == self.thread_id
                    and msg.get('params', {}).get('turn', {}).get('id') == self.turn_id):
                completed = msg
            reply = self.checkpoint_reply
            if reply is not None:
                if 'error' in reply:
                    if completed is None:
                        raise NativeError('active checkpoint steering rejected')
                    # A naturally completed phase is already a checkpoint boundary.
                elif reply.get('result', {}).get('turnId') != self.turn_id:
                    raise NativeError('checkpoint steering turn mismatch')
            return completed is not None and (self.checkpoint_request is None or reply is not None)
        self._wait(checkpoint_boundary, timeout=self.timeout)
        self.checkpoint_deadline = None
        final = completed['params']['turn']
        for item in final.get('items', []):
            self._observe_item(item)
        if final.get('status') != 'completed':
            self.unresolved.add('turn:' + self.turn_id)
            raise NativeError('turn did not complete: ' + str(final.get('status')))
        texts = [item.get('text') for item in final.get('items', [])
                 if item.get('type') == 'agentMessage' and isinstance(item.get('text'), str)]
        if not texts:
            raise NativeError('completed turn has no final agent message')
        try:
            payload = json.loads(texts[-1])
        except json.JSONDecodeError as exc:
            raise NativeError('final agent message is not schema JSON') from exc
        if not isinstance(payload, dict):
            raise NativeError('final schema payload must be an object')
        if 'foreign-lifecycle' in self.unresolved:
            raise NativeError('foreign native lifecycle event observed')
        if self.reviewer_reconciliation and self.reviewer_children and not self._reviewer_settled():
            # WORK27: the parent turn can complete before its reviewer child. Drain the observed
            # child lifecycle under the existing turn timeout; reconciliation below stays strict.
            try:
                self._wait(lambda msg: self._reviewer_settled(), timeout=self.timeout)
            except NativeError as exc:
                if str(exc) != 'app-server response deadline exceeded':
                    raise
                raise QuiescenceError('reviewer child did not settle before the turn timeout') from exc
        reviewer = self.reconcile_reviewer(required=self.reviewer_required) if self.reviewer_reconciliation else None
        self._record('turn_completed', unresolved=len(self.unresolved))
        allowed = {'userMessage', 'agentMessage', 'reasoning', 'plan', 'contextCompaction'}
        tool_item_count = sum(1 for item in self.items.values() if item['type'] not in allowed)
        return {'payload': payload, 'turn_id': self.turn_id, 'usage': self.latest_usage,
                'peak_fraction': self.peak_fraction,
                'compacted': self.compacted, 'tool_item_count': tool_item_count,
                'unresolved_operations': sorted(self.unresolved), 'reviewer': reviewer}
