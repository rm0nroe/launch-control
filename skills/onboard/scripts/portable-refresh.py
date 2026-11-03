#!/usr/bin/env python3
"""Refresh selected project checkpoint skills with guarded journal recovery."""
import argparse
import ctypes
import contextlib
import uuid
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
if sys.platform not in ('darwin', 'linux'):
    print('Portable refresh stopped: unsupported platform ' + sys.platform, file=sys.stderr)
    raise SystemExit(2)
import fcntl
HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('parity', HERE / 'codex-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)
NAMES = ('checkpoint-save', 'checkpoint-load', 'checkpoint-list')
OLD_NAMES = {'checkpoint': 'checkpoint-save', 'load': 'checkpoint-load', 'sessions': 'checkpoint-list'}
STATE = '.launch-control/refresh'
RUNTIMES = ('claude', 'codex', 'agents')
LAUNCH_FILES = ('SKILL.md', *('references/' + name + '.md' for name in
                                  ('delivery', 'implementation', 'ticket-intake', 'verification')))
RELEASES = HERE / '../references/project-skill-releases.md'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def checked(path):
    """Check every component before reading; do not resolve symlinks away."""
    path = path.absolute()
    for item in reversed((path, *path.parents)):
        try:
            mode = item.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError('symlink or special file: ' + str(item))
        if item != path and not stat.S_ISDIR(mode):
            raise ValueError('non-directory path component: ' + str(item))
    return path


def identity(path):
    checked(path)
    if not path.exists():
        return None
    s = path.stat()
    return [s.st_dev, s.st_ino]


def regular(path):
    checked(path)
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('expected regular file: ' + str(path))
        return stream.read()


def manifest(files):
    if files is None:
        return None
    return {name: {'sha256': sha(content), 'executable': executable}
            for name, (content, executable) in sorted(files.items())}


def existing(path):
    checked(path)
    return manifest(parity.bundle_tree(path))


def git(project, *args):
    result = subprocess.run(['git', '-C', str(project), *args], capture_output=True, text=True)
    if result.returncode:
        return None
    return result.stdout.strip()


def project_root(project):
    project = checked(project.absolute())
    if not project.is_dir():
        raise ValueError('project directory is missing: ' + str(project))
    root = git(project, 'rev-parse', '--show-toplevel')
    if root is None and any((parent / '.git').exists() or (parent / '.git').is_symlink() for parent in (project, *project.parents)):
        raise ValueError('Git root could not be resolved despite an existing .git marker')
    return checked(Path(root) if root else project)


def source():
    paths = [HERE / '../references/checkpoint-templates.md', HERE / 'codex-parity.py', Path(__file__).absolute(), RELEASES]
    data = [regular(Path(os.path.normpath(p))) for p in paths]
    sections = re.findall(r'^## (checkpoint-save|checkpoint-load|checkpoint-list)\n\n```markdown\n(.*?)^```$',
                          data[0].decode('utf-8'), re.MULTILINE | re.DOTALL)
    if sorted(name for name, _ in sections) != sorted(NAMES) or any(not body.strip() for _, body in sections):
        raise ValueError('expected exactly one nonempty section per portable skill')
    outputs = {runtime: {name: {'SKILL.md': ((parity.skill_text(body) if runtime != 'claude' else body)
                                           .rstrip('\n').encode('utf-8') + b'\n', 0)}
                         for name, body in sections} for runtime in RUNTIMES}
    digest = sha(canonical({'inputs': [sha(d) for d in data],
                            'outputs': {r: {n: manifest(f) for n, f in bundles.items()}
                                        for r, bundles in outputs.items()}}))
    return outputs, digest


def open_directory(path, anchors=None):
    """Pin each parent without following a symlink, including during replacement races."""
    path = path.absolute()
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = Path(path.anchor)
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            current /= component
            if anchors and str(current) in anchors:
                st = os.fstat(fd)
                if [st.st_dev, st.st_ino] != anchors[str(current)]:
                    raise ValueError('directory identity changed: ' + str(current))
        return fd
    except BaseException:
        os.close(fd)
        raise


def exclusive(source_path, dest, anchors=None):
    """No-clobber rename using pinned, no-follow parent directory descriptors."""
    checked(source_path)
    checked(dest)
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        name, flags = 'renameatx_np', 0x4 | 0x10
    elif sys.platform == 'linux':
        name, flags = 'renameat2', 1
    else:
        raise ValueError('unsupported publication platform: ' + sys.platform)
    fn = getattr(libc, name, None)
    if fn is None:
        raise ValueError('exclusive publication is unavailable: ' + name)
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fn.restype = ctypes.c_int
    fds = []
    try:
        for path in (source_path.parent, dest.parent):
            fds.append(open_directory(path, anchors))
        if fn(fds[0], os.fsencode(source_path.name), fds[1], os.fsencode(dest.name), flags):
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(dest))
    finally:
        for fd in fds:
            os.close(fd)


def capability():
    # Preview probes only disposable storage; apply must probe the target device too.
    with tempfile.TemporaryDirectory(prefix='lc023-capability-') as scratch:
        root = Path(scratch).resolve()
        a, b = root / 'a', root / 'b'
        a.mkdir()
        b.mkdir()
        before = identity(a)
        try:
            exclusive(a, b)
        except OSError as error:
            if error.errno != errno.EEXIST:
                raise
        else:
            raise ValueError('exclusive publication overwrote an existing directory')
        exclusive(a, root / 'c')
        if identity(root / 'c') != before:
            raise ValueError('exclusive publication changed identity')
    return sys.platform


def read_receipt(path, runtime, name):
    if not checked(path).exists():
        return None
    value = json.loads(regular(path))
    if (not isinstance(value, dict) or set(value) != {'version', 'runtime', 'skill', 'source_digest', 'output_manifest'}
            or type(value['version']) is not int or value['version'] != 1 or value['runtime'] != runtime or value['skill'] != name
            or not isinstance(value['source_digest'], str)
            or not re.fullmatch('[a-f0-9]{64}', value['source_digest'])):
        raise ValueError('invalid ownership receipt: ' + str(path))
    validate_manifest(value['output_manifest'])
    return value


def validate_manifest(value):
    if not isinstance(value, dict):
        raise ValueError('invalid output manifest')
    for name, entry in value.items():
        if (not isinstance(name, str) or not name or Path(name).is_absolute()
                or '..' in Path(name).parts or str(Path(name)) != name
                or not isinstance(entry, dict) or set(entry) != {'sha256', 'executable'}
                or not isinstance(entry['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', entry['sha256'])
                or type(entry['executable']) is not int or entry['executable'] & ~0o111):
            raise ValueError('invalid output manifest entry')


def operations(root):
    directory = checked(root / STATE / 'operations')
    if not directory.exists():
        return []
    if not directory.is_dir():
        raise ValueError('operations must be a directory')
    result = []
    for path in sorted(directory.iterdir()):
        checked(path)
        if not path.is_dir() or not re.fullmatch('[a-zA-Z0-9-]+', path.name):
            raise ValueError('invalid operation path: ' + str(path))
        record = json.loads(regular(path / 'journal.json'))
        # A finished journal is history: nothing replays it, yet it pins st_dev, which macOS
        # renumbers across reboots. Only an unresolved one must still match this worktree.
        if not (isinstance(record, dict) and record.get('operation_id') == path.name
                and record.get('status') in ('committed', 'recovered')):
            validate_journal(root, record, path.name)
        result.append(record)
    return result


def exclusion(root):
    raw = git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude')
    if raw is None:
        return None
    common = Path(git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    local = Path(git(root, 'rev-parse', '--absolute-git-dir'))
    path = root / '.gitignore' if common != local else Path(raw)
    checked(path)
    data = regular(path) if path.exists() else None
    return {'path': str(path), 'entry': '.launch-control/refresh/', 'original_sha256': sha(data) if data is not None else None,
            'required': data is None or b'.launch-control/refresh/' not in data.splitlines()}


def released(runtime, name, output):
    """Exact released bundle fingerprints, never names or similarity heuristics."""
    key = ('codex' if runtime == 'agents' else runtime) + ' ' + name + ' ' + sha(canonical(output))
    return key in regular(checked(Path(os.path.normpath(RELEASES)))).decode('utf-8').splitlines()


def tracked_changes(root, target):
    status = git(root, 'status', '--porcelain=v1', '--untracked-files=no', '--',
                 str(Path(target).relative_to(root)))
    if status is None and (root / '.git').exists():
        raise ValueError('cannot check tracked changes: ' + str(target))
    return bool(status)


def onboard(project, runtime, dry_run=False):
    """Upgrade eligible static skills using the same guarded refresh transaction."""
    if runtime not in ('claude', 'codex'):
        raise ValueError('onboarding runtime must be claude or codex')
    root = project_root(project)
    runtimes = [runtime]
    if runtime == 'codex' and checked(root / '.agents/skills').exists():
        runtimes.append('agents')
    proposals, pending, actions = [], [], {}
    for r in runtimes:
        found = plan_retirements(root, r)
        pending += found
        moved = {new for _, _, new, _, _ in found}
        for name in NAMES:
            # Claude generation owns absent files; .agents is only an existing mirror. A copy
            # that will leave under its old name is replaced under the new one.
            if (r in ('agents', 'claude') and name not in moved
                    and not checked(root / ('.' + r) / 'skills' / name).exists()):
                continue
            proposal = preview(root, r, [name])
            if any(c.startswith('explicit recovery required:') for c in proposal['conflicts']):
                raise ValueError('; '.join(proposal['conflicts']))
            entry = proposal['entries'][0]
            dirty = tracked_changes(root, entry['target'])
            if dirty:
                entry['action'] = 'preserved-dirty'
            elif proposal['conflicts']:
                entry['action'] = 'preserved-customized'
            proposals.append(proposal)
            actions[(r, name)] = entry['action']
    # Preflight every target before publishing; apply rechecks each digest under lock.
    changed = False
    for proposal in proposals:
        entry = proposal['entries'][0]
        action = entry['action']
        if action in ('create', 'upgrade'):
            if not dry_run:
                fresh = preview(root, entry['runtime'], [entry['skill']])
                if (fresh['entries'] != proposal['entries'] or fresh['source_digest'] != proposal['source_digest']
                        or tracked_changes(root, entry['target'])):
                    raise ValueError('skill changed during onboarding preflight: ' + entry['target'])
                result = apply(root, entry['runtime'], [entry['skill']], fresh['approval_digest'])
                print('BACKUP-STATE ' + str(root / STATE / 'operations' / result['operation_id']))
            changed = True
        print(('PLANNED-' if dry_run else '') + action.upper() + ' ' + entry['target'])
    # Old names leave discovery only after every replacement is published, so a failed
    # create can never leave a project with no active checkpoint skills.
    retired = retire_renamed(root, pending, actions, dry_run)
    return changed or retired


def plan_retirements(root, runtime):
    """Read-only: which released, untouched old-name skills this run would retire."""
    found = []
    for old, new in OLD_NAMES.items():
        path = checked(root / ('.' + runtime) / 'skills' / old)
        if not path.exists():
            continue
        if not released(runtime, old, existing(path)) or tracked_changes(root, path):
            print('KEPT ' + str(path) + ': not a released copy; the generated skill is now ' + new)
            continue
        found.append((runtime, old, new, snapshot(path, True), identity(path.parent)))
    return found


def retire_renamed(root, pending, actions, dry_run):
    """LC-036: the old generated names have no aliases. An old skill leaves discovery only when
    its replacement is a verified-current published bundle and its own bytes are still the
    released ones at the moment of the move. Park under the refresh lock with a guarded snapshot,
    pinned parents and a readback; changed content is put back, never overwriting another writer."""
    retired = False
    for runtime, old, new, expected, parent in pending:
        path = checked(root / ('.' + runtime) / 'skills' / old)
        if actions.get((runtime, new)) not in ('create', 'upgrade', 'current'):
            print('KEPT ' + str(path) + ': ' + new + ' is not a published replacement; the old skill stays active')
            continue
        if dry_run:
            print('PLANNED-RETIRE ' + str(path) + ' (now ' + new + ')')
            retired = True
            continue
        with locked(root):
            outputs, _ = source()
            replacement = checked(root / ('.' + runtime) / 'skills' / new)
            if not replacement.is_dir() or existing(replacement) != manifest(outputs[runtime][new]):
                print('KEPT ' + str(path) + ': ' + new + ' is not the verified current replacement')
                continue
            if (not path.exists() or tracked_changes(root, path) or snapshot(path, True) != expected
                    or not released(runtime, old, expected['manifest'])):
                print('KEPT ' + str(path) + ': changed or replaced during onboarding; the generated skill is now ' + new)
                continue
            retired = park(root, runtime, path, expected, parent, new) or retired
    return retired


def park(root, runtime, path, expected, parent, new):
    """Caller holds the refresh lock. Move `path` aside with a readback; restore it if it changed."""
    parked = root / STATE / 'retired' / runtime
    mkdir(root, parked)
    dest = parked / (path.name + '-' + uuid.uuid4().hex[:8])
    anchors = {str(root): identity(root), str(path.parent): parent, str(parked): identity(parked)}
    exclusive(path, dest, anchors)
    syncdir(path.parent)
    syncdir(parked)
    if snapshot(dest, True) != expected:
        try:
            exclusive(dest, path, anchors)
        except OSError:
            raise ValueError('changed skill retained at ' + str(dest) + '; ' + str(path) + ' is occupied') from None
        print('KEPT ' + str(path) + ': changed during the move and restored; the generated skill is now ' + new)
        return False
    print('RETIRE ' + str(path) + ' (now ' + new + ')')
    return True


def retire_send_it(project, runtime, dry_run=False):
    """LC-045: onboarding now generates the delivery skill as `launch`. The old `send-it` tree is
    rendered per repository, so no released fingerprint can prove it untouched the way
    retire_renamed does. It leaves discovery only once this run published a complete `launch`
    tree and it carries no uncommitted tracked change, and it is parked, never deleted."""
    root = project_root(project)
    skills = root / ('.' + runtime) / 'skills'
    path = skills / 'send-it'
    if path.is_symlink():
        print('KEPT ' + str(path) + ': a symlink; review it against launch, then remove it')
        return False
    if not checked(path).exists():
        return False
    if not path.is_dir() or tracked_changes(root, path):
        print('KEPT ' + str(path) + ': uncommitted changes; review it against launch, then remove it')
        return False
    if dry_run:
        print('PLANNED-RETIRE ' + str(path) + ' (now launch)')
        return True
    if not all(checked(skills / 'launch' / name).is_file() for name in LAUNCH_FILES):
        print('KEPT ' + str(path) + ': launch is not generated; the old skill stays active')
        return False
    with locked(root):
        exclude_state({'exclusion': exclusion(root), 'root': str(root)})
        return park(root, runtime, path, snapshot(path, True), identity(path.parent), 'launch')


def preview(project, runtime, names):
    if runtime not in (*RUNTIMES, 'both') or not names or len(names) != len(set(names)) or set(names) - set(NAMES):
        raise ValueError('select unique portable names and an explicit runtime')
    root = project_root(project)
    outputs, source_digest = source()
    platform = capability()
    for directory in (root / '.launch-control', root / STATE, root / STATE / 'receipts'):
        if checked(directory).exists() and not directory.is_dir():
            raise ValueError('state path is not a directory: ' + str(directory))
    lock = checked(root / STATE / 'lock')
    if lock.exists() and not lock.is_file():
        raise ValueError('lock path is not a regular file')
    unresolved = [o['operation_id'] for o in operations(root) if o['status'] not in ('committed', 'recovered')]
    runtimes = ('claude', 'codex') if runtime == 'both' else (runtime,)
    roots, entries, conflicts = {}, [], []
    if unresolved:
        conflicts.append('explicit recovery required: ' + ', '.join(unresolved))
    device = root.stat().st_dev
    for r in runtimes:
        directory = checked(root / ('.' + r) / 'skills')
        if directory.exists() and not directory.is_dir():
            raise ValueError('runtime skill root is not a directory: ' + str(directory))
        roots[r] = {str(p.relative_to(root)): identity(p) for p in (directory.parent, directory)}
        for p in (directory.parent, directory, root / STATE):
            if p.exists() and p.stat().st_dev != device:
                raise ValueError('targets and state must share the project device')
        for name in names:
            target = directory / name
            record_path = root / STATE / 'receipts' / r / (name + '.json')
            for touched in (target, record_path):
                for component in (touched, *touched.parents):
                    if component == root:
                        break
                    checked(component)
                    if component.exists() and component.stat().st_dev != device:
                        raise ValueError('target or state crosses devices: ' + str(component))
            before = existing(target)
            record = read_receipt(record_path, r, name)
            after = manifest(outputs[r][name])
            # Released bytes outrank a receipt: a stale receipt (offboard used to leave them) must
            # not turn current or released content into a conflict. A receipt only vouches for
            # content no release fingerprint covers.
            if before is None:
                action = 'create' if record is None else 'conflict'
            elif before == after:
                action = 'current'
            elif released(r, name, before) or (record is not None and record['output_manifest'] == before):
                action = 'upgrade'
            else:
                action = 'conflict'
            if action == 'conflict':
                conflicts.append(str(target))
            entries.append({'runtime': r, 'skill': name, 'target': str(target), 'receipt': str(record_path),
                            'original': before, 'original_identity': identity(target), 'proposed': after,
                            'old_receipt': record, 'receipt_identity': identity(record_path), 'action': action})
    proposal = {'version': 1, 'root': str(root), 'root_identity': identity(root), 'runtime_identities': roots,
                'platform': platform, 'source_digest': source_digest, 'entries': entries, 'conflicts': conflicts,
                'state': str(root / STATE), 'exclusion': exclusion(root)}
    proposal['approval_digest'] = sha(canonical(proposal))
    return proposal


def snapshot(path, bundle):
    checked(path)
    if not path.exists():
        return None
    s = path.stat()
    return {'identity': [s.st_dev, s.st_ino], 'mode': stat.S_IMODE(s.st_mode),
            'manifest': existing(path) if bundle else {'sha256': sha(regular(path))}}


def syncdir(path):
    fd = open_directory(checked(path))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(root, path):
    path.relative_to(root)
    checked(root)
    fd = open_directory(root)
    try:
        for part in path.relative_to(root).parts:
            try:
                os.mkdir(part, mode=0o755, dir_fd=fd)
                os.fsync(fd)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            if os.fstat(child).st_dev != os.fstat(fd).st_dev:
                os.close(child)
                raise ValueError('targets and state must share a device')
            os.close(fd)
            fd = child
    finally:
        os.close(fd)


def anchors_ok(root, record):
    if identity(root) != record['root_identity']:
        raise ValueError('worktree root identity changed')
    for relative, expected in record['anchors'].items():
        if identity(root / relative) != expected:
            raise ValueError('directory identity changed: ' + str(root / relative))


def persist(root, record):
    """Replace only this operation's journal, retaining a complete previous record."""
    anchors_ok(root, record)
    path = root / STATE / 'operations' / record['operation_id'] / 'journal.json'
    checked(path)
    parent = open_directory(path.parent, {str(root / p): i for p, i in record['anchors'].items()})
    temp = 'journal-' + uuid.uuid4().hex + '.tmp'
    try:
        st = os.fstat(parent)
        if [st.st_dev, st.st_ino] != record['anchors'][str(path.parent.relative_to(root))]:
            raise ValueError('journal parent changed')
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(canonical(record) + b'\n')
            stream.flush()
            os.fsync(stream.fileno())
        anchors_ok(root, record)
        os.replace(temp, 'journal.json', src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        os.close(parent)


@contextlib.contextmanager
def locked(root):
    original_root = identity(root)
    mkdir(root, root / STATE)
    path = checked(root / STATE / 'lock')
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('lock must be a regular file')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('portable refresh busy: ' + str(path)) from None
        if identity(root) != original_root or identity(path) != [os.fstat(fd).st_dev, os.fstat(fd).st_ino]:
            raise ValueError('worktree or lock identity changed')
        yield
    finally:
        os.close(fd)


def item_paths(runtime, name, operation, bundle):
    suffix = runtime + '/' + name + ('' if bundle else '.json')
    part = 'bundles' if bundle else 'receipts'
    base = STATE + '/operations/' + operation
    return {'target': '.' + runtime + '/skills/' + name if bundle else STATE + '/receipts/' + suffix,
            'stage': base + '/stage/' + part + '/' + suffix,
            'backup': base + '/backup/' + part + '/' + suffix,
            'quarantine': base + '/quarantine/' + part + '/' + suffix}


def validate_journal(root, record, operation):
    fields = {'version', 'operation_id', 'root_identity', 'runtime_identities', 'source_digest',
              'status', 'entries', 'anchors', 'intent'}
    if (not isinstance(record, dict) or set(record) != fields or type(record['version']) is not int
            or record['version'] != 1 or record['operation_id'] != operation
            or record['root_identity'] != identity(root)
            or not isinstance(record['source_digest'], str) or not re.fullmatch('[a-f0-9]{64}', record['source_digest'])
            or record['status'] not in ('prepared', 'applying', 'recovering', 'committed', 'recovered')
            or not isinstance(record['entries'], list) or not record['entries']
            or not isinstance(record['runtime_identities'], dict) or not isinstance(record['anchors'], dict)
            or not isinstance(record['intent'], str)):
        raise ValueError('invalid operation journal: ' + operation)
    seen, parents = set(), set()
    for entry in record['entries']:
        if not isinstance(entry, dict) or set(entry) != {'runtime', 'skill', 'bundle', 'receipt'}:
            raise ValueError('invalid journal entry')
        runtime, name = entry['runtime'], entry['skill']
        if runtime not in RUNTIMES or name not in (*NAMES, *OLD_NAMES) or (runtime, name) in seen:
            raise ValueError('invalid or duplicate journal target')
        seen.add((runtime, name))
        for part in ('bundle', 'receipt'):
            item = entry[part]
            expected = item_paths(runtime, name, operation, part == 'bundle')
            if not isinstance(item, dict) or set(item) != {*expected, 'original', 'proposed'}:
                raise ValueError('invalid journal snapshot fields')
            for key, relative in expected.items():
                if item[key] != relative:
                    raise ValueError('journal path differs from allowed target: ' + key)
                path = root / relative
                checked(path.parent)
                parents.update(str(p.relative_to(root)) for p in path.parents if p != root and root in p.parents)
            for key in ('original', 'proposed'):
                snap = item[key]
                if snap is None and key == 'original':
                    continue
                if (not isinstance(snap, dict) or set(snap) != {'identity', 'mode', 'manifest'}
                        or not isinstance(snap['identity'], list) or len(snap['identity']) != 2
                        or any(type(i) is not int or i < 0 for i in snap['identity'])
                        or snap['identity'][0] != root.stat().st_dev
                        or type(snap['mode']) is not int or not 0 <= snap['mode'] <= 0o7777):
                    raise ValueError('invalid journal identity or mode')
                if part == 'bundle':
                    validate_manifest(snap['manifest'])
                elif (not isinstance(snap['manifest'], dict) or set(snap['manifest']) != {'sha256'}
                      or not isinstance(snap['manifest']['sha256'], str)
                      or not re.fullmatch('[a-f0-9]{64}', snap['manifest']['sha256'])):
                    raise ValueError('invalid receipt snapshot')
    if set(record['anchors']) != parents:
        raise ValueError('journal has incomplete or foreign directory anchors')
    for relative, expected in record['anchors'].items():
        if not isinstance(expected, list) or len(expected) != 2 or any(type(i) is not int or i < 0 for i in expected):
            raise ValueError('invalid directory anchor')
    expected_runtimes = {r: {key: value for key, value in record['anchors'].items()
                             if key in ('.' + r, '.' + r + '/skills')} for r, _ in seen}
    if record['runtime_identities'] != expected_runtimes:
        raise ValueError('invalid runtime identities')
    anchors_ok(root, record)
    return record


def move(root, record, item, src, dst, snap, bundle):
    record['intent'] = item[src] + ' -> ' + item[dst]
    persist(root, record)
    anchors_ok(root, record)
    source_path, dest = root / item[src], root / item[dst]
    if snapshot(source_path, bundle) != snap:
        raise ValueError('content or identity changed: ' + str(source_path))
    exclusive(source_path, dest, {str(root): record['root_identity'],
                                **{str(root / p): i for p, i in record['anchors'].items()}})
    syncdir(source_path.parent)
    syncdir(dest.parent)
    anchors_ok(root, record)
    if snapshot(dest, bundle) != snap:
        raise ValueError('moved content changed; retained at ' + str(dest))


def restore_item(root, record, item, bundle):
    target, backup, quarantine = (root / item[k] for k in ('target', 'backup', 'quarantine'))
    before, proposed = item['original'], item['proposed']
    actual, saved, held = (snapshot(path, bundle) for path in (target, backup, quarantine))
    if saved is not None and saved != before:
        raise ValueError('changed backup retained at ' + str(backup))
    if held is not None and held != proposed:
        raise ValueError('changed quarantine retained at ' + str(quarantine))
    if actual == before:
        if saved is not None:
            raise ValueError('unexpected duplicate original retained at ' + str(backup))
        return
    if before is not None and saved != before:
        raise ValueError('original backup missing: ' + str(backup))
    if actual is not None:
        if actual != proposed or held is not None:
            raise ValueError('concurrent content retained at ' + str(target))
        move(root, record, item, 'target', 'quarantine', proposed, bundle)
    if before is not None:
        move(root, record, item, 'backup', 'target', before, bundle)
    if snapshot(target, bundle) != before:
        raise ValueError('original content was not restored: ' + str(target))


def rollback(root, record):
    validate_journal(root, record, record['operation_id'])
    if record['status'] == 'committed':
        raise ValueError('committed operation refuses rollback')
    if record['status'] == 'recovered':
        return record
    record['status'] = 'recovering'
    persist(root, record)
    conflicts = []
    for entry in reversed(record['entries']):
        try:
            restore_item(root, record, entry['bundle'], True)
            # Never restore an old receipt beside a conflicting payload.
            restore_item(root, record, entry['receipt'], False)
        except (OSError, ValueError) as error:
            conflicts.append(str(error))
    if conflicts:
        raise ValueError('recovery incomplete; ' + '; '.join(conflicts))
    record['status'], record['intent'] = 'recovered', ''
    persist(root, record)
    return record


def recover(project, operation):
    if not re.fullmatch('[a-zA-Z0-9-]+', operation):
        raise ValueError('invalid operation ID')
    root = project_root(project)
    path = checked(root / STATE / 'operations' / operation / 'journal.json')
    # Validate before creating a lock or writing any state.
    validate_journal(root, json.loads(regular(path)), operation)
    with locked(root):
        return rollback(root, json.loads(regular(path)))


def exclude_state(proposal):
    value = proposal['exclusion']
    if value is None:
        return
    append_exclusion(value)
    if subprocess.run(['git', '-C', proposal['root'], 'check-ignore', '--no-index', '-q',
                       STATE + '/'], capture_output=True).returncode != 0:
        raise ValueError('refresh state is not effectively ignored; resolve conflicting Git ignore rules')


def append_exclusion(value):
    if not value['required']:
        return
    path = checked(Path(value['path']))
    before = regular(path) if path.exists() else None
    if (sha(before) if before is not None else None) != value['original_sha256']:
        raise ValueError('ignore file changed after preview')
    if not path.parent.is_dir():
        raise ValueError('ignore parent is missing: ' + str(path.parent))
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if before is None else 0), 0o644, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        if identity(path) != [os.fstat(fd).st_dev, os.fstat(fd).st_ino] or (before is not None and regular(path) != before):
            raise ValueError('ignore file changed before append')
        data = (b'\n' if before and not before.endswith(b'\n') else b'') + value['entry'].encode() + b'\n'
        if os.write(fd, data) != len(data):
            raise OSError('incomplete ignore entry append')
        os.fsync(fd)
    finally:
        os.close(fd)
    syncdir(path.parent)


def stage_file(path, data, mode=0o644):
    checked(path)
    parent = open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    syncdir(path.parent)


def apply(project, runtime, names, expected):
    proposal = preview(project, runtime, names)
    if proposal['conflicts'] or proposal['approval_digest'] != expected:
        raise ValueError('preview conflict or approval digest mismatch')
    root = Path(proposal['root'])
    with locked(root):
        proposal = preview(root, runtime, names)
        if proposal['conflicts'] or proposal['approval_digest'] != expected:
            raise ValueError('preview changed under lock')
        if all(e['action'] == 'current' for e in proposal['entries']):
            exclude_state(proposal)
            return {'status': 'current', 'root': proposal['root']}
        # Probe the actual target filesystem before selected payload mutations.
        with tempfile.TemporaryDirectory(prefix='capability-', dir=root / STATE) as scratch:
            a, b = Path(scratch) / 'a', Path(scratch) / 'b'
            a.mkdir()
            b.mkdir()
            try:
                exclusive(a, b)
            except OSError as error:
                if error.errno != errno.EEXIST:
                    raise
            else:
                raise ValueError('exclusive publication is unavailable on target device')
            exclusive(a, Path(scratch) / 'c')
            syncdir(Path(scratch))
        exclude_state(proposal)
        operation = uuid.uuid4().hex
        record = {'version': 1, 'operation_id': operation, 'root_identity': proposal['root_identity'],
                  'runtime_identities': {}, 'source_digest': proposal['source_digest'], 'status': 'prepared',
                  'entries': [], 'anchors': {}, 'intent': ''}
        outputs, digest = source()
        if digest != proposal['source_digest']:
            raise ValueError('release source changed after preview')
        for entry in proposal['entries']:
            if entry['action'] == 'current':
                continue
            e = {'runtime': entry['runtime'], 'skill': entry['skill']}
            for part in ('bundle', 'receipt'):
                paths = item_paths(e['runtime'], e['skill'], operation, part == 'bundle')
                for relative in paths.values():
                    mkdir(root, (root / relative).parent)
                before = snapshot(root / paths['target'], part == 'bundle')
                if part == 'bundle':
                    if ((before['identity'] if before else None) != entry['original_identity']
                            or (before['manifest'] if before else None) != entry['original']):
                        raise ValueError('target changed before staging')
                    mkdir(root, root / paths['stage'])
                    for relative, (data, executable) in outputs[e['runtime']][e['skill']].items():
                        stage_file(root / paths['stage'] / relative, data, 0o644 | executable)
                else:
                    if ((before['identity'] if before else None) != entry['receipt_identity']
                            or read_receipt(root / paths['target'], e['runtime'], e['skill']) != entry['old_receipt']):
                        raise ValueError('receipt changed before staging')
                    receipt = {'version': 1, 'runtime': e['runtime'], 'skill': e['skill'],
                               'source_digest': digest, 'output_manifest': entry['proposed']}
                    stage_file(root / paths['stage'], canonical(receipt) + b'\n', 0o600)
                staged = snapshot(root / paths['stage'], part == 'bundle')
                approved = entry['proposed'] if part == 'bundle' else {'sha256': sha(canonical(receipt) + b'\n')}
                if staged['manifest'] != approved:
                    raise ValueError('staged content differs from approved proposal: ' + str(root / paths['stage']))
                e[part] = {**paths, 'original': before, 'proposed': staged}
            record['entries'].append(e)
        for entry in record['entries']:
            for part in ('bundle', 'receipt'):
                for key in ('target', 'stage', 'backup', 'quarantine'):
                    for parent in (root / entry[part][key]).parents:
                        if parent == root:
                            break
                        record['anchors'][str(parent.relative_to(root))] = identity(parent)
            r = entry['runtime']
            record['runtime_identities'][r] = {p: record['anchors'][p] for p in ('.' + r, '.' + r + '/skills')}
        persist(root, record)
        try:
            # All staged content and identities are checked before any target move.
            if source()[1] != digest:
                raise ValueError('source changed before first publication')
            for entry in record['entries']:
                for part in ('bundle', 'receipt'):
                    if snapshot(root / entry[part]['stage'], part == 'bundle') != entry[part]['proposed']:
                        raise ValueError('stage changed before first publication')
            record['status'] = 'applying'
            for part in ('bundle', 'receipt'):
                if part == 'receipt':
                    if source()[1] != digest:
                        raise ValueError('source changed before receipts')
                    for proposed in proposal['entries']:
                        if existing(Path(proposed['target'])) != proposed['proposed']:
                            raise ValueError('selected payload changed before receipts')
                for entry in record['entries']:
                    item = entry[part]
                    if snapshot(root / item['target'], part == 'bundle') != item['original']:
                        raise ValueError('original changed before backup')
                    if item['original'] is not None:
                        move(root, record, item, 'target', 'backup', item['original'], part == 'bundle')
                    if source()[1] != digest:
                        raise ValueError('source changed before publication')
                    move(root, record, item, 'stage', 'target', item['proposed'], part == 'bundle')
            for entry in record['entries']:
                for part in ('bundle', 'receipt'):
                    if snapshot(root / entry[part]['target'], part == 'bundle') != entry[part]['proposed']:
                        raise ValueError('final read-back changed')
            if source()[1] != digest or any(existing(Path(e['target'])) != e['proposed'] for e in proposal['entries']):
                raise ValueError('selected set or source changed before commit')
            record['status'], record['intent'] = 'committed', ''
            persist(root, record)
            return record
        except BaseException:
            # Use the durable record: a committed replacement survives a later fsync error.
            try:
                durable = json.loads(regular(root / STATE / 'operations' / operation / 'journal.json'))
                if durable['status'] != 'committed':
                    rollback(root, durable)
            except (OSError, ValueError, KeyError) as error:
                print('Retained operation ' + operation + ': ' + str(error), file=sys.stderr)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('preview', 'apply', 'inspect', 'recover', 'onboard', 'retire-send-it'):
        p = commands.add_parser(command, allow_abbrev=False)
        p.add_argument('--project', type=Path, default=Path.cwd())
        if command in ('preview', 'apply'):
            p.add_argument('--runtime', choices=(*RUNTIMES, 'both'), required=True)
            p.add_argument('--skill', action='append', required=True, choices=NAMES)
        if command in ('onboard', 'retire-send-it'):
            p.add_argument('--runtime', choices=('claude', 'codex'), required=True)
            p.add_argument('--dry-run', action='store_true')
        if command == 'apply':
            p.add_argument('--expect-preview', required=True)
        if command == 'recover':
            p.add_argument('--operation', required=True)
    args = parser.parse_args()
    if args.command == 'onboard':
        onboard(args.project, args.runtime, args.dry_run)
        return 0
    if args.command == 'retire-send-it':
        retire_send_it(args.project, args.runtime, args.dry_run)
        return 0
    if args.command == 'preview':
        value = preview(args.project, args.runtime, args.skill)
    elif args.command == 'apply':
        value = apply(args.project, args.runtime, args.skill, args.expect_preview)
    elif args.command == 'inspect':
        value = {'operations': operations(project_root(args.project))}
    else:
        value = recover(args.project, args.operation)
    print(json.dumps({**value, 'root': str(project_root(args.project))}, indent=2, sort_keys=True))
    return 2 if value.get('conflicts') else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('Portable refresh stopped: ' + str(error), file=sys.stderr)
        sys.exit(2)
