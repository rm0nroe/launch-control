#!/usr/bin/env bash
set -euo pipefail

# Remove the workspace `/onboard` generated in THIS repository.
#
# `./install.sh --uninstall` cannot do this: `uninstall_paths()` reads only skills/agents rows
# from the ownership manifest, rooted at $CLAUDE_CONFIG_DIR. It removes the TOOL. Everything
# /onboard writes lives in the target repository and survives a pack uninstall untouched.
#
# ROUND-11 INCIDENT, and the reason this script exists: `rm -rf .claude` deleted 24 TRACKED
# files in target repo A, which commits its `.claude/` tree. Two rules follow, and both
# are load-bearing:
#   1. Never remove by directory. Every removal is an enumerated path.
#   2. Never delete a tracked file. Untracked generated files are removed; tracked ones are
#      reported for the user to decide, because deleting a committed file is a repository
#      change that is theirs to make.
# Directory cleanup is `rmdir` only -- non-recursive, fails on non-empty, so it can never
# take a file with it.

usage() {
  cat <<'EOF'
offboard -- remove the workspace /onboard generated in this repository

  reset.sh              preview only; changes nothing (default)
  reset.sh --apply      perform the removal
  reset.sh --yes        skip the confirmation prompt (with --apply)
  reset.sh --help       this message

Run from the root of the repository you want cleaned.
EOF
}

APPLY=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'offboard: unknown option %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# --- location guard -------------------------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'offboard: not a git repository. Run this from the root of the repo you want cleaned.\n' >&2
  exit 2
}
REPO_ROOT="$(git rev-parse --show-toplevel)"
# Compare PHYSICAL paths. On macOS `git rev-parse --show-toplevel` resolves /var -> /private/var
# while $PWD keeps the symlink, so a literal string compare rejects every run under a tmpdir and
# any checkout reached through a symlink.
if [ "$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" != "$(pwd -P)" ]; then
  printf 'offboard: run from the repository root (%s), not %s\n' "$REPO_ROOT" "$PWD" >&2
  exit 2
fi
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"

# --- manifest source ------------------------------------------------------------------------
# Read the generated-path list from the INSTALLED renderer rather than restating it here. One
# definition, so the two cannot drift -- the defect class fixed in 2e6a03c, where an
# independent copy of a rule disagreed with the original.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RENDERER=""
# Look beside this script FIRST. `offboard` and `onboard` are sibling skills both installed and
# in the source tree, so ../../onboard/scripts resolves in either layout and needs no ambient
# state. Without this the script silently depended on whatever $CLAUDE_CONFIG_DIR happened to
# hold -- which passed by luck against a real ~/.claude and failed the moment the validator
# supplied an empty one.
for candidate in \
  "$SELF_DIR/../references/claude-manifest.sh" \
  "$SELF_DIR/../onboard/scripts/render-report.sh" \
  "$SELF_DIR/../../onboard/scripts/render-report.sh" \
  "$CLAUDE_DIR/skills/onboard/scripts/render-report.sh" \
  "$REPO_ROOT/skills/onboard/scripts/render-report.sh"
do
  [ -f "$candidate" ] && { RENDERER="$candidate"; break; }
done
[ -n "$RENDERER" ] || {
  printf 'offboard: cannot find the onboard renderer to read the generated-path manifest.\n' >&2
  printf '        Looked in %s and %s\n' \
    "$CLAUDE_DIR/skills/onboard/scripts" "$REPO_ROOT/skills/onboard/scripts" >&2
  exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST_PATHS="$TMP/manifest"
sed -n "/^[[:space:]]*cat <<'EOF_MANIFEST'[[:space:]]*\$/,/^EOF_MANIFEST[[:space:]]*\$/p" "$RENDERER" \
  | sed '1d;$d' > "$MANIFEST_PATHS"
[ -s "$MANIFEST_PATHS" ] || {
  printf 'offboard: the renderer at %s carried no manifest block.\n' "$RENDERER" >&2
  exit 2
}

# Files onboard MERGES into content that already existed. These are stripped, never deleted --
# they hold user content that predates onboarding.
is_merge_target() {
  case "$1" in
    CLAUDE.md|AGENTS.md|.gitignore|.mcp.json) return 0 ;;
    *) return 1 ;;
  esac
}

is_tracked() { git ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }

# The generated block carries no comment scaffolding. It is located by its stable heading:
# `## Generated Quick Reference` through the next top-level (`# `) heading or end of file in
# CLAUDE.md / AGENTS.md, and the `# Claude Code local files` rule group in .gitignore.
# Legacy `BEGIN/END GENERATED SECTION -- onboard` markers from older onboard versions are
# still recognised and stripped so an old onboarding can be undone by the current reset.
GENERATED_HEADING='## Generated Quick Reference'
GITIGNORE_HEADING='# Claude Code local files'
has_legacy_marker() { LC_ALL=C grep -q 'BEGIN GENERATED SECTION -- onboard' "$1" 2>/dev/null; }
has_generated_block() {
  case "$1" in
    .gitignore) LC_ALL=C grep -Fqx "$GITIGNORE_HEADING" "$1" 2>/dev/null || has_legacy_marker "$1" ;;
    .mcp.json) return 1 ;;
    *) LC_ALL=C grep -Fqx "$GENERATED_HEADING" "$1" 2>/dev/null || has_legacy_marker "$1" ;;
  esac
}

DELETE="$TMP/delete"; : > "$DELETE"
STRIP="$TMP/strip"; : > "$STRIP"
KEEP_TRACKED="$TMP/keep-tracked"; : > "$KEEP_TRACKED"
CONTROL="$TMP/control"; : > "$CONTROL"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -e "$rel" ] || continue
  if is_merge_target "$rel"; then
    # A merge target only qualifies when it actually carries an onboard block; otherwise
    # onboard either created it outright or never touched it. .mcp.json is JSON and can
    # carry no block, so it is never stripped.
    if has_generated_block "$rel"; then
      printf '%s\n' "$rel" >> "$STRIP"
    elif is_tracked "$rel"; then
      printf '%s\n' "$rel" >> "$KEEP_TRACKED"
    else
      printf '%s\n' "$rel" >> "$DELETE"
    fi
  elif is_tracked "$rel"; then
    printf '%s\n' "$rel" >> "$KEEP_TRACKED"
  else
    printf '%s\n' "$rel" >> "$DELETE"
  fi
done < "$MANIFEST_PATHS"

# LC-061: `/onboard --codex` mirrors the same manifest into .codex/ (codex-parity.py's mapping:
# skills keep their path, commands become skills, agents become TOML plus an ownership record).
# Derived from the one manifest above, so the two lists cannot drift. Same rules: enumerated
# paths only, tracked files kept.
KEEP_UNPROVEN="$TMP/keep-unproven"; : > "$KEEP_UNPROVEN"
sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
codex_counterparts() {
  local name
  case "$1" in
    .claude/skills/*) printf '%s\n' ".codex/skills/${1#.claude/skills/}" ;;
    .claude/commands/*.md) name="${1#.claude/commands/}"; printf '%s\n' ".codex/skills/${name%.md}/SKILL.md" ;;
    .claude/agents/*.md) name="${1#.claude/agents/}"; printf '%s\n' ".codex/agents/${name%.md}.toml" ;;
  esac
}
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  while IFS= read -r mirror; do
    [ -e "$mirror" ] || continue
    if is_tracked "$mirror"; then printf '%s\n' "$mirror" >> "$KEEP_TRACKED"; continue; fi
    case "$mirror" in
      .codex/agents/*.toml)
        # An agent is generated only when its ownership record names its exact bytes, the same
        # proof codex-parity.py requires before replacing one; the record goes with it.
        record=".codex/launch-control-agent-ownership/$(basename "$mirror" .toml).json"
        if [ -f "$record" ] && ! is_tracked "$record" && LC_ALL=C grep -Fq "\"$(sha256_of "$mirror")\"" "$record"; then
          printf '%s\n' "$mirror" "$record" >> "$DELETE"
        else
          printf '%s\n' "$mirror" >> "$KEEP_UNPROVEN"
        fi ;;
      *) printf '%s\n' "$mirror" >> "$DELETE" ;;
    esac
  done < <(codex_counterparts "$rel")
done < "$MANIFEST_PATHS"
# codex-parity.py mirrors the CLAUDE.md block into AGENTS.md, a path no manifest lists.
if [ -f AGENTS.md ] && has_generated_block AGENTS.md; then printf 'AGENTS.md\n' >> "$STRIP"; fi

# Never delete through a symlinked directory: `rm` would reach files outside this repository,
# and git reports such paths as untracked whatever they are.
under_symlink() {
  local dir; dir="$(dirname "$1")"
  while [ "$dir" != . ] && [ "$dir" != / ]; do
    [ -L "$dir" ] && return 0
    dir="$(dirname "$dir")"
  done
  return 1
}
unlinked="$TMP/unlinked"; : > "$unlinked"
while IFS= read -r rel; do
  if under_symlink "$rel"; then printf '%s\n' "$rel" >> "$KEEP_UNPROVEN"; else printf '%s\n' "$rel" >> "$unlinked"; fi
done < "$DELETE"
mv "$unlinked" "$DELETE"
# A symlinked merge target is kept as well: stripping it would rewrite the file it points to.
unlinked="$TMP/unlinked"; : > "$unlinked"
while IFS= read -r rel; do
  if [ -L "$rel" ] || under_symlink "$rel"; then printf '%s\n' "$rel" >> "$KEEP_UNPROVEN"; else printf '%s\n' "$rel" >> "$unlinked"; fi
done < "$STRIP"
mv "$unlinked" "$STRIP"

# A removed bundle's portable-refresh receipt goes with it. Left behind, it makes the next onboard
# misread the fresh bundle as customized or refuse to recreate it. A bundle with any tracked file
# is only partly removed, so it keeps its receipt. Refresh backups stay: retained by contract.
RECEIPTS="$TMP/receipts"; : > "$RECEIPTS"
while IFS= read -r rel; do
  case "$rel" in
    .claude/skills/*/SKILL.md|.codex/skills/*/SKILL.md)
      runtime="${rel%%/*}"; runtime="${runtime#.}"; name="${rel#*/skills/}"; name="${name%/SKILL.md}"
      receipt=".launch-control/refresh/receipts/$runtime/$name.json"
      if [ -e "$receipt" ] && ! is_tracked "$receipt" && ! under_symlink "$receipt" &&
        [ -z "$(git ls-files -- "${rel%/SKILL.md}")" ]; then
        printf '%s\n' "$receipt" >> "$RECEIPTS"
      fi ;;
  esac
done < "$DELETE"
cat "$RECEIPTS" >> "$DELETE"

# Onboard control state. Ephemeral by definition; stale markers confuse a later run's guards.
[ -d "$REPO_ROOT/.launch-control-onboard" ] && printf '%s\n' ".launch-control-onboard/" >> "$CONTROL"
for marker in "$GIT_DIR_ABS"/launch-control-onboard-* "$GIT_DIR_ABS"/groundwork-onboard-*; do
  [ -e "$marker" ] || continue
  printf '%s\n' "${marker#"$REPO_ROOT"/}" >> "$CONTROL"
done
REPORT="$GIT_DIR_ABS/launch-control/onboard-report.html"
[ -f "$REPORT" ] && printf '%s\n' "${REPORT#"$REPO_ROOT"/}" >> "$CONTROL"

count() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0'; }
section() {
  local file="$1" heading="$2" note="${3:-}"
  local n; n="$(count "$file")"
  [ "$n" = 0 ] && return 0
  printf '\n%s (%s)\n' "$heading" "$n"
  [ -n "$note" ] && printf '  %s\n' "$note"
  sed 's/^/  /' "$file"
}

printf '=== offboard: %s ===\n' "$REPO_ROOT"
printf 'mode: adopt (derived from the onboard manifest; no receipt in this repo)\n'
section "$DELETE" 'Remove (untracked, generated)'
section "$STRIP" 'Strip generated block, keep the file' 'user content outside the generated block is preserved'
section "$CONTROL" 'Remove (onboard control state)'
section "$KEEP_TRACKED" 'NOT removed -- tracked by git' 'delete these yourself if you want them gone: git rm <path>'
section "$KEEP_UNPROVEN" 'NOT removed -- not provably generated' 'no ownership record for these bytes, or reached through a symlinked directory'

if [ "$(count "$DELETE")" = 0 ] && [ "$(count "$STRIP")" = 0 ] && [ "$(count "$CONTROL")" = 0 ]; then
  printf '\nNothing to do. No onboard-generated workspace found here.\n'
  exit 0
fi

if [ "$APPLY" != 1 ]; then
  printf '\nPreview only -- nothing was changed. Run with --apply to execute.\n'
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf '\nApply the above to %s? [y/N] ' "$REPO_ROOT"
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) printf 'Aborted. Nothing was changed.\n'; exit 1 ;;
  esac
fi

strip_generated_block() {
  # Delete the inclusive BEGIN..END span. awk, not sed -i: portable across BSD/GNU, and it
  # cannot silently rewrite the whole file if the END marker is missing -- an unterminated
  # block leaves `skipping` true, which we detect and refuse below.
  local file="$1" out="$TMP/strip.out"
  awk -v heading="$GENERATED_HEADING" -v gi_heading="$GITIGNORE_HEADING" -v is_gitignore="$([ "$file" = .gitignore ] && printf 1 || printf 0)" '
    # Legacy comment markers (older onboard versions).
    /BEGIN GENERATED SECTION -- onboard/ { skipping = 1; seen_begin = 1; next }
    /END GENERATED SECTION -- onboard/   { skipping = 0; seen_end = 1; next }
    # Current contract: heading-delimited block. In markdown it runs to the next top-level
    # heading or EOF; in .gitignore it is the rule comment plus its contiguous rule lines.
    !is_gitignore && $0 == heading { in_block = 1; next }
    !is_gitignore && in_block && /^# / { in_block = 0 }
    is_gitignore && $0 == gi_heading { in_block = 1; next }
    is_gitignore && in_block && ($0 == "" || /^#/) { in_block = 0 }
    !skipping && !in_block { print }
    END { if (seen_begin && !seen_end) exit 3 }
  ' "$file" > "$out" || {
    printf '  !! %s has an opening marker with no closing marker; left untouched\n' "$file"
    return 0
  }
  # Trim blank lines at BOTH ends. Onboard separates its block from surrounding content with a
  # blank line, so removing the block otherwise strands one and the file no longer matches its
  # pre-onboard bytes -- `git status` then reports a modification that is pure whitespace.
  # Internal blank lines are preserved: only the leading and trailing runs are dropped.
  awk '
    { line[NR] = $0; if (NF) { if (!first) first = NR; last = NR } }
    END { for (i = first; i && i <= last; i++) print line[i] }
  ' "$out" > "$out.trimmed"
  if [ -s "$out.trimmed" ]; then
    cat "$out.trimmed" > "$file"
    printf '  stripped: %s\n' "$file"
  elif is_tracked "$file"; then
    # The whole file was the generated block AND git tracks it. This is the ordinary case for a
    # CLAUDE.md that onboard authored outright -- Launch Control's own is 100% inside the markers.
    # Deleting it would be removing a committed file, which correction 2 reserves for the user.
    # Truncating to empty would be just as much a repo change, so leave it exactly as it is.
    printf '  NOT removed -- entirely generated but tracked by git: %s\n' "$file"
    printf '     remove it yourself with: git rm %s\n' "$file"
  else
    rm -f "$file"
    printf '  removed (nothing remained outside the block): %s\n' "$file"
  fi
}

printf '\n'
if [ -s "$DELETE" ]; then
  while IFS= read -r rel; do
    rm -f "$rel"
    printf '  removed: %s\n' "$rel"
  done < "$DELETE"
fi
if [ -s "$STRIP" ]; then
  while IFS= read -r rel; do strip_generated_block "$rel"; done < "$STRIP"
fi
if [ -s "$CONTROL" ]; then
  rm -rf "$REPO_ROOT/.launch-control-onboard"
  for marker in "$GIT_DIR_ABS"/launch-control-onboard-* "$GIT_DIR_ABS"/groundwork-onboard-*; do
    [ -e "$marker" ] && rm -f "$marker"
  done
  # The visual report is the only file render-report.sh keeps under .git/launch-control/.
  rm -f "$REPORT"
  rmdir "$GIT_DIR_ABS/launch-control" 2>/dev/null || true
  printf '  removed: onboard control state\n'
fi

# Directory cleanup: rmdir ONLY. Non-recursive, fails on non-empty, deepest first -- so it can
# never take a file with it. This is the round-11 rule in code.
find .claude .codex artifacts .launch-control/refresh/receipts -depth -type d 2>/dev/null | while IFS= read -r dir; do
  rmdir "$dir" 2>/dev/null && printf '  removed empty dir: %s\n' "$dir"
done || true

printf '\nLaunch Control reset complete.\n'
[ -s "$KEEP_TRACKED" ] && printf 'Tracked files were left in place -- see the list above.\n'
exit 0
