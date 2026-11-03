# shellcheck shell=bash
# Shared state and helpers for the validator parts.
# Sourced first by tools/validate-pack.sh; every part below it relies on ROOT,
# MANIFEST, failures, run_rg, and check_absent being defined here.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/tools/fixtures/onboard-manifests.json"
failures=0

# Every fixture render would otherwise open its HTML report on the developer's desktop.
# Exported here, not in validate-pack.sh, so the partial runs CONTRIBUTING.md documents
# (sourcing lib.sh plus a few parts) get it too: they used to skip it and opened ~7 tabs a run.
export LAUNCH_CONTROL_NO_OPEN=1

# Fixture repositories commit as part of the suite, and 12 of the 51 never configure an
# identity of their own. Those commits only succeed where git can DERIVE one, which is why
# this looked OS-specific for so long: a macOS account carries a full name, while a Linux CI
# runner's `runner` user has no GECOS name, so git refuses with `empty ident name` and the
# whole suite aborts at whichever unconfigured fixture happens to come first
# (30-guard-lifecycle.sh:1138 today). Setting it here rather than in each fixture makes the
# suite independent of ambient git configuration and covers every fixture added later that
# forgets. Nothing asserts on author or committer identity, and the env vars deliberately
# override the per-repo config the other 39 fixtures set.
export GIT_AUTHOR_NAME=launch-control-validator
export GIT_AUTHOR_EMAIL=validator@example.com
export GIT_COMMITTER_NAME=launch-control-validator
export GIT_COMMITTER_EMAIL=validator@example.com

# The same class of ambient dependency, one field over: 7 of the fixtures call `git init` with
# no `-b`, so their branch is whatever `init.defaultBranch` happens to say. A developer who has
# set it to `main` -- the common case, and why this passed locally for months -- gets `main`,
# while a stock CI runner leaves it unset and gets `master`. Every one of those fixtures then
# hands the renderer `main` as the reported branch, and the renderer verifies that against
# `git branch --show-current` and exits 1 on the mismatch. It stayed invisible until the ident
# fix above let CI run far enough to reach the render-timing fixture at all.
#
# Pinned here rather than by adding `-b main` to each call site, for the reason the identity
# block gives: this covers every fixture added later that forgets. `GIT_CONFIG_*` is the only
# spelling that survives `HOME`/`XDG_CONFIG_HOME` differences between a developer and CI.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=init.defaultBranch
export GIT_CONFIG_VALUE_0=main

if [ "${LAUNCH_CONTROL_VALIDATE_NESTED:-}" = 1 ] && env | grep '^ONBOARD_' >/dev/null; then
  printf '%s\n' 'FAIL: nested validator inherited outer ONBOARD_* finalizer metadata' >&2
  exit 1
fi

# The suite runs under `set -e`, so an unguarded assertion (a bare `run_rg -q`,
# a `test -f`) aborted the whole run with a bare `exit 1` and no clue which one
# fired -- the failure mode that forced `PS4='+${LINENO}: ' bash -x` bisects for
# four rounds running. `set -E` propagates this trap into functions so the abort
# names the file and line of the assertion that fired.
#
# Reported only at subshell depth 0. Command substitutions run in a subshell
# where errexit's condition exemption does not reach, so a guarded
# `if output="$(...)"` would otherwise print an abort notice on its PASSING
# path. A genuine failure inside a subshell still surfaces: the subshell exits
# nonzero and the enclosing top-level command reports at depth 0.
validator_report_abort() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  printf 'FAIL: validator aborted (exit %s) at %s:%s\n      command: %s\n' \
    "$1" "$2" "$3" "$4" >&2
}
set -E
trap 'validator_report_abort "$?" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND"' ERR

RG_BIN="$(type -P rg 2>/dev/null || true)"
run_rg() {
  # Each branch captures its status instead of ending the function, for two
  # reasons: `exec -a rg` needs a subshell, and a failure there is invisible to
  # the depth-0 trap; and a bare failing command as the last statement of a
  # function does not fire the ERR trap on bash 3.2 the way an explicit
  # `return` does. Both paths now converge on that `return`, so an unguarded
  # `run_rg -q` names its caller instead of aborting silently.
  local status=0
  if [ -n "$RG_BIN" ]; then
    "$RG_BIN" "$@" || status=$?
  elif [ -n "${CLAUDE_CODE_EXECPATH:-}" ] && [ -x "$CLAUDE_CODE_EXECPATH" ]; then
    (exec -a rg "$CLAUDE_CODE_EXECPATH" "$@") || status=$?
  else
    printf '%s\n' 'FAIL: ripgrep unavailable (install rg or run from a Claude Code session that exposes CLAUDE_CODE_EXECPATH)' >&2
    status=127
  fi
  return "$status"
}

check_absent() {
  local pattern="$1"
  shift
  local output
  if output="$(run_rg -n "$pattern" "$@" 2>/dev/null)"; then
    printf 'FAIL: forbidden pattern %s\n%s\n' "$pattern" "$output"
    failures=$((failures + 1))
  fi
}
