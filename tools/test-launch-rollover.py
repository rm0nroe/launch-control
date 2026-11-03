#!/usr/bin/env python3
"""Real queue/runtime plus fake native JSON-RPC; never contacts a model."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'skills/onboard/scripts/launch-runtime.py'
QUEUE = ROOT / 'skills/onboard/scripts/launch-queue.py'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()


FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys, time, uuid
if '--version' in sys.argv:
    print('synthetic-codex 1'); sys.exit(0)
root = pathlib.Path.cwd()
runtime = os.environ['FAKE_LAUNCH_RUNTIME']
thread = str(uuid.uuid4())
gitdir = pathlib.Path(subprocess.check_output(['git','rev-parse','--absolute-git-dir'],text=True).strip())
counter = gitdir / 'synthetic-phases.json'
scenario = os.environ.get('FAKE_FAILURE', '')
pending = None
def run(*args, payload=None, ok=True, env=None):
    result = subprocess.run([sys.executable,runtime,'--project',str(root),'--platform','codex',*args],
        input=json.dumps(payload) if payload else None, capture_output=True, text=True, env={**os.environ, **(env or {})})
    assert result.returncode == 0 or not ok, result.stderr
    return json.loads(result.stdout)
forge = os.environ.get('FAKE_FORGE', '')
canonical_events = []  # Claude stream copies of canonical Bash calls, for the queue's own review.
common = pathlib.Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())
def emit(value): print(json.dumps(value),flush=True)
for line in sys.stdin:
    msg=json.loads(line)
    method=msg.get('method'); ident=msg.get('id')
    if method=='initialize': emit({'id':ident,'result':{}})
    elif method=='turn/steer':
        assert msg['params']['threadId']==thread and msg['params']['expectedTurnId']==turn
        emit({'id':ident,'result':{'turnId':turn}})
        if pending:
            emit(pending); pending=None
    elif method=='thread/start':
        run('hook',payload={'hook_event_name':'SessionStart','session_id':thread,'cwd':str(root),'source':'startup'})
        if os.environ.get('FAKE_CLEAR_INITIAL'):
            run('hook',payload={'hook_event_name':'SessionStart','session_id':'cleared','cwd':str(root),'source':'clear'})
        emit({'id':ident,'result':{'thread':{'id':thread},'model':'fixture-model','modelProvider':'fixture','cwd':str(root),
            'approvalPolicy':'never','approvalsReviewer':'user','sandbox':{'type':'workspaceWrite'}}})
    elif method=='turn/start':
        turn=str(uuid.uuid4()); params=msg['params']; prompt=params['input'][0]['text']
        emit({'id':ident,'result':{'turn':{'id':turn}}})
        calibration=set(params['outputSchema']['properties'])=={'loaded_hash'}
        if calibration and scenario == 'load_exit':
            sys.exit(7)
        if calibration and scenario == 'load_partial' and counter.exists():
            print(json.dumps({'type':'assistant','session_id':thread,'uuid':'partial-'+turn,'message':{'id':'partial','model':'fixture-model',
                'content':[],'usage':{'input_tokens':500,'cache_creation_input_tokens':0,'cache_read_input_tokens':0,'output_tokens':0}}}),flush=True)
            sys.exit(7)
        if calibration:
            data=json.loads(prompt.split('\n')[-1]); payload={'loaded_hash':data['loaded_hash']}
            if data['checkpoint']:
                assert data['checkpoint']['semantic']['next_phase']=='implementation'
                assert (root/'candidate').read_text().startswith('phase 1\n')
            current,total=1000,1000; items=[]
        else:
            phase=json.loads(counter.read_text())+1 if counter.exists() else 1
            if phase>1: assert (root/'candidate').read_text().startswith('phase 1\n')
            if scenario != 'no_progress':
                with (root/'candidate').open('a') as f: f.write('phase '+str(phase)+'\n')
                if phase==3 and os.environ.get('FAKE_REVIEW') in ('latin1','large'):
                    with (root/'candidate').open('ab') as f: f.write(b'caf\xe9\n' if os.environ['FAKE_REVIEW']=='latin1' else b'x'*1100000+b'\n')
            counter.write_text(json.dumps(phase))
            loaded_hash=json.loads(re.search(r'loaded_hash must be ("[a-f0-9]*")$',prompt)[1])
            payload=dict(goal='Complete fixture',scope='T-1 only',completed='phase '+str(phase),next_phase='implementation',
                next_action='Continue retained candidate',questions='none',evidence='synthetic phase '+str(phase),
                unsafe_state='uncommitted candidate',reversal='retain fixture evidence',loaded_hash=loaded_hash)
            current,total=(65000,66000) if phase<3 else (2000,3000)
            items=[{'id':'edit','type':'fileChange','status':'completed','changes':[]}]
            if scenario in ('family', 'family_refused'):
                # Unlisted commands: a bounded git read passes the family fallback, a push never does.
                command='git log -5 --format=%s' if scenario=='family' else 'git push origin HEAD'
                items.append({'id':'shell'+str(phase),'type':'commandExecution','command':command,'status':'completed','exitCode':0})
            if phase==3:
                subprocess.run(['git','add','--','candidate'],check=True)
                subprocess.run(['git','commit','-m','fixture candidate'],check=True,stdout=subprocess.DEVNULL)
                state=run('status','--run',os.environ['LAUNCH_RUN_ID'])
                evidence={k:state[k] for k in ('repo','worktree','branch','run','task','platform')}
                evidence['revision']=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
                evidence['evidence']={'behavior':'synthetic three phases across two replacements; not native model proof'}
                path=gitdir/'acceptance.json'; path.write_text(json.dumps(evidence))
                # LC-039 forges: each is one way a worker could fake readiness with plain file writes.
                if forge in ('exclude','gitconfig'):
                    (root/'conftest').write_text('makes the declared check pass')
                if forge == 'exclude':
                    with (common/'info/exclude').open('a') as f: f.write('conftest\n')
                if forge == 'gitignore':
                    (root/'sub').mkdir(); (root/'sub/.gitignore').write_text('*\n'); (root/'sub/conftest').write_text('pass')
                if forge == 'repin':
                    with (pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])/'skills/onboard/references/launch-autonomy.md').open('a') as f: f.write('drift\n')
                if forge == 'gitconfig':
                    (pathlib.Path(os.environ['HOME'])/'excludes').write_text('conftest\n')
                    (pathlib.Path(os.environ['HOME'])/'.gitconfig').write_text('[core]\n\texcludesFile = '+os.environ['HOME']+'/excludes\n')
                if forge == 'fsmonitor':
                    subprocess.run(['git','config','core.fsmonitor','false'],check=True)
                if os.environ.get('FAKE_CANONICAL'):
                    # LC-039 GAP 1: the literal canonical commands pass the gate and run through the wrapper.
                    canonical=json.loads(os.environ['FAKE_CANONICAL'])
                    for command in canonical:
                        if gate('Bash',{'command':command})!={}:
                            (gitdir/'fake-assert.txt').write_text('canonical verify refused: '+command); sys.exit(1)
                    ready=subprocess.run(['bash','-c',canonical[1]],capture_output=True,text=True)
                    if not forge: canonical_events.extend(canonical)
                    if (ready.returncode==0)==(forge in ('flip','policy','gitfile')):
                        (gitdir/'fake-assert.txt').write_text('canonical ready exit '+str(ready.returncode)+': '+ready.stderr[-500:]); sys.exit(1)
                else:
                    run('verify','ready','--run',state['run'],'--candidate',evidence['revision'],'--acceptance',str(path),ok=forge not in ('flip','policy','gitfile'))
                active=gitdir/'launch/active.json'
                if forge in ('flip','policy','gitfile'):
                    live=json.loads(active.read_text())
                    assert live['status']=='running' and live['receipt']['ok'] is False, live
                    live['status']='awaiting_review'; live['receipt']['ok']=True
                    for check in live['receipt']['checks']: check['exit']=0
                    if forge == 'policy':
                        (root/'.claude/launch/verify.json').write_text(json.dumps({'schema':1,'checks':[{'command':'true','cwd':'.','timeout':5}],'acceptance':['behavior']}))
                        live['policy']=json.loads(subprocess.check_output([sys.executable,'-c','import json,runpy,sys,pathlib;ns=runpy.run_path(sys.argv[1]);print(json.dumps(ns["Runtime"](pathlib.Path(sys.argv[2]),None,"claude").policy()))',runtime,str(root)],text=True))
                    active.write_text(json.dumps(live))
                if forge == 'acceptance':
                    path.write_text(json.dumps({**evidence,'evidence':{}}))  # Ready first, then strip the evidence.
                if forge == 'gitfile':
                    import shutil
                    fake=root/'.claude/launch/fakegit'
                    shutil.copytree(gitdir,fake)
                    (fake/'commondir').write_text(str(common)+'\n')
                    (root/'.git').write_text('gitdir: '+str(fake)+'\n')
        if not calibration and scenario == 'no_progress':
            items=[]
            payload['evidence']='fixture infrastructure unavailable before tool execution'
        if not calibration and scenario == 'command_failure':
            emit({'method':'item/completed','params':{'threadId':thread,'turnId':turn,
                'item':{'id':'broken','type':'commandExecution','command':'printf ok','status':'failed','exitCode':None}}})
        if not calibration and scenario == 'pause_unknown':
            common=pathlib.Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())
            (common/'launch-queue/PAUSE').touch()
            time.sleep(10)
        if not calibration and scenario == 'pause_usage':
            # LC-043: a Claude worker's usage line lands only after the controller has stopped it.
            import signal
            def stopped(*_):
                print(json.dumps({'type':'assistant','session_id':thread,'uuid':'stopped-'+turn,'message':{'id':'stopped','model':'fixture-model',
                    'content':[],'usage':{'input_tokens':4321,'cache_creation_input_tokens':0,'cache_read_input_tokens':0,'output_tokens':0}}}),flush=True)
                sys.exit(0)
            signal.signal(signal.SIGTERM, stopped)
            (common/'launch-queue/PAUSE').touch()
            time.sleep(10)
        if not calibration and (scenario == 'compaction' or (scenario == 'ready_compaction' and phase==3)):
            items.append({'id':'compact','type':'contextCompaction'})
        if calibration and scenario == 'load_tool':
            items=[{'id':'forbidden','type':'fileChange','status':'completed'}]
        if calibration and scenario == 'load_hash':
            payload={'loaded_hash':'wrong'}
        usage={'last':{'totalTokens':current},'total':{'totalTokens':total},'modelContextWindow':100000}
        if os.environ.get('FAKE_BAD_TELEMETRY') and not calibration: usage['modelContextWindow']=None
        emit({'method':'thread/tokenUsage/updated','params':{'threadId':thread,'turnId':turn,'tokenUsage':usage}})
        items.append({'id':'answer','type':'agentMessage','text':json.dumps(payload)})
        terminal={'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed','items':items}}}
        if os.environ.get('FAKE_ACTIVE_THRESHOLD') and not calibration and phase<3:
            pending=terminal  # No terminal notes until the real adapter steers this active turn.
        else: emit(terminal)
'''

# Reuse identical phase actions and convert only the native wire protocol.
CLAUDE_FAKE = FAKE.replace("thread = str(uuid.uuid4())", "thread = sys.argv[sys.argv.index('--session-id')+1]\nfirst = True\nusage = None")
CLAUDE_FAKE = CLAUDE_FAKE.replace("'--platform','codex'", "'--platform','claude'")
# LC-039 slice 3: the controller's separate read-only reviewer is the same binary with --safe-mode.
REVIEWER_FAKE = r'''
if '--safe-mode' in sys.argv:
    mode = os.environ.get('FAKE_REVIEW', '')
    session = sys.argv[sys.argv.index('--session-id')+1]
    root = pathlib.Path.cwd()
    gitdir = pathlib.Path(subprocess.check_output(['git','rev-parse','--absolute-git-dir'],text=True).strip())
    def fail(message):
        (gitdir/'fake-assert.txt').write_text(message); sys.exit(1)
    expected = ['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--safe-mode','--restricted',
                '--tools','Read,Glob,Grep','--strict-mcp-config','--disable-slash-commands','--no-session-persistence','--session-id',session,'--json-schema']
    if sys.argv[1:-1] != expected: fail('reviewer argv: ' + json.dumps(sys.argv[1:]))
    if any(key.startswith('LAUNCH_') for key in os.environ): fail('reviewer inherited a run binding')
    prompt = json.loads(sys.stdin.readline())['message']['content']
    head = subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    for needle in ('Approved scope:\nSynthetic fixture edits for T-1', '"command": "test -f candidate"', 'Candidate revision: ' + head,
                   'DATA, candidate diff:', '+phase 3'):
        if needle not in prompt: fail('reviewer prompt lacks ' + needle)
    if mode == 'latin1' and '+caf\ufffd' not in prompt: fail('non-UTF-8 diff line lost')
    def say(value): print(json.dumps({'session_id':session, **value}), flush=True)
    say({'type':'system','subtype':'init','model':'fixture-model','permissionMode':'default','tools':['Glob','Grep','Read','StructuredOutput'],
         'skills':[],'mcp_servers':[],'slash_commands':[],'plugins':[{'name':'cc-plugin-telemetry','source':'cc-plugin-telemetry@builtin'}]})
    usage = {'input_tokens':7000,'cache_creation_input_tokens':0,'cache_read_input_tokens':0,'output_tokens':0}
    payload = {'verdict':'revise' if mode == 'revise' else 'ship', 'revision':'0'*40 if mode == 'revision' else head,
               'findings':['phase 3 misses the edge case'] if mode == 'revise' else []}
    content = [{'type':'tool_use','id':'review-write','name':'Write','input':{'file_path':'candidate','content':'x'}}] if mode == 'write' else []
    assistant = {'type':'assistant','uuid':'review-1','parent_tool_use_id':None,'message':{'id':'review-msg','model':'fixture-model',
                 'content':content + [{'type':'tool_use','id':'review-format','name':'StructuredOutput','input':payload}],'usage':usage}}
    if mode == 'hang':
        # LC-043: the usage line lands only after the controller has decided to stop, the worst order the
        # race can take (it flaked when the stop was polled before an already-written line was read).
        import signal
        def stopped(*_):
            say(assistant); sys.exit(0)
        signal.signal(signal.SIGTERM, stopped)
        child = subprocess.Popen(['sleep','1000'])
        (gitdir/'review-child.pid').write_text(str(child.pid))
        (common/'launch-queue/PAUSE').write_text('stop the review')
        time.sleep(1000)
    say(assistant)
    if mode == 'drift':
        with (root/'candidate').open('a') as f: f.write('reviewer drift\n')
    say({'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'review-format',
         'content':'Structured output provided successfully'}] + ([{'type':'tool_result','tool_use_id':'review-write','content':'ok'}] if mode == 'write' else [])}})
    say({'type':'result','subtype':'success','uuid':'review-result','structured_output':payload,'permission_denials':[],
         'subagent_stats':{'spawned':0},'modelUsage':{'fixture-model':{'contextWindow':100000,'inputTokens':7000,'outputTokens':0,
         'cacheReadInputTokens':0,'cacheCreationInputTokens':0}}})
    sys.stdin.read()
    sys.exit(0)
'''
CLAUDE_FAKE = CLAUDE_FAKE.replace("common = pathlib.Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())\n",
                                  "common = pathlib.Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())\n" + REVIEWER_FAKE)
CLAUDE_FAKE = CLAUDE_FAKE.replace("if os.environ.get('FAKE_ACTIVE_THRESHOLD') and not calibration and phase<3:", "if False:")
CLAUDE_FAKE = CLAUDE_FAKE.replace("def emit(value): print(json.dumps(value),flush=True)", r'''def emit(value):
    global usage
    method=value.get('method')
    if method=='thread/tokenUsage/updated': usage=value['params']['tokenUsage']
    elif method=='turn/completed':
        turn=value['params']['turn']; payload=json.loads(turn['items'][-1]['text']); formatter='format-'+turn['id']
        denials=[]
        if os.environ.get('FAKE_ACTIVE_THRESHOLD') and usage['last']['totalTokens']>=65000:
            import time
            tool={'tool_use_id':'work-'+turn['id'],'tool_name':'Edit','tool_input':{'file_path':'candidate'}}
            print(json.dumps({'type':'assistant','session_id':thread,'uuid':'threshold-'+turn['id'],
                'message':{'model':'fixture-model','content':[{'type':'tool_use','id':tool['tool_use_id'],
                    'name':tool['tool_name'],'input':tool['tool_input']}],
                'usage':{'input_tokens':65000,'cache_creation_input_tokens':0,'cache_read_input_tokens':0}}}),flush=True)
            end=time.monotonic()+5
            while not json.loads((gitdir/'launch/active.json').read_text()).get('checkpoint_only'):
                assert time.monotonic()<end, 'active threshold did not close the work-tool gate'
                time.sleep(.01)
            gate=run('hook',payload={'hook_event_name':'PreToolUse','session_id':thread,'cwd':str(root),**tool})
            assert gate['hookSpecificOutput']['permissionDecision']=='deny'
            denials=[tool]
            print(json.dumps({'type':'user','session_id':thread,'message':{'content':[
                {'type':'tool_result','tool_use_id':tool['tool_use_id'],'is_error':True,'content':'checkpoint requested'}]}}),flush=True)
            assert run('hook',payload={'hook_event_name':'PreToolUse','session_id':thread,'cwd':str(root),
                'tool_name':'StructuredOutput','tool_use_id':formatter,'tool_input':payload})=={}
        for n,command in enumerate(canonical_events):
            ident='canon-'+str(n)+'-'+turn['id']
            print(json.dumps({'type':'assistant','session_id':thread,'uuid':ident,'message':{'model':'fixture-model',
                'content':[{'type':'tool_use','id':ident,'name':'Bash','input':{'command':command}}],
                'usage':{'input_tokens':usage['last']['totalTokens'],'cache_creation_input_tokens':0,'cache_read_input_tokens':0}}}),flush=True)
            print(json.dumps({'type':'user','session_id':thread,'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':ident,'content':'ok'}]}}),flush=True)
        canonical_events.clear()
        print(json.dumps({'type':'assistant','session_id':thread,'uuid':'assistant-'+turn['id'],'message':{'model':'fixture-model',
            'content':[{'type':'tool_use','name':'StructuredOutput','id':formatter,'input':payload}],
            'usage':{'input_tokens':usage['last']['totalTokens'],'cache_creation_input_tokens':0,'cache_read_input_tokens':0}}}),flush=True)
        print(json.dumps({'type':'user','session_id':thread,'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':formatter,'content':'Structured output provided successfully'}]}}),flush=True)
        print(json.dumps({'type':'result','subtype':'success','session_id':thread,'uuid':turn['id'],'structured_output':payload,
            'permission_denials':denials,'modelUsage':{'fixture-model':{'contextWindow':usage['modelContextWindow'],
            'inputTokens':usage['total']['totalTokens'],'outputTokens':0,'cacheReadInputTokens':0,'cacheCreationInputTokens':0}}}),flush=True)
''')
CLAUDE_FAKE = CLAUDE_FAKE.replace("msg=json.loads(line)", r'''msg=json.loads(line)
    prompt=msg['message']['content']
    if first:
        print(json.dumps({'type':'system','subtype':'init','session_id':thread,'model':'fixture-model',
            'permissionMode':'default','tools':[],'claude_code_version':'fixture'}),flush=True)
        run('hook',payload={'hook_event_name':'SessionStart','session_id':thread,'cwd':str(root),'source':'startup'})
        gate=run('hook',payload={'hook_event_name':'PreToolUse','session_id':thread,'cwd':str(root),'tool_name':'Bash'})
        assert gate['hookSpecificOutput']['permissionDecision']=='deny'
        schema={'properties':{'loaded_hash':{}}}
        first=False
    else:
        prompt,schema=prompt.rsplit('\nReturn exactly one JSON object satisfying this schema:\n',1)
        schema=json.loads(schema)
        def gate(name, inp=None, **extra):
            return run('hook',payload={'hook_event_name':'PreToolUse','session_id':thread,'cwd':str(root),
                'tool_name':name,'tool_input':inp or {},**extra})
        assert gate('Bash',{'command':'git status'})=={}
        # LC-039 D4: publication is Codex-only; refuse before the tool runs, not after.
        for name,inp,extra in (('Bash',{'command':'git push origin HEAD'},{}),('Bash',{'command':'gh pr create --fill'},{}),
                ('mcp__github__create_pull_request',{},{}),('Agent',{'prompt':'publish'},{}),
                ('Bash',{'command':'git status'},{'agent_id':'child'})):
            refused=gate(name,inp,**extra).get('hookSpecificOutput',{})
            if refused.get('permissionDecision')!='deny' or 'Codex-only' not in refused.get('permissionDecisionReason',''):
                (gitdir/'fake-assert.txt').write_text('refusable tool admitted: '+name+' '+json.dumps(inp)); sys.exit(1)
        if os.environ.get('LAUNCH_GIT_DIR'):
            for path, allowed in ((gitdir/'launch/active.json',False),(common/'launch-queue/active.json',False),(common/'config',False),
                                  (root/'.git',False),(pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])/'settings.json',False),
                                  (gitdir/'acceptance.json',True),(root/'candidate',True)):
                decision=gate('Write',{'file_path':str(path),'content':'x'}).get('hookSpecificOutput',{})
                if (decision.get('permissionDecision')=='deny') == allowed or (not allowed and 'protected-path' not in decision.get('permissionDecisionReason','')):
                    (gitdir/'fake-assert.txt').write_text('path rule wrong for '+str(path)+' '+json.dumps(decision)); sys.exit(1)
            steered=run('hook',payload={'hook_event_name':'PreToolUse','session_id':thread,'cwd':str(root),'tool_name':'Bash',
                'tool_input':{'command':'git status'}},env={'LAUNCH_GIT_DIR':str(root)}).get('hookSpecificOutput',{})
            if 'git roots changed' not in steered.get('permissionDecisionReason',''):
                (gitdir/'fake-assert.txt').write_text('gate trusted a steered git root: '+json.dumps(steered)); sys.exit(1)
        manifest=pathlib.Path(os.environ['LAUNCH_MANIFEST']); original=manifest.read_bytes()
        try:
            manifest.write_text(json.dumps({**json.loads(original),'minutes':999}))
            if gate('Bash',{'command':'git status'}).get('hookSpecificOutput',{}).get('permissionDecision')!='deny':
                (gitdir/'fake-assert.txt').write_text('tool admitted under a changed controller manifest'); sys.exit(1)
        finally: manifest.write_bytes(original)
    msg={'method':'turn/start','params':{'input':[{'text':prompt}],'outputSchema':schema},'id':1}
''')

for platform, scenario in (('codex','active'), ('claude','active'), ('codex','pass'), ('codex','telemetry'), ('codex','clear'), ('claude','pass'), ('claude','load_partial'), ('claude','pause_usage'), ('codex','family'), *[('codex', case) for case in ('family_refused', 'no_progress', 'command_failure', 'pause_unknown', 'load_exit', 'load_tool', 'load_hash', 'compaction', 'ready_compaction', 'token_cap')], *[(platform, 'crash_' + stage) for platform in ('codex', 'claude') for stage in ('launching', 'quiesced', 'checkpointed', 'launch_reserved', 'dispatching_load', 'loaded')]):
    with tempfile.TemporaryDirectory(prefix='launch-rollover-') as directory:
        base = Path(directory).resolve()
        root = base / 'repo'
        root.mkdir()
        git(root, 'init', '-b', 'main')
        git(root, 'config', 'user.name', 'Fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        (root / 'BACKLOG.md').write_text('## P1\n### T-1 - Fixture\n**Status:** open\n')
        (root / 'candidate').write_text('')
        policy = root / f'.{platform}/launch/verify.json'
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'test -f candidate', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
        if platform == 'claude':
            (root / '.claude/settings.json').write_text(json.dumps({'hooks': {'PreToolUse': [{'hooks': [
                {'type': 'command', 'command': 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"', 'timeout': 10}]}]}}))
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'fixture')
        worktree = base / 'work'
        git(root, 'worktree', 'add', '-b', 'T-1', str(worktree))
        fake = base / platform
        fake.write_text(CLAUDE_FAKE if platform == 'claude' else FAKE)
        fake.chmod(0o755)
        manifest = base / 'manifest.json'
        manifest.write_text(json.dumps(dict(schema=1, project=str(root), platform=platform,
            source={'kind': 'backlog', 'path': str(root / 'BACKLOG.md')},
            items=[{'id': 'T-1', 'priority': 1, 'worktree': str(worktree), 'scope': 'Synthetic fixture edits and local commits only.'}],
            minutes=3, max_tasks=1, max_launches=1, max_attempts=2, rollover={'threshold': 65, 'max_launches': 3},
            **({'max_tokens': 2000} if scenario == 'token_cap' else {}))))
        env = {**os.environ, 'FAKE_FAILURE': scenario, 'PATH': str(base) + os.pathsep + os.environ['PATH'], 'FAKE_LAUNCH_RUNTIME': str(RUNTIME),
               'FAKE_BAD_TELEMETRY': '1' if scenario == 'telemetry' else '',
               'FAKE_ACTIVE_THRESHOLD': '1' if scenario == 'active' else '',
               'FAKE_CLEAR_INITIAL': '1' if scenario == 'clear' else ''}
        crash_driver = base / 'crash.py'
        crash_driver.write_text('''import os, runpy, sys
ns=runpy.run_path(sys.argv[1])
q=ns['Queue'](ns['Path'](sys.argv[2]))
original=q.save
def save():
    original()
    if not q.state['items']: return
    item=q.state['items'][0]
    if item.get('handoff_stage') == sys.argv[3] and (sys.argv[3] not in ('dispatching_load','loaded','launch_reserved') or q.state['launches']==2):
        os._exit(73)
q.save=save
q.run()
''')
        def call(action, crash=False):
            if crash:
                return subprocess.run([sys.executable, str(crash_driver), str(QUEUE), str(manifest), scenario.removeprefix('crash_')],
                                      env=env, capture_output=True, text=True, timeout=45)
            result = subprocess.run([sys.executable, str(QUEUE), '--manifest', str(manifest), action],
                                    env=env, capture_output=True, text=True, timeout=45)
            if result.returncode:  # A fake's own refusal check exits 1; surface which one.
                result.stderr += ''.join('\nfake: ' + path.read_text() for path in sorted((root / '.git/worktrees').glob('*/fake-assert.txt')))
            return result
        assert call('init').returncode == 0
        original = json.loads((root / '.git/launch-queue/active.json').read_text())
        result = call('run', crash=scenario.startswith('crash_'))
        saved = json.loads((root / '.git/launch-queue/active.json').read_text())
        print('fixture:', platform, scenario, flush=True)
        assert saved['admissions'] == 1, (scenario, result.returncode, result.stderr)
        if scenario.startswith('crash_'):
            assert result.returncode == 73, result.stderr
            item=saved['items'][0]
            assert item['handoff_stage'] == scenario.removeprefix('crash_')
            assert saved['deadline'] == original['deadline'] and saved['manifest'] == original['manifest']
            candidate=(worktree/'candidate').read_bytes()
            runtime_path=Path(git(worktree, 'rev-parse', '--absolute-git-dir'))/'launch/active.json'
            before=json.loads(runtime_path.read_text())
            # Pipe EOF ends the fake transport and releases its inherited queue lock.
            end=time.monotonic()+5
            while item.get('pid'):
                try:
                    os.kill(item['pid'], 0)
                except ProcessLookupError:
                    break
                assert time.monotonic()<end, 'crash fixture transport did not exit'
                time.sleep(.01)
            again=call('run')
            after=json.loads(runtime_path.read_text())
            for key in ('run','task','deadline','attempts','max_attempts','controller','policy','runtime'):
                assert after[key] == before[key], (scenario,key)
            latest=json.loads((root / '.git/launch-queue/active.json').read_text())
            if scenario in ('crash_checkpointed','crash_launch_reserved'):
                assert again.returncode == 0 and latest['launches'] == 3, again.stderr
                assert (worktree/'candidate').read_bytes().startswith(candidate)
            else:
                assert again.returncode != 0 and latest == saved, again.stderr
                assert (worktree/'candidate').read_bytes() == candidate
        elif scenario == 'token_cap':
            item=saved['items'][0]
            assert result.returncode != 0 and 'token soft cap reached: no new work after 2000 tokens' in result.stderr, result.stderr
            assert saved['tokens'] > 2000 and saved['launches'] == 1, 'no replacement session past the soft cap'
            assert item['handoff_stage'] == 'checkpointed', 'progress sealed before the refusal'
            assert (worktree / 'candidate').read_text() == 'phase 1\n'
            again=call('run')
            assert again.returncode != 0 and 'token soft cap reached' in again.stderr, again.stderr
            assert json.loads((root / '.git/launch-queue/active.json').read_text())['launches'] == 1, 'restart reset the soft cap'
        elif scenario in ('family_refused', 'no_progress', 'command_failure', 'pause_unknown', 'pause_usage', 'load_exit', 'load_tool', 'load_hash', 'compaction', 'ready_compaction'):
            item=saved['items'][0]
            if scenario == 'family_refused':
                assert 'unclassified-shell:shell1' in json.dumps(item), item
            assert result.returncode != 0 and item['status'] == ('paused' if scenario in ('pause_unknown', 'pause_usage') else 'blocked'), result.stderr
            assert saved['launches'] == (3 if scenario == 'ready_compaction' else 1) and saved['deadline'] == original['deadline']
            assert saved['manifest'] == original['manifest'] and item.get('attempts', 0) == 0
            runtime_state=json.loads((Path(git(worktree, 'rev-parse', '--absolute-git-dir'))/'launch/active.json').read_text())
            assert runtime_state['max_attempts'] == 2 and runtime_state['attempts'] == 0
            assert runtime_state['run'] == item['run'] and runtime_state['session'] == item['session']
            if scenario == 'no_progress':
                assert 'no tool progress' in item['reason']
                assert 'fixture infrastructure unavailable' in runtime_state['notes']
            if scenario == 'command_failure':
                assert item['failure']['cause'].startswith('native commandExecution failed: broken')
                assert 'Traceback' in item['failure']['trace'], 'failure origin not retained'
            if scenario == 'pause_unknown':
                assert item['failure']['cause'] == 'queue paused'
                assert item['failure']['usage'] is None
                assert saved['tokens'] == 1000, 'retain known calibration tokens without inventing interrupted usage'
                assert 'unknown-telemetry' in item['failure']['unresolved_operations']
                assert item['quiescence']['group'] == 'gone'
            if scenario == 'pause_usage':
                assert item['failure']['usage']['total'] == item['session_tokens'], 'failure record keeps the pre-stop usage'
                assert saved['tokens'] == item['usage']['total'] + 4321 == item['session_tokens'], \
                    ('a stopped worker spends what it wrote after the stop', saved['tokens'], item['usage'], item['failure']['usage'])
            phases=Path(git(worktree, 'rev-parse', '--absolute-git-dir'))/'synthetic-phases.json'
            assert (json.loads(phases.read_text()) if phases.exists() else 0) == (3 if scenario == 'ready_compaction' else 0 if scenario.startswith('load_') else 1)
            pid=item.get('pid')
            try:
                os.kill(pid, 0)
                raise AssertionError('fixture process survived')
            except ProcessLookupError:
                pass
            again=call('run')
            assert again.returncode != 0 and json.loads((root / '.git/launch-queue/active.json').read_text()) == saved
        elif scenario == 'clear':
            assert result.returncode != 0 and saved['items'][0]['status'] == 'paused', result.stderr
            assert saved['launches'] == 1 and (worktree / 'candidate').read_text() == ''
        elif scenario == 'load_partial':
            item=saved['items'][0]
            assert result.returncode != 0 and saved['launches'] == 2 and item['failure']['usage']['total'] == 500, (result.stderr, item.get('failure'))
            assert saved['tokens'] == item['usage']['total'] + 500, ('a failed replacement calibration spends its tokens', saved['tokens'], item['usage'])
            # LC-062: a worker that exited on its own was never seen to quiesce; the block says so.
            assert 'Claude exited: 7; quiescence unresolved: unresolved native operations: unobserved-process-exit' in item['reason'], item['reason']
        elif scenario == 'telemetry':
            assert result.returncode != 0 and saved['items'][0]['status'] == 'blocked', result.stderr
            assert saved['launches'] == 1
            assert (worktree / 'candidate').read_text() == 'phase 1\n'
        else:
            assert result.returncode == 0, result.stderr
            assert saved['launches'] == 3 and saved['outcome'] == ('awaiting_review' if platform == 'codex' else 'review_ready_publication_unsupported')
            if platform == 'codex':
                assert saved['tokens'] == 135000, 'calibration must not double-count cumulative work usage'
            assert (worktree / 'candidate').read_text() == 'phase 1\nphase 2\nphase 3\n'
            again = call('run')
            assert again.returncode == 0, again.stderr
            assert json.loads(again.stdout)['launches'] == 3, 'restart duplicated native admission'

print('PASS: synthetic native rollover, first failure, telemetry closure, compaction/load refusal, token soft cap and six crash boundaries')

# LC-039 slice 2: a prepared Claude task is ready only when the controller's own re-check passes.
TARGET = ROOT / 'skills/onboard/scripts/launch-target.py'
HOOK = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"'
LAUNCH = ['.claude/skills/launch/SKILL.md', *('.claude/skills/launch/references/' + n for n in
           ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md'))]
import shutil
import runpy
CANONICAL = runpy.run_path(str(RUNTIME))['CANONICAL_VERIFY']
REVIEW_FORGES = ('review-revise', 'review-revision', 'review-drift', 'review-write', 'review-hang', 'review-crash', 'review-cap',
                 'review-large', 'review-attr', 'review-latin1')
PASSING = ('', 'review-attr', 'review-latin1', 'restart', 'restart-reserved')
for forge in ('', 'flip', 'policy', 'exclude', 'fsmonitor', 'gitconfig', 'gitfile', 'drift', 'acceptance', 'gitignore', 'repin', 'restart', 'restart-reserved', 'restart-tamper', 'restart-pin', 'restart-unsnapshotted', 'pin', *REVIEW_FORGES):
    with tempfile.TemporaryDirectory(prefix='launch-prepared-claude-') as directory:
        base = Path(directory).resolve()
        root = base / 'repo'
        (base / 'home').mkdir()
        root.mkdir()
        git(root, 'init', '-b', 'main')
        git(root, 'config', 'user.name', 'Fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        (root / '.gitignore').write_text('.claude/launch/\n.claude/hooks/launch.sh\nscripts/verify.sh\nlaunch-control-backups/\n')
        (root / 'BACKLOG.md').write_text('## P1\n### T-1 - Fixture\n**Status:** open\n')
        (root / 'candidate').write_text('')
        if forge == 'review-attr':  # A committed attribute must not blank the reviewer's diff.
            (root / '.gitattributes').write_text('candidate -diff\n')
        matchers = {'SessionStart': 'startup|resume|compact|clear'}
        (root / '.claude').mkdir()
        (root / '.claude/settings.json').write_text(json.dumps({'hooks': {e: [{**({'matcher': matchers[e]} if e in matchers else {}),
            'hooks': [{'type': 'command', 'command': HOOK, 'timeout': 10}]}] for e in ('SessionStart', 'PreCompact', 'Stop', 'PreToolUse')}}))
        for name in LAUNCH:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(name + '\n')
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'fixture')
        # drift: the second run of the check (the controller's) edits the candidate mid-check.
        count = base / 'count'
        check = ('test -f candidate' if forge in ('', 'fsmonitor', 'acceptance', 'repin', *REVIEW_FORGES) or forge.startswith('restart') else
                 'test -f sub/conftest || grep -q never candidate' if forge == 'gitignore' else
                 f'n=$(cat {count} 2>/dev/null || echo 0); echo $((n+1)) > {count}; [ "$n" -eq 0 ] || echo drift >> candidate' if forge == 'drift' else
                 'test -f conftest || grep -q never candidate' if forge in ('exclude', 'gitconfig') else 'grep -q never candidate')
        config = base / 'verify.json'
        config.write_text(json.dumps({'schema': 1, 'checks': [{'command': check, 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
        policy = base / 'policy.json'
        policy.write_text(json.dumps({'schema': 1, 'platform': 'claude', 'project': str(root), 'base_revision': git(root, 'rev-parse', 'HEAD'),
            'source': {'path': 'BACKLOG.md'}, 'scope_template': 'Synthetic fixture edits for {id}; acceptance at {gitdir}/acceptance.json.',
            'caps': {'minutes': 3, 'max_attempts': 2, **({'max_tokens': 135000} if forge == 'review-cap' else {}), 'rollover': {'threshold': 65, 'max_launches': 3, 'synchronous_commands': list(CANONICAL)}},
            'generator': {'argv': [sys.executable, '-I', str(RUNTIME), '--project', '{worktree}', '--platform', 'claude',
                                   'render-overlay', '--from-config', str(config)]}}))
        manifest = base / 'manifest.json'
        prepared = subprocess.run([sys.executable, str(TARGET), '--policy', str(policy), '--output', str(manifest)], capture_output=True, text=True)
        assert prepared.returncode == 0, prepared.stderr
        worktree = Path(json.loads(manifest.read_text())['items'][0]['worktree'])
        real_state = Path(git(worktree, 'rev-parse', '--absolute-git-dir')) / 'launch/active.json'
        fake = base / 'claude'
        fake.write_text(CLAUDE_FAKE)
        fake.chmod(0o755)
        # The worker's wrappers load the installed copies; the queue admits only these exact bytes.
        shutil.copytree(ROOT / 'skills/onboard', base / 'config/skills/onboard')
        env = {**os.environ, 'PATH': str(base) + os.pathsep + os.environ['PATH'], 'FAKE_LAUNCH_RUNTIME': str(RUNTIME),
               'FAKE_FORGE': forge, 'HOME': str(base / 'home'), 'CLAUDE_CONFIG_DIR': str(base / 'config'),
               'FAKE_CANONICAL': json.dumps(CANONICAL), 'FAKE_REVIEW': forge.removeprefix('review-'),
               'LAUNCH_CONTROLLER_LEAK': '1'}  # The reviewer must not inherit any LAUNCH_* the controller has.
        for key in ('FAKE_FAILURE', 'FAKE_ACTIVE_THRESHOLD', 'FAKE_BAD_TELEMETRY', 'FAKE_CLEAR_INITIAL', 'LAUNCH_GIT_DIR', 'LAUNCH_GIT_COMMON_DIR'):
            env.pop(key, None)
        crash = base / 'crash.py'
        crash.write_text('import os,runpy,sys\nns=runpy.run_path(sys.argv[1])\nq=ns["Queue"](ns["Path"](sys.argv[2]))\noriginal=q.save\n'
                         'def save():\n    original()\n    if q.state["items"] and q.state["items"][0].get("handoff_stage") == "checkpointed": os._exit(73)\n'
                         'q.save=save\nq.run()\n')
        def call(*argv):
            result = subprocess.run([sys.executable, *argv], env=env, capture_output=True, text=True, timeout=60)
            if result.returncode:
                result.stderr += ''.join('\nfake: ' + p.read_text() for p in (root / '.git/worktrees').glob('*/fake-assert.txt'))
            return result
        assert call(str(QUEUE), '--manifest', str(manifest), 'init').returncode == 0
        print('fixture: prepared claude', forge or 'pass', flush=True)
        if forge == 'review-crash':
            # The controller dies mid-review: the restart names the reviewer and never admits or re-reviews blindly.
            crash.write_text(crash.read_text().replace('.get("handoff_stage") == "checkpointed"', '.get("claude_review", {}).get("pid")'))
            assert call(str(crash), str(QUEUE), str(manifest)).returncode == 73
            item = json.loads((root / '.git/launch-queue/active.json').read_text())['items'][0]
            assert item['handoff_stage'] == 'reviewing' and item['status'] == 'running', item
            result = call(str(QUEUE), '--manifest', str(manifest), 'run')
            assert result.returncode != 0 and 'interrupted independent review; reviewer pgid %s' % item['claude_review']['pgid'] in result.stderr, result.stderr
            continue
        before = None
        if forge.startswith('restart'):
            # The controller dies after admission; the restart resumes against the snapshot it persisted then.
            if forge == 'restart-reserved':  # Dies at the first save after admission, before any worker launch.
                crash.write_text(crash.read_text().replace('"checkpointed"', '"launch_reserved"'))
            assert call(str(crash), str(QUEUE), str(manifest)).returncode == 73
            item = json.loads((root / '.git/launch-queue/active.json').read_text())['items'][0]
            before = item['snapshot']
            end = time.monotonic() + 5
            while item.get('pid'):
                try:
                    os.kill(item['pid'], 0)
                except ProcessLookupError:
                    break
                assert time.monotonic() < end, 'crash fixture transport did not exit'
                time.sleep(.01)
            if forge == 'restart-tamper':  # Changed while the controller was down: a re-taken snapshot would bless it.
                with (root / '.git/info/exclude').open('a') as f: f.write('conftest\n')
            if forge == 'restart-pin':  # The worker's gate is the installed runtime; it drifted while the controller was down.
                with (base / 'config/skills/onboard/scripts/launch-runtime.py').open('a') as f: f.write('\n# drifted\n')
            if forge == 'restart-unsnapshotted':  # Queue state from a controller that kept the snapshot in memory.
                state = json.loads((root / '.git/launch-queue/active.json').read_text())
                del state['items'][0]['snapshot']
                (root / '.git/launch-queue/active.json').write_text(json.dumps(state))
        if forge == 'pin':
            for relative in ('scripts/launch-runtime.py', 'scripts/launch-claude.py', 'scripts/launch-process.py', 'references/launch-autonomy.md'):
                installed = base / 'config/skills/onboard' / relative
                original = installed.read_bytes()
                installed.write_bytes(original + b'\n# installed copy drifted\n')
                result = call(str(QUEUE), '--manifest', str(manifest), 'run')
                installed.write_bytes(original)
                saved = json.loads((root / '.git/launch-queue/active.json').read_text())
                assert result.returncode != 0 and 'installed Launch file differs' in result.stderr and relative in result.stderr, result.stderr
                assert saved['launches'] == 0 and saved['admissions'] == 0 and saved['items'][0]['status'] == 'todo', saved
            continue
        result = call(str(QUEUE), '--manifest', str(manifest), 'run')
        saved = json.loads((root / '.git/launch-queue/active.json').read_text())
        item = saved['items'][0]
        if forge in PASSING:
            assert result.returncode == 0, result.stderr
            assert saved['outcome'] == 'review_ready_publication_unsupported' and saved['launches'] == 3, saved
            assert item['receipt']['controller'] is True and item['receipt']['ok'] is True, item['receipt']
            assert item['snapshot']['control'] and (before is None or item['snapshot'] == before), 'a restart reads the persisted snapshot, never a new one'
            assert json.loads((root / '.git/launch-queue' / (item['run'] + '-controller-receipt.json')).read_text())['ok'] is True
            review = item['claude_review']
            assert review['verdict'] == 'ship' and review['revision'] == item['receipt']['revision'] == git(worktree, 'rev-parse', 'HEAD'), review
            assert review['tokens'] == 7000 and review['quiescence']['group'] == 'gone' and not review['unresolved'], review
            assert saved['tokens'] == 135000 + 7000, ('worker and reviewer tokens both count', saved['tokens'])
            again = call(str(QUEUE), '--manifest', str(manifest), 'run')
            assert again.returncode == 0, again.stderr
            with (worktree / 'candidate').open('a') as f: f.write('edited after review\n')
            # Re-bless the worker-writable receipt so only the controller-held review fingerprint can refuse.
            state = json.loads(real_state.read_text())
            state['receipt']['fingerprint'] = runpy.run_path(str(RUNTIME))['fingerprint'](worktree)
            real_state.write_text(json.dumps(state))
            again = call(str(QUEUE), '--manifest', str(manifest), 'run')
            assert again.returncode != 0 and 'candidate changed after review' in again.stderr, again.stderr
            assert json.loads(real_state.read_text())['status'] == 'awaiting_review', 'the live check must not be what refused'
            continue
        expected = {'flip': 'declared checks failed', 'policy': 'verification policy changed after admission',
                    'exclude': 'git control files changed after admission', 'fsmonitor': 'git control files changed after admission',
                    'gitconfig': 'candidate is not the clean, unchanged committed revision',
                    'gitfile': 'git directory changed after admission',
                    'drift': 'candidate is not the clean, unchanged committed revision',
                    'acceptance': 'missing or mismatched task acceptance evidence',
                    'gitignore': 'candidate is not the clean, unchanged committed revision',
                    'repin': 'installed Launch file differs from the controller',
                    'restart-tamper': 'git control files changed after admission',
                    'restart-pin': 'installed Launch file differs from the controller',
                    'restart-unsnapshotted': 'no admission snapshot recorded',
                    'review-revise': 'independent Claude review requested revision: phase 3 misses the edge case',
                    'review-revision': 'independent review verdict not bound to the candidate revision',
                    'review-drift': 'candidate changed during independent review',
                    'review-write': 'unsupported-tool:review-write',
                    'review-hang': 'external controller stopped native worker',
                    'review-cap': 'independent Claude review failed: token soft cap reached',
                    'review-large': 'candidate diff too large for independent review'}[forge]
        # A policy edit can also be caught first by the per-turn check() poll, mid-turn (blocked).
        if forge == 'policy' and 'native policy or runtime changed' in result.stderr:
            expected, status = 'native policy or runtime changed', 'blocked'
        else:
            status = 'paused'
        assert result.returncode != 0 and expected in result.stderr, (forge, result.stderr)
        assert item['status'] == status and expected in item['reason'] and saved.get('outcome') is None, (forge, item)
        if forge.startswith('restart'):  # Refused before any worker launched, not caught later at readiness.
            assert item['handoff_stage'] == 'launch_reserved', (forge, item)
        # The stop lands in the real git dir, never in a worker-steered copy.
        live = json.loads(real_state.read_text())
        assert live['status'] == status and expected in live['reason'], (forge, live)
        if forge == 'gitfile':
            assert json.loads((worktree / '.claude/launch/fakegit/launch/active.json').read_text())['status'] == 'awaiting_review'
        if not forge.startswith('review-'):
            assert 'claude_review' not in item, (forge, 'no independent review before the controller re-check passes')
            continue
        review = item['claude_review']
        if forge in ('review-cap', 'review-large'):  # Refused before launch: paused, not blocked, nothing spent on review.
            assert review == {'revision': item['receipt']['revision']} and saved['tokens'] == 135000, (review, saved['tokens'])
            continue
        assert review['tokens'] == 7000 and saved['tokens'] >= 135000 + 7000, (forge, review, saved['tokens'])
        if forge == 'review-hang':
            child = int((Path(git(worktree, 'rev-parse', '--absolute-git-dir')) / 'review-child.pid').read_text())
            try:
                os.kill(child, 0); raise AssertionError('reviewer child survived close')
            except ProcessLookupError:
                pass
        if forge == 'review-write':  # Cleanup was never confirmed, so the restart names the reviewer.
            assert 'quiescence' not in review and review['pid'], review
            again = call(str(QUEUE), '--manifest', str(manifest), 'run')
            assert again.returncode != 0 and 'reviewer pgid %s may still be running' % review['pgid'] in again.stderr, again.stderr
        if forge == 'review-revise':
            assert review['findings'] == ['phase 3 misses the edge case'], review
            again = call(str(QUEUE), '--manifest', str(manifest), 'run')
            assert again.returncode != 0 and 'corrected work needs a new preparation and run' in again.stderr, again.stderr
print('PASS: prepared Claude readiness survives ten worker forges and pauses in the real git dir; a controller restart resumes on the persisted snapshot, and tampering while it was down still pauses')
print('PASS: a separate read-only Claude reviewer binds its verdict to the re-checked candidate; eight review forges pause, and attribute, encoding and size cannot hide the diff')
