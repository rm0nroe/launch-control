#!/usr/bin/env python3
"""Generate absent Codex artifacts from Launch Control's rendered Claude artifacts.

Python 3.11+; no packages. Refresh released static skills; preserve customized artifacts.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib

SKILL = Path(__file__).resolve().parent.parent
PROJECT_SKILLS = {'testing-patterns', 'pr-workflow', 'project-code-review',
                  'feature-development', 'systematic-debugging', 'launch',
                  'checkpoint-save', 'checkpoint-load', 'checkpoint-list'}
PROJECT_AGENTS = {'inspector', 'dispatcher'}
PROJECT_COMMANDS = {'pr', 'validate', 'fix', 'status', 'commit', 'ticket', 'explore'}
LAUNCH_FILES = ('SKILL.md', 'references/delivery.md', 'references/implementation.md',
                'references/ticket-intake.md', 'references/verification.md')
AUTONOMY_EVENTS = (
    ('SessionStart', 'startup|resume|compact|clear', 10000),
    ('PreCompact', 'manual|auto', None),
    ('Stop', None, None),
)


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def safe_regular(path, label):
    if path.is_symlink() or not path.is_file():
        raise ValueError(label + ' must be a regular file: ' + str(path))
    return path.read_bytes()


def hook_entries(value):
    """Yield native hook commands, rejecting a malformed adapter input."""
    if not isinstance(value, dict):
        raise ValueError('hooks.json must contain an object')
    hooks = value.get('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('hooks.json hooks must be an object')
    for event, groups in hooks.items():
        if not isinstance(event, str) or not isinstance(groups, list):
            raise ValueError('hooks.json event handlers must be lists')
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                raise ValueError('hooks.json handler group is malformed')
            matcher = group.get('matcher')
            if matcher is not None and not isinstance(matcher, str):
                raise ValueError('hooks.json matcher is malformed')
            for handler in group['hooks']:
                if not isinstance(handler, dict):
                    raise ValueError('hooks.json handler is malformed')
                yield event, matcher, handler


def native_hook_document(existing, command):
    """Merge the three Launch handlers without taking over user hook metadata."""
    document = {} if existing is None else json.loads(existing)
    if not isinstance(document, dict):
        raise ValueError('hooks.json must contain an object')
    hooks = document.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('hooks.json hooks must be an object')
    expected = {(event, matcher, command) for event, matcher, _ in AUTONOMY_EVENTS}
    seen = set()
    for event, matcher, handler in hook_entries(document):
        if handler.get('command') != command:
            continue
        signature = (event, matcher, command)
        if signature not in expected or handler.get('type') != 'command' or handler.get('timeout') != 10:
            raise ValueError('hooks.json has an incompatible reference to the Launch Control wrapper')
        if event == 'SessionStart' and handler.get('additionalContextLimit') != 10000:
            raise ValueError('hooks.json has an incompatible reference to the Launch Control wrapper')
        if event != 'SessionStart' and 'additionalContextLimit' in handler:
            raise ValueError('hooks.json has an incompatible reference to the Launch Control wrapper')
        seen.add(signature)
    for event, matcher, context_limit in AUTONOMY_EVENTS:
        signature = (event, matcher, command)
        if signature in seen:
            continue
        handler = {'type': 'command', 'command': command, 'timeout': 10}
        if context_limit is not None:
            handler['additionalContextLimit'] = context_limit
        group = {'hooks': [handler]}
        if matcher is not None:
            group['matcher'] = matcher
        hooks.setdefault(event, []).append(group)
    return (json.dumps(document, sort_keys=True, indent=2) + '\n').encode()


def autonomy_receipt(files, hooks_before, hooks_after):
    return (json.dumps({'schema': 1, 'files': {path: sha256(content) for path, content in sorted(files.items())},
                        'hooks_before': hooks_before, 'hooks_after': sha256(hooks_after)},
                       sort_keys=True, indent=2) + '\n').encode()


def check_autonomy_receipt(project, receipt_path):
    """A receipt proves only its original creation set; it can never adopt files."""
    record = json.loads(safe_regular(receipt_path, 'ownership receipt'))
    if not isinstance(record, dict) or record.get('schema') != 1 or not isinstance(record.get('files'), dict):
        raise ValueError('malformed native autonomy ownership receipt')
    allowed = {'.codex/launch/verify.json', '.codex/hooks/launch.sh', '.codex/hooks.json', 'scripts/verify.sh'}
    for relative, expected in record['files'].items():
        if relative not in allowed or not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
            raise ValueError('malformed native autonomy ownership receipt')
        path = safe_path(project, project / relative)
        if sha256(safe_regular(path, 'managed autonomy artifact')) != expected:
            raise ValueError('managed native autonomy artifact changed: ' + relative)
    hooks = safe_path(project, project / '.codex/hooks.json')
    if sha256(safe_regular(hooks, 'managed hooks.json')) != record.get('hooks_after'):
        raise ValueError('managed native hooks.json changed')


def native_launch_bundle(source):
    root = source / 'skills/launch'
    expected = {}
    for relative in LAUNCH_FILES:
        path = safe_path(source, root / relative)
        expected[relative] = (skill_text(read_source(source, path)) if relative == 'SKILL.md'
                              else native_text(read_source(source, path))).encode('utf-8')
    route = '${CODEX_HOME:-$HOME/.codex}/skills/onboard/references/launch-autonomy.md'
    if route not in expected['SKILL.md'].decode('utf-8'):
        raise ValueError('rendered Launch skill lacks native supervised recovery routing')
    return expected


def validate_native_launch(source, target):
    intended = native_launch_bundle(source)
    existing = target / 'skills/launch'
    safe_path(target, existing)
    if existing.exists():
        current = bundle_tree(existing)
        if current is None or set(current) != set(intended) or any(current[path][0] != content for path, content in intended.items()):
            raise ValueError('existing native Launch skill differs from the rendered five-file bundle')
    return intended


def autonomy_overlay(project, target, config_path, commands_path, base_changes,
                     controller=None, controller_digest=None, shared_root=None,
                     delivery_binding=None, delivery_binding_digest=None):
    """Plan a complete native overlay. All conflicts are found before publication."""
    shadow = project / '.agents/skills/launch'
    safe_path(project, project / '.agents')
    if shadow.exists() or shadow.is_symlink():
        raise ValueError('native Launch discovery conflict: .agents/skills/launch shadows .codex/skills/launch; resolve it explicitly')
    safe_path(project, project / '.codex')
    config_data = safe_regular(config_path, '--autonomy-config')
    commands_data = safe_regular(commands_path, '--autonomy-commands')
    runtime = runpy.run_path(str(SKILL / 'scripts/launch-runtime.py'))
    cfg = runtime['config_at'](config_path, project)
    declared = [line.strip() for line in commands_data.decode('utf-8').splitlines() if line.strip()]
    if len(declared) != len(set(declared)):
        raise ValueError('--autonomy-commands contains duplicate commands')
    rendered = [check['command'] if check['cwd'] == '.' else 'cd ' + check['cwd'] + ' && ' + check['command']
                for check in cfg['checks']]
    if set(declared) != set(rendered):
        raise ValueError('autonomy checks differ from the declared onboarding contract')
    config_toml = target / 'config.toml'
    config_before = file_snapshot(project, '.codex/config.toml')
    toml_data = base_changes.get('.codex/config.toml') or (safe_regular(config_toml, 'Codex config') if config_toml.exists() else None)
    parsed = tomllib.loads(toml_data.decode('utf-8')) if toml_data is not None else {}
    if parsed.get('hooks') is not None:
        raise ValueError('inline [hooks] conflicts with .codex/hooks.json')
    if parsed.get('features', {}).get('hooks') is False:
        raise ValueError('features.hooks=false blocks native autonomy')

    if controller is not None and safe_regular(controller, 'controller') != (SKILL / 'scripts/launch-runtime.py').read_bytes():
        raise ValueError('selected runtime differs from converter runtime')
    try:
        verifier_text, wrapper_text = runtime['wrappers'](controller, controller_digest, shared_root,
                                                        delivery_binding, delivery_binding_digest)
    except runtime['Invalid'] as error:
        raise ValueError(str(error)) from error
    wrapper, verifier = wrapper_text.encode(), verifier_text.encode()
    command_root = shared_root or project
    command = 'bash ' + shlex.quote(str(command_root / '.codex/hooks/launch.sh'))
    local_command = 'bash ' + shlex.quote(str(project / '.codex/hooks/launch.sh'))
    if shared_root is not None and shared_root != project:
        if runtime['identity'](shared_root)['repo'] != runtime['identity'](project)['repo']:
            raise ValueError('shared delivery launcher belongs to another repository')
        check_autonomy_receipt(shared_root, shared_root / '.codex/launch-control-launch-ownership.json')
        if safe_regular(shared_root / '.codex/hooks/launch.sh', 'primary delivery launcher') != wrapper:
            raise ValueError('primary delivery launcher must be generated first')
    paths = {
        '.codex/launch/verify.json': config_data,
        '.codex/hooks/launch.sh': wrapper,
        'scripts/verify.sh': verifier,
    }
    receipt_path = '.codex/launch-control-launch-ownership.json'
    receipt = project / receipt_path
    initial = {relative: file_snapshot(project, relative) for relative in base_changes}
    initial.update({relative: file_snapshot(project, relative) for relative in paths})
    initial['.codex/hooks.json'] = file_snapshot(project, '.codex/hooks.json')
    initial[receipt_path] = file_snapshot(project, receipt_path)
    for relative, before in initial.items():
        if relative in base_changes and before is not None:
            raise ValueError('destination changed during native autonomy preflight: ' + relative)
    raw_hooks = initial['.codex/hooks.json'][0] if initial['.codex/hooks.json'] else None
    selected_hooks = raw_hooks
    if controller is not None and receipt.exists() and local_command != command:
        check_autonomy_receipt(project, receipt)
        document = json.loads(raw_hooks)
        managed = [(event, matcher, handler) for event, matcher, handler in hook_entries(document)
                   if handler.get('command') == local_command]
        if managed:
            expected = {(event, matcher) for event, matcher, _ in AUTONOMY_EVENTS}
            if len(managed) != 3 or {(e, m) for e, m, _ in managed} != expected:
                raise ValueError('ambiguous managed native handlers')
            for _, _, handler in managed:
                handler['command'] = command
        selected_hooks = json.dumps(document).encode()
    after_hooks = native_hook_document(selected_hooks.decode('utf-8') if selected_hooks is not None else None, command)
    if controller is not None:
        managed = [(e, m) for e, m, h in hook_entries(json.loads(after_hooks)) if h.get('command') == command]
        if len(managed) != 3 or set(managed) != {(e, m) for e, m, _ in AUTONOMY_EVENTS}:
            raise ValueError('ambiguous selected native handlers')
    if receipt.exists() or receipt.is_symlink():
        check_autonomy_receipt(project, receipt)
        if controller is not None:
            record = json.loads(initial[receipt_path][0])
            desired = {**paths, '.codex/hooks.json': after_hooks}
            for relative, content in paths.items():
                if initial[relative] is None or initial[relative][0] != content:
                    if relative not in record['files']:
                        raise ValueError('receipt cannot adopt unmanaged autonomy file: ' + relative)
            files = {rel: desired.get(rel, initial[rel][0]) for rel in record['files']}
            desired[receipt_path] = autonomy_receipt(files, record.get('hooks_before'), after_hooks)
            changes = {**base_changes, **{rel: data for rel, data in desired.items()
                                         if initial[rel] is None or initial[rel][0] != data}}
            guards = {rel: before for rel, before in initial.items() if rel not in changes}
            if '.codex/config.toml' not in changes:
                guards['.codex/config.toml'] = config_before
            return (changes, [], {rel: initial[rel] for rel in changes}, guards, config_data, commands_data)
        if any(initial[relative] is None or initial[relative][0] != content for relative, content in paths.items()):
            raise ValueError('existing native autonomy receipt conflicts with the desired overlay')
        if raw_hooks != after_hooks:
            raise ValueError('existing native autonomy receipt conflicts with the desired hooks.json')
        changes = dict(base_changes)
        return (changes, ['.codex/launch/', '.codex/hooks/launch.sh', 'scripts/verify.sh', receipt_path],
                {relative: initial[relative] for relative in changes},
                {relative: before for relative, before in initial.items() if relative not in changes},
                config_data, commands_data)

    conflicts, created = [], {}
    for relative, content in paths.items():
        before = initial[relative]
        if before is None:
            created[relative] = content
        elif before[0] != content:
            conflicts.append(relative)
    had_native = raw_hooks is not None and any(
        handler.get('command') == command for _, _, handler in hook_entries(json.loads(raw_hooks)))
    if had_native:
        conflicts.append('.codex/hooks.json (ambiguous existing native handler)')
    if conflicts:
        raise ValueError('native autonomy stopped before all writes:\n  ' + '\n  '.join(conflicts))
    changes = dict(base_changes)
    changes.update(created)
    if raw_hooks != after_hooks:
        changes['.codex/hooks.json'] = after_hooks
    created_for_receipt = dict(created)
    if raw_hooks is None:
        created_for_receipt['.codex/hooks.json'] = after_hooks
    changes[receipt_path] = autonomy_receipt(created_for_receipt,
                                               None if raw_hooks is None else raw_hooks.decode('utf-8'), after_hooks)
    snapshots = {relative: initial[relative] for relative in changes}
    guards = {relative: before for relative, before in initial.items() if relative not in changes}
    if '.codex/config.toml' not in changes:
        guards['.codex/config.toml'] = config_before
    return changes, [], snapshots, guards, config_data, commands_data


def read_mapping():
    mapping = json.loads((SKILL / 'references/codex-model-tiers.json').read_text(encoding='utf-8'))
    for tier in mapping['tiers'].values():
        if not isinstance(tier['model'], str) or not tier['model'].strip():
            raise ValueError('model tiers require nonempty model strings')
        if tier['reasoning_effort'] not in ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'):
            raise ValueError('invalid mapped reasoning effort')
    return mapping


def scalar(value):
    value = value.strip()
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def frontmatter(text):
    """Read the scalar/folded metadata used by our templates; reject ambiguity."""
    # ponytail: scalar/folded fields only; use a YAML parser if nested metadata is needed.
    if not text.startswith('---\n') or '\n---\n' not in text[4:]:
        raise ValueError('expected Markdown frontmatter')
    header, body = text[4:].split('\n---\n', 1)
    fields = {}
    current = None
    for line in header.splitlines():
        if not line.strip():
            continue
        match = re.match(r'^([\w-]+):\s*(.*)$', line)
        if match:
            current, value = match.groups()
            fields[current] = '' if value in ('>', '|', '>-', '|-') else scalar(value)
        elif line.startswith(' ') and current in ('description',):
            fields[current] += ' ' + line.strip()
        else:
            raise ValueError('unsupported nested frontmatter; use a native Codex definition')
    return fields, body


def native_text(text):
    return native_paths(text.replace('Claude Code', 'Codex'))


def native_paths(text):
    """Paths only: AGENTS.md mirrors a project's own description, where product names are facts."""
    text = text.replace('${CLAUDE_CONFIG_DIR:-$HOME/.claude}', '${CODEX_HOME:-$HOME/.codex}')
    text = text.replace('~/.claude/skills/', '~/.codex/skills/')
    text = text.replace('.claude/skills/', '.codex/skills/')
    text = re.sub(r'\.claude/agents/([\w*-]+)\.md', r'.codex/agents/\1.toml', text)
    text = re.sub(r'\.claude/commands/([\w-]+)\.md', r'.codex/skills/\1/SKILL.md', text)
    text = text.replace('.claude/agents/', '.codex/agents/')
    if re.search(r'\{\{[^\n]*\}\}|\bDETECTED_[A-Z_]+', text):
        raise ValueError('unresolved template token')
    return text


GENERATED_HEADING = '## Generated Quick Reference'
LEGACY_BLOCK = re.compile(r'<!-- BEGIN GENERATED SECTION -- onboard -->.*?<!-- END GENERATED SECTION -- onboard -->\n?', re.S)


def split_generated(text):
    """(before, block, after): the heading through the next top-level heading or EOF."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.rstrip('\n') == GENERATED_HEADING), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('# ')), len(lines))
    return ''.join(lines[:start]), ''.join(lines[start:end]), ''.join(lines[end:])


def agents_md(project, dry_run, staged=None):
    """LC-061: Codex reads AGENTS.md, not CLAUDE.md. Mirror CLAUDE.md's verified generated block,
    converted for Codex, with the same create/replace/append rules; user prose is never touched.
    A Codex-only onboard has no project block, so it falls back to the one staged beside --source.
    A file it must not rewrite is reported KEPT, so the renderer can still flag its block stale."""
    parts = None
    for claude in (project / 'CLAUDE.md', staged):
        if parts is None and claude and not claude.is_symlink() and claude.is_file():
            parts = split_generated(claude.read_text(encoding='utf-8'))
    if parts is None:
        return
    block = native_paths(parts[1]).rstrip('\n') + '\n'
    dest = project / 'AGENTS.md'
    try:
        status = subprocess.run(['git', '-C', str(project), 'status', '--porcelain', '--untracked-files=no', '--',
                                 'AGENTS.md'], capture_output=True, text=True)
        dirty = status.returncode == 0 and bool(status.stdout.strip())
    except OSError:  # cannot prove the file clean, so keep it
        dirty = True
    if dest.is_symlink() or (dest.exists() and not dest.is_file()):
        print('KEPT ' + str(dest) + ': not a regular file')
        return
    if dirty:
        print('KEPT ' + str(dest) + ': uncommitted changes; commit them so onboarding can refresh the block')
        return
    old = None
    if dest.exists():
        with open(dest, encoding='utf-8', newline='') as stream:
            old = stream.read()
    if old is not None and '\r' in old:
        print('KEPT ' + str(dest) + ': CRLF line endings; onboarding never rewrites them')
        return
    if old is None:
        new = block
    elif LEGACY_BLOCK.search(old):
        new = LEGACY_BLOCK.sub(lambda _: block, old, count=1)
    elif split_generated(old) is None:
        new = old.rstrip('\n') + '\n\n' + block
    else:
        before, _, after = split_generated(old)
        new = before + block + ('\n' + after if after else '')
    if new == old:
        print('PRESERVED ' + str(dest))
        return
    if not dry_run:
        dest.write_text(new, encoding='utf-8')
    print(('PLANNED ' if dry_run else 'CREATED ' if old is None else 'MERGED ') + str(dest))


def skill_text(text, fallback_name=None):
    fields, body = frontmatter(text)
    name = fields.get('name', fallback_name)
    description = fields.get('description')
    if not name or not description:
        raise ValueError('skill needs name and description')
    if 'hooks' in fields:
        raise ValueError('Claude lifecycle hooks require a native Codex skill')
    return ('---\nname: ' + json.dumps(name) + '\ndescription: '
            + json.dumps(description.strip(), ensure_ascii=False) + '\n---\n'
            + native_text(body)
            + ('\n\nSource tool scope (guidance, not a Codex allowlist): '
               + native_text(fields['allowed-tools'])
               + '. Use available equivalent tools without weakening session permissions.\n'
               if fields.get('allowed-tools') else ''))


def command_text(text, name):
    """Claude Code commands may omit frontmatter; it then uses the first line as the description."""
    if text.startswith('---\n'):
        return skill_text(text, name)
    first = next((line.strip() for line in text.splitlines() if line.strip()), '')
    return skill_text('---\ndescription: ' + json.dumps(first, ensure_ascii=False) + '\n---\n' + text, name)


def agent_text(text, mapping):
    fields, body = frontmatter(text)
    for key in ('name', 'description', 'model'):
        if not fields.get(key):
            raise ValueError('agent missing ' + key)
    tier = mapping['tiers'].get(fields['model'])
    if not tier:
        raise ValueError('unmapped model tier: ' + fields['model'])
    result = {key: fields[key].strip() for key in ('name', 'description')}
    result.update(model=tier['model'], model_reasoning_effort=tier['reasoning_effort'])
    # Our pack's agents are read-only. Project agents explicitly declare write tools.
    declared = fields.get('tools', '')
    if not declared:
        raise ValueError('agent must declare its source tool boundary')
    if fields['name'] != 'dispatcher' and not re.search(r'\b(Edit|Write|NotebookEdit)\b', declared):
        result['sandbox_mode'] = 'read-only'
    result['developer_instructions'] = native_text(body).strip()
    result['developer_instructions'] += ('\n\nSource tool scope (guidance, not a Codex allowlist): '
                                       + declared + '. Use only available equivalent tools; '
                                       'never weaken the parent permissions.\n')
    output = ''.join(key + ' = ' + json.dumps(value, ensure_ascii=False) + '\n'
                     for key, value in result.items())
    tomllib.loads(output)
    return output


def safe_path(root, path):
    path.relative_to(root)
    for item in (path, *path.parents):
        if item == root.parent:
            break
        if item.is_symlink():
            raise ValueError('symlink path is preserved; cannot generate through ' + str(item))
    return path


def bundle_tree(path):
    """Hash all resources and executable bits; symlinks and special files are conflicts."""
    safe_path(path, path)
    if not path.exists():
        return None
    if not path.is_dir():
        raise ValueError('expected skill directory: ' + str(path))
    result = {}
    for item in sorted(path.rglob('*')):
        safe_path(path, item)
        if item.is_dir():
            continue
        if not item.is_file():
            raise ValueError('not a regular file: ' + str(item))
        result[item.relative_to(path).as_posix()] = (item.read_bytes(), item.stat().st_mode & 0o111)
    return result


def bundle_digest(files):
    h = hashlib.sha256()
    for name, (content, executable) in sorted(files.items()):
        h.update(json.dumps([name, executable, hashlib.sha256(content).hexdigest()],
                            separators=(',', ':')).encode() + b'\n')
    return h.hexdigest()


def read_source(root, path):
    safe_path(root, path)
    if not path.is_file():
        raise ValueError('source must be a regular file: ' + str(path))
    return path.read_text(encoding='utf-8')


def agent_receipt(name, content):
    return json.dumps({'version': 1, 'name': name,
                       'sha256': hashlib.sha256(content).hexdigest()}, sort_keys=True) + '\n'


def file_snapshot(target, relative):
    path = safe_path(target, target / relative)
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError('expected regular file: ' + str(path))
    return path.read_bytes(), path.stat().st_mode & 0o777


def publish_file(staged, dest):
    # Exclusive publication: a concurrent destination must never be overwritten.
    os.link(staged, dest)


BACKUP_MARKER = '.launch-control-backup-complete'


def finish_backup(backup, kind, prunable):
    """After a successful run, mark a released-only backup complete and remove older complete
    backups of the same kind, keeping one version back. Unmarked backups (user content, failed
    or concurrent runs, hand-made names) are never removed."""
    root = backup.parent
    if root.is_symlink() or backup.is_symlink() or not backup.is_dir():
        return
    if prunable:
        (backup / BACKUP_MARKER).write_text(kind + '\n', encoding='utf-8')
    else:
        print('kept backup with user content: ' + str(backup))
    for sibling in sorted(root.iterdir()):
        marker = sibling / BACKUP_MARKER
        if (sibling == backup or sibling.is_symlink() or not sibling.is_dir()
                or not re.fullmatch(r'\d{8}-\d{6}-\d{6}', sibling.name)
                or marker.is_symlink() or not marker.is_file()
                or marker.read_text(encoding='utf-8') != kind + '\n'):
            continue
        shutil.rmtree(sibling)
        print('prune old backup: ' + sibling.name)


def replace_files(target, changes, snapshots, kind=None, prunable=False):
    """Back up originals and recover on exceptions, including KeyboardInterrupt.
    With a kind, a successful run finishes its backup (see finish_backup)."""
    safe_path(target, target)
    target.mkdir(parents=True, exist_ok=True)
    backup = safe_path(target, target / 'launch-control-backups' /
                       datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f'))
    applied, published = [], {}
    with tempfile.TemporaryDirectory(prefix='.launch-control-agents-', dir=target) as scratch:
        stage = Path(scratch)
        for relative, content in changes.items():
            pending = stage / relative
            pending.parent.mkdir(parents=True, exist_ok=True)
            pending.write_bytes(content)
            pending.chmod(snapshots[relative][1] if snapshots[relative] else 0o644)
        for relative, before in snapshots.items():
            if file_snapshot(target, relative) != before:
                raise ValueError('destination changed during preflight: ' + relative)
        try:
            for relative, content in changes.items():
                dest = safe_path(target, target / relative)
                old = backup / relative
                if file_snapshot(target, relative) != snapshots[relative]:
                    raise ValueError('destination changed during update: ' + relative)
                applied.append(relative)
                if snapshots[relative] is not None:
                    old.parent.mkdir(parents=True, exist_ok=True)
                    dest.rename(old)
                    # Verify what was actually moved, not just the earlier read.
                    if file_snapshot(backup, relative) != snapshots[relative]:
                        raise ValueError('destination changed during backup: ' + relative)
                    print('BACKUP ' + str(old))
                dest.parent.mkdir(parents=True, exist_ok=True)
                pending = stage / relative
                identity = pending.stat()
                published[relative] = (identity.st_dev, identity.st_ino)
                publish_file(pending, dest)
        except BaseException:
            for relative in reversed(applied):
                dest, old = target / relative, backup / relative
                try:
                    safe_path(target, dest)
                    if relative in published and dest.exists():
                        identity = dest.stat()
                        if ((identity.st_dev, identity.st_ino) == published[relative]
                                and file_snapshot(target, relative) ==
                                (changes[relative], snapshots[relative][1] if snapshots[relative] else 0o644)):
                            held = backup / 'rollback' / relative
                            held.parent.mkdir(parents=True, exist_ok=True)
                            dest.rename(held)
                            identity = held.lstat()
                            if (not held.is_symlink() and
                                    (identity.st_dev, identity.st_ino) == published[relative] and
                                    file_snapshot(backup, str(held.relative_to(backup))) ==
                                    (changes[relative], snapshots[relative][1] if snapshots[relative] else 0o644)):
                                held.unlink()
                            else:
                                try:
                                    os.link(held, dest, follow_symlinks=False)
                                    held.unlink()
                                finally:
                                    if held.exists() or held.is_symlink():
                                        print('ROLLBACK concurrent content retained at: ' + str(held), file=sys.stderr)
                    if old.exists() or old.is_symlink():
                        os.link(old, dest, follow_symlinks=False)
                        old.unlink()
                except (OSError, ValueError) as error:
                    print('ROLLBACK preserved concurrent content; original at ' + str(old)
                          + ': ' + str(error), file=sys.stderr)
            raise
    if kind:
        finish_backup(backup, kind, prunable)


def update_agents(source, target, mapping, install=False, dry_run=False, force_agents=()):
    """Refresh only owned agents; project ownership is tied to rendered output."""
    candidates = {}
    for path in sorted((source / 'agents').glob('*.md')):
        if not install and path.stem not in PROJECT_AGENTS:
            continue
        if not re.fullmatch(r'[a-z][a-z0-9-]*', path.stem):
            raise ValueError('invalid agent name: ' + path.stem)
        content = agent_text(read_source(source, path), mapping)
        if tomllib.loads(content)['name'] != path.stem:
            raise ValueError('agent name differs from filename: ' + str(path))
        candidates[path.stem] = content.encode('utf-8')
    if not candidates:
        raise ValueError('no rendered agents found: ' + str(source / 'agents'))
    if set(force_agents) - candidates.keys():
        raise ValueError('unknown --force-agent: ' + ', '.join(sorted(set(force_agents) - candidates.keys())))
    released = set()
    if install:
        for line in read_source(source, source / 'install/codex-agent-digests.txt').splitlines():
            if not line or line.startswith('#'):
                continue
            match = re.fullmatch(r'([a-z][a-z0-9-]*) ([a-f0-9]{64})', line)
            if not match or match[1] not in candidates:
                raise ValueError('invalid agent ownership row: ' + line)
            released.add((match[1], match[2]))
        for name, content in candidates.items():
            if (name, hashlib.sha256(content).hexdigest()) not in released:
                raise ValueError('candidate agent digest missing from manifest: ' + name)
    changes, snapshots, conflicts = {}, {}, []
    user_content = False
    for name, content in candidates.items():
        relative = 'agents/' + name + '.toml'
        receipt = 'launch-control-agent-ownership/' + name + '.json'
        before = file_snapshot(target, relative)
        record = file_snapshot(target, receipt)
        snapshots.update({relative: before, receipt: record})
        owned = before is not None and (
            (record is not None and record[0] == agent_receipt(name, before[0]).encode())
            or (name, hashlib.sha256(before[0]).hexdigest()) in released)
        if before is not None and before[0] == content and name not in force_agents:
            print('PRESERVED ' + str(target / relative))
            # Equality alone is not proof of ownership of an unknown live file.
            continue
        if before is not None and not owned and name not in force_agents:
            conflicts.append(str(target / relative))
            continue
        if before is None and record is not None and name not in force_agents:
            conflicts.append(str(target / receipt))
            continue
        # Only a reviewed --force-agent reaches here with an unowned live file.
        user_content = user_content or (before is not None and not owned)
        changes[relative] = content
        changes[receipt] = agent_receipt(name, content).encode()
        model = tomllib.loads(content.decode())
        print(('UPGRADE ' if before else 'CREATE ') + str(target / relative)
              + ' model=' + model['model'] + ' effort=' + model['model_reasoning_effort'])
    if conflicts:
        raise ValueError('agent update stopped before all writes; use reviewed --force-agent NAME for conflicts:\n  '
                         + '\n  '.join(conflicts))
    if not dry_run and changes:
        replace_files(target, changes, snapshots, 'codex-agents', not user_content)
    print('Codex agents: ' + str(len(changes) // 2) + (' planned; no writes.' if dry_run else ' updated.'))


def generate(source, target, mapping, install=False, launch=False, refresh_static=False):
    planned = {}
    preserved = []

    def add(relative, make):
        dest = safe_path(target, target / relative)
        if dest.exists():
            if not dest.is_file():
                raise ValueError('destination is not a file: ' + str(dest))
            preserved.append(relative)
        else:
            planned[relative] = make()

    defaults = mapping['tiers'][mapping['default_tier']]
    config = ('[agents]\ndefault_subagent_model = ' + json.dumps(defaults['model'])
              + '\ndefault_subagent_reasoning_effort = '
              + json.dumps(defaults['reasoning_effort']) + '\n')
    if install:
        add('config.toml', lambda: config)
    if not launch:
        agents = source / 'agents'
        for path in sorted(agents.glob('*.md')):
            if not install and path.stem not in PROJECT_AGENTS:
                continue
            add('agents/' + path.stem + '.toml',
                lambda p=path: agent_text(read_source(source, p), mapping))

    if install and (target / 'skills/onboard').exists():
        safe_path(target, target / 'skills/onboard')
        if not (target / 'skills/onboard').is_dir():
            raise ValueError('existing onboard skill is not a directory')
        preserved.append('skills/onboard/')
    elif install:
        add('skills/onboard/SKILL.md', lambda: (SKILL / 'references/codex-onboard.md').read_text(encoding='utf-8'))
        for path in sorted((SKILL / 'references').glob('*.md')):
            if '-fixture-' not in path.name:
                add('skills/onboard/references/' + path.name, lambda p=path: p.read_text(encoding='utf-8'))
        for path in (*sorted((SKILL / 'scripts').glob('*.py')), SKILL / 'references/codex-model-tiers.json'):
            content = read_source(SKILL, path)
            add('skills/onboard/' + str(path.relative_to(SKILL)), lambda text=content: text)
    if not install:
        if not launch and not refresh_static:
            templates = dict(re.findall(r'^## (checkpoint-save|checkpoint-load|checkpoint-list)\n\n```markdown\n(.*?)^```$',
                                        (SKILL / 'references/checkpoint-templates.md').read_text(encoding='utf-8'),
                                        re.MULTILINE | re.DOTALL))
            for name in ('checkpoint-save', 'checkpoint-load', 'checkpoint-list'):
                if not (source / 'skills' / name / 'SKILL.md').exists():
                    dest_root = safe_path(target, target / 'skills' / name)
                    if dest_root.exists():
                        if not dest_root.is_dir():
                            raise ValueError('existing skill is not a directory: ' + str(dest_root))
                        preserved.append('skills/' + name + '/')
                        continue
                    add('skills/' + name + '/SKILL.md', lambda n=name: skill_text(templates[n]))
        skills = source / 'skills'
        for path in sorted(skills.glob('*/SKILL.md')):
            name = path.parent.name
            if (name not in PROJECT_SKILLS or (launch and name != 'launch')
                    or (refresh_static and name in ('checkpoint-save', 'checkpoint-load', 'checkpoint-list'))):
                continue
            dest_root = target / 'skills' / name
            safe_path(target, dest_root)
            # Preserve the whole skill, including absent references; never mix versions.
            if dest_root.exists():
                if not dest_root.is_dir():
                    raise ValueError('existing skill is not a directory: ' + str(dest_root))
                preserved.append('skills/' + name + '/')
                continue
            for item in sorted(path.parent.rglob('*')):
                safe_path(source, item)
                if item.is_file():
                    relative = 'skills/' + name + '/' + str(item.relative_to(path.parent))
                    add(relative, lambda p=item: skill_text(read_source(source, p))
                        if p.name == 'SKILL.md' else native_text(read_source(source, p)))
        if not launch:
            for path in sorted((source / 'commands').glob('*.md')):
                if path.stem not in PROJECT_COMMANDS:
                    continue
                if (target / 'skills' / path.stem).exists():
                    preserved.append('skills/' + path.stem + '/')
                    continue
                add('skills/' + path.stem + '/SKILL.md',
                    lambda p=path: command_text(read_source(source, p), p.stem))
    # Project settings are user-owned; only the global installer needs defaults.
    config_path = safe_path(target, target / 'config.toml')
    parsed = tomllib.loads(read_source(target, config_path)) if config_path.exists() else {}
    if install:
        agents = (parsed if config_path.exists() else tomllib.loads(config)).get('agents', {})
        for key in ('default_subagent_model', 'default_subagent_reasoning_effort'):
            if not isinstance(agents.get(key), str) or not agents[key].strip():
                raise ValueError('preserved config.toml lacks agents.' + key
                                 + '; configure it explicitly before installation')
    for relative, content in list(planned.items()):
        if relative.startswith('agents/'):
            name = Path(relative).stem
            receipt = 'launch-control-agent-ownership/' + name + '.json'
            if safe_path(target, target / receipt).exists():
                raise ValueError('orphaned agent ownership record: ' + receipt)
            planned[receipt] = agent_receipt(name, content.encode('utf-8'))
    return planned, preserved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--source', type=Path, help='rendered Claude artifact root, including a disposable staging tree')
    parser.add_argument('--codex', action='store_true', help='opt in without an existing .codex directory')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--launch-control', dest='launch', action='store_true')
    parser.add_argument('--enable-autonomy', action='store_true')
    parser.add_argument('--autonomy-config', type=Path)
    parser.add_argument('--autonomy-commands', type=Path)
    parser.add_argument('--autonomy-controller', type=Path)
    parser.add_argument('--autonomy-controller-digest')
    parser.add_argument('--autonomy-shared-root', type=Path)
    parser.add_argument('--autonomy-delivery-binding', type=Path)
    parser.add_argument('--autonomy-delivery-binding-digest')
    parser.add_argument('--update-agents', action='store_true', help='refresh owned agents only; preserve config and skills')
    parser.add_argument('--force-agent', action='append', default=[], metavar='NAME')
    parser.add_argument('--install', type=Path, help='Launch Control source root, installs native onboard and agents')
    parser.add_argument('--target', type=Path, help='explicit Codex config root for installation only')
    args = parser.parse_args()
    if (args.autonomy_controller or args.autonomy_controller_digest or args.autonomy_shared_root
            or args.autonomy_delivery_binding or args.autonomy_delivery_binding_digest) and not args.enable_autonomy:
        parser.error('controller selection requires --enable-autonomy')
    if args.install and (args.source or args.launch or args.codex or args.enable_autonomy):
        parser.error('--install cannot be combined with project generation options')
    if args.target and not args.install:
        parser.error('--target requires --install')
    if args.force_agent and not args.update_agents:
        parser.error('--force-agent requires --update-agents')
    if args.update_agents and args.launch:
        parser.error('--update-agents cannot be combined with --launch-control')
    if args.enable_autonomy:
        if args.launch or args.update_agents or args.install:
            parser.error('--enable-autonomy cannot be combined with --launch-control, --update-agents, or --install')
        if not args.autonomy_config or not args.autonomy_commands:
            parser.error('--enable-autonomy requires --autonomy-config and --autonomy-commands')
    elif args.autonomy_config or args.autonomy_commands:
        parser.error('--autonomy-config and --autonomy-commands require --enable-autonomy')
    if args.update_agents:
        source = args.install.absolute() if args.install else (args.source or args.project / '.claude').absolute()
        target = ((args.target or Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))).absolute()
                  if args.install else args.project.absolute() / '.codex')
        update_agents(source, target, read_mapping(), bool(args.install), args.dry_run, args.force_agent)
        return
    if args.install:
        # Global ownership upgrades belong to the repository installer; project conversion remains preserve-only.
        import subprocess
        command = [sys.executable, str(args.install.absolute() / 'tools/install-codex.py')]
        if args.target:
            command += ['--target', str(args.target)]
        if args.dry_run:
            command.append('--dry-run')
        raise SystemExit(subprocess.call(command))
    project = args.project.resolve()
    if not args.install and not args.codex and not (project / '.codex').exists() and not (project / '.codex').is_symlink():
        return
    mapping = read_mapping()
    source = args.install.absolute() if args.install else (args.source.absolute() if args.source else project / '.claude')
    target = ((args.target or Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))).absolute()
              if args.install else project / '.codex')
    safe_path(target, target)
    if not source.is_dir():
        hint = '' if args.source else '; pass --source with a staged .claude tree (references/codex-onboard.md)'
        raise ValueError('rendered source directory is missing: ' + str(source) + hint)
    if args.enable_autonomy:
        validate_native_launch(source, target)
    source_digest = bundle_digest(bundle_tree(source)) if args.enable_autonomy else None
    refresh_static = not args.launch and not args.enable_autonomy
    planned, preserved = generate(source, target, mapping, bool(args.install), args.launch, refresh_static)
    refresh = runpy.run_path(str(SKILL / 'scripts/portable-refresh.py'))
    if refresh_static:
        refresh['onboard'](project, 'codex', args.dry_run)
        refresh['onboard'](project, 'claude', args.dry_run)
    if args.enable_autonomy:
        # The normal converter and native overlay publish together from the project root.
        base_changes = {'.codex/' + relative: content.encode('utf-8') for relative, content in planned.items()}
        selection = (args.autonomy_controller, args.autonomy_controller_digest, args.autonomy_shared_root,
                     args.autonomy_delivery_binding, args.autonomy_delivery_binding_digest)
        binding_paths = [args.autonomy_controller] if args.autonomy_controller else []
        if args.autonomy_delivery_binding:
            binding_paths.append(args.autonomy_delivery_binding)
        if args.autonomy_shared_root and args.autonomy_shared_root != project:
            binding_paths += [args.autonomy_shared_root / rel for rel in
                              ('.codex/hooks/launch.sh', '.codex/hooks.json', '.codex/launch-control-launch-ownership.json')]
        bindings = {path: safe_regular(path, 'selected binding') for path in binding_paths}
        changes, extra_preserved, snapshots, guards, config_input, commands_input = autonomy_overlay(
            project, target, args.autonomy_config.absolute(), args.autonomy_commands.absolute(), base_changes, *selection)
        preserved.extend(extra_preserved)
        for relative in preserved:
            print('PRESERVED ' + str(target / relative))
        if not args.dry_run and changes:
            if any(safe_regular(path, 'selected binding') != before for path, before in bindings.items()):
                raise ValueError('selected binding changed during preflight')
            if bundle_digest(bundle_tree(source)) != source_digest:
                raise ValueError('rendered source changed during native autonomy preflight')
            if safe_regular(args.autonomy_config.absolute(), '--autonomy-config') != config_input:
                raise ValueError('--autonomy-config changed during native autonomy preflight')
            if safe_regular(args.autonomy_commands.absolute(), '--autonomy-commands') != commands_input:
                raise ValueError('--autonomy-commands changed during native autonomy preflight')
            for relative, before in guards.items():
                if file_snapshot(project, relative) != before:
                    raise ValueError('destination changed during native autonomy preflight: ' + relative)
            replace_files(project, changes, snapshots)
        for relative in changes:
            status = 'MERGED ' if relative == '.codex/hooks.json' and snapshots[relative] is not None else 'CREATED '
            print(('PLANNED ' if args.dry_run else status) + str(project / relative))
        print('Codex autonomy: ' + str(len(changes)) + (' planned.' if args.dry_run else ' generated.'))
        return
    for relative in preserved:
        print('PRESERVED ' + str(target / relative))
    # Validate everything before creating any file. Exclusive create prevents clobbering.
    for relative, content in planned.items():
        dest = target / relative
        if not args.dry_run:
            safe_path(target, dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            with dest.open('x', encoding='utf-8') as stream:
                stream.write(content)
        print(('PLANNED ' if args.dry_run else 'CREATED ') + str(dest))
    if not args.launch:
        agents_md(project, args.dry_run, args.source.absolute().parent / 'CLAUDE.md' if args.source else None)
    # LC-045: only after `launch` is published can the old generated copy leave discovery.
    refresh['retire_send_it'](project, 'codex', args.dry_run)
    print('Codex: ' + str(len(planned)) + (' planned' if args.dry_run else ' created')
          + ', ' + str(len(preserved)) + ' preserved; project config unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit('Codex generation failed: ' + str(error))
