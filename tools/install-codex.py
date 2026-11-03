#!/usr/bin/env python3
"""Install Launch Control's explicit native core bundles; never translate host syntax."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('parity', ROOT / 'skills/onboard/scripts/codex-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


tree = parity.bundle_tree
digest = parity.bundle_digest


def bundles():
    names = json.loads((ROOT / 'codex/core-skills.json').read_text(encoding='utf-8'))
    if len(names) != len(set(names)) or any(not isinstance(n, str) or not parity.re.fullmatch(r'[a-z][a-z0-9-]*', n) for n in names):
        raise ValueError('invalid core skill inventory')
    result = {}
    mapping = parity.read_mapping()
    # Build the released LC-020 native onboard format without consulting a user home.
    with tempfile.TemporaryDirectory() as scratch:
        generated, _ = parity.generate(ROOT, Path(scratch), mapping, install=True)
    for name in names:
        if name == 'onboard':
            prefix = 'skills/onboard/'
            result[name] = {p[len(prefix):]: (text.encode(), 0) for p, text in generated.items() if p.startswith(prefix)}
            continue
        original = tree(ROOT / 'skills' / name)
        override = tree(ROOT / 'codex/skills' / name)
        if not override or 'SKILL.md' not in override:
            raise ValueError('missing native entrypoint: ' + name)
        files = {p: value for p, value in original.items() if p != 'SKILL.md'}
        # Hook proof belongs to Claude only; native bootstrap has no lifecycle hook.
        if name == 'docs-create':
            files.pop('scripts/invocation-proof.sh')
        if b'references/workflow.md' in override['SKILL.md'][0]:
            _, body = original['SKILL.md'][0].decode().split('\n---\n', 1)
            files['references/workflow.md'] = (body.encode(), 0)
        files.update(override)
        result[name] = files
    result['snippets-shared-by-skills'] = tree(ROOT / 'skills/snippets-shared-by-skills')
    result['snippets-shared-by-skills'].update(tree(ROOT / 'codex/skills/snippets-shared-by-skills'))
    for name, files in result.items():
        for path, (content, _) in files.items():
            if b'~/.Codex' in content:
                raise ValueError('invalid Codex spelling: ' + name + '/' + path)
        if name != 'snippets-shared-by-skills':
            metadata, _ = parity.frontmatter(files['SKILL.md'][0].decode())
            if metadata.get('name') != name or not metadata.get('description'):
                raise ValueError('invalid native skill: ' + name)
            if set(metadata) - {'name', 'description'}:
                raise ValueError('non-native skill frontmatter: ' + name)
        entry = files.get('SKILL.md', (b'', 0))[0].decode()
        for reference in parity.re.findall(r'`((?:\.\./snippets-shared-by-skills/|references/)[\w./-]+\.md)`', entry):
            found = (reference.split('/')[-1] in result['snippets-shared-by-skills']
                     if reference.startswith('../') else reference in files)
            if not found:
                raise ValueError('missing bundled reference: ' + name + '/' + reference)
    return result, mapping


def remove_published(dest, identity, unchanged, held):
    """Quarantine before deletion so a replacement at the public path survives."""
    if dest.is_symlink() or not dest.exists():
        return
    current = dest.stat()
    if (current.st_dev, current.st_ino) != identity or not unchanged(dest):
        return
    held.parent.mkdir(parents=True, exist_ok=True)
    dest.rename(held)
    try:
        current = held.lstat()
        if ((current.st_dev, current.st_ino) == identity
                and not held.is_symlink() and unchanged(held)):
            if held.is_dir():
                shutil.rmtree(held)
            else:
                held.unlink()
        elif held.is_dir() and not held.is_symlink():
            if not dest.exists() and not dest.is_symlink():
                held.rename(dest)
        else:
            # Exclusive link restores files/symlinks without overwriting a new destination.
            os.link(held, dest, follow_symlinks=False)
            held.unlink()
    finally:
        if held.exists() or held.is_symlink():
            print('ROLLBACK concurrent content retained at: ' + str(held), file=sys.stderr)


# LC-036 phase 3: skills renamed with no aliases. A released old-name copy is retired to the
# backup root; anything else under the old name (a user's own `research`) is left alone.
# `onboard-cursor` folds into `onboard`: Cursor prefers ~/.codex over ~/.claude for a shared
# name, so a Codex copy would hide the Claude skill that does the Cursor setup.
RENAMED = {
    'groundwork-onboard': 'onboard', 'groundwork-reset': 'offboard', 'decommission': 'offboard',
    'launch': 'launch-ticket', 'mission': 'launch-backlog', 'intake-to-research': 'research-questions',
    'research': 'research-codebase', 'research-to-design': 'design-doc', 'design-to-outline': 'design-outline',
    'outline-to-plan': 'plan-write', 'plan-to-implementation': 'plan-execute', 'review': 'review-doc',
    'bootstrap-docs': 'docs-create', 'update-docs': 'docs-update', 'foundations': 'catalog',
    'domain-facts': 'catalog', 'decision-record': 'log-decision', 'onboard-cursor': 'onboard',
}


def install(target, dry_run=False, force_skills=()):
    parity.safe_path(target, target)
    payload, mapping = bundles()
    unknown_force = set(force_skills) - payload.keys()
    if unknown_force:
        raise ValueError('unknown --force-skill: ' + ', '.join(sorted(unknown_force)))
    released = set()
    for line in (ROOT / 'install/codex-owned-digests.txt').read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        match = parity.re.fullmatch(r'skills ([a-z][a-z0-9-]*) ([a-f0-9]{64})', line)
        if not match or (match[1] not in payload and match[1] not in RENAMED):
            raise ValueError('invalid Codex ownership row: ' + line)
        released.add((match[1], match[2]))
    conflicts, snapshots, changes = [], {}, {}
    for name, files in payload.items():
        if (name, digest(files)) not in released:
            raise ValueError('candidate digest missing from Codex manifest: ' + name)
        dest = target / 'skills' / name
        try:
            parity.safe_path(target, dest)
            before = tree(dest)
        except ValueError as error:
            conflicts.append(str(error))
            continue
        snapshots[name] = before
        if before == files:
            print('PRESERVED ' + str(dest))
        elif before is not None and (name, digest(before)) not in released and name not in force_skills:
            conflicts.append(str(dest))
        else:
            changes[name] = files
    if conflicts:
        raise ValueError('install stopped before all writes; conflicting paths:\n  ' + '\n  '.join(conflicts))
    # Existing config and agents retain LC-020 preservation semantics.
    generated, preserved = parity.generate(ROOT, target, mapping, install=True)
    generated = {p: text for p, text in generated.items() if not p.startswith('skills/')}
    for path in preserved:
        if not path.startswith('skills/'):
            print('PRESERVED ' + str(target / path))
    retired = []
    for old in sorted(RENAMED):
        if old in payload or old in force_skills:
            continue
        dest = target / 'skills' / old
        parity.safe_path(target, dest)
        before = tree(dest)
        if before is None:
            continue
        if (old, digest(before)) in released:
            retired.append(old)
            print('RETIRE ' + str(dest) + ' (now ' + RENAMED[old] + ')')
        else:
            print('KEEP ' + str(dest) + ': not a released copy, the pack skill is now ' + RENAMED[old])
    for name in changes:
        print(('UPGRADE ' if snapshots[name] is not None else 'CREATE ') + str(target / 'skills' / name))
    for path in generated:
        print('CREATE ' + str(target / path))
    if dry_run:
        print('Codex dry-run: no writes.')
        return
    # Stage complete bundles before moving any old version out of discovery.
    with tempfile.TemporaryDirectory(prefix='launch-control-codex-') as scratch:
        stage = Path(scratch)
        for name, files in changes.items():
            for relative, (content, executable) in files.items():
                dest = stage / name / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(content)
                dest.chmod(0o644 | executable)
        for name, before in snapshots.items():
            dest = target / 'skills' / name
            parity.safe_path(target, dest)
            if tree(dest) != before:
                raise ValueError('destination changed during preflight: ' + str(dest))
        for relative in generated:
            dest = parity.safe_path(target, target / relative)
            if dest.exists():
                raise ValueError('destination appeared during preflight: ' + str(dest))
        backup = target / 'launch-control-backups' / datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
        parity.safe_path(target, backup)
        applied, created, published = [], {}, {}
        try:
            for name in changes:
                dest = target / 'skills' / name
                old = backup / 'skills' / name
                if snapshots[name] is not None:
                    old.parent.mkdir(parents=True, exist_ok=True)
                    dest.rename(old)
                    print('BACKUP ' + str(old))
                applied.append(name)
                dest.parent.mkdir(parents=True, exist_ok=True)
                # Same filesystem staging makes publishing each bundle a single rename.
                pending = Path(tempfile.mkdtemp(prefix='.launch-control-', dir=target))
                try:
                    shutil.copytree(stage / name, pending / name)
                    identity = (pending / name).stat()
                    (pending / name).rename(dest)
                    published[name] = (identity.st_dev, identity.st_ino)
                finally:
                    shutil.rmtree(pending)
            for relative, content in generated.items():
                dest = target / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                with dest.open('x', encoding='utf-8') as stream:
                    identity = os.fstat(stream.fileno())
                    created[dest] = (identity.st_dev, identity.st_ino, content)
                    stream.write(content)
        except BaseException:
            for dest in reversed(created):
                try:
                    device, inode, content = created[dest]
                    remove_published(dest, (device, inode), lambda path: path.read_text(encoding='utf-8') == content,
                                     backup / 'rollback' / dest.relative_to(target))
                    if dest.exists() or dest.is_symlink():
                        print('ROLLBACK preserved concurrent or incomplete file: ' + str(dest), file=sys.stderr)
                except (OSError, ValueError) as error:
                    print('ROLLBACK incomplete for ' + str(dest) + ': ' + str(error), file=sys.stderr)
            for name in reversed(applied):
                dest = target / 'skills' / name
                old = backup / 'skills' / name
                try:
                    if name in published:
                        remove_published(dest, published[name], lambda path: tree(path) == changes[name],
                                         backup / 'rollback/skills' / name)
                    if dest.exists() or dest.is_symlink():
                        print('ROLLBACK preserved concurrent content: ' + str(dest), file=sys.stderr)
                        if old.exists():
                            print('ROLLBACK original retained at: ' + str(old), file=sys.stderr)
                    elif old.exists():
                        old.rename(dest)
                except (OSError, ValueError) as error:
                    # Keep recovering other bundles if this destination cannot be restored.
                    print('ROLLBACK incomplete for ' + str(dest) + ': ' + str(error)
                          + '; backup location: ' + str(old), file=sys.stderr)
            raise
        for old in retired:
            dest = target / 'skills' / old
            if tree(dest) is None or digest(tree(dest)) not in {d for n, d in released if n == old}:
                continue
            (backup / 'skills').mkdir(parents=True, exist_ok=True)
            dest.rename(backup / 'skills' / old)
            print('BACKUP ' + str(backup / 'skills' / old))
        # A --force-skill over a copy no released row reproduces is user content.
        parity.finish_backup(backup, 'codex-skills', not any(
            snapshots[name] is not None and (name, digest(snapshots[name])) not in released for name in changes))
    print('Codex core install complete; existing config and agents preserved.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--target', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--update-agents', action='store_true', help='update only global agents, preserving skills and config')
    parser.add_argument('--force-agent', action='append', default=[], metavar='NAME')
    parser.add_argument('--force-skill', action='append', default=[], metavar='NAME')
    args = parser.parse_args()
    try:
        if args.force_agent and not args.update_agents:
            parser.error('--force-agent requires --update-agents')
        if args.update_agents and args.force_skill:
            parser.error('--update-agents cannot be combined with --force-skill')
        if args.update_agents:
            parity.update_agents(ROOT, args.target.absolute(), parity.read_mapping(),
                                 install=True, dry_run=args.dry_run, force_agents=args.force_agent)
        else:
            install(args.target.absolute(), args.dry_run, args.force_skill)
    except (ValueError, OSError, KeyError) as error:
        sys.exit('Codex install failed: ' + str(error))
