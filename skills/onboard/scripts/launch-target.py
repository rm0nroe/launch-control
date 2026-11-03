#!/usr/bin/env python3
"""Prepare one approved source task; native trust, queue init and run remain explicit."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import string
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('launch_queue', Path(__file__).with_name('launch-queue.py'))
queue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue)
rt, require = queue.rt, queue.require


def template(text, allowed, values=None):
    require(isinstance(text, str) and bool(text.strip()), 'nonempty policy template required')
    for _, field, format_spec, conversion in string.Formatter().parse(text):
        require(field is None or (field in allowed and not format_spec and conversion is None), 'unsupported template placeholder')
    return text.format_map(values) if values is not None else text


def read_policy(path):
    rt.safe_path(path)
    raw = path.read_bytes()
    policy = json.loads(raw)
    required = {'schema', 'project', 'base_revision', 'source', 'scope_template', 'caps', 'generator'}
    require(isinstance(policy, dict) and required <= set(policy) <= required | {'delivery', 'task', 'platform'}
            and policy['schema'] == 1, 'invalid target policy')
    # Absent means Codex: every policy written before LC-039 slice 2 keeps its meaning.
    require(policy.get('platform', 'codex') in ('codex', 'claude'), 'invalid target platform')
    require(policy.get('platform') != 'claude' or 'delivery' not in policy, 'Claude delivery is unsupported; publication is Codex-only (D4)')
    require(isinstance(policy['project'], str) and Path(policy['project']).is_absolute(), 'absolute policy project required')
    project = Path(policy['project'])
    rt.safe_path(project)
    if 'delivery' in policy:
        delivery = rt.delivery_module()
        admitted = delivery.load_binding(policy['delivery'])
        delivery.validate_target(admitted, policy)
        delivery.bind_runtime(rt, policy['delivery'], preparing=True, original=project)
    else:
        rt.configure_git(None, None)
    rt.identity(project)
    require(isinstance(policy['base_revision'], str) and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', policy['base_revision']), 'full base revision required')
    source = policy['source']
    require(isinstance(source, dict) and {'path'} <= set(source) <= {'path', 'format', 'heading'} and isinstance(source['path'], str)
            and not Path(source['path']).is_absolute(), 'relative source path required')
    require(('format' not in source and 'heading' not in source) or source.get('format') in ('headings', 'table'),
            'explicit selected source format required')
    require('heading' not in source or (isinstance(source['heading'], str) and re.fullmatch(r'#{1,6} .+', source['heading'])),
            'exact Markdown heading required')
    source_path = project / source['path']
    rt.safe_path(source_path)
    require(source_path.is_file() and source_path.resolve().is_relative_to(project), 'unsafe or missing source')
    template(policy['scope_template'], {'id', 'gitdir'})
    require('task' not in policy or (isinstance(policy['task'], str) and policy['task']), 'invalid pinned task')
    caps = policy['caps']
    require(isinstance(caps, dict) and set(caps) - {'max_tokens'} == {'minutes', 'max_attempts', 'rollover'}, 'invalid target caps')
    require('max_tokens' not in caps or (type(caps['max_tokens']) is int and caps['max_tokens'] > 0), 'invalid target caps')
    require(type(caps['minutes']) is int and 1 <= caps['minutes'] <= 60
            and type(caps['max_attempts']) is int and 1 <= caps['max_attempts'] <= 5, 'invalid target caps')
    rollover = caps['rollover']
    require(isinstance(rollover, dict) and set(rollover) == {'threshold', 'max_launches', 'synchronous_commands'}, 'invalid rollover caps')
    require(type(rollover['threshold']) is int and 60 <= rollover['threshold'] <= 70
            and type(rollover['max_launches']) is int and rollover['max_launches'] > 0, 'invalid rollover caps')
    commands = rollover['synchronous_commands']
    require(isinstance(commands, list) and all(isinstance(c, str) for c in commands)
            and len(set(commands)) == len(commands), 'invalid synchronous commands')
    for command in commands:
        template(command, {'id'})
    generator = policy['generator']
    require(isinstance(generator, dict) and set(generator) == {'argv'} and isinstance(generator['argv'], list)
            and bool(generator['argv']), 'explicit generator argv required')
    for argument in generator['argv']:
        template(argument, {'id', 'worktree'})
    return policy, raw, project, source_path


# Claude settings and the Launch skill must be committed: a fresh worktree carries only tracked files.
CLAUDE_TRACKED = ('.claude/settings.json', '.claude/skills/launch/SKILL.md',
                  *('.claude/skills/launch/references/' + name for name in
                    ('delivery.md', 'implementation.md', 'ticket-intake.md', 'verification.md')))


def generated_baseline(project, revision, platform='codex'):
    require(rt.git(project, 'rev-parse', 'HEAD') == revision, 'policy base revision changed')
    ignore = project / '.gitignore'
    rt.safe_path(ignore)
    committed = rt.git_process(project, 'show', revision + ':.gitignore').stdout
    require(ignore.is_file() and ignore.read_bytes() == committed, 'committed ignore rules required')
    claude = platform == 'claude'
    rules = ('.claude/launch/', '.claude/hooks/launch.sh') if claude else ('.codex/',)
    probes = ('.claude/launch/verify.json', '.claude/hooks/launch.sh') if claude else ('.codex/hooks.json',)
    require({*rules, 'scripts/verify.sh', 'launch-control-backups/'} <= set(committed.decode().splitlines()), 'explicit generated ignore rules required')
    require(not rt.git(project, 'ls-files', '--', *(r.rstrip('/') for r in rules), 'scripts/verify.sh', 'launch-control-backups'),
            'tracked generated paths are unsupported')
    # ponytail: explicit root rules only; broader ignore policies need separate baseline proof.
    result = rt.git_process(project, '-c', 'core.excludesFile=/dev/null', 'check-ignore', '--',
                           *probes, 'scripts/verify.sh', 'launch-control-backups/probe', check=False)
    require(result.returncode == 0 and len(result.stdout.splitlines()) == len(probes) + 2, 'generated paths must be ignored')
    if claude:
        tracked = set(rt.git(project, 'ls-tree', '-r', '--name-only', revision, '--', *CLAUDE_TRACKED).splitlines())
        missing = [path for path in CLAUDE_TRACKED if path not in tracked]
        require(not missing, 'tracked Claude file required at the base revision: ' + ', '.join(missing))


def prepare(policy_path, output):
    policy_path, output = Path(policy_path).absolute(), Path(output).absolute()
    rt.safe_path(output)
    require(not output.exists() and not output.is_symlink(), 'manifest output already exists')
    policy, raw, project, source_path = read_policy(policy_path)
    formatted = 'format' in policy['source']
    claude = policy.get('platform') == 'claude'

    def source_records():
        return (queue.selected_backlog(source_path, policy['source']) if formatted
                else queue.backlog(source_path, headings_only=True))

    def select(records):
        # A mission child prepares only its own task; a blocked sibling stays Todo in the source.
        eligible = [r for r in records.values() if r['status'] == 'todo' and not r.get('blocked')
                    and policy.get('task', r['id']) == r['id']
                    and (all(records.get(d, {}).get('status') == 'done' and not records[d].get('blocked') for d in r['depends'])
                         if formatted else not r['depends'])]
        return min(eligible, key=lambda r: (r['priority'], r.get('subpriority', ''), r['id']), default=None)

    delivery, admitted = None, None
    if 'delivery' in policy:
        delivery = rt.delivery_module()
        selected = select(source_records())
        require(selected is not None, 'no eligible bound delivery task')
        admitted, account = delivery.prepare_clone(policy, policy['delivery'], output, selected)
        project = Path(admitted['grant']['workspace'])
        rt.git(project, 'check-ref-format', '--branch', admitted['grant']['base_branch'])
        rt.git(project, 'checkout', '-B', admitted['grant']['base_branch'], policy['base_revision'])
        rt.git(project, 'config', 'user.name', account['login'])
        rt.git(project, 'config', 'user.email', str(account['id']) + '+' + account['login'] + '@users.noreply.github.com')
        delivery.generate(admitted, policy, selected['id'], project)
        source_path = project / policy['source']['path']

    common = Path(rt.git(project, 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
    base = common / 'launch-queue'
    rt.safe_path(base / 'lock')
    base.mkdir(exist_ok=True)
    with (base / 'lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise rt.Invalid('queue lock busy') from error
        require(policy_path.read_bytes() == raw, 'policy changed before preparation')
        require(not (base / 'active.json').exists(), 'existing queue retained')
        require(not (base / 'PAUSE').exists(), 'user pause prevents preparation')
        require(not any(base.glob('preparing-*.json')), 'retained preparation requires reconciliation')
        generated_baseline(project, policy['base_revision'], 'claude' if claude else 'codex')
        records = source_records()
        selected = select(records)
        if selected is None:
            return {'outcome': 'no_eligible', 'records': {key: value['status'] for key, value in records.items()},
                    **({'blocked': {key: value['blocked'] for key, value in records.items() if value.get('blocked')}} if formatted else {})}
        prerequisites = {dep: records[dep]['digest'] for dep in selected['depends']}
        marker = base / ('preparing-' + selected['id'] + '.json')
        worktree = common / 'launch-prepared' / selected['id']
        rt.safe_path(worktree)
        require(not worktree.exists(), 'target worktree already exists')
        branch = 'launch/' + selected['id'].lower()
        require(rt.git_process(project, 'show-ref', '--verify', '--quiet', 'refs/heads/' + branch, check=False).returncode != 0,
                'target branch already exists')
        # A Claude worker has no selected controller: its hooks resolve through the worktree.
        controller = None if claude else {'path': str(Path(rt.__file__).resolve()), 'digest': rt.digest(Path(rt.__file__).read_bytes()), 'shared_root': str(common.parent)}
        if delivery:
            controller['delivery'] = policy['delivery']
        # Primary generation must already be owned and canonical before task-side writes.
        queue.validate_controller(controller, common.parent)
        claim = {'id': selected['id'], 'source_digest': selected['digest'], 'policy': str(policy_path),
                 'policy_digest': rt.digest(raw), 'base_revision': policy['base_revision'], 'status': 'preparing'}
        rt.atomic(marker, claim)
        worktree.parent.mkdir(exist_ok=True)
        rt.git_process(project, 'worktree', 'add', '-b', branch, str(worktree), policy['base_revision'])
        if delivery:
            delivery.generate(admitted, policy, selected['id'], worktree)
            delivery.provision(admitted, worktree)
        else:
            argv = [template(arg, {'id', 'worktree'}, {'id': selected['id'], 'worktree': str(worktree)}) for arg in policy['generator']['argv']]
            subprocess.run(argv, check=True, capture_output=True, text=True)
        if claude:
            queue.validate_claude_overlay(worktree)
            config = worktree / '.claude/launch/verify.json'
            rt.safe_path(config)
            claim['verify_digest'] = rt.digest(config.read_bytes())
        else:
            queue.validate_controller(controller, worktree)
        require(rt.git(worktree, 'rev-parse', 'HEAD') == policy['base_revision'], 'generated worktree base changed')
        require(not rt.git(worktree, 'status', '--porcelain'), 'generated worktree is not clean')
        require(policy_path.read_bytes() == raw, 'policy changed during preparation')
        current = source_records()
        require(current.get(selected['id']) == selected, 'source drift during preparation')
        require(all(current.get(dep, {}).get('digest') == digest and current[dep]['status'] == 'done'
                    and not current[dep].get('blocked') for dep, digest in prerequisites.items()), 'prerequisite drift during preparation')
        require(rt.git(project, 'rev-parse', 'HEAD') == policy['base_revision'], 'policy base revision changed')
        gitdir = rt.git(worktree, 'rev-parse', '--absolute-git-dir')
        cfg = {'schema': 1, 'project': str(project), 'platform': 'claude' if claude else 'codex', 'native_review': not claude,
               **({} if claude else {'controller': controller}),
               'source': {**policy['source'], 'kind': 'backlog', 'path': str(source_path)},
               'items': [{'id': selected['id'], 'priority': selected['priority'], 'worktree': str(worktree), 'depends': selected['depends'],
                          **({'subpriority': selected['subpriority'], 'prerequisites': prerequisites} if formatted else {}),
                          'scope': template(policy['scope_template'], {'id', 'gitdir'}, {'id': selected['id'], 'gitdir': gitdir})}],
               'minutes': policy['caps']['minutes'], 'max_tasks': 1, 'max_launches': 1, 'max_attempts': policy['caps']['max_attempts'],
               'rollover': {**policy['caps']['rollover'], 'synchronous_commands': [template(c, {'id'}, {'id': selected['id']}) for c in policy['caps']['rollover']['synchronous_commands']]},
               'preparation': {k: claim[k] for k in ('source_digest', 'policy', 'policy_digest', 'base_revision', 'verify_digest') if k in claim},
               **({'max_tokens': policy['caps']['max_tokens']} if 'max_tokens' in policy['caps'] else {})}
        cfg['preparation']['claim'] = str(marker)
        if delivery:
            cfg['delivery'] = policy['delivery']
        manifest_hash = rt.digest(json.dumps(cfg, sort_keys=True).encode())
        rt.safe_path(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        # Publish exclusively; an interruption retains the preparing marker, never replays.
        with output.open('x') as stream:
            json.dump(cfg, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        rt.atomic(marker, {**claim, 'status': 'prepared', 'manifest': str(output), 'manifest_hash': manifest_hash})
        if delivery:
            delivery.seal_preparation(admitted, cfg, output)
        return cfg


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.policy, args.output), indent=2))
    except (rt.Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        sys.exit('Launch target refused; any preparation evidence is retained: ' + str(error))
