#!/usr/bin/env python3
"""Publication authority and real Git lease regressions; no remote writes."""
import copy
import importlib.util
from pathlib import Path
import sys
import os
import shutil
import subprocess
import tempfile
from unittest.mock import patch
from types import SimpleNamespace

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-delivery.py'
spec = importlib.util.spec_from_file_location('delivery', SCRIPT)
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def refused(callback):
    try:
        callback()
    except ValueError:
        return
    raise AssertionError('unsafe publication accepted')


required = [{'name': 'validate', 'app_id': 1}]
run = {'id': 10, 'name': 'validate', 'app': {'id': 1}, 'head_sha': 'a' * 40,
       'status': 'completed', 'conclusion': 'success'}
assert d.check_conclusions(required, [run], [], lambda _: False) == 'passed'
assert d.check_conclusions([], [], [], lambda _: False) == 'not_declared'
for changed in ({'conclusion': 'failure'}, {'status': 'queued', 'conclusion': None},
                {'app': {'id': 2}}, {'name': 'other'}, {'conclusion': 'neutral'}):
    refused(lambda: d.check_conclusions(required, [{**run, **changed}], [], lambda _: False))
refused(lambda: d.check_conclusions(required, [], [], lambda _: False))
refused(lambda: d.check_conclusions(required, [run, run], [], lambda _: False))
refused(lambda: d.check_conclusions([], [run], [], lambda _: False))
refused(lambda: d.check_conclusions(required, [run], [{'context': 'legacy', 'state': 'pending'}], lambda _: False))
refused(lambda: d.check_conclusions(required, [run, {**run, 'id': 11, 'name': 'other', 'conclusion': 'failure'}], [], lambda _: False))
assert d.check_conclusions(required, [{**run, 'conclusion': 'failure'}], [], lambda _: True) == 'billing_unavailable'
skipped = {**run, 'id': 12, 'name': 'path-filtered', 'conclusion': 'skipped'}
assert d.check_conclusions(required, [run, skipped], [], lambda _: False) == 'passed'
refused(lambda: d.check_conclusions(required, [{**run, 'conclusion': 'skipped'}], [], lambda _: True))
refused(lambda: d.check_conclusions(required, [skipped], [], lambda _: False))
failed = {**run, 'id': 13, 'name': 'deploy', 'conclusion': 'failure'}
try:
    d.check_conclusions([], [], [], lambda _: False, observed=True)
except d.PublicationPending:
    pass
else:
    raise AssertionError('an empty merged-commit observation passed')
assert d.check_conclusions([], [run, {**run, 'id': 12, 'name': 'lint', 'conclusion': 'skipped'}], [], lambda _: False, observed=True) == 'passed'
assert d.check_conclusions([], [failed], [], lambda _: True, observed=True) == 'billing_unavailable'
refused(lambda: d.check_conclusions([], [failed], [], lambda _: False, observed=True))
refused(lambda: d.check_conclusions([], [], [{'context': 'Vercel', 'state': 'failure'}], lambda _: False, observed=True))
print('PASS: required and additional hosted checks fail closed before publication')

billing_message = ('The job was not started because recent account payments have failed or your spending limit '
                   'needs to be increased. Please check the Billing settings.')
notice = {'annotation_level': 'notice', 'message': 'The ubuntu-latest label will migrate to Ubuntu 26.'}
blocked = {'annotation_level': 'failure', 'message': billing_message}
def billing_publisher(annotations, steps=(), fallback=True):
    p = object.__new__(d.Publisher)
    p.grant = {'repository': 'fixture/repo', 'publication': {'billing_fallback': fallback}}
    p.prefix = 'repos/fixture/repo'
    p.api = lambda endpoint: {'head_sha': 'a' * 40, 'status': 'completed', 'conclusion': 'failure'}
    def rows(endpoint, key=None):
        if endpoint.endswith('/annotations'):
            return annotations
        return [{'id': 7, 'conclusion': 'failure', 'steps': list(steps),
                 'check_run_url': 'https://api.github.com/repos/fixture/repo/check-runs/9'}]
    p.rows = rows
    return p
check = {'id': 9, 'app': {'slug': 'github-actions'}, 'head_sha': 'a' * 40,
         'details_url': 'https://github.com/fixture/repo/actions/runs/5/job/7'}
assert billing_publisher([blocked]).billing(check) is True
assert billing_publisher([blocked, notice]).billing(check) is True
assert billing_publisher([blocked, {**notice, 'annotation_level': 'warning'}]).billing(check) is True
for annotations in ([], [notice], [blocked, {**notice, 'annotation_level': 'failure'}], [{**blocked, 'annotation_level': None, 'message': 'boom'}]):
    assert billing_publisher(annotations).billing(check) is False
assert billing_publisher([blocked], steps=[{'name': 'ran'}]).billing(check) is False
assert billing_publisher([blocked], fallback=False).billing(check) is False
refused(lambda: billing_publisher([blocked, 'not an annotation']).billing(check))
print('PASS: billing fallback needs zero steps and only billing failures; runner notices are ignored')

hosting = object.__new__(d.Publisher)
hosting.grant = {'publication': {'required_checks': [], 'billing_fallback': False}}
hosting.text = lambda *args: '.github/workflows/ci.yml'
hosting.rows = lambda endpoint, key=None: [{**run, 'name': 'ci'}] if 'check-runs' in endpoint else []
refused(lambda: hosting.hosted('a' * 40))
assert hosting.hosted('a' * 40, [])['status'] == 'passed'
refused(lambda: hosting.hosted('a' * 40, required))
hosting.text = lambda *args: ''
refused(lambda: hosting.hosted('a' * 40))
# A merged commit with no workflows and nothing hosted has nothing to wait for (WORK-31 run 4).
hosting.rows = lambda endpoint, key=None: []
assert hosting.hosted('a' * 40, [])['status'] == 'not_declared'
refused(lambda: hosting.hosted('a' * 40, required))
hosting.rows = lambda endpoint, key=None: [{**run, 'name': 'ci'}] if 'check-runs' in endpoint else []
assert hosting.hosted('a' * 40, [])['status'] == 'passed'
hosting.rows = lambda endpoint, key=None: [{'id': 3, 'context': 'Vercel', 'state': 'success'}] if 'statuses' in endpoint else []
assert hosting.hosted('a' * 40, [])['status'] == 'passed'
hosting.rows = lambda endpoint, key=None: []
hosting.text = lambda *args: '.github/workflows/ci.yml'
try:
    hosting.hosted('a' * 40, [])
except d.PublicationPending:
    pass
else:
    raise AssertionError('a merged commit with workflows passed before any hosted result')
print('PASS: an explicit empty post-merge list gates observed checks; omitted keeps the candidate contract')

# Exercise the production ordering: a hosted failure must precede the base intent.
for runs in ([], [{**run, 'status': 'queued', 'conclusion': None}], [{**run, 'conclusion': 'failure'}]):
    publisher = object.__new__(d.Publisher)
    candidate, base = 'a' * 40, 'b' * 40
    publisher.grant = {'workspace': '/fixture', 'publication': {'required_checks': required}}
    publisher.record = {'stage': 'reviewed', 'candidates': [], 'head_branch': 'task', 'head': candidate}
    publisher.queue = SimpleNamespace(save=lambda: None)
    publisher.check = lambda: None
    publisher.open_store = lambda: None
    publisher.review = lambda: {'revision': candidate, 'fingerprint': 'fingerprint'}
    publisher.verify = lambda *args: {'tree': 'c' * 40, 'fingerprint': 'fingerprint', 'ok': True}
    publisher.import_candidate = lambda revision: None
    publisher.fetch_base = lambda: base
    publisher.rules = lambda: base
    publisher.git = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, b'')
    publisher.branch_head = lambda: candidate
    publisher.pr_gate = lambda *args: None
    publisher.poll = lambda operation: operation()
    publisher.hosted = lambda revision, merge_checks=None: d.check_conclusions(required, runs, [], lambda _: False)
    writes = []
    publisher.write = lambda operation, *args: writes.append(operation)
    refused(publisher.run)
    assert writes == [] and 'merge' not in publisher.record
print('PASS: missing, pending and failed candidate CI produce zero base intents or writes')

# LC-030: workflows, generated Launch files and approved lockfiles are refused before any push.
locks = {'dependencies': [{'lockfile': 'ui/pnpm-lock.yaml'}]}
assert d.refused_candidate_paths(['.github/workflows/ci.yml', 'src/a.py', '.codex/x', '.claude/s.json', '.agents/skills/a',
                                  'scripts/verify.sh', 'ui/pnpm-lock.yaml', 'docs/.github/workflows/x', 'pnpm-lock.yaml',
                                  'scripts/verify.sh.bak', '.github/actions/x/action.yml', '.github/CODEOWNERS'], locks) == [
    '.github/workflows/ci.yml', '.codex/x', '.claude/s.json', '.agents/skills/a', 'scripts/verify.sh', 'ui/pnpm-lock.yaml',
    '.github/actions/x/action.yml', '.github/CODEOWNERS']
# APFS folds case: these name the protected paths on a macOS host.
folded = ['.CODEX/x', '.Claude/a', '.GitHub/workflows/ci.yml', 'Scripts/verify.sh', 'UI/pnpm-lock.yaml', '.AGENTS/s']
assert d.refused_candidate_paths(folded, locks) == folded
for touched in ('.github/workflows/ci.yml', 'ui/pnpm-lock.yaml', '.codex/skills/launch/SKILL.md', 'src/caf\u00e9.py\0.claude/x'):
    publisher = object.__new__(d.Publisher)
    candidate, base = 'a' * 40, 'b' * 40
    publisher.grant = {'workspace': '/fixture', 'publication': {'required_checks': required}, **locks}
    publisher.record = {'stage': 'reviewed', 'candidates': [], 'head_branch': 'task', 'head': ''}
    publisher.queue = SimpleNamespace(save=lambda: None)
    publisher.check = publisher.open_store = lambda: None
    publisher.review = lambda: {'revision': candidate, 'fingerprint': 'fingerprint'}
    publisher.verify = lambda *args: {'tree': 'c' * 40, 'fingerprint': 'fingerprint', 'ok': True}
    publisher.import_candidate = lambda revision: None
    publisher.fetch_base = publisher.rules = lambda: base
    diffs = []
    def git(*args, check=True, touched=touched):
        if args[0] == 'diff':
            diffs.append(args)
            return subprocess.CompletedProcess([], 0, ('src/a.py\0' + touched + '\0').encode())
        return subprocess.CompletedProcess([], 0, b'')
    publisher.git = git
    publisher.branch_head = lambda: ''
    writes = []
    publisher.write = lambda operation, *args: writes.append(operation)
    try:
        publisher.run()
        raise AssertionError('refused path published: ' + touched)
    except ValueError as error:
        assert 'candidate changes refused paths' in str(error), error
    assert writes == [] and diffs and diffs[0][-1] == base + '...' + candidate and '-z' in diffs[0], diffs
# Real git: a rename out of .github, a deletion and a mode-only change are all seen by the publisher's own diff.
with tempfile.TemporaryDirectory(prefix='publication-refusal-') as temporary:
    store = Path(temporary).resolve() / 'objects.git'
    git_bin = shutil.which('git')
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
           'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
    def real(*args, input=None, check=True):
        return subprocess.run([git_bin, '--git-dir=' + str(store), *args], input=input, env=env, capture_output=True)
    real('init', '--bare', '--template=', str(store))
    blob = real('hash-object', '-w', '--stdin', input=b'on: push\n').stdout.decode().strip()
    tool = real('hash-object', '-w', '--stdin', input=b'#!/bin/sh\n').stdout.decode().strip()
    def tree(entries):
        lines = []
        for path, mode, sha in entries:  # One directory level is enough for these fixtures.
            lines.append((path, mode, sha))
        nested = {}
        for path, mode, sha in lines:
            top, _, rest = path.partition('/')
            nested.setdefault(top, []).append((rest, mode, sha))
        rows = []
        for top, items in nested.items():
            if items[0][0]:
                rows.append('040000 tree ' + tree(items) + '\t' + top)
            else:
                rows.append(items[0][1] + ' blob ' + items[0][2] + '\t' + top)
        return real('mktree', input=('\n'.join(rows) + '\n').encode()).stdout.decode().strip()
    cases = [([('.github/workflows/ci.yml', '100644', blob)], [('src/ci.yml', '100644', blob)], '.github/workflows/ci.yml'),
             ([('.codex/hooks.json', '100644', blob), ('src/a', '100644', blob)], [('src/a', '100644', blob)], '.codex/hooks.json'),
             ([('scripts/verify.sh', '100644', tool)], [('scripts/verify.sh', '100755', tool)], 'scripts/verify.sh')]
    for before, after, expected in cases:
        base = real('commit-tree', tree(before), '-m', 'base').stdout.decode().strip()
        candidate = real('commit-tree', tree(after), '-p', base, '-m', 'candidate').stdout.decode().strip()
        publisher = object.__new__(d.Publisher)
        publisher.grant = {'workspace': '/fixture', 'publication': {'required_checks': required}}
        publisher.record = {'stage': 'reviewed', 'candidates': [], 'head_branch': 'task', 'head': ''}
        publisher.queue = SimpleNamespace(save=lambda: None)
        publisher.check = publisher.open_store = lambda: None
        publisher.review = lambda candidate=candidate: {'revision': candidate, 'fingerprint': 'fingerprint'}
        publisher.verify = lambda *args: {'tree': 'c' * 40, 'fingerprint': 'fingerprint', 'ok': True}
        publisher.import_candidate = lambda revision: None
        publisher.fetch_base = publisher.rules = lambda base=base: base
        publisher.git = real
        publisher.branch_head = lambda: ''
        writes = []
        publisher.write = lambda operation, *args: writes.append(operation)
        try:
            publisher.run()
            raise AssertionError('refused path published: ' + expected)
        except ValueError as error:
            assert 'candidate changes refused paths: ' + expected in str(error), error
        assert writes == []
print('PASS: candidates touching .github, generated Launch files or approved lockfiles never push, case-folded and by real git diff')

with tempfile.TemporaryDirectory(prefix='publication-lease-') as temporary:
    root = Path(temporary).resolve()
    store, remote = root / 'objects.git', root / 'remote.git'
    git_bin = shutil.which('git')
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
           'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
    def git(path, *args, input=None):
        return subprocess.run([git_bin, '--git-dir=' + str(path), *args], input=input,
                              env=env, capture_output=True, check=True).stdout.decode().strip()
    for path in (store, remote): git(path, 'init', '--bare', '--template=', str(path))
    tree = git(store, 'mktree', input=b'')
    base = git(store, 'commit-tree', tree, '-m', 'base')
    blob = git(store, 'hash-object', '-w', '--stdin', input=b'candidate\n')
    candidate_tree = git(store, 'mktree', input=('100644 blob ' + blob + '\ttracked\n').encode())
    candidate = git(store, 'commit-tree', candidate_tree, '-p', base, '-m', 'candidate')
    merge = git(store, 'commit-tree', candidate_tree, '-p', base, '-p', candidate, '-m', 'merge')
    publisher = object.__new__(d.Publisher)
    publisher.root, publisher.store, publisher.remote = root, store, str(remote)
    publisher.grant = {'base_branch': 'main'}
    publisher.record = {'head_branch': 'task'}
    publisher.admitted = {'host': {'git': git_bin, 'path': [str(Path(git_bin).parent), '/usr/bin', '/bin'],
                                   'read_roots': [], 'read_files': []}}
    dispatched = []
    def local_remote(*args, **kwargs):
        dispatched.append(args)
        return subprocess.run([git_bin, '--git-dir=' + str(store), *args], env=env, capture_output=True)
    publisher.remote_git = local_remote
    def local_sandbox(admitted, cwd, permissions, command, environment):
        return ['/usr/bin/env', '-i', *[k + '=' + v for k, v in environment.items()], *command]
    with patch.object(d, 'sandbox_command', local_sandbox):
        assert publisher.push_ref('main', '', base).returncode == 0
        assert publisher.push_ref('task', '', candidate).returncode == 0
        concurrent = git(store, 'commit-tree', tree, '-p', base, '-m', 'concurrent base')
        assert publisher.push_ref('main', base, concurrent).returncode == 0
        failed = publisher.push_ref('main', base, merge)
        assert failed.returncode != 0 and b'stale info' in failed.stderr
        assert git(remote, 'rev-parse', 'refs/heads/main') == concurrent
        before = len(dispatched)
        refused(lambda: publisher.push_ref('main', concurrent, candidate))
        assert len(dispatched) == before  # Ancestry fails before even a remote attempt.
        repaired = git(store, 'commit-tree', candidate_tree, '-p', candidate, '-p', concurrent, '-m', 'repaired candidate')
        verified_merge = git(store, 'commit-tree', candidate_tree, '-p', concurrent, '-p', repaired, '-m', 'verified merge')
        assert publisher.push_ref('task', candidate, repaired).returncode == 0
        assert publisher.push_ref('main', concurrent, verified_merge).returncode == 0
        assert git(remote, 'rev-parse', 'main') == verified_merge
        assert git(remote, 'rev-parse', 'main^{tree}') == candidate_tree
        assert git(remote, 'rev-list', '--parents', '-n', '1', verified_merge).split()[1:] == [concurrent, repaired]
        # A protected base refuses at the remote even if the rules read raced: no force, no resend.
        hook = remote / 'hooks/pre-receive'
        hook.parent.mkdir(exist_ok=True)
        hook.write_text('#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/main ] && '
                        '{ echo "protected branch hook declined" >&2; exit 1; }; done\nexit 0\n')
        hook.chmod(0o755)
        protected = git(store, 'commit-tree', candidate_tree, '-p', verified_merge, '-p', repaired, '-m', 'refused merge')
        publisher.record.update(intents=[], merge={'commit': protected, 'base': verified_merge, 'candidate': repaired,
                                                   'tree': candidate_tree, 'branch': 'main'}, pr={'number': 7})
        publisher.queue = SimpleNamespace(save=lambda: None)
        publisher.check = lambda action=None: None
        publisher.api = lambda endpoint: {'merged': False}
        publisher.fetch_base = lambda: git(remote, 'rev-parse', 'refs/heads/main')
        entry = publisher.write('base', publisher.record['merge'], 'publish',
                                lambda: publisher.push_ref('main', verified_merge, protected))
        assert entry['exit'] != 0 and 'protected branch hook declined' in entry['stderr'], entry
        assert git(remote, 'rev-parse', 'main') == verified_merge
        assert not any('--force' == arg or arg.startswith('+') for arg in dispatched[-1]), dispatched[-1]
        pushes = len(dispatched)
        # Refused with the base unchanged is final: block at once instead of polling to the deadline.
        try:
            publisher.acknowledge_merge()
            raise AssertionError('remote refusal acknowledged as a merge')
        except d.PublicationPending:
            raise AssertionError('remote refusal with an unchanged base polled as pending')
        except ValueError as error:
            assert 'remote refused the base push' in str(error), error
        def pending(**changes):
            saved = {key: entry[key] for key in changes}
            entry.update(changes)
            try:
                publisher.acknowledge_merge()
                raise AssertionError('uncertain base push not left pending')
            except d.PublicationPending:
                pass
            finally:
                entry.update(saved)
        pending(stderr='fatal: unable to access remote: timed out')  # Transport failure is not a refusal.
        fetch = publisher.fetch_base
        for moved in (repaired, protected):  # Base moved, or already holds the merge: readback, not a verdict.
            publisher.fetch_base = lambda: moved
            pending()
        publisher.fetch_base = fetch
        assert publisher.write('base', publisher.record['merge'], 'publish', None) is entry and len(dispatched) == pushes
print('PASS: real expected-base lease rejects races and history rewrites; verified two-parent tree publishes')
print('PASS: a remote protected-branch refusal is retained, never forced or resent, and blocks at once')

for interruption in ('none', 'response', 'expiry'):
    publisher = object.__new__(d.Publisher)
    publisher.record = {'intents': []}
    saved, calls = [], []
    def save(): saved.append(copy.deepcopy(publisher.record))
    publisher.queue = SimpleNamespace(save=save)
    def check(action):
        if interruption == 'expiry' and saved:
            raise ValueError('original deadline expired')
    publisher.check = check
    def mutation():
        calls.append('write')
        assert saved[-1]['intents'][0]['status'] == 'dispatching'
        if interruption == 'response': raise subprocess.TimeoutExpired('remote', 1)
        return subprocess.CompletedProcess([], 0, b'success', b'')
    identity = {'before': 'a' * 40, 'after': 'b' * 40, 'branch': 'main'}
    if interruption == 'expiry':
        refused(lambda: publisher.write('base', identity, 'publish', mutation))
        assert calls == []
    else:
        publisher.write('base', identity, 'publish', mutation)
        assert calls == ['write']
    publisher.write('base', identity, 'publish', mutation)
    assert len(calls) == (0 if interruption == 'expiry' else 1)
    assert len(publisher.record['intents']) == 1
    assert publisher.record['intents'][0]['status'] != 'acknowledged'
print('PASS: durable intent precedes mutation; uncertain responses and expiry never resend it')

with tempfile.TemporaryDirectory(prefix='publication-unknown-pr-') as temporary:
    publisher = object.__new__(d.Publisher)
    publisher.root = Path(temporary).resolve()
    publisher.grant = {'repository': 'fixture/repo', 'base_branch': 'main',
                       'source': {'heading': '## Mission: Heartbeat'},
                       'verification': {'checks': [{'command': 'make test', 'cwd': '.', 'timeout': 60},
                                                   {'command': 'pnpm lint', 'cwd': 'ui', 'timeout': 60}]}}
    publisher.prefix = 'repos/fixture/repo'
    publisher.record = {'head_branch': 'task', 'intents': []}
    scope = 'Worker prompt: read /Users/fixture/.git/launch/inputs.json'
    publisher.item = {'id': 'T-1', 'run': 'fixture-run', 'scope': scope,
                      'source': {'text': '| T-1 | **Ship the heartbeat.** Then the details. | [ ] | P1 |'}}
    publisher.queue = SimpleNamespace(hash='a' * 64, save=lambda: None)
    publisher.admitted = {'host': {'gh': '/fake/gh', 'path': ['/usr/bin', '/bin']}, 'grant': {'repository': 'fixture/repo'}}
    publisher.check = lambda action=None: None
    publisher.rows = lambda endpoint: []  # A late first creation is not yet visible.
    writes = []
    def uncertain(*args, **kwargs):
        writes.append(args[0])
        raise subprocess.TimeoutExpired('unknown creation outcome', 1)
    with patch.object(d, 'run_owned', uncertain):
        for _ in range(2):
            try:
                publisher.pull_request('b' * 40)
                raise AssertionError('absent uncertain PR acknowledged')
            except d.PublicationPending:
                pass
    assert len(writes) == 1 and len(publisher.record['intents']) == 1
    request = d._runtime['read_json'](publisher.root / 'pr-request.json')
    assert publisher.record['pr_request'] == d.canonical_digest(request)
    assert request['title'] == '[T-1] Ship the heartbeat', request['title']
    body = request['body']
    assert body.startswith('**Ship the heartbeat.** Then the details.\n'), body
    assert '- `make test`\n- `cd ui && pnpm lint`' in body and 'Review: Ship' in body, body
    assert 'Delivered by Launch Control · Mission Heartbeat\n\n<!-- launch-control-delivery:' in body, body
    assert scope not in body and '/Users/' not in body and 'Send It' not in body, body  # the old product name
    pr = {'number': 1, 'node_id': 'fixture', 'html_url': 'https://github.com/fixture/repo/pull/1',
          'title': request['title'], 'body': request['body'],
          'head': {'sha': 'b' * 40, 'ref': 'task', 'repo': {'full_name': 'fixture/repo'}},
          'base': {'ref': 'main', 'repo': {'full_name': 'fixture/repo'}}}
    for changed in ({'title': 'unapproved title'}, {'body': 'unapproved metadata\n' + request['body']}):
        publisher.rows = lambda endpoint: [pr]
        publisher.api = lambda endpoint: {**pr, **changed}
        refused(lambda: publisher.pull_request('b' * 40))
    publisher.rows = lambda endpoint: [pr]
    publisher.api = lambda endpoint: pr
    assert publisher.pull_request('b' * 40) == pr
print('PASS: absent PR after uncertain creation remains pending without duplicate creation')

assert d.row_title('| T-2 | Fix the clock drift. More words here. | [ ] | P1 |') == 'Fix the clock drift'
assert d.row_title('| T-2 | **Lead:** rest | [ ] | P1 |') == 'Lead'
assert d.row_title('| T-2 | `a \\| b` pipes stay | [ ] | P1 |') == '`a \\| b` pipes stay'
long = d.pr_title('T-2', '| T-2 | ' + 'word ' * 30 + '| [ ] | P1 |')
assert len(long) <= 72 and long.startswith('[T-2] word word') and long.endswith('…'), long
assert d.mission_name('## Mission: Heartbeat') == 'Heartbeat'
assert d.mission_name('## Send It run 2026-10-17') == 'Send It run 2026-10-17'  # a target's existing heading
print('PASS: PR title is the row lead, capped at 72; mission name comes from the selected heading')

publisher = object.__new__(d.Publisher)
publisher.grant = {'base_branch': 'main'}
publisher.prefix = 'repos/fixture/repo'
for protected, rules in ((True, []), (None, []), (False, [{'type': 'required_status_checks'}])):
    publisher.api = lambda endpoint: {'name': 'main', 'protected': protected, 'commit': {'sha': 'a' * 40}}
    publisher.read = lambda endpoint: rules
    refused(publisher.rules)
publisher.api = lambda endpoint: {'name': 'main', 'protected': False, 'commit': {'sha': 'a' * 40}}
publisher.prefix = 'repos/fixture/repo'
publisher.read = lambda endpoint: []
assert publisher.rules() == 'a' * 40
def plan_refusal(endpoint, private):
    if '/rules/' in endpoint:
        raise d.GitHubError('GitHub read failed: 403', d.RULES_UNAVAILABLE)
    assert endpoint == 'repos/fixture/repo'
    return {'private': private}
publisher.read = lambda endpoint: plan_refusal(endpoint, True)
assert publisher.rules() == 'a' * 40
publisher.read = lambda endpoint: plan_refusal(endpoint, False)
refused(publisher.rules)
print('PASS: protected, missing and unsupported effective rules refuse publication')

# Production conditional source transaction, with only the service boundary substituted.
import base64
import json
import runpy
qmod = runpy.run_path(str(SCRIPT.with_name('launch-queue.py')))
scope = {'path': 'BACKLOG.md', 'format': 'table', 'heading': '# Selected'}
source = (b'# Selected\r\n| ID | Item | Status | Tier | Depends on |\r\n'
          b'|---|---|---|---|---|\r\n| T-1 | selected | [ ] | P1 | none |\r\n'
          b'| T-2 | later | [ ] | P1 | T-1 |\r\n'
          b'# History\r\n| ID | Item | Status | Tier |\r\n| T-1 | old | [ ] | P1 |\r\n')
for mode in ('success', 'conflict', 'exhausted', 'drift', 'lost', 'unknown', 'expired', 'unverified', 'tamper'):
    with tempfile.TemporaryDirectory(prefix='source-write-') as temporary:
        root = Path(temporary).resolve()
        (root/'BACKLOG.md').write_bytes(source)
        publisher = object.__new__(d.Publisher)
        publisher.root = root
        publisher.prefix = 'repos/fixture/repo'
        publisher.admitted = {'host': {'gh': '/fake/gh', 'path': ['/usr/bin', '/bin']}, 'grant': {'repository': 'fixture/repo'}}
        publisher.grant = {'workspace': str(root), 'source': {**scope, 'blob': d.git_blob(source)},
                           'source_writeback': {'repository': 'fixture/repo', 'branch': 'main',
                                               'path': 'BACKLOG.md', 'heading': '# Selected', 'max_attempts': 2}}
        publisher.record = {'intents': [], 'verified': mode != 'unverified', 'stage': 'merged_source_pending',
                            'merge': {'commit': 'a'*40}, 'post_merge': {'ok': True, 'revision': 'a'*40},
                            'hosted_merge': {'revision': 'a'*40, 'status': 'not_declared'}}
        publisher.item = {'id': 'T-1', 'source': qmod['selected_backlog_text'](source.decode(), scope)['T-1']}
        saved, writes = [], []
        publisher.queue = SimpleNamespace(save=lambda: saved.append(copy.deepcopy(publisher.record)))
        expired = [mode == 'expired']
        def check(action=None):
            if action is not None and expired[0]: raise ValueError('original deadline exhausted')
        publisher.check = check
        remote = [source + b'concurrent unrelated note\r\n']
        def read(endpoint):
            assert endpoint == 'contents/BACKLOG.md?ref=main'
            return {'type': 'file', 'path': 'BACKLOG.md', 'sha': d.git_blob(remote[0]),
                    'encoding': 'base64', 'content': base64.b64encode(remote[0]).decode()}
        publisher.api = read
        def write(command, *args, **kwargs):
            assert command[:4] == ['/fake/gh', 'api', '--hostname', 'github.com']
            assert '--include' in command and command[command.index('--method')+1] == 'PUT'
            payload = json.loads(Path(command[command.index('--input')+1]).read_text())
            assert payload['sha'] == d.git_blob(remote[0]) and payload['branch'] == 'main'
            assert payload['message'] == 'docs(backlog): mark T-1 done (Mission Selected)\n\nVerified merge ' + 'a'*40
            assert saved[-1]['intents'][-1]['status'] == 'dispatching'
            writes.append(payload)
            if mode in ('conflict', 'exhausted', 'drift') and (len(writes) == 1 or mode == 'exhausted'):
                remote[0] += b'another unrelated edit\r\n'
                if mode == 'drift': remote[0] = remote[0].replace(b'| later |', b'| changed task |')
                return subprocess.CompletedProcess(command, 1, b'HTTP/2.0 409 Conflict\r\n\r\n{}', b'conflict')
            if mode in ('unknown', 'tamper'): raise subprocess.TimeoutExpired('unknown source write', 1)
            remote[0] = base64.b64decode(payload['content'])
            if mode == 'lost': raise SystemExit(75)
            return subprocess.CompletedProcess(command, 0, b'HTTP/2.0 200 OK\r\n\r\n{}', b'')
        def complete(): publisher.complete_source(qmod['selected_backlog_text'], qmod['complete_backlog'])
        with patch.object(d, 'run_owned', write):
            if mode in ('exhausted', 'drift', 'unknown', 'expired', 'unverified', 'tamper'):
                refused(complete)
                before = len(writes)
                if mode == 'tamper':
                    request = root/'source-request-1.json'
                    request.write_text(request.read_text().replace('main', 'other'))
                refused(complete)
                assert len(writes) == before
                assert before == (2 if mode == 'exhausted' else 0 if mode in ('expired', 'unverified') else 1)
                assert publisher.item.get('status') != 'delivered'
            else:
                if mode == 'lost':
                    try: complete(); raise AssertionError('source crash absent')
                    except SystemExit as error: assert error.code == 75
                    publisher.record = copy.deepcopy(saved[-1])
                    expired[0] = True
                complete()
                assert publisher.item['status'] == 'delivered'
                report = publisher.record['rediscovery']
                assert report['eligible'] == ['T-2'] and report['selection_complete'] is False
                assert len(writes) == (2 if mode == 'conflict' else 1)
                before = copy.deepcopy(publisher.record['intents'])
                complete()
                assert publisher.record['intents'] == before
                assert remote[0] == (source + b'concurrent unrelated note\r\n' +
                                     (b'another unrelated edit\r\n' if mode == 'conflict' else b'')).replace(
                                         b'| selected | [ ] |', b'| selected | Done |')
                assert (root/'BACKLOG.md').read_bytes() == source
                if mode == 'success':
                    queue = object.__new__(qmod['Queue'])
                    queue.base = root/'queue'
                    queue.base.mkdir()
                    queue.path = queue.base/'state.json'
                    queue.hash = 'fixture-manifest'
                    queue.cfg = {'platform': 'codex', 'delivery': {}, 'max_tasks': 1, 'max_attempts': 2}
                    queue.rollover = {'max_launches': 1, 'synchronous_commands': []}
                    queue.delivery = d
                    publisher.item['priority'] = 1
                    publisher.item['delivery'] = publisher.record
                    queue.state = {'manifest': queue.hash, 'items': [publisher.item],
                                   'admissions': 1, 'launches': 1, 'deadline': 0}
                    queue.validate_preparation = lambda: None
                    queue.source_items = lambda: qmod['selected_backlog_text'](source.decode(), scope)
                    queue.context = lambda *args: (_ for _ in ()).throw(AssertionError('unexpected native launch'))
                    publisher.queue = queue
                    publisher.grant['allowed_actions'] = ['source_done']
                    publisher.grant['publication'] = {}
                    publisher.record['merge'].update(candidate='b'*40, base='c'*40, tree='d'*40)
                    publisher.record['pr'] = {'number': 1}
                    publisher.record['intents'].insert(0, {'operation': 'base', 'identity': copy.deepcopy(publisher.record['merge'])})
                    publisher.grant['base_branch'] = 'main'
                    publisher.open_store = lambda: None
                    publisher.fetch_base = lambda: 'e'*40
                    publisher.git = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, b'')
                    publisher.text = lambda *args: 'd'*40
                    publisher.poll = lambda operation: operation()
                    publisher.hosted = lambda revision, merge_checks=None: {'revision': revision, 'status': 'not_declared'}
                    def unexpected(*args): raise AssertionError('completed task replayed')
                    publisher.review = publisher.verify = publisher.write = unexpected
                    source_read = publisher.api
                    publisher.api = lambda endpoint: ({'merged': True, 'merge_commit_sha': 'a'*40,
                        'head': {'sha': 'b'*40}, 'base': {'ref': 'main'}} if endpoint == 'pulls/1' else source_read(endpoint))
                    terminal_intents = copy.deepcopy(publisher.record['intents'])
                    queue.save()
                    def retained(*args):
                        publisher.item = queue.state['items'][0]
                        publisher.record = publisher.item['delivery']
                        return publisher
                    with patch.object(d, 'check_binding', return_value={'grant': publisher.grant}), \
                         patch.object(d, 'Publisher', retained):
                        queue.run()
                    assert queue.state['outcome'] == 'selected_task_delivered'
                    assert queue.state['admissions'] == queue.state['launches'] == 1
                    assert queue.state['deadline'] == 0 and len(queue.state['items']) == 1
                    assert publisher.record['intents'] == terminal_intents
                    assert publisher.record['verified'] and publisher.record['stage'] == 'delivered'
print('PASS: conditional source completion, byte preservation, drift, two intents, lost ack and expired read-only recovery')
