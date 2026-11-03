#!/usr/bin/env python3
"""Restricted delivery admission checks; no network or native model."""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import runpy
import subprocess
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts/launch-delivery.py'
spec = importlib.util.spec_from_file_location('launch_delivery', SCRIPT)
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
SYSTEM_PATH = list(dict.fromkeys(str(Path(p).resolve(strict=True)) for p in ('/usr/bin', '/bin')))


def refused(callback, phrase):
    try:
        callback()
    except ValueError as error:
        assert phrase in str(error), str(error)
    else:
        raise AssertionError('expected refusal: ' + phrase)


config = {'model': 'fixture', 'hooks': {'state': {'hook': {'enabled': True,
          'trusted_hash': 'sha256:' + 'a' * 64}}},
          'projects': {'/fixture': {'trust_level': 'trusted'}}}
original = copy.deepcopy(config)
expected = delivery.execution_digest(config)
assert config == original
config['projects']['/second'] = {'trust_level': 'untrusted'}
config['hooks']['state']['hook']['enabled'] = False
assert delivery.execution_digest(config) == expected
config['model'] = 'changed'
assert delivery.execution_digest(config) != expected
for section, entry in [('projects', {'trust_level': 'trusted', 'command': 'bad'}),
                       ('hooks', {'enabled': 'true'}),
                       ('hooks', {'trusted_hash': 'unverified'})]:
    bad = copy.deepcopy(original)
    if section == 'projects': bad['projects']['/fixture'] = entry
    else: bad['hooks']['state']['hook'] = entry
    refused(lambda: delivery.execution_digest(bad), 'trust metadata')

policy = {'schema': 1, 'scope_template': 'Implement {id}',
          'generator': {'argv': ['/python', '/codex-parity.py', '--project', '{worktree}']}}
target_hash = delivery.target_digest(policy)
policy['delivery'] = {'grant': '/grant.json', 'digest': 'a' * 64}
assert delivery.target_digest(policy) == target_hash
policy['scope_template'] = 'Publish unrelated work'
assert delivery.target_digest(policy) != target_hash
print('PASS: execution settings and target scope remain bound across trust/grant metadata')

with tempfile.TemporaryDirectory(prefix='launch-binding-') as temporary:
    base = Path(temporary).resolve()
    home, code, authority = base / 'home', base / 'code', base / 'authority'
    for path in (home, code, authority): path.mkdir()
    config_path = home / 'config.toml'
    config_path.write_text('model="fixture"\n')
    executables = {}
    for name in ('codex', 'python', 'git', 'gh'):
        path = code / name
        path.write_text('fixture ' + name)
        path.chmod(0o755)
        executables[name] = str(path)
    host = {'schema': 1, 'platform': 'Darwin', 'codex_version': 'codex-cli 0.162.0',
            **executables, 'path': [str(code), *SYSTEM_PATH],
            'read_roots': [str(code)], 'read_files': [],
            'files': {path: delivery.canonical_digest(name) for name, path in executables.items()},
            'native_config': {'path': str(config_path),
                              'execution_digest': delivery.execution_digest({'model': 'fixture'})},
            'native_overrides': [], 'hook_commands': {}}
    import hashlib
    host['files'] = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                     for path in executables.values()}
    host_path = authority / 'host.json'
    host_path.write_text(json.dumps(host))
    approved = {'schema': 1, 'project': str(base / 'original'), 'base_revision': 'a' * 40,
                'source': {'path': 'BACKLOG.md', 'format': 'table', 'heading': '# Selected'},
                'scope_template': 'Fix {id}', 'generator': {'argv': [executables['python'],
                    str(code / 'codex-parity.py'), '--project', '{worktree}']},
                'caps': {'minutes': 15, 'max_attempts': 2,
                         'rollover': {'threshold': 65, 'max_launches': 1, 'synchronous_commands': []}}}
    grant = {'schema': 1, 'target_digest': delivery.target_digest(approved),
             'verification': {'schema': 1, 'checks': [{'command': 'test -f tracked', 'cwd': '.',
                             'timeout': 5}], 'acceptance': ['behavior']},
             'repository': 'fixture/repo', 'base_branch': 'main', 'base_revision': 'a' * 40,
             'source': {**approved['source'], 'blob': 'b' * 40}, 'workspace': str(base / 'worker'),
             'host_policy': {'path': str(host_path), 'digest': hashlib.sha256(host_path.read_bytes()).hexdigest()},
             'allowed_actions': ['prepare', 'implement', 'review'],
             'minutes': 15, 'max_attempts': 2, 'max_launches': 1}
    grant_path = authority / 'grant.json'
    def binding_for(value):
        grant_path.write_text(json.dumps(value))
        return {'grant': str(grant_path), 'digest': hashlib.sha256(grant_path.read_bytes()).hexdigest()}
    with patch.dict(os.environ, {'HOME': str(home), 'CODEX_HOME': str(home)}), \
         patch.object(delivery.platform, 'system', return_value='Darwin'):
        binding = binding_for(grant)
        admitted = delivery.load_binding(binding)
        assert admitted['grant'] == grant
        publishing = {**grant, 'allowed_actions': grant['allowed_actions'] + ['push', 'pull_request', 'publish'],
                      'publication': {'mode': 'github-base-lease', 'deployment': 'none',
                                      'required_checks': [{'name': 'validate', 'app_id': 1}],
                                      'billing_fallback': False}}
        assert delivery.load_binding(binding_for(publishing))['grant'] == publishing
        merging = {**publishing, 'publication': {**publishing['publication'], 'post_merge_checks': []}}
        assert delivery.load_binding(binding_for(merging))['grant'] == merging
        for checks in ([{'name': '', 'app_id': 1}], [{'name': 'validate'}], 'all'):
            bad = {**publishing, 'publication': {**publishing['publication'], 'post_merge_checks': checks}}
            refused(lambda: delivery.load_binding(binding_for(bad)), 'publication')
        for change in ({'deployment': 'required'}, {'mode': 'head-only'}, {'billing_fallback': 'true'},
                       {'required_checks': [] + [{'name': '', 'app_id': 1}]},
                       {'required_checks': [{'name': 'validate', 'app_id': True}]},
                       {'required_checks': [{'name': 'validate', 'app_id': 1}] * 2}):
            bad = {**publishing, 'publication': {**publishing['publication'], **change}}
            refused(lambda: delivery.load_binding(binding_for(bad)), 'publication')
        for bad in ({**publishing, 'allowed_actions': grant['allowed_actions']},
                    {**grant, 'allowed_actions': grant['allowed_actions'] + ['push']},
                    {k: v for k, v in publishing.items() if k != 'publication'}):
            refused(lambda: delivery.load_binding(binding_for(bad)), 'publication')
        completing = {**publishing, 'allowed_actions': publishing['allowed_actions'] + ['source_done'],
                      'source_writeback': {'repository': 'fixture/repo', 'branch': 'main',
                                           'path': 'BACKLOG.md', 'heading': '# Selected', 'max_attempts': 2}}
        assert delivery.load_binding(binding_for(completing))['grant'] == completing
        for change in ({'repository': 'other/repo'}, {'branch': 'other'}, {'max_attempts': 3}, {'max_attempts': 2.0},
                       {'heading': '# History'}, {'path': 'other.md'}):
            bad = {**completing, 'source_writeback': {**completing['source_writeback'], **change}}
            refused(lambda: delivery.load_binding(binding_for(bad)), 'source')
        for bad in ({k: v for k, v in completing.items() if k != 'source_writeback'},
                    {**completing, 'allowed_actions': publishing['allowed_actions']}):
            refused(lambda: delivery.load_binding(binding_for(bad)), 'source')
        deps = base / 'deps'
        deps.mkdir()
        (deps / 'pkg').write_text('fixture package\n')
        dependency = {'target': 'ui/node_modules', 'source': str(deps), 'digest': delivery.tree_digest(deps),
                      'lockfile': 'ui/pnpm-lock.yaml', 'lock_digest': 'c' * 64}
        (deps / 'link').symlink_to('pkg')
        identity = delivery.tree_digest(deps)
        (deps / 'pkg').chmod(0o755)
        assert delivery.tree_digest(deps) != identity
        (deps / 'pkg').chmod(0o644)
        (deps / 'link').unlink()
        (deps / 'link').symlink_to('other')
        assert delivery.tree_digest(deps) != identity
        (deps / 'link').unlink()
        (deps / 'link').symlink_to('pkg')
        assert delivery.tree_digest(deps) == identity
        dependency['digest'] = identity
        provisioned = {**grant, 'dependencies': [dependency]}
        assert delivery.load_binding(binding_for(provisioned))['grant'] == provisioned
        for change in ({'target': '../escape'}, {'target': '.git/hooks'}, {'target': '.codex/x'}, {'lockfile': '/abs.lock'},
                       {'digest': 'short'}, {'lock_digest': 'C' * 64}, {'extra': True}, {'target': []},
                       {'target': '.GIT/hooks'}, {'target': '.Codex/x'}):
            bad = {**grant, 'dependencies': [{**dependency, **change}]}
            refused(lambda: delivery.load_binding(binding_for(bad)), 'invalid provisioned dependency')
        refused(lambda: delivery.load_binding(binding_for({**grant, 'dependencies': [dependency, dependency]})),
                'invalid provisioned dependencies')
        refused(lambda: delivery.load_binding(binding_for({**grant, 'dependencies': [dependency, {**dependency, 'target': 'UI'}]})),
                'invalid provisioned dependencies')
        (deps / 'pkg').chmod(0o4644)
        refused(lambda: delivery.tree_digest(deps), 'unsupported provisioned dependency entry')
        (deps / 'pkg').chmod(0o644)
        for source in (home, authority, base / 'missing'):
            bad = {**grant, 'dependencies': [{**dependency, 'source': str(source)}]}
            refused(lambda: delivery.load_binding(binding_for(bad)), 'provisioned dependency overlaps')
        binding = binding_for(grant)
        env = delivery.tool_environment(admitted, {'GH_TOKEN': 'must-not-pass', 'PYTHONPATH': '/bad',
                                                 'LAUNCH_RUN_ID': 'fixture-run'})
        assert 'GH_TOKEN' not in env and 'PYTHONPATH' not in env
        assert env['GIT_CONFIG_GLOBAL'] == '/dev/null' and env['LAUNCH_RUN_ID'] == 'fixture-run'
        argv = delivery.sandbox_command(admitted, base, {str(code): 'read'}, ['/git', 'status'], env)
        inner = argv.index('/usr/bin/env')
        assert argv[inner + 1] == '-i' and argv[-2:] == ['/git', 'status']
        runtime_dir = home / 'runtime'
        runtime_dir.mkdir()
        host['read_roots'].append(str(runtime_dir))
        host_path.write_text(json.dumps(host))
        grant['host_policy']['digest'] = hashlib.sha256(host_path.read_bytes()).hexdigest()
        binding = binding_for(grant)
        admitted = delivery.load_binding(binding)
        hook = code / 'hook.sh'
        hook.write_text('#!/bin/bash\nexit 0\n')
        shell = str(Path('/bin/bash').resolve())
        command = shell + ' ' + str(hook)
        hooks_file = home / 'hooks.json'
        hooks_file.write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': command}]}]}}))
        for path in (hook, Path(shell), hooks_file):
            host['files'][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        def refresh_host():
            host_path.write_text(json.dumps(host))
            grant['host_policy']['digest'] = hashlib.sha256(host_path.read_bytes()).hexdigest()
            return binding_for(grant)
        binding = refresh_host()
        refused(lambda: delivery.load_binding(binding), 'hook command inventory')
        host['hook_commands'] = {command: [shell]}
        binding = refresh_host()
        refused(lambda: delivery.load_binding(binding), 'hook artifact')
        host['hook_commands'][command].append(str(hook))
        helper = code / 'helper.py'
        helper.write_text('# reviewed transitive helper\n')
        host['files'][str(helper)] = hashlib.sha256(helper.read_bytes()).hexdigest()
        host['hook_commands'][command].append(str(helper))
        binding = refresh_host()
        admitted = delivery.load_binding(binding)
        native_disabled = 'model="fixture"\n[hooks.state.fixture]\nenabled=false\n'
        config_path.write_text(native_disabled)
        delivery.load_binding(binding)
        helper.write_text('# changed helper\n')
        refused(lambda: delivery.load_binding(binding), 'reviewed file changed')
        helper.write_text('# reviewed transitive helper\n')
        hook.write_text('#!/bin/bash\nexit 9\n')
        refused(lambda: delivery.load_binding(binding), 'reviewed file changed')
        hook.write_text('#!/bin/bash\nexit 0\n')
        approved['delivery'] = binding
        delivery.validate_target(admitted, approved)
        for field in ('scope_template', 'generator'):
            changed = copy.deepcopy(approved)
            changed[field] = 'substituted' if field == 'scope_template' else {'argv': ['bad']}
            refused(lambda: delivery.validate_target(admitted, changed), 'target policy')
        for actions in (['review'], ['prepare', 'implement', 'review', 'admin']):
            refused(lambda: delivery.load_binding(binding_for({**grant, 'allowed_actions': actions})), 'actions')
        binding = binding_for(grant)
        config_path.write_text('model="changed"\n')
        refused(lambda: delivery.load_binding(binding), 'execution configuration changed')
        config_path.write_text('model="fixture"\n')
        Path(executables['git']).write_text('changed executable')
        refused(lambda: delivery.load_binding(binding), 'reviewed file changed')
print('PASS: frozen grant, required actions, host execution settings and executable drift')
print('PASS: provisioned dependency shape, relative targets and protected-source admission')

fixture_admitted = {'host': {'gh': '/gh', 'path': []}, 'binding': {'grant': '/authority/grant.json'},
                    'grant': {'repository': 'o/r'}}
gh_403 = subprocess.CompletedProcess([], 1, json.dumps(delivery.RULES_UNAVAILABLE).encode(), b'gh: HTTP 403')
with patch.object(delivery, 'run_owned', return_value=gh_403):
    try:
        delivery.github_read(fixture_admitted, 'repos/o/r/rules/branches/main')
    except delivery.GitHubError as error:
        assert error.body == delivery.RULES_UNAVAILABLE and 'HTTP 403' in str(error)
    else:
        raise AssertionError('failed GitHub read returned')
with patch.object(delivery, 'run_owned', return_value=subprocess.CompletedProcess([], 1, b'not json', b'')):
    refused(lambda: delivery.github_read(fixture_admitted, 'repos/o/r'), 'GitHub read failed')

# The ambient gh login reaches every repository the user can; each credentialed call names only the grant.
for endpoint in ('user', 'repos/o/r', 'repos/o/r/pulls?state=all&head=o%3Ax', 'repos/o/r/branches/acceptance%2Fx'):
    assert delivery.github_endpoint(fixture_admitted, endpoint) == endpoint
for endpoint in ('repos/o/r2/pulls', 'repos/o/rx', 'repos/x/r/pulls', 'repos/o/r/../../x/y/pulls',
                 'repos/o/r/%2e%2e/%2E%2E/x/y/pulls', 'graphql', 'orgs/o', 'https://api.github.com/repos/o/r',
                 'user/repos', 'repos/o/r/./pulls'):
    with patch.object(delivery, 'run_owned', side_effect=AssertionError('credentialed call dispatched')):
        refused(lambda: delivery.gh_api(fixture_admitted, endpoint, '--method', 'POST'), 'ungranted GitHub endpoint')
        refused(lambda: delivery.github_read(fixture_admitted, endpoint), 'ungranted GitHub endpoint')
fixture_admitted['host']['git'] = '/git'
url = 'https://github.com/o/r.git'
with patch.object(delivery, 'run_owned', return_value=subprocess.CompletedProcess([], 0, b'', b'')) as owned:
    delivery.credential_git(fixture_admitted, '/cwd', {}, 'push', url, 'a' * 40 + ':refs/heads/main')
    assert owned.call_args[0][0][:5] == ['/git', '-c', 'credential.helper=', '-c', 'credential.helper=!/gh auth git-credential']
for args in (('clone', '--', 'https://github.com/o/r2.git', '/w'), ('fetch', 'ssh://git@github.com/o/r.git'),
             ('fetch', 'git@github.com:o/r.git'), ('fetch', 'ext::sh -c id'), ('push', url, 'https://github.com/x/r.git'),
             ('fetch', 'https://evil.example/o/r.git'), ('fetch', 'evil.example:o/r'), ('fetch', 'github.com:o/r'),
             ('-c', 'url.evil.example:.insteadOf=https://github.com/', 'fetch', url),
             ('fetch', '--upload-pack=touch /tmp/x', url), ('fetch', url, 'refs/heads/main:/tmp/x'),
             ('push', url, url), ('fetch', 'origin')):
    with patch.object(delivery, 'run_owned', side_effect=AssertionError('credentialed call dispatched')):
        refused(lambda: delivery.credential_git(fixture_admitted, '/cwd', {}, *args), 'ungranted Git remote')
pusher = object.__new__(delivery.Publisher)
pusher.grant, pusher.record = {'base_branch': 'main'}, {'head_branch': 'launch/t-1'}
pusher.git = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('ungranted branch reached Git'))
for branch in ('other', 'refs/heads/main', 'main:other', 'launch/t-2'):
    refused(lambda: pusher.push_ref(branch, '', 'a' * 40), 'ungranted publication branch')
print('PASS: credentialed GitHub calls name only the granted repository, remote and branches')
responses = {}
def fixture_read(admitted, endpoint):
    value = responses[endpoint]
    if isinstance(value, Exception):
        raise value
    return value
rules_endpoint = 'repos/o/r/rules/branches/main?per_page=100'
if True:
    responses.update({rules_endpoint: [{'type': 'pull_request'}]})
    assert delivery.branch_rules(lambda e: fixture_read(None, e), 'repos/o/r', 'main') == [{'type': 'pull_request'}]
    responses.update({rules_endpoint: delivery.GitHubError('GitHub read failed: 403', delivery.RULES_UNAVAILABLE),
                      'repos/o/r': {'private': True}})
    assert delivery.branch_rules(lambda e: fixture_read(None, e), 'repos/o/r', 'main') == []
    responses['repos/o/r'] = []
    refused(lambda: delivery.branch_rules(lambda e: fixture_read(None, e), 'repos/o/r', 'main'), 'GitHub read failed')
    responses['repos/o/r'] = {'private': False}
    refused(lambda: delivery.branch_rules(lambda e: fixture_read(None, e), 'repos/o/r', 'main'), 'GitHub read failed')
    responses['repos/o/r'] = {'private': True}
    for body in ({**delivery.RULES_UNAVAILABLE, 'status': '404'}, {'message': 'Not Found'}, None):
        responses[rules_endpoint] = delivery.GitHubError('GitHub read failed: other', body)
        refused(lambda: delivery.branch_rules(lambda e: fixture_read(None, e), 'repos/o/r', 'main'), 'GitHub read failed')
print('PASS: rules are empty only for the exact plan refusal on a private repository')

runtime = runpy.run_path(str(SCRIPT.with_name('launch-runtime.py')))
seen = []
def git_runner(root, *args):
    seen.append((str(root), args))
    return subprocess.CompletedProcess(args, 0, b'', b'')
runtime['configure_git']('one-grant', git_runner)
assert runtime['git'](Path('/fixture'), 'status') == ''
assert runtime['fingerprint'](Path('/fixture')) == runtime['digest'](b'[]')
assert [args[0] for _, args in seen] == ['status', 'ls-files']
try:
    runtime['configure_git'](None, None)
except runtime['Invalid']:
    pass
else:
    raise AssertionError('restricted process reused by an unbound caller')
try:
    runtime['configure_git']('different-grant', git_runner)
except runtime['Invalid']:
    pass
else:
    raise AssertionError('process delivery grant replaced')
print('PASS: shared Git routing and immutable process grant')

# Run real preparation/generation/Git with only network and the OS sandbox launcher
# substituted. Native sandbox denial is a separate installed acceptance requirement.
import base64
import shutil
import types
with tempfile.TemporaryDirectory(prefix='delivery-prepare-') as temporary:
    base = Path(temporary).resolve()
    original, home, rendered = base/'original', base/'home', base/'rendered'
    for directory in (original, home, rendered): directory.mkdir()
    git_bin, python_bin = str(Path(shutil.which('git')).resolve()), str(Path(sys.executable).resolve())
    def git_at(root, *args):
        return subprocess.check_output([git_bin, '-C', str(root), *args], stderr=subprocess.DEVNULL).decode().strip()
    git_at(original, 'init', '-b', 'main')
    git_at(original, 'config', 'user.name', 'Fixture')
    git_at(original, 'config', 'user.email', 'fixture@example.invalid')
    (original/'.gitignore').write_text('.codex/\nscripts/verify.sh\nlaunch-control-backups/\ndeps/\n.check-cache\n')
    (original/'tracked').write_text('fixture')
    (original/'deps.lock').write_text('fixture lock\n')
    source = '# Selected\n| ID | Item | Status | Tier |\n|---|---|---|---|\n| T-1 | selected | [ ] | P1 |\n'
    (original/'BACKLOG.md').write_text(source)
    git_at(original, 'add', '.')
    git_at(original, 'commit', '-m', 'fixture')
    revision, blob = git_at(original, 'rev-parse', 'HEAD'), git_at(original, 'rev-parse', 'HEAD:BACKLOG.md')
    remote = base/'remote.git'
    subprocess.run([git_bin, 'clone', '--bare', str(original), str(remote)], check=True, capture_output=True)
    refs = rendered/'skills/launch/references'
    refs.mkdir(parents=True)
    (refs.parent/'SKILL.md').write_text('---\nname: launch\ndescription: fixture\n---\n${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/references/launch-autonomy.md\n')
    for name in ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md'):
        (refs/name).write_text(name+'\n')
    check_command = 'test -f tracked && test -f deps/marker && touch .check-cache'
    checks = {'schema': 1, 'checks': [{'command': check_command, 'cwd': '.', 'timeout': 5}], 'acceptance': ['behavior']}
    config, commands, native_config = base/'checks.json', base/'commands.txt', home/'config.toml'
    config.write_text(json.dumps(checks)); commands.write_text(check_command + '\n'); native_config.write_text('model="fixture"\n')
    fake = base/'fake-command'; fake.write_text('not executed'); fake.chmod(0o755)
    workspace = base/'worker'
    runtime_path = SCRIPT.with_name('launch-runtime.py')
    argv = [python_bin, '-I', str(SCRIPT.with_name('codex-parity.py')), '--codex', '--enable-autonomy',
            '--source', str(rendered), '--autonomy-config', str(config), '--autonomy-commands', str(commands),
            '--autonomy-controller', str(runtime_path), '--autonomy-controller-digest', hashlib.sha256(runtime_path.read_bytes()).hexdigest(),
            '--autonomy-shared-root', str(workspace), '--project', '{worktree}']
    policy = {'schema': 1, 'project': str(original), 'base_revision': revision,
              'source': {'path': 'BACKLOG.md', 'format': 'table', 'heading': '# Selected'},
              'scope_template': 'Fix {id}; acceptance at {gitdir}/acceptance.json.', 'generator': {'argv': argv},
              'caps': {'minutes': 15, 'max_attempts': 3, 'rollover': {'threshold': 65, 'max_launches': 2,
                                                                    'synchronous_commands': ['git status --short', 'git rev-parse HEAD^2', 'git diff HEAD^2...HEAD']}}}
    pinned = [Path(python_bin), Path(git_bin), fake, config, commands,
              *[p for p in SCRIPT.parent.iterdir() if p.is_file()], *[p for p in rendered.rglob('*') if p.is_file()]]
    host = {'schema': 1, 'platform': 'Darwin', 'codex_version': 'codex-cli 0.162.0',
            'codex': str(fake), 'gh': str(fake), 'python': python_bin, 'git': git_bin,
            'path': list(dict.fromkeys([str(Path(python_bin).parent), str(Path(git_bin).parent), *SYSTEM_PATH])),
            'read_roots': list(dict.fromkeys([str(Path(python_bin).parent), str(Path(git_bin).parent), str(SCRIPT.parent), str(rendered)])),
            'read_files': [str(config), str(commands)],
            'files': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in pinned},
            'native_config': {'path': str(native_config), 'execution_digest': delivery.execution_digest({'model': 'fixture'})},
            'native_overrides': [], 'hook_commands': {}}
    provisioned = base/'provisioned'
    (provisioned/'bin').mkdir(parents=True)
    (provisioned/'marker').write_text('host-built dependency\n')
    (provisioned/'bin/tool').write_text('#!/bin/sh\n')
    (provisioned/'bin/tool').chmod(0o755)
    (provisioned/'current').symlink_to('bin')
    host_path = base/'host.json'; host_path.write_text(json.dumps(host))
    grant = {'schema': 1, 'target_digest': delivery.target_digest(policy), 'verification': checks,
             'repository': 'fixture/repo', 'base_branch': 'main', 'base_revision': revision,
             'source': {**policy['source'], 'blob': blob}, 'workspace': str(workspace),
             'host_policy': {'path': str(host_path), 'digest': hashlib.sha256(host_path.read_bytes()).hexdigest()},
             'allowed_actions': ['prepare', 'implement', 'review', 'push', 'pull_request', 'publish'],
             'publication': {'mode': 'github-base-lease', 'deployment': 'none', 'required_checks': [], 'billing_fallback': False,
                             'post_merge_checks': []},
             'minutes': 15, 'max_attempts': 3, 'max_launches': 2,
             'dependencies': [{'target': 'deps', 'source': str(provisioned), 'digest': delivery.tree_digest(provisioned),
                               'lockfile': 'deps.lock', 'lock_digest': hashlib.sha256(b'fixture lock\n').hexdigest()}]}
    for missing in ('git rev-parse HEAD^2', 'git diff HEAD^2...HEAD'):
        incomplete = copy.deepcopy(policy)
        incomplete['caps']['rollover']['synchronous_commands'].remove(missing)
        authority = {**grant, 'target_digest': delivery.target_digest(incomplete)}
        refused(lambda: delivery.validate_target({'grant': authority}, incomplete), 'repair review')
    grant_path = base/'grant.json'; grant_path.write_text(json.dumps(grant))
    binding = {'grant': str(grant_path), 'digest': hashlib.sha256(grant_path.read_bytes()).hexdigest()}
    policy['delivery'] = binding
    policy_path = base/'policy.json'; policy_path.write_text(json.dumps(policy))
    target = runpy.run_path(str(SCRIPT.with_name('launch-target.py')))
    trace = []
    remote_pr, writes, raced, rule_reads = {}, [], [], []
    def pr_readback():
        branch = 'launch/t-1'
        candidate = git_at(remote, 'rev-parse', 'refs/heads/' + branch)
        main = git_at(remote, 'rev-parse', 'refs/heads/main')
        merged = subprocess.run([git_bin, '-C', str(remote), 'merge-base', '--is-ancestor', candidate, main], capture_output=True).returncode == 0
        return {'number': 1, 'node_id': 'fixture-pr', 'html_url': 'https://github.com/fixture/repo/pull/1',
                'head': {'sha': candidate, 'ref': branch, 'repo': {'full_name': 'fixture/repo'}},
                'base': {'sha': main, 'ref': 'main', 'repo': {'full_name': 'fixture/repo'}},
                'title': remote_pr['title'], 'body': remote_pr['body'], 'merged': merged, 'merge_commit_sha': main if merged else None,
                'state': 'closed' if merged else 'open', 'draft': False, 'mergeable': True}
    def local_command(command, cwd, env, timeout=60, input=None, on_start=None):
        trace.append(list(command))
        if command[:2] == [str(fake), 'api']:
            if '--method' in command:
                assert command[command.index('--method') + 1] == 'POST'
                assert not remote_pr, 'duplicate PR creation'
                remote_pr.update(json.loads(Path(command[command.index('--input') + 1]).read_text()))
                writes.append('pull_request')
                return subprocess.CompletedProcess(command, 0, json.dumps(pr_readback()).encode(), b'')
            assert 'Accept: application/vnd.github.diff' in command
            pr = pr_readback()
            # GitHub abbreviates index hashes by repository size (8 on target repo C), never a fixed 7.
            diff = subprocess.check_output([git_bin, '-C', str(workspace), 'diff', '--no-ext-diff', '--no-textconv',
                                           '--abbrev=8', pr['base']['sha'] + '...' + pr['head']['sha']])
            return subprocess.CompletedProcess(command, 0, diff, b'')
        if command[:2] == [str(fake), 'sandbox']:
            command = command[command.index('--') + 1:]
        else:
            command = [str(remote) if value == 'https://github.com/fixture/repo.git' else value for value in command]
        if 'push' in command and command[-1].endswith(':refs/heads/main') and not raced:
            (original/'concurrent.txt').write_text('preserve unrelated base work\n')
            git_at(original, 'add', 'concurrent.txt')
            git_at(original, 'commit', '-m', 'concurrent base advance')
            git_at(original, 'push', str(remote), 'HEAD:refs/heads/main')
            raced.append(git_at(remote, 'rev-parse', 'main'))
        if on_start:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            on_start(process.pid)
            stdout, stderr = process.communicate(input, timeout=timeout)
            result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        else:
            result = subprocess.run(command, cwd=cwd, env=env, input=input, capture_output=True, timeout=timeout)
        if 'push' in command:
            writes.append('base' if command[-1].endswith(':refs/heads/main') else 'head')
            if writes[-1] == 'base' and result.returncode == 0:
                raise subprocess.TimeoutExpired('synthetic lost successful base response', timeout)
        return result
    def remote_read(admitted, endpoint):
        if endpoint == 'user': return {'id': 1, 'login': 'fixture'}
        if '/branches/main' in endpoint and '/rules/' not in endpoint:
            return {'name': 'main', 'protected': False, 'commit': {'sha': git_at(remote, 'rev-parse', 'main')}}
        if '/rules/branches/' in endpoint:  # Free private plan: rulesets and protection cannot exist.
            rule_reads.append(endpoint)
            raise delivery.GitHubError('GitHub read failed: HTTP 403', delivery.RULES_UNAVAILABLE)
        if endpoint == 'repos/fixture/repo': return {'private': True}
        if endpoint.endswith('/reviews?per_page=100&page=1'):
            return []
        if '/git/matching-refs/heads/' in endpoint:
            return [{'ref': 'refs/heads/' + line.split()[0], 'object': {'type': 'commit', 'sha': line.split()[1]}}
                    for line in git_at(remote, 'for-each-ref', '--format=%(refname:short) %(objectname)', 'refs/heads').splitlines()]
        if '/check-runs?' in endpoint: return {'check_runs': []}
        if '/statuses?' in endpoint:  # Only the merged base commit carries a hosted result (a deploy status).
            merged = endpoint.split('/commits/')[1].split('/')[0] == git_at(remote, 'rev-parse', 'main')
            return [{'id': 1, 'context': 'deploy', 'state': 'success'}] if merged and remote_pr else []
        if '/pulls?' in endpoint:  # An operator closed an earlier run's PR on the same head branch (GC #645).
            stale = {'number': 99, 'state': 'closed', 'merged_at': None, 'body': 'earlier run\n\n<!-- launch-control-delivery:old:run -->'}
            return [stale] + ([pr_readback()] if remote_pr else [])
        if endpoint.endswith('/pulls/1'): return pr_readback()
        if '/git/trees/' in endpoint:
            return {'truncated': False, 'tree': [{'path': name} for name in git_at(original, 'ls-files').splitlines()]}
        if '/commits/' in endpoint: return {'sha': revision, 'commit': {'tree': {'sha': git_at(original, 'rev-parse', 'HEAD^{tree}')}}}
        return {'sha': blob, 'encoding': 'base64', 'content': base64.b64encode(source.encode()).decode()}
    with patch.dict(os.environ, {'HOME': str(home), 'CODEX_HOME': str(home)}), \
         patch.object(delivery.platform, 'system', return_value='Darwin'), \
         patch.object(delivery, 'run_owned', local_command), \
         patch.object(delivery, 'github_read', remote_read), \
         patch.object(target['rt'], 'delivery_module', return_value=delivery):
        manifest = base/'manifest.json'
        cfg = target['prepare'](policy_path, manifest)
        assert len(rule_reads) == 1
        assert cfg['project'] == str(workspace) and cfg['items'][0]['id'] == 'T-1'
        # Only Git may write a protected .agents tree; the prepare checkout of a tracked skill needs it.
        agents = json.dumps(str(workspace/'.agents')) + '="write"'
        prepare_checkout = next(c for c in trace if c[:2] == [str(fake), 'sandbox'] and 'checkout' in c and '-B' in c)
        assert any(agents in v for v in prepare_checkout if v.startswith('permissions.launch_control_delivery='))
        generator_calls = [command for command in trace if str(SCRIPT.with_name('codex-parity.py')) in command]
        assert len(generator_calls) == 2
        assert not any(agents in v for c in generator_calls for v in c)
        for command, project in zip(generator_calls, (workspace, Path(cfg['items'][0]['worktree']))):
            profile = next(value for value in command if value.startswith('permissions.launch_control_delivery='))
            assert json.dumps(str(project / '.codex')) + '=\"write\"' in profile
        assert not (original/'.git/launch-queue').exists()
        hook_result = subprocess.run(['/bin/bash', str(workspace/'.codex/hooks/launch.sh')],
                                     cwd=workspace, env={**os.environ, 'LAUNCH_RUN_ID': '', 'PYTHONPATH': str(original)},
                                     input='{}', text=True, capture_output=True)
        assert hook_result.returncode == 0 and json.loads(hook_result.stdout) == {}, hook_result.stderr
        assert not list((SCRIPT.parent/'__pycache__').glob('*.pyc'))
        for project in (workspace, Path(cfg['items'][0]['worktree'])):
            project_config = project / '.codex/config.toml'
            assert not project_config.exists()
            project_config.write_text('[features]\nhooks = true\n')
            refused(lambda: target['queue'].Queue(manifest), 'protected delivery configuration changed')
            project_config.unlink()
        q = target['queue'].Queue(manifest)
        q.run(True)
        assert q.state['launches'] == q.state['admissions'] == 0
        marker = '<!-- launch-control-delivery:h:r -->'
        assert delivery.foreign_stale_pr({'state': 'closed', 'merged_at': None, 'body': 'x'}, marker)
        assert not delivery.foreign_stale_pr({'state': 'closed', 'merged_at': '2026-10-15T00:00:00Z', 'body': 'x'}, marker)
        assert not delivery.foreign_stale_pr({'state': 'open', 'merged_at': None, 'body': 'x'}, marker)
        assert not delivery.foreign_stale_pr({'state': 'closed', 'merged_at': None, 'body': 'x\n' + marker}, marker)
        launch = delivery.launch_options(q, {**cfg['items'][0], 'run': 'fixture'}, {'GH_TOKEN': 'secret'})
        assert launch['permission_profile'] == 'launch_control_delivery' and 'GH_TOKEN' not in launch['env']
        # A login shell's path_helper puts /System/Cryptexes/App/usr/bin ahead of the pinned PATH;
        # the sandbox answers that lookup with EPERM, so `pnpm build` could not spawn `sh` (target repo C).
        assert 'allow_login_shell=false' in launch['command']
        # Codex memories let a delivery worker read cross-project notes outside its read set (LC-030 live run).
        assert 'features.memories=false' in launch['command']
        assert 'skills.include_instructions=false' in launch['command']
        profile = next(value for value in launch['command'] if value.startswith('permissions.launch_control_delivery='))
        gitdir = workspace/'.git/worktrees'/Path(cfg['items'][0]['worktree']).name
        assert json.dumps(str(gitdir)) + '="write"' in profile
        assert json.dumps(str(gitdir/'commondir')) + '="read"' in profile
        check_spawns = []
        real_popen = subprocess.Popen
        def local_popen(command, *args, **kwargs):
            if command[:2] == [str(fake), 'sandbox']:
                check_spawns.append(command)
                command = command[command.index('--') + 1:]
            return real_popen(command, *args, **kwargs)
        with patch.object(subprocess, 'Popen', local_popen):
            runtime = target['rt'].Runtime(Path(cfg['items'][0]['worktree']), None, 'codex')
            assert runtime.verify(None, 'checks', None, None)['ok']
        assert len(check_spawns) == 1
        assert '/usr/bin/env' in check_spawns[0] and not any(arg.startswith('HOME=') for arg in check_spawns[0])
        # A worker-written success receipt cannot replace a fresh independent check.
        (runtime.base/'receipt.json').write_text('{"ok":true,"checks":[]}')
        admitted = delivery.check_binding(q)
        proof = delivery.verify_snapshot(admitted, workspace, revision, base/'fresh-verification')
        assert proof['revision'] == revision and proof['ok'] and proof['checks'][0]['exit'] == 0
        assert proof['checks'][0]['group_gone'] is True
        assert proof['worktree'] != str(runtime.root)
        assert (runtime.base/'receipt.json').read_text() == '{"ok":true,"checks":[]}'
        fresh = base/'fresh-verification/repo'
        for checkout in (runtime.root, fresh):
            assert delivery.tree_digest(checkout/'deps') == grant['dependencies'][0]['digest']
            assert (checkout/'.check-cache').is_file() and os.access(checkout/'deps/bin/tool', os.X_OK)
        verifier = [c for c in trace if c[:2] == [str(fake), 'sandbox'] and '--config' in c][-1]
        profile = next(v for v in verifier if v.startswith('permissions.launch_control_delivery='))
        assert json.dumps(str(fresh)) + '="write"' in profile and json.dumps(str(fresh/'.git')) + '="read"' in profile
        assert json.dumps(str(fresh/'deps')) + '="read"' in profile
        checkout = next(c for c in trace if c[:2] == [str(fake), 'sandbox'] and 'checkout' in c and 'verification' in c
                        and str(fresh) in c)
        checkout_profile = next(v for v in checkout if v.startswith('permissions.launch_control_delivery='))
        assert json.dumps(str(fresh/'.agents')) + '="write"' in checkout_profile
        assert json.dumps(str(fresh/'.agents')) + '="write"' not in profile
        probe = base/'provision-probe'
        probe.mkdir()
        (probe/'deps.lock').write_text('changed lock\n')
        refused(lambda: delivery.provision(admitted, probe), 'dependency lockfile changed')
        (probe/'deps.lock').write_text('fixture lock\n')
        (provisioned/'marker').write_text('tampered\n')
        refused(lambda: delivery.provision(admitted, probe), 'provisioned dependency changed')
        assert not (probe/'deps').exists()
        with patch.object(delivery.shutil, 'copytree', side_effect=OSError('fixture disk full')):
            refused(lambda: delivery.provision(admitted, probe), 'provisioned dependency copy failed')
        (provisioned/'marker').write_text('host-built dependency\n')
        (probe/'deps').mkdir()
        refused(lambda: delivery.provision(admitted, probe), 'provisioned dependency target exists')
        real_run = delivery.run_owned
        def tampering(command, *args, **kwargs):
            if '--config' in command:
                with (base/'tamper-check/repo/deps/marker').open('a') as stream:
                    stream.write('rewritten by a check\n')
            return real_run(command, *args, **kwargs)
        with patch.object(delivery, 'run_owned', tampering):
            refused(lambda: delivery.verify_snapshot(admitted, workspace, revision, base/'tamper-check'),
                    'provisioned dependency changed during checks')
        unignored = base/'unignored'
        shutil.copytree(original, unignored)
        (unignored/'.gitignore').write_text('.codex/\nscripts/verify.sh\nlaunch-control-backups/\n.check-cache\n')
        git_at(unignored, 'commit', '-am', 'stop ignoring dependencies')
        refused(lambda: delivery.verify_snapshot(admitted, unignored, git_at(unignored, 'rev-parse', 'HEAD'), base/'unignored-check'),
                'provisioned dependency is not ignored')
        with (q.base/'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            item = q.state['items'][0]
            q.prepare(item)
            item['next_session'] = 'fixture-native'
            q.save()
            runtime.activate(runtime.load(item['run']), 'fixture-native')
            item.update(session='fixture-native', status='running')
            q.save()
            state = runtime.load(item['run'])
            state['notes'] = json.dumps({key: 'fixture' for key in ('goal', 'scope', 'completed', 'next_phase',
                'next_action', 'questions', 'evidence', 'unsafe_state', 'reversal')})
            with runtime.lock(): runtime.save(state)
            (runtime.root/'tracked').write_text('reviewed candidate\n')
            git_at(runtime.root, 'add', 'tracked')
            git_at(runtime.root, 'commit', '-m', 'candidate')
            candidate = git_at(runtime.root, 'rev-parse', 'HEAD')
            state = runtime.load(item['run'])
            acceptance = {key: state[key] for key in ('repo', 'worktree', 'branch', 'run', 'task', 'platform')}
            acceptance.update(revision=candidate, evidence={'behavior': 'synthetic exact candidate; native acceptance is separate'})
            acceptance_path = runtime.base/'acceptance.json'
            acceptance_path.write_text(json.dumps(acceptance))
            with patch.object(subprocess, 'Popen', local_popen):
                assert runtime.verify(state, 'ready', candidate, acceptance_path)['ok']
            item['native_review'] = {'revision': candidate, 'fingerprint': target['rt'].fingerprint(runtime.root),
                                     'verdict': 'ship ' + candidate}
            item['quiescence'] = {'process': 'exited', 'group': 'gone', 'known_descendants': []}
            item['handoff_stage'] = 'phase_complete'
            # The fixture host/sandbox are in-process substitutes, not a native CLI installation.
            with patch.object(q, 'runtime', return_value=runtime.load(item['run'])):
                q.finish(item, 0)
            limits = copy.deepcopy(item['runtime_limits'])
            replacements, interrupted = [], []
            def replacement(current, held_lock):
                replacements.append(current['run'])
                sealed = runtime.load(current['run'])
                repair_action = json.loads(sealed['notes'])['next_action']
                assert 'git rev-parse HEAD^2' in repair_action and 'git diff HEAD^2...HEAD' in repair_action
                assert current['delivery']['repair']['base'] in repair_action
                bound = runtime.bind(sealed, current['checkpoint_hash'], 'fixture-replacement')
                current.update(session='fixture-replacement', status='running')
                q.save()
                head = git_at(runtime.root, 'rev-parse', 'HEAD')
                evidence = {key: bound[key] for key in ('repo', 'worktree', 'branch', 'run', 'task', 'platform')}
                evidence.update(revision=head, evidence={'behavior': 'fresh repaired candidate fixture'})
                acceptance_path.write_text(json.dumps(evidence))
                with patch.object(subprocess, 'Popen', local_popen):
                    assert runtime.verify(bound, 'ready', head, acceptance_path)['ok']
                current.update(native_review={'revision': head, 'fingerprint': target['rt'].fingerprint(runtime.root),
                                              'verdict': 'ship ' + head}, handoff_stage='phase_complete')
                with patch.object(q, 'runtime', return_value=runtime.load(current['run'])):
                    q.finish(current, 0)
            save = q.save
            def interrupted_save():
                save()
                if q.state['items'][0].get('handoff_stage') == 'delivery_repair_merged' and not interrupted:
                    interrupted.append(True)
                    raise SystemExit(75)  # The merge exists, but the controller has not sealed its handoff.
            with patch.object(delivery.Publisher, 'review', lambda self: self.item['native_review']), \
                 patch.object(q, 'context', replacement), patch.object(q, 'save', interrupted_save):
                # An operator pause stops before any write and stays resumable, never delivery_blocked.
                (q.base/'PAUSE').write_text('paused\n')
                try:
                    q.publication(item, lock)
                    raise AssertionError('paused publication proceeded')
                except target['rt'].Invalid as error:
                    assert 'publication paused' in str(error)
                assert item['status'] == 'paused' and not writes, (item['status'], writes)
                assert len(item['delivery']['candidates']) == 1  # Each run verifies afresh before writing.
                (q.base/'PAUSE').unlink()
                try:
                    q.publication(item, lock)
                    raise AssertionError('repair crash was not reached')
                except SystemExit as error:
                    assert error.code == 75 and runtime.load(item['run'])['attempts'] == 1
                q.state = target['rt'].read_json(q.path)
                item = q.state['items'][0]
                assert q.publication(item, lock)
                assert item['status'] == 'merged_source_pending' and item['delivery']['verified']
                assert item['delivery']['hosted_merge']['status'] == 'passed'
                assert item['delivery']['hosted_candidate']['status'] == 'not_declared'
                assert q.publication(item, lock)  # Matching remote merge is read back, never republished.
                with patch.object(delivery.Publisher, 'hosted', side_effect=ValueError('later hosted failure')):
                    try:
                        q.publication(item, lock)
                        raise AssertionError('later hosted failure accepted')
                    except target['rt'].Invalid as error:
                        assert 'later hosted failure' in str(error)
                assert item['status'] == 'merged_source_pending' and item['delivery']['verified'] is False
            assert writes == ['head', 'pull_request', 'base', 'head', 'base']
            assert replacements == [item['run']]
            assert item['runtime_limits'] == limits and item['attempts'] == 1
            assert q.state['admissions'] == 1 and q.state['launches'] == 2
            assert len(item['delivery']['candidates']) == 3 and len(item['delivery']['repairs']) == 1
            repair_merge = next(c for c in trace if c[:2] == [str(fake), 'sandbox'] and '--no-ff' in c)
            assert any(json.dumps(item['worktree'] + '/.agents') + '="write"' in v for v in repair_merge)
            assert git_at(remote, 'show', 'main:concurrent.txt') == 'preserve unrelated base work'
            assert git_at(workspace, 'rev-parse', 'HEAD') == revision
            assert git_at(remote, 'show', 'main:BACKLOG.md') == source.strip()
        before = len(trace)
        git_config = workspace/'.git/config'
        git_config.write_text(git_config.read_text()+'\n[core]\nfsmonitor = /unapproved\n')
        refused(lambda: target['queue'].Queue(manifest), 'protected delivery metadata changed')
        assert len(trace) == before  # Refusal precedes Git even on restart.
print('PASS: real preparation, lease race, bounded repair/restart, exact merge readback and source preservation (sandbox/GitHub/native observations substituted)')
