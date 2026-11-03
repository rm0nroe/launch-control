#!/usr/bin/env python3
"""Supervised, single-task Launch state. No queue or publication authority."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


class Invalid(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def group_closed(pgid, seconds=1):
    """macOS answers EPERM while a group's only members are exiting zombies; drain that before judging."""
    end = time.monotonic() + seconds
    while True:
        try:
            os.killpg(pgid, 0)
            return False
        except ProcessLookupError:
            return True
        except PermissionError:
            if time.monotonic() >= end:
                return False
            time.sleep(.01)


def safe_path(path):
    if any(p.is_symlink() for p in (path, *path.absolute().parents)):
        raise Invalid(f"unsafe state path: {path}")


def read_json(path):
    safe_path(path)
    if path.is_symlink() or not path.is_file():
        raise Invalid(f"missing or unsafe file: {path}")
    try:
        return json.loads(path.read_text())
    except (ValueError, UnicodeError) as exc:
        raise Invalid(f"malformed JSON: {path}") from exc


def atomic(path, value, raw=False):
    safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise Invalid(f"unsafe state path: {path}")
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            if raw:
                out.write(value)
            else:
                json.dump(value, out, sort_keys=True, indent=2)
                out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


_git_binding = None
_git_runner = None
_check_command = None
_delivery_module = None
_git_env = None  # Set only inside controller_git().


@contextlib.contextmanager
def controller_git():
    """LC-039: controller git ignores config a worker can write: global/system files, fsmonitor, hooks, excludes."""
    global _git_env
    overrides = (('core.fsmonitor', 'false'), ('core.hooksPath', '/dev/null'), ('core.excludesFile', '/dev/null'))
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_NO_REPLACE_OBJECTS': '1',
           'GIT_CONFIG_COUNT': str(len(overrides))}
    for index, (key, value) in enumerate(overrides):
        env[f'GIT_CONFIG_KEY_{index}'], env[f'GIT_CONFIG_VALUE_{index}'] = key, value
    previous, _git_env = _git_env, env
    try:
        yield
    finally:
        _git_env = previous


def delivery_module():
    global _delivery_module
    sys.dont_write_bytecode = True
    if _delivery_module is None:
        spec = importlib.util.spec_from_file_location('launch_delivery', Path(__file__).with_name('launch-delivery.py'))
        _delivery_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_delivery_module)
    return _delivery_module


def configure_git(binding, runner, check_command=None):
    global _git_binding, _git_runner, _check_command
    # ponytail: one grant per CLI process; independent queues need separate processes.
    if _git_binding is not None and binding != _git_binding:
        raise Invalid('cannot replace the process delivery grant')
    if binding is not None:
        if not isinstance(binding, str) or not binding or not callable(runner):
            raise Invalid('invalid delivery Git binding')
        if _git_binding is None:
            _git_binding, _git_runner = binding, runner
            _check_command = check_command


def git_process(root, *args, check=True):
    result = (_git_runner(root, *args) if _git_runner is not None else
              subprocess.run(["git", "-C", str(root), *args], capture_output=True, env=_git_env))
    if check and result.returncode:
        raise Invalid("git failed: " + result.stderr.decode(errors="replace").strip())
    return result


def git(root, *args):
    result = git_process(root, *args)
    return result.stdout.decode().strip()


def identity(root):
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        raise Invalid("project must be the exact Git worktree root")
    branch = git(root, "symbolic-ref", "--short", "HEAD")
    common = Path(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    return {"repo": digest(str(common).encode()), "worktree": str(root),
            "branch": branch, "revision": git(root, "rev-parse", "HEAD")}


def config_at(path, root):
    value = read_json(path)
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise Invalid("verification config requires schema 1")
    checks = value.get("checks")
    if not isinstance(checks, list) or not checks:
        raise Invalid("empty validation contract")
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("command"), str) or not check["command"].strip():
            raise Invalid("check requires a nonempty declared command")
        cwd, timeout = check.get("cwd"), check.get("timeout")
        if not isinstance(cwd, str) or Path(cwd).is_absolute() or not (root / cwd).resolve().is_relative_to(root):
            raise Invalid("check cwd must stay inside project")
        if not (root / cwd).is_dir():
            raise Invalid("check cwd missing")
        if type(timeout) not in (int, float) or not 0 < timeout <= 3600:
            raise Invalid("check timeout must be in (0, 3600]")
    if len({(check["command"], check["cwd"]) for check in checks}) != len(checks):
        raise Invalid("duplicate declared check")
    acceptance = value.get("acceptance")
    if not isinstance(acceptance, list) or not acceptance or not all(isinstance(x, str) and x.strip() for x in acceptance) or len(set(acceptance)) != len(acceptance):
        raise Invalid("acceptance must list nonempty unique required evidence names")
    return value


# ponytail: remote/service managers need their own completion adapter, not a shell exit.
MANAGERS = {'docker', 'podman', 'kubectl', 'helm', 'launchctl', 'systemctl', 'service',
            'ssh', 'at', 'batch', 'nohup', 'disown', 'setsid', 'tmux', 'screen',
            'pm2', 'forever', 'crontab', 'schtasks'}
# Do not hide lifecycle operations inside a quoted script or shell indirection.
SHELLS = {'sh', 'bash', 'dash', 'zsh', 'ksh', 'fish', 'csh', 'tcsh', 'eval', 'source'}


def _screened(text, globs=''):
    """Quote-aware: anything the shell would expand, chain, redirect or glob is refused (`globs` excepted)."""
    quote, previous = None, ' '
    for index, char in enumerate(text):
        if quote == "'":
            quote = None if char == "'" else quote
        elif quote == '"':
            # A backslash is literal unless it escapes one of these (grep's "a\|b" alternation).
            if char in '$`' or (char == '\\' and text[index + 1:index + 2] in ('$', '`', '"', '\\', '\n', '')):
                return False
            quote = None if char == '"' else quote
        elif char in '\'"':
            quote = char
        elif (char in '$`;|&<>()*?[]~{}!\\\n\r\0' and char not in globs) or (char in '=#' and previous in ' \t'):
            return False  # A leading = is zsh's =cmd path expansion; a leading # starts a comment.
        previous = char
    return quote is None


def _contained(word, cwd, roots, absolute=False):
    path = Path(word)
    if not word or word.startswith('-') or '..' in path.parts or (path.is_absolute() and not absolute):
        return False
    full = Path(os.path.realpath(path if path.is_absolute() else cwd / path))
    return any(full == root or full.is_relative_to(root) for root in roots)


# grep -R follows nested symlinks out of the worktree; -r does not.
READ_FLAGS = {'cat': r'-[nbsv]+', 'wc': r'-[lwcm]+', 'ls': r'-[1aAlhRtrSdF]+', 'grep': r'-[nrilwFEhHcsvx]+'}
GIT_READ = ('status', 'diff', 'log', 'show', 'rev-parse', 'ls-files')
GIT_READ_BANNED = {'--output', '--ext-diff', '--textconv', '--no-index', '--exclude-from'}


def _read_glob(word):
    """Ryan, 2026-10-17: a relative read glob expands under its literal lead, so never to an option,
    `..` (dot-glob), a recursive `**` walk or an absolute path."""
    return (re.match(r'[A-Za-z0-9_]', word) is not None and '**' not in word
            and not any(part.startswith('.') and ('*' in part or '?' in part) for part in word.split('/')))


def command_family(command, worktree, checks=(), read_roots=(), mutate=True):
    """LC-030 fallback for unlisted commands: bounded read, git read, focused test and commit shapes.

    `mutate=False` is the reviewer's read-only subset. Reads may also reach the admitted
    sandbox read set; everything else stays inside the worktree.
    """
    if not isinstance(command, str):
        return False
    root = Path(os.path.realpath(worktree))
    cwd, rest = '.', command
    if command.startswith('cd ') and ' && ' in command:
        prefix, rest = command.split(' && ', 1)
        words = shlex.split(prefix) if _screened(prefix) else []
        if len(words) != 2 or not _contained(words[1], root, [root]):
            return False
        cwd = os.path.normpath(words[1])
        if not (root / cwd).is_dir():
            return False
    if not _screened(rest, '*?'):
        return False
    try:
        words = shlex.split(rest)
        tokens = shlex.split(rest, posix=False)
    except ValueError:
        return False
    if not words:
        return False
    # An unquoted * or ? is a glob: read programs only, on an unquoted word that stays a read glob.
    for token in tokens:
        if re.search(r'[*?]', re.sub(r"'[^']*'|\"[^\"]*\"", '', token)) and (
                words[0] not in READ_FLAGS and words[0] not in ('head', 'tail', 'sed')
                or re.search('[\'"]', token) or not _read_glob(token)):
            return False
    here = root / cwd
    reads = [root, *(Path(os.path.realpath(r)) for r in read_roots)]
    inside = lambda word: _contained(word, here, [root])
    # Ryan, 2026-10-17: an absolute read is a read; the delivery sandbox allows or denies it.
    # Never a device, procfs or the whole disk: those block or stream forever.
    endless = lambda word: (word.startswith(('/dev/', '/proc/')) and word != '/dev/null') or Path(word) == Path('/')
    readable = lambda paths: all(_contained(word, here, reads)
                                 or (Path(word).is_absolute() and '..' not in Path(word).parts and not endless(word))
                                 for word in paths)
    program, args = words[0], words[1:]
    if words == ['pwd']:
        return True
    if program in ('cat', 'wc', 'ls'):
        paths = [word for word in args if not re.fullmatch(READ_FLAGS[program], word)]
        return (bool(paths) or program == 'ls') and readable(paths)
    if program in ('head', 'tail'):
        if args[:1] == ['-n'] and len(args) > 1 and args[1].isdigit():
            args = args[2:]
        elif args and re.fullmatch(r'-n?\d+', args[0]):
            args = args[1:]
        return bool(args) and readable(args)
    if program == 'grep':
        index, patterns = 0, 0
        while index < len(args):
            if args[index] == '-e' and index + 1 < len(args):
                index, patterns = index + 2, patterns + 1
            elif re.fullmatch(READ_FLAGS['grep'], args[index]):
                index += 1
            else:
                break
        if not patterns:  # The first operand is the pattern unless -e supplied them.
            if index >= len(args) or args[index].startswith('-'):
                return False
            index += 1
        return len(args) > index and readable(args[index:])
    if program == 'sed':
        return (len(args) > 2 and args[0] == '-n' and re.fullmatch(r'\d+(,\d+)?p', args[1]) is not None
                and readable(args[2:]))
    if program == 'git' and args[:1] and args[0] in GIT_READ:
        # Word 1 must be the subcommand, so global options (-c, -C, --git-dir) never parse.
        return not any(word.split('=', 1)[0] in GIT_READ_BANNED or word.startswith('-O') for word in args[1:])
    if not mutate:
        return False
    if program == 'git' and args[:1] == ['add']:
        paths = args[2:] if args[1:2] == ['--'] else args[1:]
        return bool(paths) and all(inside(word) for word in paths)
    if program == 'git' and args[:1] == ['commit']:
        return len(args) > 4 and args[1] == '-m' and args[3] == '--' and all(inside(word) for word in args[4:])
    # The autonomy reference's phase-notes command: the admitted runtime (never a worktree copy) for this worktree.
    if (program == 'python3' and len(args) == 10
            and [args[1], args[3], args[5], args[6], args[8]] == ['--project', '--platform', 'notes', '--run', '--text']
            and Path(args[0]).is_absolute() and not Path(args[0]).is_relative_to(root)
            and Path(os.path.realpath(args[0])).name == 'launch-runtime.py'
            and _contained(args[0], here, [Path(os.path.realpath(r)) for r in read_roots], absolute=True)
            and Path(args[2]).is_absolute() and Path(os.path.realpath(args[2])) == root and args[4] in ('codex', 'claude')
            and re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', args[7])):
        return True
    for check in checks:
        declared = shlex.split(check['command'])
        if (os.path.normpath(check['cwd']) != cwd or words[0] != declared[0]
                or declared[0] == '.' or Path(declared[0]).name in MANAGERS | SHELLS):
            continue
        # Pin the program through its subcommand or script and every non-path word; the
        # tail may drop declared operands, reuse declared flags, or name existing worktree paths.
        flag = lambda word: word.startswith('-')
        first = next((i for i, word in enumerate(declared) if i and not flag(word)), 0)
        pinned = [i for i, word in enumerate(declared) if i and not flag(word) and not re.search(r'[/.]', word)]
        head = max([first, *pinned])
        if words[:head + 1] != declared[:head + 1]:
            continue
        tail = {w for w in declared[head + 1:] if flag(w)}
        node = lambda word: word.split('::', 1)[0]  # A pytest node ID names an existing file.
        if all(word in tail or (inside(node(word)) and (here / node(word)).exists()) for word in words[head + 1:]):
            return True
    return False


def deny_tool(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                   'permissionDecisionReason': reason}}


def synchronous_shell(command, approved, worktree=None, checks=(), read_roots=()):
    """A recorded lifecycle contract, not permission to run arbitrary shell work."""
    if not isinstance(command, str):
        return False
    if command not in approved:
        # Family programs are fixed or a declared non-manager check, so no word scan is needed.
        return bool(worktree) and command_family(command, worktree, checks, read_roots)
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars='();<>|&\n')
        lexer.whitespace = ' \t\r'  # A newline separates commands, so it must stay a token.
        words = list(lexer)
    except ValueError:
        return False
    # `.` sources a file only in command position; as an operand (`ruff check .`) it is a path.
    prefixes = {'!', '{', 'if', 'then', 'else', 'elif', 'do', 'while', 'until', 'time', 'command', 'builtin', 'exec'}
    at_command, target = True, False
    for word, following in zip(words, words[1:] + ['']):
        operator = all(char in '();<>|&\n' for char in word)
        redirect = operator and ('<' in word or '>' in word)
        if word == '.' and at_command and not target:
            return False
        if target:
            target = False
        elif redirect or (word.isdigit() and following[:1] in '<>' and following):
            target = redirect  # A redirection and its target keep the command position.
        elif operator:
            at_command = True
        elif not (word in prefixes or re.match(r'[A-Za-z_][A-Za-z0-9_]*=', word)):
            at_command = False
    return bool(words) and not any(word == '&' or Path(word).name in MANAGERS | SHELLS for word in words)


def run_checks(root, checks, deadline=None):
    """Run declared checks in order, stopping at the first failure; returns (results, stop reason)."""
    results = []
    for check in checks:
        if deadline is not None and time.time() >= deadline:
            return results, "run deadline exhausted"
        start = time.monotonic()
        timeout = check["timeout"]
        if deadline is not None:
            timeout = min(timeout, max(0.01, deadline - time.time()))
        with tempfile.TemporaryFile() as output:
            argv, env = ["bash", "-o", "pipefail", "-c", check["command"]], None
            if _git_binding is not None:
                if not callable(_check_command):
                    raise Invalid('restricted verification launcher is missing')
                argv, env = _check_command(root / check['cwd'], argv)
            proc = subprocess.Popen(argv, env=env, cwd=root / check["cwd"], stdout=output,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            reason = "completed"
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
                reason = "timeout"
            # A finished leader cannot account for a surviving check child.
            group_gone = group_closed(proc.pid)
            if not group_gone:
                code = code or 1
                if reason == "completed":
                    reason = "owned check process group remained"
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                end = time.monotonic() + 1
                while time.monotonic() < end:
                    if group_closed(proc.pid, 0):
                        group_gone = True
                        break
                    time.sleep(.01)
            output.seek(0)
            message = output.read(16384).decode(errors="replace")
        results.append({**check, "exit": code, "reason": reason, "seconds": time.monotonic()-start, "output": message,
                        "pgid": proc.pid, "group_gone": group_gone})
        if code:
            break
    return results, None


def acceptance_ok(evidence, expected, required):
    """Revision-bound acceptance: every identity field matches and every contracted key has text."""
    return (isinstance(evidence, dict) and isinstance(evidence.get("evidence", {}), dict)
            and all(evidence.get(k) == expected.get(k) for k in ("repo", "worktree", "branch", "run", "task", "revision", "platform"))
            and all(isinstance(evidence.get("evidence", {}).get(k), str) and evidence["evidence"][k].strip() for k in required))


def fingerprint(root):
    paths = git_process(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout.split(b"\0")
    entries = []
    for raw in sorted(set(paths) - {b""}):
        path = root / os.fsdecode(raw)
        if path.is_symlink():
            value = "link:" + os.readlink(path)
        elif path.is_file():
            value = digest(path.read_bytes()) + ":" + str(path.stat().st_mode & 0o777)
        elif path.is_dir():
            value = "directory:" + git(path, "rev-parse", "HEAD") + git(path, "status", "--porcelain")
        else:
            value = "missing"
        entries.append((os.fsdecode(raw), value))
    return digest(json.dumps(entries).encode())


HOOK_WRAPPER = '\n'.join([
    '#!/usr/bin/env bash', 'set -euo pipefail',
    'exec python3 -I "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/launch-runtime.py" --project "$CLAUDE_PROJECT_DIR" hook', ''
])
VERIFY_WRAPPER = '\n'.join([
    '#!/usr/bin/env bash', 'set -euo pipefail',
    'PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"',
    'platform="${LAUNCH_PLATFORM:-}"',
    'if [ -z "$platform" ]; then',
    '  for candidate in claude codex; do',
    '    if [ -f "$PROJECT_ROOT/.$candidate/launch/verify.json" ]; then',
    '      [ -z "$platform" ] || { echo "Set LAUNCH_PLATFORM=claude or codex for this dual-runtime project" >&2; exit 1; }',
    '      platform="$candidate"',
    '    fi',
    '  done',
    'fi',
    'case "$platform" in',
    '  claude) runtime="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/launch-runtime.py" ;;',
    '  codex) runtime="${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/launch-runtime.py" ;;',
    '  *) echo "Select a configured LAUNCH_PLATFORM=claude or codex" >&2; exit 1 ;;',
    'esac',
    'exec python3 -I "$runtime" --project "$PROJECT_ROOT" --platform "$platform" verify "$@"', ''
])
CODEX_HOOK_WRAPPER = '\n'.join([
    '#!/usr/bin/env bash', 'set -euo pipefail',
    'PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"',
    'exec python3 -I "${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/launch-runtime.py" --project "$PROJECT_ROOT" --platform codex hook', ''
])


def wrappers(controller=None, controller_digest=None, shared_root=None,
             delivery_binding=None, delivery_binding_digest=None):
    """Render one explicit controller binding, leaving standalone defaults unchanged."""
    delivery = None
    if delivery_binding is not None or delivery_binding_digest is not None:
        if controller is None or shared_root is None or delivery_binding is None or delivery_binding_digest is None:
            raise Invalid('delivery launcher needs selected controller, shared root and binding pair')
        path = Path(delivery_binding)
        safe_path(path)
        if not path.is_absolute() or not path.is_file() or digest(path.read_bytes()) != delivery_binding_digest:
            raise Invalid('delivery launcher binding changed')
        delivery = {'grant': str(path), 'digest': delivery_binding_digest}
    if controller is None:
        if controller_digest is not None or shared_root is not None:
            raise Invalid('controller path and digest required')
        return VERIFY_WRAPPER, CODEX_HOOK_WRAPPER
    controller = Path(controller)
    safe_path(controller)
    if (not controller.is_absolute() or not controller.is_file()
            or digest(controller.read_bytes()) != controller_digest):
        raise Invalid('controller must be an absolute regular file with matching digest')
    quoted = shlex.quote(str(controller))
    installed = '"${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/launch-runtime.py"'
    verifier = VERIFY_WRAPPER.replace(installed, quoted)
    hook = CODEX_HOOK_WRAPPER.replace(installed, quoted)
    if shared_root is not None:
        shared_root = Path(shared_root)
        safe_path(shared_root)
        common = Path(git(shared_root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
        if not shared_root.is_absolute() or common.parent != shared_root or identity(shared_root)['worktree'] != str(shared_root):
            raise Invalid('shared delivery launcher requires the exact primary repository root')
        code = f'''import json, os, pathlib, runpy, sys
sys.dont_write_bytecode = True
path = pathlib.Path({str(controller)!r})
import hashlib
if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != {controller_digest!r}:
    print(json.dumps({{'continue': False, 'stopReason': 'selected Launch runtime changed'}}))
    raise SystemExit(0)
runtime_ns = runpy.run_path(str(path))
run = os.environ.get('LAUNCH_RUN_ID')
if not run:
    print('{{}}')
    raise SystemExit(0)
try:
    payload = json.load(sys.stdin)
    state = runtime_ns['read_json'](pathlib.Path({str(common / 'launch-queue/active.json')!r}))
    items = [item for item in state['items'] if item.get('run') == run and item.get('worktree') == payload.get('cwd')]
    if len(items) != 1:
        print('{{}}')
        raise SystemExit(0)
    runtime = runtime_ns['Runtime'](pathlib.Path(items[0]['worktree']), None, 'codex')
    with runtime.lock():
        live = runtime.load(run)
        if not runtime.controlled(live):
            raise runtime_ns['Invalid']('shared delivery launcher has no exact live queue claim')
        print(json.dumps(runtime.hook(payload, run)))
except Exception as error:
    print(json.dumps({{'continue': False, 'stopReason': 'Launch blocked: ' + str(error)}}))
'''
        if delivery is not None:
            launcher = f'''import importlib.util, json, pathlib, sys
sys.dont_write_bytecode = True
try:
    path = pathlib.Path({str(controller.with_name('launch-delivery.py'))!r})
    import hashlib
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != {digest(controller.with_name('launch-delivery.py').read_bytes())!r}:
        raise ValueError('selected delivery launcher changed')
    spec = importlib.util.spec_from_file_location('launch_delivery', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.run_hook({delivery!r}, {str(shared_root)!r}, {code!r})
except Exception as error:
    print(json.dumps({{'continue': False, 'stopReason': 'Launch blocked: ' + str(error)}}))
'''
            code = launcher
        hook = '#!/usr/bin/env bash\nset -euo pipefail\nexec python3 -I -c ' + shlex.quote(code) + '\n'
    return verifier, hook


def control_digests(root, git_dir, common):
    """Git control files a worker can write that change what status, fingerprint or hooks report."""
    def value(path):
        if path.is_symlink():
            return 'symlink:' + os.readlink(path)
        if path.is_dir():
            return 'directory:' + digest(json.dumps(sorted((f.name, value(f)) for f in path.iterdir())).encode())
        return digest(path.read_bytes()) if path.is_file() else 'absent'
    return {str(p): value(p) for p in (root / '.git', common / 'config', git_dir / 'config.worktree',
                                      common / 'info/exclude', common / 'info/attributes', common / 'hooks')}


def controller_clean(root):
    """Clean by content. A worker-run status can leave stale clean stat data in the real index, and
    --really-refresh still trusts stat data; a fresh index from HEAD has none, so git reads every file."""
    global _git_env
    with controller_git(), tempfile.TemporaryDirectory() as scratch:
        saved = _git_env
        _git_env = {**saved, 'GIT_INDEX_FILE': str(Path(scratch) / 'index')}
        try:
            git(root, 'read-tree', 'HEAD')
            hidden = git_process(root, 'ls-files', '-z', '--others', '--ignored', '--exclude-standard').stdout.split(b'\0')
            if any(os.path.basename(os.fsdecode(path)) in ('.gitignore', '.gitattributes') for path in hidden if path):
                return False  # An untracked `*` .gitignore hides itself and every file beside it.
            return not git(root, 'status', '--porcelain', '--untracked-files=all')
        finally:
            _git_env = saved


def claude_config_dir():
    return str(Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude'))


def git_roots(root):
    with controller_git():
        return (str(Path(git(root, 'rev-parse', '--absolute-git-dir')).resolve()),
                str(Path(git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()))


def controller_snapshot(root):
    """Taken at admission and persisted in the queue state, never re-taken: what readiness is compared against."""
    git_dir, common = git_roots(root)
    with controller_git():
        runtime = Runtime(root, None, 'claude')
        cfg = config_at(runtime.config, root)
        return {'git_dir': git_dir, 'common_dir': common, 'policy': runtime.policy(), 'checks': cfg['checks'],
                'acceptance': cfg['acceptance'], 'control': control_digests(root, Path(git_dir), Path(common))}


def snapshot_drift(root, snapshot):
    if git_roots(root) != (snapshot['git_dir'], snapshot['common_dir']):
        return 'git directory changed after admission'
    if control_digests(root, Path(snapshot['git_dir']), Path(snapshot['common_dir'])) != snapshot['control']:
        return 'git control files changed after admission'
    with controller_git():
        if Runtime(root, None, 'claude').policy() != snapshot['policy']:
            return 'verification policy changed after admission'
    return None


def controller_recheck(root, snapshot, run, task, deadline, receipt_path):
    """LC-039: readiness the worker cannot forge. Re-run the admitted checks; trust no worker-written state."""
    receipt = {'run': run, 'task': task, 'platform': 'claude', 'controller': True, 'checks': [], 'ok': False, 'started': time.time()}
    reason = snapshot_drift(root, snapshot)
    if not reason:
        with controller_git():
            receipt.update(identity(root), fingerprint=fingerprint(root))
            clean = controller_clean(root)
            receipt['checks'], stopped = run_checks(root, snapshot['checks'], deadline)
            unchanged = (fingerprint(root) == receipt['fingerprint'] and identity(root) == {k: receipt[k] for k in ('repo', 'worktree', 'branch', 'revision')}
                         and controller_clean(root))
        try:
            evidence = read_json(Path(snapshot['git_dir']) / 'acceptance.json')
        except Invalid:
            evidence = None
        reason = (stopped or snapshot_drift(root, snapshot)
                  or (None if clean and unchanged else 'candidate is not the clean, unchanged committed revision')
                  or (None if all(c['exit'] == 0 for c in receipt['checks']) and len(receipt['checks']) == len(snapshot['checks'])
                      else 'declared checks failed')
                  or (None if acceptance_ok(evidence, receipt, snapshot['acceptance']) else 'missing or mismatched task acceptance evidence'))
    receipt.update(ok=reason is None, finished=time.time(), **({'reason': reason} if reason else {}))
    atomic(receipt_path, receipt)
    return receipt


CANONICAL_VERIFY = ('bash scripts/verify.sh checks --run "$LAUNCH_RUN_ID"',
                    'bash scripts/verify.sh ready --run "$LAUNCH_RUN_ID" --candidate "$(git rev-parse HEAD)" --acceptance "$(git rev-parse --absolute-git-dir)/acceptance.json"')


def canonical_verify(command, declared, bound):
    """The two canonical verify commands: admitted only when declared and the controller binding holds."""
    return bool(bound) and command in CANONICAL_VERIFY and command in declared


CLAUDE_HOOK_COMMAND = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"'


def claude_tool_gate(settings):
    """The slice 1 all-tool PreToolUse entry: exactly one, or Claude runs tools ungated."""
    hooks = [h for entry in settings.get('hooks', {}).get('PreToolUse', [])
             if entry.get('matcher', '') in ('', '*') for h in entry.get('hooks', [])
             if h.get('type') == 'command' and h.get('command') == CLAUDE_HOOK_COMMAND and h.get('timeout') == 10]
    if len(hooks) != 1:
        raise Invalid('native Claude needs its all-tool PreToolUse hook')


def claude_hooks_enabled(root):
    """The worker runs in bypassPermissions, so its PreToolUse gate is the only gate: no settings layer may turn hooks off."""
    for path in (Path(claude_config_dir()) / 'settings.json', root / '.claude/settings.json', root / '.claude/settings.local.json'):
        try:
            value = json.loads(path.read_text()) if path.exists() or path.is_symlink() else {}
        except (OSError, ValueError, UnicodeError) as exc:
            raise Invalid(f'unreadable Claude settings: {path}') from exc
        if not isinstance(value, dict) or value.get('disableAllHooks'):
            raise Invalid(f'Claude hooks are disabled or unreadable in {path}; the worker would run ungated')


def render_overlay(runtime, source):
    """Claude generator: canonical wrappers plus the policy-named checks; never overwrites."""
    files = {'.claude/hooks/launch.sh': HOOK_WRAPPER, 'scripts/verify.sh': VERIFY_WRAPPER,
             '.claude/launch/verify.json': source.read_text()}
    config_at(source, runtime.root)
    for rel in files:
        safe_path(runtime.root / rel)
        if (runtime.root / rel).exists() or (runtime.root / rel).is_symlink():
            raise Invalid('generated overlay file already exists: ' + rel)
    for rel, text in files.items():
        path = runtime.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)


def validate_overlay(runtime, commands, controller=None, controller_digest=None, shared_root=None,
                     delivery_binding=None, delivery_binding_digest=None):
    cfg = config_at(runtime.config, runtime.root)
    declared = {line.strip() for line in commands.read_text().splitlines() if line.strip()}
    rendered = {check['command'] if check['cwd'] == '.' else 'cd ' + check['cwd'] + ' && ' + check['command'] for check in cfg['checks']}
    if rendered != declared:
        raise Invalid('autonomy checks differ from the declared onboarding contract')
    native = runtime.platform == 'codex'
    if controller is not None and not native:
        raise Invalid('selected controller requires Codex')
    verifier, native_hook = wrappers(controller, controller_digest, shared_root, delivery_binding, delivery_binding_digest)
    if shared_root is not None and identity(Path(shared_root))['repo'] != runtime.ident['repo']:
        raise Invalid('shared delivery launcher belongs to another repository')
    hook_path = f'.{runtime.platform}/hooks/launch.sh'
    for rel, expected in ((hook_path, native_hook if native else HOOK_WRAPPER), ('scripts/verify.sh', verifier)):
        path = runtime.root / rel
        if path.is_symlink() or not path.is_file() or path.read_text() != expected:
            raise Invalid('preserved or generated wrapper conflicts with the canonical binding: ' + rel)
    settings = read_json(runtime.root / ('.codex/hooks.json' if native else '.claude/settings.json'))
    command = ('bash ' + shlex.quote(str((Path(shared_root) if shared_root else runtime.root) / hook_path))) if native else CLAUDE_HOOK_COMMAND
    for event, matcher in (('SessionStart', 'startup|resume|compact|clear'), ('PreCompact', 'manual|auto' if native else ''), ('Stop', '')):
        entries = settings.get('hooks', {}).get(event, [])
        matches = [h for entry in entries if entry.get('matcher', '') == matcher for h in entry.get('hooks', []) if h.get('type') == 'command' and h.get('command') == command and h.get('timeout') == 10]
        if len(matches) != 1:
            raise Invalid('missing or duplicate autonomy hook: ' + event)
        if native and event == 'SessionStart' and matches[0].get('additionalContextLimit') != 10000:
            raise Invalid('native checkpoint context limit must be 10000')
    if any(h.get('command') == command for entry in settings.get('hooks', {}).get('SubagentStop', []) for h in entry.get('hooks', [])):
        raise Invalid('autonomy must not gate SubagentStop')


class Runtime:
    def __init__(self, root, config, platform='claude'):
        self.root = root.resolve()
        self.ident = identity(self.root)
        self.platform = platform
        self.config = config.absolute() if config else self.root / f".{platform}/launch/verify.json"
        self.base = Path(git(self.root, "rev-parse", "--absolute-git-dir")) / "launch"
        if self.base.is_symlink():
            raise Invalid("unsafe runtime directory")
        self.state_path = self.base / "active.json"

    @contextlib.contextmanager
    def lock(self, timeout=None):
        self.base.mkdir(parents=True, exist_ok=True)
        lock = self.base / "lock"
        if lock.is_symlink():
            raise Invalid("unsafe lock")
        with lock.open("a") as stream:
            # ponytail: one lock per worktree; shared queue ownership belongs to Slice 3.
            end = None if timeout is None else time.monotonic() + timeout
            while True:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | (fcntl.LOCK_NB if end else 0))
                    break
                except BlockingIOError:
                    if time.monotonic() >= end:
                        raise Invalid('runtime lock busy')
                    time.sleep(.05)
            yield

    def load(self, run=None):
        state = read_json(self.state_path)
        required = {"repo", "worktree", "branch", "revision", "run", "task", "session", "status", "attempts", "max_attempts", "deadline", "sequence", "notes", "policy", "runtime"}
        if not isinstance(state, dict) or not required <= state.keys():
            raise Invalid("malformed run state")
        # Existing Slice 1 checkpoints are Claude-only, never implicitly migrated.
        if state.get('platform', 'claude') != self.platform:
            raise Invalid('run platform mismatch')
        if not isinstance(state["run"], str) or str(uuid.UUID(state["run"])) != state["run"]:
            raise Invalid("invalid run identifier")
        if state["status"] not in ("initializing", "running", "handoff", "paused", "blocked", "awaiting_review") or any(type(state[k]) is not int or state[k] < 0 for k in ("attempts", "max_attempts", "sequence")):
            raise Invalid("malformed run status or counters")
        if 'controller' in state and (not isinstance(state['controller'], str) or not re.fullmatch('[0-9a-f]{64}', state['controller'])):
            raise Invalid('malformed controller binding')
        if type(state["deadline"]) not in (int, float) or not isinstance(state["notes"], str):
            raise Invalid("malformed run deadline or notes")
        if any(state[k] != self.ident[k] for k in ("repo", "worktree", "branch")):
            raise Invalid("run identity mismatch")
        if run and state["run"] != run:
            raise Invalid("run ID mismatch")
        return state

    def begin(self, task, session, minutes, max_attempts, run=None, controller=None, pending=False):
        """Create under the caller's runtime lock; a pending native run admits no work."""
        config_at(self.config, self.root)
        if self.state_path.exists():
            raise Invalid('existing run retained; recover it explicitly')
        if not task.strip() or (not pending and not session.strip()) or not 1 <= minutes <= 60 or not 1 <= max_attempts <= 5:
            raise Invalid('invalid task/session or limits')
        if pending and (session or not controller):
            raise Invalid('pending native startup requires controller and no fabricated session')
        rid = run or str(uuid.uuid4())
        if str(uuid.UUID(rid)) != rid:
            raise Invalid('invalid run identifier')
        state = {**self.ident, 'platform': self.platform, 'run': rid, 'task': task, 'session': session,
                 'status': 'initializing' if pending else 'running', 'attempts': 0, 'max_attempts': max_attempts,
                 'deadline': time.time() + minutes * 60, 'sequence': 0,
                 'notes': 'Semantic notes missing; record at the first phase boundary.',
                 'policy': self.policy(), 'runtime': digest(Path(__file__).read_bytes())}
        if controller:
            state['controller'] = controller
            if not self.controlled(state):
                raise Invalid('controller must own the matching queue claim and lock')
        self.save(state)
        return state

    def activate(self, expected, session):
        with self.lock():
            state = self.current(expected)
            if state['status'] != 'initializing' or not isinstance(session, str) or not session.strip():
                raise Invalid('native startup is not awaiting an actual session')
            if state.get('hook_session', session) != session:
                raise Invalid('native startup hook session mismatch')
            if (time.time() >= state['deadline'] or state['policy'] != self.policy()
                    or state['runtime'] != digest(Path(__file__).read_bytes()) or state['attempts'] >= state['max_attempts']):
                raise Invalid('native startup limits or policy changed')
            state.update(status='running', session=session)
            self.save(state)
            return self.load(state['run'])

    def save(self, state):
        state["sequence"] += 1
        state["updated"] = time.time()
        atomic(self.state_path, state)
        history = self.base / state["run"]
        if history.is_symlink():
            raise Invalid("unsafe history directory")
        atomic(history / f'{state["sequence"]:08d}.json', state)
        if state["status"] in ("paused", "blocked", "awaiting_review"):
            terminal = history / (state["status"] + ".json")
            if not terminal.exists():
                atomic(terminal, state)
            if not (history / "terminal.json").exists():
                atomic(history / "terminal.json", state)
        for path in sorted(history.glob("[0-9]*.json"))[:-15]:
            if not path.is_symlink():
                path.unlink()

    def calibration(self, expected, enabled):
        """Only the owning queue opens Claude's tool gate after native calibration."""
        with self.lock():
            state = self.current(expected)
            if self.platform != 'claude' or type(enabled) is not bool:
                raise Invalid('Claude calibration flag required')
            if enabled:
                claude_tool_gate(read_json(self.root / '.claude/settings.json'))
                claude_hooks_enabled(self.root)
                if state['status'] not in ('initializing', 'handoff'):
                    raise Invalid('native Claude calibration needs its all-tool PreToolUse hook')
            elif (not state.get('calibrating') or state['status'] != 'running'
                  or state.get('hook_session') != state['session']):
                raise Invalid('native Claude calibration binding was not observed')
            state['calibrating'] = enabled
            self.save(state)
            return self.load(state['run'])

    def request_checkpoint(self, expected):
        """Close Claude's existing work-tool gate while the active turn saves notes."""
        with self.lock():
            state = self.current(expected)
            if (self.platform != 'claude' or state.get('calibrating')
                    or state.get('hook_session') != state['session']
                    or state['status'] not in ('running', 'awaiting_review')):
                raise Invalid('active checkpoint requires a bound Claude worker')
            if state['status'] == 'running' and not state.get('checkpoint_only'):
                state.update(checkpoint_only=True, checkpoint_denials={})
                self.save(state)
            return self.load(state['run'])

    def checkpoint_denial(self, run, session, tool):
        state = self.load(run)
        return (state.get('checkpoint_only') is True and state['session'] == session
                and self.controlled(state) and isinstance(tool, dict)
                and isinstance(tool.get('tool_use_id'), str)
                and state.get('checkpoint_denials', {}).get(tool['tool_use_id'])
                == digest(json.dumps([tool.get('tool_name'), tool.get('tool_input')], sort_keys=True).encode()))

    def current(self, expected):
        """Caller holds runtime lock after queue lock; no native waits here."""
        self.ident = identity(self.root)
        state = self.load(expected['run'])
        if state['sequence'] != expected['sequence'] or not self.controlled(state):
            raise Invalid('stale checkpoint caller or missing controller binding')
        return state

    def controlled(self, state):
        """Verify the existing queue record and live lock, not an unchecked flag."""
        if not state.get('controller'):
            return False
        base = Path(git(self.root, 'rev-parse', '--path-format=absolute', '--git-common-dir')) / 'launch-queue'
        safe_path(base / 'lock')
        if not (base / 'lock').is_file() or (base / 'PAUSE').exists():
            return False
        with (base / 'lock').open('r') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                return False  # No queue currently owns admission.
        try:
            queue = read_json(base / 'active.json')
        except (Invalid, OSError):
            return False
        if (not isinstance(queue, dict) or not isinstance(queue.get('items'), list)
                or any(not isinstance(item, dict) for item in queue['items'])
                or type(queue.get('deadline')) not in (int, float)):
            return False
        matches = [item for item in queue.get('items', []) if item.get('run') == state['run']]
        return (queue.get('manifest') == state['controller'] and len(matches) == 1
                and all(matches[0].get(k) == v for k, v in
                        {'id': state['task'], 'worktree': str(self.root)}.items())
                and state['session'] in (matches[0].get('session'), matches[0].get('next_session'))
                and matches[0].get('status') in ('admitting', 'launching', 'running', 'handoff')
                and state['deadline'] <= queue.get('deadline', 0))

    def attach(self, expected, manifest):
        with self.lock():
            state = self.load(expected['run'])
            if state['sequence'] != expected['sequence'] or state['status'] != 'running':
                raise Invalid('stale or stopped controller attachment')
            if not isinstance(manifest, str) or not re.fullmatch('[0-9a-f]{64}', manifest):
                raise Invalid('invalid controller manifest')
            state['controller'] = manifest
            if not self.controlled(state):
                raise Invalid('controller must own the matching queue claim and lock')
            self.save(state)
            return self.load(state['run'])

    def index_digest(self):
        return digest(git_process(self.root, 'ls-files', '--stage', '-z').stdout)

    def check_handoff(self, state, expected_hash):
        self.ident = identity(self.root)
        envelope = state.get('handoff', {})
        if not isinstance(envelope, dict):
            raise Invalid('malformed checkpoint envelope')
        record = envelope.get('record', {})
        required = {'repo', 'worktree', 'branch', 'run', 'task', 'platform', 'session', 'deadline', 'attempts', 'max_attempts', 'controller', 'policy', 'runtime', 'revision', 'fingerprint', 'index_digest', 'snapshot_sequence', 'semantic'}
        if (not isinstance(record, dict) or set(record) != required or envelope.get('hash') != expected_hash
                or digest(json.dumps(record, sort_keys=True).encode()) != expected_hash):
            raise Invalid('missing or corrupt sealed checkpoint')
        if state['status'] not in ('handoff', 'running'):
            raise Invalid('checkpoint task is paused or terminal')
        if any(record.get(k) != state[k] for k in ('repo', 'worktree', 'branch', 'run', 'task', 'platform', 'deadline', 'attempts', 'max_attempts', 'controller')):
            raise Invalid('checkpoint identity or limits changed')
        if (any(record[k] != self.ident[k] for k in self.ident) or record['fingerprint'] != fingerprint(self.root)
                or record['index_digest'] != self.index_digest() or record['policy'] != self.policy()
                or record['runtime'] != digest(Path(__file__).read_bytes())):
            raise Invalid('checkpoint candidate, index or policy changed')
        if time.time() >= state['deadline'] or state['attempts'] >= state['max_attempts']:
            raise Invalid('checkpoint budget exhausted')
        return record

    def handoff(self, expected, expected_hash):
        with self.lock():
            return self.check_handoff(self.current(expected), expected_hash)

    def checkpoint_markdown(self, record, key):
        notes = record['semantic']
        return (f"# Checkpoint: launch-run-{record['run']}\n\n"
                f"Launch Control-owned view. Run: {record['run']}\nPlatform: {record['platform']}\n"
                f"Sealed SHA256: {key}\nAuthoritative state: {self.state_path}\n\n"
                "Validate this exact run and hash with the runtime checkpoint command before loading.\n\n"
                + '\n\n'.join(f'## {k.replace("_", " ").title()}\n{notes[k]}' for k in
                               ('goal', 'scope', 'unsafe_state', 'reversal', 'completed', 'next_phase', 'next_action', 'questions', 'evidence')) + '\n')

    def write_view(self, state):
        """Locked derivative repair; never adopt user modifications after a crash."""
        envelope = state['handoff']
        view = self.base / state['run'] / 'checkpoint.md'
        safe_path(view)
        actual = digest(view.read_bytes()) if view.is_file() else None
        if actual not in (envelope['view_digest'], envelope['previous_view_digest']):
            raise Invalid('manual checkpoint view changed or is not owned')
        markdown = self.checkpoint_markdown(envelope['record'], envelope['hash'])
        if digest(markdown.encode()) != envelope['view_digest']:
            raise Invalid('manual view digest mismatch')
        if actual != envelope['view_digest']:
            atomic(view, markdown, raw=True)
        if digest(view.read_bytes()) != envelope['view_digest']:
            raise Invalid('manual view readback failed')

    def export_view(self, expected, expected_hash):
        with self.lock():
            state = self.current(expected)
            self.check_handoff(state, expected_hash)
            self.write_view(state)

    def delivery_repair(self, expected, repair_id, attempts):
        """Spend a protected controller reservation without renewing task authority."""
        with self.lock():
            state = self.current(expected)
            base = Path(git(self.root, 'rev-parse', '--path-format=absolute', '--git-common-dir')) / 'launch-queue'
            queue = read_json(base / 'active.json')
            claim = next(item for item in queue['items'] if item.get('run') == state['run'])
            delivery = claim.get('delivery', {})
            repair = delivery.get('repair', {})
            if (self.platform != 'codex' or not _git_binding or delivery.get('grant') != _git_binding
                    or not isinstance(repair_id, str) or not re.fullmatch('[0-9a-f]{64}', repair_id)
                    or repair.get('id') != repair_id or type(attempts) is not int
                    or repair.get('attempts') != attempts or claim.get('attempts') != attempts
                    or not 0 < attempts < state['max_attempts']
                    or time.time() >= min(state['deadline'], queue['deadline'])
                    or state['policy'] != self.policy() or state['runtime'] != digest(Path(__file__).read_bytes())):
                raise Invalid('delivery repair authority or budget changed')
            if state.get('delivery_repair') == repair_id:
                if state['attempts'] != attempts or state['status'] not in ('running', 'handoff'):
                    raise Invalid('delivery repair replay changed')
                return state
            if (state['status'] != 'awaiting_review' or repair.get('previous_attempts') != state['attempts']
                    or attempts != state['attempts'] + 1 or repair.get('candidate') != self.ident['revision']
                    or repair.get('fingerprint') != fingerprint(self.root)
                    or not state.get('receipt', {}).get('ok')):
                raise Invalid('delivery repair candidate or reservation changed')
            state.update(status='running', attempts=attempts, delivery_repair=repair_id,
                         reason='base advanced; fresh verification and independent review required')
            state.pop('receipt', None)
            self.save(state)
            return self.load(state['run'])

    def seal(self, expected, notes):
        fields = {'goal', 'scope', 'completed', 'next_phase', 'next_action', 'questions', 'evidence', 'unsafe_state', 'reversal'}
        if not isinstance(notes, dict) or set(notes) != fields or any(not isinstance(v, str) or not v.strip() for v in notes.values()):
            raise Invalid('complete structured semantic notes required')
        with self.lock():
            state = self.current(expected)
            if not self.eligible(state):
                raise Invalid('task is not eligible for checkpoint handoff')
            view = self.base / state['run'] / 'checkpoint.md'
            safe_path(view)
            prior = state.get('handoff', {}).get('view_digest')
            if (prior and (not view.is_file() or digest(view.read_bytes()) != prior)) or (view.exists() and not prior):
                raise Invalid('manual checkpoint view changed or is not owned')
            record = {k: state[k] for k in ('repo', 'worktree', 'branch', 'run', 'task', 'platform', 'session', 'deadline', 'attempts', 'max_attempts', 'controller', 'policy', 'runtime')}
            record.update(revision=self.ident['revision'], fingerprint=fingerprint(self.root),
                          index_digest=self.index_digest(), snapshot_sequence=state['sequence'] + 1, semantic=notes)
            key = digest(json.dumps(record, sort_keys=True).encode())
            markdown = self.checkpoint_markdown(record, key)
            state.update(status='handoff', notes=json.dumps(notes, sort_keys=True), checkpoint_revision=self.ident['revision'],
                         handoff={'record': record, 'hash': key, 'stage': 'checkpointed', 'view_digest': digest(markdown.encode()), 'previous_view_digest': prior})
            self.save(state)  # active.json is authoritative; history and Markdown are derived.
            persisted = self.load(state['run'])
            self.check_handoff(persisted, key)
            self.write_view(persisted)
            return persisted

    def bind(self, expected, expected_hash, session):
        with self.lock():
            state = self.current(expected)
            record = self.check_handoff(state, expected_hash)
            if not isinstance(session, str) or not session.strip() or session == record['session']:
                raise Invalid('replacement requires a different native session')
            if state['handoff']['stage'] == 'bound':
                if state['session'] != session:
                    raise Invalid('checkpoint already bound to another session')
                return state
            if state['status'] != 'handoff' or state['handoff']['stage'] != 'checkpointed':
                raise Invalid('checkpoint is not awaiting replacement')
            if state.get('pending_hook_session', session) != session:
                raise Invalid('replacement startup hook session mismatch')
            state.update(status='running', session=session, revision=record['revision'], checkpoint_revision=record['revision'])
            state.pop('checkpoint_only', None)
            state.pop('checkpoint_denials', None)
            state.pop('hook_session', None)
            if state.get('pending_hook_session'):
                state['hook_session'] = state.pop('pending_hook_session')
            state['handoff']['stage'] = 'bound'
            self.save(state)
            persisted = self.load(state['run'])
            self.check_handoff(persisted, expected_hash)
            return persisted

    def policy(self):
        paths = [self.config, self.root / f".{self.platform}/hooks/launch.sh", self.root / "scripts/verify.sh",
                 self.root / ('.codex/hooks.json' if self.platform == 'codex' else '.claude/settings.json')]
        if self.platform == 'codex':
            paths.append(self.root / '.codex/config.toml')
        return {str(p): digest(p.read_bytes()) if p.is_file() and not p.is_symlink() else "absent" for p in paths}

    def eligible(self, state):
        if state["status"] == "awaiting_review":
            receipt = state.get("receipt", {})
            if receipt.get("revision") != self.ident["revision"] or receipt.get("fingerprint") != fingerprint(self.root) or state["policy"] != self.policy():
                state.update(status="paused", reason="review evidence invalidated by candidate or policy change")
                self.save(state)
            return False
        if state["status"] != "running":
            return False
        if state["policy"] != self.policy() or state["runtime"] != digest(Path(__file__).read_bytes()):
            state.update(status="paused", reason="verification policy changed; human review required")
        elif state.get('controller') and not self.controlled(state):
            state.update(status='paused', reason='controller no longer owns the matching queue claim and lock')
        elif time.time() >= state["deadline"]:
            state.update(status="paused", reason="run deadline exhausted")
        elif state["attempts"] >= state["max_attempts"]:
            state.update(status="blocked", reason="repair attempts exhausted")
        else:
            return True
        self.save(state)
        return False

    def verify(self, state, mode, candidate, acceptance):
        if state and not self.eligible(state):
            raise Invalid(state.get("reason", state["status"]))
        cfg = config_at(self.config, self.root)
        before = fingerprint(self.root)
        receipt = {**identity(self.root), "platform": self.platform, "config_digest": digest(self.config.read_bytes()), "fingerprint": before,
                   "mode": mode, "checks": [], "ok": False, "started": time.time()}
        if state:
            receipt.update(run=state["run"], task=state["task"])
        receipt["checks"], stopped = run_checks(self.root, cfg["checks"], state["deadline"] if state else None)
        if stopped:
            receipt["reason"] = stopped
        receipt["ok"] = all(c["exit"] == 0 for c in receipt["checks"]) and len(receipt["checks"]) == len(cfg["checks"])
        if fingerprint(self.root) != before or identity(self.root) != {k:receipt[k] for k in self.ident} or digest(self.config.read_bytes()) != receipt["config_digest"]:
            receipt.update(ok=False, reason="candidate or configuration changed during checks")
        if mode == "ready":
            if not state or candidate != receipt["revision"] or git(self.root, "status", "--porcelain", "--untracked-files=all"):
                receipt.update(ok=False, reason="readiness requires exact candidate and clean assigned worktree")
            if not cfg["acceptance"]:
                receipt.update(ok=False, reason="task acceptance contract is empty")
            try:
                evidence = read_json(acceptance) if acceptance else {}
            except Invalid:
                evidence = {}
            if not acceptance_ok(evidence, receipt, cfg["acceptance"]):
                receipt.update(ok=False, reason="missing or mismatched task acceptance evidence")
            receipt["acceptance"] = evidence
        receipt["finished"] = time.time()
        if state and receipt["finished"] >= state["deadline"]:
            receipt.update(ok=False, reason="run deadline exhausted")
        atomic(self.base / "receipt.json", receipt)
        if state:
            state["receipt"] = {**receipt, "checks": [
                {key: value for key, value in check.items() if key != "output"}
                for check in receipt["checks"]
            ]}
            state["revision"] = receipt["revision"]
            if not receipt["ok"]:
                state["attempts"] += 1
                state["reason"] = receipt.get("reason", "declared checks failed")
                if state["attempts"] >= state["max_attempts"]:
                    state["status"] = "blocked"
            elif mode == "ready":
                state.update(status="awaiting_review", reason="local checks and supplied acceptance evidence recorded; human delivery review required")
            if time.time() >= state["deadline"]:
                state.update(status="paused", reason="run deadline exhausted")
            self.save(state)
        return receipt

    def hook(self, payload, run):
        if not run:
            return {}
        if not isinstance(payload, dict):
            raise Invalid('hook payload must be an object')
        state = self.load(run)
        event = payload.get("hook_event_name")
        if self.platform == 'claude' and event == 'PreToolUse' and state.get('calibrating'):
            expected_hash = state.get('handoff', {}).get('hash', '')
            observed = state.get('pending_hook_session') or state.get('hook_session')
            if (payload.get('tool_name') == 'StructuredOutput' and payload.get('tool_input') == {'loaded_hash': expected_hash}
                    and observed and payload.get('session_id') == observed and not payload.get('agent_id')
                    and payload.get('cwd') == str(self.root) and self.controlled(state)):
                return {}  # Native data formatter only; retain native permission handling.
            return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                    'permissionDecisionReason': 'Launch native calibration has not admitted tool work.'}}
        if self.platform == 'claude' and event == 'PreToolUse' and state.get('checkpoint_only'):
            bound = (payload.get('session_id') == state['session'] and not payload.get('agent_id')
                     and payload.get('cwd') == str(self.root) and self.controlled(state)
                     and state['status'] == 'running' and time.time() < state['deadline'])
            values = payload.get('tool_input')
            fields = {'goal', 'scope', 'completed', 'next_phase', 'next_action', 'questions',
                      'evidence', 'unsafe_state', 'reversal'}
            if (bound and payload.get('tool_name') == 'StructuredOutput' and isinstance(values, dict)
                    and set(values) == fields | {'loaded_hash'}
                    and all(isinstance(values[k], str) and values[k].strip() for k in fields)
                    and values['loaded_hash'] == state.get('handoff', {}).get('hash', '')):
                return {}  # Native formatter only; never grant a native permission.
            ident = payload.get('tool_use_id')
            if bound and isinstance(ident, str) and ident and payload.get('tool_name') != 'StructuredOutput':
                # The hook entry point already holds the runtime lock.
                state['checkpoint_denials'][ident] = digest(json.dumps(
                    [payload.get('tool_name'), values], sort_keys=True).encode())
                self.save(state)
            return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                    'permissionDecisionReason': 'Context threshold reached. Do not attempt more work tools. '
                    'Return complete semantic checkpoint JSON with the exact next action and loaded_hash now; '
                    'the controller will continue in a fresh session.'}}
        if self.platform == 'claude' and event == 'PreToolUse' and self.controlled(state):
            refusal = self.tool_refusal(payload, state)
            if refusal:
                return deny_tool(f'Launch refused {payload.get("tool_name")} ({refusal}) before it ran: only declared '
                                 'synchronous commands and local file tools are admitted. Publication (push, PR, merge, '
                                 'source Done) is Codex-only (D4); finish at awaiting_review.')
        clearing = event == 'SessionStart' and payload.get('source') == 'clear'
        session = payload.get('session_id')
        if state['status'] == 'initializing':
            if clearing and not payload.get('agent_id') and payload.get('cwd') == str(self.root) and isinstance(session, str) and session:
                state.update(status='paused', reason='session cleared during native initialization')
                self.save(state)
                return self.stop_output(state)
            if payload.get('agent_id') or event != 'SessionStart' or payload.get('source') != 'startup':
                return self.stop_output(state)
            if (not isinstance(session, str) or not session or not self.controlled(state)
                    or payload.get('cwd') != str(self.root) or state.get('hook_session', session) != session):
                raise Invalid('pending native startup hook mismatch')
            state['hook_session'] = session
            self.save(state)
            return {}  # Thread creation may finish; controller has not admitted a turn.
        if (state['status'] == 'handoff' and event == 'SessionStart' and payload.get('source') == 'startup'
                and not payload.get('agent_id') and session != state['session']):
            if (not isinstance(session, str) or not session or not self.controlled(state)
                    or payload.get('cwd') != str(self.root) or state.get('pending_hook_session', session) != session):
                raise Invalid('replacement startup hook mismatch')
            state['pending_hook_session'] = session
            self.save(state)
            return {}  # Observation only; only the controller can bind the returned native ID.
        if (payload.get("agent_id") or not isinstance(session, str) or not session
                or (session != state["session"] and not clearing)):
            return {}
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not Path(cwd).is_absolute():
            raise Invalid("hook worktree mismatch")
        cwd = Path(cwd).resolve()
        if (not cwd.is_dir() or not cwd.is_relative_to(self.root)
                or Path(git(cwd, "rev-parse", "--show-toplevel")).resolve() != self.root):
            raise Invalid("hook worktree mismatch")
        if self.platform == 'codex':
            if event not in ('SessionStart', 'PreCompact', 'Stop'):
                raise Invalid('unsupported native lifecycle event')
            if event == 'Stop' and type(payload.get('stop_hook_active')) is not bool:
                raise Invalid('native Stop requires boolean stop_hook_active')
            if event == 'PreCompact' and payload.get('trigger') not in ('manual', 'auto'):
                raise Invalid('unsupported native compaction trigger')
            if event == 'SessionStart' and payload.get('source') not in ('startup', 'resume', 'compact', 'clear'):
                raise Invalid('unsupported native session source')
        if clearing:
            # Native clear creates a new session ID. Its run envelope may only
            # pause work, never inherit context or bind the replacement session.
            if state['status'] in ('running', 'handoff'):
                state.update(status="paused", reason="session cleared; explicit recovery required")
                self.save(state)
            return self.stop_output(state) if self.platform == 'codex' else {}
        if not self.eligible(state):
            return self.stop_output(state)
        if event == "PreCompact":
            state["checkpoint_revision"] = self.ident["revision"]
            self.save(state)
        elif event == "SessionStart" and payload.get("source") in ("startup", "resume", "compact"):
            if state.get("checkpoint_revision", state["revision"]) != self.ident["revision"]:
                raise Invalid("checkpoint revision mismatch; reconcile with explicit notes before resuming")
            if state.get('controller'):
                state['hook_session'] = session
                self.save(state)
            return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Active supervised Launch checkpoint:\n" + json.dumps(state)}}
        elif event == "Stop":
            if self.controlled(state):
                return {}  # The bound controller validates this turn before admitting another.
            if payload.get("stop_hook_active"):
                state.update(status="paused", reason="continuation did not reach a phase boundary; explicit recovery required")
                self.save(state)
                return self.stop_output(state)
            return {"decision": "block", "reason": f'Launch task {state["task"]} remains running. Follow the approved plan, save phase notes, run explicit verification, or persist paused/blocked with a reason. Do not publish or select another task.'}
        return {}

    def tool_refusal(self, payload, state):
        """D4: a queue-controlled Claude worker meets the adapter's allowlist before a tool runs, not after."""
        if payload.get('agent_id'):
            return 'subagent'
        if payload.get('tool_name') == 'StructuredOutput':
            return None  # Native turn formatter; the adapter validates its input as notes.
        if state['policy'] != self.policy():
            return 'policy changed'  # The queue snapshots checks at launch; an edited verify.json must not widen them.
        try:
            manifest = read_json(Path(os.environ['LAUNCH_MANIFEST']))
        except (KeyError, Invalid, OSError, ValueError):
            return 'controller manifest unavailable'
        if not isinstance(manifest, dict) or digest(json.dumps(manifest, sort_keys=True).encode()) != state['controller']:
            return 'controller manifest changed'
        sys.dont_write_bytecode = True  # Never leave __pycache__ beside installed, digest-owned scripts.
        spec = importlib.util.spec_from_file_location('launch_claude_gate', Path(__file__).with_name('launch-claude.py'))
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        # Mirrors the queue's `synchronous` closure. Read roots come only from Codex delivery. The canonical
        # verify commands need the prepared binding: env roots from the controller plus the policy check above.
        declared = (manifest.get('rollover') or {}).get('synchronous_commands', [])
        checks = config_at(self.config, self.root)['checks']
        protected = None
        if os.environ.get('LAUNCH_GIT_DIR') or os.environ.get('LAUNCH_GIT_COMMON_DIR'):
            # Set by the controller at launch; a tool subprocess cannot change its parent's env.
            roots = (os.environ.get('LAUNCH_GIT_DIR'), os.environ.get('LAUNCH_GIT_COMMON_DIR'))
            if git_roots(self.root) != roots:
                return 'git roots changed'
            protected = {'git_dir': roots[0], 'common_dir': roots[1], 'worktree': str(self.root), 'config_dir': claude_config_dir()}
        return adapter.tool_refusal(payload.get('tool_name'), payload.get('tool_input'),
                                    lambda command: canonical_verify(command, declared, protected)
                                    or synchronous_shell(command, declared, self.root, checks, ()), protected)

    def stop_output(self, state):
        message = f'Launch {state["status"]}: {state.get("reason", "human action required")}'
        result = {'systemMessage': message}
        if self.platform == 'codex':
            result.update({'continue': False, 'stopReason': message})
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path)
    parser.add_argument("--platform", choices=('claude', 'codex'), default='claude')
    parser.add_argument('--delivery-binding', type=Path)
    parser.add_argument('--delivery-binding-digest')
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("validate-config")
    overlay = sub.add_parser("validate-overlay")
    overlay.add_argument("--commands", type=Path, required=True)
    overlay.add_argument('--controller', type=Path)
    overlay.add_argument('--controller-digest')
    overlay.add_argument('--shared-root', type=Path)
    overlay.add_argument('--overlay-delivery-binding', type=Path)
    overlay.add_argument('--overlay-delivery-binding-digest')
    render = sub.add_parser('render-overlay')
    render.add_argument('--from-config', type=Path, required=True)
    start = sub.add_parser("start")
    start.add_argument("--task", required=True)
    start.add_argument("--session", required=True)
    start.add_argument("--supervised", action="store_true", required=True)
    start.add_argument("--minutes", type=int, default=60)
    start.add_argument("--max-attempts", type=int, default=5)
    checkpoint = sub.add_parser('checkpoint')
    checkpoint.add_argument('--run', required=True)
    checkpoint.add_argument('--hash', required=True)
    for name in ("notes", "pause", "block", "recover", "status"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--run", required=True)
        if name in ("notes", "pause", "block", "recover"):
            cmd.add_argument("--text", required=True)
        if name == "recover":
            cmd.add_argument("--session", required=True)
            cmd.add_argument("--minutes", type=int, default=60)
            cmd.add_argument("--reset-attempts", action="store_true")
    verify = sub.add_parser("verify")
    verify.add_argument("mode", choices=("checks", "ready"))
    verify.add_argument("--run", default=os.environ.get("LAUNCH_RUN_ID"))
    verify.add_argument("--candidate")
    verify.add_argument("--acceptance", type=Path)
    sub.add_parser("hook")
    args = parser.parse_args()
    if args.action == "hook" and not os.environ.get("LAUNCH_RUN_ID"):
        return 0
    if args.delivery_binding is not None or args.delivery_binding_digest is not None:
        delivery_module().bind_runtime(sys.modules[__name__], {
            'grant': str(args.delivery_binding) if args.delivery_binding is not None else None,
            'digest': args.delivery_binding_digest})
    if args.action == 'hook' and args.platform == 'codex':
        try:
            runtime = Runtime(args.project, args.config, args.platform)
            with runtime.lock():
                result = runtime.hook(json.load(sys.stdin), os.environ['LAUNCH_RUN_ID'])
        except (Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            # Codex can continue after hook process failures; use its native stop contract.
            result = {'continue': False, 'stopReason': f'Launch blocked: {error}'}
        print(json.dumps(result))
        return 0
    if args.action == 'hook' and args.platform == 'claude':
        payload = None
        try:
            payload = json.load(sys.stdin)
            runtime = Runtime(args.project, args.config, args.platform)
            with runtime.lock():
                result = runtime.hook(payload, os.environ.get('LAUNCH_RUN_ID', ''))
        except (Exception, SystemExit) as error:
            # Claude runs the tool when a PreToolUse hook exits 1. A queue-launched worker (its
            # controller sets LAUNCH_MANIFEST) fails closed; ordinary sessions keep prior behavior.
            if not (os.environ.get('LAUNCH_MANIFEST') and isinstance(payload, dict)
                    and payload.get('hook_event_name') == 'PreToolUse'):
                raise
            result = deny_tool(f'Launch blocked: {error}')
        print(json.dumps(result))
        return 0
    runtime = Runtime(args.project, args.config, args.platform)
    if args.action == "validate-overlay":
        validate_overlay(runtime, args.commands, args.controller, args.controller_digest, args.shared_root,
                         args.overlay_delivery_binding, args.overlay_delivery_binding_digest)
        return 0
    if args.action == 'render-overlay':
        if args.platform != 'claude':
            raise Invalid('render-overlay generates the Claude overlay only')
        render_overlay(runtime, args.from_config.absolute())
        return 0
    if args.action == "validate-config":
        config_at(runtime.config, runtime.root)
        return 0
    with runtime.lock():
        if args.action == "start":
            state = runtime.begin(args.task, args.session, args.minutes, args.max_attempts)
            print(json.dumps(state))
        elif args.action == "hook":
            print(json.dumps(runtime.hook(json.load(sys.stdin), os.environ["LAUNCH_RUN_ID"])))
        elif args.action == "verify":
            state = runtime.load(args.run) if args.run else None
            if state is None and runtime.state_path.exists():
                raise Invalid("active run requires --run or LAUNCH_RUN_ID")
            receipt = runtime.verify(state, args.mode, args.candidate, args.acceptance)
            print(json.dumps(receipt))
            return 0 if receipt["ok"] else 1
        elif args.action == 'checkpoint':
            print(json.dumps(runtime.check_handoff(runtime.load(args.run), args.hash), indent=2))
        else:
            state = runtime.load(args.run)
            if args.action == "status":
                runtime.eligible(state)
            if args.action == "recover":
                if not args.text.strip() or not args.session.strip() or not 1 <= args.minutes <= 60:
                    raise Invalid("recovery requires reason and bounded deadline")
                state.update(status="running", session=args.session, deadline=time.time()+args.minutes*60, reason=args.text, revision=runtime.ident["revision"], checkpoint_revision=runtime.ident["revision"], policy=runtime.policy(), runtime=digest(Path(__file__).read_bytes()))
                if args.reset_attempts:
                    state["attempts"] = 0
            elif args.action == "notes":
                state.update(notes=args.text, checkpoint_revision=runtime.ident["revision"])
            elif args.action in ("pause", "block"):
                state.update(status="paused" if args.action == "pause" else "blocked", reason=args.text)
            if args.action != "status":
                runtime.save(state)
            print(json.dumps(state))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Launch blocked: {error}", file=sys.stderr)
        sys.exit(1)
