#!/usr/bin/env python3
"""Fail-closed persistent Claude stream-json adapter for Launch."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shlex
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('launch_process', Path(__file__).with_name('launch-process.py'))
_process = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_process)
OwnedProcess = _process.OwnedProcess


class ClaudeError(RuntimeError):
    pass


class CalibrationError(ClaudeError):
    pass


class QuiescenceError(ClaudeError):
    pass


def protected_write(path, protected):
    """LC-039: inside the git dirs only the canonical acceptance file is writable; the gitfile never is."""
    if not isinstance(path, str) or not path:
        return True
    worktree = os.path.realpath(protected['worktree'])
    full = os.path.realpath(os.path.join(worktree, path)).casefold()  # APFS is case-insensitive.
    git_dir, common, worktree = (os.path.realpath(protected[k]).casefold() for k in ('git_dir', 'common_dir', 'worktree'))
    inside = lambda root: full == root or full.startswith(root.rstrip(os.sep) + os.sep)
    if full == os.path.join(git_dir, 'acceptance.json'):
        return False  # A linked worktree's git dir is itself inside the common dir.
    # The gate's own wrappers, settings (disableAllHooks) and installed copies would let a worker turn it off.
    gate = [os.path.join(worktree, p) for p in ('.claude/hooks', '.claude/launch', '.claude/settings.json',
                                                 '.claude/settings.local.json', 'scripts/verify.sh')]
    if protected.get('config_dir'):
        gate.append(os.path.realpath(protected['config_dir']).casefold())
    return (inside(git_dir) or (inside(common) and not inside(worktree)) or full == os.path.join(worktree, '.git')
            or any(inside(path) for path in gate))


WORKER_TOOLS = ('Read', 'Edit', 'Write', 'Glob', 'Grep', 'Bash')
TOKEN_FIELDS = ('inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens')


def tool_refusal(name, inp, synchronous, protected=None, allowed=WORKER_TOOLS):
    """One allowlist for after-the-fact stream review and the before-execution PreToolUse gate."""
    command = inp.get('command', '') if isinstance(inp, dict) else ''
    if name in ('Agent', 'Task') or not isinstance(name, str) or name.lower().startswith('mcp') or name not in allowed:
        return 'unsupported-tool'
    if name in ('Write', 'Edit') and protected and protected_write(inp.get('file_path') if isinstance(inp, dict) else None, protected):
        return 'protected-path'
    if name != 'Bash':
        return None
    try:
        if (not isinstance(command, str) or (isinstance(inp, dict) and inp.get('run_in_background') is True) or
                any(token == '&' for token in shlex.shlex(command, posix=True, punctuation_chars=True)) or
                any(x in command for x in ('nohup', 'disown', 'setsid', 'launchctl', 'tmux ', 'screen '))):
            return 'background-tool'
    except ValueError:
        return 'unclassified-shell'
    try: supported = synchronous(command) is True
    except Exception: supported = False
    return None if supported else 'unclassified-shell'


STREAM = ('claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose')


class Claude(OwnedProcess):
    # Pinned so the operator's own defaultMode never decides. Only bypass may write the protected git dir's
    # acceptance.json (dontAsk denies it even on a hook allow); the all-tool PreToolUse gate stays the boundary.
    # No MCP servers: one that finishes connecting mid-run changes the init digest (D1 attempt 1, 2026-10-20).
    # No user settings: they carry the operator's hooks and plugins, and a plugin's MCP server gets past
    # --strict-mcp-config. The gate lives in project settings, so project and local still load (LC-039).
    COMMAND = STREAM + ('--permission-mode', 'bypassPermissions', '--strict-mcp-config', '--setting-sources', 'project,local')
    TOOLS = WORKER_TOOLS
    SEMANTIC = ('goal', 'scope', 'completed', 'next_phase', 'next_action', 'questions', 'evidence', 'unsafe_state', 'reversal')
    STRUCTURED_SCHEMA = {'type': 'object', 'properties': {'loaded_hash': {'type': 'string'},
        **{key: {'type': 'string', 'minLength': 1} for key in SEMANTIC}},
        'required': ['loaded_hash'], 'additionalProperties': False}
    Error = ClaudeError
    CLI_DENIAL_RESOLVES = False  # The worker's own gate is the policy; a CLI denial past it still blocks.
    Quiescence = QuiescenceError
    WORKER = 'Claude'
    READER_EOF_EVENT = False

    def __init__(self, cwd, env, lock_fd, check, log_path, session=None, timeout=None, synchronous=None, protected=None):
        self.cwd, self.env, self.lock_fd, self.check = str(Path(cwd).resolve()), dict(env), lock_fd, check
        self._own(log_path)
        self.session = session or self.env.get('LAUNCH_SESSION_ID')
        if not isinstance(self.session, str) or not self.session:
            raise ClaudeError('explicit Claude session ID required')
        if synchronous is not None and not callable(synchronous):
            raise ClaudeError('synchronous shell classifier must be callable')
        self.synchronous = synchronous or (lambda command: False)
        self.protected = protected
        self.model = None
        self.version = None
        self.window = None
        self.calibrated = False
        self.turn_index = 0
        self.tools = {}
        self.formatters = {}
        self.consumed_results = set()
        self.consumed_assistants = set()
        self.consumed_tools = set()
        self.current_assistants = set()
        self.tool_item_count = 0
        self.compacted = False
        self.init_digest = None
        self.init_model = None
        self.timeout = float(timeout if timeout is not None else self.env.get('LAUNCH_NATIVE_TIMEOUT', 60))
        if not 0 < self.timeout <= 3600: raise ClaudeError('invalid native turn timeout')
        self.on_turn_started = None
        self.on_result = None
        self.checkpoint_threshold = None
        self.checkpoint_requested = False
        self.checkpoint_deadline = None
        self.on_checkpoint = None
        self.checkpoint_denial = None
        self.tool_requests = {}
        self.refused = {}  # tool_use_id -> refusal; resolved only once proven denied before it ran.
        self.errored = set()  # Admitted tools whose result was an error.
        self.total = 0  # Cumulative session tokens from the last result's modelUsage.
        self.model_totals = {}  # Per model: modelUsage is cumulative per session (probe, 2026-10-20).
        self.turn_usage = {}  # message.id -> largest usage seen this turn; a lower bound until the result.
        self.latest_usage = None

    def _check(self):
        if self.checkpoint_deadline is not None and time.monotonic() >= self.checkpoint_deadline:
            raise ClaudeError('active context checkpoint deadline exceeded')
        if self.check is not None and self.check() is False:
            raise ClaudeError('external controller stopped native worker')

    def _next(self, timeout):
        try: msg = self.messages.get(timeout=timeout)
        except queue.Empty: return None
        if msg.get('_reader_error'):
            raise ClaudeError(str(self.reader_error))
        return msg

    def _count_usage(self, message, ident):
        # Counted mid-turn so a turn that never reaches its result still spends its tokens.
        usage = message.get('usage') if isinstance(message.get('usage'), dict) else {}
        size = sum(usage[k] for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens')
                   if type(usage.get(k)) is int and usage[k] >= 0)
        key = message.get('id') if isinstance(message.get('id'), str) else ident
        self.turn_usage[key] = max(self.turn_usage.get(key, 0), size)
        self.latest_usage = {**(self.latest_usage or {}), 'total': self.total + sum(self.turn_usage.values())}

    def _drain_usage(self):
        # LC-043: a stop is polled between reads, so it can land after Claude wrote an assistant message
        # and before this side read it. Once the process is gone, charge what it wrote; judge nothing else.
        # Drain while the reader finishes so a full queue never makes it drop a line.
        end, reader_done, turn_over = time.monotonic() + self.POLL, False, False
        while True:
            try: event = self.messages.get_nowait()
            except queue.Empty:
                if reader_done or self._reader_thread is None or time.monotonic() >= end: return
                self._reader_thread.join(timeout=0.05)
                reader_done = not self._reader_thread.is_alive()  # One more pass picks up its last put.
                continue
            turn_over = turn_over or event.get('type') == 'result'  # Past a result, nothing belongs to the turn that was stopped.
            message, ident = event.get('message'), event.get('uuid')
            if (not turn_over and event.get('type') == 'assistant' and not event.get('parent_tool_use_id')
                    and event.get('session_id') == self.session
                    and isinstance(message, dict) and isinstance(ident, str) and ident and ident not in self.consumed_assistants):
                self._count_usage(message, ident)

    _before_reap = _drain_usage  # close() charges what a stopped process wrote, before judging quiescence.

    def _send(self, prompt):
        encoded = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': prompt}}, separators=(',', ':'))
        if len(encoded) > self.MAX_LINE:
            raise ClaudeError('Claude input exceeds limit')
        self.proc.stdin.write(encoded + '\n')
        self.proc.stdin.flush()

    def start(self):
        if self.proc is not None:
            raise ClaudeError('Claude already started')
        self.log_path = self._safe_log(self.log_path)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = self.log_path.open('x', encoding='utf-8')
        fds = () if self.lock_fd is None else (self.lock_fd,)
        schema = json.dumps(self.STRUCTURED_SCHEMA, sort_keys=True, separators=(',', ':'))
        self.proc = subprocess.Popen([*self.COMMAND, '--session-id', self.session, '--json-schema', schema], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, cwd=self.cwd,
            env=self.env, start_new_session=True, pass_fds=fds)
        self._adopt(self.proc)
        return {'session': self.session, 'pid': self.pid,
                'settings_digest': self.env.get('LAUNCH_SETTINGS_DIGEST'),
                'cli_version': self.env.get('CLAUDE_VERSION')}

    def _tool(self, block):
        ident, name = block.get('id'), block.get('name')
        if not isinstance(ident, str) or not isinstance(name, str): self.unresolved.add('malformed-tool'); return
        if ident in self.consumed_tools or ident in self.tools or ident in self.formatters:
            self.unresolved.add('replayed-tool:' + ident); return
        if name == 'StructuredOutput':
            inp = block.get('input')
            if ident in self.formatters or not isinstance(inp, dict): self.unresolved.add('invalid-formatter:' + ident)
            else: self.formatters[ident] = {'input': inp, 'state': 'requested'}
            return
        self.tool_item_count += 1
        inp = block.get('input', {})
        self.tool_requests[ident] = {'tool_use_id': ident, 'tool_name': name, 'tool_input': inp}
        refusal = tool_refusal(name, inp, self.synchronous, self.protected, self.TOOLS)
        if refusal: self.refused[ident], self.tools[ident] = refusal, 'refused'
        else: self.tools[ident] = 'requested'

    def _tool_result(self, block, event):
        ident = block.get('tool_use_id') or block.get('id')
        if ident in self.formatters:
            if self.formatters[ident]['state'] != 'requested' or block.get('content') != 'Structured output provided successfully':
                self.unresolved.add('invalid-formatter-result:' + str(ident))
            else: self.formatters[ident]['state'] = 'completed'
        elif isinstance(ident, str) and self.tools.get(ident) == 'refused':
            # An error result alone is not proof: a refused tool that produced output ran.
            if block.get('is_error') is True: self.tools[ident] = 'refused-error'
            else: self.unresolved.add(self.refused[ident] + ':' + ident)
        elif block.get('run_in_background') is True or block.get('is_background') is True or event.get('run_in_background') is True or event.get('is_background') is True:
            self.unresolved.add('background-tool-result')
        elif not isinstance(ident, str) or self.tools.get(ident) != 'requested':
            self.unresolved.add('unknown-tool-result')
        else:
            self.tools[ident] = 'completed'
            if block.get('is_error') is True: self.errored.add(ident)

    def _blocks(self, event):
        message = event.get('message', {})
        content = message.get('content', []) if isinstance(message, dict) else []
        if not isinstance(content, list): self.unresolved.add('malformed-content'); return
        for block in content:
            if not isinstance(block, dict): self.unresolved.add('malformed-content'); continue
            if block.get('type') == 'tool_use': self._tool(block)
            elif block.get('type') == 'tool_result': self._tool_result(block, event)

    @staticmethod
    def _identities(value):
        if not isinstance(value, list): return []
        result = []
        for item in value:
            if isinstance(item, str): result.append(item)
            elif isinstance(item, dict):
                result.append({key: item[key] for key in ('name', 'version', 'source') if isinstance(item.get(key), str)})
        return result

    def _init(self, event):
        fields = {key: event.get(key) for key in ('model', 'permissionMode', 'tools', 'agents', 'output_style', 'claude_code_version')
                  if isinstance(event.get(key), (str, int, float, bool, list, dict))}
        fields['skills'] = self._identities(event.get('skills'))
        fields['plugins'] = self._identities(event.get('plugins'))
        encoded = json.dumps(fields, sort_keys=True, separators=(',', ':')).encode()
        digest = hashlib.sha256(encoded).hexdigest()
        if self.init_digest is None:
            self.init_digest, self.init_model = digest, fields.get('model')
            self._record('init', digest=digest, model=self.init_model)
        elif self.init_digest != digest:
            self.unresolved.add('init-settings-changed')

    def _validate_event(self, event, assistants):
        typ = event.get('type')
        message = event.get('message', {})
        content = message.get('content', []) if isinstance(message, dict) else []
        tool_result = isinstance(content, list) and any(isinstance(block, dict) and block.get('type') == 'tool_result' for block in content)
        bound = typ in ('assistant', 'result') or (typ == 'user' and tool_result) or (typ == 'system' and event.get('subtype') == 'init')
        if (bound and event.get('session_id') != self.session) or (not bound and event.get('session_id') not in (None, self.session)):
            self.unresolved.add('foreign-session')
            return
        self._blocks(event)
        if typ == 'system':
            if event.get('subtype') == 'init': self._init(event)
            if 'compact' in str(event.get('subtype', '')).lower(): self.compacted = True
        if typ == 'assistant':
            if event.get('parent_tool_use_id'):
                self.unresolved.add('subagent')
                return
            message = event.get('message')
            if not isinstance(message, dict) or not isinstance(message.get('model'), str):
                self.unresolved.add('malformed-assistant')
                return
            ident = event.get('uuid')
            if not isinstance(ident, str) or not ident:
                self.unresolved.add('missing-assistant-id')
                return
            if ident in self.consumed_assistants or ident in self.current_assistants:
                self.unresolved.add('replayed-assistant:' + ident)
                return
            self.current_assistants.add(ident)
            self._count_usage(message, ident)
            if self.model is not None and message['model'] != self.model:
                self.unresolved.add('model-changed')
            assistants.append(event)
            if self.checkpoint_threshold is not None:
                usage = self._usage(event)
                if usage is None or not self.calibrated or self.window is None:
                    raise CalibrationError('missing active Claude context telemetry')
                if (not self.checkpoint_requested and not self.unresolved
                        and usage / self.window >= self.checkpoint_threshold / 100):
                    if not callable(self.on_checkpoint):
                        raise ClaudeError('active checkpoint hook unavailable')
                    self.on_checkpoint()
                    self.checkpoint_requested = True
                    self.checkpoint_deadline = time.monotonic() + 60
                    self._record('checkpoint_requested', current=usage, window=self.window,
                                 threshold=self.checkpoint_threshold)
        elif typ in ('tool', 'tool_use', 'tool_result'):
            self.unresolved.add('unsupported-tool-lifecycle')

    @staticmethod
    def _usage(event):
        usage = event.get('message', {}).get('usage', {})
        fields = ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')
        if not isinstance(usage, dict) or any(type(usage.get(k)) is not int or usage[k] < 0 for k in fields):
            return None
        return sum(usage.get(k, 0) for k in fields)

    def _wait_result(self, timeout=None):
        timeout = self.timeout if timeout is None else timeout
        end, assistants = time.monotonic() + timeout, []
        while True:
            self._check()
            self._tick()
            if self.proc.poll() is not None:
                raise ClaudeError('Claude exited: ' + str(self.proc.returncode))
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise ClaudeError('Claude response deadline exceeded')
            event = self._next(min(self.POLL, remaining))
            if event is None: continue
            self._validate_event(event, assistants)
            if event.get('type') == 'result':
                if event.get('session_id') != self.session:
                    self.unresolved.add('foreign-session')
                return event, assistants

    @staticmethod
    def _model_usage(result, model):
        entries = result.get('modelUsage')
        if not isinstance(entries, dict): return None
        candidates = []
        if isinstance(entries.get(model), dict): candidates.append(entries[model])
        candidates += [v for v in entries.values() if isinstance(v, dict) and v.get('canonicalModel') == model and v not in candidates]
        return candidates[0] if len(candidates) == 1 else None

    @staticmethod
    def _model_totals(result):
        entries = result.get('modelUsage')
        if not isinstance(entries, dict) or not entries or any(
                not isinstance(v, dict) or any(type(v.get(k)) is not int or v[k] < 0 for k in TOKEN_FIELDS) for v in entries.values()):
            return None
        return {model: sum(v[k] for k in TOKEN_FIELDS) for model, v in entries.items()}

    def _fixed_payload(self, payload):
        if not isinstance(payload, dict) or set(payload) - set(self.STRUCTURED_SCHEMA['properties']): return False
        if not isinstance(payload.get('loaded_hash'), str): return False
        return all(key not in payload or (isinstance(payload[key], str) and payload[key].strip()) for key in self.SEMANTIC)

    def _finish(self, result, assistants, required=(), properties=None):
        if result.get('subtype') != 'success' or result.get('is_error') is True:
            raise ClaudeError('Claude result was not successful')
        if 'foreign-session' in self.unresolved:
            raise ClaudeError('foreign Claude session event observed')
        if not assistants:
            raise ClaudeError('missing main assistant telemetry')
        if any(self._usage(item) is None for item in assistants):
            raise CalibrationError('malformed main assistant telemetry')
        last = assistants[-1]
        model = last['message']['model']
        if any(item['message'].get('model') != model for item in assistants):
            self.unresolved.add('model-changed')
        usage = self._usage(last)
        model_usage = self._model_usage(result, model)
        window = model_usage.get('contextWindow') if isinstance(model_usage, dict) else None
        if usage is None or type(window) is not int or window <= 0:
            raise CalibrationError('missing matching Claude context window')
        if self.model is None:
            self.model, self.window = model, window
        elif model != self.model or window != self.window:
            self.unresolved.add('model-or-window-changed')
        if self.init_model is not None and self.init_model != self.model:
            self.unresolved.add('init-model-changed')
        totals = self._model_totals(result)
        if totals is None or any(n < self.model_totals.get(model, 0) for model, n in totals.items()):
            raise CalibrationError('missing or regressing cumulative Claude token usage')
        totals = {**self.model_totals, **totals}  # A side model absent from a later result keeps what it spent.
        total = sum(totals.values())
        self.latest_usage = {**(self.latest_usage or {}), 'total': total}  # Spent even if the payload is refused below.
        if isinstance(result.get('permission_denials'), list) and result['permission_denials']:
            for denial in result['permission_denials']:
                # LC-063: the CLI streams the subagent tool as "Agent" and names it "Task" in its denial.
                if isinstance(denial, dict) and denial.get('tool_name') in ('Agent', 'Task'):
                    denial = {**denial, 'tool_name': 'Agent'}
                observed = self.tool_requests.get(denial.get('tool_use_id')) if isinstance(denial, dict) else None
                if observed and observed['tool_name'] == 'Task':
                    observed = {**observed, 'tool_name': 'Agent'}
                if (observed and self.tools.get(observed['tool_use_id']) == 'refused-error'
                        and all(denial.get(k) == v for k, v in observed.items())):
                    # The PreToolUse gate (same tool_refusal) denied it before execution and the worker moved on.
                    self.tools[observed['tool_use_id']] = 'completed'
                    continue
                if (self.CLI_DENIAL_RESOLVES and observed and observed['tool_use_id'] in self.errored
                        and all(denial.get(k) == v for k, v in observed.items())):
                    continue  # LC-064: the CLI itself refused a read-only call before it ran.
                if (not self.checkpoint_requested or not observed
                        or any(denial.get(k) != v for k, v in observed.items())
                        or not callable(self.checkpoint_denial) or not self.checkpoint_denial(observed)):
                    self.unresolved.add('tool-denied')
        stats = result.get('subagent_stats')
        if isinstance(stats, dict) and any(stats.get(key, 0) for key in ('spawned', 'completed', 'failed')):
            self.unresolved.add('subagent')
        self.unresolved.update(self.refused[i] + ':' + i for i, state in self.tools.items() if state in ('refused', 'refused-error'))
        if any(state != 'completed' for state in self.tools.values()): self.unresolved.add('unresolved-tool')
        if not isinstance(result.get('uuid'), str) or not result['uuid']:
            raise ClaudeError('Claude result has no native UUID')
        if result['uuid'] in self.consumed_results:
            raise ClaudeError('replayed Claude result UUID')
        payload = result.get('structured_output')
        if not self._fixed_payload(payload):
            raise ClaudeError('missing or invalid native structured output')
        if len(self.formatters) != 1:
            raise ClaudeError('native structured formatter count invalid')
        formatter = next(iter(self.formatters.values()))
        if any(name.startswith('invalid-formatter') for name in self.unresolved) or formatter['state'] != 'completed' or formatter['input'] != payload:
            raise ClaudeError('native structured formatter does not match result')
        if any(name.startswith(('replayed-assistant:', 'replayed-tool:')) for name in self.unresolved):
            raise ClaudeError('replayed Claude native identity')
        properties = properties or {}
        valid = True
        for key in required:
            rule = properties.get(key, {}) if isinstance(properties, dict) else {}
            minimum = rule.get('minLength', 0) if isinstance(rule, dict) else 0
            valid = valid and isinstance(payload.get(key), str) and type(minimum) is int and minimum >= 0 and len(payload[key]) >= minimum
        if not valid:
            raise ClaudeError('final semantic payload is incomplete')
        peak = max((self._usage(item) or 0) / window for item in assistants)
        if self.init_digest is None:
            raise CalibrationError('missing Claude effective init metadata')
        out = {'payload': payload, 'event_id': result['uuid'], 'turn_id': result['uuid'], 'session': self.session,
               'usage': {'current': usage, 'window': window, 'total': total}, 'peak_fraction': peak,
               'compacted': self.compacted, 'tool_item_count': self.tool_item_count,
               'unresolved_operations': sorted(self.unresolved),
               'binding': {'model': self.model, 'window': self.window,
                           'effective_init_digest': self.init_digest,
                           'cli_version': self.env.get('CLAUDE_VERSION')}}
        self._record('completed', uuid=result['uuid'], current=usage, window=window,
                     peak=peak, compacted=self.compacted, tool_count=self.tool_item_count,
                     unresolved=sorted(self.unresolved), payload_keys=sorted(payload))
        if self.on_result is not None: self.on_result(out['event_id'])
        self.consumed_results.add(result['uuid'])
        self.consumed_assistants.update(self.current_assistants)
        self.consumed_tools.update(self.tools)
        self.consumed_tools.update(self.formatters)
        self.tools, self.formatters, self.tool_item_count = {}, {}, 0
        self.checkpoint_deadline = None
        self.total, self.model_totals, self.turn_usage, self.latest_usage = total, totals, {}, out['usage']
        return out

    def calibrate(self, prompt, expected_hash=''):
        if self.proc is None or self.calibrated:
            raise CalibrationError('calibration must be first and only once')
        if not isinstance(expected_hash, str): raise CalibrationError('calibration hash must be a string')
        self.turn_index += 1; self.tools = {}; self.formatters = {}; self.current_assistants = set(); self.tool_item_count = 0; self.compacted = False
        if self.on_turn_started is not None: self.on_turn_started(self.turn_index)
        self._send(prompt)
        result, assistants = self._wait_result()
        out = self._finish(result, assistants)
        if out['payload'] != {'loaded_hash': expected_hash} or out['tool_item_count'] or out['unresolved_operations']:
            raise CalibrationError('calibration observed unsupported work')
        self.calibrated = True
        return out

    def turn(self, prompt, output_schema):
        if not self.calibrated:
            raise CalibrationError('ordinary Claude work requires calibration')
        if not isinstance(prompt, str) or not prompt or not isinstance(output_schema, dict):
            raise ClaudeError('prompt and output schema required')
        if self.checkpoint_threshold is not None and (type(self.checkpoint_threshold) is not int
                                                      or not 60 <= self.checkpoint_threshold <= 70):
            raise ClaudeError('checkpoint threshold must be 60..70 percent')
        self.checkpoint_requested = False
        self.checkpoint_deadline = None
        self.tool_requests = {}
        required = output_schema.get('required', [])
        if not isinstance(required, list) or not all(isinstance(key, str) for key in required):
            raise ClaudeError('output schema required fields invalid')
        self.turn_index += 1; self.tools = {}; self.formatters = {}; self.current_assistants = set(); self.tool_item_count = 0; self.compacted = False
        if self.on_turn_started is not None: self.on_turn_started(self.turn_index)
        schema = json.dumps(output_schema, sort_keys=True, separators=(',', ':'))
        self._send(prompt + '\nReturn exactly one JSON object satisfying this schema:\n' + schema)
        return self._finish(*self._wait_result(), required=required, properties=output_schema.get('properties'))


class Reviewer(Claude):
    """LC-039 slice 3: one read-only review turn in a fresh session with no hooks, project config, MCP or Bash."""
    COMMAND = STREAM + ('--safe-mode', '--restricted', '--tools', 'Read,Glob,Grep', '--strict-mcp-config',
                                '--disable-slash-commands', '--no-session-persistence')
    TOOLS = ('Read', 'Glob', 'Grep')
    CLI_DENIAL_RESOLVES = True  # Every admitted tool is read-only, so a denied call did nothing.
    STRUCTURED_SCHEMA = {'type': 'object', 'additionalProperties': False, 'required': ['verdict', 'revision', 'findings'],
                         'properties': {'verdict': {'enum': ['ship', 'revise']},
                                        'revision': {'type': 'string', 'pattern': '^[0-9a-f]{40}$'},
                                        'findings': {'type': 'array', 'items': {'type': 'string'}}}}

    def _init(self, event):
        super()._init(event)
        tools, plugins = event.get('tools'), event.get('plugins')
        # The flags are only trusted as far as the CLI reports their effect (probe, 2026-10-20).
        if not (isinstance(tools, list) and set(tools) <= set(self.TOOLS) | {'StructuredOutput'}
                and all(event.get(key) == [] for key in ('skills', 'mcp_servers', 'slash_commands'))
                and isinstance(plugins, list)
                and all(isinstance(p, dict) and isinstance(p.get('source'), str) and p['source'].endswith('@builtin') for p in plugins)):
            self.unresolved.add('reviewer-isolation')

    def _fixed_payload(self, payload):
        return (isinstance(payload, dict) and set(payload) == {'verdict', 'revision', 'findings'}
                and payload['verdict'] in ('ship', 'revise')
                and isinstance(payload['revision'], str) and re.fullmatch('[0-9a-f]{40}', payload['revision']) is not None
                and isinstance(payload['findings'], list) and all(isinstance(f, str) for f in payload['findings']))

    def review(self, prompt):
        if self.proc is None or self.turn_index:
            raise ClaudeError('independent review must be the only turn of a started session')
        if not isinstance(prompt, str) or not prompt:
            raise ClaudeError('review prompt required')
        self.turn_index = 1
        self._send(prompt)
        out = self._finish(*self._wait_result())
        if out['unresolved_operations'] or out['compacted']:
            raise ClaudeError('independent review observed unsupported work: ' + ', '.join(out['unresolved_operations'] or ['compaction']))
        return out
