#!/usr/bin/env python3
"""LC-030 stage: one project.json becomes an admitted template, rendered skill and planned mission.

Fake GitHub, fake toolchain and a fake native home; the real binding, plan and init checks judge the output.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('launch_stage', ROOT / 'skills/onboard/scripts/launch-stage.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
rt, delivery, mission = s.rt, s.delivery, s.mission
parity = runpy.run_path(str(ROOT / 'skills/onboard/scripts/codex-parity.py'))


def refused(callback, phrase):
    try:
        callback()
    except Exception as error:  # launch-go loads its own runtime copy, so its Invalid is a sibling class.
        if not isinstance(error, ValueError) and type(error).__name__ != 'Invalid':
            raise
        assert phrase in str(error), (phrase, str(error))
        return
    raise AssertionError('accepted: ' + phrase)


def executable(path, text='#!/bin/sh\nexit 0\n'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


# 1. Deterministic renderer: the shipped templates, the conditional grammar the validator uses.
assert s.render_flags('a{{#if X}}b{{#unless Y}}c{{/unless}}{{/if}}d', {'X': True}) == 'abcd'
assert s.render_flags('a{{#if X}}b{{/if}}{{#unless X}}e{{/unless}}d', {}) == 'aed'
refused(lambda: s.render_flags('{{#if X}}b{{/unless}}', {}), 'mismatched unless conditional')
refused(lambda: s.render_flags('{{#if X}}b', {}), 'unclosed if conditional')
with tempfile.TemporaryDirectory() as temporary:
    out = Path(temporary) / 'rendered'
    values = s.skill_values('main', ['true'], [])
    s.render(out / 'skills/launch', *values)
    names = sorted(str(p.relative_to(out / 'skills/launch')) for p in out.rglob('*') if p.is_file())
    assert names == ['SKILL.md', 'references/delivery.md', 'references/implementation.md',
                     'references/ticket-intake.md', 'references/verification.md'], names
    texts = [p.read_text() for p in out.rglob('*.md')]
    assert not any('{{' in t or 'MODEL_INSERT' in t for t in texts)
    assert '`true`' in (out / 'skills/launch/SKILL.md').read_text()
    parity['native_launch_bundle'](out)  # The generator accepts the tree: native supervised recovery routing present.
    strict = dict(values[0]); strict.pop('BASE_BRANCH')
    refused(lambda: s.render(Path(temporary) / 'again', strict, *values[1:]), 'unresolved template value BASE_BRANCH')
assert s.NPM_TOOL.fullmatch('pnpm@10.33.2').groups() == ('pnpm', '10.33.2')
assert s.NPM_TOOL.fullmatch('@openai/codex@0.162.0').groups() == ('@openai/codex', '0.162.0')
assert s.NPM_TOOL.fullmatch('/opt/homebrew/opt/python@3.14/bin/python3.14') is None and s.NPM_TOOL.fullmatch('uv') is None
assert s.shipped(s.ONBOARD / 'scripts/launch-runtime.py') and not s.shipped(s.ONBOARD / 'scripts/__pycache__/x.pyc')
assert not s.shipped(s.ONBOARD / '.DS_Store') and not s.shipped(s.ONBOARD / 'references/.x.swp')
print('PASS: deterministic launch renderer: conditionals, loops, strict values, generator-accepted tree')

# 2. Full stage over fakes; the real load_binding, plan and init dry run judge what it wrote.
# T-2 ranks higher but waits on T-1: mission order is priority order; the run holds T-2 until T-1 is Done.
SECTION = '## Run\n| ID | Item | Status | Tier | Depends on |\n|---|---|---|---|---|\n' \
          '| T-0 | shipped | Done | P1 | none |\n| T-1 | first {x} | Todo | P2 | T-0 |\n| T-2 | second | Todo | P1 | T-1 |\n'
BASE = 'c' * 40
FILES = {'BACKLOG.md': '# Backlog\n\n' + SECTION, 'sub/manifest.txt': 'm\n', 'sub/lock.txt': 'lock\n',
         'py/pyproject.toml': '[project]\n', 'py/uv.lock': 'uv\n'}


def github(endpoint):
    if endpoint == 'repos/o/r/commits/main':
        return {'sha': BASE}
    if endpoint.startswith('repos/o/r/git/blobs/'):
        raw = next(v.encode() for v in FILES.values() if delivery.git_blob(v.encode()) == endpoint.rsplit('/', 1)[1])
        return {'encoding': 'base64', 'content': base64.b64encode(raw).decode(), 'sha': delivery.git_blob(raw)}
    path, ref = endpoint.split('/contents/', 1)[1].split('?ref=')
    assert ref == BASE, endpoint
    raw = FILES[path].encode()
    if path == 'py/uv.lock':  # Over 1 MB: no inline content.
        return {'type': 'file', 'encoding': 'none', 'content': '', 'sha': delivery.git_blob(raw)}
    return {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(raw).decode(), 'sha': delivery.git_blob(raw)}


with tempfile.TemporaryDirectory(prefix='launch-stage-') as temporary:
    base = Path(temporary).resolve()
    home, tools, pins, project = base / 'home', base / 'tools', base / 'pins', base / 'project'
    code = home / '.codex'
    code.mkdir(parents=True)
    agent = code / 'agents/helper.toml'
    agent.parent.mkdir()
    agent.write_text('model = "x"\n')
    (code / 'config.toml').write_text('model = "fixture"\n[mcp_servers.demo]\ncommand = "x"\n[agents.helper]\nconfig_file = "%s"\n' % agent)
    hook = executable(home / 'bin/hook.sh')
    relative = "sh '%s' session" % hook  # A bare interpreter resolves through the final canonical host PATH.
    (code / 'hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': str(hook)}]}],
                                                           'SessionStart': [{'hooks': [{'type': 'command', 'command': relative}]}]}}))
    fakes = {name: executable(tools / 'bin' / name) for name in ('python', 'git', 'gh', 'codex')}
    interpreter = executable(tools / 'py-install/bin/python3')
    (tools / 'py-install/lib/python3.12').mkdir(parents=True)
    (tools / 'py-install/lib/python3.12/os.py').write_text('')  # A real install has a stdlib.
    # A venv build records its base interpreter; the stage must admit that install root for reads.
    venv = "import os; os.makedirs('.venv/bin'); os.symlink(%r, '.venv/bin/python'); open('.venv/pyvenv.cfg', 'w').write('home = %s\\n')" % (str(interpreter), str(interpreter.parent))
    toolchain = {**{k: str(v) for k, v in fakes.items()}, 'path': [str(tools / 'bin'), '/usr/bin', '/usr/bin'], 'read_roots': [str(tools)],
                 'pinned': [str(v) for v in fakes.values()]}

    def pin(name, version):  # npm-pinned build tool, also put on the worker PATH.
        root = pins / (name + '-' + version)
        executable(root / 'node_modules/.bin' / name, '#!/bin/sh\nmkdir tree && cp lock.txt tree/copied\n')
        return root

    config = {'repository': 'o/r', 'base_branch': 'main', 'source': {'path': 'BACKLOG.md', 'heading': '## Run'},
              'checks': [{'command': 'true', 'cwd': '.', 'timeout': 30}, {'command': 'make check', 'cwd': 'sub', 'timeout': 60}],
              'acceptance': ['behavior', 'independent-review'],
              'dependencies': [{'cwd': 'sub', 'manifest': 'manifest.txt', 'lockfile': 'lock.txt', 'build': ['fake@1.0', 'install'], 'target': 'tree'},
                               {'cwd': 'py', 'manifest': 'pyproject.toml', 'lockfile': 'uv.lock', 'build': [sys.executable, '-c', venv], 'target': '.venv'}],
              'publication': {'required_checks': [{'name': 'ci', 'app_id': 7}], 'billing_fallback': True},
              'caps': {'minutes': 120, 'max_attempts': 4, 'max_launches': 4, 'max_tokens': 1000,
                       'task_minutes': 30, 'task_max_attempts': 2, 'task_max_launches': 2}}
    project.mkdir()
    (project / 'project.json').write_text(json.dumps(config))
    with patch.dict(os.environ, {'HOME': str(home), 'CODEX_HOME': str(code)}), \
         patch.object(delivery.platform, 'system', return_value='Darwin'), \
         patch.object(s, 'toolchain', return_value=toolchain), patch.object(s, 'pin', side_effect=pin):
        summary = s.stage(project / 'project.json', github)
        out = project / 'stage'
        assert summary['tasks'] == ['T-2', 'T-1'] and summary['skipped'] == [], summary
        assert summary['digest'] == rt.digest((out / 'mission.json').read_bytes())
        grant_path = out / 'template-grant.json'
        admitted = delivery.load_binding({'grant': str(grant_path), 'digest': rt.digest(grant_path.read_bytes())})
        host, grant = admitted['host'], admitted['grant']
        policy = json.loads((out / 'template-policy.json').read_text())
        assert grant['target_digest'] == delivery.target_digest(policy) and grant['base_revision'] == policy['base_revision'] == BASE
        assert grant['source']['blob'] == delivery.git_blob(FILES['BACKLOG.md'].encode())
        assert grant['publication'] == {'mode': 'github-base-lease', 'deployment': 'none', 'required_checks': [{'name': 'ci', 'app_id': 7}],
                                        'post_merge_checks': [], 'billing_fallback': True}
        assert grant['verification'] == {'schema': 1, 'checks': config['checks'], 'acceptance': config['acceptance']}
        assert json.loads((out / 'verify.json').read_text()) == grant['verification']
        assert (out / 'commands.txt').read_text() == 'true\ncd sub && make check\n'
        deps = {d['target']: d for d in grant['dependencies']}
        assert set(deps) == {'sub/tree', 'py/.venv'} and deps['sub/tree']['lockfile'] == 'sub/lock.txt'
        assert deps['sub/tree']['digest'] == delivery.tree_digest(out / 'deps/0/sub/tree')
        assert (out / 'deps/0/sub/tree/copied').read_text() == 'lock\n', 'built from the base lockfile'
        assert deps['py/.venv']['lock_digest'] == hashlib.sha256(b'uv\n').hexdigest()
        assert str(tools / 'py-install') in host['read_roots'], 'venv base interpreter root admitted'
        assert str(out / 'deps') in host['read_roots'], 'venv metadata may point back at the build directory'
        assert str(pins / 'fake-1.0/node_modules/.bin') in host['path'] and str(pins / 'fake-1.0') in host['read_roots']
        system_path = [str(Path(p).resolve()) for p in ('/usr/bin', '/bin')]
        assert host['path'] == list(dict.fromkeys([*toolchain['path'], str(pins / 'fake-1.0/node_modules/.bin'), *system_path]))
        assert all(not Path(p).is_symlink() and str(Path(p).resolve()) == p for p in host['path'])
        sh = str(Path('/bin/sh').resolve())
        assert host['hook_commands'] == {str(hook): sorted([str(hook), sh]), relative: sorted([sh, str(hook)])}, host['hook_commands']
        assert host['native_overrides'] == ['mcp_servers.demo.enabled=false'] and str(agent) in host['files']
        for pinned in (ROOT / 'skills/onboard/scripts/launch-runtime.py', out / 'rendered/skills/launch/SKILL.md', out / 'verify.json',
                       out / 'commands.txt', pins / 'fake-1.0/node_modules/.bin/fake'):
            assert str(pinned) in host['files'], pinned
        onboard = ROOT / 'skills/onboard'
        reference = str(onboard / 'references/launch-autonomy.md')
        assert reference in host['read_files'] and str(onboard) in host['read_roots']
        argv = policy['generator']['argv']
        controller = onboard / 'scripts/launch-runtime.py'
        assert argv[argv.index('--autonomy-controller') + 1] == str(controller)
        assert argv[argv.index('--autonomy-controller-digest') + 1] == hashlib.sha256(controller.read_bytes()).hexdigest()
        parity['native_launch_bundle'](Path(argv[argv.index('--source') + 1]))
        planned = json.loads((out / 'mission.json').read_text())
        assert all(reference + mission.ROW in t['scope_template'] for t in planned['tasks'])
        assert planned['tasks'][1]['scope_template'].endswith('first {{x}}')
        dry = mission.Mission(base / 'mission', reader=github).init(out / 'mission.json', summary['digest'], dry_run=True)
        assert dry['tasks'] == ['T-2', 'T-1'] and dry['allowed_actions'] == grant['allowed_actions']
        refused(lambda: s.stage(project / 'project.json', github), 'stage already exists')
        (base / 'bad').mkdir()
        (base / 'bad/project.json').write_text(json.dumps({**config, 'scope': 'widen'}))
        refused(lambda: s.stage(base / 'bad/project.json', github), 'invalid project config')
        (base / 'bad/project.json').write_text(json.dumps({**config, 'publication': {**config['publication'], 'deployment': 'production'}}))
        refused(lambda: s.stage(base / 'bad/project.json', github), 'invalid project config')  # Never silently dropped.
        (base / 'bad2').mkdir()
        (base / 'bad2/project.json').write_text(json.dumps({**config, 'source': {'path': 'BACKLOG.md', 'heading': '## Missing'}}))
        with patch.object(s, 'toolchain', side_effect=AssertionError('built before the section was checked')):
            refused(lambda: s.stage(base / 'bad2/project.json', github), 'selected heading must be unique')
        assert not (base / 'bad2/stage').exists(), 'a refused config leaves no stage behind'
        (base / 'bad3').mkdir()
        (base / 'bad3/project.json').write_text(json.dumps({**config, 'dependencies': [{**config['dependencies'][1], 'build': ['true']}]}))
        refused(lambda: s.stage(base / 'bad3/project.json', github), 'dependency build produced no tree: py/.venv')
        assert not (base / 'bad3/stage').exists(), 'a failed stage is removed, so a retry needs no manual cleanup'
        dep = config['dependencies'][1]
        for bad in ({**dep, 'cwd': '/abs'}, {**dep, 'cwd': '..'}, {**dep, 'cwd': 'a/../b'}, {**dep, 'manifest': 'x/pyproject.toml'},
                    {**dep, 'lockfile': dep['manifest']}, {**dep, 'target': '.git'}, {**dep, 'cwd': 'sub'}):
            (base / 'bad3/project.json').write_text(json.dumps({**config, 'dependencies': [config['dependencies'][0], bad]}))
            refused(lambda: s.stage(base / 'bad3/project.json', github), 'invalid project config')
        assert not (base / 'bad3/stage').exists()
        (base / 'bad3/project.json').write_text(json.dumps(config))
        for broad in ('/usr/local', '/Library'):  # A python.org or /usr/local layout must fail closed, never admit the parent.
            with patch.object(s, 'toolchain', return_value={**toolchain, 'read_roots': [str(tools), broad]}):
                refused(lambda: s.stage(base / 'bad3/project.json', github), 'derived host path too broad: ' + broad)
        linked = tools / 'linked-bin'
        linked.symlink_to(tools / 'bin', target_is_directory=True)
        refused(lambda: delivery.checked_path(str(linked)), 'unsafe state path: ' + str(linked))
        with patch.object(s, 'toolchain', return_value={**toolchain, 'path': [str(linked)]}):
            refused(lambda: s.stage(base / 'bad3/project.json', github), 'unsafe state path: ' + str(linked))
        assert not (base / 'bad3/stage').exists(), 'unsafe toolchain paths are refused, never canonicalized away'
        stray = executable(base / 'elsewhere/bin/python3')
        planted = venv.replace(repr(str(interpreter)), repr(str(stray)))
        (base / 'bad3/project.json').write_text(json.dumps({**config, 'dependencies': [{**dep, 'build': [sys.executable, '-c', planted]}]}))
        refused(lambda: s.stage(base / 'bad3/project.json', github), 'venv interpreter outside its recorded home')
        # Build output names the root: it must be an existing Python install, never an arbitrary directory.
        for target, label in ((base / 'nowhere/bin/python3', 'dangling'), (stray, 'no stdlib')):
            planted = venv.replace(repr(str(interpreter)), repr(str(target))).replace('home = ' + str(interpreter.parent), 'home = ' + str(target.parent))
            (base / 'bad3/project.json').write_text(json.dumps({**config, 'dependencies': [{**dep, 'build': [sys.executable, '-c', planted]}]}))
            refused(lambda: s.stage(base / 'bad3/project.json', github), 'venv interpreter is not a Python install')
        assert not (base / 'bad3/stage').exists()
        with patch.object(sys, 'argv', ['launch-stage.py', '--config', str(base / 'absent/project.json')]):
            assert s.main() == 2, 'a missing file is a reported error, not a traceback'
        with patch.object(sys, 'argv', ['launch-stage.py', '--config', str(base / 'bad3/project.json')]), \
             patch.object(s, 'gh_api', github), patch.dict(os.environ, {'CODEX_HOME': str(base / 'empty')}):
            (base / 'bad3/project.json').write_text(json.dumps(config))
            assert s.main() == 2, 'no native config.toml: reported, not a traceback'
        FILES['BACKLOG.md'] += 'tampered\n'
        honest = github
        github = lambda endpoint: {**honest(endpoint), 'sha': '0' * 40} if 'BACKLOG' in endpoint else honest(endpoint)
        (base / 'bad4').mkdir()
        (base / 'bad4/project.json').write_text(json.dumps(config))
        refused(lambda: s.stage(base / 'bad4/project.json', github), 'base file does not match its blob: BACKLOG.md')
print('PASS: stage writes an admitted template, derived host policy, base-built trees and a plan init accepts')

# 3. launch-go: one confirmation, or resume the mission in progress; never restage, never reset limits.
github = honest  # Section 2 left the tampering reader bound.
spec = importlib.util.spec_from_file_location('launch_go', ROOT / 'skills/onboard/scripts/launch-go.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
with tempfile.TemporaryDirectory(prefix='launch-go-') as temporary:
    base = Path(temporary).resolve()
    home, tools, pins, project = base / 'home', base / 'tools', base / 'pins', base / 'project'
    code = home / '.codex'
    code.mkdir(parents=True)
    (code / 'config.toml').write_text('model = "fixture"\n')
    fakes = {name: executable(tools / 'bin' / name) for name in ('python', 'git', 'gh', 'codex')}
    toolchain = {**{k: str(v) for k, v in fakes.items()}, 'path': [str(tools / 'bin')], 'read_roots': [str(tools)],
                 'pinned': [str(v) for v in fakes.values()]}
    project.mkdir()
    (project / 'project.json').write_text(json.dumps({**config, 'dependencies': []}))
    runs, out = [], []
    fake_run = lambda self: runs.append(self.root) or {'outcome': 'complete'}
    go = lambda **kw: g.go(project / 'project.json', github=github, reader=github, say=out.append, **kw)
    with patch.dict(os.environ, {'HOME': str(home), 'CODEX_HOME': str(code)}), \
         patch.object(delivery.platform, 'system', return_value='Darwin'), \
         patch.object(g.stage, 'toolchain', return_value=toolchain), patch.object(g.mission.Mission, 'run', fake_run), \
         patch.object(sys.stdin, 'isatty', return_value=False):
        refused(lambda: go(), 'confirmation required: rerun with --approve')
        digest = rt.digest((project / 'stage/mission.json').read_bytes())
        assert json.loads(out[-1])['tasks'] == ['T-2', 'T-1'], 'the dry-run summary is shown before asking'
        assert go(stage_only=True) == {'outcome': 'staged', 'digest': digest} and not runs, '/mission stage only stages'
        assert json.loads(out[-1])['tasks'] == ['T-2', 'T-1'] and not (project / 'mission/mission.json').exists()
        refused(lambda: go(approve='0' * 64), 'not approved')
        assert not (project / 'mission/mission.json').exists() and not runs, 'nothing starts without the confirmation'
        with patch.object(g.stage, 'stage', side_effect=AssertionError('restaged')):  # The unconfirmed stage is reused.
            with patch.object(sys.stdin, 'isatty', return_value=True):
                refused(lambda: go(ask=lambda prompt: 'n'), 'not approved')
                # The file confirmed is the file init reads: a swap during the prompt fails closed.
                planned_raw = (project / 'stage/mission.json').read_bytes()
                swap = lambda prompt: ((project / 'stage/mission.json').write_bytes(planned_raw.replace(b'"T-2"', b'"T-2" ', 1)), 'y')[1]
                refused(lambda: go(ask=swap), 'mission file digest differs from the approved digest')
                (project / 'stage/mission.json').write_bytes(planned_raw)
                assert not (project / 'mission/mission.json').exists()
                edited = json.loads((project / 'project.json').read_text())
                (project / 'project.json').write_text(json.dumps({**edited, 'caps': {**edited['caps'], 'max_tokens': 5}}))
                refused(lambda: go(ask=lambda prompt: 'y'), 'project.json changed since staging')
                (project / 'project.json').write_text(json.dumps(edited))
                assert go(ask=lambda prompt: digest[:12] in prompt and 'y') == {'outcome': 'complete'}
            assert runs == [project / 'mission'] and rt.read_json(project / 'mission/mission.json')['mission_digest'] == digest
            state = rt.read_json(project / 'mission/mission.json')
            (project / 'mission/PAUSE').write_text('paused\n')
            rt.atomic(project / 'mission/mission.json', {**state, 'outcome': 'paused', 'reason': 'operator pause'})
            refused(lambda: go(stage_only=True), 'a mission already exists')  # Staging never resumes a held mission.
            assert (project / 'mission/PAUSE').exists() and len(runs) == 1
            assert go() == {'outcome': 'complete'} and len(runs) == 2, 'a paused mission resumes with run, no confirmation'
            assert not (project / 'mission/PAUSE').exists()
            assert rt.read_json(project / 'mission/mission.json')['deadline'] == state['deadline'], 'limits never reset'
            # A live run holds the lock: a second go must not lift the operator's pause under it.
            import fcntl
            (project / 'mission/PAUSE').write_text('paused\n')
            with (project / 'mission/mission.lock').open('a') as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                refused(lambda: go(), 'mission already running')
            assert (project / 'mission/PAUSE').exists() and len(runs) == 2
            for outcome in ('active', 'error', 'publication_pending'):  # Resumable: run reconciles the reserved task.
                rt.atomic(project / 'mission/mission.json', {**state, 'outcome': outcome})
                go()
            assert len(runs) == 5
            rt.atomic(project / 'mission/mission.json', {**state, 'outcome': 'complete'})
            assert go()['outcome'] == 'complete' and len(runs) == 5, 'a finished mission is reported, not rerun'
            rt.atomic(project / 'mission/mission.json', {**state, 'outcome': 'merged_source_pending', 'reason': 'T-1 merged'})
            refused(lambda: go(), 'mark its source row Done by hand')  # Never while Todo: that would deliver it again.
            rt.atomic(project / 'mission/mission.json', {**state, 'outcome': 'blocked', 'reason': 'base drift: x'})
            refused(lambda: go(approve=digest), 'mission ended blocked: base drift: x')
            assert len(runs) == 5
print('PASS: launch-go confirms once, reuses an unconfirmed stage, resumes active or paused missions, refuses ended ones')

# An installed pin is reused from ~/.local/share/launch-control, never re-downloaded.
with tempfile.TemporaryDirectory(prefix='launch-tools-home-') as temporary:
    home = Path(temporary)
    package = home / '.local/share/launch-control/codex-1.0.0/node_modules/@openai/codex/package.json'
    package.parent.mkdir(parents=True)
    package.write_text(json.dumps({'version': '1.0.0'}))
    with patch.dict(os.environ, {'HOME': str(home)}), patch.object(s.subprocess, 'run', side_effect=AssertionError('re-downloaded')):
        assert s.pin('@openai/codex', '1.0.0') == home / '.local/share/launch-control/codex-1.0.0'
print('PASS: an installed pinned tool is reused')
