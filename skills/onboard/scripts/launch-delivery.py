#!/usr/bin/env python3
"""Explicit, frozen admission for restricted Codex delivery on a reviewed host."""
import copy
import base64
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import quote, unquote

_runtime = runpy.run_path(str(Path(__file__).with_name('launch-runtime.py')))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    allow_nan=False).encode()).hexdigest()


def git_blob(raw):
    return hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()


def target_digest(policy):
    return canonical_digest({key: value for key, value in policy.items() if key != 'delivery'})


def execution_digest(config):
    """Exclude only native trust receipts; every execution setting stays pinned."""
    require(isinstance(config, dict), 'invalid native configuration')
    value = copy.deepcopy(config)
    projects = value.pop('projects', {})
    require(isinstance(projects, dict), 'invalid project trust metadata')
    for name, metadata in projects.items():
        require(isinstance(name, str) and isinstance(metadata, dict)
                and set(metadata) == {'trust_level'}
                and metadata['trust_level'] in ('trusted', 'untrusted'),
                'invalid project trust metadata')
    hooks = value.get('hooks', {})
    require(isinstance(hooks, dict), 'invalid hook trust metadata')
    states = hooks.pop('state', {})
    require(isinstance(states, dict), 'invalid hook trust metadata')
    for name, metadata in states.items():
        require(isinstance(name, str) and isinstance(metadata, dict)
                and set(metadata) <= {'trusted_hash', 'enabled'}, 'invalid hook trust metadata')
        if 'trusted_hash' in metadata:
            require(isinstance(metadata['trusted_hash'], str)
                    and re.fullmatch(r'sha256:[0-9a-f]{64}', metadata['trusted_hash']),
                    'invalid hook trust metadata')
        if 'enabled' in metadata:
            require(type(metadata['enabled']) is bool, 'invalid hook trust metadata')
    if 'hooks' in value and not hooks:
        del value['hooks']
    return canonical_digest(value)


def checked_path(value, file=False):
    require(isinstance(value, str) and value and Path(value).is_absolute(), 'absolute delivery path required')
    path = Path(value)
    try:
        _runtime['safe_path'](path)
    except _runtime['Invalid'] as error:
        raise ValueError(str(error)) from error
    require(path == path.resolve(), 'canonical delivery path required')
    if file:
        require(path.is_file(), 'regular delivery file required: ' + str(path))
    return path


def hex_value(value, lengths=(64,)):
    return isinstance(value, str) and len(value) in lengths and re.fullmatch('[0-9a-f]+', value)


def pinned_json(path, expected):
    path = checked_path(path, file=True)
    require(hex_value(expected), 'invalid delivery digest')
    raw = path.read_bytes()
    require(_runtime['digest'](raw) == expected, 'delivery binding changed: ' + str(path))
    result = json.loads(raw)
    require(isinstance(result, dict), 'delivery object required')
    return result


def file_stamp(path):
    stat = path.stat()
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mode, stat.st_mtime_ns, stat.st_ctime_ns


@lru_cache(maxsize=512)
def reviewed_digest(path, stamp):
    # These files are outside worker writes; ctime also detects same-size/mtime edits.
    value = _runtime['digest'](path.read_bytes())
    require(file_stamp(path) == stamp, 'reviewed file changed while hashing')
    return value


def load_binding(binding):
    """Filesystem-only admission; never run Git or snapshot current files as approval."""
    require(isinstance(binding, dict) and set(binding) == {'grant', 'digest'}, 'invalid delivery binding')
    grant = pinned_json(binding['grant'], binding['digest'])
    require(set(grant) - {'publication', 'source_writeback', 'max_tokens', 'dependencies'} == {'schema', 'target_digest', 'verification', 'repository', 'base_branch',
            'base_revision', 'source', 'workspace', 'host_policy', 'allowed_actions',
            'minutes', 'max_attempts', 'max_launches'} and type(grant['schema']) is int
            and grant['schema'] == 1, 'invalid delivery grant')
    require(hex_value(grant['target_digest']) and hex_value(grant['base_revision'], (40, 64)),
            'invalid grant revision or target digest')
    require(isinstance(grant['repository'], str)
            and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', grant['repository'])
            and all(part not in ('.', '..') for part in grant['repository'].split('/')), 'invalid repository')
    branch = grant['base_branch']
    require(isinstance(branch, str) and branch and not branch.startswith('-')
            and not any(c.isspace() or ord(c) < 32 for c in branch), 'invalid base branch')
    actions = grant['allowed_actions']
    require(isinstance(actions, list) and all(isinstance(a, str) for a in actions)
            and len(set(actions)) == len(actions)
            and {'prepare', 'implement', 'review'} <= set(actions)
            <= {'prepare', 'implement', 'review', 'push', 'pull_request', 'publish', 'source_done'},
            'invalid delivery actions')
    publish_actions = {'push', 'pull_request', 'publish'}
    publication = grant.get('publication')
    if publish_actions & set(actions):
        require(publish_actions <= set(actions), 'incomplete publication authority')
        require(isinstance(publication, dict)
                and set(publication) - {'post_merge_checks'} == {'mode', 'deployment', 'required_checks', 'billing_fallback'}
                and publication['mode'] == 'github-base-lease' and publication['deployment'] == 'none'
                and type(publication['billing_fallback']) is bool, 'unsupported publication contract')
        for checks in (publication['required_checks'], publication.get('post_merge_checks', [])):
            require(isinstance(checks, list) and all(isinstance(c, dict) and set(c) == {'name', 'app_id'}
                    and isinstance(c['name'], str) and c['name'].strip()
                    and not any(ord(x) < 32 or ord(x) == 127 for x in c['name'])
                    and type(c['app_id']) is int and c['app_id'] > 0 for c in checks)
                    and len({(c['name'], c['app_id']) for c in checks}) == len(checks),
                    'invalid publication checks')
    else:
        require('publication' not in grant, 'publication contract lacks authority')
    for name, ceiling in (('minutes', 60), ('max_attempts', 5), ('max_launches', 100)):
        require(type(grant[name]) is int and 1 <= grant[name] <= ceiling, 'invalid delivery cap: ' + name)
    require('max_tokens' not in grant or (type(grant['max_tokens']) is int and grant['max_tokens'] > 0), 'invalid delivery cap: max_tokens')
    source = grant['source']
    require(isinstance(source, dict) and set(source) == {'path', 'format', 'heading', 'blob'}
            and source['format'] == 'table' and isinstance(source['heading'], str)
            and re.fullmatch(r'#{1,6} .+', source['heading'])
            and hex_value(source['blob'], (40, 64)), 'invalid delivery source')
    require(isinstance(source['path'], str) and source['path']
            and not Path(source['path']).is_absolute()
            and all(part not in ('', '.', '..') for part in source['path'].split('/')), 'unsafe delivery source')
    if 'source_done' in actions:
        require(publication is not None and isinstance(grant.get('source_writeback'), dict)
                and type(grant['source_writeback'].get('max_attempts')) is int
                and grant['source_writeback'] == {
            'repository': grant['repository'], 'branch': grant['base_branch'],
            'path': source['path'], 'heading': source['heading'], 'max_attempts': 2},
            'unsupported or missing explicit source writeback authority')
    else:
        require('source_writeback' not in grant, 'source writeback lacks authority')
    verification = grant['verification']
    require(isinstance(verification, dict) and set(verification) == {'schema', 'checks', 'acceptance'}
            and type(verification['schema']) is int and verification['schema'] == 1,
            'invalid approved verification')
    checks, acceptance = verification['checks'], verification['acceptance']
    require(isinstance(checks, list) and checks and isinstance(acceptance, list) and acceptance
            and all(isinstance(a, str) and a.strip() for a in acceptance)
            and len(set(acceptance)) == len(acceptance), 'empty approved verification')
    for check in checks:
        require(isinstance(check, dict) and set(check) == {'command', 'cwd', 'timeout'}
                and isinstance(check['command'], str) and check['command'].strip()
                and isinstance(check['cwd'], str) and check['cwd']
                and not Path(check['cwd']).is_absolute() and '..' not in Path(check['cwd']).parts
                and type(check['timeout']) in (int, float) and 0 < check['timeout'] <= 3600,
                'invalid approved check')
    require(len({(c['command'], c['cwd']) for c in checks}) == len(checks), 'duplicate approved check')
    workspace = checked_path(grant['workspace'])
    dependencies = grant.get('dependencies', [])
    def relative(value):
        # APFS is case-insensitive: `.GIT/hooks` is `.git/hooks`.
        return (isinstance(value, str) and value and not Path(value).is_absolute()
                and all(part not in ('', '.', '..') for part in value.split('/'))
                and value.split('/')[0].casefold() not in ('.git', '.codex'))
    require(isinstance(dependencies, list), 'invalid provisioned dependencies')
    for dependency in dependencies:
        require(isinstance(dependency, dict) and set(dependency) == {'target', 'source', 'digest', 'lockfile', 'lock_digest'}
                and relative(dependency['target']) and relative(dependency['lockfile'])
                and hex_value(dependency['digest']) and hex_value(dependency['lock_digest']),
                'invalid provisioned dependency')
    targets = [Path(d['target'].casefold()) for d in dependencies]
    require(not any(a.is_relative_to(b) for i, a in enumerate(targets) for j, b in enumerate(targets) if i != j),
            'invalid provisioned dependencies: duplicate or nested targets')
    host_binding = grant['host_policy']
    require(isinstance(host_binding, dict) and set(host_binding) == {'path', 'digest'}, 'invalid host policy binding')
    host = pinned_json(host_binding['path'], host_binding['digest'])
    require(set(host) == {'schema', 'platform', 'codex_version', 'codex', 'python', 'git', 'gh',
            'path', 'read_roots', 'read_files', 'files', 'native_config', 'native_overrides', 'hook_commands'}
            and type(host['schema']) is int and host['schema'] == 1, 'invalid reviewed host policy')
    require(host['platform'] == platform.system() == 'Darwin'
            and host['codex_version'] == 'codex-cli 0.162.0' and sys.version_info >= (3, 11),
            'unsupported delivery host')
    import tomllib
    native = host['native_config']
    require(isinstance(native, dict) and set(native) == {'path', 'execution_digest'}, 'invalid native config binding')
    native_path = checked_path(native['path'], file=True)
    code_home = checked_path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    require(native_path == code_home / 'config.toml', 'unbound native configuration location')
    native_config = tomllib.loads(native_path.read_text())
    require(hex_value(native['execution_digest'])
            and execution_digest(native_config) == native['execution_digest'],
            'execution configuration changed')
    files = host['files']
    require(isinstance(files, dict) and files and str(native_path) not in files, 'invalid reviewed file inventory')
    for name, expected in files.items():
        path = checked_path(name, file=True)
        require(hex_value(expected) and reviewed_digest(path, file_stamp(path)) == expected,
                'reviewed file changed: ' + name)
    for key in ('codex', 'python', 'git', 'gh'):
        executable = checked_path(host[key], file=True)
        require(str(executable) in files and os.access(executable, os.X_OK), 'unreviewed executable: ' + key)
    home = checked_path(str(Path.home()))
    protected = [checked_path(binding['grant']), checked_path(host_binding['path']), native_path,
                 code_home / 'auth.json', home / '.ssh', home / '.config/gh', workspace]
    for path in [*protected[:-1], *map(Path, files)]:
        require(not path.is_relative_to(workspace), 'delivery authority overlaps workspace')
    for key in ('read_roots', 'read_files', 'path'):
        require(isinstance(host[key], list) and all(isinstance(p, str) for p in host[key])
                and len(set(host[key])) == len(host[key]), 'invalid runtime access list')
        for name in host[key]:
            path = checked_path(name, file=key == 'read_files')
            require(path.is_file() if key == 'read_files' else path.is_dir(), 'missing runtime path')
            require(not any(p.is_relative_to(path) or path.is_relative_to(p) for p in protected),
                    'runtime access overlaps protected authority')
            require(not home.is_relative_to(path) and not code_home.is_relative_to(path),
                    'runtime access encompasses native home')
    # Dependency trees are copied into worker-visible checkouts; they must not carry authority.
    for dependency in dependencies:
        source = checked_path(dependency['source'])
        require(source.is_dir() and not any(p.is_relative_to(source) or source.is_relative_to(p) for p in protected)
                and not home.is_relative_to(source) and not code_home.is_relative_to(source),
                'provisioned dependency overlaps protected authority or is missing')
    roots = [Path(p) for p in host['read_roots']]
    require(all(p in ('/usr/bin', '/bin') or any(Path(p).is_relative_to(r) for r in roots)
                for p in host['path']), 'PATH is outside reviewed runtime roots')
    overrides = host['native_overrides']
    require(isinstance(overrides, list) and all(isinstance(v, str) and re.fullmatch(
        r'(?:mcp_servers|plugins)\.[A-Za-z0-9_@./-]+\.enabled=false', v) for v in overrides)
        and len(set(overrides)) == len(overrides), 'invalid native integration overrides')
    for category in ('mcp_servers', 'plugins'):
        integrations = native_config.get(category, {})
        require(isinstance(integrations, dict) and all(
            category + '.' + name + '.enabled=false' in overrides for name in integrations),
            'native integration is not disabled')
    agents = native_config.get('agents', {})
    require(isinstance(agents, dict), 'invalid reviewed native agents')
    for agent in agents.values():
        if isinstance(agent, dict) and 'config_file' in agent:
            config_file = checked_path(agent['config_file'], file=True)
            require(str(config_file) in files, 'unreviewed native agent configuration')
    for path in (code_home / 'hooks.json',):
        require(not path.exists() or str(path) in files, 'unreviewed native hooks')
    validate_hooks(host, native_config, code_home)
    for parent in workspace.parents:
        for name in ('config.toml', 'hooks.json'):
            layer = parent / '.codex' / name
            require(not layer.exists() or layer in (native_path, code_home / 'hooks.json'),
                    'unsupported ancestor native configuration: ' + str(layer))
    return {'binding': dict(binding), 'grant': grant, 'host': host}


def validate_hooks(host, native_config, code_home):
    require(set(native_config.get('hooks', {})) <= {'state'}, 'inline native hooks are unsupported')
    path = code_home / 'hooks.json'
    document = json.loads(path.read_text()) if path.exists() else {'hooks': {}}
    require(isinstance(document, dict) and isinstance(document.get('hooks'), dict), 'invalid native hooks document')
    commands = set()
    for groups in document['hooks'].values():
        require(isinstance(groups, list), 'invalid native hook groups')
        for group in groups:
            require(isinstance(group, dict) and isinstance(group.get('hooks'), list), 'invalid native hook group')
            for hook in group['hooks']:
                require(isinstance(hook, dict) and hook.get('type') == 'command'
                        and isinstance(hook.get('command'), str), 'unsupported native hook type')
                commands.add(hook['command'])
    inventory = host['hook_commands']
    require(isinstance(inventory, dict) and set(inventory) == commands, 'native hook command inventory mismatch')
    for command, listed in inventory.items():
        require(isinstance(listed, list) and listed and all(isinstance(p, str) for p in listed)
                and len(set(listed)) == len(listed), 'invalid reviewed hook artifact list')
        for name in listed:
            checked_path(name, file=True)
            require(name in host['files'], 'unreviewed transitive hook artifact')
        require(hook_artifacts(command, host['path']) <= set(listed), 'resolved hook artifact missing from reviewed command')


def hook_artifacts(command, path):
    """The executable, script and shebang interpreters a hook command resolves to under PATH."""
    interpreters = {'bash', 'sh', 'zsh', 'python3'}
    def executable(value):
        if not Path(value).is_absolute():
            require(value in interpreters, 'unsupported relative hook executable')
            value = shutil.which(value, path=os.pathsep.join(path))
            require(value is not None, 'missing reviewed hook interpreter')
        return str(checked_path(str(Path(value).resolve()), file=True))
    require(command and not any(c in command for c in '\n\r`$|&;<>'), 'unsupported native hook command syntax')
    argv = shlex.split(command)
    require(argv and '-c' not in argv, 'unsupported native hook command syntax')
    first = executable(argv[0])
    derived = {first}
    if Path(argv[0]).name in interpreters or re.fullmatch(r'python3(?:\.\d+)?', Path(first).name):
        offset = 2 if len(argv) > 1 and argv[1] == '-I' else 1
        require(len(argv) > offset and Path(argv[offset]).is_absolute(), 'absolute hook script required')
        derived.add(str(checked_path(argv[offset], file=True)))
    else:
        with Path(first).open('rb') as stream:
            line = stream.readline(512)
        if line.startswith(b'#!'):
            shebang = shlex.split(line[2:].decode().strip())
            require(shebang and '-c' not in shebang, 'unsupported hook shebang')
            derived.add(executable(shebang[0]))
            if Path(shebang[0]).name == 'env':
                require(len(shebang) == 2 and shebang[1] in interpreters, 'unsupported hook env shebang')
                derived.add(executable(shebang[1]))
    return derived


def validate_target(admitted, policy):
    grant = admitted['grant']
    require(target_digest(policy) == grant['target_digest'], 'approved target policy changed')
    require(policy.get('base_revision') == grant['base_revision']
            and policy.get('source') == {k: v for k, v in grant['source'].items() if k != 'blob'},
            'target source or base differs from grant')
    caps = policy.get('caps', {})
    require(caps.get('minutes') == grant['minutes'] and caps.get('max_attempts') == grant['max_attempts']
            and caps.get('rollover', {}).get('max_launches') == grant['max_launches']
            and caps.get('max_tokens') == grant.get('max_tokens'),
            'target limits differ from grant')
    if 'publication' in grant and grant['max_launches'] > 1 and grant['max_attempts'] > 1:
        commands = caps.get('rollover', {}).get('synchronous_commands', [])
        require(all(command in commands for command in ('git rev-parse HEAD^2', 'git diff HEAD^2...HEAD')),
                'repair review requires exact second-parent inspection commands')
    original = checked_path(policy['project'])
    workspace = checked_path(grant['workspace'])
    require(not original.is_relative_to(workspace) and not workspace.is_relative_to(original),
            'original project overlaps delivery workspace')


def tool_environment(admitted, values=None):
    values = values or {}
    env = {key: values[key] for key in ('LANG', 'LC_ALL', 'LAUNCH_RUN_ID') if key in values}
    env.update(PATH=os.pathsep.join(admitted['host']['path']), PYTHONDONTWRITEBYTECODE='1',
               LAUNCH_PLATFORM='codex', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_COUNT='4')
    for number, (key, value) in enumerate((('core.hooksPath', '/dev/null'), ('core.fsmonitor', 'false'),
                                         ('core.excludesFile', '/dev/null'), ('core.attributesFile', '/dev/null'))):
        env['GIT_CONFIG_KEY_' + str(number)] = key
        env['GIT_CONFIG_VALUE_' + str(number)] = value
    return env


def host_environment(admitted):
    env = {key: value for key, value in os.environ.items()
           if key in ('HOME', 'CODEX_HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
    env.update(PATH=os.pathsep.join(admitted['host']['path']), PYTHONDONTWRITEBYTECODE='1')
    return env


def toml_inline(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k) + '=' + toml_inline(v) for k, v in value.items()) + '}'
    return json.dumps(value, allow_nan=False)


def permission_options(filesystem):
    return ['-c', 'permissions.launch_control_delivery=' + toml_inline({
        'filesystem': {':root': 'deny', ':minimal': 'read', **filesystem},
        'network': {'enabled': False}})]


def item_cell(text):
    """The Item cell of a selected BACKLOG table row; unescaped pipes are structural."""
    cells = [cell.strip() for cell in re.split(r'(?<!\\)\|', text.strip().strip('|'))]
    return cells[1] if len(cells) > 1 else ''


def row_title(text):
    """The row's leading bold text, else its first sentence."""
    item = item_cell(text)
    bold = re.match(r'\*\*(.+?)\*\*', item)
    return (bold[1] if bold else re.split(r'(?<=[.!?])\s', item, maxsplit=1)[0]).strip().rstrip('.:')


def pr_title(ident, text):
    title = '[' + ident + '] ' + (row_title(text) or 'deliver approved task')
    return title if len(title) <= 72 else title[:71].rstrip() + '…'


def mission_name(heading):
    text = heading.lstrip('#').strip()
    match = re.fullmatch(r'Mission:\s*(.+)', text)
    return match[1].strip() if match else text


def foreign_stale_pr(row, marker):
    """A closed, unmerged PR from another run on the same head branch never binds this one."""
    return (isinstance(row, dict) and row.get('state') == 'closed' and row.get('merged_at') is None
            and marker not in (row.get('body') or ''))


def sandbox_command(admitted, cwd, filesystem, command, env):
    return [admitted['host']['codex'], 'sandbox', '-P', 'launch_control_delivery',
            *permission_options(filesystem), '-C', str(cwd), '--', '/usr/bin/env', '-i',
            *[key + '=' + value for key, value in env.items()], *map(str, command)]


def run_owned(command, cwd, env, timeout=60, input=None, on_start=None):
    """Retain the established check contract: a leader exit is not group closure."""
    proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE if input is not None else None,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        if on_start is not None:
            on_start(proc.pid)
        stdout, stderr = proc.communicate(input, timeout=timeout)
    except BaseException:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.communicate()
        raise
    if _runtime['group_closed'](proc.pid):
        return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    for _ in range(50):
        if _runtime['group_closed'](proc.pid, 0):
            break
        time.sleep(.02)
    raise ValueError('owned delivery process group remained')


def preparation_path(admitted):
    return Path(admitted['binding']['grant']).parent / 'delivery-preparation.json'


def preparation_record(admitted, sealed=True):
    path = checked_path(str(preparation_path(admitted)), file=True)
    record = json.loads(path.read_text())
    require(isinstance(record, dict) and record.get('grant_digest') == admitted['binding']['digest']
            and record.get('workspace') == admitted['grant']['workspace'], 'delivery preparation identity changed')
    if sealed:
        require(record.get('status') == 'prepared', 'delivery preparation is not sealed')
        files = record.get('files')
        require(isinstance(files, dict) and files, 'missing protected delivery metadata')
        for name, expected in files.items():
            path = checked_path(name)
            require(not path.exists() if expected is None else path.is_file()
                    and _runtime['digest'](path.read_bytes()) == expected, 'protected delivery metadata changed: ' + name)
    return record


def filesystem(admitted, preparing=False, original=None):
    host = admitted['host']
    result = {name: 'read' for name in [*host['read_roots'], *host['read_files']]}
    workspace = Path(admitted['grant']['workspace'])
    if preparing:
        result[str(workspace)] = 'write'
        result[str(workspace / '.git')] = 'write'
        if original is not None:
            result[str(original)] = 'read'
        result[admitted['binding']['grant']] = 'read'
    else:
        record = preparation_record(admitted)
        worktree = checked_path(record['worktree'])
        require(worktree.is_relative_to(workspace / '.git/launch-prepared'), 'unexpected prepared worktree')
        # Codex 0.162 makes a writable root's gitdir read-only; run state and commits live there.
        result.update({str(workspace): 'read', str(workspace / '.git'): 'write', str(worktree): 'write',
                       str(workspace / '.git/worktrees' / worktree.name): 'write',
                       str(workspace / '.git/launch-queue'): 'read',
                       str(workspace / '.codex'): 'read', str(worktree / '.codex'): 'read'})
        for name in record['files']:
            if Path(name).is_relative_to(workspace):
                result[name] = 'read'
    return result


def git_filesystem(root, permissions):
    # Codex protects .agents beneath a writable root; Git alone may still check out a tracked project skill.
    if permissions.get(str(root)) == 'write':
        return {**permissions, str(Path(root) / '.agents'): 'write'}
    return permissions


def restricted_git(admitted, root, permissions, *args, input=None):
    command = sandbox_command(admitted, root, git_filesystem(root, permissions),
                              [admitted['host']['git'], '-C', str(root), *args], tool_environment(admitted))
    result = run_owned(command, root, host_environment(admitted), input=input)
    require(not any(word in result.stderr.lower() for word in
                    (b'warning:', b'fatal:', b'error:', b'operation not permitted')),
            'restricted Git diagnostic: ' + result.stderr.decode(errors='replace')[:500])
    return result


def tree_digest(root):
    """Identity of a host-built dependency tree: names, links, executable bits and bytes."""
    root, entries = Path(root), []
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if path.is_symlink():
            entries.append([name, 'link', os.readlink(path)])
        elif path.is_dir():
            entries.append([name, 'dir'])
        else:
            mode = path.stat().st_mode & 0o7777
            require(path.is_file() and not mode & 0o6000, 'unsupported provisioned dependency entry: ' + name)
            with path.open('rb') as stream:
                entries.append([name, mode, hashlib.file_digest(stream, 'sha256').hexdigest()])
    return canonical_digest(entries)


def refused_candidate_paths(paths, grant):
    """LC-030 v1 boundary: .github (workflows and the actions they run), generated Launch files
    and approved lockfiles stay untouched. A changed lockfile would also block the next task's
    provision. Case-folded, because APFS resolves .GitHub to .github (see relative()).
    """
    locks = {dependency['lockfile'].casefold() for dependency in grant.get('dependencies', [])}
    return [path for path in paths
            if path.casefold().startswith(('.github/', '.codex/', '.claude/', '.agents/'))
            or path.casefold() in {'scripts/verify.sh', *locks}]


def provision(admitted, root):
    """Copy approved host-built dependencies into a checkout whose lockfiles still match them."""
    root = Path(root)
    for dependency in admitted['grant'].get('dependencies', []):
        lockfile = checked_path(str(root / dependency['lockfile']), file=True)
        require(_runtime['digest'](lockfile.read_bytes()) == dependency['lock_digest'],
                'dependency lockfile changed; re-provision outside delivery: ' + dependency['lockfile'])
        target = root / dependency['target']
        checked_path(str(target.parent))
        require(not target.exists() and not target.is_symlink(), 'provisioned dependency target exists: ' + dependency['target'])
        try:
            shutil.copytree(checked_path(dependency['source']), target, symlinks=True)
            copied = tree_digest(target)
        except OSError as error:
            raise ValueError('provisioned dependency copy failed: ' + str(error)[:300]) from error
        if copied != dependency['digest']:
            shutil.rmtree(target, ignore_errors=True)  # A partial residue stays as evidence.
            raise ValueError('provisioned dependency changed: ' + dependency['source'])


def verify_snapshot(admitted, source, candidate, destination):
    """Run the pinned verifier on fresh objects, never a worker receipt."""
    admitted = load_binding(admitted['binding'])
    require(hex_value(candidate, (40, 64)), 'invalid verification candidate')
    source, destination = checked_path(str(source)), checked_path(str(destination))
    require(source.is_dir() and not destination.exists(), 'verification snapshot already exists or source missing')
    require(not destination.is_relative_to(source) and not source.is_relative_to(destination),
            'verification snapshot overlaps source')
    for path in (source / '.git/objects/info/alternates', source / 'objects/info/alternates'):
        require(not path.exists() and not path.is_symlink(), 'verification source has object alternatives')
    destination.mkdir()
    worktree = destination / 'repo'
    host = admitted['host']
    reads = {name: 'read' for name in [*host['read_roots'], *host['read_files']]}
    # Codex protects .agents beneath a writable root; a tracked project skill must still check out.
    permissions = {**reads, str(source): 'read', str(destination): 'read',
                   str(worktree): 'write', str(worktree / '.git'): 'write', str(worktree / '.agents'): 'write'}
    def git(root, *args):
        result = restricted_git(admitted, root, permissions, *args)
        require(result.returncode == 0, 'verification Git failed: ' + result.stderr.decode(errors='replace')[:300])
        return result.stdout.decode().strip()
    git(destination, 'clone', '--no-hardlinks', '--no-checkout', '--template=', str(source), str(worktree))
    git(worktree, 'checkout', '-b', 'verification', candidate)
    tree = git(worktree, 'rev-parse', 'HEAD^{tree}')
    require(git(worktree, 'rev-parse', 'HEAD') == candidate
            and not git(worktree, 'status', '--porcelain', '--untracked-files=all'), 'verification checkout mismatch')
    entries = git(worktree, 'ls-tree', '-r', candidate).splitlines()
    require(not any(line.startswith(('120000 ', '160000 ')) for line in entries),
            'verification symlinks or submodules unsupported')
    provision(admitted, worktree)
    require(not git(worktree, 'status', '--porcelain', '--untracked-files=all'), 'provisioned dependency is not ignored')
    config = destination / 'verification.json'
    _runtime['atomic'](config, admitted['grant']['verification'])
    config_digest = _runtime['digest'](config.read_bytes())
    runtime = Path(__file__).with_name('launch-runtime.py').resolve()
    require(host['files'].get(str(runtime)) == _runtime['digest'](runtime.read_bytes()),
            'independent verifier runtime is not pinned')
    temporary = worktree / '.git/launch/tmp'
    temporary.mkdir(parents=True)
    # Checks may write ignored caches and build output; HEAD, tree and status are re-proved after.
    # Dependency trees stay read-only so one check cannot rewrite the tools a later check runs.
    permissions = {**reads, str(worktree): 'write', str(worktree / '.git'): 'read',
                   str(worktree / '.git/launch'): 'write', str(config): 'read',
                   **{str(worktree / d['target']): 'read' for d in admitted['grant'].get('dependencies', [])}}
    env = {**tool_environment(admitted), 'TMPDIR': str(temporary)}
    argv = [host['python'], '-I', str(runtime), '--project', str(worktree), '--config', str(config),
            '--platform', 'codex', 'verify', 'checks']
    limit = sum(check['timeout'] for check in admitted['grant']['verification']['checks']) + 30
    result = run_owned(sandbox_command(admitted, worktree, permissions, argv, env),
                       worktree, host_environment(admitted), timeout=limit)
    (destination / 'stdout').write_bytes(result.stdout)
    (destination / 'stderr').write_bytes(result.stderr)
    require(result.returncode == 0 and not result.stderr, 'independent verification failed')
    receipt = json.loads(result.stdout)
    checks = receipt.get('checks') if isinstance(receipt, dict) else None
    expected = admitted['grant']['verification']['checks']
    require(isinstance(checks, list) and len(checks) == len(expected) and checks
            and all(isinstance(actual, dict) and actual.get('exit') == 0
                    and actual.get('group_gone') is True
                    and all(actual.get(key) == value for key, value in check.items())
                    for actual, check in zip(checks, expected))
            and receipt.get('ok') is True and receipt.get('revision') == candidate
            and receipt.get('worktree') == str(worktree) and receipt.get('branch') == 'verification'
            and receipt.get('platform') == 'codex' and receipt.get('mode') == 'checks'
            and receipt.get('config_digest') == config_digest, 'independent verification receipt mismatch')
    require(git(worktree, 'rev-parse', 'HEAD') == candidate and git(worktree, 'rev-parse', 'HEAD^{tree}') == tree
            and not git(worktree, 'status', '--porcelain', '--untracked-files=all')
            and _runtime['digest'](config.read_bytes()) == config_digest, 'independent verification changed')
    for dependency in admitted['grant'].get('dependencies', []):
        require(tree_digest(worktree / dependency['target']) == dependency['digest'],
                'provisioned dependency changed during checks: ' + dependency['target'])
    receipt['tree'] = tree
    _runtime['atomic'](destination / 'result.json', receipt)
    return receipt


def bind_runtime(runtime, binding, preparing=False, original=None):
    admitted = load_binding(binding)
    if not preparing:
        preparation_record(admitted)
    def git_runner(root, *args):
        current = load_binding(binding)
        receipt = preparation_path(current)
        sealed = receipt.exists() and preparation_record(current, sealed=False).get('status') == 'prepared'
        require(preparing or sealed, 'unsealed delivery Git operation')
        permissions = filesystem(current, preparing=preparing and not sealed, original=original)
        return restricted_git(current, root, permissions, *args)
    def check_command(root, argv):
        current = load_binding(binding)
        preparation_record(current)
        return (sandbox_command(current, root, filesystem(current), ['/bin/bash', *argv[1:]],
                                tool_environment(current)), host_environment(current))
    runtime.configure_git(binding['digest'], git_runner, check_command)
    return admitted


def run_hook(binding, shared_root, code):
    if not os.environ.get('LAUNCH_RUN_ID'):
        print('{}')
        return
    admitted = load_binding(binding)
    require(shared_root == admitted['grant']['workspace'], 'delivery launcher belongs to another clone')
    payload = sys.stdin.buffer.read(1024 * 1024 + 1)
    require(len(payload) <= 1024 * 1024, 'native hook payload exceeds limit')
    command = sandbox_command(admitted, shared_root, filesystem(admitted),
                              [admitted['host']['python'], '-I', '-c', code],
                              tool_environment(admitted, os.environ))
    result = run_owned(command, shared_root, host_environment(admitted), timeout=8, input=payload)
    require(result.returncode == 0 and not result.stderr, 'restricted hook process failed')
    value = json.loads(result.stdout)
    require(isinstance(value, dict), 'invalid restricted hook result')
    print(json.dumps(value))


class GitHubError(ValueError):
    def __init__(self, message, body):
        super().__init__(message)
        self.body = body


def github_endpoint(admitted, endpoint):
    """The ambient gh login reaches every repository; only the granted one is ever named."""
    path = endpoint.split('?', 1)[0]
    repository = 'repos/' + admitted['grant']['repository']
    require(path == 'user' or ((path == repository or path.startswith(repository + '/'))
            and not {'.', '..'} & set(unquote(path).split('/'))), 'ungranted GitHub endpoint')
    return endpoint


def gh_api(admitted, endpoint, *args, cwd=None, timeout=30):
    return run_owned([admitted['host']['gh'], 'api', '--hostname', 'github.com', github_endpoint(admitted, endpoint), *args],
                     cwd or Path(admitted['binding']['grant']).parent, host_environment(admitted), timeout=timeout)


def credential_git(admitted, cwd, env, *args):
    """Git with the gh credential helper, refusing any remote but the granted repository."""
    url = 'https://github.com/' + admitted['grant']['repository'] + '.git'
    def allowed(arg):
        # Anything with a colon can name a remote (scp form, transports, -c url rewrites); only the
        # granted URL, branch refspecs and the expected-base lease may carry one.
        return (arg == url or (':' not in arg and not arg.startswith(('-c', '--config', '-u', '--upload-pack',
                                                                       '--receive-pack', '--exec')))
                or re.fullmatch(r'\+?(refs/heads/[^:\s]+|[0-9a-f]{40,64}):refs/heads/[^:\s]+', arg)
                or re.fullmatch(r'--force-with-lease=refs/heads/[^:\s]+:([0-9a-f]{40,64})?', arg))
    require(args.count(url) == 1 and all(map(allowed, args)), 'ungranted Git remote')
    return run_owned([admitted['host']['git'], '-c', 'credential.helper=', '-c',
                      'credential.helper=!' + shlex.quote(admitted['host']['gh']) + ' auth git-credential', *args],
                     cwd, env)


def github_read(admitted, endpoint):
    result = gh_api(admitted, endpoint)
    if result.returncode != 0:
        try:
            body = json.loads(result.stdout)
        except ValueError:
            body = None
        raise GitHubError('GitHub read failed: ' + result.stderr.decode(errors='replace')[:300], body)
    return json.loads(result.stdout)


RULES_UNAVAILABLE = {'message': 'Upgrade to GitHub Pro or make this repository public to enable this feature.',
                     'documentation_url': 'https://docs.github.com/rest/repos/rules#get-rules-for-a-branch',
                     'status': '403'}


def branch_rules(read, repository, branch):
    """Effective rules; a private repository on a plan without rulesets or protection has none."""
    try:
        return read(repository + '/rules/branches/' + branch + '?per_page=100')
    except GitHubError as error:
        require(error.body == RULES_UNAVAILABLE, str(error))
        repo = read(repository)
        require(isinstance(repo, dict) and repo.get('private') is True, str(error))
        return []


class PublicationPending(ValueError):
    pass


class PublicationPaused(ValueError):
    """An operator pause before a write; the next run resumes from the journal."""


def check_conclusions(required, runs, statuses, billing, observed=False):
    """Exact required identities plus every observed current result gate the write.

    `observed` gates only what ran: an explicit empty post-merge list for a repository whose
    workflows run on pull requests, never on the merged base commit."""
    require(isinstance(runs, list) and isinstance(statuses, list), 'malformed hosted checks')
    if not required and not observed:
        require(not runs and not statuses, 'hosted checks exist outside empty publication contract')
        return 'not_declared'
    if observed and not runs and not statuses:
        raise PublicationPending('no hosted result observed on the merged commit yet')
    seen, unavailable = set(), False
    declared = {(check['name'], check['app_id']) for check in required}
    for run in runs:
        require(isinstance(run, dict) and isinstance(run.get('app'), dict)
                and isinstance(run.get('name'), str) and type(run['app'].get('id')) is int,
                'malformed hosted check identity')
        identity = (run['name'], run['app']['id'])
        require(identity not in seen, 'ambiguous hosted check identity')
        seen.add(identity)
        if run.get('status') in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
            raise PublicationPending('hosted checks pending')
        require(run.get('status') == 'completed', 'unknown hosted check status')
        # A skipped additional job ran nothing; required checks must still pass or prove billing.
        if run.get('conclusion') == 'skipped' and identity not in declared:
            continue
        if run.get('conclusion') != 'success':
            require(run.get('conclusion') == 'failure' and billing(run) is True,
                    'hosted check failed or unavailable')
            unavailable = True
    if not declared <= seen:
        raise PublicationPending('required hosted checks missing')
    for status in statuses:
        require(isinstance(status, dict), 'malformed hosted status')
        if status.get('state') == 'pending':
            raise PublicationPending('hosted commit status pending')
        require(status.get('state') == 'success', 'hosted commit status failed or unknown')
    return 'billing_unavailable' if unavailable else 'passed'


class Publisher:
    """One granted GitHub task, under the existing queue lock."""
    def __init__(self, queue, item, runtime, reviewer_synchronous):
        self.queue, self.item, self.rt = queue, item, runtime
        self.reviewer_synchronous = reviewer_synchronous
        self.admitted = check_binding(queue)
        self.grant = self.admitted['grant']
        require('publication' in self.grant, 'publication was not granted')
        self.worktree = Path(item['worktree'])
        self.runtime = runtime.Runtime(self.worktree, None, 'codex')
        live = self.runtime.load(item['run'])
        limits = item.get('runtime_limits')
        require(isinstance(limits, dict) and limits == {key: live[key] for key in ('deadline', 'max_attempts')},
                'original publication runtime limits unavailable or changed')
        self.identity = {'schema': 1, 'grant': queue.cfg['delivery']['digest'], 'manifest': queue.hash,
                         'run': item['run'], 'deadline': queue.state['deadline'],
                         'runtime_limits': limits, 'repository': self.grant['repository'],
                         'base_branch': self.grant['base_branch'],
                         'head_branch': runtime.identity(self.worktree)['branch']}
        require(self.identity['head_branch'] != self.grant['base_branch'], 'task branch is the publication base')
        for branch in (self.identity['head_branch'], self.grant['base_branch']):
            runtime.git(self.worktree, 'check-ref-format', '--branch', branch)
        if 'delivery' not in item:
            require(item['status'] == 'awaiting_review', 'publication needs reviewed candidate')
            item['delivery'] = {**self.identity, 'stage': 'reviewed', 'candidates': [], 'intents': []}
            queue.save()
        self.record = item['delivery']
        require(all(self.record.get(key) == value for key, value in self.identity.items()),
                'publication journal identity changed')
        self.root = checked_path(str(Path(queue.cfg['delivery']['grant']).parent / ('publication-' + queue.hash)))
        marker = self.root / 'owner.json'
        if not self.root.exists():
            self.root.mkdir()
            _runtime['atomic'](marker, self.identity)
        require(_runtime['read_json'](marker) == self.identity, 'publication artifact ownership changed')
        self.store = self.root / 'objects.git'
        self.remote = 'https://github.com/' + self.grant['repository'] + '.git'
        self.prefix = 'repos/' + self.grant['repository']
        self.counters = (queue.state['admissions'], queue.state['launches'], item.get('attempts', 0))

    def check(self, action=None):
        self.admitted = check_binding(self.queue)
        self.queue.validate_preparation()
        require(self.rt.read_json(self.queue.path) == self.queue.state, 'publication queue state changed')
        require(all(self.record.get(key) == value for key, value in self.identity.items()),
                'publication identity changed')
        if action is not None:
            live = self.runtime.load(self.item['run'])
            require(action in self.grant['allowed_actions'], 'publication action outside grant')
            if (self.queue.base / 'PAUSE').exists():
                raise PublicationPaused('publication paused')
            require(time.time() < min(self.identity['deadline'], self.identity['runtime_limits']['deadline']),
                    'original publication deadline exhausted')
            require({key: live[key] for key in ('deadline', 'max_attempts')} == self.identity['runtime_limits']
                    and live['status'] == 'awaiting_review'
                    and live['attempts'] == self.item.get('attempts', 0)
                    and live['attempts'] < live['max_attempts'], 'publication runtime authority changed')
            require(self.counters == (self.queue.state['admissions'], self.queue.state['launches'], self.item.get('attempts', 0))
                    and self.queue.state['launches'] <= self.grant['max_launches'], 'publication counters changed')
            candidate = self.record.get('candidate', {})
            proofs = self.record.get('candidates', [])
            require(proofs and proofs[-1]['verification'].get('ok') is True
                    and proofs[-1]['verification'].get('revision') == candidate.get('revision')
                    and proofs[-1]['review'] == self.item.get('native_review')
                    and self.rt.identity(self.worktree)['revision'] == candidate.get('revision')
                    and self.rt.fingerprint(self.worktree) == candidate.get('fingerprint')
                    and live.get('receipt', {}).get('revision') == candidate.get('revision')
                    and not self.rt.git(self.worktree, 'status', '--porcelain', '--untracked-files=all'),
                    'publication candidate evidence changed')
            if action == 'source_done':
                self.source_verified()
            if action == 'publish':
                hosted = self.record.get('hosted_candidate', {})
                require(hosted.get('revision') == candidate['revision']
                        and hosted.get('status') in ('passed', 'not_declared', 'billing_unavailable'),
                        'publication lacks exact candidate hosted gate')

    def read(self, endpoint):
        self.check()
        return github_read(self.admitted, endpoint)

    def api(self, endpoint):
        return self.read(self.prefix + '/' + endpoint)

    def rows(self, endpoint, key=None):
        result = []
        for page in range(1, 51):
            value = self.api(endpoint + ('&' if '?' in endpoint else '?') + f'per_page=100&page={page}')
            rows = value.get(key) if key and isinstance(value, dict) else value
            require(isinstance(rows, list) and len(rows) <= 100, 'malformed GitHub pagination')
            result.extend(rows)
            if len(rows) < 100:
                return result
        raise ValueError('GitHub pagination incomplete')

    def git(self, *args, input=None, check=True):
        permissions = {name: 'read' for name in [*self.admitted['host']['read_roots'], *self.admitted['host']['read_files']]}
        permissions.update({str(self.root): 'read', str(self.store): 'write'})
        result = restricted_git(self.admitted, self.root, permissions,
                                '--git-dir=' + str(self.store), *args, input=input)
        require(not check or result.returncode == 0, 'publisher Git failed: ' + result.stderr.decode(errors='replace')[:300])
        return result

    def text(self, *args):
        return self.git(*args).stdout.decode().strip()

    def remote_git(self, *args, action=None):
        require(self.store.is_dir() and not self.store.is_symlink()
                and _runtime['digest'](checked_path(str(self.store / 'config'), file=True).read_bytes()) == self.record.get('store_config')
                and not (self.store / 'objects/info/alternates').exists(), 'publisher Git configuration changed')
        env = {**host_environment(self.admitted), **tool_environment(self.admitted)}
        self.check(action)
        return credential_git(self.admitted, self.root, env, '--git-dir=' + str(self.store), *args)

    def open_store(self):
        if not self.store.exists():
            self.git('init', '--bare', '--template=', str(self.store))
            self.record['store_config'] = _runtime['digest']((self.store / 'config').read_bytes())
            self.queue.save()
        require(_runtime['digest'](checked_path(str(self.store / 'config'), file=True).read_bytes()) == self.record.get('store_config'),
                'unacknowledged publisher store initialization')

    def fetch_base(self):
        result = self.remote_git('fetch', '--no-tags', '--no-write-fetch-head', self.remote,
                                 '+refs/heads/' + self.grant['base_branch'] + ':refs/heads/observed-base')
        require(result.returncode == 0, 'publisher base fetch failed')
        return self.text('rev-parse', 'refs/heads/observed-base')

    def push_ref(self, branch, before, after):
        require(branch in (self.grant['base_branch'], self.record['head_branch']), 'ungranted publication branch')
        self.git('check-ref-format', 'refs/heads/' + branch)
        require(hex_value(after, (40, 64)) and (before == '' or hex_value(before, (40, 64))), 'invalid publication ref identity')
        if before:
            require(self.git('merge-base', '--is-ancestor', before, after, check=False).returncode == 0,
                    'publication would rewrite history')
        return self.remote_git('push', self.remote,
                               '--force-with-lease=refs/heads/' + branch + ':' + before,
                               after + ':refs/heads/' + branch,
                               action='publish' if branch == self.grant['base_branch'] else 'push')

    def write(self, operation, identity, action, command):
        previous = [entry for entry in self.record['intents'] if entry['operation'] == operation and entry['identity'] == identity]
        require(len(previous) <= 1, 'duplicate publication intent')
        if previous:
            return previous[0]  # Readback owns every restart, never a second dispatch.
        self.check(action)
        entry = {'sequence': len(self.record['intents']) + 1, 'operation': operation,
                 'identity': identity, 'status': 'dispatching', 'started': time.time()}
        self.record['intents'].append(entry)
        self.queue.save()
        self.check(action)
        try:
            result = command()
            entry.update(exit=result.returncode, status='responded',
                         stderr=result.stderr.decode(errors='replace')[:1000])
            if operation == 'source_done':
                status = re.match(rb'HTTP/[0-9.]+ ([0-9]{3})\b', result.stdout)
                entry['http_status'] = int(status[1]) if status else None
        except (OSError, subprocess.SubprocessError) as error:
            entry.update(status='uncertain', reason=str(error)[:500])
        self.queue.save()
        return entry

    def import_candidate(self, candidate):
        permissions = {name: 'read' for name in [*self.admitted['host']['read_roots'], *self.admitted['host']['read_files']]}
        permissions.update({self.grant['workspace']: 'read', str(self.root): 'read', str(self.store): 'write'})
        result = restricted_git(self.admitted, self.root, permissions, '--git-dir=' + str(self.store),
                                'fetch', '--no-tags', '--no-write-fetch-head', self.grant['workspace'], candidate)
        require(result.returncode == 0, 'candidate object import failed')

    def verify(self, revision, source):
        number = self.record.get('verifications', 0) + 1
        self.record['verifications'] = number
        self.queue.save()  # Reserve a fresh destination; never adopt interrupted evidence.
        return verify_snapshot(self.admitted, source, revision, self.root / f'verification-{number}')

    def review(self):
        expected = self.item.get('native_review', {})
        revision = self.rt.identity(self.worktree)['revision']
        require(expected.get('revision') == revision and expected.get('fingerprint') == self.rt.fingerprint(self.worktree)
                and isinstance(expected.get('verdict'), str)
                and re.match(r'(?i)^\s*(?:\*\*)?ship\b(?!-)', expected['verdict'])
                and revision in expected['verdict'], 'publication lacks exact native review')
        require(self.item.get('quiescence') == {'process': 'exited', 'group': 'gone', 'known_descendants': []},
                'native worker closure unavailable')
        live = self.runtime.load(self.item['run'])
        require(live['status'] == 'awaiting_review' and live.get('receipt', {}).get('ok') is True
                and live['receipt'].get('checks') and all(c.get('group_gone') is True for c in live['receipt']['checks'])
                and not self.rt.git(self.worktree, 'status', '--porcelain', '--untracked-files=all'),
                'publication candidate is not clean and ready')
        spec = importlib.util.spec_from_file_location('publication_native', Path(__file__).with_name('launch-native.py'))
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        launch = launch_options(self.queue, self.item, {})
        launch['env']['LAUNCH_RUN_ID'] = ''
        number = self.record.get('review_readbacks', 0) + 1
        self.record['review_readbacks'] = number
        self.queue.save()
        reader = native.Codex(self.worktree, launch['env'], None, self.check, self.root / f'review-{number}.log',
            command=launch['command'], permission_profile=launch['permission_profile'], timeout=60,
            reviewer_synchronous=self.reviewer_synchronous)
        try:
            reader.connect()
            reader.read_review(expected)
        finally:
            reader.close()
        return expected

    def rules(self):
        branch = quote(self.grant['base_branch'], safe='')
        state = self.api('branches/' + branch)
        require(isinstance(state, dict) and state.get('name') == self.grant['base_branch']
                and state.get('protected') is False and branch_rules(self.read, self.prefix, branch) == [],
                'protected or unknown base publication rules are unsupported')
        revision = state.get('commit', {}).get('sha')
        require(hex_value(revision, (40, 64)), 'GitHub base identity missing')
        return revision

    def billing(self, check):
        if not self.grant['publication']['billing_fallback'] or check.get('app', {}).get('slug') != 'github-actions':
            return False
        match = re.fullmatch(r'https://github\.com/' + re.escape(self.grant['repository'])
                             + r'/actions/runs/([0-9]+)/job/([0-9]+)(?:\?[^#]*)?', check.get('details_url', ''))
        if not match:
            return False
        run = self.api('actions/runs/' + match[1])
        jobs = self.rows('actions/runs/' + match[1] + '/jobs', 'jobs')
        if (run.get('head_sha') != check.get('head_sha') or run.get('status') != 'completed'
                or run.get('conclusion') != 'failure' or not jobs
                or any(job.get('steps') != [] for job in jobs)):
            return False
        matches = [job for job in jobs if job.get('id') == int(match[2])
                   and job.get('check_run_url') == 'https://api.github.com/' + self.prefix + '/check-runs/' + str(check['id'])]
        if len(matches) != 1 or matches[0].get('conclusion') != 'failure':
            return False
        annotations = self.rows('check-runs/' + str(check['id']) + '/annotations')
        explanation = 'The job was not started because recent account payments have failed or your spending limit needs to be increased.'
        # GitHub adds runner-image notices beside the billing failure; only failures must match.
        require(all(isinstance(a, dict) for a in annotations), 'malformed hosted check annotation')
        failures = [a for a in annotations if a.get('annotation_level') not in ('notice', 'warning')]
        return bool(failures) and all(isinstance(a.get('message'), str) and explanation in a['message'] for a in failures)

    def hosted(self, revision, required=None):
        observed = required is not None
        required = self.grant['publication']['required_checks'] if required is None else required
        if not required and not observed:
            require(not self.text('ls-tree', '-r', '--name-only', revision, '--', '.github/workflows/'),
                    'workflow exists outside empty publication check contract')
        runs = self.rows('commits/' + revision + '/check-runs?filter=latest', 'check_runs')
        require(all(isinstance(run, dict) and run.get('head_sha') == revision
                    and type(run.get('id')) is int for run in runs), 'hosted check revision mismatch')
        statuses = self.rows('commits/' + revision + '/statuses')
        latest = {}
        for status in statuses:
            require(isinstance(status, dict) and isinstance(status.get('context'), str)
                    and type(status.get('id')) is int, 'malformed hosted commit status')
            name = status['context']
            if name not in latest or status['id'] > latest[name]['id']:
                latest[name] = status
        # ponytail: nothing declared, observed or able to run (no workflows) on this revision; an
        # external status app posting after this read is not waited for. Declare it to gate it.
        if (not required and not runs and not latest
                and not self.text('ls-tree', '-r', '--name-only', revision, '--', '.github/workflows/')):
            return {'revision': revision, 'status': 'not_declared', 'runs': [], 'statuses': []}
        result = check_conclusions(required, runs, list(latest.values()), self.billing, observed and not required)
        return {'revision': revision, 'status': result, 'runs': runs, 'statuses': list(latest.values())}

    def poll(self, operation):
        while True:
            try:
                return operation()
            except PublicationPending:
                remaining = min(self.identity['deadline'], self.identity['runtime_limits']['deadline']) - time.time()
                if remaining <= 0 or (self.queue.base / 'PAUSE').exists():
                    raise
                time.sleep(min(5, remaining))

    def pull_request(self, candidate):
        owner = self.grant['repository'].split('/')[0]
        endpoint = ('pulls?state=all&head=' + quote(owner + ':' + self.record['head_branch'], safe='')
                    + '&base=' + quote(self.grant['base_branch'], safe=''))
        marker = '<!-- launch-control-delivery:' + self.queue.hash + ':' + self.item['run'] + ' -->'
        # The worker prompt (item scope) holds local paths and stays out of the PR.
        checks = ''.join('\n- `' + (c['command'] if c['cwd'] == '.' else 'cd ' + c['cwd'] + ' && ' + c['command']) + '`'
                         for c in self.grant['verification']['checks'])
        body = (item_cell(self.item['source']['text']) + '\n\nChecks passed:' + checks
                + '\n\nReview: Ship (independent Codex review of the exact commit)'
                + '\n\nDelivered by Launch Control · Mission ' + mission_name(self.grant['source']['heading'])
                + '\n\n' + marker)
        request = {'title': pr_title(self.item['id'], self.item['source']['text']),
                   'head': self.record['head_branch'], 'base': self.grant['base_branch'],
                   'body': body, 'draft': False}
        path = self.root / 'pr-request.json'
        if not path.exists():
            _runtime['atomic'](path, request)
        require(_runtime['read_json'](path) == request, 'pull request request changed')
        digest = canonical_digest(request)
        require(self.record.get('pr_request', digest) == digest, 'pull request request identity changed')
        self.record['pr_request'] = digest
        self.queue.save()
        found = [row for row in self.rows(endpoint) if not foreign_stale_pr(row, marker)]
        require(len(found) <= 1, 'ambiguous task pull request')
        if not found:
            require('pr' not in self.record, 'recorded pull request disappeared')
            def create():
                self.check('pull_request')
                return gh_api(self.admitted, self.prefix + '/pulls', '--method', 'POST', '--input', str(path), cwd=self.root)
            self.write('pull_request', request, 'pull_request', create)
            found = [row for row in self.rows(endpoint) if not foreign_stale_pr(row, marker)]
            if not found:
                raise PublicationPending('pull request creation awaits exact readback; not resent')
            require(len(found) == 1, 'ambiguous created pull request')
        listed = found[0]
        require(isinstance(listed, dict) and type(listed.get('number')) is int, 'pull request number missing')
        pr = self.api('pulls/' + str(listed['number']))
        require(isinstance(pr, dict) and isinstance(pr.get('head'), dict) and isinstance(pr.get('base'), dict)
                and isinstance(pr['head'].get('repo'), dict) and isinstance(pr['base'].get('repo'), dict),
                'pull request repository identity missing')
        require(pr.get('number') == listed['number'] and pr.get('title') == request['title'] and pr.get('body') == request['body']
                and pr.get('head', {}).get('sha') == candidate
                and pr['head'].get('ref') == self.record['head_branch']
                and pr['head'].get('repo', {}).get('full_name') == self.grant['repository']
                and pr.get('base', {}).get('ref') == self.grant['base_branch']
                and pr['base'].get('repo', {}).get('full_name') == self.grant['repository'],
                'pull request identity or candidate changed')
        identity = {key: pr[key] for key in ('number', 'node_id', 'html_url')}
        require(all(listed.get(key) == value for key, value in identity.items())
                and self.record.get('pr', identity) == identity, 'pull request identity changed')
        self.record['pr'] = identity
        self.queue.save()
        return pr

    def pr_gate(self, candidate, base):
        pr = self.pull_request(candidate)
        require(pr.get('state') == 'open' and pr.get('draft') is False and pr.get('merged') is False,
                'pull request is not open for granted publication')
        if pr.get('mergeable') is None:
            raise PublicationPending('pull request mergeability pending')
        require(pr['mergeable'] is True, 'pull request is not mergeable')
        decisions = {}
        for review in self.rows('pulls/' + str(pr['number']) + '/reviews'):
            require(isinstance(review, dict) and isinstance(review.get('user'), dict)
                    and type(review.get('id')) is int and type(review['user'].get('id')) is int,
                    'malformed pull request review')
            require(review.get('state') in ('APPROVED', 'CHANGES_REQUESTED', 'COMMENTED', 'DISMISSED'),
                    'unknown or pending pull request review')
            user = review['user']['id']
            if review['state'] != 'COMMENTED' and (user not in decisions or review['id'] > decisions[user]['id']):
                decisions[user] = review
        require(not any(review['state'] == 'CHANGES_REQUESTED' for review in decisions.values()),
                'pull request changes requested')
        result = gh_api(self.admitted, self.prefix + '/pulls/' + str(pr['number']), '-H', 'Accept: application/vnd.github.diff',
                        cwd=self.root)
        require(result.returncode == 0 and result.stdout, 'stored pull request diff unavailable')
        local = self.git('diff', '--no-ext-diff', '--no-textconv', '--abbrev=7', '--src-prefix=a/', '--dst-prefix=b/',
                         base + '...' + candidate).stdout
        def normalize(value):
            # GitHub abbreviates index hashes by repository size; compare the 7-character prefixes.
            value = re.sub(rb'(?m)^(index [0-9a-f]{7})[0-9a-f]*\.\.([0-9a-f]{7})[0-9a-f]*', rb'\1..\2', value)
            return re.sub(rb'(?m)^(@@[^\n]*?@@)[^\n]*$', rb'\1', value)
        require(local and normalize(local) == normalize(result.stdout), 'stored pull request diff differs from candidate')
        path = self.root / ('pr-' + candidate + '.diff')
        if path.exists():
            require(path.read_bytes() == result.stdout, 'stored pull request diff changed')
        else:
            path.write_bytes(result.stdout)
        return {'number': pr['number'], 'head': candidate, 'base': base, 'diff': _runtime['digest'](result.stdout)}

    def branch_head(self):
        branch = self.record['head_branch']
        matches = self.rows('git/matching-refs/heads/' + quote(branch, safe=''))
        exact = [row for row in matches if isinstance(row, dict) and row.get('ref') == 'refs/heads/' + branch]
        require(len(exact) <= 1, 'ambiguous remote task ref')
        if not exact:
            return ''
        value = exact[0].get('object', {})
        require(value.get('type') == 'commit' and hex_value(value.get('sha'), (40, 64)), 'invalid remote task ref')
        return value['sha']

    def acknowledge_merge(self):
        merge = self.record['merge']
        observed = self.fetch_base()
        pr = self.api('pulls/' + str(self.record['pr']['number']))
        contains = self.git('merge-base', '--is-ancestor', merge['commit'], observed, check=False).returncode == 0
        if contains and pr.get('merged') is True:
            require(pr.get('merge_commit_sha') == merge['commit'] and pr.get('head', {}).get('sha') == merge['candidate']
                    and pr.get('base', {}).get('ref') == self.grant['base_branch']
                    and self.text('rev-parse', merge['commit'] + '^{tree}') == merge['tree'], 'merged identity mismatch')
            self.record.update(stage='merged_source_pending', merged_base=observed)
            self.item['status'] = 'merged_source_pending'
            self.queue.save()
            return True
        require(pr.get('merged') is not True, 'different merge observed; retained for reconciliation')
        intent = next((entry for entry in self.record['intents']
                       if entry['operation'] == 'base' and entry['identity'] == merge), None)
        if not contains and intent and intent.get('exit') not in (None, 0) and 'stale info' in intent.get('stderr', ''):
            require(observed != merge['base'], 'stale lease without observed base advance')
            return observed
        # A receive-side refusal is final when the base never moved: block now, never resend.
        refused = intent and '[remote rejected]' in intent.get('stderr', '')
        require(not refused or observed != merge['base'],
                'remote refused the base push with the base unchanged; retained, never resent')
        raise PublicationPending('publication awaits exact merge readback; not resent')

    def run(self):
        self.check()
        self.open_store()
        if self.record.get('merge') and any(entry['operation'] == 'base' and entry['identity'] == self.record['merge']
                                            for entry in self.record['intents']):
            merged = self.poll(self.acknowledge_merge)
            if merged is not True:
                return merged
        if self.record['stage'] != 'merged_source_pending':
            review = self.review()
            candidate = review['revision']
            proof = self.verify(candidate, Path(self.grant['workspace']))
            require(proof['fingerprint'] == review['fingerprint'], 'verified snapshot differs from reviewed files')
            self.record['candidates'].append({'review': copy.deepcopy(review), 'verification': proof})
            self.record['candidate'] = {'revision': candidate, 'tree': proof['tree'], 'fingerprint': review['fingerprint']}
            self.queue.save()
            self.import_candidate(candidate)
            base = self.fetch_base()
            changed = self.git('diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', base + '...' + candidate).stdout
            refused = refused_candidate_paths([p for p in changed.decode('utf-8', 'surrogateescape').split('\0') if p], self.grant)
            require(not refused, 'candidate changes refused paths: ' + ', '.join(refused[:5]))
            self.rules()
            if not self.grant['publication']['required_checks']:
                require(not self.text('ls-tree', '-r', '--name-only', base, '--', '.github/workflows/'),
                        'base workflow is outside empty publication check contract')
            if self.git('merge-base', '--is-ancestor', base, candidate, check=False).returncode:
                return base
            before = self.record.get('head', '')
            current = self.branch_head()
            identity = {'branch': self.record['head_branch'], 'before': before, 'after': candidate}
            if current == candidate:
                require(before == candidate or any(entry['operation'] == 'head' and entry['identity'] == identity
                                                   for entry in self.record['intents']), 'unowned remote task branch')
            if current != candidate:
                require(current == before, 'remote task branch changed')
                self.write('head', identity, 'push', lambda: self.push_ref(self.record['head_branch'], before, candidate))
                current = self.branch_head()
            require(current == candidate, 'task push awaits exact ref readback; not resent')
            self.record['head'] = candidate
            self.queue.save()
            self.poll(lambda: self.pr_gate(candidate, base))
            hosted = self.poll(lambda: self.hosted(candidate))
            self.record['hosted_candidate'] = hosted
            self.queue.save()
            observed = self.fetch_base()
            if observed != base:
                return observed
            require(self.rules() == base, 'base changed during publication preflight')
            self.poll(lambda: self.pr_gate(candidate, base))
            self.poll(lambda: self.hosted(candidate))
            merge = self.record.get('merge')
            if merge is None:
                name = self.rt.git(self.worktree, 'config', 'user.name')
                email = self.rt.git(self.worktree, 'config', 'user.email')
                commit = self.git('-c', 'user.name=' + name, '-c', 'user.email=' + email,
                                  'commit-tree', proof['tree'], '-p', base, '-p', candidate,
                                  input=('Merge pull request #' + str(self.record['pr']['number']) + '\n').encode()).stdout.decode().strip()
                merge = {'commit': commit, 'tree': proof['tree'], 'base': base, 'candidate': candidate,
                         'branch': self.grant['base_branch']}
                self.record['merge'] = merge
                self.queue.save()
            require(merge['base'] == base and merge['candidate'] == candidate and merge['tree'] == proof['tree']
                    and self.text('rev-parse', merge['commit'] + '^{tree}') == proof['tree']
                    and self.text('rev-list', '--parents', '-n', '1', merge['commit']).split()[1:] == [base, candidate],
                    'computed merge identity changed')
            self.write('base', merge, 'publish', lambda: self.push_ref(self.grant['base_branch'], base, merge['commit']))
            merged = self.poll(self.acknowledge_merge)
            if merged is not True:
                return merged
        merge = self.record['merge']
        if not self.record.get('verified'):
            self.record['post_merge'] = self.verify(merge['commit'], self.store)
        self.record['verified'] = False
        self.queue.save()
        self.record['hosted_merge'] = self.poll(lambda: self.hosted(merge['commit'], self.grant['publication'].get('post_merge_checks')))
        self.record.update(verified=True, stage='merged_source_pending')
        self.item.update(status='merged_source_pending', reason='exact merge verified; source completion requires its explicit granted transition')
        self.queue.save()
        return None

    def source_verified(self):
        merge = self.record.get('merge', {})
        proof, hosted = self.record.get('post_merge', {}), self.record.get('hosted_merge', {})
        require(self.record.get('verified') is True and hex_value(merge.get('commit'), (40, 64))
                and proof.get('ok') is True and proof.get('revision') == merge['commit']
                and hosted.get('revision') == merge['commit']
                and hosted.get('status') in ('passed', 'not_declared', 'billing_unavailable'),
                'source completion needs verified post-merge evidence')

    def complete_source(self, parser, patcher):
        self.check()
        self.source_verified()
        source = self.grant['source']
        authority = self.grant['source_writeback']
        original = checked_path(str(Path(self.grant['workspace']) / source['path']), file=True).read_bytes()
        require(git_blob(original) == source['blob'], 'frozen source bytes changed')
        baseline = parser(original.decode('utf-8'), source)
        require(baseline.get(self.item['id']) == self.item['source'], 'frozen selected task changed')
        expected_records = parser(patcher(original, source, self.item['id']).decode('utf-8'), source)
        endpoint = 'contents/' + quote(authority['path'], safe='/')
        while True:
            intents = [entry for entry in self.record['intents'] if entry['operation'] == 'source_done']
            require(len(intents) <= 2, 'source write intent cap exceeded')
            for number, entry in enumerate(intents, 1):
                identity = entry['identity']
                request = _runtime['read_json'](self.root / f'source-request-{number}.json')
                require(identity.get('source') == authority and identity.get('task') == self.item['id']
                        and identity.get('merge') == self.record['merge']['commit']
                        and canonical_digest(request) == identity.get('request')
                        and request.get('branch') == authority['branch'] and request.get('sha') == identity.get('before'),
                        'source request identity changed')
                replacement = base64.b64decode(request['content'], validate=True)
                require(git_blob(replacement) == identity.get('after')
                        and _runtime['digest'](replacement) == identity.get('content')
                        and parser(replacement.decode('utf-8'), source) == expected_records,
                        'source replacement identity changed')
            remote = self.api(endpoint + '?ref=' + quote(authority['branch'], safe=''))
            require(isinstance(remote, dict) and remote.get('type') == 'file'
                    and remote.get('path') == authority['path'] and remote.get('encoding') == 'base64',
                    'source Contents identity unavailable')
            raw = base64.b64decode(''.join(remote.get('content', '').split()), validate=True)
            require(git_blob(raw) == remote.get('sha'), 'source blob does not match content')
            records = parser(raw.decode('utf-8'), source)
            matched = [entry for entry in intents if entry['identity']['after'] == remote['sha']
                       and entry['identity']['content'] == _runtime['digest'](raw)]
            if matched:
                require(len(matched) == 1 and records == expected_records, 'completed source identity changed')
                receipt = {'sequence': matched[0]['sequence'], 'blob': remote['sha'],
                           'content': _runtime['digest'](raw), 'record': records[self.item['id']]['digest'],
                           'merge': self.record['merge']['commit']}
                require(self.record.get('source_receipt', receipt) == receipt, 'source receipt changed')
                eligible = sorted((ident for ident, record in records.items()
                    if record['status'] == 'todo' and not record.get('blocked')
                    and all(records.get(dep, {}).get('status') == 'done'
                            and not records[dep].get('blocked') for dep in record['depends'])),
                    key=lambda ident: (records[ident]['priority'], records[ident]['subpriority'], ident))
                remaining = sorted(ident for ident, record in records.items() if record['status'] != 'done' or record.get('blocked'))
                self.record.update(source_receipt=receipt, stage='delivered', rediscovery={
                    'source_blob': remote['sha'], 'eligible': eligible, 'remaining': remaining,
                    'selection_complete': bool(records) and not remaining,
                    'outcome': 'next_work_requires_grant' if eligible else 'no_eligible' if remaining else 'source_selection_complete'})
                self.item.update(status='delivered', reason='selected task merged, verified and source Done; rediscovery is report-only')
                self.queue.save()
                return
            # ponytail: exact blob acknowledgment; add historical commit proof if later edits need reconciliation.
            require('source_receipt' not in self.record, 'completed source changed; retain prior receipt')
            if intents:
                last = intents[-1]
                if last.get('http_status') != 409 or last.get('status') != 'responded' or last.get('exit') in (None, 0):
                    raise PublicationPending('source write awaits exact readback; not resent')
                require(len(intents) < 2, 'source write intent budget exhausted')
                require(remote['sha'] != last['identity']['before'], 'source conflict lacks observed blob advance')
            require(records == baseline, 'selected source records changed')
            replacement = patcher(raw, source, self.item['id'])
            require(parser(replacement.decode('utf-8'), source) == expected_records, 'source patch identity changed')
            request = {'branch': authority['branch'], 'sha': remote['sha'],
                       'content': base64.b64encode(replacement).decode(),
                       'message': ('docs(backlog): mark ' + self.item['id'] + ' done (Mission '
                                   + mission_name(source['heading']) + ')\n\nVerified merge ' + self.record['merge']['commit'])}
            path = self.root / f'source-request-{len(intents) + 1}.json'
            if not path.exists():
                _runtime['atomic'](path, request)
            require(_runtime['read_json'](path) == request, 'retained source request changed')
            identity = {'source': authority, 'task': self.item['id'], 'merge': self.record['merge']['commit'],
                        'before': remote['sha'], 'after': git_blob(replacement),
                        'content': _runtime['digest'](replacement), 'request': canonical_digest(request)}
            def put():
                require(_runtime['read_json'](path) == request, 'source request changed before dispatch')
                self.check('source_done')
                return gh_api(self.admitted, self.prefix + '/' + endpoint, '--method', 'PUT', '--include', '--input', str(path),
                              cwd=self.root, timeout=60)
            self.write('source_done', identity, 'source_done', put)

    def reserve_repair(self, base):
        self.check('implement')
        candidate = self.record['candidate']
        require(hex_value(base, (40, 64))
                and self.git('merge-base', '--is-ancestor', candidate['revision'], base, check=False).returncode != 0,
                'candidate already incorporated elsewhere; delivery identity needs reconciliation')
        live = self.runtime.load(self.item['run'])
        attempts = live['attempts'] + 1
        require(attempts < live['max_attempts'] and self.queue.state['launches'] < self.grant['max_launches'],
                'original delivery repair or launch budget exhausted')
        repair = {'candidate': candidate['revision'], 'fingerprint': candidate['fingerprint'], 'base': base,
                  'attempts': attempts, 'previous_attempts': live['attempts']}
        repair['id'] = canonical_digest(repair)
        self.record.setdefault('repairs', []).append(copy.deepcopy(repair))
        if self.record.get('merge'):
            self.record.setdefault('previous_merges', []).append(self.record.pop('merge'))
        self.record.update(stage='repair', repair=repair)
        self.item.update(status='handoff', handoff_stage='delivery_repair_reserved', attempts=attempts)
        self.queue.save()

    def resume_repair(self):
        self.check()
        repair = self.record['repair']
        self.runtime.delivery_repair(self.runtime.load(self.item['run']), repair['id'], repair['attempts'])
        if self.item['handoff_stage'] == 'delivery_repair_merging':
            require(type(repair.get('pgid')) is int, 'uncertain repair launch retained')
            if not _runtime['group_closed'](repair['pgid']):
                raise ValueError('repair process group still present; retained')
        head = self.rt.identity(self.worktree)['revision']
        if head == repair['candidate']:
            require(self.item['handoff_stage'] == 'delivery_repair_reserved'
                    and self.rt.fingerprint(self.worktree) == repair['fingerprint'], 'uncertain or changed repair candidate')
            permissions = filesystem(self.admitted)
            permissions[str(self.store)] = 'read'
            result = restricted_git(self.admitted, self.worktree, permissions, 'fetch', '--no-tags',
                                    '--no-write-fetch-head', str(self.store), repair['base'])
            require(result.returncode == 0, 'repair base import failed')
            self.item['handoff_stage'] = 'delivery_repair_merging'
            self.queue.save()
            def started(pid):
                repair['pgid'] = pid
                self.queue.save()
            command = sandbox_command(self.admitted, self.worktree, git_filesystem(self.worktree, filesystem(self.admitted)),
                                      [self.admitted['host']['git'], '-C', str(self.worktree),
                                       'merge', '--no-ff', '--no-edit', repair['base']], tool_environment(self.admitted))
            result = run_owned(command, self.worktree, host_environment(self.admitted), on_start=started)
            require(result.returncode == 0 and not any(word in result.stderr.lower() for word in
                    (b'warning:', b'fatal:', b'error:', b'operation not permitted')), 'repair merge failed; worktree retained')
            head = self.rt.identity(self.worktree)['revision']
        require(self.rt.git(self.worktree, 'rev-list', '--parents', '-n', '1', head).split()[1:] == [repair['candidate'], repair['base']]
                and not self.rt.git(self.worktree, 'status', '--porcelain', '--untracked-files=all'), 'repair merge identity or worktree changed')
        self.item['handoff_stage'] = 'delivery_repair_merged'
        repair['revision'] = head
        self.queue.save()
        live = self.runtime.load(self.item['run'])
        if live['status'] == 'handoff' and live.get('delivery_repair') == repair['id']:
            sealed = live
            self.runtime.handoff(live, live['handoff']['hash'])
        else:
            notes = json.loads(live['notes'])
            notes.update(next_phase='independent review and verification',
                         next_action='Review the entire repaired candidate ' + head + ' against new base ' + repair['base']
                                     + '. For this fresh post-repair reviewer, first confirm git rev-parse HEAD^2 equals that base, '
                                     + 'then inspect git diff HEAD^2...HEAD plus staged, unstaged and untracked states. '
                                     + 'origin/main remains the immutable admission baseline; the second parent identifies '
                                     + 'concurrent base changes, which are not task edits. Include this comparison in the '
                                     + 'initial reviewer request. Obtain a fresh native review and rerun canonical readiness. Do not publish.',
                         evidence=notes['evidence'] + '\nPrevious reviewed candidate: ' + repair['candidate'])
            sealed = self.runtime.seal(live, notes)
        self.item.pop('native_review', None)
        self.record.pop('hosted_candidate', None)
        self.item.update(checkpoint_hash=sealed['handoff']['hash'], handoff_stage='checkpointed')
        self.queue.save()


def generator_argv(admitted, policy, task, worktree):
    validate_target(admitted, policy)
    argv = policy.get('generator', {}).get('argv')
    expected = [admitted['host']['python'], '-I', str(Path(__file__).with_name('codex-parity.py'))]
    require(isinstance(argv, list) and argv[:3] == expected and all(isinstance(a, str) for a in argv),
            'delivery requires the reviewed isolated canonical generator')
    options = ('--autonomy-delivery-binding', '--autonomy-delivery-binding-digest')
    require(not any(arg.split('=', 1)[0] in options for arg in argv), 'caller supplied delivery binding arguments')
    for name in ('launch-runtime.py', 'launch-delivery.py', 'codex-parity.py'):
        path = Path(__file__).with_name(name)
        require(admitted['host']['files'].get(str(path)) == _runtime['digest'](path.read_bytes()),
                'unreviewed generator controller input')
    # The known converter owns directory discovery; pin every rendered input before it runs.
    for flag, directory in (('--source', True), ('--autonomy-config', False), ('--autonomy-commands', False)):
        require(argv.count(flag) == 1 and argv.index(flag) + 1 < len(argv), 'missing explicit generator input')
        path = checked_path(argv[argv.index(flag) + 1], file=not directory)
        paths = [p for p in path.rglob('*') if p.is_file() or p.is_symlink()] if directory else [path]
        require(paths, 'empty generator input')
        for entry in paths:
            checked_path(str(entry), file=True)
            require(admitted['host']['files'].get(str(entry)) == _runtime['digest'](entry.read_bytes()),
                    'unreviewed generator input: ' + str(entry))
    config = checked_path(argv[argv.index('--autonomy-config') + 1], file=True)
    require(json.loads(config.read_text()) == admitted['grant']['verification'], 'generator verification differs from grant')
    values = {'id': task, 'worktree': str(worktree)}
    return [arg.format_map(values) for arg in argv] + [options[0], admitted['binding']['grant'],
                                                     options[1], admitted['binding']['digest']]


def generate(admitted, policy, task, worktree):
    argv = generator_argv(admitted, policy, task, worktree)
    permissions = filesystem(admitted, preparing=True)
    # Native sandbox protects .codex even beneath a writable clone.
    permissions[str(Path(worktree) / '.codex')] = 'write'
    result = run_owned(sandbox_command(admitted, worktree, permissions,
                                      argv, tool_environment(admitted)), worktree, host_environment(admitted))
    require(result.returncode == 0, 'restricted generator failed: ' + result.stderr.decode(errors='replace')[:500])
    config = Path(worktree) / '.codex/launch/verify.json'
    require(json.loads(config.read_text()) == admitted['grant']['verification'], 'generated verification differs from grant')


def prepare_clone(policy, binding, output, selected):
    admitted = load_binding(binding)
    validate_target(admitted, policy)
    workspace = Path(admitted['grant']['workspace'])
    require(output.parent == Path(binding['grant']).parent, 'delivery manifest must share the grant directory')
    require(not workspace.exists(), 'delivery workspace already exists; retain and reconcile')
    # Validate all generator inputs before reserving anything or reaching authenticated commands.
    generator_argv(admitted, policy, selected['id'], workspace)
    grant = admitted['grant']
    source = checked_path(str(Path(policy['project']) / grant['source']['path']), file=True).read_bytes()
    repository = 'repos/' + grant['repository']
    remote = github_read(admitted, repository + '/commits/' + quote(grant['base_branch'], safe=''))
    require(remote.get('sha') == grant['base_revision'], 'GitHub base changed before preparation')
    if 'publication' in grant:
        branch = quote(grant['base_branch'], safe='')
        state = github_read(admitted, repository + '/branches/' + branch)
        rules = branch_rules(lambda endpoint: github_read(admitted, endpoint), repository, branch)
        require(state.get('protected') is False and state.get('commit', {}).get('sha') == grant['base_revision']
                and rules == [], 'unsupported publication branch rules or changed base')
        if not grant['publication']['required_checks']:
            tree = remote.get('commit', {}).get('tree', {}).get('sha')
            require(hex_value(tree, (40, 64)), 'publication base tree unavailable')
            listing = github_read(admitted, repository + '/git/trees/' + tree + '?recursive=1')
            require(listing.get('truncated') is False and isinstance(listing.get('tree'), list)
                    and all(isinstance(entry, dict) and isinstance(entry.get('path'), str)
                            and entry['path'] != '.github/workflows' and not entry['path'].startswith('.github/workflows/')
                            for entry in listing['tree']), 'base workflows require explicit publication checks')
    blob = github_read(admitted, repository + '/contents/' + quote(grant['source']['path'], safe='/')
                       + '?ref=' + grant['base_revision'])
    require(blob.get('sha') == grant['source']['blob'] and blob.get('encoding') == 'base64'
            and base64.b64decode(blob.get('content', '')) == source, 'GitHub source differs from approved local source')
    account = github_read(admitted, 'user')
    require(isinstance(account.get('id'), int) and isinstance(account.get('login'), str)
            and re.fullmatch('[A-Za-z0-9-]+', account['login']), 'GitHub commit identity unavailable')
    marker = preparation_path(admitted)
    record = {'grant_digest': binding['digest'], 'workspace': str(workspace), 'status': 'cloning',
              'id': selected['id'], 'source_digest': selected['digest']}
    with marker.open('x') as stream:
        json.dump(record, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    cwd = marker.parent / 'delivery-fetch'
    cwd.mkdir()  # Exclusive; retain an interrupted fetch context.
    env = {**host_environment(admitted), **tool_environment(admitted), 'GIT_TERMINAL_PROMPT': '0'}
    result = credential_git(admitted, cwd, env, 'clone', '--no-checkout', '--template=', '--',
                            'https://github.com/' + grant['repository'] + '.git', str(workspace))
    require(result.returncode == 0 and not any(word in result.stderr.lower() for word in
            (b'warning:', b'fatal:', b'error:')), 'delivery fetch failed; retained preparation requires reconciliation')
    return admitted, account


def protected_metadata(workspace, worktree):
    workspace, worktree = Path(workspace), Path(worktree)
    require(worktree.parent == workspace / '.git/launch-prepared', 'unexpected delivery worktree parent')
    metadata = workspace / '.git/worktrees' / worktree.name
    pointer = checked_path(str(worktree / '.git'), file=True)
    require(pointer.read_text().strip() == 'gitdir: ' + str(metadata), 'delivery Git pointer changed')
    paths = [workspace / '.git/config', workspace / '.git/config.worktree', pointer,
             metadata / 'commondir', metadata / 'gitdir', metadata / 'config.worktree',
             workspace / 'scripts/verify.sh', worktree / 'scripts/verify.sh']
    for project in (workspace, worktree):
        directory = checked_path(str(project / '.codex'))
        require(directory.is_dir(), 'missing generated delivery config')
        import tomllib
        config_path = checked_path(str(directory / 'config.toml'))
        config = tomllib.loads(config_path.read_text()) if config_path.exists() else {}
        require(set(config) <= {'agents', 'features'}
                and isinstance(config.get('agents', {}), dict)
                and set(config.get('agents', {})) <= {'default_subagent_model', 'default_subagent_reasoning_effort'}
                and isinstance(config.get('features', {}), dict)
                and set(config.get('features', {})) <= {'hooks'}
                and config.get('features', {}).get('hooks', True) is True,
                'unsupported generated native execution configuration')
        for path in directory.rglob('*'):
            checked_path(str(path))
            if path.is_file(): paths.append(path)
        # Configuration additions also change this map, not only existing-file hashes.
        require(not (project / '.mcp.json').exists() and not (project / '.agents/skills/launch').exists(),
                'unapproved project runtime configuration')
    result = {}
    for path in paths:
        checked_path(str(path))
        result[str(path)] = _runtime['digest'](path.read_bytes()) if path.is_file() else None
    return result


def seal_preparation(admitted, cfg, manifest):
    record = preparation_record(admitted, sealed=False)
    require(record['status'] == 'cloning' and record['id'] == cfg['items'][0]['id'],
            'delivery preparation cannot be replaced')
    worktree = cfg['items'][0]['worktree']
    record.update(status='prepared', worktree=worktree, manifest=str(manifest),
                  manifest_digest=_runtime['digest'](manifest.read_bytes()),
                  files=protected_metadata(admitted['grant']['workspace'], worktree))
    _runtime['atomic'](preparation_path(admitted), record)


def check_binding(queue):
    admitted = load_binding(queue.cfg['delivery'])
    record = preparation_record(admitted)
    prepared = queue.cfg.get('preparation', {})
    policy = pinned_json(prepared.get('policy'), prepared.get('policy_digest'))
    validate_target(admitted, policy)
    require(record['manifest'] == str(queue.manifest_path)
            and record['manifest_digest'] == _runtime['digest'](queue.manifest_path.read_bytes()),
            'sealed delivery manifest changed')
    require(queue.cfg['project'] == admitted['grant']['workspace']
            and len(queue.cfg['items']) == 1 and queue.cfg['items'][0]['worktree'] == record['worktree']
            and queue.cfg['items'][0]['id'] == record['id'], 'sealed delivery task changed')
    require(protected_metadata(admitted['grant']['workspace'], record['worktree']) == record['files'],
            'protected delivery configuration changed')
    for root in (admitted['grant']['workspace'], record['worktree']):
        config = checked_path(str(Path(root) / '.codex/launch/verify.json'), file=True)
        require(json.loads(config.read_text()) == admitted['grant']['verification'], 'approved verification changed')
    return admitted


def launch_options(queue, item, env):
    admitted = check_binding(queue)
    require(item['worktree'] == queue.cfg['items'][0]['worktree'], 'unbound native worktree')
    options = permission_options(filesystem(admitted))
    for value in ['default_permissions="launch_control_delivery"', 'apps._default.enabled=false',
                  'web_search="disabled"', 'features.apps=false', 'features.plugins=false', 'features.memories=false',
                  'shell_environment_policy.inherit="none"', 'allow_login_shell=false',
                  'shell_environment_policy.set=' + toml_inline(tool_environment(admitted, env)),
                  *admitted['host']['native_overrides']]:
        options += ['-c', value]
    native_env = host_environment(admitted)
    native_env.update(LAUNCH_RUN_ID=item['run'], LAUNCH_PLATFORM='codex',
                      CODEX_VERSION=admitted['host']['codex_version'])
    return {'command': [admitted['host']['codex'], 'app-server', *options],
            'permission_profile': 'launch_control_delivery', 'env': native_env}
