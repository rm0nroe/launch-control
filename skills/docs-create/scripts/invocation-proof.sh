#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')"
[ "$event" = PreToolUse ] || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
case "$tool" in Edit|Write) ;; *) exit 0 ;; esac

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$cwd" ] && [ -n "$session_id" ] && [ -n "$file_path" ] || exit 0
[[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

cwd="$(cd "$cwd" && pwd -P)"
case "$file_path" in
  "$cwd/artifacts/architecture.md") relative='artifacts/architecture.md' ;;
  "$cwd/artifacts/infrastructure.md") relative='artifacts/infrastructure.md' ;;
  *) exit 0 ;;
esac

git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
proof="$git_dir/launch-control-bootstrap-docs-$session_id.proof"
if [ ! -f "$proof" ] || ! grep -Fqx -- "$relative" "$proof"; then
  printf '%s\n' "$relative" >> "$proof"
fi
