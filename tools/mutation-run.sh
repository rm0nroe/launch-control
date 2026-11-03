#!/usr/bin/env bash
set -euo pipefail

# Run one mutation test against skills/ or agents/ and restore the tree afterwards.
#
#   ./tools/mutation-run.sh --mutate '<shell that edits the tree>' -- <test command...>
#
# Exists because three separate mechanics made hand-run mutation testing report
# passes that meant nothing:
#
#   1. The ownership digest gate (tools/validate/10-pack-inventory.sh) rejects a
#      mutated tree before any behavioral case runs, so every mutation needed a
#      hand-appended manifest row -- and the hand-appended row had to be undone
#      afterwards or it shipped.
#   2. A mutation command that silently matched nothing left the tree identical
#      to the fixed file. Both arms then passed and the mutant looked killed.
#      Step "verify the mutation landed" below turns that into a hard failure.
#   3. A run killed by a timeout (a full validate-pack.sh is ~13-15 min) left the
#      mutant in the working tree, where the next run read it as source.
#
# Restore works from a pre-mutation copy, never from git: mutation testing a fix
# means the tree carries that uncommitted fix, and `git checkout --` would
# discard it along with the mutant.
#
# This wrapper changes nothing about a normal run. The digest gate it works
# around is only ever relaxed inside a tree this script has already mutated, and
# only until the same invocation restores it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=launch-control-digests.sh
. "$ROOT/tools/launch-control-digests.sh"

MANIFEST_REL="install/launch-control-owned-digests.txt"

# Every directory a mutation may target. `tools/` and `install/` are as mutable as the
# skills are -- the validator parts, the installer and the ownership manifest all live
# there -- and scoping snapshot, no-op detection and restore to skills+agents alone made
# this script silently wrong for them: a mutation of tools/preflight-onboard.sh reported
# "changed nothing" (the digests it compared had genuinely not moved), and the restore left
# the mutant in the working tree, where three successive runs stacked their edits on top of
# each other. Add a directory here rather than teaching any one step about it.
SCOPE_DIRS=(skills agents tools install)

usage() {
  printf '%s\n' \
    "usage: tools/mutation-run.sh --mutate '<shell>' -- <test command...>" \
    '' \
    "  --mutate  shell run in the repo root that introduces the defect" \
    "  --        everything after it is the command that should FAIL on the mutant" >&2
}

mutate=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mutate)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      mutate="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [ -z "$mutate" ] || [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

snapshot="$(mktemp -d "${TMPDIR:-/tmp}/launch-control-mutation.XXXXXX")"
for scope_dir in "${SCOPE_DIRS[@]}"; do
  cp -R "$ROOT/$scope_dir" "$snapshot/$scope_dir"
done
# Written last: the trap restores only from a snapshot proven complete, so a
# copy that died halfway can never overwrite the real tree with a partial one.
: > "$snapshot/.complete"

# Non-atomic by design: each scope directory is removed and re-copied in turn, so a SIGKILL
# mid-restore leaves the tree partially reverted. Every scope directory is git-tracked, so
# `git checkout -- skills agents tools install` recovers it -- stated here rather than left
# as tribal knowledge, because the widened scope now covers the toolchain itself.
restore() {
  local status=$? scope_dir
  if [ -f "$snapshot/.complete" ]; then
    for scope_dir in "${SCOPE_DIRS[@]}"; do
      rm -rf "${ROOT:?}/$scope_dir"
      cp -R "$snapshot/$scope_dir" "$ROOT/$scope_dir"
    done
  else
    printf 'mutation-run: snapshot incomplete, tree NOT restored: %s\n' "$snapshot" >&2
  fi
  rm -rf "$snapshot"
  exit "$status"
}
trap restore EXIT INT TERM

# Content checksum over the whole scope, not the ownership digests. The digests cover
# skills/ and agents/ only, so using them to answer "did the mutation land?" made every
# mutation of a tools/ or install/ file look like a no-op.
scope_checksum() {
  local scope_dir
  for scope_dir in "${SCOPE_DIRS[@]}"; do
    find "$ROOT/$scope_dir" -type f -print0
  done | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }'
}

item_digests() {
  local item scope name
  for item in "$ROOT"/skills/* "$ROOT"/agents/*; do
    [ -e "$item" ] || continue
    case "$item" in
      "$ROOT"/skills/*) scope=skills ;;
      *) scope=agents ;;
    esac
    name="$(basename "$item")"
    printf '%s %s %s\n' "$scope" "$name" "$(launch_control_item_digest "$item")"
  done
}

checksum_before="$(scope_checksum)"
( cd "$ROOT" && eval "$mutate" )
checksum_after="$(scope_checksum)"
after="$(item_digests)"

# Verify the mutation landed. Without this a no-op edit -- a pattern that matched
# nothing, a path that did not exist -- produces a "mutant" byte-identical to the
# source, and the test passes for the wrong reason.
if [ "$checksum_before" = "$checksum_after" ]; then
  printf 'mutation-run: FAIL -- the mutation changed nothing under %s.\n' "${SCOPE_DIRS[*]}" >&2
  printf '%s\n' '              A test result against this tree would be meaningless.' >&2
  exit 2
fi

# Re-open the digest gate for exactly the items the mutation moved, so the
# behavioral cases actually run. The trap above puts the manifest back.
appended=0
while read -r scope name digest; do
  if ! launch_control_manifest_has_digest "$ROOT/$MANIFEST_REL" "$scope" "$name" "$digest"; then
    printf '%s %s %s\n' "$scope" "$name" "$digest" >> "$ROOT/$MANIFEST_REL"
    appended=$((appended + 1))
  fi
done <<EOF
$after
EOF
printf 'mutation-run: mutation applied, %s digest row(s) appended for this run.\n' "$appended" >&2

status=0
"$@" || status=$?

if [ "$status" -eq 0 ]; then
  printf 'mutation-run: MUTANT SURVIVED -- `%s` passed against the mutated tree.\n' "$*" >&2
else
  printf 'mutation-run: mutant killed (exit %s).\n' "$status" >&2
fi
exit "$status"
