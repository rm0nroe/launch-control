#!/usr/bin/env python3
"""No-network deterministic checks for persistent Claude stream handling."""
import importlib.util, json, os, queue, signal, subprocess, sys, tempfile, time
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-claude.py'
spec = importlib.util.spec_from_file_location('launch_claude', SCRIPT)
claude = importlib.util.module_from_spec(spec); spec.loader.exec_module(claude)

class Stream:
    def __init__(self): self.q = queue.Queue()
    def readline(self, size=-1):
        value = self.q.get(); return '' if value is None else value

class In:
    def __init__(self, owner): self.owner = owner
    def write(self, text):
        self.owner.calls += 1
        prompt = json.loads(text)['message']['content']
        model = 'fake-model' if not self.owner.drift else 'other-model'
        init = {'type':'system','session_id':'s1','subtype':'init','model':'fake-model',
            'permissionMode':'default','tools':['Read','Edit'],'agents':[],'output_style':'default',
            'claude_code_version':'test','skills':[{'name':'launch','version':'1'}],
            'plugins':[{'name':'test','version':'1','source':'fixture'}]}
        if self.owner.reviewer:
            init.update(tools=self.owner.init_tools, skills=[], mcp_servers=[], slash_commands=[],
                        plugins=[{'name':'cc-plugin-telemetry','path':'builtin','source':'cc-plugin-telemetry@builtin'}])
        self.owner.emit(init)
        loaded = '' if self.owner.empty_loaded else ''
        payload = {'loaded_hash': loaded}
        if self.owner.calls > 1: payload['goal'] = '' if self.owner.malformed_fields else 'ok'
        if self.owner.reviewer: payload = self.owner.payload
        turn = 1 if self.owner.replay else self.owner.calls
        formatter = {'type': 'tool_use', 'id': 'format-'+str(turn), 'name': 'StructuredOutput', 'input': ({'loaded_hash':'wrong'} if self.owner.mismatch_formatter else payload)}
        content = [{'type': 'text', 'text': 'prose is ignored'}, formatter]
        if self.owner.duplicate_formatter: content.append({'type':'tool_use','id':'format-'+str(turn),'name':'StructuredOutput','input':payload})
        if self.owner.sync: content.append({'type': 'tool_use', 'id': 'tool', 'name': 'Edit', 'input': {}})
        if self.owner.background: content.append({'type': 'tool_use', 'id': 'tool', 'name': 'Bash', 'input': {'command':'sleep 5 &'}})
        if self.owner.extra_tool: content.append({'type': 'tool_use', 'id': 'tool', 'name': self.owner.extra_tool, 'input': {'file_path':'x', 'command':'true'}})
        usage = {'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':30,'output_tokens':5}
        if self.owner.malformed: usage.pop('cache_read_input_tokens')
        assistant = {'type':'assistant','session_id':'s1','uuid':'a-'+str(turn),'parent_tool_use_id':None,
            'message':{'id':'m-'+str(turn),'model':model,'content':content,'usage':usage}}
        if self.owner.missing_assistant_session: assistant.pop('session_id')
        self.owner.emit(assistant)
        if self.owner.hang:  # The CLI repeats one message's usage on each content block's event.
            self.owner.emit({**assistant, 'uuid':'a-repeat-'+str(turn)})
        if self.owner.subagent:
            self.owner.emit({**assistant, 'uuid':'sub-'+str(turn), 'parent_tool_use_id':'parent', 'message':{**assistant['message'], 'content':[]}})
        results = [{'type':'tool_result','tool_use_id':'format-'+str(turn),'content':'Structured output provided successfully'}]
        if (self.owner.sync or self.owner.extra_tool) and not self.owner.drop_result:
            results.append({'type':'tool_result','tool_use_id':'tool', **({'is_error':True} if self.owner.tool_error else {})})
        if self.owner.hang: return len(text)  # The turn never reaches its result.
        self.owner.emit({'type':'user','session_id':'s1','message':{'content':results}})
        if self.owner.compact: self.owner.emit({'type':'system','session_id':'s1','subtype':'compact_boundary'})
        if self.owner.drift_calibration:
            self.owner.emit({'type':'assistant','session_id':'s1','uuid':'b','parent_tool_use_id':None,
                'message':{'model':'other-model','content':content,'usage':{'input_tokens':1,'cache_creation_input_tokens':1,'cache_read_input_tokens':1}}})
        result = {'type':'result','session_id':'s1','uuid':'r-'+str(turn),'subtype':'success','is_error':False,
            'modelUsage':{model:{'canonicalModel':model,'contextWindow':100,'inputTokens':10*self.owner.calls,'outputTokens':self.owner.calls,
                                 'cacheReadInputTokens':30*self.owner.calls,'cacheCreationInputTokens':20*self.owner.calls}},
            'permission_denials':self.owner.denials, 'subagent_stats':{'spawned':int(self.owner.stats)}, 'structured_output':payload}
        if self.owner.no_tokens: del result['modelUsage'][model]['outputTokens']
        if self.owner.side and self.owner.calls == 1:  # A side model reported once, then absent.
            result['modelUsage']['side-model'] = {'inputTokens':100,'outputTokens':0,'cacheReadInputTokens':0,'cacheCreationInputTokens':0}
        if self.owner.shrink and self.owner.calls == 2:
            result['modelUsage'][model].update(inputTokens=0, cacheReadInputTokens=0, cacheCreationInputTokens=0)
        if self.owner.missing_uuid: result.pop('uuid')
        if self.owner.missing_structured: result.pop('structured_output')
        self.owner.emit(result)
        return len(text)
    def flush(self): pass

class Fake:
    pid = None
    def __init__(self, *args, **kwargs):
        self.stdout, self.stdin, self.returncode = Stream(), In(self), None
        self.calls = 0
        self.denials = []
        self.reviewer = self.extra_tool = self.tool_error = self.drop_result = self.subagent = self.stats = self.hang = self.no_tokens = self.side = self.shrink = False
        self.init_tools = ['Glob','Grep','Read','StructuredOutput']
        self.payload = {'verdict':'ship','revision':'a'*40,'findings':[]}
        self.sync = self.background = self.drift = self.drift_calibration = self.compact = self.malformed = self.missing_uuid = self.empty_loaded = self.missing_assistant_session = self.duplicate_formatter = self.mismatch_formatter = self.missing_structured = self.malformed_fields = self.replay = False
    def emit(self, data): self.stdout.q.put(json.dumps(data)+'\n')
    def poll(self): return self.returncode
    def wait(self, timeout=None): self.returncode = 0; return 0

with tempfile.TemporaryDirectory(prefix='claude-threshold-bounds-') as temporary:
    for index, threshold in enumerate((60, 65, 70, 59, 71, True, 65.0, '65')):
        with patch.object(claude.subprocess, 'Popen', Fake):
            worker = claude.Claude(temporary, {}, None, None, Path(temporary) / f'{index}.log', 's1')
            worker.start(); worker.calibrate('calibrate')
            worker.checkpoint_threshold = threshold
            worker.on_checkpoint = lambda: None
            if type(threshold) is int and 60 <= threshold <= 70:
                worker.turn('work', {'required': ['goal', 'loaded_hash']})
                assert worker.proc.calls == 2
            else:
                try:
                    worker.turn('work', {'required': ['goal', 'loaded_hash']})
                    raise AssertionError('invalid threshold accepted: ' + repr(threshold))
                except claude.ClaudeError as error:
                    assert str(error) == 'checkpoint threshold must be 60..70 percent'
                assert worker.proc.calls == 1, 'invalid threshold dispatched work'
            worker.proc.returncode = 0

with tempfile.TemporaryDirectory(prefix='claude-threshold-denial-') as temporary:
    for case in ('recorded', 'unrecorded', 'changed', 'foreign'):
        with patch.object(claude.subprocess, 'Popen', Fake):
            worker = claude.Claude(temporary, {}, None, None, Path(temporary)/(case+'.log'), 's1')
            worker.start(); worker.calibrate('calibrate')
            worker.checkpoint_threshold = 60
            worker.on_checkpoint = lambda: None
            worker.checkpoint_denial = lambda tool: case != 'unrecorded'
            worker.proc.sync = True
            worker.proc.denials = [{'tool_use_id': 'missing' if case == 'foreign' else 'tool',
                'tool_name': 'Edit', 'tool_input': {'unexpected': True} if case == 'changed' else {}}]
            result = worker.turn('work', {'required': ['goal', 'loaded_hash']})
            assert ('tool-denied' in result['unresolved_operations']) == (case != 'recorded'), case
            worker.proc.returncode = 0

with tempfile.TemporaryDirectory(prefix='launch-claude-test-') as tmp:
    tmp = Path(tmp)
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'one.log', 's1'); worker.start()
        try: worker.turn('work', {'required':['goal']}); raise AssertionError('ordinary work bypassed calibration')
        except claude.CalibrationError: pass
        calibration = worker.calibrate('calibrate')
        assert calibration['usage'] == {'current':60,'window':100,'total':61} and worker.calibrated
        triggered = []
        worker.checkpoint_threshold = 65
        worker.on_checkpoint = lambda: triggered.append('checkpoint')
        event = {'type': 'assistant', 'session_id': 's1', 'uuid': 'threshold-event',
                 'message': {'model': 'fake-model', 'content': [], 'usage': {
                     'input_tokens': 65, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}}
        worker._validate_event(event, [])
        assert triggered == ['checkpoint'], 'checkpoint gate must close before the native result'
        worker._validate_event({**event, 'uuid': 'threshold-event-2'}, [])
        assert triggered == ['checkpoint'], 'threshold must latch once'
        worker.proc.sync = True
        ordinary = worker.turn('work', {'required':['goal','loaded_hash']})
        assert ordinary['payload']['goal'] == 'ok' and ordinary['tool_item_count'] == 1 and not ordinary['unresolved_operations']
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'empty-loaded.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.empty_loaded = True
        schema = {'required':['goal','loaded_hash'], 'properties':{'goal':{'type':'string','minLength':1},'loaded_hash':{'type':'string'}}}
        assert worker.turn('work', schema)['payload']['loaded_hash'] == ''
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'two.log', 's1'); worker.start(); worker.proc.sync = True
        try: worker.calibrate('calibrate'); raise AssertionError('tool calibration accepted')
        except claude.CalibrationError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'three.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.drift = True
        result = worker.turn('work', {'required':['goal']})
        assert 'model-changed' in result['unresolved_operations']
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'background.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.background = True
        assert any(x.startswith('background-tool') for x in worker.turn('work', {'required':['goal']})['unresolved_operations'])
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'compact.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.compact = True
        assert worker.turn('work', {'required':['goal']})['compacted']
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'malformed.log', 's1'); worker.start(); worker.proc.malformed = True
        try: worker.calibrate('calibrate'); raise AssertionError('malformed usage accepted')
        except claude.CalibrationError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'drift-cal.log', 's1'); worker.start(); worker.proc.drift_calibration = True
        try: worker.calibrate('calibrate'); raise AssertionError('calibration model drift accepted')
        except claude.CalibrationError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'missing-id.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.missing_uuid = True
        try: worker.turn('work', {'required':['goal']}); raise AssertionError('result without UUID accepted')
        except claude.ClaudeError: pass
    for flag, name in (('missing_structured', 'no-structured.log'), ('mismatch_formatter', 'mismatch.log'), ('duplicate_formatter', 'duplicate.log'), ('malformed_fields', 'malformed-fields.log')):
        with patch.object(claude.subprocess, 'Popen', Fake):
            worker = claude.Claude(tmp, {}, None, lambda: True, tmp/name, 's1'); worker.start(); worker.calibrate('calibrate'); setattr(worker.proc, flag, True)
            try: worker.turn('work', {'required':['goal']}); raise AssertionError(flag + ' accepted')
            except claude.ClaudeError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'missing-session.log', 's1'); worker.start(); worker.proc.missing_assistant_session = True
        try: worker.calibrate('calibrate'); raise AssertionError('assistant without session accepted')
        except claude.ClaudeError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'replay.log', 's1'); worker.start(); worker.calibrate('calibrate'); worker.proc.replay = True
        try: worker.turn('work', {'required':['goal']}); raise AssertionError('completed native triplet replay accepted')
        except claude.ClaudeError: pass
    try: claude.Claude(tmp, {}, None, lambda: True, tmp/'one.log', 's1').start(); raise AssertionError('log append accepted')
    except claude.ClaudeError: pass

with tempfile.TemporaryDirectory(prefix='launch-claude-kill-') as tmp:
    tmp = Path(tmp); child = tmp/'child.pid'
    code = 'import pathlib,subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)'
    worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'kill.log', 's1')
    worker.proc = subprocess.Popen([sys.executable, '-c', code, str(child)], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    worker.pgid = worker.proc.pid
    for _ in range(50):
        if child.exists(): break
        time.sleep(.01)
    assert child.exists()
    assert worker.close()['group'] == 'gone'

with tempfile.TemporaryDirectory(prefix='launch-claude-shell-') as tmp:
    worker = claude.Claude(tmp, {}, None, lambda: True, Path(tmp)/'shell.log', 's1', synchronous=lambda command: command == 'true && true')
    worker._tool({'id':'sync','name':'Bash','input':{'command':'true && true'}})
    assert worker.tools['sync'] == 'requested' and not worker.unresolved
    worker._tool_result({'tool_use_id':'sync','is_background':True}, {})
    assert 'background-tool-result' in worker.unresolved
    unknown = claude.Claude(tmp, {}, None, lambda: True, Path(tmp)/'unknown.log', 's1')
    unknown._tool({'id':'unknown','name':'Bash','input':{'command':'printf nope'}})
    unknown._tool_result({'tool_use_id':'unknown'}, {})
    assert 'unclassified-shell:unknown' in unknown.unresolved, 'a refused tool that returned output ran'

# LC-039 D1: a tool the PreToolUse gate refused is resolved only by proof it never ran.
with tempfile.TemporaryDirectory(prefix='launch-claude-refused-') as tmp:
    tmp = Path(tmp)
    denial = {'tool_use_id':'tool', 'tool_name':'Bash', 'tool_input':{'file_path':'x', 'command':'true'}}
    for case, error, denials, drop in (('denied', True, [denial], False), ('ran', False, [denial], False),
                                       ('undenied', True, [], False), ('changed', True, [{**denial, 'tool_input':{'command':'true'}}], False),
                                       ('foreign', True, [{**denial, 'tool_use_id':'other'}], False), ('no-result', False, [denial], True),
                                       ('twice', True, [denial, denial], False)):
        with patch.object(claude.subprocess, 'Popen', Fake):
            worker = claude.Claude(tmp, {}, None, lambda: True, tmp/(case+'.log'), 's1'); worker.start(); worker.calibrate('calibrate')
            worker.proc.extra_tool, worker.proc.tool_error, worker.proc.denials, worker.proc.drop_result = 'Bash', error, denials, drop
            unresolved = worker.turn('work', {'required':['goal']})['unresolved_operations']
            assert (unresolved == []) == (case == 'denied'), (case, unresolved)
            assert case in ('denied', 'twice') or 'unclassified-shell:tool' in unresolved, (case, unresolved)
            worker.proc.returncode = 0
    # LC-063: claude 2.1.322 streams the subagent tool as "Agent" and reports its denial as "Task". Proven refused
    # before it ran, the call resolves under either name; no other tool gains an alias.
    for case, tool, denied_as in (('agent-as-task', 'Agent', 'Task'), ('task-as-agent', 'Task', 'Agent'), ('bash-as-task', 'Bash', 'Task')):
        with patch.object(claude.subprocess, 'Popen', Fake):
            worker = claude.Claude(tmp, {}, None, lambda: True, tmp/(case+'.log'), 's1'); worker.start(); worker.calibrate('calibrate')
            worker.proc.extra_tool, worker.proc.tool_error, worker.proc.denials = tool, True, [{**denial, 'tool_name': denied_as}]
            unresolved = worker.turn('work', {'required':['goal']})['unresolved_operations']
            assert (unresolved == []) == (case != 'bash-as-task'), (case, unresolved)
            worker.proc.returncode = 0

# LC-039 slice 3: cumulative tokens, counted mid-turn too, and the read-only reviewer.
with tempfile.TemporaryDirectory(prefix='launch-claude-tokens-') as tmp:
    tmp = Path(tmp)
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'tokens.log', 's1'); worker.start(); worker.calibrate('calibrate')
        assert worker.turn('work', {'required':['goal']})['usage']['total'] == 122 and worker.latest_usage['total'] == 122
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'no-tokens.log', 's1'); worker.start(); worker.proc.no_tokens = True
        try: worker.calibrate('calibrate'); raise AssertionError('result without cumulative token usage accepted')
        except claude.CalibrationError: pass
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'hang.log', 's1', timeout=0.5); worker.start(); worker.calibrate('calibrate')
        worker.proc.hang = True
        try: worker.turn('work', {'required':['goal']}); raise AssertionError('turn without result accepted')
        except claude.ClaudeError as error: assert 'deadline' in str(error), error
        assert worker.latest_usage['total'] == 61 + 65, worker.latest_usage  # Spent tokens survive a turn with no result.

    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'side.log', 's1'); worker.start(); worker.proc.side = True
        worker.calibrate('calibrate')
        assert worker.turn('work', {'required':['goal']})['usage']['total'] == 122 + 100, 'a side model absent later keeps its tokens'
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'shrink.log', 's1'); worker.start(); worker.proc.shrink = True
        worker.calibrate('calibrate')
        try: worker.turn('work', {'required':['goal']}); raise AssertionError('a per-model token decrease accepted')
        except claude.CalibrationError: pass

def reviewer(tmp, name, **flags):
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Reviewer(tmp, {}, None, lambda: True, tmp/(name + '.log'), 's1', timeout=0.5); worker.start()
    worker.proc.reviewer = True
    for key, value in flags.items(): setattr(worker.proc, key, value)
    return worker

with tempfile.TemporaryDirectory(prefix='launch-claude-reviewer-') as tmp:
    tmp = Path(tmp)
    assert claude.Reviewer.TOOLS == ('Read', 'Glob', 'Grep') and claude.Reviewer.COMMAND[-7:] == (
        '--safe-mode', '--restricted', '--tools', 'Read,Glob,Grep', '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence')
    # Only the worker is pinned to bypass (the protected git dir's acceptance.json); the read-only reviewer never is.
    assert claude.Claude.COMMAND[-5:] == ('--permission-mode', 'bypassPermissions', '--strict-mcp-config', '--setting-sources', 'project,local')
    assert '--permission-mode' not in claude.Reviewer.COMMAND and claude.Reviewer.COMMAND[:7] == claude.STREAM
    good = reviewer(tmp, 'ship', payload={'verdict':'revise','revision':'b'*40,'findings':['one','two']})
    out = good.review('review')
    assert out['payload']['findings'] == ['one','two'] and out['usage']['total'] == 61 and not good.calibrated
    try: good.review('again'); raise AssertionError('second review turn accepted')
    except claude.ClaudeError: pass
    unsupported, payload = 'unsupported work', 'invalid native structured output'
    expected = {'write': 'unsupported-tool', 'bash': 'unsupported-tool', 'edit': 'unsupported-tool', 'subagent': 'subagent',
                'stats': 'subagent', 'init': 'reviewer-isolation', 'tokens': 'token usage', 'keys': payload, 'missing': payload,
                'verdict': payload, 'revision': payload, 'findings': payload, 'hang': 'deadline'}
    for name, flags in (('write', {'extra_tool':'Write'}), ('bash', {'extra_tool':'Bash'}), ('edit', {'extra_tool':'Edit'}),
                        ('subagent', {'subagent':True}), ('stats', {'stats':True}),
                        ('init', {'init_tools':['Read','Bash','StructuredOutput']}), ('tokens', {'no_tokens':True}),
                        ('keys', {'payload':{'verdict':'ship','revision':'a'*40,'findings':[],'extra':1}}),
                        ('missing', {'payload':{'verdict':'ship','revision':'a'*40}}),
                        ('verdict', {'payload':{'verdict':'approve','revision':'a'*40,'findings':[]}}),
                        ('revision', {'payload':{'verdict':'ship','revision':'A'*40,'findings':[]}}),
                        ('findings', {'payload':{'verdict':'ship','revision':'a'*40,'findings':[1]}}),
                        ('hang', {'hang':True})):
        bad = reviewer(tmp, name, **flags)
        try: bad.review('review'); raise AssertionError('reviewer accepted ' + name)
        except claude.ClaudeError as error: assert expected[name] in str(error), (name, str(error))
    # LC-064: the reviewer's CLI refuses a Read outside the worktree (the approved scope names the git-dir acceptance
    # file). A read-only call the CLI denied before it ran, proven by its error result and matching denial, is no work.
    read = {'tool_use_id':'tool', 'tool_name':'Read', 'tool_input':{'file_path':'x', 'command':'true'}}
    denied = reviewer(tmp, 'denied-read', extra_tool='Read', tool_error=True, denials=[read])
    assert denied.review('review')['payload']['verdict'] == 'ship' and not denied.unresolved, denied.unresolved
    for name, flags in (('ran-read', {'tool_error':False, 'denials':[read]}),
                        ('changed-read', {'tool_error':True, 'denials':[{**read, 'tool_input':{'file_path':'y'}}]}),
                        ('foreign-read', {'tool_error':True, 'denials':[{**read, 'tool_use_id':'other'}]})):
        bad = reviewer(tmp, name, extra_tool='Read', **flags)
        try: bad.review('review'); raise AssertionError('reviewer accepted ' + name)
        except claude.ClaudeError as error: assert 'tool-denied' in str(error), (name, str(error))
    # The worker keeps the stricter rule: a CLI denial of a tool its own gate admitted still blocks.
    with patch.object(claude.subprocess, 'Popen', Fake):
        worker = claude.Claude(tmp, {}, None, lambda: True, tmp/'worker-denied.log', 's1'); worker.start(); worker.calibrate('calibrate')
        worker.proc.sync, worker.proc.tool_error, worker.proc.denials = True, True, [{'tool_use_id':'tool', 'tool_name':'Edit', 'tool_input':{}}]
        assert 'tool-denied' in worker.turn('work', {'required':['goal']})['unresolved_operations']
        worker.proc.returncode = 0
    hung = reviewer(tmp, 'hang-tokens', hang=True)
    try: hung.review('review')
    except claude.ClaudeError: pass
    assert hung.latest_usage == {'total': 65}, hung.latest_usage
    assert claude.tool_refusal('Write', {'file_path':'x'}, lambda c: True, None, claude.Reviewer.TOOLS) == 'unsupported-tool'
    assert claude.tool_refusal('Read', {'file_path':'x'}, lambda c: True, None, claude.Reviewer.TOOLS) is None

# LC-043: close() charges what a stopped process wrote but this side never read; only this turn's own top-level messages.
with tempfile.TemporaryDirectory() as temporary:
    drained = claude.Claude(temporary, {}, None, None, Path(temporary) / 'drain.log', 's1')
    drained.consumed_assistants.add('old')
    def assistant(ident, size, **extra):
        return {'type':'assistant', 'session_id':'s1', 'uuid':ident, 'parent_tool_use_id':None,
                'message':{'id':ident, 'model':'m', 'usage':{'input_tokens':size}}, **extra}
    for event in (assistant('a', 7), assistant('old', 100), assistant('sub', 200, parent_tool_use_id='t'),
                  assistant('foreign', 400, session_id='s2'), {'type':'result', 'session_id':'s1'}, assistant('late', 800)):
        drained.messages.put(event)
    drained._drain_usage()
    assert drained.latest_usage == {'total': 7}, drained.latest_usage

# LC-062: the Claude leg owns its process by the same rules as the Codex leg. A real process speaks
# the minimum stream-json handshake; every helper writes to /dev/null so only the worker holds stdout.
REAL_FAKE = r'''
import json, os, signal, subprocess, sys, time
mode, pidfile = sys.argv[1], sys.argv[2]
session = sys.argv[sys.argv.index('--session-id') + 1]
def say(value): print(json.dumps({'session_id': session, **value}), flush=True)
SLOW = 'import os,signal,sys,time\ndef stop(*_): time.sleep(3); os._exit(0)\nsignal.signal(signal.SIGTERM, stop)\nopen(sys.argv[1], "w").write(str(os.getpid()))\ntime.sleep(60)'
if mode == 'setsid':
    helper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True, stdout=subprocess.DEVNULL)
    open(pidfile, 'w').write(str(helper.pid))
if mode == 'slow':
    subprocess.Popen([sys.executable, '-c', SLOW, pidfile], stdout=subprocess.DEVNULL)
if mode == 'eof':
    sys.exit(0)
init = {'type': 'system', 'subtype': 'init', 'model': 'fake-model', 'permissionMode': 'bypassPermissions', 'tools': ['Read'],
        'agents': [], 'output_style': 'default', 'claude_code_version': 'test', 'skills': [], 'plugins': []}
for count, line in enumerate(sys.stdin, 1):
    say(init)
    if mode == 'exit':
        sys.exit(3)
    if mode == 'burst':
        for _ in range(300): say({'type': 'system', 'subtype': 'status'})
    payload = {'loaded_hash': ''}
    usage = {'input_tokens': 10, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0, 'output_tokens': 1}
    say({'type': 'assistant', 'uuid': 'a-%d' % count, 'parent_tool_use_id': None, 'message': {'id': 'm-%d' % count,
         'model': 'fake-model', 'usage': usage, 'content': [{'type': 'tool_use', 'id': 'f-%d' % count, 'name': 'StructuredOutput', 'input': payload}]}})
    say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'f-%d' % count,
         'content': 'Structured output provided successfully'}]}})
    say({'type': 'result', 'uuid': 'r-%d' % count, 'subtype': 'success', 'is_error': False, 'structured_output': payload,
         'permission_denials': [], 'subagent_stats': {'spawned': 0}, 'modelUsage': {'fake-model': {'contextWindow': 100,
         'inputTokens': 10, 'outputTokens': 1, 'cacheReadInputTokens': 0, 'cacheCreationInputTokens': 0}}})
'''

def real_worker(tmp, mode, **kwargs):
    script = tmp / 'fake-claude.py'
    script.write_text(REAL_FAKE)
    worker = claude.Claude(tmp, {}, None, lambda: True, tmp / (mode + '.log'), 's1', **kwargs)
    worker.COMMAND = (sys.executable, str(script), mode, str(tmp / (mode + '.pid')))
    return worker

def helper_pid(tmp, mode):
    pidfile, end = tmp / (mode + '.pid'), time.monotonic() + 10
    while not (pidfile.exists() and pidfile.read_text()):
        assert time.monotonic() < end, mode + ' helper never started'
        time.sleep(.01)
    return int(pidfile.read_text())

def alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False

def kill_all(worker, tmp, mode):
    """Every process a case started dies, whether the case passed or failed: the worker's group, then the
    helper the fake recorded, read here so a case that failed before reading it still reaps it. While the fake
    still runs, its whole process tree goes too, which covers a helper that has not written its pid yet."""
    pids = []
    if worker.proc is not None and worker.proc.poll() is None:
        rows = [tuple(map(int, row.split())) for row in subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True).splitlines()]
        pending = [worker.pid]
        while pending:
            parent = pending.pop()
            children = [pid for pid, ppid in rows if ppid == parent]
            pids += children; pending += children
        try: os.killpg(worker.pgid, signal.SIGKILL)
        except ProcessLookupError: pass
        worker.proc.wait()
    pidfile = tmp / (mode + '.pid')
    if pidfile.exists() and pidfile.read_text(): pids.append(int(pidfile.read_text()))
    for pid in pids:
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass

with tempfile.TemporaryDirectory(prefix='launch-claude-own-') as tmp:
    tmp = Path(tmp).resolve()
    # A clean run closes with the same proof the Codex leg reports.
    worker = real_worker(tmp, 'clean')
    try:
        worker.start(); worker.calibrate('calibrate')
        closed = worker.close()
        assert closed == {'process': 'exited', 'group': 'gone', 'known_descendants': []}, closed
    finally: kill_all(worker, tmp, 'clean')

    # A helper that left the owned group is still a descendant: close refuses and leaves it to the operator.
    worker = real_worker(tmp, 'setsid')
    try:
        worker.start(); helper = helper_pid(tmp, 'setsid')
        try: worker.close(); raise AssertionError('a helper outside the owned group passed quiescence')
        except claude.QuiescenceError as error:
            remain = str(error).partition('known native descendants remain: ')[2]
            assert str(helper) in remain.split(', '), error
        assert alive(helper), 'close must not kill a process outside the owned group'
    finally: kill_all(worker, tmp, 'setsid')

    # A same-group child still exiting after the leader is reaped is drained, not refused.
    worker = real_worker(tmp, 'slow')
    try:
        worker.start(); child = helper_pid(tmp, 'slow')
        closed = worker.close()
        assert closed['group'] == 'gone' and not alive(child), closed
    finally: kill_all(worker, tmp, 'slow')

    # A worker that exits on its own mid-turn is not quiescent: nothing observed what it left behind.
    worker = real_worker(tmp, 'exit')
    try:
        worker.start()
        try: worker.calibrate('calibrate'); raise AssertionError('a worker exit mid-turn completed the turn')
        except claude.ClaudeError as error: assert 'Claude exited' in str(error), error
        try: worker.close(); raise AssertionError('an unobserved worker exit passed quiescence')
        except claude.QuiescenceError as error: assert 'unobserved-process-exit' in str(error), error
    finally: kill_all(worker, tmp, 'exit')

    # End of stream hands the waiter nothing: no sentinel reaches _validate_event or the usage drain.
    worker = real_worker(tmp, 'eof')
    try:
        worker.start(); worker._reader_thread.join(5)
        assert not worker._reader_thread.is_alive(), 'reader outlived the stream'
        seen = []
        while (event := worker._next(.05)) is not None: seen.append(event)
        assert not any('_reader_closed' in event for event in seen), seen
        try: worker.close()
        except claude.QuiescenceError: pass
    finally: kill_all(worker, tmp, 'eof')

    # A burst larger than the queue while the controller is busy: nothing dropped, and the descendant
    # scan (two ps calls) runs at most once per POLL rather than once per message.
    worker = real_worker(tmp, 'burst', timeout=8)
    try:
        worker.start()
        send = worker._send
        worker._send = lambda prompt: (send(prompt), time.sleep(2))
        calls, check_output = [], subprocess.check_output
        def counting(args, *rest, **kwargs):
            if args and args[0] == 'ps': calls.append(args)
            return check_output(args, *rest, **kwargs)
        began = time.monotonic()
        with patch.object(subprocess, 'check_output', counting):
            out = worker.calibrate('calibrate')
        elapsed = time.monotonic() - began
        assert out['event_id'] == 'r-1', out
        assert len(calls) <= 2 * elapsed + 2, (len(calls), elapsed)
        worker.close()
    finally: kill_all(worker, tmp, 'burst')

print('launch Claude adapter checks passed')
