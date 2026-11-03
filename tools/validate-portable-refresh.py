#!/usr/bin/env python3
"""Disposable checks for portable refresh. No live homes or external dependencies."""
import atexit
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'skills/onboard/scripts/portable-refresh.py'
spec = importlib.util.spec_from_file_location('refresh', SCRIPT)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
REAL_RELEASES = p.RELEASES


# Every patched manifest lives under one scratch dir the parent removes at exit. The --child
# processes SIGKILL themselves and skip atexit, so they inherit the parent's dir instead of
# making their own; a dir per call leaked ~850 a run.
SCRATCH = os.environ.get('LC_RELEASES_SCRATCH')
if not SCRATCH:
    SCRATCH = os.environ['LC_RELEASES_SCRATCH'] = tempfile.mkdtemp(prefix='lc-releases-')
    atexit.register(shutil.rmtree, SCRATCH, True)


def with_old_fingerprints_under_new_names():
    """Engine checks seed historical bundles; LC-036 moved their names, not their bytes."""
    renamed = {'checkpoint': 'checkpoint-save', 'load': 'checkpoint-load', 'sessions': 'checkpoint-list'}
    text = REAL_RELEASES.read_text()
    extra = [f'{r} {renamed[n]} {h}' for r, n, h in (l.split() for l in text.splitlines()
                                                    if l.split()[:1] in (['claude'], ['codex']) and len(l.split()) == 3)
             if n in renamed]
    patched = Path(tempfile.mkdtemp(dir=SCRATCH)).resolve() / 'releases.md'
    patched.write_text(text.replace('\n```\n', '\n' + '\n'.join(extra) + '\n```\n', 1))
    p.RELEASES = patched


with_old_fingerprints_under_new_names()


def put(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def snapshot(root):
    return {str(path.relative_to(root)): (path.read_bytes() if path.is_file() else None,
                                         path.stat().st_mode, path.stat().st_ino)
            for path in root.rglob('*')}


def fails(call):
    try:
        call()
    except (ValueError, OSError, KeyError, TypeError):
        return
    raise AssertionError('expected fail-closed rejection')


def record(root, runtime, name, output, digest):
    value = {'version': 1, 'runtime': runtime, 'skill': name, 'source_digest': digest, 'output_manifest': output}
    path = root / p.STATE / 'receipts' / runtime / (name + '.json')
    put(path, json.dumps(value))
    return path


def checkpoint_contract_checks():
    # Instruction assertions, not evidence that a native model follows them.
    outputs, _ = p.source()
    for runtime in p.RUNTIMES:
        load = outputs[runtime]['checkpoint-load']['SKILL.md'][0].decode()
        save = outputs[runtime]['checkpoint-save']['SKILL.md'][0].decode()
        for clause in (
            'before any ordinary-file lookup',
            'reject malformed `launch-run-` names',
            'exact requested run',
            'before reading the view or invoking the runtime',
            'Claude uses `CLAUDE_CONFIG_DIR` when set, otherwise `$HOME/.claude`',
            'Codex uses `CODEX_HOME` when set, otherwise `$HOME/.codex`',
            'as a separate command',
            'exit status and full JSON output',
            'all nine semantic fields and retained limits',
            'Never fall back to an ordinary file, another task, a source-checkout runtime, or a latest checkpoint',
            'stop without confirming a load',
        ):
            assert clause in load, (runtime, clause)
        for clause in (
            'reject it for manual checkpoint names',
            'run, platform, snapshot sequence and sealed hash',
            'all nine semantic fields and retained limits',
            'label this manual document as session notes',
            'Do not overwrite the Git-local generated view',
        ):
            assert clause in save, (runtime, clause)
    print('Checkpoint contracts passed: reserved routing, fail-closed readback, save authority.')


def preview_checks():
    with tempfile.TemporaryDirectory(prefix='lc023-preview-') as scratch:
        root = Path(scratch).resolve()
        project = root / 'project'
        project.mkdir()
        put(project / '.claude_states/keep.md', 'old checkpoint')
        put(project / '.codex/config.toml', '# untouched config')
        before = snapshot(project)
        proposal = p.preview(project, 'both', list(p.NAMES))
        assert snapshot(project) == before
        assert len(proposal['entries']) == 6
        assert {e['action'] for e in proposal['entries']} == {'create'}
        assert proposal == p.preview(project, 'both', list(p.NAMES))
        payload, digest = p.source()
        for entry in proposal['entries']:
            put(Path(entry['target']) / 'SKILL.md', payload[entry['runtime']][entry['skill']]['SKILL.md'][0].decode())
        before = snapshot(project)
        current = p.preview(project, 'both', list(p.NAMES))
        assert {e['action'] for e in current['entries']} == {'current'}
        assert snapshot(project) == before and not (project / p.STATE).exists()
        value = p.apply(project, 'both', list(p.NAMES), current['approval_digest'])
        assert value['status'] == 'current'
        assert not (project / p.STATE / 'receipts').exists()
        assert not (project / p.STATE / 'operations').exists()
        with p.locked(project):
            fails(lambda: p.apply(project, 'both', list(p.NAMES), p.preview(project, 'both', list(p.NAMES))['approval_digest']))
        path = project / '.codex/skills/checkpoint-load'
        receipt = record(project, 'codex', 'checkpoint-load', p.existing(path), digest)
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'current'
        put(path / 'SKILL.md', 'old generated version')
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'conflict'
        record(project, 'codex', 'checkpoint-load', p.existing(path), digest)
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'upgrade'
        (path / 'SKILL.md').chmod(0o755)
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'conflict'
        (path / 'SKILL.md').chmod(0o644)
        # LC-061: offboard removes a bundle but used to leave its receipt, so a re-onboard meets a
        # receipt from an older release. Bytes that are current, or exactly a released version, are
        # not a customization: the stale receipt must not turn them into a conflict.
        put(path / 'SKILL.md', payload['codex']['checkpoint-load']['SKILL.md'][0].decode())
        stale = json.loads(json.dumps(p.existing(path)))
        stale['SKILL.md']['sha256'] = '0' * 64
        record(project, 'codex', 'checkpoint-load', stale, digest)
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'current'
        put(path / 'SKILL.md', 'an older released version')
        older = p.existing(path)
        with patch.object(p, 'released', lambda runtime, name, output: output == older):
            assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'upgrade'
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'conflict'
        shutil.rmtree(path)
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'conflict'
        receipt.unlink()
        path.mkdir()
        assert p.preview(project, 'codex', ['checkpoint-load'])['entries'][0]['action'] == 'conflict'
        path.rmdir()
        path.symlink_to(root / 'outside')
        fails(lambda: p.preview(project, 'codex', ['checkpoint-load']))
        path.unlink()
        for bad in ({}, {'version': 2}, {'version': 1, 'runtime': 'codex', 'skill': 'checkpoint-load',
                                       'source_digest': 'x', 'output_manifest': {}}):
            put(receipt, json.dumps(bad))
            fails(lambda: p.preview(project, 'codex', ['checkpoint-load']))
        receipt.unlink()
        for names in ([], ['checkpoint-load', 'checkpoint-load'], ['../checkpoint-load'], ['issue-verify']):
            fails(lambda: p.preview(project, 'codex', names))
        with patch.object(p.sys, 'platform', 'unsupported'):
            fails(lambda: p.preview(project, 'codex', ['checkpoint-load']))
        journal = project / p.STATE / 'operations/bad/journal.json'
        put(journal, '{}')
        fails(lambda: p.preview(project, 'codex', ['checkpoint-load']))
        shutil.rmtree(journal.parent)
        lock = project / p.STATE / 'lock'
        lock.unlink()
        lock.mkdir()
        fails(lambda: p.preview(project, 'codex', ['checkpoint-load']))
        lock.rmdir()
        real_stat = Path.stat
        def foreign_stat(path, *args, **kwargs):
            value = real_stat(path, *args, **kwargs)
            if path == project / '.codex/skills/checkpoint-list':
                fields = list(value)
                fields[2] += 1
                return os.stat_result(fields)
            return value
        with patch.object(Path, 'stat', foreign_stat):
            fails(lambda: p.preview(project, 'codex', ['checkpoint-list']))
        # Actual copied release inputs determine provenance, not a label or home path.
        release = root / 'release'
        shutil.copytree(ROOT / 'skills/onboard', release)
        script = release / 'scripts/portable-refresh.py'
        cmd = [sys.executable, '-B', str(script), 'preview', '--project', str(project), '--runtime', 'codex', '--skill', 'checkpoint-load']
        first = json.loads(subprocess.check_output(cmd))
        with (release / 'references/checkpoint-templates.md').open('a') as stream:
            stream.write('\nSource changed.\n')
        second = json.loads(subprocess.check_output(cmd))
        assert first['source_digest'] != second['source_digest']
        assert first['approval_digest'] != second['approval_digest']
        assert not list(release.rglob('__pycache__'))
        assert subprocess.run(cmd + ['--force'], capture_output=True).returncode == 2
        assert subprocess.run(cmd + ['--skill', 'checkpoint-load'], capture_output=True).returncode == 2
        # A real nested linked worktree resolves locally and proposes local .gitignore.
        repo = root / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                        'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        linked = root / 'linked'
        subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-qb', 'linked', str(linked)], check=True)
        nested = linked / 'nested/deep'
        nested.mkdir(parents=True)
        before = snapshot(linked)
        proposal = p.preview(nested, 'both', list(p.NAMES))
        assert proposal['root'] == str(linked)
        assert proposal['exclusion']['path'] == str(linked / '.gitignore')
        assert snapshot(linked) == before
        assert p.preview(repo, 'codex', ['checkpoint-load'])['exclusion']['path'] == str(repo / '.git/info/exclude')
        put(repo / '.gitignore', '!.launch-control/refresh/\n!.launch-control/refresh/**\n')
        for _ in range(2):  # Also check an already-present exclusion entry.
            proposal = p.preview(repo, 'codex', ['checkpoint-load'])
            fails(lambda: p.apply(repo, 'codex', ['checkpoint-load'], proposal['approval_digest']))
            assert not (repo / '.codex').exists()
            assert not (repo / p.STATE / 'receipts').exists()
            assert not (repo / p.STATE / 'operations').exists()
        (repo / '.gitignore').unlink()
        proposal = p.preview(repo, 'codex', ['checkpoint-load'])
        assert p.apply(repo, 'codex', ['checkpoint-load'], proposal['approval_digest'])['status'] == 'committed'
        # macOS assigns an APFS volume's st_dev at mount, so a reboot can renumber it. A finished
        # journal pinning the old number must not block later commands; an unresolved one must.
        journal = next((repo / p.STATE / 'operations').glob('*/journal.json'))
        dev = repo.stat().st_dev
        def renumber(value):
            if isinstance(value, dict):
                return {k: renumber(v) for k, v in value.items()}
            if isinstance(value, list):
                if len(value) == 2 and value[0] == dev and type(value[1]) is int:
                    return [dev + 1, value[1]]
                return [renumber(v) for v in value]
            return value
        rebooted = renumber(json.loads(journal.read_text()))
        assert rebooted['root_identity'] == [dev + 1, repo.stat().st_ino]
        journal.write_text(json.dumps(rebooted))
        assert {e['action'] for e in p.preview(repo, 'codex', ['checkpoint-load'])['entries']} == {'current'}
        journal.write_text(json.dumps({**rebooted, 'status': 'prepared'}))
        fails(lambda: p.operations(repo))
    print('Portable refresh preview passed: classification, ownership, source, no writes, symlinks, capabilities, nested linked worktrees, renumbered volume.')


def onboarding_checks():
    import contextlib
    import io
    outputs, _ = p.source()
    for runtime in p.RUNTIMES:
        for name in p.NAMES:
            assert p.released(runtime, name, p.manifest(outputs[runtime][name])), (runtime, name)
    old = (ROOT / 'tools/fixtures/project-skills/load-v1.md').read_text()
    with tempfile.TemporaryDirectory(prefix='lc-upgrade-') as scratch:
        root = Path(scratch).resolve()
        for runtime in p.RUNTIMES:
            body = p.parity.skill_text(old) if runtime == 'codex' else old
            put(root / ('.' + runtime) / 'skills/checkpoint-load/SKILL.md', body)
        before = snapshot(root)
        with contextlib.redirect_stdout(io.StringIO()):
            p.onboard(root, 'codex', True)
            p.onboard(root, 'claude', True)
        assert snapshot(root) == before
        with contextlib.redirect_stdout(io.StringIO()):
            p.onboard(root, 'codex')
            p.onboard(root, 'claude')
        for runtime in p.RUNTIMES:
            path = root / ('.' + runtime) / 'skills/checkpoint-load/SKILL.md'
            assert 'set_thread_title' in path.read_text()
            assert (root / p.STATE / 'receipts' / runtime / 'checkpoint-load.json').exists()
        assert len(list((root / p.STATE / 'operations').glob('*/backup/bundles/*/checkpoint-load/SKILL.md'))) == 3
        before = snapshot(root)
        with contextlib.redirect_stdout(io.StringIO()):
            assert not p.onboard(root, 'codex')
            assert not p.onboard(root, 'claude')
        assert snapshot(root) == before
        custom = root / '.codex/skills/checkpoint-load/SKILL.md'
        custom.write_text('my customized workflow')
        # A matching historical file plus extra resources is not a released bundle.
        duplicate = root / '.agents/skills/checkpoint-load'
        (duplicate / 'SKILL.md').write_text(old)
        put(duplicate / 'references/custom.md', 'keep this resource')
        (root / p.STATE / 'receipts/agents/checkpoint-load.json').unlink()
        before = snapshot(root)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            p.onboard(root, 'codex')
        assert 'PRESERVED-CUSTOMIZED' in output.getvalue()
        assert snapshot(root) == before
        # The real onboarding CLI must ignore stale rendered source for static skills.
        project = root / 'native'
        put(project / '.claude/skills/load/SKILL.md', old)
        put(project / '.agents/skills/load/SKILL.md', old)
        command = [sys.executable, '-B', str(ROOT / 'skills/onboard/scripts/codex-parity.py'),
                   '--project', str(project), '--codex']
        before = snapshot(project)
        subprocess.run(command + ['--dry-run'], check=True, capture_output=True)
        assert snapshot(project) == before
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        for runtime in ('codex', 'agents'):
            assert 'set_thread_title' in (project / ('.' + runtime) / 'skills/checkpoint-load/SKILL.md').read_text()
        assert 'set_thread_title' in (project / '.claude/skills/checkpoint-load/SKILL.md').read_text()
        # The added discovery surface uses the existing interrupted-publication recovery.
        recovery = root / 'agents-recovery'
        target = recovery / '.agents/skills/checkpoint-load'
        put(target / 'SKILL.md', old)
        original = observed(target)
        proposal = p.preview(recovery, 'agents', ['checkpoint-load'])
        real_move = p.move
        def interrupted(root, value, item, src, dst, snap, bundle):
            real_move(root, value, item, src, dst, snap, bundle)
            if bundle and src == 'stage':
                raise ValueError('interrupted agents publication')
        with patch.object(p, 'move', interrupted):
            fails(lambda: p.apply(recovery, 'agents', ['checkpoint-load'], proposal['approval_digest']))
        assert observed(target) == original
        assert not (recovery / p.STATE / 'receipts/agents/checkpoint-load.json').exists()
        # Git-dirty released content is still preserved during automatic onboarding.
        project = root / 'dirty'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        put(project / '.codex/skills/checkpoint-load/SKILL.md', 'original tracked custom skill')
        subprocess.run(['git', '-C', str(project), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(project), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        target = project / '.codex/skills/checkpoint-load/SKILL.md'
        target.write_text(p.parity.skill_text(old))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            p.onboard(project, 'codex')
        assert 'PRESERVED-DIRTY' in output.getvalue()
        assert target.read_text() == p.parity.skill_text(old)
    print('Onboarding upgrades passed: released legacy bundles, stale source, duplicates, backups, dry-run, custom and dirty preservation.')


def seeded(root, old=True):
    root.mkdir(parents=True)
    put(root / '.claude_states/keep.md', 'unchanged checkpoint')
    put(root / '.codex/config.toml', '# unchanged config')
    if old:
        for runtime in ('claude', 'codex'):
            for name in p.NAMES:
                target = root / ('.' + runtime) / 'skills' / name
                put(target / 'SKILL.md', 'old ' + runtime + '/' + name)
                (target / 'SKILL.md').chmod(0o750)
                target.chmod(0o700)
                record(root, runtime, name, p.existing(target), 'a' * 64)


def observed(path):
    if not path.exists():
        return None
    st = path.stat()
    contents = ({str(f.relative_to(path)): (f.read_bytes() if f.is_file() else None,
                                            f.stat().st_mode, f.stat().st_ino)
                 for f in path.rglob('*')} if path.is_dir() else path.read_bytes())
    return st.st_dev, st.st_ino, st.st_mode, contents


def selected(root):
    return {(runtime, name, bundle): observed(root / ('.' + runtime) / 'skills' / name if bundle
                                               else root / p.STATE / 'receipts' / runtime / (name + '.json'))
            for runtime in ('claude', 'codex') for name in p.NAMES for bundle in (True, False)}


def child(root, action, boundary):
    import signal
    events, inside = [], [False]
    def event(name):
        events.append(name)
        if len(events) == boundary:
            os.kill(os.getpid(), signal.SIGKILL)
    real_persist, real_rename = p.persist, p.exclusive
    real_replace, real_sync, real_open = p.os.replace, p.os.fsync, p.os.fdopen
    def persist(root, value):
        event('before:persist:' + value['status'])
        inside[0] = True
        try:
            real_persist(root, value)
        finally:
            inside[0] = False
        event('after:persist:' + value['status'])
    def rename(src, dst, anchors=None):
        if anchors:
            event('before:rename')
        real_rename(src, dst, anchors)
        if anchors:
            event('after:rename')
    def replace(*args, **kwargs):
        event('before:journal-replace')
        result = real_replace(*args, **kwargs)
        event('after:journal-replace')
        return result
    def sync(fd):
        if inside[0]:
            event('before:journal-fsync')
        result = real_sync(fd)
        if inside[0]:
            event('after:journal-fsync')
        return result
    class Stream:
        def __init__(self, wrapped):
            self.wrapped = wrapped
        def __enter__(self):
            self.wrapped.__enter__()
            return self
        def __exit__(self, *args):
            return self.wrapped.__exit__(*args)
        def __getattr__(self, name):
            return getattr(self.wrapped, name)
        def write(self, data):
            event('before:journal-temp-write')
            split = len(data) // 2
            result = self.wrapped.write(data[:split])
            self.wrapped.flush()
            event('during:journal-temp-write')
            result += self.wrapped.write(data[split:])
            event('after:journal-temp-write')
            return result
    def opened(*args, **kwargs):
        stream = real_open(*args, **kwargs)
        return Stream(stream) if inside[0] else stream
    if action in ('hold-apply', 'hold-prepared'):
        ready = Path(str(root) + '.ready')
        original_preview = p.preview
        calls = [0]
        def hold():
            ready.write_text('locked')
            while True:
                signal.pause()
        def preview(*args):
            value = original_preview(*args)
            calls[0] += 1
            if calls[0] == 3 and action == 'hold-apply':
                hold()
            return value
        def prepared(root, value):
            real_persist(root, value)
            if value['status'] == 'prepared' and action == 'hold-prepared':
                hold()
        with patch.object(p, 'preview', preview), patch.object(p, 'persist', prepared):
            value = p.preview(root, 'both', list(p.NAMES))
            p.apply(root, 'both', list(p.NAMES), value['approval_digest'])
        raise AssertionError('hold must be killed by parent')
    if action == 'prepare-recovery':
        def crash(root, value):
            if value['status'] == 'committed':
                os.kill(os.getpid(), signal.SIGKILL)
            real_persist(root, value)
        p.persist = crash
        proposal = p.preview(root, 'both', list(p.NAMES))
        p.apply(root, 'both', list(p.NAMES), proposal['approval_digest'])
        raise AssertionError('expected kill before commit')
    with patch.object(p, 'persist', persist), patch.object(p, 'exclusive', rename), \
         patch.object(p.os, 'replace', replace), patch.object(p.os, 'fsync', sync), patch.object(p.os, 'fdopen', opened):
        if action == 'apply':
            proposal = p.preview(root, 'both', list(p.NAMES))
            p.apply(root, 'both', list(p.NAMES), proposal['approval_digest'])
        else:
            operation = next((root / p.STATE / 'operations').iterdir()).name
            p.recover(root, operation)
    print(json.dumps(events))


def subprocess_child(root, action, boundary=0):
    return subprocess.run([sys.executable, '-B', __file__, '--child', str(root), action, str(boundary)],
                          capture_output=True, text=True)


def recover_twice(root, baseline):
    directory = root / p.STATE / 'operations'
    journals = list(directory.glob('*/journal.json')) if directory.exists() else []
    if not journals:
        assert selected(root) == baseline
        return 'retained-before-journal'
    assert len(journals) == 1
    value = json.loads(journals[0].read_text())
    if value['status'] == 'committed':
        assert all(e['action'] == 'current' for e in p.preview(root, 'both', list(p.NAMES))['entries'])
        before = snapshot(root)
        fails(lambda: p.recover(root, value['operation_id']))
        assert snapshot(root) == before
        return 'committed'
    for _ in range(2):
        result = subprocess_child(root, 'recover')
        assert result.returncode == 0, result.stderr
        assert selected(root) == baseline
    assert (root / '.claude_states/keep.md').read_text() == 'unchanged checkpoint'
    assert (root / '.codex/config.toml').read_text() == '# unchanged config'
    return 'recovered'


def fault_boundaries(events):
    # Test every rename and each journal helper boundary in every distinct phase.
    selected, seen, phase, within = [], set(), '', {}
    for index, event in enumerate(events, 1):
        if event.startswith('before:persist:'):
            phase, within = event.rsplit(':', 1)[1], {}
        within[event] = within.get(event, 0) + 1
        key = (phase, event, within[event])
        if event.endswith(':rename') or key not in seen:
            selected.append(index)
            seen.add(key)
    return selected


def transaction_checks():
    import signal
    with tempfile.TemporaryDirectory(prefix='lc023-transactions-') as scratch:
        directory = Path(scratch).resolve()
        counts = {}
        for old in (False, True):
            root = directory / ('trace-old' if old else 'trace-new')
            seeded(root, old)
            trace = subprocess_child(root, 'apply')
            assert trace.returncode == 0, trace.stderr
            events = json.loads(trace.stdout)
            counts['apply-old' if old else 'apply-new'] = len(fault_boundaries(events))
            for boundary in fault_boundaries(events):
                root = directory / ('old-' if old else 'new-') / str(boundary)
                seeded(root, old)
                baseline = selected(root)
                result = subprocess_child(root, 'apply', boundary)
                assert result.returncode == -signal.SIGKILL, (boundary, result.stderr)
                recover_twice(root, baseline)
        for old in (False, True):
            root = directory / ('trace-recover-old' if old else 'trace-recover-new')
            seeded(root, old)
            assert subprocess_child(root, 'prepare-recovery').returncode == -signal.SIGKILL
            trace = subprocess_child(root, 'recover')
            assert trace.returncode == 0, trace.stderr
            events = json.loads(trace.stdout)
            counts['recover-old' if old else 'recover-new'] = len(fault_boundaries(events))
            for boundary in fault_boundaries(events):
                root = directory / ('recover-old-' if old else 'recover-new-') / str(boundary)
                seeded(root, old)
                baseline = selected(root)
                assert subprocess_child(root, 'prepare-recovery').returncode == -signal.SIGKILL
                result = subprocess_child(root, 'recover', boundary)
                assert result.returncode == -signal.SIGKILL, (boundary, result.stderr)
                recover_twice(root, baseline)
        print('Portable refresh SIGKILL boundaries passed: ' + json.dumps(counts), flush=True)
        # Concurrent edits and symlinks at payload leaves preserve other safe entries.
        for kind in ('edited', 'symlink', 'empty-directory'):
            root = directory / kind
            seeded(root)
            baseline = selected(root)
            assert subprocess_child(root, 'prepare-recovery').returncode == -signal.SIGKILL
            target = root / '.codex/skills/checkpoint-load'
            if kind == 'edited':
                put(target / 'SKILL.md', 'concurrent edit')
            else:
                target.rename(root / 'user-held')
                if kind == 'symlink':
                    target.symlink_to(root / 'user-held')
                else:
                    target.mkdir()
            operation = next((root / p.STATE / 'operations').iterdir()).name
            receipt = (root / p.STATE / 'receipts/codex/checkpoint-load.json').read_bytes()
            fails(lambda: p.recover(root, operation))
            assert (root / p.STATE / 'receipts/codex/checkpoint-load.json').read_bytes() == receipt
            assert observed(root / '.claude/skills/checkpoint-load') == baseline['claude', 'checkpoint-load', True]
            assert observed(root / '.codex/skills/checkpoint-list') == baseline['codex', 'checkpoint-list', True]
            if kind == 'edited':
                assert (target / 'SKILL.md').read_text() == 'concurrent edit'
            elif kind == 'symlink':
                assert target.is_symlink()
            else:
                assert not list(target.iterdir())
        # Path-edited journals fail before writes.
        root = directory / 'tampered-journal'
        seeded(root)
        assert subprocess_child(root, 'prepare-recovery').returncode == -signal.SIGKILL
        path = next((root / p.STATE / 'operations').glob('*/journal.json'))
        value = json.loads(path.read_text())
        value['entries'][0]['bundle']['target'] = '../../foreign'
        path.write_text(json.dumps(value))
        before = snapshot(root)
        fails(lambda: p.recover(root, path.parent.name))
        assert snapshot(root) == before
        # Actual apply/apply and apply/recover processes contend on the shared lock.
        import time
        for action in ('apply', 'recover'):
            root = directory / ('contention-' + action)
            seeded(root)
            holder_action = 'hold-apply' if action == 'apply' else 'hold-prepared'
            holder = subprocess.Popen([sys.executable, '-B', __file__, '--child', str(root), holder_action, '0'],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 15
                while not Path(str(root) + '.ready').exists():
                    assert holder.poll() is None, holder.communicate()
                    assert time.monotonic() < deadline, 'holder failed to acquire lock'
                    time.sleep(0.02)
                result = subprocess_child(root, action)
                assert result.returncode != 0 and 'busy' in result.stderr, result.stderr
            finally:
                holder.kill()
                holder.communicate(timeout=10)
            if action == 'recover':
                assert p.preview(root, 'both', list(p.NAMES))['conflicts']
            assert subprocess_child(root, action).returncode == 0
        # Alter staged/source content after preparation: no original target is lost.
        for kind in ('stage', 'source'):
            root = directory / ('tamper-' + kind)
            seeded(root)
            before = selected(root)
            real = p.persist
            fired = [False]
            def tamper(root, value):
                real(root, value)
                if value['status'] == 'prepared' and not fired[0]:
                    fired[0] = True
                    if kind == 'stage':
                        put(root / value['entries'][0]['bundle']['stage'] / 'SKILL.md', 'tampered')
                    else:
                        p.source = lambda: ({}, 'f' * 64)
            original_source = p.source
            proposal = p.preview(root, 'both', list(p.NAMES))
            try:
                with patch.object(p, 'persist', tamper):
                    fails(lambda: p.apply(root, 'both', list(p.NAMES), proposal['approval_digest']))
            finally:
                p.source = original_source
            assert selected(root) == before
        # Revalidation between publications and during backup protects concurrent writers.
        for kind in ('source-middle', 'stage-middle', 'backup-edit', 'destination-race'):
            root = directory / kind
            seeded(root)
            baseline = selected(root)
            proposal = p.preview(root, 'both', list(p.NAMES))
            real_move, real_exclusive, original_source = p.move, p.exclusive, p.source
            fired = [False]
            def moving(root, value, item, src, dst, snap, bundle):
                real_move(root, value, item, src, dst, snap, bundle)
                if bundle and src == 'stage' and not fired[0] and kind.endswith('middle'):
                    fired[0] = True
                    if kind == 'source-middle':
                        p.source = lambda: ({}, 'f' * 64)
                    else:
                        put(root / value['entries'][1]['bundle']['stage'] / 'SKILL.md', 'concurrent stage edit')
            def renaming(src, dest, anchors=None):
                if anchors and not fired[0]:
                    if kind == 'backup-edit' and '/skills/' in str(src):
                        fired[0] = True
                        put(src / 'SKILL.md', 'edited during backup')
                    elif kind == 'destination-race' and '/skills/' in str(dest):
                        fired[0] = True
                        dest.mkdir()
                real_exclusive(src, dest, anchors)
            try:
                with patch.object(p, 'move', moving), patch.object(p, 'exclusive', renaming):
                    fails(lambda: p.apply(root, 'both', list(p.NAMES), proposal['approval_digest']))
            finally:
                p.source = original_source
            assert fired[0]
            if kind.endswith('middle'):
                assert selected(root) == baseline
            else:
                backups = list((root / p.STATE / 'operations').glob('*/backup/bundles/claude/checkpoint-save/SKILL.md'))
                assert len(backups) == 1
                if kind == 'backup-edit':
                    assert backups[0].read_text() == 'edited during backup'
                else:
                    assert backups[0].read_text() == 'old claude/checkpoint-save'
                    assert not list((root / '.claude/skills/checkpoint-save').iterdir())
        # An incomplete journal blocks another apply after the killed writer's lock is released.
        root = directory / 'incomplete-blocks-apply'
        seeded(root)
        assert subprocess_child(root, 'prepare-recovery').returncode == -signal.SIGKILL
        before = selected(root)
        value = p.preview(root, 'both', list(p.NAMES))
        assert value['conflicts']
        fails(lambda: p.apply(root, 'both', list(p.NAMES), value['approval_digest']))
        assert selected(root) == before
        print('Portable refresh recovery passed: concurrent edits, symlinks, empty directories, journal tampering, lock contention, source/stage tampering.', flush=True)


def retirement_checks():
    """LC-036: a released old-name project skill leaves discovery; a customized one stays."""
    import contextlib
    import io
    saved, p.RELEASES = p.RELEASES, REAL_RELEASES
    try:
        old = (ROOT / 'tools/fixtures/project-skills/load-v1.md').read_text()
        with tempfile.TemporaryDirectory(prefix='lc-retire-') as scratch:
            root = Path(scratch).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            put(root / '.codex/skills/load/SKILL.md', p.parity.skill_text(old))
            put(root / '.claude/skills/load/SKILL.md', old)
            put(root / '.claude/skills/sessions/SKILL.md', 'my customized sessions')
            with contextlib.redirect_stdout(io.StringIO()) as out:
                p.onboard(root, 'codex', True)
                p.onboard(root, 'claude', True)
            assert (root / '.claude/skills/load/SKILL.md').exists(), 'dry run moved a skill'
            assert 'PLANNED-RETIRE' in out.getvalue()
            with contextlib.redirect_stdout(io.StringIO()):
                p.onboard(root, 'codex')
                p.onboard(root, 'claude')
            assert not (root / '.codex/skills/load').exists() and not (root / '.claude/skills/load').exists()
            assert list((root / p.STATE / 'retired/claude').glob('load-*/SKILL.md'))
            assert 'set_thread_title' in (root / '.codex/skills/checkpoint-load/SKILL.md').read_text()
            assert (root / '.claude/skills/sessions/SKILL.md').read_text() == 'my customized sessions'
    finally:
        p.RELEASES = saved


def followup_checks():
    """Review of #66: legacy journals, lock contention, edits during retirement, failed create."""
    import contextlib
    import fcntl
    import io
    old_names = {'checkpoint': 'checkpoint-save', 'load': 'checkpoint-load', 'sessions': 'checkpoint-list'}

    def seed(root):
        for old in old_names:
            put(root / '.claude/skills' / old / 'SKILL.md', 'released old ' + old + '\n')

    def release(root):
        rows = [f'claude {old} {p.sha(p.canonical(p.existing(root / ".claude/skills" / old)))}' for old in old_names]
        text = REAL_RELEASES.read_text()
        patched = Path(tempfile.mkdtemp(dir=SCRATCH)).resolve() / 'releases.md'
        patched.write_text(text.replace('\n```\n', '\n' + '\n'.join(rows) + '\n```\n', 1))
        p.RELEASES = patched

    def project(scratch):
        root = Path(scratch).resolve()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        seed(root)
        release(root)
        return root

    def quiet(call):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            try:
                return call(), out.getvalue()
            except BaseException as error:
                return error, out.getvalue()

    saved = p.RELEASES
    try:
        # 1. Journals written by the parent release name the old skills; they must still validate.
        with tempfile.TemporaryDirectory(prefix='lc-legacy-journal-') as scratch:
            root = project(scratch)
            result, _ = quiet(lambda: p.onboard(root, 'codex'))
            assert not isinstance(result, BaseException), result
            journals = list((root / p.STATE / 'operations').glob('*/journal.json'))
            assert journals
            for journal in journals:
                text = journal.read_text()
                for old, new in old_names.items():
                    text = text.replace(new, old)
                journal.write_text(text)
            assert p.operations(root), 'legacy journals were not read'
            result, _ = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            for old, new in old_names.items():
                assert (root / '.claude/skills' / new / 'SKILL.md').exists(), new
                assert not (root / '.claude/skills' / old).exists(), old

        # 2. Lock contention: nothing is parked and nothing is created.
        with tempfile.TemporaryDirectory(prefix='lc-retire-lock-') as scratch:
            root = project(scratch)
            lock = root / p.STATE / 'lock'
            lock.parent.mkdir(parents=True)
            fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                result, _ = quiet(lambda: p.onboard(root, 'claude'))
            finally:
                os.close(fd)
            assert isinstance(result, ValueError) and 'busy' in str(result), result
            for old, new in old_names.items():
                assert (root / '.claude/skills' / old / 'SKILL.md').exists(), old
                assert not (root / '.claude/skills' / new).exists(), new
            assert not (root / p.STATE / 'retired').exists()

        # 2b. A lock taken after the create, before the move, stops the move itself.
        with tempfile.TemporaryDirectory(prefix='lc-retire-lock2-') as scratch:
            root = project(scratch)
            real_apply, held, calls = p.apply, [], []

            def apply_then_lock(*args, **kwargs):
                result = real_apply(*args, **kwargs)
                calls.append(1)
                if len(calls) == len(old_names):
                    held.append(os.open(root / p.STATE / 'lock', os.O_RDWR))
                    fcntl.flock(held[0], fcntl.LOCK_EX)
                return result

            try:
                with patch.object(p, 'apply', apply_then_lock):
                    result, _ = quiet(lambda: p.onboard(root, 'claude'))
            finally:
                for fd in held:
                    os.close(fd)
            assert isinstance(result, ValueError) and 'busy' in str(result), result
            for old in old_names:
                assert (root / '.claude/skills' / old / 'SKILL.md').exists(), old
            assert not (root / p.STATE / 'retired').exists()

        # 3. An edit that lands after planning, before the move, keeps that skill in place.
        with tempfile.TemporaryDirectory(prefix='lc-retire-edit-') as scratch:
            root = project(scratch)
            real_apply = p.apply

            def apply_then_edit(*args, **kwargs):
                result = real_apply(*args, **kwargs)
                with (root / '.claude/skills/load/SKILL.md').open('a') as stream:
                    stream.write('my edit\n')
                return result

            with patch.object(p, 'apply', apply_then_edit):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            assert 'KEPT' in out
            assert 'my edit' in (root / '.claude/skills/load/SKILL.md').read_text(), 'edited skill was parked'
            assert not (root / '.claude/skills/checkpoint').exists() and not (root / '.claude/skills/sessions').exists()
            assert not list((root / p.STATE / 'retired/claude').glob('load-*'))
            assert len(list((root / p.STATE / 'retired/claude').glob('*-*'))) == 2
            for new in old_names.values():
                assert (root / '.claude/skills' / new / 'SKILL.md').exists(), new

        # 3b. The directory replaced by a byte-identical copy after planning is a different
        # directory; the move is refused rather than assumed safe.
        with tempfile.TemporaryDirectory(prefix='lc-retire-swap-') as scratch:
            root = project(scratch)
            real_apply = p.apply

            def apply_then_swap(*args, **kwargs):
                result = real_apply(*args, **kwargs)
                target = root / '.claude/skills/load'
                before = p.snapshot(target, True)
                # Keep the original inode allocated so the replacement cannot reuse its identity.
                original = Path(tempfile.mkdtemp(prefix='original-load-', dir=root)) / 'load'
                target.rename(original)
                put(target / 'SKILL.md', 'released old load\n')
                assert p.identity(target) != before['identity'], 'swap fixture reused the directory identity'
                assert p.existing(target) == before['manifest'], 'swap fixture changed the released bundle'
                return result

            with patch.object(p, 'apply', apply_then_swap):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            assert 'KEPT' in out and (root / '.claude/skills/load/SKILL.md').exists(), 'swapped directory was parked'

        # 4. A failed create leaves the old skills active, never an empty set.
        with tempfile.TemporaryDirectory(prefix='lc-retire-fail-') as scratch:
            root = project(scratch)

            def refuse(*args, **kwargs):
                raise ValueError('create failed')

            with patch.object(p, 'apply', refuse):
                result, _ = quiet(lambda: p.onboard(root, 'claude'))
            assert isinstance(result, ValueError), result
            for old in old_names:
                assert (root / '.claude/skills' / old / 'SKILL.md').exists(), old
            assert not (root / p.STATE / 'retired').exists()
    finally:
        p.RELEASES = saved


def hardening_checks():
    """Review of #67: unusable replacements, edits during the final check, parent swaps, mirrors."""
    import contextlib
    import io
    old_names = {'checkpoint': 'checkpoint-save', 'load': 'checkpoint-load', 'sessions': 'checkpoint-list'}

    def quiet(call):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            try:
                return call(), out.getvalue()
            except BaseException as error:
                return error, out.getvalue()

    def project(scratch, runtimes=('claude',)):
        root = Path(scratch).resolve()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        rows = []
        for runtime in runtimes:
            for old in old_names:
                put(root / ('.' + runtime) / 'skills' / old / 'SKILL.md', 'released old ' + old + '\n')
                key = 'codex' if runtime in ('codex', 'agents') else runtime
                rows.append(f'{key} {old} {p.sha(p.canonical(p.existing(root / ("." + runtime) / "skills" / old)))}')
        patched = Path(tempfile.mkdtemp(dir=SCRATCH)).resolve() / 'releases.md'
        patched.write_text(REAL_RELEASES.read_text().replace('\n```\n', '\n' + '\n'.join(rows) + '\n```\n', 1))
        p.RELEASES = patched
        return root

    def active(root, runtime, names):
        return [n for n in names if (root / ('.' + runtime) / 'skills' / n / 'SKILL.md').exists()]

    saved = p.RELEASES
    try:
        # 1. A directory is not a published replacement: empty or customized stays, old stays active.
        for kind in ('empty', 'customized'):
            with tempfile.TemporaryDirectory(prefix='lc-retire-repl-') as scratch:
                root = project(scratch)
                replacement = root / '.claude/skills/checkpoint-load'
                replacement.mkdir()
                if kind == 'customized':
                    put(replacement / 'SKILL.md', 'my own checkpoint-load\n')
                result, out = quiet(lambda: p.onboard(root, 'claude'))
                assert not isinstance(result, BaseException), result
                assert (root / '.claude/skills/load/SKILL.md').read_text() == 'released old load\n', kind
                assert not list((root / p.STATE / 'retired/claude').glob('load-*')), kind
                assert 'RETIRE ' + str(root / '.claude/skills/load') not in out, kind
                if kind == 'empty':
                    assert not list(replacement.iterdir())
                else:
                    assert (replacement / 'SKILL.md').read_text() == 'my own checkpoint-load\n'
                # The other two replacements published normally, so their old copies retire.
                assert active(root, 'claude', ('checkpoint-save', 'checkpoint-list')) == ['checkpoint-save', 'checkpoint-list']
                assert not (root / '.claude/skills/checkpoint').exists()

        # 1a. Preview parity: a dry run never predicts retirement behind an unusable replacement.
        with tempfile.TemporaryDirectory(prefix='lc-retire-dry-') as scratch:
            root = project(scratch)
            (root / '.claude/skills/checkpoint-load').mkdir()
            before = snapshot(root)
            result, out = quiet(lambda: p.onboard(root, 'claude', True))
            assert not isinstance(result, BaseException), result
            assert 'PLANNED-RETIRE ' + str(root / '.claude/skills/load') not in out, 'dry run predicts a retirement that cannot happen'
            assert 'PLANNED-RETIRE ' + str(root / '.claude/skills/checkpoint') in out
            assert snapshot(root) == before, 'dry run wrote state'

        # 1c. A replacement published and then rewritten before the move is no longer verified
        # current; the old skill stays and the user's rewrite is untouched.
        with tempfile.TemporaryDirectory(prefix='lc-retire-rewrite-') as scratch:
            root = project(scratch)
            real_apply, calls = p.apply, []

            def apply_then_rewrite(*args, **kwargs):
                result = real_apply(*args, **kwargs)
                calls.append(1)
                if len(calls) == len(old_names):
                    put(root / '.claude/skills/checkpoint-load/SKILL.md', 'my rewrite of checkpoint-load\n')
                return result

            with patch.object(p, 'apply', apply_then_rewrite):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            assert (root / '.claude/skills/load/SKILL.md').exists()
            assert (root / '.claude/skills/checkpoint-load/SKILL.md').read_text() == 'my rewrite of checkpoint-load\n'
            assert 'RETIRE ' + str(root / '.claude/skills/load') not in out

        # 1b. Codex and the .agents mirror: a conflicting mirror keeps only its own old copy.
        with tempfile.TemporaryDirectory(prefix='lc-retire-mirror-') as scratch:
            root = project(scratch, ('codex', 'agents'))
            (root / '.agents/skills/checkpoint-load').mkdir()
            result, out = quiet(lambda: p.onboard(root, 'codex'))
            assert not isinstance(result, BaseException), result
            assert (root / '.agents/skills/load/SKILL.md').exists(), 'mirror old skill retired without a replacement'
            assert not list((root / p.STATE / 'retired/agents').glob('load-*'))
            assert not (root / '.codex/skills/load').exists() and active(root, 'codex', old_names.values()) == list(old_names.values())
            assert not (root / '.agents/skills/checkpoint').exists() and not (root / '.agents/skills/sessions').exists()

        # 2. An edit during the final tracked-changes check must stay in active discovery.
        with tempfile.TemporaryDirectory(prefix='lc-retire-late-') as scratch:
            root = project(scratch)
            old = root / '.claude/skills/load'
            real_tracked, calls = p.tracked_changes, []

            def edit_at_second(project_root, target):
                if Path(target) == old:
                    calls.append(1)
                    if len(calls) == 2:
                        with (old / 'SKILL.md').open('a') as stream:
                            stream.write('user edit during retirement\n')
                return real_tracked(project_root, target)

            real_exclusive, renames = p.exclusive, []

            def counting_exclusive(source, dest, anchors=None):
                if source == old:
                    renames.append(dest)
                return real_exclusive(source, dest, anchors)

            with patch.object(p, 'tracked_changes', edit_at_second), patch.object(p, 'exclusive', counting_exclusive):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            assert not renames, 'the edited skill was moved before the final snapshot caught it'
            assert len(calls) >= 2, 'edit never reached the final status check'
            assert 'user edit during retirement' in (old / 'SKILL.md').read_text(), 'edited skill left active discovery'
            assert 'RETIRE ' + str(old) not in out, 'late edit reported as retired'
            assert not list((root / p.STATE / 'retired/claude').glob('load-*'))

        # 2b. An edit that lands after the final snapshot, inside the rename, is detected by
        # readback and the original is restored.
        with tempfile.TemporaryDirectory(prefix='lc-retire-move-') as scratch:
            root = project(scratch)
            real_exclusive = p.exclusive

            def edit_after_rename(source, dest, anchors=None):
                real_exclusive(source, dest, anchors)
                if source.name == 'load' and 'retired' in str(dest):
                    with (dest / 'SKILL.md').open('a') as stream:
                        stream.write('edit during rename\n')

            with patch.object(p, 'exclusive', edit_after_rename):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            assert not isinstance(result, BaseException), result
            assert 'edit during rename' in (root / '.claude/skills/load/SKILL.md').read_text(), 'edited skill not restored'
            assert not list((root / p.STATE / 'retired/claude').glob('load-*'))
            assert 'RETIRE ' + str(root / '.claude/skills/load') not in out

        # 2c. Restoration never overwrites a writer that recreated the old path.
        with tempfile.TemporaryDirectory(prefix='lc-retire-occupied-') as scratch:
            root = project(scratch)
            real_exclusive = p.exclusive

            def edit_then_recreate(source, dest, anchors=None):
                real_exclusive(source, dest, anchors)
                if source.name == 'load' and 'retired' in str(dest):
                    with (dest / 'SKILL.md').open('a') as stream:
                        stream.write('edit during rename\n')
                    put(source / 'SKILL.md', 'someone else rewrote load\n')

            with patch.object(p, 'exclusive', edit_then_recreate):
                result, _ = quiet(lambda: p.onboard(root, 'claude'))
            assert isinstance(result, ValueError) and 'retained' in str(result), result
            assert (root / '.claude/skills/load/SKILL.md').read_text() == 'someone else rewrote load\n'
            kept = list((root / p.STATE / 'retired/claude').glob('load-*/SKILL.md'))
            assert kept and 'edit during rename' in kept[0].read_text()

        # 2c-empty. A writer that recreates an EMPTY directory is just as protected: a plain
        # rename would replace it, so only the no-clobber exchange keeps its identity.
        with tempfile.TemporaryDirectory(prefix='lc-retire-empty-') as scratch:
            root = project(scratch)
            real_exclusive, recreated = p.exclusive, []

            def edit_then_recreate_empty(source, dest, anchors=None):
                real_exclusive(source, dest, anchors)
                if source.name == 'load' and 'retired' in str(dest):
                    with (dest / 'SKILL.md').open('a') as stream:
                        stream.write('edit during rename\n')
                    source.mkdir()
                    recreated.append(p.identity(source))

            with patch.object(p, 'exclusive', edit_then_recreate_empty):
                result, out = quiet(lambda: p.onboard(root, 'claude'))
            old = root / '.claude/skills/load'
            assert isinstance(result, ValueError) and 'retained' in str(result), result
            assert recreated and p.identity(old) == recreated[0], 'the other writer\'s empty directory was replaced'
            assert not list(old.iterdir()), 'the other writer\'s directory was filled'
            kept = list((root / p.STATE / 'retired/claude').glob('load-*/SKILL.md'))
            assert kept and 'edit during rename' in kept[0].read_text(), 'edited bundle not retained'
            assert 'RETIRE ' + str(old) not in out, 'retirement reported as successful'

        # 2d. Swapping the skills directory after validation cannot substitute a bundle.
        with tempfile.TemporaryDirectory(prefix='lc-retire-parent-') as scratch:
            root = project(scratch)
            real_apply, calls = p.apply, []

            def apply_then_swap_parent(*args, **kwargs):
                result = real_apply(*args, **kwargs)
                calls.append(1)
                skills = root / '.claude/skills'
                moved = root / '.claude/skills.moved'
                if len(calls) == len(old_names):
                    os.rename(skills, moved)
                    skills.mkdir()
                    for child in moved.iterdir():
                        os.rename(child, skills / child.name)
                return result

            with patch.object(p, 'apply', apply_then_swap_parent):
                result, _ = quiet(lambda: p.onboard(root, 'claude'))
            assert isinstance(result, ValueError) and 'identity' in str(result), result
            assert (root / '.claude/skills/load/SKILL.md').exists()
            assert not list((root / p.STATE).glob('retired/*/*')), 'a bundle was parked through a swapped parent'
    finally:
        p.RELEASES = saved


def send_it_retirement_checks():
    """LC-045: the per-repo `send-it` tree leaves discovery once a complete `launch` tree exists."""
    import contextlib
    import io

    def project(scratch, runtime='claude', committed=True):
        root = Path(scratch).resolve()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        for name in p.LAUNCH_FILES:
            put(root / ('.' + runtime) / 'skills/send-it' / name, 'old ' + name + '\n')
            put(root / ('.' + runtime) / 'skills/launch' / name, 'new ' + name + '\n')
        if committed:
            subprocess.run(['git', '-C', str(root), 'add', '-A'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=t', '-c', 'user.email=t@t',
                            'commit', '-qm', 'seed'], check=True)
        return root

    def run(root, runtime='claude', dry_run=False):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            result = p.retire_send_it(root, runtime, dry_run)
        return result, out.getvalue()

    for runtime in ('claude', 'codex'):
        with tempfile.TemporaryDirectory(prefix='lc045-retire-') as scratch:
            root = project(scratch, runtime)
            old = root / ('.' + runtime) / 'skills/send-it'
            result, out = run(root, runtime, True)
            assert result and 'PLANNED-RETIRE' in out and (old / 'SKILL.md').exists(), 'dry run moved send-it'
            result, out = run(root, runtime)
            assert result and out.startswith('RETIRE '), out
            assert not old.exists(), runtime + ': send-it is still discoverable'
            parked = list((root / p.STATE / 'retired' / runtime).glob('send-it-*/SKILL.md'))
            assert parked and parked[0].read_text() == 'old SKILL.md\n', 'send-it was not parked intact'
            status = subprocess.run(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all'],
                                    capture_output=True, text=True, check=True).stdout
            assert '.launch-control' not in status, 'parked send-it is visible to git: ' + status
            assert run(root, runtime) == (False, ''), 'absent send-it was not a no-op'

    with tempfile.TemporaryDirectory(prefix='lc045-incomplete-') as scratch:
        root = project(scratch)
        (root / '.claude/skills/launch/references/verification.md').unlink()
        result, out = run(root)
        assert not result and 'KEPT' in out and (root / '.claude/skills/send-it/SKILL.md').exists(), out

    with tempfile.TemporaryDirectory(prefix='lc045-dirty-') as scratch:
        root = project(scratch)
        put(root / '.claude/skills/send-it/SKILL.md', 'my edit\n')
        result, out = run(root)
        assert not result and 'uncommitted' in out
        assert (root / '.claude/skills/send-it/SKILL.md').read_text() == 'my edit\n'

    with tempfile.TemporaryDirectory(prefix='lc045-symlink-') as scratch:
        root = project(scratch, committed=False)
        real = root / 'elsewhere'
        os.rename(root / '.claude/skills/send-it', real)
        os.symlink(real, root / '.claude/skills/send-it')
        result, out = run(root)
        assert not result and 'symlink' in out and (root / '.claude/skills/send-it').is_symlink(), out


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--child':
        child(Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]))
    else:
        checkpoint_contract_checks()
        preview_checks()
        onboarding_checks()
        retirement_checks()
        send_it_retirement_checks()
        followup_checks()
        hardening_checks()
        transaction_checks()
