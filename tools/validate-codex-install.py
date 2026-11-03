#!/usr/bin/env python3
"""Disposable global install/upgrade regression checks; no live-home writes."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
os.environ.setdefault('LAUNCH_CONTROL_NO_OPEN', '1')  # never open the report page from a test run

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('installer', ROOT / 'tools/install-codex.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
payload, mapping = m.bundles()
core = json.loads((ROOT / 'codex/core-skills.json').read_text())
assert set(core) == {p.name for p in (ROOT / 'skills').iterdir() if (p / 'SKILL.md').is_file()}
assert len(core) == 16
# LC-036: an installed Codex onboard-cursor is retired so Cursor resolves the Claude copy.
assert 'onboard-cursor' not in payload and m.RENAMED['onboard-cursor'] == 'onboard'
assert '\nskills onboard-cursor ' in (ROOT / 'install/codex-owned-digests.txt').read_text()
assert b'Document codebase as-is' in payload['research-codebase']['SKILL.md'][0]
assert b'codex-companion.mjs' not in payload['review-doc']['references/second-opinion.md'][0]
assert b'hooks:' not in payload['docs-create']['SKILL.md'][0]
assert 'scripts/invocation-proof.sh' not in payload['docs-create']
assert b'~/.codex' in payload['docs-create']['SKILL.md'][0]
claude_bootstrap = (ROOT / 'skills/docs-create/SKILL.md').read_text()
for required in ('PreToolUse:', 'invocation-proof.sh', 'Create only what applies or was requested',
                 'Update, never replace', 'command-based MCP entry', 'generated path', 'hook statement'):
    assert required in claude_bootstrap, required
for required in ('Create only what applies or was requested', 'Update, never replace', 'hook statement'):
    assert required.encode() in payload['docs-create']['references/workflow.md'][0]
for host, content in [('Claude', (ROOT / 'skills/docs-update/SKILL.md').read_text()),
                      ('Codex', payload['docs-update']['SKILL.md'][0].decode())]:
    assert 'whole scope' in content and 'useful content' in content and 'unless' in content, host
for name, files in payload.items():
    for relative, (content, _) in files.items():
        assert b'~/.Codex' not in content, (name, relative)
        if relative.endswith('.sh'):
            subprocess.run(['bash', '-n'], input=content, check=True)
        if relative.endswith('.py'):
            compile(content, name + '/' + relative, 'exec')
# Reset's read-only manifest is the actual renderer's manifest, not a new removal scope.
renderer = (ROOT / 'skills/onboard/scripts/render-report.sh').read_text()
manifest = payload['offboard']['references/claude-manifest.sh'][0].decode().strip()
assert manifest in renderer


def snapshot(path):
    return {str(p.relative_to(path)): (p.read_bytes(), p.stat().st_mode & 0o111)
            for p in path.rglob('*') if p.is_file()}


def install(target, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
        m.install(target, **kwargs)
    assert not errors.getvalue(), errors.getvalue()


def blocked(target, expected, **kwargs):
    before = snapshot(target)
    try:
        install(target, **kwargs)
    except ValueError as error:
        assert expected in str(error), str(error)
    else:
        raise AssertionError('expected conflict: ' + expected)
    assert snapshot(target) == before


with tempfile.TemporaryDirectory(prefix='lc-codex-install-') as scratch:
    scratch = Path(scratch).resolve()
    # Global installation uses the same model-tier validation as project conversion.
    bad_skill = scratch / 'bad-onboard'
    (bad_skill / 'references').mkdir(parents=True)
    bad_mapping = json.loads(json.dumps(mapping))
    bad_mapping['tiers']['sonnet']['reasoning_effort'] = 'invented'
    (bad_skill / 'references/codex-model-tiers.json').write_text(json.dumps(bad_mapping))
    original_skill = m.parity.SKILL
    m.parity.SKILL = bad_skill
    try:
        blocked(scratch / 'invalid-home', 'invalid mapped reasoning effort')
        assert not (scratch / 'invalid-home').exists()
    finally:
        m.parity.SKILL = original_skill
    target = scratch / 'home with spaces'
    install(target, dry_run=True)
    assert not target.exists()
    install(target)
    for name, files in payload.items():
        assert m.tree(target / 'skills' / name) == files
    assert len(list((target / 'agents').glob('*.toml'))) == 7
    first = snapshot(target)
    install(target)
    assert first == snapshot(target) and not (target / 'launch-control-backups').exists()
    # An unknown copy blocks absent skills too, before config/agents or backup writes.
    conflict = target / 'skills/docs-update/SKILL.md'
    conflict.write_text(conflict.read_text() + '\nUser content.\n')
    shutil.rmtree(target / 'skills/plan-write')
    blocked(target, str(target / 'skills/docs-update'))
    assert not (target / 'skills/plan-write').exists()
    # Scoped force does not authorize replacement of a second conflicting skill.
    second = target / 'skills/research-codebase/references/local.md'
    second.write_text('user resource')
    blocked(target, str(target / 'skills/research-codebase'), force_skills=['docs-update'])
    second.unlink()
    install(target, force_skills=['docs-update'])
    backups = list((target / 'launch-control-backups').glob('*/skills/docs-update/SKILL.md'))
    assert len(backups) == 1 and b'User content.' in backups[0].read_bytes()
    assert m.tree(target / 'skills/plan-write') == payload['plan-write']
    # Additional resources and executable-bit changes are ownership modifications.
    extra = target / 'skills/research-codebase/references/user.txt'
    extra.write_text('preserve me')
    blocked(target, str(target / 'skills/research-codebase'))
    extra.unlink()
    conflict.chmod(0o755)
    blocked(target, str(target / 'skills/docs-update'))
    conflict.chmod(0o644)
    linked = target / 'skills/research-codebase/references/link'
    linked.symlink_to(scratch / 'absent')
    blocked(target, 'symlink', force_skills=['research-codebase'])
    linked.unlink()
    # A missing config default stops before newly absent skills are restored.
    config = target / 'config.toml'
    saved = config.read_bytes()
    config.write_text('model = "user"\n')
    shutil.rmtree(target / 'skills/plan-write')
    blocked(target, 'lacks agents.default_subagent_model')
    config.write_bytes(saved)
    install(target)
    # Native reset works without any Claude home or renderer, and leaves Codex artifacts.
    project = scratch / 'project'
    project.mkdir()
    subprocess.run(['git', 'init', '-q', str(project)], check=True)
    (project / '.codex').mkdir()
    (project / '.codex/user.txt').write_text('untouched')
    result = subprocess.run(['bash', str(target / 'skills/offboard/scripts/reset.sh')],
                            cwd=project, env=dict(os.environ, CLAUDE_CONFIG_DIR=str(scratch / 'missing')),
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert (project / '.codex/user.txt').read_text() == 'untouched'
    # Simulate a released earlier bundle in a disposable source manifest. Never adopt a
    # live hash into the real ownership registry. Upgrade replaces the entire resource set.
    fixture = scratch / 'source'
    (fixture / 'install').mkdir(parents=True)
    shutil.copytree(ROOT / 'agents', fixture / 'agents')
    old = target / 'skills/research-codebase'
    (old / 'references/retired.md').write_text('old bundled resource')
    old_bytes = m.tree(old)
    registry = (ROOT / 'install/codex-owned-digests.txt').read_text()
    (fixture / 'install/codex-owned-digests.txt').write_text(registry + 'skills research-codebase ' + m.digest(old_bytes) + '\n')
    original_bundles, original_root = m.bundles, m.ROOT
    m.bundles = lambda: (payload, mapping)
    m.ROOT = fixture
    try:
        install(target)
    finally:
        m.ROOT, m.bundles = original_root, original_bundles
    assert m.tree(old) == payload['research-codebase']
    backup = list((target / 'launch-control-backups').glob('*/skills/research-codebase'))
    assert len(backup) == 1 and m.tree(backup[0]) == old_bytes
    assert not list((target / 'skills').glob('*.bak*'))
    # A copy failure after one published upgrade rolls both complete bundles back.
    old_versions = {}
    for name in ('plan-write', 'research-codebase'):
        path = target / 'skills' / name
        (path / 'references/retired.md').write_text('earlier release')
        old_versions[name] = m.tree(path)
    (fixture / 'install/codex-owned-digests.txt').write_text(registry + ''.join(
        'skills ' + name + ' ' + m.digest(files) + '\n' for name, files in old_versions.items()))
    original_copy = m.shutil.copytree
    copies = [0]
    for failure in (OSError, KeyboardInterrupt, ValueError):
        copies[0] = 0
        def fail_second(*args, **kwargs):
            copies[0] += 1
            if copies[0] == 2:
                raise failure('injected copy failure')
            return original_copy(*args, **kwargs)
        m.bundles, m.ROOT, m.shutil.copytree = lambda: (payload, mapping), fixture, fail_second
        try:
            try:
                install(target)
            except failure as error:
                assert 'injected copy failure' in str(error)
            else:
                raise AssertionError('expected injected failure')
            for name, files in old_versions.items():
                assert m.tree(target / 'skills' / name) == files, failure.__name__
        finally:
            m.shutil.copytree = original_copy
            m.ROOT, m.bundles = original_root, original_bundles
    # A concurrent symlink is preserved with its entire bundle; other upgrades recover.
    linked = target / 'skills/plan-write/user-link'
    def symlink_then_fail(src, dest, *args, **kwargs):
        if Path(src).name == 'research-codebase':
            linked.symlink_to(scratch / 'absent-user-target')
            raise OSError('injected failure after symlink')
        return original_copy(src, dest, *args, **kwargs)
    m.bundles, m.ROOT, m.shutil.copytree = lambda: (payload, mapping), fixture, symlink_then_fail
    try:
        try:
            install(target)
        except OSError as error:
            assert 'injected failure after symlink' in str(error)
        else:
            raise AssertionError('expected symlink failure')
        assert linked.is_symlink() and os.readlink(linked) == str(scratch / 'absent-user-target')
        assert m.tree(target / 'skills/research-codebase') == old_versions['research-codebase']
        backups = list((target / 'launch-control-backups').glob('*/skills/plan-write'))
        assert len(backups) == 1 and m.tree(backups[0]) == old_versions['plan-write']
        linked.unlink()
        assert m.tree(target / 'skills/plan-write') == payload['plan-write']
    finally:
        m.shutil.copytree = original_copy
        m.ROOT, m.bundles = original_root, original_bundles
    # An interrupted fresh install removes already-published bundles and re-raises.
    fresh = scratch / 'interrupted-fresh'
    def interrupt_third(src, dest, *args, **kwargs):
        if Path(src).name == 'plan-write':
            raise KeyboardInterrupt('injected fresh interrupt')
        return original_copy(src, dest, *args, **kwargs)
    m.shutil.copytree = interrupt_third
    try:
        try:
            install(fresh)
        except KeyboardInterrupt as error:
            assert 'injected fresh interrupt' in str(error)
        else:
            raise AssertionError('expected fresh interrupt')
        assert not snapshot(fresh)
    finally:
        m.shutil.copytree = original_copy
    # Backup pruning, seeded before the restore below: only complete (marked) backups of the
    # same kind with the installer's own timestamp name are removed.
    backup_root = target / 'launch-control-backups'
    marker_name = m.parity.BACKUP_MARKER
    upgrade_backup = backup[0].parent.parent
    assert (upgrade_backup / marker_name).read_text() == 'codex-skills\n'
    forced = list(backup_root.glob('*/skills/docs-update/SKILL.md'))
    assert len(forced) == 1, 'the forced (user-content) backup was pruned'
    forced_backup = forced[0].parent.parent.parent
    assert not (forced_backup / marker_name).exists()
    for name, kind in (('manual-keep', 'codex-skills'), ('20200101-000000-000000', 'codex-agents'),
                       ('20200101-000001-000000', 'codex-skills')):
        (backup_root / name).mkdir()
        (backup_root / name / marker_name).write_text(kind + '\n')
    (scratch / 'prune-outside').mkdir()
    (scratch / 'prune-outside' / marker_name).write_text('codex-skills\n')
    (backup_root / '20200101-000002-000000').symlink_to(scratch / 'prune-outside')
    # Restore via the same test-only released-version registry.
    m.bundles, m.ROOT = lambda: (payload, mapping), fixture
    try:
        install(target)
    finally:
        m.ROOT, m.bundles = original_root, original_bundles
    assert not upgrade_backup.exists() and not (backup_root / '20200101-000001-000000').exists()
    assert (backup_root / 'manual-keep' / marker_name).is_file()
    assert (backup_root / '20200101-000000-000000' / marker_name).is_file()
    assert (backup_root / '20200101-000002-000000').is_symlink() and (scratch / 'prune-outside' / marker_name).is_file()
    assert forced_backup.exists() and backups[0].exists(), 'user-content or failed-run backup was pruned'
    marked = [d for d in backup_root.iterdir() if not d.is_symlink()
              and m.parity.re.fullmatch(r'\d{8}-\d{6}-\d{6}', d.name)
              and (d / marker_name).is_file() and (d / marker_name).read_text() == 'codex-skills\n']
    assert len(marked) == 1 and marked[0] != upgrade_backup
    # Concurrent destinations belong to the user, even when publication fails.
    for race in ('fresh', 'upgrade', 'modified-published', 'replaced-published'):
        upgrading = race == 'upgrade'
        raced_home = scratch / ('race-' + race)
        if upgrading:
            install(raced_home)
            for name, files in old_versions.items():
                (raced_home / 'skills' / name / 'references/retired.md').write_text('earlier release')
        raced_name = 'research-codebase'
        raced_dest = raced_home / 'skills' / raced_name
        def create_concurrent_destination(src, dest, *args, **kwargs):
            result = original_copy(src, dest, *args, **kwargs)
            if Path(src).name == raced_name:
                if race.endswith('published'):
                    previous = raced_home / 'skills/docs-create'
                    if race == 'replaced-published':
                        previous.rename(raced_home / 'user-moved-bundle')
                        previous.mkdir()
                    (previous / 'user.txt').write_text('concurrent user edit')
                    raise OSError('injected failure after concurrent edit')
                raced_dest.mkdir(parents=True)
                (raced_dest / 'user.txt').write_text('concurrent user content')
            return result
        m.bundles, m.ROOT, m.shutil.copytree = lambda: (payload, mapping), fixture, create_concurrent_destination
        try:
            try:
                install(raced_home)
            except OSError:
                pass
            else:
                raise AssertionError('expected concurrent publication failure')
            if race.endswith('published'):
                assert (raced_home / 'skills/docs-create/user.txt').read_text() == 'concurrent user edit'
                assert not raced_dest.exists()
                continue
            assert (raced_dest / 'user.txt').read_text() == 'concurrent user content'
            if upgrading:
                assert m.tree(raced_home / 'skills/plan-write') == old_versions['plan-write']
                backups = list((raced_home / 'launch-control-backups').glob('*/skills/research-codebase'))
                assert len(backups) == 1 and m.tree(backups[0]) == old_versions['research-codebase']
            else:
                assert not (raced_home / 'skills/docs-create').exists()
        finally:
            m.shutil.copytree = original_copy
            m.ROOT, m.bundles = original_root, original_bundles
    # A later agent failure must not remove a concurrently edited/replaced config.
    original_open = Path.open
    for race in ('unchanged', 'modified', 'replaced'):
        raced_home = scratch / ('config-race-' + race)
        config = raced_home / 'config.toml'
        def fail_agent_open(path, mode='r', *args, **kwargs):
            if path.parent == raced_home / 'agents' and mode == 'x':
                if race == 'replaced':
                    config.rename(raced_home / 'user-moved-config.toml')
                if race != 'unchanged':
                    config.write_text('concurrent config content')
                raise OSError('injected agent creation failure')
            return original_open(path, mode, *args, **kwargs)
        Path.open = fail_agent_open
        try:
            try:
                install(raced_home)
            except OSError as error:
                assert 'injected agent creation failure' in str(error)
            else:
                raise AssertionError('expected agent creation failure')
            if race == 'unchanged':
                assert not config.exists()
            else:
                assert config.read_text() == 'concurrent config content'
            assert not any((raced_home / 'skills').iterdir())
        finally:
            Path.open = original_open
    # Replacing a public path during quarantine must not trick rollback into deleting it.
    original_rename = Path.rename
    for directory in (False, True):
        for timing in ('before', 'after'):
            case = scratch / ('quarantine-' + str(directory) + '-' + timing)
            case.mkdir()
            dest, held = case / 'published', case / 'held'
            def put(content):
                if directory:
                    dest.mkdir()
                (dest / 'content' if directory else dest).write_text(content)
            put('installer content')
            identity = dest.stat()
            before = m.tree(dest) if directory else dest.read_text()
            def replace_during_rename(path, target):
                if path == dest and timing == 'before':
                    original_rename(path, case / 'user-moved-original')
                    put('concurrent content')
                result = original_rename(path, target)
                if path == dest and timing == 'after':
                    put('concurrent content')
                return result
            Path.rename = replace_during_rename
            try:
                m.remove_published(dest, (identity.st_dev, identity.st_ino),
                                   lambda path: (m.tree(path) if directory else path.read_text()) == before, held)
                assert (dest / 'content' if directory else dest).read_text() == 'concurrent content'
                assert not held.exists()
            finally:
                Path.rename = original_rename
    # LC-036: a released old-name copy is retired to the backup root; a user's own skill that
    # shares an old name stays in discovery.
    retire_home = scratch / 'retire-home'
    install(retire_home)
    (retire_home / 'skills/foundations').mkdir()
    (retire_home / 'skills/foundations/SKILL.md').write_text('released old foundations\n')
    (retire_home / 'skills/research').mkdir()
    (retire_home / 'skills/research/SKILL.md').write_text('my own research skill\n')
    retire_fixture = scratch / 'retire-source'
    (retire_fixture / 'install').mkdir(parents=True)
    shutil.copytree(ROOT / 'agents', retire_fixture / 'agents')
    (retire_fixture / 'install/codex-owned-digests.txt').write_text(
        (ROOT / 'install/codex-owned-digests.txt').read_text()
        + 'skills foundations ' + m.digest(m.tree(retire_home / 'skills/foundations')) + '\n')
    original_bundles, original_root = m.bundles, m.ROOT
    m.bundles = lambda: (payload, mapping)
    m.ROOT = retire_fixture
    try:
        install(retire_home)
    finally:
        m.ROOT, m.bundles = original_root, original_bundles
    assert not (retire_home / 'skills/foundations').exists(), 'released old-name copy stayed in discovery'
    assert list((retire_home / 'launch-control-backups').glob('*/skills/foundations/SKILL.md')), 'retired copy not backed up'
    assert (retire_home / 'skills/research/SKILL.md').read_text() == 'my own research skill\n', 'user skill was retired'
    # Both public CLI entrypoints use the same ownership gate.
    for command in ([str(ROOT / 'install.sh'), '--codex', '--dry-run'],
                    [sys.executable, str(ROOT / 'skills/onboard/scripts/codex-parity.py'), '--install', str(ROOT), '--target', str(target), '--dry-run']):
        result = subprocess.run(command, env=dict(os.environ, CODEX_HOME=str(target)), capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
print('Codex global checks passed: 16 core skills, bundles, idempotence, upgrades/backups, conflicts, scoped force, symlinks, native reset.')
