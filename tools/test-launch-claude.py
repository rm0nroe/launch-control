#!/usr/bin/env python3
"""No-network deterministic checks for persistent Claude stream handling."""
import importlib.util, json, queue, subprocess, sys, tempfile, time
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

print('launch Claude adapter checks passed')
