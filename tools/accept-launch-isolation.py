#!/usr/bin/env python3
"""Installed acceptance: the real `codex sandbox` denies delivery processes what they were not granted.

Not a validate-pack gate: it needs macOS, the pinned Codex 0.162.0 and this host's toolchain.
Each surface uses the production permission map and environment; every credential probe
reports only success or failure, never output, so a sandbox that fails open prints no secret.
Exit 0 all pass, 1 any probe failed, 2 not run or a denial unproven.
"""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1] / 'skills/onboard/scripts'


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROBE = r'''
import json, os, socket, subprocess, sys
probes = json.load(open(PROBES))
result = {}
for name, kind, arg in probes:
    try:
        if kind == 'read':
            open(arg, 'rb').read(1)
        elif kind == 'list':
            os.listdir(arg)
        elif kind == 'write':
            open(arg, 'ab').close()
        elif kind == 'connect':
            socket.create_connection(('127.0.0.1', int(arg)), 2).close()
        elif kind == 'exec':
            if subprocess.run(arg, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode != 0:
                raise OSError('exit')
        elif kind == 'env':
            if arg not in os.environ:
                raise KeyError(arg)
        result[name] = True
    except Exception:
        result[name] = False
print(json.dumps(result))
'''


def main():
    if platform.system() != 'Darwin':
        print('NOT RUN: macOS seatbelt required')
        return 2
    stage, delivery = load('launch-stage'), load('launch-delivery')
    try:
        tools = stage.toolchain()
    except Exception as error:  # Missing pinned Codex or Xcode tools: not a pass.
        print('NOT RUN: toolchain unavailable: ' + str(error)[:200])
        return 2
    real_home = Path.home()
    runs = real_home / '.codex/visualizations'
    created = not runs.exists()
    runs.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='lc031-isolation-', dir=runs)).resolve()
    stray = []
    try:
        return run(root, real_home, tools, delivery, stray)
    finally:
        shutil.rmtree(root, ignore_errors=True)
        for path in stray:
            path.unlink(missing_ok=True)
        if created:
            runs.rmdir()


def run(root, real_home, tools, delivery, stray):
    git = tools['git']
    def sh(*args, cwd=None):
        subprocess.run(args, cwd=cwd, check=True, capture_output=True)

    # Production-shaped clone: workspace, prepared worktree, queue state, authority beside it.
    workspace, authority, sibling, fake_home = root / 'worker', root / 'authority', root / 'sibling', root / 'fake-home'
    for path in (authority, sibling, fake_home / '.config/gh', fake_home / '.ssh', fake_home / 'codex'):
        path.mkdir(parents=True)
    sh(git, 'init', '-q', '-b', 'main', str(workspace))
    (workspace / 'tracked').write_text('fixture\n')
    sh(git, '-C', str(workspace), 'add', 'tracked')
    sh(git, '-C', str(workspace), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
       'commit', '-q', '-m', 'fixture')
    worktree = workspace / '.git/launch-prepared/t-1'
    sh(git, '-C', str(workspace), 'worktree', 'add', '-q', '-b', 'launch/t-1', str(worktree))
    queue = workspace / '.git/launch-queue'
    queue.mkdir()
    (queue / 'active.json').write_text('{"status": "running"}\n')
    token = 'ghp_FAKE' + 'x' * 32
    (sibling / 'secret.txt').write_text('sibling secret\n')
    (fake_home / '.config/gh/hosts.yml').write_text('github.com:\n    oauth_token: ' + token + '\n')
    (fake_home / '.ssh/id_ed25519').write_text('-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n')
    (fake_home / 'codex/auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'sk-fake'}))
    descriptor, temp_secret = tempfile.mkstemp(prefix='lc031-secret-')
    os.close(descriptor)
    temp_secret = Path(temp_secret).resolve()
    stray.append(temp_secret)
    config = authority / 'verify.json'
    config.write_text('{}')

    grant_path = authority / 'grant.json'
    grant = {'workspace': str(workspace), 'repository': 'fixture/repo', 'base_branch': 'main'}
    grant_path.write_text(json.dumps(grant))
    binding = {'grant': str(grant_path), 'digest': hashlib.sha256(grant_path.read_bytes()).hexdigest()}
    sealed = authority / 'sealed'
    sealed.write_text('sealed\n')
    (authority / 'delivery-preparation.json').write_text(json.dumps({
        'grant_digest': binding['digest'], 'workspace': str(workspace), 'status': 'prepared',
        'worktree': str(worktree), 'files': {str(sealed): hashlib.sha256(sealed.read_bytes()).hexdigest()}}))
    host = {'codex': tools['codex'], 'git': git, 'python': tools['python'], 'gh': tools['gh'],
            'path': list(dict.fromkeys(tools['path'] + ['/usr/bin', '/bin'])),
            'read_roots': tools['read_roots'], 'read_files': [str(config)]}
    admitted = {'host': host, 'grant': grant, 'binding': binding}

    # Inert endpoint: anything that reaches it is a network escape.
    # Completed connections wait in the backlog until drained, so nothing races the probes.
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(128)
    port = listener.getsockname()[1]
    def drain():
        count = 0
        listener.settimeout(0.5)
        while True:
            try:
                listener.accept()[0].close()
                count += 1
            except socket.timeout:
                return count

    home_write = real_home / ('lc031-probe-' + str(os.getpid()))
    stray.append(home_write)
    denied = [
        ('read sibling secret', 'read', str(sibling / 'secret.txt')),
        ('read fake gh token', 'read', str(fake_home / '.config/gh/hosts.yml')),
        ('read fake ssh key', 'read', str(fake_home / '.ssh/id_ed25519')),
        ('read fake codex auth', 'read', str(fake_home / 'codex/auth.json')),
        ('read grant authority', 'read', str(grant_path)),
        ('read secret in TMPDIR', 'read', str(temp_secret)),
        ('open real gh hosts.yml', 'read', str(real_home / '.config/gh/hosts.yml')),
        ('open real codex auth.json', 'read', str(real_home / '.codex/auth.json')),
        ('list real ~/.ssh', 'list', str(real_home / '.ssh')),
        ('write sibling', 'write', str(sibling / 'written')),
        ('write fake home', 'write', str(fake_home / 'written')),
        ('write real home', 'write', str(home_write)),
        ('write queue state', 'write', str(queue / 'active.json')),
        ('connect inert endpoint', 'connect', str(port)),
        ('gh auth token', 'exec', [tools['gh'], 'auth', 'token']),
        ('keychain gh item', 'exec', ['/usr/bin/security', 'find-generic-password', '-s', 'gh:github.com']),
        ('env GH_TOKEN', 'env', 'GH_TOKEN'),
        ('env HOME', 'env', 'HOME'),
    ]
    # Exec controls: the same binaries run inside the sandbox, so their credential denials are real.
    granted = [('read worktree file', 'read', str(worktree / 'tracked')),
               ('run gh in sandbox', 'exec', [tools['gh'], '--version']),
               ('run security in sandbox', 'exec', ['/usr/bin/security', 'help'])]
    writable = [('write worktree', 'write', str(worktree / 'probe-written'))]

    def script(at, probes):
        """Probe files live inside a granted root so the sandboxed interpreter can load them."""
        (at / 'probes.json').write_text(json.dumps(probes))
        (at / 'probe.py').write_text('PROBES = ' + repr(str(at / 'probes.json')) + '\n' + PROBE)
        return at / 'probe.py'

    def sandboxed(cwd, permissions, argv, env):
        result = delivery.run_owned(delivery.sandbox_command(admitted, cwd, permissions, argv, env),
                                    cwd, delivery.host_environment(admitted), timeout=120)
        if result.returncode != 0:
            raise RuntimeError('probe process failed: ' + result.stderr.decode(errors='replace')[:300])
        return json.loads(result.stdout)

    results = {}
    with patch.dict(os.environ, {'GH_TOKEN': token}):
        probe = script(worktree, denied + granted + writable)
        # Declared checks: bind_runtime's check_command.
        results['worker check'] = (sandboxed(worktree, delivery.filesystem(admitted), [host['python'], '-I', str(probe)],
                                             delivery.tool_environment(admitted)), granted + writable)
        # Hook inner stage: the real run_hook, with the parent's GH_TOKEN in its environment.
        out = io.StringIO()
        with patch.object(delivery, 'load_binding', return_value=admitted), \
             patch.dict(os.environ, {'LAUNCH_RUN_ID': 'fixture-run'}), \
             patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'{}'))), redirect_stdout(out):
            delivery.run_hook(binding, str(workspace), 'import runpy; runpy.run_path(' + repr(str(probe)) + ')')
        results['hook'] = (json.loads(out.getvalue()), granted + writable)
        # Restricted Git: the git_filesystem map, probed through a shell alias.
        git_result = delivery.restricted_git(admitted, worktree, delivery.filesystem(admitted),
                                             '-c', 'alias.probe=!' + host['python'] + ' -I ' + str(probe), 'probe')
        results['restricted git'] = (json.loads(git_result.stdout), granted + writable)
        # Independent verifier: verify_snapshot's map on a separate clone; the worker clone is a sibling.
        verifier = root / 'verification/repo'
        sh(git, 'clone', '-q', '--no-hardlinks', str(workspace), str(verifier))
        (verifier / '.git/launch/tmp').mkdir(parents=True)
        vprobe = script(verifier, [*denied, ('read worker clone', 'read', str(workspace / 'tracked')),
                                   ('read verifier file', 'read', str(verifier / 'tracked')),
                                   ('write verifier clone', 'write', str(verifier / 'probe-written')), *granted[1:]])
        reads = {name: 'read' for name in [*host['read_roots'], *host['read_files']]}
        permissions = {**reads, str(verifier): 'write', str(verifier / '.git'): 'read',
                       str(verifier / '.git/launch'): 'write', str(config): 'read'}
        results['verifier'] = (sandboxed(verifier, permissions, [host['python'], '-I', str(vprobe)],
                                         {**delivery.tool_environment(admitted), 'TMPDIR': str(verifier / '.git/launch/tmp')}),
                               [('read verifier file',), ('write verifier clone',), *granted[1:]])
        token_visible = os.environ.get('GH_TOKEN') == token

    escaped = drain()
    # Positive controls outside the sandbox: the targets exist and the endpoint answers.
    def quiet(argv):
        return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    socket.create_connection(('127.0.0.1', port), 2).close()
    reached = drain()
    listener.close()
    wrote_home = home_write.exists()
    if not wrote_home:
        home_write.write_text('control\n')
    controls = {'sibling secret readable unsandboxed': (sibling / 'secret.txt').read_text() == 'sibling secret\n',
                'inert endpoint reachable unsandboxed': reached == 1,
                'GH_TOKEN visible to the parent during probes': token_visible,
                'HOME passed to the controller': 'HOME' in delivery.host_environment(admitted),
                'real home writable unsandboxed': not wrote_home and home_write.read_text() == 'control\n'}
    home_write.unlink()
    # Real targets may be absent on a host; a denial of something absent proves nothing, so say so.
    unproven = {'open real gh hosts.yml': (real_home / '.config/gh/hosts.yml').is_file(),
                'open real codex auth.json': (real_home / '.codex/auth.json').is_file(),
                'list real ~/.ssh': (real_home / '.ssh').is_dir(),
                'gh auth token': quiet([tools['gh'], 'auth', 'token']),
                'keychain gh item': quiet(['/usr/bin/security', 'find-generic-password', '-s', 'gh:github.com'])}

    failed = unproved = 0
    for surface, (observed, expected) in results.items():
        allowed = {probe[0] for probe in expected}
        for name, ok in sorted(observed.items()):
            good = ok if name in allowed else not ok
            failed += not good
            label = 'PASS' if good else 'FAIL'
            if good and not unproven.get(name, True):
                label = 'UNPROVEN (absent unsandboxed)'
                unproved += 1
            print(label + ': ' + surface + ': ' + name + (' allowed' if ok else ' denied'))
    for name, ok in controls.items():
        failed += not ok
        print(('PASS' if ok else 'FAIL') + ': control: ' + name)
    failed += escaped != 0
    print(('PASS' if escaped == 0 else 'FAIL') + ': inert endpoint saw %d sandboxed connection(s)' % escaped)
    if wrote_home:
        print('FAIL: a sandboxed process wrote ' + str(home_write))
        failed += 1
    print('%d failure(s), %d unproven' % (failed, unproved))
    return 1 if failed else 2 if unproved else 0


if __name__ == '__main__':
    sys.exit(main())
