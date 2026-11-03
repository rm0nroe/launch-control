#!/usr/bin/env python3
"""Checkpoint handoff regressions in disposable Git repositories."""
import copy
import fcntl
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ns = runpy.run_path(str(ROOT / 'skills/onboard/scripts/launch-runtime.py'))
Runtime, Invalid = ns['Runtime'], ns['Invalid']


# A shell exit is not an external-service completion receipt, even if listed.
for command in ('docker compose up -d', 'podman run --detach image', 'systemctl start app', 'ssh host start-job', 'sleep 5 &'):
    assert not ns['synchronous_shell'](command, [command])
assert not ns['synchronous_shell']('python phase.py', [])
assert ns['synchronous_shell']('printf ok', ['printf ok'])
# The generated per-phase diff uses a path operand, not the dot source builtin.
diff_stat = 'git diff --stat -- .'
assert ns['synchronous_shell'](diff_stat, [diff_stat])
assert not ns['synchronous_shell'](diff_stat, [])
for command in ('. phase.sh', 'source .', diff_stat + '; . phase.sh', diff_stat + ' && . phase.sh',
                diff_stat + ' || . phase.sh', diff_stat + ' | . phase.sh', diff_stat + '\n. phase.sh',
                '(. phase.sh)', '{ . phase.sh; }', '! . phase.sh', 'if . phase.sh; then :; fi',
                'command . phase.sh', 'builtin . phase.sh', 'time . phase.sh', 'X=1 . phase.sh',
                '>out . phase.sh', '2>/dev/null . phase.sh', diff_stat + ' &', 'bash -c ' + repr(diff_stat)):
    assert not ns['synchronous_shell'](command, [command]), command
# A dot operand is a path, not sourcing: only command position sources.
for command in ('ruff check .', 'git diff -- .', 'cd voice && ruff check .', 'ls . >out', 'printf %s .'):
    assert ns['synchronous_shell'](command, [command]), command
for command in ("bash -c 'sleep 30 &'", "sh -c 'docker compose up -d'",
                "/bin/bash -c 'sleep 30 &'", "env bash -c 'sleep 30 &'",
                "command bash -c 'sleep 30 &'", "busybox sh -c 'sleep 30 &'",
                "eval 'sleep 30 &'", 'source phase.sh', '. phase.sh'):
    assert not ns['synchronous_shell'](command, [command])

# LC-030: unlisted commands fall back to bounded families, never to arbitrary shell.
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp).resolve()
    wt, outside, install = tmp / 'wt', tmp / 'outside', tmp / 'install'
    for d in (wt / 'app/tests', wt / 'ui', outside, install / 'refs', install / 'scripts'):
        d.mkdir(parents=True)
    (wt / 'link').symlink_to(outside)
    (outside / 's').write_text('SECRET\n')
    for f in ('app/tests/test_new.py', 'app/tests/test_a.py', 'ui/unit.config.ts', 'ui/other.config.ts'):
        (wt / f).write_text('')
    runtime = install / 'scripts/launch-runtime.py'
    runtime.write_text('')
    (outside / 'launch-runtime.py').write_text('')
    (wt / 'launch-runtime.py').write_text('')
    (wt / 'planted').mkdir()
    (wt / 'planted/launch-runtime.py').symlink_to(runtime)
    (wt / 'rootlink').symlink_to(install / 'scripts')
    (install / 'scripts/other.py').write_text('')
    (wt / 'planted/alias').mkdir()
    (wt / 'planted/alias/launch-runtime.py').symlink_to(install / 'scripts/other.py')
    (install / 'scripts/alias').mkdir()
    (install / 'scripts/alias/launch-runtime.py').symlink_to(install / 'scripts/other.py')
    run = '01234567-89ab-cdef-0123-456789abcdef'
    notes = lambda **kw: ' '.join([kw.get('program', 'python3'), kw.get('script', str(runtime)), '--project', kw.get('project', str(wt)),
                                   '--platform', kw.get('platform', 'codex'), 'notes', '--run', kw.get('run', run)] + kw.get('tail', ["--text 'Done (a); next: b.'"]))
    checks = [{'command': '.venv/bin/python -m pytest tests/ -q --cov', 'cwd': 'app'},
              {'command': 'pnpm exec playwright test -c unit.config.ts', 'cwd': 'ui'},
              {'command': 'node scripts/sync.mjs --check', 'cwd': '.'}, {'command': 'make test', 'cwd': '.'},
              {'command': 'docker compose run test', 'cwd': '.'}, {'command': 'bash run-tests.sh', 'cwd': '.'}]
    roots = [str(install)]
    worker = lambda c: ns['synchronous_shell'](c, [], str(wt), checks, roots)
    reviewer = lambda c: ns['command_family'](c, str(wt), checks, roots, mutate=False)
    reads = ['cat app/x.py', 'cat -n app/x.py', 'head -n 20 app/x.py', 'tail -n 5 app/x.py',
             'wc -l app/x.py', 'ls', 'ls -la app', 'grep -n foo app/x.py', "grep -rn 'a.*b' app",
             "grep -n '$(x); `y` > z' app/x.py", "sed -n '1,40p' app/x.py", 'pwd',
             'cat ' + str(install / 'refs/launch-autonomy.md'), 'cat ' + str(wt / 'app/x.py'),
             'cd app && cat tests/t.py', 'git status -sb', 'git status --short', 'git diff --check',
             'git diff --stat -- .', 'git diff origin/main...HEAD', 'git diff HEAD^2...HEAD',
             'git log -5 --format=%s', 'git rev-parse HEAD^2', 'git rev-parse --show-superproject-working-tree',
             'git show HEAD', 'git ls-files app', 'git ls-files -o --exclude-standard',
             # Worker and reviewer agree: manager names as search terms are plain data.
             'grep -n docker app/x.py', 'grep -rn service app',
             # LC-030 live run: a basic-regex alternation; a backslash in double quotes is literal before other characters.
             'grep -n "def a\\|def b" app/x.py', 'grep -n ^# app/x.py', 'grep -n ../ app/x.py', 'grep -n -e a -e b app/x.py', 'grep -rn -e a app',
             # Ryan, 2026-10-17: an absolute read is a read; the delivery sandbox allows or denies it.
             'cat /etc/passwd', 'cat /dev/null', 'cat ' + str(outside / 's'), 'head -n 5 ' + str(outside / 's'), 'ls ' + str(outside),
             # Ryan, 2026-10-17 (LC-030 live run 4): a relative read glob under a literal lead.
             'ls app/config/practice_profile.*.json', 'cat app/*.py', 'cat app/?.py', 'wc -l app/t*.py', 'head -n 5 app/*.py',
             'grep -n foo app/*.py', "grep -n 'a.*b' app/*.py", "sed -n '1,4p' app/*.py", 'cd app && ls tests/*.py']
    writes = ['cd app && .venv/bin/python -m pytest tests/test_new.py -q',
              'cd app && .venv/bin/python -m pytest tests/ -q --cov',
              'cd app && .venv/bin/python -m pytest -q tests/test_a.py',
              'cd ui && pnpm exec playwright test -c unit.config.ts', 'cd ui && pnpm exec playwright test -c other.config.ts',
              'node scripts/sync.mjs --check', 'make test',
              'git add app/x.py app/y.py', 'git add -- app/x.py',
              'git commit -m "feat(app): add x (ABC-1)" -- app/x.py app/y.py',
              "git commit -m 'fix #12 $(not expanded)' -- app/x.py",
              # LC-030 live run: a pytest node ID on an existing file, and the reference's phase-notes command.
              'cd app && .venv/bin/python -m pytest tests/test_a.py::test_x -q', notes(), notes(platform='claude')]
    for command in reads:
        assert worker(command) and reviewer(command), command
    for command in writes:
        assert worker(command) and not reviewer(command), command
    refused_commands = [
        # Raw screen: expansion, chaining, redirection, globbing, comments, escapes.
        'cat $(echo x)', 'cat `x`', 'cat "$HOME/x"', 'cat "a`b`"', 'cat x > y', 'cat x; rm y', 'cat x &',
        'cat x | sh', 'cat x && rm y', 'cat app/[ab].py', 'cat ~/x',
        # Read globs: never a leading glob (option injection), dot-glob (`..`), `**`, absolute, quoted mix, or non-read program.
        'cat *.py', 'cat ?.py', 'sed -n 1p *', 'cat -*', 'ls .*', 'ls app/.*', 'cat app/.?', 'cat ./*.py', 'cat app/**/x.py',
        'cat /etc/*', 'cat /d*/zero', "cat app/'.'*", 'cat app/"x"*.py', 'cat ' + str(outside) + '/*', "cat 'app'/*.py", 'cat app/../*.py', 'cd app && cat ../*.py',
        'git diff app/*', 'git status app/?', 'git log -- app/*.py', 'cd app* && cat x.py', 'node scripts/*.mjs --check',
        'cat {a,b}', 'cat app/{x.py', 'cat app/x}.py', 'cat x # -- y', 'cat app/x.py #app/y.py', 'cat a\\;b',
        'cat app/x\\.py', 'cat $HOME/x', "cd 'app && cat x", 'cat =sh', 'ls =python3', 'cat app/x.py =sh', 'cat a\x00', 'cat x\nrm y', "cat 'unterminated", 'cat (x)',
        'cat <app/x.py', 'cat app/x(.py', 'cat app/x).py', 'cat app/x[.py', 'cat app/x].py', 'cat app/x!.py', 'cat app/x.py\r',
        # Paths: parent, absolute outside, symlink out.
        'cat ../x', 'cat app/../../x', 'cat app/../app/x.py', 'cd .. && cat wt/app/x.py', 'git add ' + str(wt / 'app/x.py'), 'cat link/secret',
        'cat ' + str(outside / '../x'), 'cat /etc/../etc/passwd',
        # Flags and shapes outside the read allow-list.
        'tail -f app/x.py', 'tail -F app/x.py', 'head -c 5 app/x.py', 'grep -f pats app/x.py', 'grep -n -e', 'grep -e a', 'grep -n -e a -f p app/x.py',
        'grep --include=x foo app', "sed -i 's/a/b/' app/x.py", "sed -n '1p;w out' app/x.py",
        "sed -n '1,4p'", 'cat', 'ls --color=always', 'find . -name x', 'rg foo',
        # Git: global options, writers, diff drivers, unlisted subcommands.
        'git -c core.pager=sh log', 'git -C .. status', 'git --git-dir=x log', 'git --work-tree=. status',
        'git --exec-path=. status', 'git diff --ext-diff', 'git log --output=x', 'git show --textconv HEAD',
        'git diff --no-index a b', 'git diff -O/etc/passwd',
        'git ls-files --exclude-from=/etc/x', 'git diff --output=x', 'grep -Rn SECRET .', 'grep -R SECRET link', 'git push', 'git config x y', 'git checkout x', 'git stash', 'git',
        # Commit shapes.
        'git commit -m msg', 'git commit -m msg app/x.py app/y.py', 'git commit -am msg -- app/x.py', 'git commit -m msg --amend -- app/x.py',
        'git commit -m "$(nohup srv &)" -- app/x.py', 'git commit -m msg -- /etc/x', 'git commit -m msg --',
        'git commit -m msg -- link/x', 'git add -A', 'git add ../x', 'git add --force app/x.py', 'git add',
        # Focused tests: different program, subcommand, cwd, or unlisted flags.
        'cd app && .venv/bin/python -m pytest --pdb', 'cd app && .venv/bin/python other.py',
        'cd app && .venv/bin/python -c x', '.venv/bin/python -m pytest tests/ -q',
        'cd ui && pnpm exec playwright show-report', 'node scripts/other.mjs --check',
        'cd app && .venv/bin/python -m pytest /etc/x', 'cd app && .venv/bin/python -m pytest --cov-report=html',
        'cd app && .venv/bin/python -m pytest -k', 'cd ui && pnpm exec playwright test -c /tmp/evil.ts',
        'cd app && .venv/bin/python -m pytest -k slug', 'cd app && .venv/bin/python -m pytest -x tests/test_a.py',
        'cd app && .venv/bin/python -m pytest tests/missing.py', 'make test deploy', 'make test -k clean', 'make test link/s', 'make test ' + str(outside / 's'),
        '.venv/bin/python -m pytest app/tests/test_a.py -q',
        'docker compose run test', 'bash run-tests.sh', 'cd missing && cat x',
        # cd prefix: absolute, parent, symlink out, chained.
        'cd /tmp && cat x', 'cd .. && cat x', 'cd link && cat x', 'cd app && cd .. && cat x', 'cd && cat x',
        # Wrappers and lifecycle managers.
        'bash -c "cat x"', 'sh -c cat', 'env cat x', 'xargs cat', 'nohup cat x', 'timeout 5 cat x',
        'command cat x', 'exec cat x', 'sudo cat x',
        # Double-quoted escapes the shell interprets stay refused.
        'grep -n "a\\$b" app/x.py', 'grep -n "a\\"b" app/x.py', 'grep -n "a\\\\b" app/x.py', 'grep -n "a\\`b`" app/x.py',
        # Node IDs: the file must exist inside the worktree.
        'cd app && .venv/bin/python -m pytest tests/missing.py::test_x', 'cd app && .venv/bin/python -m pytest ../x.py::t',
        'cd app && .venv/bin/python -m pytest ::test_x',
        # Notes: only the admitted runtime, this worktree, a known platform, a run ID and one text.
        notes(script=str(outside / 'launch-runtime.py')), notes(project=str(outside)), notes(platform='bash'),
        notes(program='python'), notes(run='latest'), notes(tail=[]), notes(tail=["--text a", '--reset-attempts']),
        notes(tail=["--text 'x'", '--text y']), notes(script=str(install / 'refs/launch-autonomy.md')),
        # A worker-written runtime in the worktree would be arbitrary code: only the admitted read set.
        notes(script=str(wt / 'launch-runtime.py')), notes(script='launch-runtime.py'),
        # Symlinks planted in the worktree, and another reviewed script under the runtime's name.
        notes(script=str(wt / 'planted/launch-runtime.py')), notes(script=str(wt / 'rootlink/launch-runtime.py')),
        notes(script=str(wt / 'planted/alias/launch-runtime.py')), notes(project='.'),
        notes(script=str(install / 'scripts/alias/launch-runtime.py')), notes(project=os.path.relpath(wt)),
        # Absolute reads the sandbox may grant but that block or stream forever.
        'cat /dev/zero', 'tail -n 1 /dev/stdin', 'cat /dev/fd/3', 'head -n 1 /proc/self/environ', 'grep -r a /', 'ls /']
    for command in refused_commands:
        assert not worker(command) and not reviewer(command), command
    # Families are only the fallback: no worktree means only the exact recorded list.
    assert not ns['synchronous_shell']('cat app/x.py', [])
    assert not ns['synchronous_shell']('cat app/x.py', [], None, checks, roots)
print('PASS: LC-030 command families, raw-string screen, path containment and reviewer split')


def refused(call):
    try:
        call()
    except (Invalid, OSError):
        return
    raise AssertionError('unsafe handoff accepted')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)


with tempfile.TemporaryDirectory(prefix='launch-handoff-') as directory:
    root = Path(directory).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'candidate').write_text('original\n')
    policy = root / '.claude/launch/verify.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'true', 'cwd': '.', 'timeout': 1}], 'acceptance': ['behavior']}))
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'fixture')
    rt = Runtime(root, None)
    state = json.loads(subprocess.check_output([
        'python3', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'),
        '--project', str(root), 'start', '--supervised', '--task', 'T-1',
        '--session', 'old-session',
    ]))
    refused(lambda: rt.attach(state, 'a' * 64))
    unowned_flag = subprocess.run([
        'python3', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'),
        '--project', str(root), 'start', '--supervised', '--task', 'T-1',
        '--session', 'unsafe', '--controller', 'a' * 64,
    ], capture_output=True)
    assert unowned_flag.returncode != 0
    queue_base = root / '.git/launch-queue'
    queue_base.mkdir()
    queue_lock = (queue_base / 'lock').open('a')
    fcntl.flock(queue_lock, fcntl.LOCK_EX)
    claim = dict(manifest='a' * 64, deadline=state['deadline'], items=[dict(
        run=state['run'], id=state['task'], worktree=str(root), session=state['session'], status='running')])
    ns['atomic'](queue_base / 'active.json', claim)
    state = rt.attach(state, 'a' * 64)
    notes = dict(goal='Fix candidate', scope='T-1 only', completed='Read initial candidate',
                 next_phase='implementation', next_action='Verify preserved dirty candidate',
                 questions='none', evidence='initial read', unsafe_state='dirty file retained',
                 reversal='Restore original candidate only if requested')
    (root / 'candidate').write_text('uncommitted\n')
    dirty = (root / 'candidate').read_bytes()
    for invalid in ({}, {**notes, 'next_action': ''}, {**notes, 'extra': 'unknown'}):
        refused(lambda: rt.seal(state, invalid))
    payload = {'hook_event_name': 'Stop', 'cwd': str(root), 'session_id': 'old-session', 'stop_hook_active': False}
    assert rt.hook(payload, state['run']) == {}, 'controller turn must finish without finishing task'
    original = rt.load(state['run'])
    with rt.lock():
        paused = copy.deepcopy(original)
        paused.update(status='paused', reason='user pause')
        rt.save(paused)
    refused(lambda: rt.seal(original, notes))
    with rt.lock():
        ns['atomic'](rt.state_path, original)  # restore exact disposable test setup
    replace = os.replace
    def fail_active(source, target):
        if Path(target) == rt.state_path:
            raise OSError('interrupted before authoritative publication')
        return replace(source, target)
    try:
        os.replace = fail_active
        refused(lambda: rt.seal(original, notes))
    finally:
        os.replace = replace
    assert rt.load(state['run']) == original
    def fail_view(source, target):
        if Path(target).name == 'checkpoint.md':
            raise OSError('interrupted after authoritative publication')
        return replace(source, target)
    try:
        os.replace = fail_view
        refused(lambda: rt.seal(original, notes))
    finally:
        os.replace = replace
    sealed = rt.load(state['run'])
    assert sealed['status'] == 'handoff'
    record_hash = sealed['handoff']['hash']
    rt.export_view(sealed, record_hash)
    record = rt.handoff(sealed, record_hash)
    assert record['semantic'] == notes and record['snapshot_sequence'] == sealed['sequence']
    # A valid hash cannot authorize another task's or run's checkpoint.
    authoritative = rt.state_path.read_bytes()
    view_before = (rt.base / state['run'] / 'checkpoint.md').read_bytes()
    for key, value in (('task', 'T-2'), ('run', '00000000-0000-4000-8000-000000000002')):
        foreign = copy.deepcopy(sealed)
        foreign['handoff']['record'][key] = value
        foreign_hash = ns['digest'](json.dumps(foreign['handoff']['record'], sort_keys=True).encode())
        foreign['handoff']['hash'] = foreign_hash
        try:
            rt.check_handoff(foreign, foreign_hash)
            raise AssertionError('cross-task checkpoint accepted: ' + key)
        except Invalid as error:
            assert str(error) == 'checkpoint identity or limits changed'
        if key == 'run':
            wrong_run = subprocess.run(['python3', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'),
                '--project', str(root), 'checkpoint', '--run', value, '--hash', record_hash],
                capture_output=True, text=True)
            assert wrong_run.returncode != 0 and 'run ID mismatch' in wrong_run.stderr
            assert not wrong_run.stdout.strip()
    assert rt.state_path.read_bytes() == authoritative
    assert (rt.base / state['run'] / 'checkpoint.md').read_bytes() == view_before
    assert rt.handoff(sealed, record_hash) == record
    # The CLI must not substitute the valid active seal or a competing Markdown file.
    # Manual skill routing itself is instruction-tested, not simulated here.
    (root / '.git/info/exclude').write_text('.claude_states/\n')
    ordinary = root / '.claude_states'
    ordinary.mkdir()
    foreign_run = '00000000-0000-4000-8000-000000000002'
    decoys = [ordinary / f'launch-run-{state["run"]}.md',
              ordinary / f'launch-run-{foreign_run}.md', ordinary / 'latest.md',
              rt.base / foreign_run / 'checkpoint.md']
    for decoy in decoys:
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_bytes(view_before)
    for run, key, error in ((foreign_run, record_hash, 'run ID mismatch'),
                            ('../latest', record_hash, 'run ID mismatch'),
                            (state['run'], '0' * 64, 'missing or corrupt sealed checkpoint')):
        result = subprocess.run(['python3', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'),
            '--project', str(root), 'checkpoint', '--run', run, '--hash', key],
            capture_output=True, text=True)
        assert result.returncode != 0 and error in result.stderr, result
        assert not result.stdout.strip(), 'failed exact lookup returned a substitute checkpoint'
    assert rt.state_path.read_bytes() == authoritative
    assert (rt.base / state['run'] / 'checkpoint.md').read_bytes() == view_before
    assert all(decoy.read_bytes() == view_before for decoy in decoys)
    exact = subprocess.run(['python3', str(ROOT / 'skills/onboard/scripts/launch-runtime.py'),
        '--project', str(root), 'checkpoint', '--run', state['run'], '--hash', record_hash],
        capture_output=True, text=True)
    assert exact.returncode == 0 and json.loads(exact.stdout) == record, exact
    assert (root / 'candidate').read_bytes() == dirty
    refused(lambda: rt.bind(sealed, '0' * 64, 'new-session'))
    git(root, 'add', 'candidate')
    refused(lambda: rt.bind(sealed, record_hash, 'new-session'))
    git(root, 'reset', 'HEAD', '--', 'candidate')
    # The unchanged working-tree bytes must not conceal changed index content.
    assert (root / 'candidate').read_bytes() == dirty
    with rt.lock():
        paused = copy.deepcopy(sealed)
        paused.update(status='paused', reason='pause after seal')
        rt.save(paused)
    refused(lambda: rt.bind(sealed, record_hash, 'new-session'))
    with rt.lock():
        ns['atomic'](rt.state_path, sealed)
    rt.hook({**payload, 'hook_event_name': 'SessionStart', 'source': 'clear', 'session_id': 'cleared-session'}, state['run'])
    refused(lambda: rt.bind(sealed, record_hash, 'new-session'))
    assert rt.load(state['run'])['status'] == 'paused'
    with rt.lock():
        ns['atomic'](rt.state_path, sealed)
    def fail_history(source, target):
        if Path(target).parent == rt.base / state['run']:
            raise OSError('interrupted after binding publication')
        return replace(source, target)
    try:
        os.replace = fail_history
        refused(lambda: rt.bind(sealed, record_hash, 'new-session'))
    finally:
        os.replace = replace
    bound = rt.load(state['run'])
    claim['items'][0]['session'] = 'new-session'
    ns['atomic'](queue_base / 'active.json', claim)
    for key in ('run', 'task', 'deadline', 'attempts', 'max_attempts'):
        assert bound[key] == original[key], key
    assert bound['session'] == 'new-session' and bound['handoff']['stage'] == 'bound'
    assert rt.bind(bound, record_hash, 'new-session') == bound, 'exact readback must be idempotent'
    refused(lambda: rt.bind(bound, record_hash, 'different-session'))
    assert rt.hook(payload, state['run']) == {}, 'old session cannot receive checkpoint'
    loaded = rt.hook({**payload, 'session_id': 'new-session', 'hook_event_name': 'SessionStart', 'source': 'startup'}, state['run'])
    assert notes['next_action'] in loaded['hookSpecificOutput']['additionalContext']
    view = rt.base / state['run'] / 'checkpoint.md'
    assert record_hash in view.read_text() and notes['unsafe_state'] in view.read_text()
    # Same tree and index, but a different commit must invalidate cached Runtime identity.
    git(root, 'commit', '--allow-empty', '-m', 'same tree new revision')
    refused(lambda: rt.check_handoff(bound, record_hash))
    git(root, 'reset', '--soft', record['revision'])
    git(root, 'switch', '-c', 'same-commit-other-branch')
    refused(lambda: rt.check_handoff(bound, record_hash))
    git(root, 'switch', 'fixture')
    view.write_text(view.read_text() + '\nuser edit\n')
    refused(lambda: rt.seal(bound, notes))
    view.unlink()  # explicit removal in this disposable test only
    for _ in range(20):
        with rt.lock():
            latest = rt.load(state['run'])
            rt.save(latest)
    assert len(list((rt.base / state['run']).glob('[0-9]*.json'))) == 15
    latest = rt.load(state['run'])
    latest['deadline'] = time.time() - 1
    with rt.lock():
        ns['atomic'](rt.state_path, latest)
    refused(lambda: rt.seal(latest, notes))
    outside = root / 'outside'
    outside.mkdir()
    link = root / 'alias'
    link.symlink_to(outside, target_is_directory=True)
    refused(lambda: ns['atomic'](link / 'state.json', {}))
    assert not (outside / 'state.json').exists()
    queue_lock.close()

print('PASS: sealed identity/index, pause races, exact bind, retained limits, manual view and symlink refusal')

# Claude cannot use tools until the same native session completes calibration.
with tempfile.TemporaryDirectory(prefix='launch-calibration-') as directory:
    root = Path(directory).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    policy = root / '.claude/launch/verify.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'true', 'cwd': '.', 'timeout': 1}], 'acceptance': ['behavior']}))
    settings = root / '.claude/settings.json'
    settings.write_text(json.dumps({'hooks': {'PreToolUse': [{'hooks': [{'type': 'command',
        'command': 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"', 'timeout': 10}]}]}}))
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'fixture')
    rt = Runtime(root, None)
    base = root / '.git/launch-queue'
    base.mkdir()
    with (base / 'lock').open('a') as queue_lock:
        fcntl.flock(queue_lock, fcntl.LOCK_EX)
        import uuid
        rid = str(uuid.uuid4())
        manifest = root / '.git/fixture-manifest.json'
        manifest.write_text(json.dumps({'schema': 1, 'platform': 'claude'}))
        os.environ['LAUNCH_MANIFEST'] = str(manifest)
        bound = ns['digest'](json.dumps(json.loads(manifest.read_text()), sort_keys=True).encode())
        claim = dict(manifest=bound, deadline=time.time() + 120, items=[dict(run=rid,
            id='T-1', worktree=str(root), session='', status='admitting')])
        ns['atomic'](base / 'active.json', claim)
        with rt.lock():
            state = rt.begin('T-1', '', 1, 2, run=rid, controller=bound, pending=True)
        # The worker runs in bypassPermissions, so a settings layer that switches hooks off must refuse admission.
        config = root / '.git/claude-config'  # Untracked and removed with the fixture.
        config.mkdir()
        os.environ['CLAUDE_CONFIG_DIR'] = str(config)
        for layer in (config / 'settings.json', root / '.claude/settings.local.json', settings):
            original = layer.read_text() if layer.exists() else None
            layer.write_text(json.dumps({**json.loads(original or '{}'), 'disableAllHooks': True}))
            refused(lambda: rt.calibration(state, True))
            layer.write_text(original) if original else layer.unlink()
        for unreadable in ('{', '[]'):
            (config / 'settings.json').write_text(unreadable)
            refused(lambda: rt.calibration(state, True))
        (config / 'settings.json').write_text(json.dumps({'disableAllHooks': False}))
        state = rt.calibration(state, True)
        tool = dict(hook_event_name='PreToolUse', cwd=str(root), session_id='actual', tool_name='Bash')
        assert rt.hook(tool, rid)['hookSpecificOutput']['permissionDecision'] == 'deny'
        refused(lambda: rt.calibration(state, False))
        rt.hook(dict(hook_event_name='SessionStart', cwd=str(root), session_id='actual', source='startup'), rid)
        formatter = {**tool, 'tool_name': 'StructuredOutput', 'tool_input': {'loaded_hash': ''}}
        assert rt.hook(formatter, rid) == {}
        for bad in ({**formatter, 'tool_input': {'loaded_hash': '', 'goal': 'extra'}},
                    {**formatter, 'tool_input': {'loaded_hash': 'wrong'}},
                    {**formatter, 'session_id': 'foreign'}, {**formatter, 'agent_id': 'child'}):
            assert rt.hook(bad, rid)['hookSpecificOutput']['permissionDecision'] == 'deny'
        claim['items'][0]['next_session'] = 'actual'
        ns['atomic'](base / 'active.json', claim)
        state = rt.activate(rt.load(rid), 'actual')
        claim['items'][0].update(session='actual', status='running')
        ns['atomic'](base / 'active.json', claim)
        state = rt.calibration(state, False)
        assert rt.hook({**tool, 'tool_input': {'command': 'git status'}}, rid) == {}
        assert rt.hook(tool, rid)['hookSpecificOutput']['permissionDecision'] == 'deny'  # no command: unclassified
        def reason(payload):
            return rt.hook(payload, rid).get('hookSpecificOutput', {}).get('permissionDecisionReason', '')
        assert rt.hook({**tool, 'tool_input': {'command': 'true'}}, rid) == {}  # declared check
        assert rt.hook({**tool, 'tool_name': 'StructuredOutput', 'tool_input': {'goal': 'notes'}}, rid) == {}
        del os.environ['LAUNCH_MANIFEST']
        assert '(controller manifest unavailable)' in reason({**tool, 'tool_input': {'command': 'git status'}})
        os.environ['LAUNCH_MANIFEST'] = str(manifest)
        original = policy.read_bytes()
        policy.write_text(json.dumps({**json.loads(original), 'checks': [{'command': 'git push origin HEAD', 'cwd': '.', 'timeout': 1}]}))
        assert '(policy changed)' in reason({**tool, 'tool_input': {'command': 'git push origin HEAD'}})
        policy.write_bytes(original)
        assert rt.hook({**tool, 'tool_input': {'command': 'git status'}}, rid) == {}
        assert hasattr(rt, 'request_checkpoint'), 'active checkpoint needs a controller-owned tool gate'
        state = rt.request_checkpoint(rt.load(rid))
        work = {**tool, 'tool_use_id': 'work-1', 'tool_input': {'command': 'printf work'}}
        assert rt.hook(work, rid)['hookSpecificOutput']['permissionDecision'] == 'deny'
        observed = {k: work[k] for k in ('tool_use_id', 'tool_name', 'tool_input')}
        assert rt.checkpoint_denial(rid, 'actual', observed)
        assert not rt.checkpoint_denial(rid, 'foreign', observed)
        assert not rt.checkpoint_denial(rid, 'actual', {**observed, 'tool_input': {'command': 'printf other'}})
        semantic = dict(goal='Finish task', scope='T-1 only', completed='phase one',
                        next_phase='implementation', next_action='phase two', questions='none',
                        evidence='phase one check', unsafe_state='dirty candidate', reversal='preserve candidate')
        complete = {**formatter, 'tool_use_id': 'format-checkpoint',
                    'tool_input': {**semantic, 'loaded_hash': ''}}
        assert rt.hook(complete, rid) == {}
        for bad in ({**complete, 'session_id': 'foreign'}, {**complete, 'agent_id': 'child'},
                    {**complete, 'tool_input': {**semantic, 'loaded_hash': 'wrong'}},
                    {**complete, 'tool_input': {**semantic, 'loaded_hash': '', 'next_action': ''}}):
            assert rt.hook(bad, rid)['hookSpecificOutput']['permissionDecision'] == 'deny'
        state = rt.seal(rt.load(rid), semantic)
        state = rt.bind(state, state['handoff']['hash'], 'replacement')
        assert not state.get('checkpoint_only') and not state.get('checkpoint_denials')
print('Claude calibration gate checks passed')

# Publication repair spends the existing budget once, then uses ordinary handoff.
with tempfile.TemporaryDirectory(prefix='launch-delivery-repair-') as directory:
    root = Path(directory).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    policy = root / '.codex/launch/verify.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'true', 'cwd': '.', 'timeout': 1}], 'acceptance': ['behavior']}))
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'fixture')
    rt = Runtime(root, None, 'codex')
    base = root / '.git/launch-queue'
    base.mkdir()
    rid = str(__import__('uuid').uuid4())
    claim = dict(manifest='c' * 64, deadline=time.time() + 3600, admissions=1, launches=1, items=[dict(
        run=rid, id='T-1', worktree=str(root), session='reviewed-session', status='running', attempts=0)])
    ns['atomic'](base / 'active.json', claim)
    with (base / 'lock').open('a') as queue_lock:
        fcntl.flock(queue_lock, fcntl.LOCK_EX)
        with rt.lock():
            state = rt.begin('T-1', 'reviewed-session', 30, 3, run=rid, controller=claim['manifest'])
            state.update(status='awaiting_review', receipt={'ok': True})
            rt.save(state)
        repair = {'id': 'd' * 64, 'candidate': rt.ident['revision'], 'fingerprint': ns['fingerprint'](root),
                  'base': 'e' * 40, 'attempts': 1, 'previous_attempts': 0}
        claim['items'][0].update(status='handoff', attempts=1,
            delivery={'grant': 'f' * 64, 'repair': repair})
        ns['atomic'](base / 'active.json', claim)
        ns['configure_git']('f' * 64, lambda cwd, *args: subprocess.run(
            ['git', '-C', str(cwd), *args], capture_output=True))
        changed = rt.delivery_repair(rt.load(rid), repair['id'], 1)
        assert changed['status'] == 'running' and changed['attempts'] == 1 and 'receipt' not in changed
        assert changed['deadline'] == state['deadline'] and changed['run'] == rid
        assert rt.delivery_repair(changed, repair['id'], 1) == changed
        retained = rt.state_path.read_bytes()
        refused(lambda: rt.delivery_repair(changed, '0' * 64, 1))
        refused(lambda: rt.delivery_repair(changed, repair['id'], 2))
        assert rt.state_path.read_bytes() == retained
        assert claim['admissions'] == claim['launches'] == 1
        sealed = rt.seal(changed, notes)
        assert sealed['handoff']['record']['attempts'] == 1
        assert sealed['handoff']['record']['deadline'] == state['deadline']
        assert (rt.base / rid / 'awaiting_review.json').exists()
print('PASS: controller-only repair idempotence, retained deadline/counters and ordinary sealed handoff')
