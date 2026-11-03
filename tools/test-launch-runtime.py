#!/usr/bin/env python3
"""Disposable Git fixtures for the supervised runtime; never uses user config."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import runpy
import re
os.environ.setdefault('LAUNCH_CONTROL_NO_OPEN', '1')  # never open the report page from a test run

PLATFORM = 'claude'
RUNTIME = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-runtime.py'


def run(root, *args, ok=True, payload=None, env=None):
    if args == ('hook',) and PLATFORM == 'codex' and not ok:
        result = run(root, *args, payload=payload, env=env)
        assert result['continue'] is False and result['stopReason']
        return result
    result = subprocess.run(['python3', str(RUNTIME), '--project', str(root), '--platform', PLATFORM, *args], input=json.dumps(payload) if payload else None, text=True, capture_output=True, env={**os.environ, 'LAUNCH_RUN_ID': '', **(env or {})})
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return json.loads(result.stdout) if result.stdout.strip() else None


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()


# Generated entry points must not import candidate modules before checking authority.
with tempfile.TemporaryDirectory(prefix='launch-imports-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', 'tracked')
    git(root, 'commit', '-m', 'fixture')
    wrappers = runpy.run_path(str(RUNTIME))
    canary = root / '.git/imported'
    (root / 'json.py').write_text(f'open({str(canary)!r}, "w").write("candidate import")\nraise SystemExit(97)\n')
    for platform in ('claude', 'codex'):
        installed = root / platform / 'skills/onboard/scripts/launch-runtime.py'
        installed.parent.mkdir(parents=True)
        installed.write_bytes(RUNTIME.read_bytes())
    env = {**os.environ, 'PYTHONPATH': str(root), 'LAUNCH_RUN_ID': '', 'LAUNCH_PLATFORM': 'codex',
           'CLAUDE_PROJECT_DIR': str(root), 'CLAUDE_CONFIG_DIR': str(root / 'claude'),
           'CODEX_HOME': str(root / 'codex')}
    cases = [('.claude/hooks/launch.sh', wrappers['HOOK_WRAPPER'], []),
             ('.codex/hooks/launch.sh', wrappers['CODEX_HOOK_WRAPPER'], []),
             ('scripts/verify.sh', wrappers['VERIFY_WRAPPER'], ['--help']),
             ('.codex/hooks/shared.sh', wrappers['wrappers'](RUNTIME, wrappers['digest'](RUNTIME.read_bytes()), root)[1], [])]
    reference = (RUNTIME.parent.parent / 'references/launch-autonomy.md').read_text()
    documented = [block for block in re.findall(r'```bash\n(.*?)```', reference, re.S)
                  if block.startswith('#!/usr/bin/env bash\n')]
    assert len(documented) == 2
    cases += [('.claude/hooks/documented.sh', documented[0], []),
              ('scripts/documented.sh', documented[1], ['--help'])]
    for name, content, args in cases:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        result = subprocess.run(['bash', str(path), *args], cwd=root, env=env,
                                input='{}', capture_output=True, text=True)
        assert not canary.exists(), ('candidate module imported by ' + name, result.stderr)
        assert result.returncode == 0, (name, result.stdout, result.stderr)
print('PASS: generated hooks and verifier isolate Python imports from candidate cwd and environment')


for PLATFORM in ('claude', 'codex'):
    with tempfile.TemporaryDirectory(prefix='launch-fixture-') as temporary:
        root = Path(temporary).resolve()
        git(root, 'init', '-b', 'fixture')
        git(root, 'config', 'user.name', 'Fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        (root / 'tracked').write_text('initial')
        policy = root / f'.{PLATFORM}/launch/verify.json'
        policy.parent.mkdir(parents=True)
        config = {'schema': 1, 'checks': [{'command': 'test -f tracked', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}
        policy.write_text(json.dumps(config))
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'fixture')
        assert run(root, 'hook') is None  # no active envelope: no state, no hook effect
        run(root, 'validate-config')
        assert run(root, 'verify', 'checks')['ok']
        (root / 'tracked').write_text('dirty')
        assert run(root, 'verify', 'checks')['ok']  # dirty checks are intentional
        state = run(root, 'start', '--supervised', '--task', 'T-1', '--session', 'session-one')
        rid = state['run']
        assert state['platform'] == PLATFORM
        other = 'codex' if PLATFORM == 'claude' else 'claude'
        run(root, '--platform', other, 'status', '--run', rid, ok=False)
        run(root, '--platform', other, 'recover', '--run', rid, '--session', 'wrong', '--text', 'must reject', ok=False)
        run(root, 'start', '--supervised', '--task', 'T-2', '--session', 'two', ok=False)
        run(root, 'notes', '--run', rid, '--text', 'Next: preserve the dirty implementation and test behavior.')
        envelope = {'LAUNCH_RUN_ID': rid}
        payload = {'hook_event_name': 'SessionStart', 'source': 'compact', 'session_id': 'session-one', 'cwd': str(root), 'trigger': 'auto', 'stop_hook_active': False}
        loaded = run(root, 'hook', env=envelope, payload=payload)
        assert 'preserve the dirty implementation' in loaded['hookSpecificOutput']['additionalContext']
        assert run(root, 'hook', env=envelope, payload={**payload, 'session_id': 'unrelated'}) == {}
        cleared = {**payload, 'source': 'clear', 'session_id': 'new-native-session'}
        assert run(root, 'hook', env=envelope, payload={**cleared, 'agent_id': 'unrelated-agent'}) == {}
        assert run(root, 'status', '--run', rid)['status'] == 'running'
        result = run(root, 'hook', env=envelope, payload=cleared)
        assert 'hookSpecificOutput' not in result
        paused = run(root, 'status', '--run', rid)
        assert paused['status'] == 'paused' and paused['session'] == 'session-one'
        assert paused['notes'] == 'Next: preserve the dirty implementation and test behavior.'
        assert paused['attempts'] == state['attempts']
        assert run(root, 'hook', env=envelope, payload={**payload, 'session_id': 'new-native-session'}) == {}
        run(root, 'recover', '--run', rid, '--session', 'session-one', '--text', 'Operator resumes fixture after clear')
        run(root, 'hook', env={'LAUNCH_RUN_ID': 'wrong'}, payload=payload, ok=False)
        for trigger in ('manual', 'auto'):
            before = run(root, 'status', '--run', rid)
            run(root, 'hook', env=envelope, payload={**payload, 'hook_event_name': 'PreCompact', 'trigger': trigger})
            snapshot = run(root, 'status', '--run', rid)
            assert snapshot['sequence'] == before['sequence'] + 1
            assert snapshot['checkpoint_revision'] == git(root, 'rev-parse', 'HEAD')
            for key in ('repo', 'worktree', 'branch', 'revision', 'run', 'task', 'platform', 'session',
                        'status', 'notes', 'deadline', 'attempts', 'max_attempts', 'policy', 'runtime'):
                assert snapshot[key] == before[key], (PLATFORM, trigger, key)
            history = root / '.git/launch' / rid / f"{snapshot['sequence']:08d}.json"
            assert json.loads(history.read_text()) == snapshot
            loaded = run(root, 'hook', env=envelope, payload=payload)
            assert json.loads(loaded['hookSpecificOutput']['additionalContext'].split('\n', 1)[1]) == snapshot
        stop = {**payload, 'hook_event_name': 'Stop'}
        # Native clients retain shell cwd changes; only the assigned worktree may resume.
        with tempfile.TemporaryDirectory(dir=root) as nested, tempfile.TemporaryDirectory() as outside:
            nested, outside = Path(nested), Path(outside).resolve()
            for event in ('SessionStart', 'PreCompact', 'Stop'):
                result = run(root, 'hook', env=envelope, payload={**payload, 'cwd': str(nested), 'hook_event_name': event})
                if event == 'Stop':
                    assert result['decision'] == 'block'
                elif event == 'SessionStart':
                    assert 'preserve the dirty implementation' in result['hookSpecificOutput']['additionalContext']
            (nested / 'inside').symlink_to(root, target_is_directory=True)
            assert run(root, 'hook', env=envelope, payload={**stop, 'cwd': str(nested / 'inside')})['decision'] == 'block'
            (nested / 'escape').symlink_to(outside, target_is_directory=True)
            git(root, 'worktree', 'add', '--detach', str(outside / 'linked'), 'HEAD')
            git(nested, 'init', '-b', 'foreign')
            for cwd in (None, '', '.', 42, str(root / 'tracked'), str(root / 'missing'),
                        str(outside), str(outside / 'linked'), str(nested), str(nested / 'escape')):
                run(root, 'hook', env=envelope, payload={**stop, 'cwd': cwd}, ok=False)
            run(root, 'hook', env=envelope, payload={k: v for k, v in stop.items() if k != 'cwd'}, ok=False)
            git(root, 'worktree', 'remove', str(outside / 'linked'))
        if PLATFORM == 'codex':
            run(root, 'hook', env=envelope, payload={**stop, 'stop_hook_active': 'false'}, ok=False)
            run(root, 'hook', env=envelope, payload={**payload, 'hook_event_name': 'Unsupported'}, ok=False)
        assert run(root, 'hook', env=envelope, payload=stop)['decision'] == 'block'
        run(root, 'hook', env=envelope, payload={**stop, 'stop_hook_active': True})
        assert run(root, 'status', '--run', rid)['status'] == 'paused'
        replacement = run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'Operator approved replacement session')
        assert replacement['notes'] == 'Next: preserve the dirty implementation and test behavior.'
        assert replacement['reason'] == 'Operator approved replacement session'
        payload['session_id'] = 'replacement'
        assert replacement['notes'] in run(root, 'hook', env=envelope, payload={**payload, 'source': 'startup'})['hookSpecificOutput']['additionalContext']
        run(root, 'hook', env=envelope, payload={**payload, 'source': 'clear'})
        assert run(root, 'status', '--run', rid)['status'] == 'paused'
        # Policy changes require explicit operator recovery; missing tools never pass.
        config['checks'][0]['command'] = 'nonexistent_launch_fixture_tool'
        policy.write_text(json.dumps(config))
        run(root, 'verify', 'checks', '--run', rid, ok=False)
        run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'Approve fixture policy')
        for _ in range(5):
            failed = run(root, 'verify', 'checks', '--run', rid, ok=False)
            assert not failed['ok'] and failed['checks'][0]['exit'] == 127
        capped = run(root, 'status', '--run', rid)
        assert capped['attempts'] == 5 and capped['status'] == 'blocked'
        assert 'terminal.json' in [p.name for p in (root / '.git/launch' / rid).iterdir()]
        run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'No reset grant')
        run(root, 'verify', 'checks', '--run', rid, ok=False)
        assert run(root, 'status', '--run', rid)['attempts'] == 5
        config['checks'][0].update(command="echo DIAGNOSTIC-MARKER; exit 1", timeout=5)
        policy.write_text(json.dumps(config))
        run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'Approve diagnostic fixture', '--reset-attempts')
        diagnostic = run(root, 'verify', 'checks', '--run', rid, ok=False)
        assert 'DIAGNOSTIC-MARKER' in diagnostic['checks'][0]['output']
        resumed = run(root, 'hook', env=envelope, payload=payload)
        # Command is intentionally still declared metadata; emitted diagnostics are excluded.
        recovered = json.loads(resumed['hookSpecificOutput']['additionalContext'].split('\n', 1)[1])
        assert 'output' not in recovered['receipt']['checks'][0]
        config['checks'][0].update(command='sleep 2', timeout=0.05)
        policy.write_text(json.dumps(config))
        run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'Approve timeout fixture', '--reset-attempts')
        assert run(root, 'verify', 'checks', '--run', rid, ok=False)['checks'][0]['reason'] == 'timeout'
        config['checks'][0].update(command='test -f tracked', timeout=5)
        policy.write_text(json.dumps(config))
        run(root, 'recover', '--run', rid, '--session', 'replacement', '--text', 'Approve passing policy', '--reset-attempts')
        run(root, 'verify', 'ready', '--run', rid, '--candidate', git(root, 'rev-parse', 'HEAD'), ok=False)
        # Fixture commits are disposable test setup, never a delivery operation.
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'candidate')
        run(root, 'hook', env=envelope, payload=payload, ok=False)  # stale checkpoint
        run(root, 'notes', '--run', rid, '--text', 'Candidate reconciled')
        state = run(root, 'status', '--run', rid)
        evidence = {k: state[k] for k in ('repo', 'worktree', 'branch', 'run', 'task', 'platform')}
        evidence.update(revision=git(root, 'rev-parse', 'HEAD'), evidence={'behavior': 'Synthetic behavior confirmed'})
        evidence_path = root / '.git/acceptance.json'
        evidence_path.write_text(json.dumps(evidence))
        receipt = run(root, 'verify', 'ready', '--run', rid, '--candidate', evidence['revision'], '--acceptance', str(evidence_path))
        assert receipt['platform'] == PLATFORM
        assert receipt['ok'] and run(root, 'status', '--run', rid)['status'] == 'awaiting_review'
        (root / 'tracked').write_text('changed after ready')
        run(root, 'hook', env=envelope, payload=payload)
        assert run(root, 'status', '--run', rid)['status'] == 'paused'
        manual = root / '.claude_states' / root.name / '00000001.json'
        manual.parent.mkdir(parents=True)
        manual.write_text('user-authored checkpoint, not runtime history\n')
        history = root / '.git/launch' / rid
        preserved = {path: path.read_bytes() for path in (manual, history / 'terminal.json',
                     history / 'paused.json', history / 'blocked.json', history / 'awaiting_review.json')}
        for n in range(20):
            run(root, 'notes', '--run', rid, '--text', f'phase {n}')
        assert len(list((root / '.git/launch' / rid).glob('[0-9]*.json'))) == 15
        assert all(path.read_bytes() == contents for path, contents in preserved.items())
        config['acceptance'] = []
        policy.write_text(json.dumps(config))
        run(root, 'validate-config', ok=False)
        config['acceptance'] = ['behavior']
        config['checks'] = []
        policy.write_text(json.dumps(config))
        run(root, 'validate-config', ok=False)
        config['checks'] = [{'command': 'true', 'cwd': '..', 'timeout': 1}]
        policy.write_text(json.dumps(config))
        run(root, 'validate-config', ok=False)
        active = root / '.git/launch/active.json'
        saved = json.loads(active.read_text())
        saved.update(status='running', deadline=1)
        # Keep policy equal so the fixture specifically observes the deadline outcome.
        saved['policy'][str(policy)] = __import__('hashlib').sha256(policy.read_bytes()).hexdigest()
        active.write_text(json.dumps(saved))
        expired = run(root, 'status', '--run', rid)
        assert expired['status'] == 'paused' and expired['reason'] == 'run deadline exhausted'
        active.write_text('{malformed')
        run(root, 'status', '--run', rid, ok=False)
        outside = root / 'not-a-repo'
        outside.mkdir()
        run(outside, 'verify', 'checks', ok=False)
    print('PASS: supervised runtime identity, recovery, checks, readiness, caps, retention and failure fixtures')

PLATFORM = 'claude'

namespace = runpy.run_path(str(RUNTIME))
with tempfile.TemporaryDirectory(prefix='launch-atomic-') as temporary:
    target = Path(temporary).resolve() / 'active.json'
    namespace['atomic'](target, {'sequence': 1})
    replace = os.replace
    def interrupted(*args):
        raise OSError('synthetic interrupted rename')
    try:
        os.replace = interrupted
        try:
            namespace['atomic'](target, {'sequence': 2})
            raise AssertionError('interrupted replacement passed')
        except OSError:
            pass
    finally:
        os.replace = replace
    assert json.loads(target.read_text()) == {'sequence': 1}
    assert list(Path(temporary).resolve().iterdir()) == [target]

with tempfile.TemporaryDirectory(prefix='launch-overlay-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'overlay')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    (root / 'noop.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
    (root / 'noop.sh').chmod(0o755)
    git(root, 'add', 'tracked', 'noop.sh')
    git(root, 'commit', '-m', 'fixture')
    for rel, content in (('.claude/hooks/launch.sh', namespace['HOOK_WRAPPER']), ('scripts/verify.sh', namespace['VERIFY_WRAPPER'])):
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    policy = root / '.claude/launch/verify.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': './noop.sh', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
    command = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"'
    hooks = {event: [{'matcher': matcher, 'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}] for event, matcher in [('SessionStart', 'startup|resume|compact|clear'), ('PreCompact', ''), ('Stop', '')]}
    hooks['Stop'].append({'hooks': [{'type': 'command', 'command': 'echo user-hook'}]})
    settings = root / '.claude/settings.json'
    settings.write_text(json.dumps({'hooks': hooks, 'permissions': {'allow': ['Bash(./noop.sh)']}}))
    commands = root / '.git/commands.txt'
    commands.write_text('./noop.sh\n')
    run(root, 'validate-overlay', '--commands', str(commands))
    hooks['Stop'].append(hooks['Stop'][0])
    settings.write_text(json.dumps({'hooks': hooks, 'permissions': {'allow': ['Bash(./noop.sh)']}}))
    run(root, 'validate-overlay', '--commands', str(commands), ok=False)
    hooks['Stop'].pop()
    settings.write_text(json.dumps({'hooks': hooks, 'permissions': {'allow': ['Bash(./noop.sh)']}}))
    commands.write_text('false\n')
    run(root, 'validate-overlay', '--commands', str(commands), ok=False)
    commands.write_text('./noop.sh\n')
print('PASS: overlay hook coexistence and contract binding')

# A shared verifier must dispatch to the selected installation.
import shutil
for order in (('claude', 'codex'), ('codex', 'claude')):
    with tempfile.TemporaryDirectory(prefix='launch-shared-') as temporary:
        base = Path(temporary).resolve()
        root = base / 'project'
        root.mkdir()
        git(root, 'init', '-b', 'shared')
        git(root, 'config', 'user.name', 'Fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        (root / 'tracked').write_text('fixture')
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'fixture')
        wrapper = root / 'scripts/verify.sh'
        wrapper.parent.mkdir()
        wrapper.write_text(namespace['VERIFY_WRAPPER'])
        env = {**os.environ, 'LAUNCH_RUN_ID': '', 'LAUNCH_PLATFORM': '',
               'CLAUDE_CONFIG_DIR': str(base / 'claude-home'), 'CODEX_HOME': str(base / 'codex-home')}
        for platform in order:
            home = Path(env['CODEX_HOME' if platform == 'codex' else 'CLAUDE_CONFIG_DIR'])
            installed = home / 'skills/onboard/scripts/launch-runtime.py'
            installed.parent.mkdir(parents=True)
            shutil.copyfile(RUNTIME, installed)
            policy = root / f'.{platform}/launch/verify.json'
            policy.parent.mkdir(parents=True)
            policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'test -f tracked', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
            result = subprocess.run(['bash', str(wrapper), 'checks'], cwd=base, env={**env, 'LAUNCH_PLATFORM': platform}, text=True, capture_output=True)
            assert result.returncode == 0, result.stderr
            assert json.loads(result.stdout)['platform'] == platform
        ambiguous = subprocess.run(['bash', str(wrapper), 'checks'], cwd=base, env=env, capture_output=True)
        assert ambiguous.returncode != 0
print('PASS: shared verifier dispatch and dual-config refusal in both setup orders')

# A successful shell leader does not prove its background check group is gone.
with tempfile.TemporaryDirectory(prefix='launch-check-group-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'fixture')
    policy = root / '.claude/launch/verify.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'sleep 2 &', 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}))
    result = run(root, 'verify', 'checks', ok=False)
    assert not result['ok'] and result['checks'][0]['group_gone']
    assert result['checks'][0]['reason'] == 'owned check process group remained'

# macOS drains EPERM while an exiting child is reaped; Linux keeps its group observable until reaping.
import threading
import time
closed = runpy.run_path(str(RUNTIME))['group_closed']
with subprocess.Popen(['/usr/bin/true'], start_new_session=True) as zombie:
    if sys.platform == 'linux':
        os.waitid(os.P_PID, zombie.pid, os.WEXITED | os.WNOWAIT)  # Observe exit without reaping.
        assert not closed(zombie.pid, 2), 'an unreaped Linux child still owns its process group'
        zombie.wait()
    else:
        time.sleep(.2)
        threading.Timer(.2, zombie.wait).start()
    assert closed(zombie.pid, 2), 'process group did not close after reaping'
live = subprocess.Popen(['/bin/sleep', '5'], start_new_session=True)
try:
    assert not closed(live.pid, 2)
finally:
    live.kill(); live.wait()
delivery_ns = runpy.run_path(str(RUNTIME.with_name('launch-delivery.py')))
draining = delivery_ns['run_owned'](['/bin/bash', '-c', 'exit 0'], '/', None)
assert draining.returncode == 0
real_killpg, probes = os.killpg, []
def exiting_once(pgid, sig):
    probes.append(sig)
    if sig == 0 and len(probes) == 1:
        raise PermissionError(1, 'Operation not permitted')
    return real_killpg(pgid, sig)
os.killpg = exiting_once
try:
    assert delivery_ns['run_owned'](['/bin/bash', '-c', 'exit 0'], '/', None).returncode == 0
finally:
    os.killpg = real_killpg
print('PASS: reaped process groups close; unreaped Linux children and live members remain open')

# LC-039 D4: Claude runs a tool when a PreToolUse hook exits 1, so a queue-launched worker
# (LAUNCH_MANIFEST set) is denied on hook failure; an ordinary session keeps the prior error.
with tempfile.TemporaryDirectory(prefix='launch-hook-closed-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    tool = {'hook_event_name': 'PreToolUse', 'cwd': str(root), 'session_id': 's', 'tool_name': 'Bash',
            'tool_input': {'command': 'git push origin HEAD'}}
    worker = {'LAUNCH_RUN_ID': 'missing-run', 'LAUNCH_MANIFEST': str(root / 'manifest.json')}
    refused = run(root, 'hook', env=worker, payload=tool)['hookSpecificOutput']
    assert refused['permissionDecision'] == 'deny' and refused['permissionDecisionReason'].startswith('Launch blocked:')
    run(root, 'hook', env={'LAUNCH_RUN_ID': 'missing-run'}, payload=tool, ok=False)
    run(root, 'hook', env=worker, payload={**tool, 'hook_event_name': 'Stop'}, ok=False)
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    git(root, 'commit', '--allow-empty', '-m', 'fixture')
    import contextlib, io, sys
    hook_ns = runpy.run_path(str(RUNTIME))
    def broken(self, payload, run):
        raise AttributeError('adapter module failed to load')
    hook_ns['Runtime'].hook = broken  # Outside the CLI's narrow error tuple.
    argv, stdin, saved_env = sys.argv, sys.stdin, dict(os.environ)
    try:
        sys.argv = ['launch-runtime.py', '--project', str(root), '--platform', 'claude', 'hook']
        os.environ.update(worker)
        sys.stdin, out = io.StringIO(json.dumps(tool)), io.StringIO()
        with contextlib.redirect_stdout(out):
            assert hook_ns['main']() == 0
        assert json.loads(out.getvalue())['hookSpecificOutput']['permissionDecision'] == 'deny'
        del os.environ['LAUNCH_MANIFEST']
        sys.stdin = io.StringIO(json.dumps(tool))
        try:
            hook_ns['main']()
            raise AssertionError('ordinary session swallowed a hook error')
        except AttributeError:
            pass
    finally:
        sys.argv, sys.stdin = argv, stdin
        os.environ.clear(); os.environ.update(saved_env)
print('PASS: a queue-launched Claude worker fails closed when the PreToolUse hook errors')

# LC-039 slice 2: inside the git dirs a prepared Claude worker may write only the canonical acceptance file.
adapter = runpy.run_path(str(RUNTIME.with_name('launch-claude.py')))
with tempfile.TemporaryDirectory(prefix='launch-protected-') as temporary:
    base = Path(temporary).resolve()
    common = base / 'repo/.git'
    worktree = common / 'launch-prepared/T-2'  # Prepared worktrees live inside the common git dir.
    gitdir = common / 'worktrees/T-2'
    for path in (worktree, gitdir / 'launch', common / 'launch-queue', common / 'info', common / 'hooks'):
        path.mkdir(parents=True)
    (base / 'elsewhere').mkdir()
    (base / 'config').mkdir()
    (worktree / 'linked').symlink_to(gitdir)
    protected = {'git_dir': str(gitdir), 'common_dir': str(common), 'worktree': str(worktree), 'config_dir': str(base / 'config')}
    def refusal(path, name='Write'):
        return adapter['tool_refusal'](name, {'file_path': str(path)}, lambda command: False, protected)
    for path in (gitdir / 'launch/active.json', common / 'launch-queue/active.json', common / 'config',
                 gitdir / 'config.worktree', common / 'info/exclude', common / 'hooks/pre-commit', worktree / '.git',
                 worktree / '../../worktrees/T-2/launch/active.json', worktree / 'linked/launch/active.json',
                 Path(str(gitdir).upper()) / 'launch/active.json', Path(str(gitdir / 'launch/active.json').replace('launch', 'LAUNCH')),
                 worktree / '.claude/hooks/launch.sh', worktree / '.claude/settings.json', worktree / '.claude/settings.local.json',
                 worktree / 'scripts/verify.sh', worktree / '.claude/launch/verify.json', worktree / '.Claude/Settings.json',
                 base / 'config/settings.json', base / 'config/skills/onboard/scripts/launch-runtime.py'):
        for name in ('Write', 'Edit'):
            assert refusal(path, name) == 'protected-path', (name, path)
    for path in (gitdir / 'acceptance.json', worktree / 'candidate', base / 'elsewhere/notes', worktree / '.claude/skills/x/SKILL.md'):
        assert refusal(path) is None, path
    assert adapter['tool_refusal']('Write', {'file_path': str(gitdir / 'launch/active.json')}, lambda command: False) is None
print('PASS: the prepared-Claude path rule protects both git dirs, the gitfile, .. and case variants, and admits acceptance')

# Controller git ignores worker-writable config: fsmonitor runs nothing, global excludes hide nothing.
with tempfile.TemporaryDirectory(prefix='launch-controller-git-') as temporary:
    base = Path(temporary).resolve()
    root = base / 'repo'
    root.mkdir()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', 'tracked')
    git(root, 'commit', '-m', 'fixture')
    marker = base / 'fsmonitor-ran'
    monitor = base / 'monitor.sh'
    monitor.write_text(f'#!/bin/sh\ntouch {marker}\nexit 1\n')
    monitor.chmod(0o755)
    git(root, 'config', 'core.fsmonitor', str(monitor))
    (root / 'hidden').write_text('untracked')
    excludes = base / 'excludes'
    excludes.write_text('hidden\n')
    # A global clean filter runs worker-chosen code on status and can make an edit look unchanged.
    filtered = base / 'filter-ran'
    clean = base / 'filter.sh'
    clean.write_text(f'#!/bin/sh\ntouch {filtered}\ngit show HEAD:tracked\n')
    clean.chmod(0o755)
    (base / 'attributes').write_text('tracked filter=probe\n')
    (base / 'gitconfig').write_text(f'[core]\n\texcludesFile = {excludes}\n\tattributesFile = {base / "attributes"}\n'
                                    f'[filter "probe"]\n\tclean = {clean}\n')
    (root / 'tracked').write_text('fixturx')  # Same size: status re-reads content through the clean filter.
    os.utime(root / 'tracked', (1, 1))
    ns = runpy.run_path(str(RUNTIME))
    saved = dict(os.environ)
    try:
        os.environ['GIT_CONFIG_GLOBAL'] = str(base / 'gitconfig')
        status = ns['git'](root, 'status', '--porcelain')
        assert 'hidden' not in status and 'tracked' not in status and marker.exists() and filtered.exists(), ('fixture must reproduce all three bypasses', status)
        marker.unlink(); filtered.unlink()
        with ns['controller_git']():
            assert '?? hidden' in ns['git'](root, 'status', '--porcelain', '--untracked-files=all')
        (root / 'hidden').unlink()
        # The filtered status above also refreshed the index, recording the edited file as clean.
        assert 'tracked' not in ns['git'](root, 'status', '--porcelain'), 'fixture must leave stale clean stat data'
        marker.unlink(); filtered.unlink(missing_ok=True)  # That outside status ran both again.
        index = (root / '.git/index').read_bytes()
        assert not ns['controller_clean'](root), 'controller trusted stale clean stat data or global config'
        assert (root / '.git/index').read_bytes() == index, 'the controller rewrote the worker index'
        assert not marker.exists(), 'controller git ran the worker-configured fsmonitor'
        assert not filtered.exists(), 'controller git ran a clean filter from global config'
        (root / 'tracked').write_text('fixture')
        assert ns['controller_clean'](root), 'restored content must read clean'
    finally:
        os.environ.clear(); os.environ.update(saved)
print('PASS: controller git ignores repository fsmonitor and global excludes and filters')

# The canonical verify commands pass only when declared and bound to a prepared controller.
ns = runpy.run_path(str(RUNTIME))
for command in ns['CANONICAL_VERIFY']:
    assert ns['canonical_verify'](command, [command], {'git_dir': '/g'}) is True
    assert ns['canonical_verify'](command, [], {'git_dir': '/g'}) is False
    assert ns['canonical_verify'](command, [command], None) is False
assert ns['canonical_verify']('bash scripts/verify.sh ready', ['bash scripts/verify.sh ready'], True) is False
print('PASS: canonical verify needs the exact declared command and a controller binding')

# LC-039 slice 3: index flags a declared check can set live in the real index; the fresh index has none.
with tempfile.TemporaryDirectory(prefix='launch-flags-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', 'tracked')
    git(root, 'commit', '-m', 'fixture')
    ns = runpy.run_path(str(RUNTIME))
    for flag in ('--skip-worktree', '--assume-unchanged'):
        git(root, 'update-index', flag, 'tracked')
        (root / 'tracked').write_text('hidden ' + flag)
        assert not git(root, 'status', '--porcelain'), 'fixture must hide the edit from the real index'
        assert not ns['controller_clean'](root), 'an index flag hid an edit from the clean check: ' + flag
        git(root, 'update-index', '--no' + flag[1:], 'tracked')
        git(root, 'checkout', '--', 'tracked')
        assert ns['controller_clean'](root)

# The controller's clean check sees through replace objects and an untracked catch-all .gitignore.
with tempfile.TemporaryDirectory(prefix='launch-clean-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', 'tracked')
    git(root, 'commit', '-m', 'fixture')
    ns = runpy.run_path(str(RUNTIME))
    assert ns['controller_clean'](root)
    (root / 'sub').mkdir()
    (root / 'sub/.gitignore').write_text('*\n')
    (root / 'sub/conftest.py').write_text('makes checks pass')
    assert not git(root, 'status', '--porcelain', '--untracked-files=all'), 'fixture must hide the untracked files'
    assert not ns['controller_clean'](root), 'an untracked catch-all .gitignore hid files from the clean check'
    for name in ('.gitignore', 'conftest.py'):
        (root / 'sub' / name).unlink()
    (root / 'tracked').write_text('edited')
    git(root, 'add', 'tracked')
    tree = git(root, 'write-tree')  # The index now matches the replacement tree.
    fake = git(root, 'commit-tree', tree, '-p', git(root, 'rev-parse', 'HEAD'), '-m', 'replacement')
    git(root, 'replace', git(root, 'rev-parse', 'HEAD'), fake)
    assert not git(root, 'status', '--porcelain'), 'fixture must make the edit look committed'
    assert not ns['controller_clean'](root), 'a replace object made an uncommitted edit look clean'
    runtime = ns['Runtime'](root, None, 'claude')
    with runtime.lock():
        import time as clock
        started = clock.monotonic()
        try:
            with runtime.lock(timeout=0.3):
                raise AssertionError('a held runtime lock was acquired twice')
        except ns['Invalid'] as error:
            assert 'busy' in str(error) and clock.monotonic() - started < 3
print('PASS: the controller clean check sees replace objects and catch-all ignores; its lock wait is bounded')

