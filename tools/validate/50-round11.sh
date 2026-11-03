# shellcheck shell=bash
# Round 11 — environment fidelity: unreadable baselines, generated boundaries, collapse.
# LC-037: the runner-spelling, environment-gap, sandbox-collision and npm-cache cases that used to
# live here tested what happened when onboarding EXECUTED a project's commands. Onboarding never
# runs them, so those cases are gone; the fixtures below are shared by the later parts.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
r11_fixture() {
  local repo="$1"
  mkdir -p "$repo/.claude" "$repo/checks"
  git -C "$repo" init -q -b validator
  git -C "$repo" config user.name validator
  git -C "$repo" config user.email validator@example.com
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/checks/validate-a.sh"
  chmod +x "$repo/checks/validate-a.sh"
  printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(./checks/gap-tool.sh)","Bash(pytest tests/unit/ -v)","Bash(uv run pytest tests/unit/ -v)","Bash(./.venv/bin/pytest tests/unit/ -v)"]}}' > "$repo/.claude/settings.json"
  printf '%s\n' 'shims/' '.venv/' > "$repo/.gitignore"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  mkdir -p "$repo/.launch-control-onboard"
  printf 'SKIPPED\t.mcp.json\n' > "$repo/.launch-control-onboard/ledger.tsv"
  : > "$repo/.launch-control-onboard/required-paths.txt"
  : > "$repo/.launch-control-onboard/baseline-paths.txt"
}
r11_render() {
  local repo="$1" dependencies="${2:-ready}"
  (cd "$repo" && PATH="$repo/shims:$PATH" \
    ONBOARD_REQUIRED_PATHS_FILE="$repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
    valid absent "$dependencies" .launch-control-onboard/validation-commands.txt none complete)
}

# The lens guard names the offending bullet instead of only the file.
printf '%s\n' \
  '## Project-specific review lens' \
  '- Review shell quoting. Evidence: `install.sh`, `tools/validate-pack.sh`.' \
  '- Review generated frontmatter. Evidence: `skills/onboard/SKILL.md`.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
reset_run_anchor "$reviewer_repo"
if (cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null 2>"$installer_tmp/r11-lens.err"; then
  printf '%s\n' 'FAIL: renderer accepted a reviewer lens bullet with multiple evidence paths' >&2
  exit 1
fi
run_rg -q 'offending bullet: "- Review shell quoting' "$installer_tmp/r11-lens.err"

# A /fix command that cannot run any fix command must be SKIPPED, never created.
r11_fix_repo="$installer_tmp/r11-fix-repo"
r11_fixture "$r11_fix_repo"
mkdir -p "$r11_fix_repo/.claude/commands"
printf '%s\n' '---' 'description: No auto-fix command declared for this repo' \
  'allowed-tools: Read, Grep, Glob' '---' '' '$ARGUMENTS' '' 'Nothing to auto-fix.' \
  > "$r11_fix_repo/.claude/commands/fix.md"
printf 'CREATED\t.claude/commands/fix.md\n' > "$r11_fix_repo/.launch-control-onboard/ledger.tsv"
printf '%s\n' './checks/validate-a.sh' > "$r11_fix_repo/.launch-control-onboard/validation-commands.txt"
if r11_render "$r11_fix_repo" ready > /dev/null 2> "$installer_tmp/r11-fix.err"; then
  printf '%s\n' 'FAIL: renderer accepted a generated /fix command that cannot run a fix command' >&2
  exit 1
fi
run_rg -q 'must be SKIPPED instead of created: \.claude/commands/fix\.md' "$installer_tmp/r11-fix.err"

# Discovery policy: the bounded sweep is safer than the unbounded one it already allowed.
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"find . -maxdepth 1 -type f",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"allow"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"find . -maxdepth 2 -type d",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"allow"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"find . -type d",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"allow"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"find . -maxdepth 1 -name CLAUDE.md",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"deny"' "$policy_output"

# The secret boundary onboarding generates takes effect the moment settings.json is written,
# and from then on the renderer cannot read the paths it just protected. A tracked, dirty
# `.env` hashed clean before that write and unreadable after it, which the PRESERVED
# comparison read as "content changed" and blocked a complete run. Unreadable is not changed:
# the path is disclosed as content-unverified and the run completes.
r11_protected_repo="$installer_tmp/r11-protected-repo"
mkdir -p "$r11_protected_repo/.claude" "$r11_protected_repo/checks" "$r11_protected_repo/.launch-control-onboard"
git -C "$r11_protected_repo" init -q -b validator
git -C "$r11_protected_repo" config user.name validator
git -C "$r11_protected_repo" config user.email validator@example.com
mkdir -p "$r11_protected_repo/conf"
printf 'SECRET=1\n' > "$r11_protected_repo/conf/.env"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r11_protected_repo/checks/validate-a.sh"
chmod +x "$r11_protected_repo/checks/validate-a.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' > "$r11_protected_repo/.claude/settings.json"
git -C "$r11_protected_repo" add -A
git -C "$r11_protected_repo" commit -qm baseline
printf 'SECRET=2\n' > "$r11_protected_repo/conf/.env"
printf 'PRESERVED\tconf/.env\n' > "$r11_protected_repo/.launch-control-onboard/ledger.tsv"
: > "$r11_protected_repo/.launch-control-onboard/required-paths.txt"
printf 'conf/.env\n' > "$r11_protected_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './checks/validate-a.sh' > "$r11_protected_repo/.launch-control-onboard/validation-commands.txt"
r11_protected_render() {
  (cd "$r11_protected_repo" && \
    ONBOARD_REQUIRED_PATHS_FILE="$r11_protected_repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$r11_protected_repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
    valid absent ready .launch-control-onboard/validation-commands.txt none complete)
}
# Readable: byte-identical to pre-round-11 behaviour, no disclosure section.
r11_protected_render > "$installer_tmp/r11-readable.out"
if run_rg -q 'Protected, content unverified' "$installer_tmp/r11-readable.out"; then
  printf '%s\n' 'FAIL: readable dirty baseline path was reported as content-unverified' >&2
  exit 1
fi
# Unreadable: completes, discloses, and never claims the content was compared. The
# preserve-hashes file stands in for the capture the lifecycle guard makes in a hooked run,
# which is the route that content-verifies a baseline path.
printf '%s  %s\n' "$(shasum -a 256 "$r11_protected_repo/conf/.env" | awk '{print $1}')" 'conf/.env' \
  > "$r11_protected_repo/.launch-control-onboard/preserve-hashes.txt"
chmod 000 "$r11_protected_repo/conf"
reset_run_anchor "$r11_protected_repo"
r11_protected_status=0
r11_protected_render > "$installer_tmp/r11-protected.out" 2> "$installer_tmp/r11-protected.err" || r11_protected_status=$?
chmod 755 "$r11_protected_repo/conf"
if [ "$r11_protected_status" -ne 0 ]; then
  printf '%s\n' 'FAIL: an unreadable protected baseline path blocked the render' >&2
  cat "$installer_tmp/r11-protected.err" >&2
  exit 1
fi
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r11-protected.out"
run_rg -q '^Protected, content unverified \(1\):$' "$installer_tmp/r11-protected.out"
run_rg -q '^  conf/\.env$' "$installer_tmp/r11-protected.out"
run_rg -q 'their content was never read or compared' "$installer_tmp/r11-protected.out"

# A bare `credentials*` deny also matched ordinary source such as `api/routers/credentials.py`,
# which blocked the renderer's own verification reads and left the user's source unreadable in
# every later session. Credential DATA stays protected; source stays readable.
for r11_secret_path in credentials .credentials_key credentials.json credentials-prod.yaml credentials.pem secrets/token.txt; do
  jq -n --arg cwd "$policy_repo" --arg p "$r11_secret_path" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Read",tool_input:{file_path:($cwd+"/"+$p)}}' | run_policy > "$policy_output"
  run_rg -q 'protected project secret paths' "$policy_output" || {
    printf 'FAIL: policy stopped protecting credential data: %s\n' "$r11_secret_path" >&2
    exit 1
  }
done
for r11_source_path in api/routers/credentials.py credentials.ts credentials.go credentials.md; do
  jq -n --arg cwd "$policy_repo" --arg p "$r11_source_path" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Read",tool_input:{file_path:($cwd+"/"+$p)}}' | run_policy > "$policy_output"
  if run_rg -q 'protected project secret paths' "$policy_output"; then
    printf 'FAIL: policy denied a source file as a credential store: %s\n' "$r11_source_path" >&2
    exit 1
  fi
done
# The over-broad pattern must not come back anywhere the generated config is specified.
for r11_glob_source in "$ROOT/skills/onboard/references/configuration-generation.md" "$ROOT/skills/onboard/references/hooks-and-config.md"; do
  if run_rg -q -- '\*\*/credentials\*\)' "$r11_glob_source"; then
    printf 'FAIL: over-broad bare credentials* deny glob is back in %s\n' "$r11_glob_source" >&2
    exit 1
  fi
done

# An untracked dependency directory puts tens of thousands of pre-existing paths in the
# baseline. They stay captured and verified; the report collapses them by top-level directory
# so it remains readable, because a run that cannot print a scannable report reached instead
# for asking the user to gitignore the directory — refusing an ordinary repository state.
r11_big_repo="$installer_tmp/r11-big-repo"
mkdir -p "$r11_big_repo/.claude" "$r11_big_repo/checks" "$r11_big_repo/.venv/lib" "$r11_big_repo/.launch-control-onboard"
git -C "$r11_big_repo" init -q -b validator
git -C "$r11_big_repo" config user.name validator
git -C "$r11_big_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r11_big_repo/checks/validate-a.sh"
chmod +x "$r11_big_repo/checks/validate-a.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' > "$r11_big_repo/.claude/settings.json"
printf 'seed\n' > "$r11_big_repo/seed.txt"
git -C "$r11_big_repo" add seed.txt
git -C "$r11_big_repo" commit -qm baseline
r11_big_index=0
while [ "$r11_big_index" -lt 120 ]; do
  r11_big_index=$((r11_big_index + 1))
  printf 'x\n' > "$r11_big_repo/.venv/lib/mod$r11_big_index.py"
done
printf 'loose\n' > "$r11_big_repo/notes.txt"
printf 'SKIPPED\t.mcp.json\n' > "$r11_big_repo/.launch-control-onboard/ledger.tsv"
: > "$r11_big_repo/.launch-control-onboard/required-paths.txt"
git -C "$r11_big_repo" status --short --untracked-files=all -- . ':(exclude).launch-control-onboard/**' \
  | awk '{print $2}' | grep -v '^\.claude/settings\.json$' > "$r11_big_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './checks/validate-a.sh' > "$r11_big_repo/.launch-control-onboard/validation-commands.txt"
(cd "$r11_big_repo" && ONBOARD_REQUIRED_PATHS_FILE="$r11_big_repo/.launch-control-onboard/required-paths.txt" \
  ONBOARD_BASELINE_PATHS_FILE="$r11_big_repo/.launch-control-onboard/baseline-paths.txt" \
  "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
  valid absent ready .launch-control-onboard/validation-commands.txt none complete) > "$installer_tmp/r11-big.out"
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r11-big.out"
run_rg -q '^Untouched pre-existing \(12[0-9]\):$' "$installer_tmp/r11-big.out"
run_rg -q '^  \.venv/ \(120 paths\)$' "$installer_tmp/r11-big.out"
run_rg -q '^  notes\.txt$' "$installer_tmp/r11-big.out"
run_rg -q 'every path above was captured and verified' "$installer_tmp/r11-big.out"
# The collapse must not swallow the listing for an ordinary workspace.
if [ "$(awk 'END { print NR }' "$installer_tmp/r11-big.out")" -gt 60 ]; then
  printf '%s\n' 'FAIL: large baseline still printed one line per path' >&2
  exit 1
fi
if run_rg -q 'Collapsed by top-level directory' "$installer_tmp/r11-readable.out"; then
  printf '%s\n' 'FAIL: a small baseline was collapsed instead of listed' >&2
  exit 1
fi
