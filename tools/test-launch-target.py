#!/usr/bin/env python3
"""Bounded source preparation through real Git and canonical generation; no model."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'skills/onboard/scripts/launch-target.py'
target = runpy.run_path(str(SCRIPT))


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.DEVNULL).strip()


@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='launch-target-') as directory:
        base = Path(directory).resolve()
        project = base / 'repo'
        project.mkdir()
        git(project, 'init', '-b', 'fixture')
        git(project, 'config', 'user.name', 'Fixture')
        git(project, 'config', 'user.email', 'fixture@example.invalid')
        (project / '.gitignore').write_text('.codex/\nscripts/verify.sh\nlaunch-control-backups/\n')
        (project / 'tracked').write_text('fixture')
        source = project / 'BACKLOG.md'
        source.write_text('## P1\n### T-1 - complete\n**Status:** done\n### T-2 - selected\n**Status:** ready\n- [ ] nested acceptance\n### T-3 - later\n**Status:** ready\n**Depends on:** T-2\n')
        git(project, 'add', '.')
        git(project, 'commit', '-m', 'fixture')
        rendered = base / 'rendered'
        refs = rendered / 'skills/launch/references'
        refs.mkdir(parents=True)
        (refs.parent / 'SKILL.md').write_text('---\nname: launch\ndescription: fixture\n---\n${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/references/launch-autonomy.md\n')
        for name in ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md'):
            (refs / name).write_text(name+'\n')
        config, commands = base / 'verify.json', base / 'commands.txt'
        config.write_text(json.dumps({'schema':1,'checks':[{'command':'test -f tracked','cwd':'.','timeout':5}],'acceptance':['behavior']}))
        commands.write_text('test -f tracked\n')
        runtime = ROOT / 'skills/onboard/scripts/launch-runtime.py'
        argv = [sys.executable, str(ROOT / 'skills/onboard/scripts/codex-parity.py'), '--codex', '--enable-autonomy', '--source', str(rendered), '--autonomy-config', str(config), '--autonomy-commands', str(commands), '--autonomy-controller', str(runtime), '--autonomy-controller-digest', hashlib.sha256(runtime.read_bytes()).hexdigest(), '--autonomy-shared-root', str(project)]
        subprocess.run([*argv, '--project', str(project)], check=True, capture_output=True)
        generator = base / 'generator.py'
        generator.write_text('import subprocess,sys\nsubprocess.run('+repr(argv)+"+['--project',sys.argv[2]],check=True)\n")
        policy = base / 'policy.json'
        policy.write_text(json.dumps({'schema':1, 'project':str(project), 'base_revision':git(project,'rev-parse','HEAD'),
            'source':{'path':'BACKLOG.md'}, 'scope_template':'Fix {id}; write acceptance at {gitdir}/acceptance.json.',
            'caps':{'minutes':10,'max_attempts':2,'rollover':{'threshold':65,'max_launches':1,'synchronous_commands':['git status --short']}},
            'generator':{'argv':[sys.executable,str(generator),'{id}','{worktree}']}}))
        yield base, project, source, policy


def refused(function, phrase):
    try:
        function()
        raise AssertionError('expected refusal: '+phrase)
    except target['rt'].Invalid as error:
        assert phrase in str(error), str(error)


with fixture() as (base, project, source, policy):
    output = base / 'manifest.json'
    approved = policy.read_text()
    data = json.loads(approved)
    for threshold in (60, 65, 70, 59, 71, True, 65.0, '65', None):
        data['caps']['rollover']['threshold'] = threshold
        policy.write_text(json.dumps(data))
        if type(threshold) is int and 60 <= threshold <= 70:
            assert target['read_policy'](policy)[0]['caps']['rollover']['threshold'] == threshold
        else:
            refused(lambda: target['prepare'](policy, output), 'invalid rollover caps')
        assert not output.exists() and not (project / '.git/launch-queue').exists()
        assert not (project / '.git/launch-prepared').exists()
    policy.write_text(approved)
    result = target['prepare'](policy, output)
    assert result['items'][0]['id'] == 'T-2'
    assert not git(Path(result['items'][0]['worktree']), 'status', '--porcelain')
    prepared = output.read_text()
    manifest = json.loads(prepared)
    for threshold in (60, 65, 70, 59, 71, True, 65.0, '65', None):
        manifest['rollover']['threshold'] = threshold
        output.write_text(json.dumps(manifest))
        if type(threshold) is int and 60 <= threshold <= 70:
            assert target['queue'].Queue(output).rollover['threshold'] == threshold
        else:
            refused(lambda: target['queue'].Queue(output), 'rollover threshold must be 60..70 percent')
        assert not (project / '.git/launch-queue/active.json').exists()
    output.write_text(prepared)
    q = target['queue'].Queue(output)
    q.run(True)
    assert q.state['launches'] == 0
    refused(lambda: target['prepare'](policy, base/'again.json'), 'retained')
    policy.write_text(policy.read_text()+'\n')
    refused(lambda: q.run(), 'policy changed')
    assert json.loads(q.path.read_text())['launches'] == 0

for content, message in [
    ('## P1\n### T-2\n**Status:** ready\n### T-2\n**Status:** ready\n', 'duplicate'),
    ('### T-2\n**Status:** ready\n', 'priority'),
    ('## P1\n| T-2 | [ ] |\n', 'table'),
]:
    with fixture() as (base, project, source, policy):
        source.write_text(content)
        refused(lambda: target['prepare'](policy,base/'manifest.json'), message)
        assert not (project/'.git/launch-prepared').exists()

with fixture() as (base, project, source, policy):
    source.write_text('## P1\n### T-1\n**Status:** mystery\n### T-2\n**Status:** ready\n**Depends on:** after deployment\n')
    assert target['prepare'](policy,base/'none.json')['outcome'] == 'no_eligible'
    assert not (base/'none.json').exists() and not (project/'.git/launch-prepared').exists()

with fixture() as (base, project, source, policy):
    (project/'.gitignore').write_text('')
    refused(lambda: target['prepare'](policy,base/'manifest.json'), 'ignore')
    assert not (project/'.git/launch-prepared').exists()

print('PASS: source selection, canonical preparation, retained authority and policy drift')

with fixture() as (base, project, source, policy):
    output = base/'manifest.json'
    target['prepare'](policy, output)
    source.write_text(source.read_text().replace('## P1\n', '## P1\n### T-0 - new\n**Status:** ready\n'))
    q = target['queue'].Queue(output)
    q.run(True)
    assert q.state['items'][0]['id'] == 'T-2'
    source.write_text(source.read_text().replace('nested acceptance', 'changed acceptance'))
    refused(lambda: q.run(), 'source changed')
    assert json.loads(q.path.read_text())['launches'] == 0

for field in ('output', 'template', 'pause', 'claim'):
    with fixture() as (base, project, source, policy):
        output = base/'manifest.json'
        if field == 'output':
            output.write_text('user-owned')
        elif field == 'template':
            data = json.loads(policy.read_text()); data['scope_template'] = 'bad {unknown}'
            policy.write_text(json.dumps(data))
        else:
            directory = project/'.git/launch-queue'; directory.mkdir()
            (directory/('PAUSE' if field == 'pause' else 'preparing-T-2.json')).write_text('retained')
        refused(lambda: target['prepare'](policy, output), {'output':'output already', 'template':'placeholder', 'pause':'pause', 'claim':'retained'}[field])
        assert not (project/'.git/launch-prepared').exists()
        if field == 'output': assert output.read_text() == 'user-owned'

# A generator failure leaves both claim and worktree; the next invocation never replays it.
with fixture() as (base, project, source, policy):
    generator = base/'generator.py'
    generator.write_text('raise SystemExit(17)\n')
    try:
        target['prepare'](policy, base/'manifest.json')
        raise AssertionError('generator failure passed')
    except subprocess.CalledProcessError as error:
        assert error.returncode == 17
    marker = project/'.git/launch-queue/preparing-T-2.json'
    original = marker.read_bytes()
    assert json.loads(original)['status'] == 'preparing'
    assert (project/'.git/launch-prepared/T-2').is_dir()
    refused(lambda: target['prepare'](policy,base/'again.json'), 'retained')
    assert marker.read_bytes() == original

for contenders in (2, 8):
    with fixture() as (base, project, source, policy):
        linked = base/'linked'
        git(project,'worktree','add','-b','linked',str(linked),'HEAD')
        read_fd, write_fd = os.pipe()
        processes=[]
        code='import os,runpy,sys; fd=int(sys.argv.pop(1)); script=sys.argv.pop(1); os.read(fd,1); runpy.run_path(script,run_name="__main__")'
        try:
            for number in range(contenders):
                context = project if number % 2 == 0 else linked
                data=json.loads(policy.read_text()); data['project']=str(context)
                grant=base/f'policy-{number}.json'; grant.write_text(json.dumps(data))
                processes.append(subprocess.Popen([sys.executable,'-c',code,str(read_fd),str(SCRIPT),'--policy',str(grant),'--output',str(base/f'race-{number}.json')], cwd=context, pass_fds=(read_fd,), stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True))
            os.write(write_fd,b'x'*contenders)
            outputs=[p.communicate(timeout=60) for p in processes]
            assert sum(p.returncode == 0 for p in processes) == 1, [(p.returncode,o) for p,o in zip(processes,outputs)]
            assert len(list(base.glob('race-*.json'))) == 1
            assert len(list((project/'.git/launch-queue').glob('preparing-*.json'))) == 1
            assert len(list((project/'.git/launch-prepared').iterdir())) == 1
        finally:
            os.close(read_fd); os.close(write_fd)
            for p in processes:
                if p.poll() is None: p.kill(); p.wait()
print('PASS: retained failures, source identity and real 2/8 primary-linked preparation races')

# A clean generated tree is insufficient: its revision must still be the approved base.
with fixture() as (base, project, source, policy):
    generator=base/'generator.py'
    with generator.open('a') as stream:
        stream.write("subprocess.run(['git','-C',sys.argv[2],'commit','--allow-empty','-m','unexpected base'],check=True)\n")
    refused(lambda: target['prepare'](policy,base/'manifest.json'), 'worktree base')
    assert not (base/'manifest.json').exists()

for initialized, mutation in ((False, 'dirty'), (True, 'commit')):
    with fixture() as (base, project, source, policy):
        output=base/'manifest.json'
        cfg=target['prepare'](policy,output)
        q=target['queue'].Queue(output)
        if initialized: q.run(True)
        worktree=Path(cfg['items'][0]['worktree'])
        if mutation == 'dirty': (worktree/'tracked').write_text('unapproved edit')
        else: git(worktree,'commit','--allow-empty','-m','unapproved base')
        def no_launch(item): raise AssertionError('native admission reached before baseline refusal')
        q.prepare=no_launch
        refused(lambda: q.run(not initialized), 'worktree')
        assert not q.path.exists() or json.loads(q.path.read_text())['launches'] == 0
print('PASS: generated and post-preparation baseline drift refuses before native admission')

# Explicit section authority excludes duplicate history and binds completed prerequisites.
def selected_fixture(source, policy, format):
    if format == 'headings':
        heading = '## P1.A - selected'
        prerequisite = '### T-1 - complete\n**Status:** done'
        content = heading+'\n'+prerequisite+'\n### T-2 - selected\n**Status:** ready\n**Depends on:** T-1\n### T-3 - later\n**Status:** ready\n**Depends on:** T-2\n## History\n### T-2 - duplicate\n**Status:** done\n'
    else:
        heading = '# Selected'
        prerequisite = '| T-1 | complete | [x] | P1 | none |'
        content = heading+'\n| ID | Item | Status | Tier | Depends on |\n|---|---|---|---|---|\n'+prerequisite+'\n| T-2 | selected | [ ] | P1.A | T-1 |\n| T-3 | later | [ ] | P1.B | T-2 |\n# History\n| ID | Item | Status | Tier |\n|---|---|---|---|\n| T-2 | duplicate | [x] | P1 |\n'
    source.write_text(content)
    data = json.loads(policy.read_text())
    data['source'].update(format=format, heading=heading)
    policy.write_text(json.dumps(data))
    return prerequisite

for format in ('headings', 'table'):
    with fixture() as (base, project, source, policy):
        prerequisite = selected_fixture(source, policy, format)
        output = base/'manifest.json'
        result = target['prepare'](policy, output)
        item = result['items'][0]
        assert (item['id'], item['priority'], item['subpriority'], item['depends']) == ('T-2', 1, 'A', ['T-1'])
        assert item['prerequisites'] == {'T-1': hashlib.sha256(prerequisite.encode()).hexdigest()}
        assert not git(Path(item['worktree']), 'status', '--porcelain')
        q = target['queue'].Queue(output)
        q.run(True)
        assert q.state['admissions'] == q.state['launches'] == 0
        source.write_text('unrelated preface\n'+source.read_text())
        q.validate_preparation()
        source.write_text(source.read_text().replace(prerequisite, prerequisite.replace('done','ready').replace('[x]','[ ]')))
        refused(lambda: q.run(), 'prerequisite changed')
        assert json.loads(q.path.read_text())['launches'] == 0
print('PASS: selected heading/table preparation and completed prerequisite drift')

# Grammar failures stay inside the selected authority and cannot become ready tasks.
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory).resolve()/'BACKLOG.md'
    reader = target['queue'].selected_backlog
    scope = {'format':'headings', 'heading':'## P1 - selected'}
    prefix = scope['heading']+'\n### T-2\n'
    for metadata, reason in [
        ('**Status:** ready\n**Status:** done', 'duplicate field'),
        ('**Status:** unknown', 'ambiguous status'),
        ('**Status:** done; pending deployment', 'ambiguous status'),
        ('**Status:** ready but blocked', 'ambiguous status'),
        ('**Status:** ready\n**Depends on:** T-1 after deployment', 'ambiguous dependency'),
        ('**Status:** ready\n**Depends on:** T-1\nconditional continuation', 'ambiguous dependency'),
        ('**Status:** ready\n**Depends on:** T-1, T-1', 'duplicate dependency'),
    ]:
        path.write_text(prefix+metadata+'\n')
        item = reader(path, scope)['T-2']
        assert item['status'] == 'blocked' and reason in item['blocked'], item
    path.write_text(prefix+'**Status:** ready\n```\n### T-9\n**Status:** done\n```\n')
    assert set(reader(path,scope)) == {'T-2'}
    assert reader(path,scope)['T-2']['status'] == 'todo'
    for content, phrase in [
        ('# other\n','unique'),
        (scope['heading']+'\n'+scope['heading']+'\n','unique'),
        (prefix+'**Status:** ready\n### T-2\n**Status:** done\n','duplicate source'),
        (prefix+'**Status:** ready\n```\n','unterminated'),
    ]:
        path.write_text(content)
        refused(lambda:reader(path,scope),phrase)
    for tier in ('P1 plus follow-up', 'unknown'):
        path.write_text('| ID | Item | Status | Tier |\n| T-2 | task | [ ] | '+tier+' |\n')
        assert reader(path,{'format':'table'})['T-2']['blocked'] == 'ambiguous priority'
    path.write_text('| ID | Item | Status | Tier |\n| T-2 | task | extra | [ ] | P1 |\n')
    assert reader(path,{'format':'table'})['T-2']['status'] == 'blocked'
    path.write_text(prefix+'**Status:** ready\n')
    original = path.with_name('original.md')
    path.rename(original); path.symlink_to(original)
    refused(lambda:reader(path,scope),'unsafe')

for selected_source in ({'format':'headings','heading':None}, {'format':'table','heading':3}, {'heading':'# Selected'}):
    with fixture() as (base, project, source, policy):
        data=json.loads(policy.read_text());data['source'].update(selected_source);policy.write_text(json.dumps(data))
        refused(lambda:target['prepare'](policy,base/'manifest.json'), 'heading' if 'format' in selected_source else 'format')
        assert not list((project/'.git').glob('launch-queue/preparing-*'))

for dependency in ('T-99', 'T-3'):
    with fixture() as (base, project, source, policy):
        selected_fixture(source,policy,'table')
        source.write_text(source.read_text().replace('| P1.A | T-1 |','| P1.A | '+dependency+' |'))
        assert target['prepare'](policy,base/'manifest.json')['outcome'] == 'no_eligible'
        assert not (project/'.git/launch-prepared').exists()

with fixture() as (base, project, source, policy):
    selected_fixture(source,policy,'table')
    source.write_text(source.read_text().replace('| T-3 | later | [ ] | P1.B | T-2 |','| T-0 | later | [ ] | P1.B | none |'))
    assert target['prepare'](policy,base/'manifest.json')['items'][0]['id'] == 'T-2'

# A mission child prepares only its pinned task, never the source's first eligible one.
for pinned, expected in (('T-0', 'T-0'), ('T-3', None)):
    with fixture() as (base, project, source, policy):
        selected_fixture(source,policy,'table')
        source.write_text(source.read_text().replace('| T-3 | later | [ ] | P1.B | T-2 |','| T-0 | later | [ ] | P1.B | none |\n| T-3 | later | [ ] | P1.C | T-2 |'))
        data = json.loads(policy.read_text()); data['task'] = pinned; policy.write_text(json.dumps(data))
        result = target['prepare'](policy,base/'manifest.json')
        assert (result['items'][0]['id'] if expected else result['outcome']) == (expected or 'no_eligible'), result

with fixture() as (base, project, source, policy):
    selected_fixture(source,policy,'headings')
    with (base/'generator.py').open('a') as stream:
        stream.write('from pathlib import Path\np=Path('+repr(str(source))+')\np.write_text(p.read_text().replace("**Status:** done", "**Status:** ready", 1))\n')
    refused(lambda:target['prepare'](policy,base/'manifest.json'),'prerequisite drift')
    assert not (base/'manifest.json').exists()
    assert json.loads((project/'.git/launch-queue/preparing-T-2.json').read_text())['status']=='preparing'
    assert (project/'.git/launch-prepared/T-2').is_dir()

# The real native wait callback must stop source drift even after admission.
with fixture() as (base, project, source, policy):
    selected_fixture(source,policy,'headings')
    output=base/'manifest.json';target['prepare'](policy,output)
    q=target['queue'].Queue(output);q.run(True);deadline=q.state['deadline']
    fake=base/'codex';trace=base/'requests.jsonl'
    fake.write_text('''#!/usr/bin/env python3
import json,pathlib,sys
if '--version' in sys.argv:
 print('synthetic-codex 1');sys.exit(0)
source=pathlib.Path('''+repr(str(source))+''')
trace=pathlib.Path('''+repr(str(trace))+''')
for line in sys.stdin:
 message=json.loads(line)
 with trace.open('a') as stream:stream.write(json.dumps(message.get('method'))+'\\n')
 if message.get('method')=='initialize':
  source.write_text(source.read_text().replace('**Status:** done','**Status:** ready',1))
  print(json.dumps({'id':message['id'],'result':{}}),flush=True)
''')
    fake.chmod(0o755)
    result=subprocess.run([sys.executable,str(SCRIPT.with_name('launch-queue.py')),'--manifest',str(output),'run'],
        env={**os.environ,'PATH':str(base)+os.pathsep+os.environ['PATH']},capture_output=True,text=True,timeout=30)
    assert result.returncode != 0 and 'prerequisite changed' in result.stderr, result.stderr
    state=json.loads(q.path.read_text());item=state['items'][0]
    assert state['admissions']==state['launches']==1 and state['deadline']==deadline
    assert item['status']=='blocked' and item['quiescence']['group']=='gone',item
    assert 'turn/start' not in [json.loads(line) for line in trace.read_text().splitlines()]
print('PASS: bounded source grammar, eligibility, retained generator failure and native source-drift closure')

# Unsupported columns must not silently discard source constraints.
with tempfile.TemporaryDirectory() as directory:
    source=Path(directory).resolve()/'BACKLOG.md'
    source.write_text('| ID | Item | Status | Tier | Notes |\n| T-2 | task | [ ] | P1 | prerequisite not represented |\n')
    refused(lambda:target['queue'].selected_backlog(source,{'format':'table'}),'unsupported table columns')

# Bound task text and prerequisite text/invalid rank cannot drift after initialization.
for old, new, phrase in [('| selected |','| changed |','source changed'),
                         ('| complete |','| completed differently |','prerequisite changed'),
                         ('| [x] | P1 |','| [x] | unknown |','prerequisite changed')]:
    with fixture() as (base, project, source, policy):
        selected_fixture(source,policy,'table')
        output=base/'manifest.json';target['prepare'](policy,output)
        q=target['queue'].Queue(output);q.run(True)
        source.write_text(source.read_text().replace(old,new))
        refused(lambda:q.run(),phrase)
        assert json.loads(q.path.read_text())['launches']==0
print('PASS: selected task and completed-prerequisite record drift')


# Completion changes only one selected status cell, including original CRLF bytes.
scope = {'format': 'table', 'heading': '# Selected'}
raw = ('préface\r\n# Selected\r\n| ID | Item | Status | Tier | Depends on |\r\n'
       '|---|---|---|---|---|\r\n| T-1 | done | [x] | P1 | none |\r\n'
       '| T-2 | selected \\| value |  [ ]  | P1.A | T-1 |\r\n'
       '| T-3 | later | [ ] | P1.B | T-2 |\r\n'
       '```\r\n| T-2 | fenced | [ ] | P1 | none |\r\n```\r\n'
       '# History\r\n| ID | Item | Status | Tier |\r\n'
       '| T-2 | historical | [ ] | P1 |\r\n').encode()
patched = target['queue'].complete_backlog(raw, scope, 'T-2')
assert patched == raw.replace(b'|  [ ]  |', b'|  Done  |', 1)
parsed = target['queue'].selected_backlog_text(patched.decode(), scope)
assert parsed['T-2']['status'] == 'done' and parsed['T-3']['depends'] == ['T-2']
refused(lambda: target['queue'].complete_backlog(patched, scope, 'T-2'), 'todo')
refused(lambda: target['queue'].complete_backlog(raw.replace(b'P1.A', b'unknown'), scope, 'T-2'), 'todo')
print('PASS: byte-exact selected source completion preserves fences, history, unicode and CRLF')


# LC-039 slice 2: a Claude policy prepares a review-free manifest. Publication stays Codex-only (D4).
CLAUDE_HOOK = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"'
LAUNCH = ['.claude/skills/launch/SKILL.md', *('.claude/skills/launch/references/' + n for n in
           ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md'))]


def claude_settings(events=('SessionStart', 'PreCompact', 'Stop', 'PreToolUse')):
    matchers = {'SessionStart': 'startup|resume|compact|clear'}
    return {'hooks': {e: [{**({'matcher': matchers[e]} if e in matchers else {}),
                           'hooks': [{'type': 'command', 'command': CLAUDE_HOOK, 'timeout': 10}]}] for e in events}}


@contextlib.contextmanager
def claude_fixture(settings=None, ignore='.claude/launch/\n.claude/hooks/launch.sh\nscripts/verify.sh\nlaunch-control-backups/\n',
                   untracked=()):
    with tempfile.TemporaryDirectory(prefix='launch-target-claude-') as directory:
        base = Path(directory).resolve()
        project = base / 'repo'
        project.mkdir()
        git(project, 'init', '-b', 'fixture')
        git(project, 'config', 'user.name', 'Fixture')
        git(project, 'config', 'user.email', 'fixture@example.invalid')
        (project / '.gitignore').write_text(ignore)
        (project / 'tracked').write_text('fixture')
        source = project / 'BACKLOG.md'
        source.write_text('## P1\n### T-2 - selected\n**Status:** ready\n')
        (project / '.claude').mkdir()
        (project / '.claude/settings.json').write_text(json.dumps(claude_settings() if settings is None else settings))
        for name in LAUNCH:
            (project / name).parent.mkdir(parents=True, exist_ok=True)
            (project / name).write_text(name + '\n')
        git(project, 'add', '--', *[p for p in ('.gitignore', 'tracked', 'BACKLOG.md', '.claude/settings.json', *LAUNCH) if p not in untracked])
        git(project, 'commit', '-m', 'fixture')
        config = base / 'verify.json'
        config.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'test -f tracked', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
        runtime = ROOT / 'skills/onboard/scripts/launch-runtime.py'
        policy = base / 'policy.json'
        policy.write_text(json.dumps({'schema': 1, 'platform': 'claude', 'project': str(project), 'base_revision': git(project, 'rev-parse', 'HEAD'),
            'source': {'path': 'BACKLOG.md'}, 'scope_template': 'Fix {id}; write acceptance at {gitdir}/acceptance.json.',
            'caps': {'minutes': 10, 'max_attempts': 2, 'rollover': {'threshold': 65, 'max_launches': 1, 'synchronous_commands': ['git status --short']}},
            'generator': {'argv': [sys.executable, '-I', str(runtime), '--project', '{worktree}', '--platform', 'claude',
                                   'render-overlay', '--from-config', str(config)]}}))
        yield base, project, source, policy


with claude_fixture() as (base, project, source, policy):
    output = base / 'manifest.json'
    cfg = target['prepare'](policy, output)
    worktree = Path(cfg['items'][0]['worktree'])
    assert cfg['platform'] == 'claude' and cfg['native_review'] is False and 'controller' not in cfg, cfg
    assert cfg['rollover']['max_launches'] == 1 and 'delivery' not in cfg
    assert cfg['preparation']['verify_digest'] == hashlib.sha256((base / 'verify.json').read_bytes()).hexdigest()
    assert (worktree / '.claude/launch/verify.json').read_bytes() == (base / 'verify.json').read_bytes()
    assert not git(worktree, 'status', '--porcelain')
    q = target['queue'].Queue(output)
    q.run(True)
    assert q.state['launches'] == 0
    assert 'independent review' not in q.prompt({**q.state['items'][0], 'source': {'text': ''}})
    target['queue'].validate_claude_overlay(worktree)
    # The generator never overwrites: a second render into the same worktree is refused.
    argv = [str(worktree) if a == '{worktree}' else a for a in json.loads(policy.read_text())['generator']['argv']]
    again = subprocess.run(argv, capture_output=True, text=True)
    assert again.returncode != 0 and 'exists' in again.stderr, again.stderr
    # Admission binds the checks recorded at preparation; an ignored verify.json edit leaves status clean.
    (worktree / '.claude/launch/verify.json').write_text(json.dumps({'schema': 1, 'checks': [{'command': 'true', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
    assert not git(worktree, 'status', '--porcelain')
    refused(lambda: q.run(), 'checks changed')
    assert json.loads(q.path.read_text())['launches'] == 0

with claude_fixture() as (base, project, source, policy):
    output = base / 'manifest.json'
    target['prepare'](policy, output)
    manifest = json.loads(output.read_text())
    del manifest['rollover']
    manifest['command'] = ['true', '{session}', '{prompt}']  # The gate-less local() shape.
    output.write_text(json.dumps(manifest))
    refused(lambda: target['queue'].Queue(output).validate_preparation(), 'Claude rollover')

for name, change, phrase in [
    ('platform', {'platform': 'gemini'}, 'invalid target platform'),
    ('delivery', {'delivery': {'grant': '/nonexistent', 'digest': '0' * 64}}, 'Claude delivery'),
]:
    with claude_fixture() as (base, project, source, policy):
        data = json.loads(policy.read_text()); data.update(change); policy.write_text(json.dumps(data))
        refused(lambda: target['prepare'](policy, base / 'manifest.json'), phrase)
        assert not (project / '.git/launch-prepared').exists(), name

for options, phrase in [
    ({'untracked': ('.claude/settings.json',)}, 'tracked Claude file'),
    ({'untracked': (LAUNCH[2],)}, 'tracked Claude file'),
    ({'ignore': 'scripts/verify.sh\nlaunch-control-backups/\n'}, 'explicit generated ignore rules required'),
    ({'settings': {}}, 'missing or duplicate autonomy hook'),
    ({'settings': claude_settings(('SessionStart', 'PreCompact', 'Stop'))}, 'all-tool PreToolUse'),
]:
    with claude_fixture(**options) as (base, project, source, policy):
        refused(lambda: target['prepare'](policy, base / 'manifest.json'), phrase)
        assert not (base / 'manifest.json').exists(), options
print('PASS: Claude preparation admits a review-free manifest and refuses untracked, unignored or ungated overlays')

# The Claude relaxation never admits a Codex preparation without native review.
with fixture() as (base, project, source, policy):
    output = base / 'manifest.json'
    manifest = target['prepare'](policy, output)
    manifest['native_review'] = False
    output.write_text(json.dumps(manifest))
    refused(lambda: target['queue'].Queue(output).validate_preparation(), 'preparation requires one reviewed local task')
print('PASS: a Codex preparation without native review stays refused')

with claude_fixture() as (base, project, source, policy):
    (project / 'scripts').mkdir()
    (project / 'scripts/verify.sh').write_text('user-owned')
    render = subprocess.run([sys.executable, '-I', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'), '--project', str(project),
                             '--platform', 'claude', 'render-overlay', '--from-config', str(base / 'verify.json')], capture_output=True, text=True)
    assert render.returncode != 0 and 'already exists: scripts/verify.sh' in render.stderr, render.stderr
    assert not (project / '.claude/hooks/launch.sh').exists() and not (project / '.claude/launch').exists()
    assert (project / 'scripts/verify.sh').read_text() == 'user-owned'
print('PASS: render-overlay refuses before writing when any generated file exists')
