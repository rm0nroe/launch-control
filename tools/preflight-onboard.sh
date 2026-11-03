#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"

# shellcheck source=launch-control-digests.sh
source "$ROOT/tools/launch-control-digests.sh"

if ! launch_control_load_user_owned "$CLAUDE_DIR" "$ROOT/skills" "$ROOT/agents"; then
  exit 2
fi

mismatches=()
check_item() {
  local source_item="$1" installed_item="$2" label="$3"
  local scope="${label%%/*}" name="${label#*/}"
  if launch_control_user_owned_has "$scope" "$name"; then
    if ! launch_control_items_equal "$source_item" "$installed_item"; then
      mismatches+=("intentional user-owned mismatch: $label")
    fi
    return
  fi
  if [ ! -e "$installed_item" ]; then
    mismatches+=("missing: $label")
  elif ! launch_control_items_equal "$source_item" "$installed_item"; then
    mismatches+=("differs: $label")
  fi
}

for source_item in "$ROOT"/skills/*; do
  [ -e "$source_item" ] || continue
  name="$(basename "$source_item")"
  check_item "$source_item" "$SKILLS_DST/$name" "skills/$name"
done

for source_item in "$ROOT"/agents/*; do
  [ -e "$source_item" ] || continue
  name="$(basename "$source_item")"
  check_item "$source_item" "$AGENTS_DST/$name" "agents/$name"
done

legacy_intake_name='problem-to''-research'
for legacy_path in "$SKILLS_DST/$legacy_intake_name" "$SKILLS_DST/$legacy_intake_name".bak-*; do
  if [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; then
    mismatches+=("legacy discovery entry: skills/$(basename "$legacy_path")")
  fi
done

refresh_command='./install.sh --force'

if [ "${#mismatches[@]}" -gt 0 ]; then
  printf '%s\n' 'Launch Control onboard preflight failed: installed/source parity differs.' >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  printf '\nRefresh the active Launch Control install:\n  %s\n' "$refresh_command" >&2
  if [ -n "${LAUNCH_CONTROL_USER_OWNED[*]-}" ]; then
    printf '%s\n' 'Declared user-managed mismatches are retained intentionally; source parity requires removing that declaration and authorizing replacement.' >&2
  fi
  printf '%s\n' 'Then fully restart Claude Code and rerun ./tools/preflight-onboard.sh.' >&2
  exit 1
fi

printf '%s\n' 'Launch Control onboard preflight passed: installed skills and agents match this checkout.'
printf '%s\n' 'Fully restart Claude Code, open an ordinary session in this checkout, and run plain /onboard.'
