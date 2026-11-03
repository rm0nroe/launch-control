#!/usr/bin/env python3
"""Disposable queue regression: real runtime receipts, synthetic worker, no services."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-queue.py'
spec = importlib.util.spec_from_file_location('queue_runtime', SCRIPT)
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()


def call(manifest, action, ok=True):
    p = subprocess.run([sys.executable, str(SCRIPT), '--manifest', str(manifest), action], capture_output=True, text=True)
    assert (p.returncode == 0) == ok, (p.stdout, p.stderr)
    return json.loads(p.stdout) if p.returncode == 0 else p.stderr


def fixture(base):
    root = base / 'repo'
    root.mkdir()
    git(root, 'init', '-b', 'main')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'BACKLOG.md').write_text('## P1 - Work\n### T-1 - First\n**Status:** open\n- [ ] nested acceptance\n### T-2 - Second\n**Status:** open\n')
    cfg = root / '.claude/launch/verify.json'
    cfg.parent.mkdir(parents=True)
    cfg.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'test -f BACKLOG.md', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
    git(root, 'add', '--', 'BACKLOG.md', '.claude/launch/verify.json')
    git(root, 'commit', '-m', 'fixture')
    worker = base / 'worker.py'
    worker.write_text('''import json,os,pathlib,subprocess,sys
runtime=sys.argv[1]
root=pathlib.Path.cwd()
def run(*args):
 p=subprocess.run([sys.executable,runtime,'--project',str(root),*args],capture_output=True,text=True)
 assert p.returncode==0,(p.stdout,p.stderr)
 return json.loads(p.stdout)
s=run('status','--run',os.environ['LAUNCH_RUN_ID'])
assert s['session']==sys.argv[2]
e={k:s[k] for k in ('repo','worktree','branch','run','task','revision','platform')}
e['evidence']={'behavior':'synthetic worker validates exact session and declared check; not model-driven proof'}
p=pathlib.Path(subprocess.check_output(['git','rev-parse','--absolute-git-dir'],text=True).strip())/'evidence.json'
p.write_text(json.dumps(e))
run('verify','ready','--run',s['run'],'--candidate',s['revision'],'--acceptance',str(p))
''')
    items = []
    for key in ('T-2', 'T-1'):
        wt = base / key
        git(root, 'worktree', 'add', '-b', key, str(wt))
        items.append({'id': key, 'priority': 1, 'worktree': str(wt), 'scope': 'Read-only fixture check.'})
    manifest = base / 'manifest.json'
    manifest.write_text(json.dumps({'schema': 1, 'project': str(root), 'source': {'kind': 'backlog', 'path': str(root / 'BACKLOG.md')}, 'items': items, 'minutes': 2, 'max_tasks': 2, 'max_launches': 2, 'max_attempts': 2, 'command': [sys.executable, str(worker), str(SCRIPT.with_name('launch-runtime.py')), '{session}', '{prompt}']}))
    return manifest, root


with tempfile.TemporaryDirectory(prefix='launch-queue-test-') as tmp:
    base = Path(tmp).resolve()
    manifest, root = fixture(base)
    state = call(manifest, 'init')
    deadline = state['deadline']
    lockpath = root / '.git/launch-queue/lock'
    with lockpath.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert 'already owned' in call(manifest, 'run', False)
    result = call(manifest, 'run')
    assert result['outcome'] == 'review_ready_publication_unsupported' and result['launches'] == 2
    assert all(i['publication'] == 'unsupported' for i in result['items'])
    order = sorted(result['items'], key=lambda x: x['receipt']['started'])
    assert [i['id'] for i in order] == ['T-1', 'T-2']
    assert call(manifest, 'run')['launches'] == 2  # restart cannot duplicate
    assert call(manifest, 'status')['deadline'] == deadline
    call(manifest, 'init', False)  # retained queue cannot reset budgets
    saved = root / '.git/launch-queue/active.json'
    interrupted = json.loads(saved.read_text())
    interrupted['items'][0]['status'] = 'running'
    saved.write_text(json.dumps(interrupted))
    assert 'interrupted admission' in call(manifest, 'run', False)
    saved.write_text(json.dumps(result))
    (base / 'T-1/BACKLOG.md').write_text('changed')
    assert 'candidate changed' in call(manifest, 'run', False)

for scenario in ('pause', 'changed', 'deadline', 'limit', 'interrupted', 'dependency', 'manifest'):
    with tempfile.TemporaryDirectory(prefix='launch-queue-test-') as tmp:
        base = Path(tmp).resolve()
        manifest, root = fixture(base)
        if scenario == 'dependency':
            with (root / 'BACKLOG.md').open('a') as f:
                f.write('**Depends on:** T-1\n')
        call(manifest, 'init')
        path = root / '.git/launch-queue/active.json'
        state = json.loads(path.read_text())
        if scenario == 'pause':
            call(manifest, 'pause')
        elif scenario == 'changed':
            with (root / 'BACKLOG.md').open('a') as f:
                f.write('changed scope')
        elif scenario == 'deadline':
            state['deadline'] = 0
        elif scenario == 'limit':
            state['launches'] = 2
        elif scenario == 'interrupted':
            state['items'][0]['status'] = 'admitting'
        elif scenario == 'manifest':
            data = json.loads(manifest.read_text())
            data['minutes'] = 3
            manifest.write_text(json.dumps(data))
        path.write_text(json.dumps(state))
        result = call(manifest, 'run', scenario == 'dependency')
        if scenario == 'dependency':
            assert result['outcome'] == 'dependency_blocked' and result['launches'] == 1

with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / 'BACKLOG.md'
    p.write_text('## P2\n| T-1 | task | [ ] |\n- [ ] T-99 nested\n| T-2 | task | [x] |\n')
    rows = q.backlog(p)
    assert set(rows) == {'T-1', 'T-2'} and rows['T-2']['status'] == 'done'
    original = rows['T-1']['digest']
    p.write_text('## P2\n| T-2 | task | [x] |\n| T-1 | task | [ ] |\n')
    assert q.backlog(p)['T-1']['digest'] == original
    with p.open('a') as f:
        f.write('| T-1 | duplicate | [ ] |\n')
    try:
        q.backlog(p)
        raise AssertionError('duplicate admitted')
    except q.rt.Invalid:
        pass
print('PASS: queue progression, retained claims, scope drift, dependency gate, pause, budgets, interrupted admission, and candidate invalidation')

# Native adapter contract: assignment only, persistent uncertain write reconciliation.
for uncertain in (False, 'assignment', 'configuration', 'ignored_configuration', 'unsafe_permissions', 'paused'):
    with tempfile.TemporaryDirectory(prefix='launch-native-test-') as tmp:
        base = Path(tmp).resolve()
        manifest, root = fixture(base)
        data = json.loads(manifest.read_text())
        data['source'] = {'kind': 'paperclip', 'company': 'fixture-company', 'api_base': 'http://fixture.invalid'}
        for item in data['items']:
            item.update(issue='uuid-' + item['id'], agent='agent-' + item['id'], priority=2)
        manifest.write_text(json.dumps(data))
        queue = q.Queue(manifest)
        launches, ready, configured = [], set(), set()
        persisted = {}
        def pc(*args):
            key = next((i for i in data['items'] if args[2] in (i['id'], i['issue'], i['agent'])), None)
            action = args[:2]
            if action == ('issue', 'get'):
                return {'id': key['issue'], 'identifier': key['id'], 'companyId': 'fixture-company', 'title': key['id'], 'description': 'fixture', 'priority': 'medium', 'status': 'in_review' if key['id'] in ready else 'todo', 'blockedBy': [], 'assigneeAgentId': key['agent'] if key['id'] in ready else None}
            if action == ('agent', 'get'):
                return json.loads(json.dumps({'companyId': 'fixture-company', 'status': 'paused' if uncertain == 'paused' else 'idle', 'adapterType': 'claude_local', 'adapterConfig': {'engine': 'cli', 'cwd': key['worktree'], 'instructionsBundleMode': 'managed'}, **persisted.get(key['id'], {})}))
            if action == ('agent', 'update'):
                assert uncertain != 'paused', 'paused agent was mutated'
                payload = json.loads(args[4])
                assert payload['runtimeConfig'] == {'heartbeat': {'enabled': False, 'wakeOnDemand': True, 'maxConcurrentRuns': 1, 'maxDailyRuns': 1}}
                if uncertain != 'ignored_configuration':
                    persisted[key['id']] = payload
                    payload['adapterConfig']['instructionsBundleMode'] = 'external'
                    if uncertain == 'unsafe_permissions':
                        payload['adapterConfig']['dangerouslySkipPermissions'] = True
                if uncertain == 'configuration' and not configured:
                    configured.add(key['id'])
                    raise q.rt.Invalid('uncertain configuration response')
                return {}
            if action == ('agent', 'pause'):
                return {}
            if action == ('issue', 'live-runs'):
                return []
            if action == ('issue', 'runs'):
                return [{'runId': key['id'], 'status': 'succeeded', 'invocationSource': 'assignment', 'agentId': key['agent']}] if key['id'] in ready else []
            assert action == ('issue', 'update'), args
            launches.append(key['id'])
            item = next(i for i in queue.state['items'] if i['id'] == key['id'])
            p = subprocess.run([sys.executable, str(base / 'worker.py'), str(SCRIPT.with_name('launch-runtime.py')), item['session']], cwd=key['worktree'], env={**os.environ, 'LAUNCH_RUN_ID': item['run']}, capture_output=True, text=True)
            assert p.returncode == 0, p.stderr
            ready.add(key['id'])
            if uncertain == 'assignment' and len(launches) == 1:
                raise q.rt.Invalid('uncertain assignment response')
            return {}
        queue.pc = pc
        queue.run(True)
        try:
            queue.run()
        except q.rt.Invalid as e:
            if uncertain in ('ignored_configuration', 'unsafe_permissions', 'paused'):
                assert ('not idle' if uncertain == 'paused' else 'configuration readback mismatch') in str(e), str(e)
                assert not launches
                continue
            assert uncertain and 'uncertain' in str(e), str(e)
            queue.run()
        assert uncertain not in ('ignored_configuration', 'unsafe_permissions', 'paused'), 'unsafe configuration launched a worker'
        assert launches == ['T-1', 'T-2']
        queue.run()
        assert launches == ['T-1', 'T-2']
print('PASS: native assignment contract and uncertain-write readback without duplicate launch (synthetic adapter)')

# Independent review never inherits the parent's mutating shell contracts.
import runpy
queue_ns = runpy.run_path(str(SCRIPT))
for command, allowed in [('git status --short', True), ('cat tracked', True),
                         ('git commit -m bad', False), ('git diff > file', False),
                         ('bash scripts/verify.sh checks', False)]:
    assert queue_ns['reviewer_shell'](command, [command]) is allowed
# LC-030: an unlisted read passes review by family; an unlisted mutation never does.
with tempfile.TemporaryDirectory() as tmp:
    for command, allowed in [('git log -5 --format=%s', True), ('cat tracked', True),
                             ('git add tracked', False), ('git push', False)]:
        assert queue_ns['reviewer_shell'](command, [], tmp) is allowed, command
        assert queue_ns['reviewer_shell'](command, []) is False, command
    # Both reviewer sites (native launch and publication readback) share this binding.
    manifest, root = fixture(Path(tmp).resolve())
    queue = q.Queue(manifest)
    queue.rollover = {'synchronous_commands': []}
    review = queue.reviewer_classifier({'worktree': str(root)})
    assert review('git log -5 --format=%s') and review('cat BACKLOG.md') and not review('git add BACKLOG.md')
# Structural pin: no suite drives a real reviewer subagent through the queue, so both reviewer
# sites must route through the tested binding rather than an inline classifier.
source = SCRIPT.read_text()
assert source.count('self.reviewer_classifier(item)') == 2 and source.count('reviewer_shell(') == 3, 'reviewer site bypasses reviewer_classifier'
command = 'bash /repo/.codex/hooks/launch.sh'
hooks = [{'key': e, 'eventName': e, 'matcher': m, 'command': command, 'enabled': True,
          'trustStatus': 'trusted', 'handlerType': 'command', 'timeoutSec': 10,
          'additionalContextLimit': 10000 if e == 'sessionStart' else None}
         for e, m in [('sessionStart', 'startup|resume|compact|clear'), ('preCompact', 'manual|auto'), ('stop', None)]]
inventory = {'data': [{'cwd': cwd, 'hooks': hooks, 'errors': []} for cwd in ('/repo', '/worktree')]}
assert queue_ns['trusted_hooks'](inventory, ['/repo', '/worktree'], command)
for field, value in [('enabled', False), ('trustStatus', 'untrusted'), ('key', 'different')]:
    bad = json.loads(json.dumps(inventory))
    bad['data'][1]['hooks'][0][field] = value
    try:
        queue_ns['trusted_hooks'](bad, ['/repo', '/worktree'], command)
        raise AssertionError('bad hook inventory passed')
    except queue_ns['rt'].Invalid:
        pass


# LC-039 D4: only Codex reaches the publication boundary; Claude, missing and invalid platforms stop
# at review-ready before any binding, Publisher, push, PR, merge or source-Done writeback.
class PublisherReached(Exception):
    pass


def guarded(platform, status, delivery=None):
    queue = object.__new__(q.Queue)
    queue.cfg = {} if platform is None else {'platform': platform}
    queue.state, queue.saves, queue.built = {'outcome': 'retained', 'launches': 1}, [], []
    queue.save = lambda: queue.saves.append(json.dumps(queue.state, sort_keys=True))

    class Delivery:
        def check_binding(self, _):
            return {'grant': {'publication': {}, 'allowed_actions': ['push', 'pull_request', 'publish', 'source_done']}}

        def Publisher(self, *args):
            queue.built.append(args)
            raise PublisherReached()
    queue.delivery = Delivery()
    item = {'id': 'T-1', 'status': status, **({'delivery': delivery} if delivery else {})}
    return queue, item


for platform in ('claude', None, '', 'Codex', 'codex '):
    queue, item = guarded(platform, 'awaiting_review')
    assert queue.publication(item, None) is False and queue.publication(item, None) is False
    assert queue.built == [] and item['status'] == 'awaiting_review' and item['publication'] == 'unsupported'
    assert len(queue.saves) == 1, 'repeated refusal wrote again'
    assert queue.state == {'outcome': 'retained', 'launches': 1}, 'refusal changed limits or outcome'
    for status, delivery in (('running', None), ('delivery_blocked', {'stage': 'pr'})):
        queue, item = guarded(platform, status, delivery)
        assert queue.publication(item, None) is False and queue.built == [] and queue.saves == []
        assert item['status'] == status and 'publication' not in item, 'unready work was promoted'
queue, item = guarded('codex', 'awaiting_review')
try:
    queue.publication(item, None)
    raise AssertionError('Codex no longer reaches the publication path')
except PublisherReached:
    pass
assert len(queue.built) == 1 and 'publication' not in item
print('PASS: publication boundary admits Codex only; Claude stops review-ready with publication unsupported')

# LC-039: a prepared Claude stop is recorded even when the worker corrupted its run state.
with tempfile.TemporaryDirectory(prefix='launch-queue-stop-') as tmp:
    base = Path(tmp).resolve()
    manifest, root = fixture(base)
    runtime = q.rt.Runtime(root, None, 'claude')
    runtime.base.mkdir(parents=True, exist_ok=True)
    runtime.state_path.write_text('{corrupt')
    stopped = q.Queue.stop_local(None, {'run': 'r', 'session': 's', 'attempts': 1}, runtime, 'pause', 'refused')
    assert stopped['status'] == 'blocked' and stopped['reason'].startswith('refused; run state unavailable') and stopped['session'] == 's'
print('PASS: a stop on corrupt prepared run state still records blocked')

# Target repo C run (2026-10-21): a repair reviewer requested after a checkpoint load never saw the
# verdict format, answered without "ship" and blocked delivery. Continuations carry the rule.
for review in (True, False):
    queue = object.__new__(q.Queue)
    queue.review, queue.rollover = review, {'synchronous_commands': ['git rev-parse HEAD^2']}
    text = queue.continuation({'scope': 'T-1 only'})
    assert text.startswith('Continue the existing Launch task') and 'Approved scope: T-1 only' in text
    assert ('Its final answer must start ship followed by the exact commit SHA' in text) is review, text
    assert ('never runs declared checks' in text) is review, text
print('PASS: checkpoint and repair continuations carry the review verdict and no-checks rules')
