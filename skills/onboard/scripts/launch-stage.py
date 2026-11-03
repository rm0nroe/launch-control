#!/usr/bin/env python3
"""Stage a Launch mission from one operator project.json: no hard-coded paths, no per-task text.

Writes <config dir>/stage/ once: the rendered launch skill, verify.json, commands.txt, dependency
trees built from the base lockfiles, the host policy, the template policy and grant, and the
planned mission. Prints the mission summary and digest; approving that digest with
`launch-mission.py init` is the operator's one confirmation. The pack this script lives in is the
reviewed pack every worker runs. Spec: LC-030 backlog target (the maintainers' private design record).
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib
from urllib.parse import quote

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ONBOARD = HERE.parent
_spec = importlib.util.spec_from_file_location('launch_mission', HERE / 'launch-mission.py')
mission = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mission)
rt, queue, delivery, require = mission.rt, mission.queue, mission.delivery, mission.require
CODEX = ('@openai/codex', '0.162.0')  # The only version load_binding admits.
TEMPLATES = {'SKILL.md': 'launch-template.md', 'references/ticket-intake.md': 'launch-ticket-intake-template.md',
             'references/implementation.md': 'launch-implementation-template.md',
             'references/delivery.md': 'launch-delivery-template.md', 'references/verification.md': 'launch-verification-template.md'}
TAG = re.compile(r'\{\{#(if|unless) ([A-Z0-9_]+)\}\}|\{\{/(if|unless)\}\}')
NPM_TOOL = re.compile(r'((?:@[\w.-]+/)?[\w.-]+)@(\d[\w.+-]*)')  # `pnpm@10.33.2`: an npm name, never a path.
digest = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()


def render_flags(source, flags):
    """Same grammar as renderFlags in tools/validate/15-launch-contract.sh."""
    def walk(cursor, stop):
        output = []
        while True:
            match = TAG.search(source, cursor)
            if not match:
                require(stop is None, 'unclosed %s conditional' % stop)
                return ''.join(output) + source[cursor:], len(source)
            output.append(source[cursor:match.start()])
            if match[3]:
                require(match[3] == stop, 'mismatched %s conditional' % match[3])
                return ''.join(output), match.end()
            body, cursor = walk(match.end(), match[1])
            if (match[1] == 'if') == bool(flags.get(match[2])):
                output.append(body)
    return walk(0, None)[0]


def render(out, values, lists, flags):
    """Deterministic launch skill tree: every surviving placeholder needs an explicit value."""
    def value(match):
        require(match[1] in values, 'unresolved template value ' + match[1])
        return values[match[1]]
    for name, template in TEMPLATES.items():
        text = re.sub(r'^<!--[\s\S]*?-->\s*', '', render_flags((ONBOARD / 'references' / template).read_text(), flags), count=1)
        text = re.sub(r'\{\{#each (\w+)\}\}([\s\S]*?)\{\{/each\}\}', lambda m: ''.join(
            re.sub(r'\{\{this\.(\w+)\}\}', lambda k: item.get(k[1], ''), m[2]) for item in lists.get(m[1], [])), text)
        text = re.sub(r'\{\{([A-Z0-9_]+)\}\}', value, text)
        text = re.sub(r'\n{3,}', '\n\n', re.sub(r'<!-- MODEL_INSERT:[\s\S]*?-->', '', text))
        require('{{' not in text, 'unresolved template: ' + template)
        path = Path(out) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.open('x').write(text)


def skill_values(base_branch, commands, targets):
    conventions = '#### Declared checks\n\nRun from the repo root: ' + '; '.join('`' + c + '`' for c in commands) + '.'
    if targets:
        conventions += ' Dependencies (' + ', '.join('`' + t + '`' for t in targets) + ') are provisioned read-only; never install packages.'
    conventions += ' Network is off during delivery.'
    values = {'PLATFORM_LIST': 'general/unknown', 'BASE_BRANCH': base_branch, 'TEST_CMD': queue.CANONICAL_VERIFY[0],
              'TYPECHECK_CMD': '', 'LINT_CMD': '', 'PACKAGE_DIFF_SCOPE': '.',
              'SPECIALIST_DOMAIN_LIST': 'none; use inspector for mandatory independent review'}
    lists = {'AGENTS_BY_PLATFORM_ROW': [{'platform': 'any', 'agents': 'inspector'}],
             'CLAUDE_MD_FILES': [{'source': 'the Launch stage', 'content': conventions}]}
    flags = {'WORKTREES_ENABLED': True, 'PLATFORM_GENERAL': True, 'AUTONOMY_ENABLED': True, 'CLAUDE_MD_FILES': True}
    return values, lists, flags


def shipped(path):
    """Pack files to pin: never pycache or dotfiles, which change on their own and would fail the run."""
    return not any(part == '__pycache__' or part.startswith('.') for part in path.relative_to(ONBOARD).parts)


def output(argv, **kw):
    return subprocess.check_output(list(map(str, argv)), text=True, **kw)


def gh_api(endpoint):
    return json.loads(output(['gh', 'api', endpoint]))


def contents(github, repository, path, ref):
    blob = github('repos/%s/contents/%s?ref=%s' % (repository, quote(path), ref))
    require(blob.get('type') == 'file' and blob.get('encoding') in ('base64', 'none'), 'base file unavailable: ' + path)
    if blob['encoding'] == 'none':  # Over 1 MB (large lockfiles): the contents API omits the body.
        blob = {**github('repos/%s/git/blobs/%s' % (repository, blob['sha'])), 'sha': blob['sha']}
        require(blob.get('encoding') == 'base64', 'base file unavailable: ' + path)
    raw = base64.b64decode(''.join(blob['content'].split()), validate=True)
    require(delivery.git_blob(raw) == blob['sha'], 'base file does not match its blob: ' + path)
    return raw, blob['sha']


def pin(name, version):
    """npm-pinned tool under ~/.local/share/launch-control, installed once (network, operator side only)."""
    root = Path.home() / '.local/share/launch-control' / ('%s-%s' % (name.split('/')[-1], version))
    manifest = root / 'node_modules' / name / 'package.json'
    if not manifest.is_file():
        subprocess.run(['npm', 'install', '--prefix', str(root), '%s@%s' % (name, version)], check=True)
    require(json.loads(manifest.read_text()).get('version') == version, 'pinned tool version differs: ' + name)
    return root


def toolchain():
    """Host executables the controller and workers run, with the read roots they need."""
    python = Path(sys.executable).resolve()
    prefix = Path(sys.base_prefix).resolve()
    python_root = next((p.parent for p in (prefix, *prefix.parents) if p.name == 'Frameworks'), prefix)
    developer = Path(output(['xcode-select', '-p']).strip()).resolve()
    git = Path(output(['xcrun', '--find', 'git']).strip()).resolve()
    gh = shutil.which('gh')
    require(gh is not None, 'gh is required')
    found = list((pin(*CODEX) / 'node_modules/@openai').glob('codex-darwin-*/vendor/*/bin/codex'))
    require(len(found) == 1, 'pinned codex binary not found')
    codex = found[0]
    require(output([codex, '--version']).strip() == 'codex-cli ' + CODEX[1], 'pinned codex version differs')
    path, roots, pinned = [python.parent, git.parent], [python_root, developer, codex.parents[1]], [python, git, Path(gh).resolve(), codex]
    node = shutil.which('node')
    if node:
        node = Path(node).resolve()
        path.append(node.parents[1] / 'bin')
        roots.append(node.parents[1])
        pinned.append(node)
    if Path('/System/Library/OpenSSL').is_dir():
        roots.append(Path('/System/Library/OpenSSL'))
    return {'python': str(python), 'git': str(git), 'gh': str(Path(gh).resolve()), 'codex': str(codex),
            'path': list(map(str, path)), 'read_roots': list(map(str, roots)), 'pinned': list(map(str, pinned))}


def check_config(config):
    text = lambda value: isinstance(value, str) and bool(value.strip())
    name = lambda value: text(value) and re.fullmatch(r'[\w.-]+', value) and value not in ('.', '..')
    relative = lambda value: value == '.' or (text(value) and all(name(part) for part in value.split('/'))
                                               and value.split('/')[0].casefold() not in ('.git', '.codex'))
    shape = lambda value, keys: isinstance(value, dict) and set(value) == keys
    require(shape(config, {'repository', 'base_branch', 'source', 'checks', 'acceptance', 'dependencies', 'publication', 'caps'})
            and text(config['repository']) and text(config['base_branch'])
            and shape(config['source'], {'path', 'heading'}) and all(text(v) for v in config['source'].values())
            and isinstance(config['checks'], list) and config['checks'] and isinstance(config['acceptance'], list)
            and isinstance(config['dependencies'], list)
            and all(shape(d, {'cwd', 'manifest', 'lockfile', 'build', 'target'}) and isinstance(d['build'], list) and d['build']
                    and all(text(a) for a in d['build']) and relative(d['cwd']) and relative(d['target']) and d['target'] != '.'
                    and name(d['manifest']) and name(d['lockfile']) and d['manifest'] != d['lockfile'] for d in config['dependencies'])
            and len({d['cwd'] for d in config['dependencies']}) == len(config['dependencies'])
            and shape(config['publication'], {'required_checks', 'billing_fallback'}) and isinstance(config['caps'], dict),
            'invalid project config')
    return config


def stage(config_path, github=gh_api):
    config_path = Path(config_path).resolve()
    config = check_config(rt.read_json(config_path))
    out = config_path.parent / 'stage'
    require(not out.exists() and not out.is_symlink(), 'stage already exists: remove %s to restage' % out)
    repository, branch, source = config['repository'], config['base_branch'], {**config['source'], 'format': 'table'}
    base = github('repos/%s/commits/%s' % (repository, branch))['sha']
    backlog, blob = contents(github, repository, source['path'], base)
    queue.selected_backlog_text(backlog.decode('utf-8'), source)  # Refuse a missing or malformed section before writing.
    tools = toolchain()
    code_home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    native = tomllib.loads((code_home / 'config.toml').read_text())
    out.mkdir()
    try:
        return build(config, config_path, out, github, base, blob, tools, code_home, native)
    except BaseException:
        shutil.rmtree(out, ignore_errors=True)  # This run created it; a retry then needs no manual cleanup.
        raise


def build(config, config_path, out, github, base, blob, tools, code_home, native):
    repository, branch, source = config['repository'], config['base_branch'], {**config['source'], 'format': 'table'}
    put = lambda name, value: (out / name).open('x').write(json.dumps(value, indent=2) + '\n')
    path, roots, pinned = list(tools['path']), list(tools['read_roots']), list(tools['pinned'])
    join = lambda cwd, name: name if cwd == '.' else cwd + '/' + name

    # Dependency trees, built here (network) from the base manifests and lockfiles, copied read-only into workers.
    dependencies = []
    for index, dep in enumerate(config['dependencies']):
        build_dir = out / 'deps' / str(index) / dep['cwd']  # Own directory each: a '.' build never sees a sibling.
        build_dir.mkdir(parents=True)
        for name in (dep['manifest'], dep['lockfile']):
            (build_dir / name).open('xb').write(contents(github, repository, join(dep['cwd'], name), base)[0])
        argv = list(dep['build'])
        tool = NPM_TOOL.fullmatch(argv[0])
        if tool:  # `pnpm@10.33.2`: an npm-pinned tool, also on the worker PATH for declared checks.
            root = pin(tool[1], tool[2])
            executable = root / 'node_modules/.bin' / tool[1].split('/')[-1]
            argv[0] = str(executable)
            path.append(str(executable.parent))
            roots.append(str(root))
            pinned.append(str(executable.resolve()))
            # ponytail: pins the bin entry and its dist bundle only; pin the whole package if a tool loads more.
            bundle = executable.resolve().parents[1] / 'dist' / (executable.name + '.cjs')
            if bundle.is_file():
                pinned.append(str(bundle))
        subprocess.run(argv, cwd=build_dir, check=True)
        tree = build_dir / dep['target']
        require(tree.is_dir(), 'dependency build produced no tree: ' + join(dep['cwd'], dep['target']))
        if (tree / 'pyvenv.cfg').is_file():  # Admit the venv's base interpreter install, as the venv records it.
            home = next((line.split('=', 1)[1].strip() for line in (tree / 'pyvenv.cfg').read_text().splitlines()
                         if line.split('=', 1)[0].strip() == 'home'), '')
            require(home and Path(home).is_absolute(), 'venv records no interpreter home')
            install = Path(home).resolve().parent
            interpreter = (tree / 'bin/python').resolve()
            require(interpreter.is_relative_to(install), 'venv interpreter outside its recorded home')
            # A planted link can then only name a directory holding a real stdlib, never an arbitrary one.
            require(any(install.glob('lib/python3*/os.py')),
                    'venv interpreter is not a Python install: ' + str(install))
            roots.append(str(install))
        dependencies.append({'target': join(dep['cwd'], dep['target']), 'source': str(tree), 'digest': delivery.tree_digest(tree),
                             'lockfile': join(dep['cwd'], dep['lockfile']), 'lock_digest': digest(build_dir / dep['lockfile'])})
    if dependencies:
        roots.append(str(out / 'deps'))

    put('project.json', config)  # What was staged; launch-go refuses to reuse a stage for a changed config.
    verify = {'schema': 1, 'checks': config['checks'], 'acceptance': config['acceptance']}
    put('verify.json', verify)
    commands = [c['command'] if c['cwd'] == '.' else 'cd %s && %s' % (c['cwd'], c['command']) for c in config['checks']]
    (out / 'commands.txt').open('x').write('\n'.join(commands) + '\n')
    render(out / 'rendered/skills/launch', *skill_values(branch, commands, [d['target'] for d in dependencies]))

    # Host policy: pinned executables, native config, hooks and every file a worker or the generator reads.
    config_toml = code_home / 'config.toml'
    reference = ONBOARD / 'references/launch-autonomy.md'
    read_files = [out / 'verify.json', out / 'commands.txt', reference]
    pinned += [str(p) for p in [*read_files, *filter(shipped, ONBOARD.rglob('*')), *(out / 'rendered').rglob('*')] if p.is_file()]
    # Only built-in system paths may be aliases (merged-/usr); supplied paths still face the strict guard.
    system_path = [str(Path(p).resolve(strict=True)) for p in ('/usr/bin', '/bin')]
    path = list(dict.fromkeys([*path, *system_path]))  # Hooks resolve bare interpreters here.
    hooks, hook_commands = code_home / 'hooks.json', {}
    if hooks.is_file():
        pinned.append(str(hooks))
        for groups in json.loads(hooks.read_text())['hooks'].values():
            for group in groups:
                for hook in group['hooks']:
                    # ponytail: what the command resolves to, not what a hook script runs later; list those by hand if needed.
                    hook_commands[hook['command']] = sorted(delivery.hook_artifacts(hook['command'], path))
    pinned += [p for listed in hook_commands.values() for p in listed]
    pinned += [v['config_file'] for v in native.get('agents', {}).values() if isinstance(v, dict) and v.get('config_file')]
    host = {'schema': 1, 'platform': delivery.platform.system(), 'codex_version': 'codex-cli ' + CODEX[1],
            **{k: tools[k] for k in ('codex', 'python', 'git', 'gh')},
            'path': path,
            'read_roots': list(dict.fromkeys([str(ONBOARD), str(out / 'rendered'), *roots])),
            'read_files': list(map(str, read_files)), 'files': {str(Path(p).resolve()): digest(p) for p in pinned},
            'native_config': {'path': str(config_toml), 'execution_digest': delivery.execution_digest(native)},
            'native_overrides': [c + '.' + n + '.enabled=false' for c in ('mcp_servers', 'plugins') for n in native.get(c, {})],
            'hook_commands': hook_commands}
    # Read roots only widen worker reads (PATH must sit inside them); a shallow one such as /Library or /usr/local fails closed.
    for entry in host['read_roots']:
        require(len(Path(entry).parts) >= 4, 'derived host path too broad: ' + entry)
    put('host.json', host)

    # Template policy and grant; the mission derives each task's copy by a closed list of overwrites.
    caps = config['caps']
    controller = ONBOARD / 'scripts/launch-runtime.py'
    policy = {'schema': 1, 'project': str(out / 'template-original'), 'base_revision': base, 'source': source,
              'scope_template': 'replaced per task',
              'caps': {'minutes': caps.get('task_minutes'), 'max_attempts': caps.get('task_max_attempts'),
                       'rollover': {'threshold': 65, 'max_launches': caps.get('task_max_launches'),
                                    'synchronous_commands': list(mission.BASELINE)}},
              'generator': {'argv': [tools['python'], '-I', str(ONBOARD / 'scripts/codex-parity.py'), '--codex', '--enable-autonomy',
                                     '--source', str(out / 'rendered'), '--autonomy-config', str(out / 'verify.json'),
                                     '--autonomy-commands', str(out / 'commands.txt'), '--autonomy-controller', str(controller),
                                     '--autonomy-controller-digest', digest(controller),
                                     '--autonomy-shared-root', str(out / 'template-ws'), '--project', '{worktree}']}}
    publication = {'mode': 'github-base-lease', 'deployment': 'none', 'required_checks': config['publication']['required_checks'],
                   'post_merge_checks': [], 'billing_fallback': config['publication']['billing_fallback']}
    grant = {'schema': 1, 'target_digest': delivery.target_digest(policy), 'verification': verify, 'repository': repository,
             'base_branch': branch, 'base_revision': base, 'source': {**source, 'blob': blob}, 'workspace': str(out / 'template-ws'),
             'host_policy': {'path': str(out / 'host.json'), 'digest': digest(out / 'host.json')},
             'allowed_actions': ['prepare', 'implement', 'review', 'push', 'pull_request', 'publish', 'source_done'],
             'source_writeback': {'repository': repository, 'branch': branch, 'path': source['path'], 'heading': source['heading'],
                                  'max_attempts': 2},
             'publication': publication, 'dependencies': dependencies,
             'minutes': caps.get('task_minutes'), 'max_attempts': caps.get('task_max_attempts'), 'max_launches': caps.get('task_max_launches')}
    put('template-policy.json', policy)
    put('template-grant.json', grant)
    delivery.load_binding({'grant': str(out / 'template-grant.json'), 'digest': digest(out / 'template-grant.json')})

    put('plan.json', {'repository': repository, 'base_branch': branch, 'source': config['source'], 'caps': caps,
                      'template': {'policy': str(out / 'template-policy.json'), 'grant': str(out / 'template-grant.json')}})
    planned = mission.Mission(config_path.parent / 'mission', reader=github).plan(out / 'plan.json', out / 'mission.json')
    return {**planned, 'caps': caps, 'allowed_actions': grant['allowed_actions'],
            'init': [sys.executable, str(HERE / 'launch-mission.py'), '--root', str(config_path.parent / 'mission'),
                     'init', '--mission', planned['mission'], '--digest', planned['digest']]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='operator project.json; the stage is written beside it')
    args = parser.parse_args()
    try:
        result = stage(args.config, gh_api)
    except Exception as error:  # The stage is already removed; report, never a traceback.
        print(json.dumps({'error': str(error) if isinstance(error, rt.Invalid) else '%s: %s' % (type(error).__name__, error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
