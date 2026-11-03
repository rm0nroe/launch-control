#!/usr/bin/env python3
"""Mission controller over fake GitHub and fake children; never contacts a model or network."""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('launch_mission', ROOT / 'skills/onboard/scripts/launch-mission.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
queue, rt = m.queue, m.rt
HEADING = '# Mission'
SOURCE = {'path': 'BACKLOG.md', 'format': 'table', 'heading': HEADING}
REF = '/pack/references/launch-autonomy.md'  # Derived from the template's --autonomy-controller.
TABLE = HEADING + '\n| ID | Item | Status | Tier |\n|---|---|---|---|\n| T-1 | first | Todo | P1 |\n| T-2 | second | Todo | P2 |\n'


def sha(text):
    return hashlib.sha1(text.encode()).hexdigest()


def refused(callback, phrase):
    try:
        callback()
    except rt.Invalid as error:
        assert phrase in str(error), (phrase, str(error))
        return
    raise AssertionError('accepted: ' + phrase)


class GitHub:
    """Commits on main, each with a parent list and the BACKLOG bytes at that commit."""
    def __init__(self, source):
        self.commits = {'c0': {'parents': [], 'source': source}}
        self.head, self.reads, self.prs = 'c0', 0, {}

    def commit(self, name, source, parents=None):
        self.commits[name] = {'parents': parents or [self.head], 'source': source}
        self.head = name

    def __call__(self, endpoint):
        self.reads += 1
        if endpoint.endswith('/commits/main'):
            return {'sha': self.head}
        if '/contents/BACKLOG.md?ref=' in endpoint:
            raw = self.commits[endpoint.rsplit('=', 1)[1]]['source'].encode()
            return {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(raw).decode(), 'sha': m.delivery.git_blob(raw)}
        if '/commits?path=BACKLOG.md&sha=main' in endpoint:
            # Newest first-parent commit that changed the file, as GitHub's path filter reports.
            name = self.head
            while self.commits[name]['parents']:
                parent = self.commits[name]['parents'][0]
                if parent not in self.commits or self.commits[parent]['source'] != self.commits[name]['source']:
                    break
                name = parent
            return [{'sha': name, 'parents': [{'sha': p} for p in self.commits[name]['parents']]}]
        if '/pulls/' in endpoint:
            return self.prs[int(endpoint.rsplit('/', 1)[1])]
        if '/compare/' in endpoint:
            return {'status': 'ahead', 'behind_by': 0}
        if '/commits/' in endpoint:
            return {'commit': {'tree': {'sha': 'tree-' + endpoint.rsplit('/', 1)[1]}}}
        raise AssertionError('unexpected read ' + endpoint)


def fixture(directory, source=TABLE, caps=None):
    base = Path(directory)
    policy = {'schema': 1, 'project': '/template/original', 'base_revision': 'c0', 'source': SOURCE,
              'scope_template': 'template scope', 'generator': {'argv': ['/py', '-I', 'gen.py', '--autonomy-shared-root', '/template/ws', '--project', '{worktree}',
                                                   '--autonomy-controller', '/pack/scripts/launch-runtime.py']},
              'caps': {'minutes': 20, 'max_attempts': 2, 'rollover': {'threshold': 65, 'max_launches': 2, 'synchronous_commands': ['git status']}}}
    grant = {'schema': 1, 'target_digest': 'x', 'verification': {'schema': 1, 'checks': [{'command': 'true', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']},
             'repository': 'fixture/repo', 'base_branch': 'main', 'base_revision': 'c0', 'source': {**SOURCE, 'blob': 'b0'},
             'workspace': '/template/ws', 'host_policy': {'path': '/host.json', 'digest': '0' * 64},
             'allowed_actions': ['prepare', 'implement', 'review', 'push', 'pull_request', 'publish', 'source_done'],
             'publication': {'mode': 'github-base-lease', 'deployment': 'none', 'required_checks': [], 'billing_fallback': False},
             'minutes': 20, 'max_attempts': 2, 'max_launches': 2}
    (base / 'policy.json').write_text(json.dumps(policy))
    (base / 'grant.json').write_text(json.dumps(grant))
    # LC-030: the mission is planned from the section, never hand-written.
    config = {'repository': 'fixture/repo', 'base_branch': 'main', 'source': {'path': 'BACKLOG.md', 'heading': HEADING},
              'template': {'policy': str(base / 'policy.json'), 'grant': str(base / 'grant.json')},
              'caps': caps or {'minutes': 60, 'max_attempts': 4, 'max_launches': 4, 'max_tokens': 1000,
                               'task_minutes': 20, 'task_max_attempts': 2, 'task_max_launches': 2}}
    (base / 'project.json').write_text(json.dumps(config))
    path = base / 'mission.json'
    planned = m.Mission(base / 'planner', reader=GitHub(source)).plan(base / 'project.json', path)
    assert planned['digest'] == rt.digest(path.read_bytes())
    return path, planned['digest'], policy, grant, json.loads(path.read_text())


def child_state(ident, outcome, status, attempts=1, launches=1, tokens=100, record=None, deadline=None):
    item = {'id': ident, 'status': status, 'attempts': attempts, 'quiescence': {'group': 'gone', 'known_descendants': [], 'process': 'exited'}}
    if record:
        item['delivery'] = record
    if status == 'blocked':
        item['reason'] = 'synthetic repair budget exhausted'
    return {'outcome': outcome, 'items': [item], 'admissions': 1, 'launches': launches, 'tokens': tokens,
            'deadline': deadline or time.time() + 60}


def make_spawn(mission, github, plan, number=[0]):
    """plan[id] -> 'deliver' | 'blocked' | 'signal' | 'nostate' | 'pending' | 'foreign' | callable."""
    calls = []
    def spawn(ident, lock_fd):
        calls.append(ident)
        action = plan[ident].pop(0) if isinstance(plan[ident], list) else plan[ident]
        qdir = mission.child(ident) / 'repo/.git/launch-queue'
        if action == 'nostate':
            return 1
        qdir.mkdir(parents=True, exist_ok=True)
        if action == 'signal':
            rt.atomic(qdir / 'active.json', child_state(ident, None, 'running', tokens=50))
            return -9
        if action == 'blocked':
            rt.atomic(qdir / 'active.json', child_state(ident, 'dependency_blocked', 'blocked', attempts=2, tokens=300))
            return 1
        if action == 'capped':  # Queue refused a replacement at the token soft cap: status stays handoff.
            (mission.child(ident) / 'child.log').write_text('{"error": "token soft cap reached: no new work after 900 tokens"}\n')
            rt.atomic(qdir / 'active.json', child_state(ident, None, 'handoff', tokens=1000))
            return 2
        if action == 'publication':
            state = child_state(ident, 'dependency_blocked', 'publication_pending')
            rt.atomic(qdir / 'active.json', state)
            return 1
        if action == 'child_paused':
            (qdir / 'PAUSE').write_text('paused\n')
            rt.atomic(qdir / 'active.json', child_state(ident, None, 'paused'))
            return 1
        number[0] += 1
        merge = 'm-' + ident
        source = github.commits[github.head]['source']
        github.commit(merge, source)
        record_state = 'delivered'
        if action == 'pending':
            rt.atomic(qdir / 'active.json', child_state(ident, 'merged_source_pending', 'merged_source_pending'))
            return 1
        done = queue.complete_backlog(source.encode(), SOURCE, ident).decode()
        github.commit('w-' + ident, done, parents=['other'] if action == 'foreign_parent' else [merge])
        if action == 'foreign':
            github.commit('foreign-' + ident, done)
        blob = m.delivery.git_blob(done.encode())
        record = {'stage': record_state, 'verified': True, 'post_merge': {'ok': True, 'revision': merge},
                  'source_receipt': {'merge': merge, 'blob': blob}, 'merge': {'commit': merge, 'tree': 'tree-' + merge},
                  'candidate': {'revision': 'cand-' + ident, 'tree': 'tree-' + merge}, 'rediscovery': {'source_blob': blob},
                  'pr': {'number': number[0]}}
        github.prs[number[0]] = {'merged': True, 'merge_commit_sha': merge, 'head': {'sha': 'cand-' + ident}}
        rt.atomic(qdir / 'active.json', child_state(ident, 'selected_task_delivered', 'delivered', record=record))
        return 0
    spawn.calls = calls
    return spawn


def run(mission):
    try:
        return mission.run()
    except m.StopMission as stopped:
        return stopped.state


def scenario(plan, source=TABLE, caps=None, setup=None):
    directory = tempfile.TemporaryDirectory(prefix='launch-mission-')
    path, digest, policy, grant, spec_ = fixture(directory.name, source, caps)
    github = GitHub(source)
    root = Path(directory.name) / 'state'
    mission = m.Mission(root, reader=github)
    mission.spawn = make_spawn(mission, github, plan)
    mission.init(path, digest)
    if setup:
        setup(mission, github)
    return directory, mission, github, (path, digest, policy, grant, spec_)


# 1. Two tasks deliver in order with no operator step; the chain base advances to each writeback.
d, mission, github, (path, digest, policy, grant, spec_) = scenario({'T-1': 'deliver', 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'complete', state
assert [t['status'] for t in state['tasks']] == ['delivered', 'delivered']
assert mission.spawn.calls == ['T-1', 'T-2']
second = rt.read_json(mission.child('T-2') / 'grant.json')
assert second['base_revision'] == 'w-T-1' and state['chain_base'] == 'w-T-2'
first_policy = rt.read_json(mission.child('T-1') / 'policy.json')
assert first_policy['scope_template'] == m.SCOPE + REF + m.ROW + 'first' and first_policy['generator']['argv'][4] == str(mission.child('T-1') / 'repo')
assert first_policy['caps']['rollover']['synchronous_commands'] == list(m.BASELINE)
assert first_policy['delivery']['digest'] == rt.digest((mission.child('T-1') / 'grant.json').read_bytes())
assert second['max_tokens'] == 900, 'second child budget excludes the first child tokens'
assert mission.used() == {'attempts': 2, 'launches': 2, 'tokens': 200}
d.cleanup()

# 2. The closed derivation refuses any change outside the listed fields.
with tempfile.TemporaryDirectory() as directory:
    path, digest, policy, grant, spec_ = fixture(directory)
    limits = {'minutes': 20, 'max_attempts': 2, 'max_launches': 2, 'max_tokens': 1000}
    p, g = m.derive(spec_, policy, grant, spec_['tasks'][0], 'c0', 'b0', Path(directory) / 'child', limits)
    for document, mutate, phrase in [
            ('grant', lambda x: x['allowed_actions'].append('deploy'), 'derived grant'),
            ('grant', lambda x: x['publication'].update(deployment='production'), 'derived grant'),
            ('grant', lambda x: x['verification']['checks'].clear(), 'derived grant'),
            ('policy', lambda x: x['caps']['rollover'].update(threshold=70), 'derived policy'),
            ('policy', lambda x: x['generator']['argv'].__setitem__(0, '/evil'), 'derived generator'),
            ('policy', lambda x: x['generator']['argv'].append('--extra'), 'derived generator')]:
        dp, dg = copy.deepcopy(p), copy.deepcopy(g)
        mutate(dg if document == 'grant' else dp)
        refused(lambda: m.assert_closed(policy, grant, dp, dg), phrase)
    from unittest.mock import patch
    with patch.object(m, 'assert_closed', side_effect=rt.Invalid('closed check ran')):
        refused(lambda: m.derive(spec_, policy, grant, spec_['tasks'][0], 'c0', 'b0', Path(directory) / 'child', limits), 'closed check ran')
print('PASS: two-task delivery, chain base, budgets and closed derivation')

# 3. A foreign commit between tasks stops the run before the second task.
d, mission, github, _ = scenario({'T-1': 'foreign', 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'blocked' and 'base drift' in state['reason'] and mission.spawn.calls == ['T-1'], state
d.cleanup()

# 4. A writeback whose parent is not the task merge is refused.
d, mission, github, _ = scenario({'T-1': 'foreign_parent', 'T-2': 'deliver'})
refused(mission.run, 'source writeback parent is not the task merge')
assert mission.spawn.calls == ['T-1']
d.cleanup()

# 5. init refuses a digest mismatch, a task outside the section and a reordered mission.
with tempfile.TemporaryDirectory() as directory:
    path, digest, policy, grant, spec_ = fixture(directory)
    refused(lambda: m.Mission(Path(directory) / 's', reader=GitHub(TABLE)).init(path, '0' * 64), 'digest differs')
    swapped = dict(spec_, tasks=list(reversed(spec_['tasks'])))
    path.write_text(json.dumps(swapped))
    refused(lambda: m.Mission(Path(directory) / 's', reader=GitHub(TABLE)).init(path, rt.digest(path.read_bytes())), 'differs from the plan')
    extra = TABLE + '| T-3 | third | Todo | P3 |\n'
    path.write_text(json.dumps(spec_))
    refused(lambda: m.Mission(Path(directory) / 's', reader=GitHub(extra)).init(path, rt.digest(path.read_bytes())), 'differs from the plan')
    edited = dict(spec_, tasks=[dict(spec_['tasks'][0], scope_template='Fix T-1'), spec_['tasks'][1]])
    path.write_text(json.dumps(edited))
    refused(lambda: m.Mission(Path(directory) / 's', reader=GitHub(TABLE)).init(path, rt.digest(path.read_bytes())), 'differs from the plan')
    path.write_text(json.dumps(spec_))
    summary = m.Mission(Path(directory) / 's', reader=GitHub(TABLE)).init(path, rt.digest(path.read_bytes()), dry_run=True)
    assert summary['tasks'] == ['T-1', 'T-2'] and 'no new task' in summary['token_soft_cap'] and not (Path(directory) / 's').exists()
print('PASS: foreign base, writeback parent, init digest/order/selection refusals and dry-run disclosure')

# 6. A child killed by a signal leaves the task reserved; the next run resumes it once.
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': ['signal', 'deliver']})
state = run(mission)
assert state['outcome'] == 'error' and mission.task('T-2')['status'] == 'reserved', state
deadline = state['deadline']
again = m.Mission(mission.root, reader=github)
again.spawn = mission.spawn
state = run(again)
assert state['outcome'] == 'complete' and state['deadline'] == deadline, state
assert again.task('T-2')['dispatches'] == 2 and mission.spawn.calls == ['T-1', 'T-2', 'T-2']
d.cleanup()

# 7. A dispatch that left no child state is never replayed; reconcile blocks it and the run continues.
d, mission, github, _ = scenario({'T-1': 'nostate', 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'blocked' and 'reconcile T-1' in state['reason'], state
state = run(m.Mission(mission.root, reader=github))
assert state['outcome'] == 'blocked' and mission.spawn.calls == ['T-1'], 'retained dispatch replayed'
mission.reconcile('T-1')
again = m.Mission(mission.root, reader=github)
again.spawn = mission.spawn
state = run(again)
assert state['outcome'] == 'blocked' and [t['status'] for t in state['tasks']] == ['blocked', 'delivered'], state
d.cleanup()

# 8. A blocked first task does not stop an independent second task; its usage still counts.
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'})
state = run(mission)
assert [t['status'] for t in state['tasks']] == ['blocked', 'delivered'] and state['outcome'] == 'blocked', state
assert mission.task('T-1')['reason'] == 'synthetic repair budget exhausted'
second = rt.read_json(mission.child('T-2') / 'grant.json')
assert second['max_attempts'] == 2 and second['max_tokens'] == 700, 'run caps include the blocked child usage'
d.cleanup()

# 9. Run-level limits stop before the next task, naming the limit.
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'},
    caps={'minutes': 60, 'max_attempts': 4, 'max_launches': 4, 'max_tokens': 300,
          'task_minutes': 20, 'task_max_attempts': 2, 'task_max_launches': 2})
state = run(mission)
assert state['outcome'] == 'paused' and 'max_tokens' in state['reason'] and mission.spawn.calls == ['T-1'], state
d.cleanup()
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'},
    caps={'minutes': 60, 'max_attempts': 2, 'max_launches': 4, 'max_tokens': 1000,
          'task_minutes': 20, 'task_max_attempts': 2, 'task_max_launches': 2})
state = run(mission)
assert state['outcome'] == 'paused' and 'max_attempts' in state['reason'], state
d.cleanup()
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'},
    setup=lambda mission, github: (mission.state.update(deadline=time.time() + 30), mission.save()))
state = run(mission)
assert state['outcome'] == 'paused' and 'minutes' in state['reason'] and mission.spawn.calls == [], state
d.cleanup()

# 10. Pause stops before the next task and reaches the active child's queue.
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'})
original = mission.spawn
def pausing(ident, lock_fd):
    result = original(ident, lock_fd)
    mission.pause()
    return result
mission.spawn = pausing
state = run(mission)
assert state['outcome'] == 'paused' and original.calls == ['T-1'], state
d.cleanup()
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'})
mission.state['tasks'][0]['status'] = 'reserved'
(mission.child('T-1') / 'repo/.git/launch-queue').mkdir(parents=True)
mission.pause()
assert (mission.child('T-1') / 'repo/.git/launch-queue/PAUSE').exists() is False, 'pause reads saved state, not memory'
mission.save()
mission.pause()
assert (mission.child('T-1') / 'repo/.git/launch-queue/PAUSE').exists()
d.cleanup()

# 11. A crash between freezing inputs and writing the marker dispatches with frozen inputs only.
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'})
mission.load()
head, blob, raw = mission.remote()
mission.reserve(mission.task('T-1'), head, blob, raw, mission.limits()[0])
reads = github.reads
again = m.Mission(mission.root, reader=github)
again.spawn = mission.spawn
first_reads = []
def spawn_once(ident, lock_fd):
    first_reads.append(github.reads - reads)
    return mission.spawn(ident, lock_fd)
again.spawn = spawn_once
assert run(again)['outcome'] == 'complete'
assert first_reads[0] == 0, 'frozen dispatch re-read GitHub'
d.cleanup()

# 12. A merged task with an unconfirmed Done write stops as merged_source_pending.
d, mission, github, _ = scenario({'T-1': 'pending', 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'merged_source_pending' and mission.spawn.calls == ['T-1'], state
d.cleanup()
print('PASS: signal resume, unreplayed dispatch and reconcile, blocked-task continuation, run limits, pause, frozen dispatch and merged_source_pending')

# 13. A task that depends on a blocked task is blocked without running.
DEPENDENT = HEADING + '\n| ID | Item | Status | Tier | Depends on |\n|---|---|---|---|---|\n| T-1 | first | Todo | P1 | none |\n| T-2 | second | Todo | P2 | T-1 |\n'
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'}, source=DEPENDENT)
state = run(mission)
assert state['outcome'] == 'blocked' and mission.spawn.calls == ['T-1'], state
assert mission.task('T-2')['status'] == 'blocked' and mission.task('T-2')['reason'] == 'dependency blocked'
d.cleanup()
print('PASS: dependency on a blocked task')

# 14. A child refused mid-task (token soft cap, status handoff) is blocked after the dispatch, never looped.
d, mission, github, _ = scenario({'T-1': 'capped', 'T-2': 'deliver'})
state = run(mission)
assert mission.task('T-1')['status'] == 'blocked' and 'token soft cap reached' in mission.task('T-1')['reason'], state
assert state['outcome'] == 'paused' and 'max_tokens' in state['reason'] and mission.spawn.calls == ['T-1'], state
d.cleanup()

# 15. An open or unconfirmed PR stops the run as publication_pending; it may still merge.
d, mission, github, _ = scenario({'T-1': 'publication', 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'publication_pending' and mission.task('T-1')['status'] == 'reserved', state
d.cleanup()

# 16. A paused child stays reserved; resume clears both pause files and the child resumes.
d, mission, github, _ = scenario({'T-1': ['child_paused', 'deliver'], 'T-2': 'deliver'})
state = run(mission)
assert state['outcome'] == 'paused' and mission.task('T-1')['status'] == 'reserved', state
mission.resume()
assert not list(mission.root.glob('tasks/*/repo/.git/launch-queue/PAUSE')) and not (mission.root / 'PAUSE').exists()
again = m.Mission(mission.root, reader=github)
again.spawn = mission.spawn
assert run(again)['outcome'] == 'complete' and mission.spawn.calls == ['T-1', 'T-1', 'T-2']
d.cleanup()

# 17. A crash after freezing inputs but before saving the reservation reuses the frozen inputs.
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'})
mission.load()
head, blob, raw = mission.remote()
frozen_limits = dict(mission.limits()[0], minutes=7)
(mission.child('T-1')).mkdir(parents=True)
m.exclusive(mission.child('T-1') / 'inputs.json', {'base': head, 'blob': blob, 'source': m.base64.b64encode(raw).decode(), 'limits': frozen_limits})
assert run(mission)['outcome'] == 'complete'
assert rt.read_json(mission.child('T-1') / 'grant.json')['minutes'] == 7, 'frozen limits replaced after a crash'
d.cleanup()

# 18. Run caps subtract earlier usage below the task cap, and launch exhaustion stops naming the limit.
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'},
    caps={'minutes': 60, 'max_attempts': 3, 'max_launches': 4, 'max_tokens': 1000,
          'task_minutes': 20, 'task_max_attempts': 3, 'task_max_launches': 2})
run(mission)
assert rt.read_json(mission.child('T-2') / 'grant.json')['max_attempts'] == 1, 'run attempts not subtracted'
d.cleanup()
d, mission, github, _ = scenario({'T-1': 'blocked', 'T-2': 'deliver'},
    caps={'minutes': 60, 'max_attempts': 4, 'max_launches': 1, 'max_tokens': 1000,
          'task_minutes': 20, 'task_max_attempts': 2, 'task_max_launches': 2})
state = run(mission)
assert state['outcome'] == 'paused' and 'max_launches' in state['reason'] and mission.spawn.calls == ['T-1'], state
d.cleanup()
print('PASS: capped child blocked once, publication_pending, child pause and resume, crash-safe reserve, run-cap subtraction and launch exhaustion')

# 19. Child minutes leave a preparation margin so the child queue deadline fits the mission's.
d, mission, github, _ = scenario({'T-1': 'deliver', 'T-2': 'deliver'},
    setup=lambda mission, github: (mission.state.update(deadline=time.time() + 245), mission.save()))
run(mission)
assert rt.read_json(mission.child('T-1') / 'grant.json')['minutes'] == 1, 'preparation margin not reserved'
assert [rt.read_json(mission.child(t) / 'policy.json')['task'] for t in ('T-1', 'T-2')] == ['T-1', 'T-2'], 'child task not pinned'
d.cleanup()
print('PASS: preparation margin')

# 20. The original clone checks out a tracked .agents tree, which Codex protects beneath a writable root.
with tempfile.TemporaryDirectory() as temporary:
    child, seen = Path(temporary), []
    admitted = {'host': {'git': 'git', 'gh': 'gh', 'read_roots': [], 'read_files': []},
                'grant': {'repository': 'o/r', 'base_branch': 'main'}}
    stub = {'load_binding': lambda binding: admitted, 'host_environment': lambda a: {}, 'tool_environment': lambda a: {},
            'run_owned': lambda command, cwd, env: ((Path(command[-1]) / '.git').mkdir(parents=True),
                                                    type('R', (), {'returncode': 0, 'stderr': b''})())[1]}

    def checkout(a, root, permissions, *args):
        seen.append(permissions)
        (root / 'BACKLOG.md').write_bytes(b'source')
        return type('R', (), {'returncode': 0})()
    saved = {name: getattr(m.delivery, name) for name in [*stub, 'restricted_git']}
    try:
        for name, value in {**stub, 'restricted_git': checkout}.items():
            setattr(m.delivery, name, value)
        m.clone_original(child, 'binding', 'c0', 'BACKLOG.md', b'source')
    finally:
        for name, value in saved.items():
            setattr(m.delivery, name, value)
    assert seen and seen[0].get(str(child / 'original/.agents')) == 'write', seen
print('PASS: original clone checks out a protected .agents tree')

# 21. LC-030 plan: Todo rows in priority order; every skip carries a reason; Done rows are ignored.
SECTION = HEADING + """
| ID | Item | Status | Tier | Depends on |
|---|---|---|---|---|
| A-1 | done thing | Done | P1 | none |
| A-2 | needs done A-1 | Todo | P3 | A-1 |
| A-3 | first | Todo | P2 | none |
| A-4 | ranked higher, waits for A-3 | Todo | P1 | A-3 |
| A-5 | outside done dep | Todo | P2 | Z-1 |
| A-6 | outside open dep | Todo | P2 | Z-2 |
| A-7 | transitive | Todo | P2 | A-5 |
| A-8 | cycle a | Todo | P2 | A-9 |
| A-9 | cycle b | Todo | P2 | A-8 |
| A-10 | not eligible | Blocked | P2 | none |
| A-11 | uses {braces} and {id} | Todo | P4 | none |
| A-12 | depends on not eligible | Todo | P2 | A-10 |
| A-13 |  | Todo | P2 | none |
| A-14 | after cycle | Todo | P2 | A-9 |
| A-15 | chain top | Todo | P2 | A-16 |
| A-16 | chain middle | Todo | P2 | A-17 |
| A-17 | chain bottom | Todo | P2 | Z-3 |
"""
records = queue.selected_backlog_text(SECTION, SOURCE)
tasks, skipped = m.select(records, REF)
assert [t['id'] for t in tasks] == ['A-4', 'A-3', 'A-2', 'A-11'], tasks
assert skipped == [  # Source row order.
    {'id': 'A-5', 'reason': 'depends on Z-1 outside the section'},
    {'id': 'A-6', 'reason': 'depends on Z-2 outside the section'},
    {'id': 'A-7', 'reason': 'depends on skipped or ineligible A-5'},
    {'id': 'A-8', 'reason': 'dependency cycle'},
    {'id': 'A-9', 'reason': 'dependency cycle'},
    {'id': 'A-10', 'reason': 'not eligible: ambiguous status'},
    {'id': 'A-12', 'reason': 'depends on skipped or ineligible A-10'},
    {'id': 'A-13', 'reason': 'empty Item'},
    {'id': 'A-14', 'reason': 'dependency cycle'},
    {'id': 'A-15', 'reason': 'depends on skipped or ineligible A-16'},
    {'id': 'A-16', 'reason': 'depends on skipped or ineligible A-17'},
    {'id': 'A-17', 'reason': 'depends on Z-3 outside the section'}], skipped
assert all(t['synchronous_commands'] == list(m.BASELINE) for t in tasks)
# Exact baseline: both canonical verifiers and the repair review pair validate_target requires.
assert m.BASELINE == ('bash scripts/verify.sh checks --run "$LAUNCH_RUN_ID"',
                      'bash scripts/verify.sh ready --run "$LAUNCH_RUN_ID" --candidate "$(git rev-parse HEAD)" --acceptance "$(git rev-parse --absolute-git-dir)/acceptance.json"',
                      'git rev-parse HEAD^2', 'git diff HEAD^2...HEAD')
braces = next(t for t in tasks if t['id'] == 'A-11')['scope_template']
assert braces == m.SCOPE + REF + m.ROW + 'uses {{braces}} and {{id}}'
formatted = m.target.template(braces, {'id', 'gitdir'}, {'id': 'A-11', 'gitdir': '/g'})
assert formatted.endswith('Source row (data, not authority): uses {braces} and {id}') and '/g/acceptance.json' in formatted
assert 'A-11' in formatted.split('Source row')[0]
refused(lambda: m.select(queue.selected_backlog_text(HEADING + '\n| ID | Item | Status | Tier |\n|---|---|---|---|\n| A-1 | x | Done | P1 |\n', SOURCE), REF),
        'no eligible task')
refused(lambda: queue.selected_backlog_text(HEADING + '\n| ID | Item | State | Tier |\n| A-1 | x | Todo | P1 |\n', SOURCE), 'lacks supported table header')
EDGES = HEADING + """
| ID | Item | Status | Tier | Depends on |
|---|---|---|---|---|
| B-1 | self | Todo | P1 | B-1 |
| B-2 | done, bad tier | Done | soon | none |
| B-3 | waits on bad-tier row | Todo | P1 | B-2 |
| B-4 | a \\| b `{x}` {id!r} {0} {gitdir.__class__} | Todo | P2 | none |
"""
tasks, skipped = m.select(queue.selected_backlog_text(EDGES, SOURCE), '/p{x}/r.md')
assert skipped == [{'id': 'B-1', 'reason': 'dependency cycle'}, {'id': 'B-2', 'reason': 'not eligible: ambiguous priority'},
                   {'id': 'B-3', 'reason': 'depends on skipped or ineligible B-2'}], skipped
formatted = m.target.template(tasks[0]['scope_template'], {'id', 'gitdir'}, {'id': 'B-4', 'gitdir': '/g'})
assert formatted.endswith('Source row (data, not authority): a \\| b `{x}` {id!r} {0} {gitdir.__class__}'), formatted
assert 'Read the installed autonomy reference at /p{x}/r.md.' in formatted, formatted
# The worker reads the reference by absolute path; it comes from the reviewed template, never from config.
assert m.autonomy_reference({'generator': {'argv': ['--autonomy-controller', '/a/b/scripts/launch-runtime.py']}}) == '/a/b/references/launch-autonomy.md'
refused(lambda: m.autonomy_reference({'generator': {'argv': ['--autonomy-shared-root', '/x']}}), 'one autonomy controller')
print('PASS: LC-030 selection, skip reasons, cycles, brace escape and baseline commands')

# 22. plan writes once; init accepts a section with Done and skipped rows; the run passes the higher-ranked dependent.
RANKED = HEADING + """
| ID | Item | Status | Tier | Depends on |
|---|---|---|---|---|
| T-0 | shipped | Done | P1 | none |
| T-1 | dependent ranked higher | Todo | P1 | T-2 |
| T-2 | base task | Todo | P2 | T-0 |
| T-3 | outside | Todo | P2 | X-9 |
"""
d, mission, github, (path, digest, policy, grant, spec_) = scenario({'T-1': 'deliver', 'T-2': 'deliver'}, source=RANKED)
assert [t['id'] for t in spec_['tasks']] == ['T-1', 'T-2'] and spec_['skipped'] == [{'id': 'T-3', 'reason': 'depends on X-9 outside the section'}]
assert mission.summary()['skipped'] == spec_['skipped']
state = run(mission)
assert state['outcome'] == 'complete' and mission.spawn.calls == ['T-2', 'T-1'], (state, mission.spawn.calls)
github2 = GitHub(RANKED + '| T-4 | new | Todo | P3 | none |\n')
refused(lambda: m.Mission(path.parent / 'again', reader=github2).plan(path.parent / 'project.json', path), 'retained mission file differs')
again = m.Mission(path.parent / 'again', reader=GitHub(RANKED)).plan(path.parent / 'project.json', path)
assert again['digest'] == digest, 'replanning the same source is idempotent'
altered = {**spec_, 'skipped': [{'id': 'T-3', 'reason': 'operator said so'}]}
path.write_text(json.dumps(altered))
refused(lambda: m.Mission(path.parent / 'other', reader=GitHub(RANKED)).init(path, rt.digest(path.read_bytes())), 'differs from the plan')
config = json.loads((path.parent / 'project.json').read_text())
(path.parent / 'wrong.json').write_text(json.dumps({**config, 'source': {'path': 'BACKLOG.md', 'heading': '# Other'}}))
refused(lambda: m.Mission(path.parent / 'other', reader=GitHub(RANKED)).plan(path.parent / 'wrong.json', path.parent / 'm2.json'),
        'template source or repository differs')
assert not (path.parent / 'm2.json').exists()
# The mission file appears whole or not at all; a symlink at the name is refused, never followed.
(path.parent / 'elsewhere').mkdir()
(path.parent / 'linked.json').symlink_to(path.parent / 'elsewhere' / 'm.json')
refused(lambda: m.Mission(path.parent / 'other', reader=GitHub(RANKED)).plan(path.parent / 'project.json', path.parent / 'linked.json'), 'unsafe state path')
assert not (path.parent / 'elsewhere' / 'm.json').exists() and not list(path.parent.glob('.*.tmp'))
(path.parent / 'missing.json').write_text(json.dumps({**config, 'template': {**config['template'], 'grant': str(path.parent / 'nope.json')}}))
refused(lambda: m.Mission(path.parent / 'other', reader=GitHub(RANKED)).plan(path.parent / 'missing.json', path.parent / 'm4.json'), 'invalid plan config')
(path.parent / 'badcaps.json').write_text(json.dumps({**config, 'caps': {**config['caps'], 'task_minutes': 61}}))
refused(lambda: m.Mission(path.parent / 'other', reader=GitHub(RANKED)).plan(path.parent / 'badcaps.json', path.parent / 'm3.json'), 'invalid mission caps')
assert not (path.parent / 'm3.json').exists(), 'an invalid mission must never be written'
for bad in ({**spec_, 'skipped': [{'id': 'T-1', 'reason': 'x'}]}, {**spec_, 'skipped': [{'id': 'T-3'}]},
            {**spec_, 'skipped': [{'id': 'T-3', 'reason': 'x'}, {'id': 'T-3', 'reason': 'y'}]},
            {**spec_, 'skipped': [{'id': 'T-3', 'reason': ''}]},
            {k: v for k, v in spec_.items() if k != 'skipped'}, {**spec_, 'scope_suffix': 'widen'}):
    path.write_text(json.dumps(bad))
    refused(lambda: m.read_mission(path, rt.digest(path.read_bytes())), 'invalid mission')
d.cleanup()
print('PASS: LC-030 plan idempotence, skipped schema, Done-row init and higher-ranked dependent order')

# Trust teardown: only what setup_native wrote, only while it still holds that value; a table empties whole.
W, K = '/w/ABC-1/repo', '/w/ABC-1/repo/.codex/hooks.json:stop:0:0'
records = [{'filePath': '/c', 'edits': [{'keyPath': '"projects"."%s"."trust_level"' % W, 'value': 'trusted', 'mergeStrategy': 'replace'}]},
           {'filePath': '/c', 'edits': [{'keyPath': '"hooks"."state"."%s"."trusted_hash"' % K, 'value': 'sha256:' + 'a' * 64, 'mergeStrategy': 'replace'}]}]
current = {'model': 'x', 'projects': {W: {'trust_level': 'trusted'}, '/keep': {'trust_level': 'trusted'}},
           'hooks': {'state': {K: {'trusted_hash': 'sha256:' + 'a' * 64}}}}
removals = m.trust_removals(current, records)
assert [e['keyPath'] for e in removals] == ['"projects"."%s"' % W, '"hooks"."state"."%s"' % K], removals
assert all(e['value'] is None and e['mergeStrategy'] == 'replace' for e in removals)
assert m.without(current, removals) == {'model': 'x', 'projects': {'/keep': {'trust_level': 'trusted'}}}
# Changed since setup (user distrust, rehashed hook), or already gone: left alone.
changed = copy.deepcopy(current)
changed['projects'][W]['trust_level'] = 'untrusted'
changed['hooks']['state'][K]['trusted_hash'] = 'sha256:' + 'b' * 64
assert m.trust_removals(changed, records) == []
assert m.trust_removals({'model': 'x'}, records) == []
# A table the user extended keeps the extra field; only the written leaf goes.
extended = copy.deepcopy(current)
extended['hooks']['state'][K]['enabled'] = True
assert [e['keyPath'] for e in m.trust_removals(extended, records)][1] == '"hooks"."state"."%s"."trusted_hash"' % K
assert m.without(extended, m.trust_removals(extended, records))['hooks'] == {'state': {K: {'enabled': True}}}
print('PASS: trust teardown removes only unchanged setup writes')
