#!/usr/bin/env python3
"""Run disposable agent update checks without installing into a live home."""
import contextlib
import importlib.util
import io
import shutil
import tempfile
from pathlib import Path
from unittest.mock import patch
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('parity', ROOT / 'skills/onboard/scripts/codex-parity.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
mapping = p.read_mapping()


def put(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')


def files(root):
    return {str(path.relative_to(root)): path.read_bytes() for path in root.rglob('*') if path.is_file()}


def update(source, target, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()):
        p.update_agents(source, target, mapping, **kwargs)


def fails(call, message):
    try:
        call()
    except ValueError as error:
        assert message in str(error), error
    else:
        raise AssertionError('expected ' + message)


with tempfile.TemporaryDirectory(prefix='lc021-') as scratch:
    root = Path(scratch)
    source, target = root / 'project/.claude', root / 'project/.codex'
    original = '---\nname: inspector\ndescription: Project review\nmodel: sonnet\ntools: Read, Grep\n---\nCheck project-specific café rules.\n'
    put(source / 'agents/inspector.md', original)
    planned, _ = p.generate(source, target, mapping)
    for relative, content in planned.items():
        put(target / relative, content)
    put(target / 'skills/custom/SKILL.md', 'user skill')
    put(target / 'config.toml', '# user authoritative\n')
    before = files(target)
    put(source / 'agents/inspector.md', original + 'New project rule.\n')
    update(source, target, dry_run=True)
    assert files(target) == before
    update(source, target)
    agent = target / 'agents/inspector.toml'
    assert b'New project rule.' in agent.read_bytes()
    assert b'project-specific' in agent.read_bytes()
    backups = list((target / 'launch-control-backups').glob('*/agents/inspector.toml'))
    assert len(backups) == 1 and backups[0].read_bytes() == before['agents/inspector.toml']
    assert (target / 'config.toml').read_bytes() == before['config.toml']
    assert (target / 'skills/custom/SKILL.md').read_bytes() == before['skills/custom/SKILL.md']
    stable = files(target)
    update(source, target)
    assert files(target) == stable
    # Old projects lacking records are preserved, even when identical to current output.
    record = target / 'launch-control-agent-ownership/inspector.json'
    record.unlink()
    stable = files(target)
    update(source, target)
    assert files(target) == stable and not record.exists()
    put(source / 'agents/inspector.md', original + 'Later release.\n')
    fails(lambda: update(source, target), 'conflicts')
    assert files(target) == stable
    fails(lambda: update(source, target, force_agents=['../config']), 'unknown --force-agent')
    update(source, target, force_agents=['inspector'])
    assert b'Later release.' in agent.read_bytes() and record.exists()
    # The forced run backed up an unowned agent (user content): left unmarked, while the first
    # (owned, marked) backup was pruned so only one version back remains.
    project_backups = list((target / 'launch-control-backups').iterdir())
    assert len(project_backups) == 1 and not (project_backups[0] / p.BACKUP_MARKER).exists()
    put(agent, 'customized')
    stable = files(target)
    fails(lambda: update(source, target), 'conflicts')
    assert files(target) == stable
    # A named force cannot authorize another modified agent.
    second = original.replace('inspector', 'dispatcher')
    put(source / 'agents/dispatcher.md', second)
    put(target / 'agents/dispatcher.toml', 'other custom')
    fails(lambda: update(source, target, force_agents=['inspector']), 'dispatcher')
    assert agent.read_text() == 'customized'
    (target / 'agents/dispatcher.toml').unlink()
    update(source, target, force_agents=['inspector'])
    project_backups = list((target / 'launch-control-backups').iterdir())
    assert len(project_backups) == 2, 'a user-content backup was pruned'
    assert not any((d / p.BACKUP_MARKER).exists() for d in project_backups)
    # A released global install from before receipts upgrades by source-derived manifest.
    pack = root / 'pack'
    shutil.copytree(ROOT / 'agents', pack / 'agents')
    shutil.copytree(ROOT / 'install', pack / 'install')
    home = root / 'home'
    for path in (pack / 'agents').glob('*.md'):
        put(home / 'agents' / (path.stem + '.toml'), p.agent_text(path.read_text(), mapping))
    old_global = files(home)
    changed = next((pack / 'agents').glob('*.md'))
    changed.write_text(changed.read_text() + '\nNew global release.\n')
    digest = p.hashlib.sha256(p.agent_text(changed.read_text(), mapping).encode()).hexdigest()
    manifest = pack / 'install/codex-agent-digests.txt'
    manifest.write_text(manifest.read_text() + changed.stem + ' ' + digest + '\n')
    update(pack, home, install=True)
    assert b'New global release.' in (home / 'agents' / (changed.stem + '.toml')).read_bytes()
    assert next((home / 'launch-control-backups').glob('*/agents/*.toml')).read_bytes() == old_global['agents/' + changed.stem + '.toml']
    # A second released update keeps one version back: the first (marked) backup is pruned, an
    # unmarked failed-run dir and another kind's backup are not.
    global_backups = home / 'launch-control-backups'
    first_global = next(global_backups.iterdir())
    assert (first_global / p.BACKUP_MARKER).read_text() == 'codex-agents\n'
    put(global_backups / '20200101-000000-000000/agents/x.toml', 'failed-run original')
    put(global_backups / '20200101-000001-000000' / p.BACKUP_MARKER, 'codex-skills\n')
    changed.write_text(changed.read_text() + '\nSecond global release.\n')
    digest = p.hashlib.sha256(p.agent_text(changed.read_text(), mapping).encode()).hexdigest()
    manifest.write_text(manifest.read_text() + changed.stem + ' ' + digest + '\n')
    update(pack, home, install=True)
    assert not first_global.exists()
    assert (global_backups / '20200101-000000-000000/agents/x.toml').read_text() == 'failed-run original'
    assert (global_backups / '20200101-000001-000000' / p.BACKUP_MARKER).is_file()
    assert len([d for d in global_backups.iterdir() if (d / p.BACKUP_MARKER).is_file()
                and (d / p.BACKUP_MARKER).read_text() == 'codex-agents\n']) == 1
    # Faults after publication roll back bytes and receipts; concurrent content survives.
    for failure in ('oserror', 'interrupt', 'modified', 'symlink', 'appeared'):
        dest = root / failure
        update(source, dest)
        baseline = files(dest)
        put(source / 'agents/inspector.md', (source / 'agents/inspector.md').read_text() + 'Next.\n')
        real_publish = p.publish_file
        calls = []
        def broken(staged, path):
            calls.append(path)
            if len(calls) == 2:
                first = calls[0]
                if failure == 'modified':
                    first.write_text('concurrent content')
                if failure == 'symlink':
                    first.unlink()
                    first.symlink_to(root / 'external')
                if failure == 'interrupt':
                    raise KeyboardInterrupt()
                raise OSError('injected failure')
            if failure == 'appeared':
                path.write_text('concurrent appearance')
            real_publish(staged, path)
        try:
            with patch.object(p, 'publish_file', broken), contextlib.redirect_stderr(io.StringIO()):
                update(source, dest)
        except (OSError, KeyboardInterrupt):
            pass
        else:
            raise AssertionError('fault did not fire')
        changed_path = dest / 'agents/inspector.toml'
        if failure in ('oserror', 'interrupt'):
            for relative, content in baseline.items():
                assert (dest / relative).read_bytes() == content, (failure, relative)
        else:
            if failure == 'symlink':
                assert changed_path.is_symlink()
            else:
                assert changed_path.read_text().startswith('concurrent')
            assert next((dest / 'launch-control-backups').glob('*/agents/inspector.toml')).read_bytes() == baseline['agents/inspector.toml']
    # A failure during a fresh install leaves no published agent or receipt.
    fresh = root / 'fresh-failure'
    real_publish = p.publish_file
    count = [0]
    def interrupt_fresh(staged, path):
        real_publish(staged, path)
        count[0] += 1
        if count[0] == 1:
            raise KeyboardInterrupt()
    try:
        with patch.object(p, 'publish_file', interrupt_fresh):
            update(source, fresh)
    except KeyboardInterrupt:
        pass
    else:
        raise AssertionError('fresh interruption did not fire')
    assert files(fresh) == {}
    # A writer changing a file during the backup rename keeps its new content.
    race = root / 'backup-race'
    update(source, race)
    put(source / 'agents/inspector.md', original + 'Changed again.\n')
    real_rename = Path.rename
    def race_rename(path, destination):
        if path == race / 'agents/inspector.toml':
            path.write_text('changed at backup')
        return real_rename(path, destination)
    with patch.object(Path, 'rename', race_rename):
        fails(lambda: update(source, race), 'changed during backup')
    assert (race / 'agents/inspector.toml').read_text() == 'changed at backup'
    # Symlinks are never followed even under explicit force.
    agent.unlink()
    agent.symlink_to(root / 'external')
    fails(lambda: update(source, target, force_agents=['inspector']), 'symlink')
    assert not (root / 'external').exists()
print('Codex agent checks passed: old global/project updates, ownership, preview, force, backups, idempotence, rollback, interrupts, concurrent writes, symlinks.')
