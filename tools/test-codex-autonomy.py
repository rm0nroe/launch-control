#!/usr/bin/env python3
"""Disposable native Launch generation fixtures; no installed Codex required."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import contextlib


ROOT = Path(__file__).resolve().parents[1]
PARITY = ROOT / 'skills/onboard/scripts/codex-parity.py'
RUNTIME = ROOT / 'skills/onboard/scripts/launch-runtime.py'


def git(root, *args):
    subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)


@contextlib.contextmanager
def fixture():
  with tempfile.TemporaryDirectory(prefix='codex-autonomy-') as temporary:
    root = Path(temporary).resolve()
    git(root, 'init', '-b', 'fixture')
    git(root, 'config', 'user.name', 'Fixture')
    git(root, 'config', 'user.email', 'fixture@example.invalid')
    (root / 'tracked').write_text('fixture')
    git(root, 'add', 'tracked')
    git(root, 'commit', '-m', 'fixture')
    source = root / 'rendered/.claude'
    launch = source / 'skills/launch/references'
    launch.mkdir(parents=True)
    (launch.parent / 'SKILL.md').write_text('---\nname: launch\ndescription: fixture\n---\n'
                                             '${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/references/launch-autonomy.md\n')
    for name in ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md'):
        (launch / name).write_text(name + '\n')
    policy = root / 'input-policy.json'
    policy.write_text(json.dumps({'schema': 1, 'checks': [{'command': 'test -f tracked', 'cwd': '.', 'timeout': 5}],
                                  'acceptance': ['behavior']}))
    commands = root / 'input-commands.txt'
    commands.write_text('test -f tracked\n')
    yield root, source, policy, commands


def invoke(root, source, policy, commands, *extra, ok=True):
    result = subprocess.run(['python3', str(PARITY), '--project', str(root), '--source', str(source), '--codex',
                             '--enable-autonomy', '--autonomy-config', str(policy), '--autonomy-commands', str(commands),
                             *extra], text=True, capture_output=True)
    assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
    return result


with fixture() as (project, source, policy, commands):
    empty = project / 'empty/.claude'
    empty.mkdir(parents=True)
    invoke(project, empty, policy, commands, ok=False)
    assert not (project / '.codex').exists()
    preview = invoke(project, source, policy, commands, '--dry-run')
    assert 'PLANNED ' in preview.stdout and not (project / '.codex').exists()
    invoke(project, source, policy, commands)
    assert not (project / '.codex/config.toml').exists()
    runtime = subprocess.run(['python3', str(RUNTIME), '--project', str(project), '--platform', 'codex',
                              'validate-overlay', '--commands', str(commands)], text=True, capture_output=True)
    assert runtime.returncode == 0, runtime.stderr
    hooks = json.loads((project / '.codex/hooks.json').read_text())
    command = 'bash ' + __import__('shlex').quote(str(project / '.codex/hooks/launch.sh'))
    session = hooks['hooks']['SessionStart'][0]['hooks'][0]
    assert session['command'] == command and session['timeout'] == 10 and session['additionalContextLimit'] == 10000
    assert hooks['hooks']['PreCompact'][0]['matcher'] == 'manual|auto'
    before = {p.relative_to(project).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in (project / '.codex').rglob('*') if p.is_file()}
    invoke(project, source, policy, commands)
    after = {p.relative_to(project).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in (project / '.codex').rglob('*') if p.is_file()}
    assert before == after
    alias = project.parent / (project.name + '-alias')
    alias.symlink_to(project, target_is_directory=True)
    invoke(alias, source, policy, commands)
    (project / '.codex/skills/launch/references/delivery.md').write_text('stale\n')
    invoke(project, source, policy, commands, ok=False)
    (project / '.codex/skills/launch/references/delivery.md').write_text('delivery.md\n')
    wrapper = project / '.codex/hooks/launch.sh'
    wrapper.write_text('user replacement\n')
    invoke(project, source, policy, commands, ok=False)

with fixture() as (project, source, policy, commands):
    codex = project / '.codex'
    codex.mkdir()
    (codex / 'config.toml').write_text('[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n')
    (codex / 'hooks.json').write_text(json.dumps({'metadata': {'owner': 'user'}, 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo user'}]}]}}))
    invoke(project, source, policy, commands)
    hooks = json.loads((codex / 'hooks.json').read_text())
    assert hooks['metadata'] == {'owner': 'user'}
    assert hooks['hooks']['Stop'][0]['hooks'][0]['command'] == 'echo user'

with fixture() as (project, source, policy, commands):
    (project / '.codex').mkdir()
    (project / '.codex/config.toml').write_text('[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n')
    victim = project / 'scripts/verify.sh'
    victim.parent.mkdir()
    victim.write_text('user content\n')
    before = victim.read_bytes()
    invoke(project, source, policy, commands, ok=False)
    assert victim.read_bytes() == before and not (project / '.codex/hooks.json').exists()

with fixture() as (project, source, policy, commands):
    (project / '.codex').mkdir()
    (project / '.codex/config.toml').write_text('[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n[features]\nhooks = false\n')
    invoke(project, source, policy, commands, ok=False)
    assert not (project / '.codex/hooks.json').exists()

with fixture() as (project, source, policy, commands):
    shadow = project / '.agents/skills/launch'
    shadow.mkdir(parents=True)
    invoke(project, source, policy, commands, ok=False)
    assert not (project / '.codex').exists()

with fixture() as (project, source, policy, commands):
    (project / '.codex').mkdir()
    (project / '.codex/config.toml').write_text('[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n')
    command = 'bash ' + __import__('shlex').quote(str(project / '.codex/hooks/launch.sh'))
    (project / '.codex/hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}]}}))
    invoke(project, source, policy, commands, ok=False)

# Interrupted publication restores every generated path. This tests the shared transaction,
# without invoking a live Codex hook.
namespace = runpy.run_path(str(PARITY))
assert '${CODEX_HOME:-$HOME/.codex}' in namespace['native_text']('${CLAUDE_CONFIG_DIR:-$HOME/.claude}')
with fixture() as (project, source, policy, commands):
    base = {'.codex/config.toml': b'[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n'}
    globals_ = namespace['autonomy_overlay'].__globals__
    original_hook_document = globals_['native_hook_document']
    def mutate_after_read(*args):
        result = original_hook_document(*args)
        path = project / 'scripts/verify.sh'
        path.parent.mkdir(exist_ok=True)
        path.write_text('concurrent user file\n')
        return result
    globals_['native_hook_document'] = mutate_after_read
    try:
        changes, _, snapshots, _, _, _ = namespace['autonomy_overlay'](project, project / '.codex', policy, commands, base)
        try:
            namespace['replace_files'](project, changes, snapshots)
            raise AssertionError('concurrent write passed')
        except ValueError:
            pass
    finally:
        globals_['native_hook_document'] = original_hook_document
    assert (project / 'scripts/verify.sh').read_text() == 'concurrent user file\n'
with fixture() as (project, source, policy, commands):
    base = {'.codex/config.toml': b'[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n'}
    changes, _, snapshots, _, _, _ = namespace['autonomy_overlay'](project, project / '.codex', policy, commands, base)
    globals_ = namespace['replace_files'].__globals__
    original = globals_['publish_file']
    def interrupted(staged, dest):
        nonlocal_calls[0] += 1
        if nonlocal_calls[0] == 2:
            raise OSError('synthetic interruption')
        original(staged, dest)
    nonlocal_calls = [0]
    globals_['publish_file'] = interrupted
    try:
        try:
            namespace['replace_files'](project, changes, snapshots)
            raise AssertionError('interrupted transaction passed')
        except OSError:
            pass
    finally:
        globals_['publish_file'] = original
    assert not (project / '.codex/config.toml').exists()
    assert not (project / '.codex/hooks/launch.sh').exists()
    assert not (project / 'scripts/verify.sh').exists()

print('PASS: native Codex autonomy preview, generation, idempotency, coexistence, collisions and rollback')

# Selection remains opt-in and canonical for relocated controller paths.
ns = runpy.run_path(str(RUNTIME))
assert ns['wrappers']() == (ns['VERIFY_WRAPPER'], ns['CODEX_HOOK_WRAPPER'])
with tempfile.TemporaryDirectory(prefix='selected-runtime-') as temporary:
    selected = Path(temporary).resolve() / "runtime's copy.py"
    selected.write_bytes(RUNTIME.read_bytes())
    digest = hashlib.sha256(selected.read_bytes()).hexdigest()
    verifier, hook = ns['wrappers'](selected, digest)
    assert '${CODEX_HOME' not in verifier and '${CLAUDE_CONFIG_DIR' in verifier
    assert __import__('shlex').quote(str(selected)) in verifier
    for path, expected in ((selected, '0' * 64), (Path('relative'), digest)):
        try:
            ns['wrappers'](path, expected)
            raise AssertionError('unsafe selection accepted')
        except ns['Invalid']:
            pass
    alias = selected.with_name('alias.py')
    alias.symlink_to(selected)
    try:
        ns['wrappers'](alias, digest)
        raise AssertionError('symlink controller accepted')
    except ns['Invalid']:
        pass

with fixture() as (project, source, policy, commands):
    (project / '.codex').mkdir()
    (project / '.codex/config.toml').write_text('[agents]\ndefault_subagent_model = "gpt"\ndefault_subagent_reasoning_effort = "low"\n')
    (project / '.codex/hooks.json').write_text(json.dumps({'metadata': 'keep', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo user'}]}]}}))
    invoke(project, source, policy, commands)
    receipt = project / '.codex/launch-control-launch-ownership.json'
    before = json.loads(receipt.read_text())
    selected = ['--autonomy-controller', str(RUNTIME), '--autonomy-controller-digest', hashlib.sha256(RUNTIME.read_bytes()).hexdigest(), '--autonomy-shared-root', str(project)]
    invoke(project, source, policy, commands, *selected)
    after = json.loads(receipt.read_text())
    assert set(after['files']) == set(before['files']) and after['hooks_before'] == before['hooks_before']
    assert json.loads((project / '.codex/hooks.json').read_text())['metadata'] == 'keep'
    snapshot = {str(p): p.read_bytes() for p in project.rglob('*') if p.is_file()}
    invoke(project, source, policy, commands, *selected)
    assert snapshot == {str(p): p.read_bytes() for p in project.rglob('*') if p.is_file()}
    check = subprocess.run(['python3', str(RUNTIME), '--project', str(project), '--platform', 'codex', 'validate-overlay', '--commands', str(commands), '--controller', str(RUNTIME), '--controller-digest', hashlib.sha256(RUNTIME.read_bytes()).hexdigest(), '--shared-root', str(project)], capture_output=True, text=True)
    assert check.returncode == 0, check.stderr
    (project / '.codex/hooks/launch.sh').write_text('user change')
    invoke(project, source, policy, commands, *selected, ok=False)

# Both real worktrees use the same selected delivery launcher and verifier, preserving ownership.
with fixture() as (project, source, policy, commands):
    selected = ['--autonomy-controller', str(RUNTIME), '--autonomy-controller-digest', hashlib.sha256(RUNTIME.read_bytes()).hexdigest(), '--autonomy-shared-root', str(project)]
    invoke(project, source, policy, commands, *selected)
    linked = project / '.git/launch-prepared/TEST-1'
    git(project, 'worktree', 'add', '-b', 'selected', str(linked), 'HEAD')
    invoke(linked, source, policy, commands, *selected)
    assert (linked / '.codex/hooks/launch.sh').read_bytes() == (project / '.codex/hooks/launch.sh').read_bytes()
    for root in (project, linked):
        record = json.loads((root / '.codex/launch-control-launch-ownership.json').read_text())
        assert {'.codex/launch/verify.json', '.codex/hooks/launch.sh', 'scripts/verify.sh'} <= set(record['files'])
        result = subprocess.run(['bash', str(root / 'scripts/verify.sh'), 'checks'], cwd=root,
            env={**os.environ, 'LAUNCH_PLATFORM': 'codex', 'LAUNCH_RUN_ID': ''}, capture_output=True, text=True)
        assert result.returncode == 0 and json.loads(result.stdout)['checks'][0]['group_gone'], result.stderr
    before = (linked / '.codex/hooks/launch.sh').read_bytes()
    (project / '.codex/hooks/launch.sh').write_text('user changed primary')
    invoke(linked, source, policy, commands, *selected, ok=False)
    assert (linked / '.codex/hooks/launch.sh').read_bytes() == before
print('PASS: selected runtime, owned refresh and primary/linked canonical verification')
