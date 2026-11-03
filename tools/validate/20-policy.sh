# shellcheck shell=bash
# Unattended policy: read/bash confinement, bypassPermissions behavior.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
validator_workspace_tmp="$ROOT/.launch-control-onboard"
validator_workspace_created=false
if [ ! -d "$validator_workspace_tmp" ]; then
  mkdir -p "$validator_workspace_tmp"
  validator_workspace_created=true
fi
installer_tmp="$(mktemp -d "$ROOT/.launch-control-onboard/validate.XXXXXX")"
# Fixtures live inside this checkout: stop git's upward search so a non-git fixture never
# resolves to this repository's .git and reads a live session's run markers.
export GIT_CEILING_DIRECTORIES="$ROOT/.launch-control-onboard"
cleanup_validator_tmp() {
  rm -rf "$installer_tmp"
  if [ "$validator_workspace_created" = true ]; then
    rmdir "$validator_workspace_tmp" 2>/dev/null || true
  fi
}
trap cleanup_validator_tmp EXIT

# The abort diagnostic in lib.sh is the reason this suite is split across files:
# a failing assertion used to surface as a bare `exit 1`, costing a
# `PS4='+${LINENO}: ' bash -x` bisect every time. Pin both halves of it. The
# unguarded case must name the probe's own file and line, and it goes through
# `run_rg` specifically -- rg is often absent from PATH, in which case run_rg
# falls back to a subshell whose failure reaches the trap only because both
# branches funnel through one `return`.
trap_probe="$installer_tmp/trap-probe.sh"
printf '%s\n' \
  'set -euo pipefail' \
  ". \"$ROOT/tools/validate/lib.sh\"" \
  'run_rg -q LAUNCH_CONTROL_TRAP_PROBE_NO_MATCH "$ROOT/README.md"' > "$trap_probe"
trap_probe_output="$(bash "$trap_probe" 2>&1 || true)"
case "$trap_probe_output" in
  *"FAIL: validator aborted (exit 1) at $trap_probe:3"*) ;;
  *)
    printf 'FAIL: an unguarded assertion aborted without naming its file and line: %s\n' \
      "$trap_probe_output" >&2
    exit 1
    ;;
esac

# The other half: a GUARDED assertion is the passing path and must stay silent.
# check_absent runs its search in a command substitution, where errexit's
# condition exemption does not reach, so a naive ERR trap printed an abort
# notice for every no-match check -- thirteen false alarms on a green run.
printf '%s\n' \
  'set -euo pipefail' \
  ". \"$ROOT/tools/validate/lib.sh\"" \
  'check_absent LAUNCH_CONTROL_TRAP_PROBE_NO_MATCH "$ROOT/README.md"' \
  'if run_rg -q LAUNCH_CONTROL_TRAP_PROBE_NO_MATCH "$ROOT/README.md"; then :; fi' \
  'if probe_out="$(run_rg -n LAUNCH_CONTROL_TRAP_PROBE_NO_MATCH "$ROOT/README.md")"; then :; fi' \
  'printf %s\\n probe-completed' > "$trap_probe"
trap_probe_output="$(bash "$trap_probe" 2>&1)"
if [ "$trap_probe_output" != 'probe-completed' ]; then
  printf 'FAIL: a guarded assertion produced output on its passing path: %s\n' \
    "$trap_probe_output" >&2
  exit 1
fi

policy="$ROOT/skills/onboard/scripts/unattended-policy.sh"
policy_repo="$installer_tmp/policy-repo"
policy_config="$installer_tmp/claude-config"
mkdir -p "$policy_repo/.claude" "$policy_repo/.launch-control-onboard" \
  "$policy_config/skills/onboard/references" "$policy_config/skills/onboard/scripts"
git -C "$policy_repo" init -q -b policy-test
printf '%s\n' '{"permissions":{"allow":["Bash(npm test)","Bash(pytest tests/*.py)"]}}' > "$policy_repo/.claude/settings.json"
printf '%s\n' '{"permissions":{"allow":[]}}' > "$policy_repo/.claude/settings.local.json"
printf '%s\n' '# Installed reference' > "$policy_config/skills/onboard/references/hooks-and-config.md"
printf '%s\n' '# Installed skill' > "$policy_config/skills/onboard/SKILL.md"
printf '%s\n' 'not markdown' > "$policy_config/skills/onboard/references/not-markdown.txt"
ln -s "$installer_tmp" "$policy_config/skills/onboard/references/escape.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$policy_config/skills/onboard/scripts/render-report.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$policy_config/skills/onboard/scripts/discovery-checkpoint.sh"
chmod +x "$policy_config/skills/onboard/scripts/render-report.sh" \
  "$policy_config/skills/onboard/scripts/discovery-checkpoint.sh"
policy_ledger="$policy_repo/.launch-control-onboard/ledger.tsv"
policy_required="$policy_repo/.launch-control-onboard/required-paths.txt"
policy_baseline="$policy_repo/.launch-control-onboard/baseline-paths.txt"
policy_validation="$policy_repo/.launch-control-onboard/validation-commands.txt"
: > "$policy_ledger"
: > "$policy_required"
: > "$policy_baseline"
printf '%s\n' 'npm test' > "$policy_validation"
run_policy() {
  CLAUDE_CONFIG_DIR="$policy_config" "$policy"
}
policy_settings_before="$(shasum -a 256 "$policy_repo/.claude/settings.local.json")"
policy_output="$installer_tmp/policy-output.json"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:($cwd+"/CLAUDE.md")}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"allow"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:($cwd+"/README.md")}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"deny"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Read",tool_input:{file_path:($cwd+"/.env")}}' | run_policy > "$policy_output"
run_rg -q 'protected project secret paths' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"./tools/validate-pack.sh",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"ask"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git reset --hard",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"deny"' "$policy_output"
# LC-037: onboarding never runs a project's own commands, so no validation command is auto-allowed,
# whether or not the caller disabled the sandbox: a project command reaches the normal prompt like
# anything else outside the allowlist. The first assertion of this group was `allow` before.
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"./tools/validate-pack.sh",dangerouslyDisableSandbox:true}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"ask"' "$policy_output"
# The rest of the boundary is unchanged: a mutating git command stays denied even with the flag set.
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git reset --hard",dangerouslyDisableSandbox:true}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"deny"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"npm test",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"ask"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"pytest tests/*.py",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"ask"' "$policy_output"
# Round-19: THIS is the ask path's coverage of record. No `permission_mode` is sent, so the
# policy answers as it would in the default mode, and an undeclared repo-local script is the
# shape that reaches the gate. Under `bypassPermissions` the policy converts `ask` into a hard
# deny and under `auto` a classifier answers instead of a human, so only a default-mode session
# can exercise it.
# Round-22 correction: default mode is no longer declined -- an acceptance pair ran under it and
# the policy emitted `allow` 63 and 60 times with `"permissionDecision":"ask"` appearing zero
# times in either transcript. The mode was never what blocked the path; the SHAPE is. Neither
# run invoked an undeclared repo-local script, and no ordinary onboarding turn has reason to.
# Treat this assertion as the coverage of record until a live run is observed emitting `ask`.
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"./tools/not-declared.sh",dangerouslyDisableSandbox:false}}' | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"ask"' "$policy_output"
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PermissionRequest",cwd:$cwd,tool_name:"Write",tool_input:{file_path:($cwd+"/CLAUDE.md")}}' | run_policy > "$policy_output"
run_rg -q '"behavior":"allow"' "$policy_output"
test "$(shasum -a 256 "$policy_repo/.claude/settings.local.json")" = "$policy_settings_before"

# Normal external repositories may read only canonical installed onboard Markdown
# references. Siblings, traversal, non-Markdown files, and symlink escapes stay denied.
policy_read_decision() {
  jq -n --arg cwd "$policy_repo" --arg path "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Read",tool_input:{file_path:$path}}' \
    | run_policy | jq -r '.hookSpecificOutput.permissionDecision // "ask"'
}
installed_reference="$policy_config/skills/onboard/references/hooks-and-config.md"
if [ "$(policy_read_decision "$installed_reference")" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow a canonical installed onboard reference' >&2
  exit 1
fi
for denied_reference in \
  "$policy_config/skills/onboard/SKILL.md" \
  "$policy_config/skills/onboard/references/../SKILL.md" \
  "$policy_config/skills/onboard/references/not-markdown.txt" \
  "$policy_config/skills/onboard/references/escape.md" \
  "$policy_config/arbitrary.md"; do
  if [ "$(policy_read_decision "$denied_reference")" != deny ]; then
    printf 'FAIL: policy did not deny non-canonical installed reference: %s\n' "$denied_reference" >&2
    exit 1
  fi
done

# Native repository reads deny every arbitrary root or nested .env* variant while the
# four exact documentation/example basenames remain available to the onboard hook.
for denied_env_path in \
  "$policy_repo/.env.qa" \
  "$policy_repo/.env.preview" \
  "$policy_repo/.env.backup" \
  "$policy_repo/nested/.env.qa" \
  "$policy_repo/nested/.env.preview" \
  "$policy_repo/nested/.env.backup" \
  "$policy_repo/.env.example.local"; do
  if [ "$(policy_read_decision "$denied_env_path")" != deny ]; then
    printf 'FAIL: policy did not deny native protected env read: %s\n' "$denied_env_path" >&2
    exit 1
  fi
done
for safe_env_path in \
  "$policy_repo/.env.example" \
  "$policy_repo/.env.sample" \
  "$policy_repo/.env.template" \
  "$policy_repo/.env.local.example" \
  "$policy_repo/nested/.env.example" \
  "$policy_repo/nested/.env.sample" \
  "$policy_repo/nested/.env.template" \
  "$policy_repo/nested/.env.local.example"; do
  if [ "$(policy_read_decision "$safe_env_path")" != allow ]; then
    printf 'FAIL: policy did not allow exact native safe-example read: %s\n' "$safe_env_path" >&2
    exit 1
  fi
done

# Bash discovery commands must confine every path argument to the repository and reject
# protected secrets; a prefix match on cat/ls/head/tail/wc/rg is not standalone authority.
policy_bash_decision() {
  jq -n --arg cwd "$policy_repo" --arg cmd "$1" --arg pm "${2:-}" --arg sid "${3:-}" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$sid,permission_mode:$pm,tool_name:"Bash",tool_input:{command:$cmd,dangerouslyDisableSandbox:false}}' \
    | run_policy | jq -r '.hookSpecificOutput.permissionDecision // "ask"'
}
printf '%s\n' x > "$policy_repo/README.md"
mkdir -p "$policy_repo/src" "$policy_repo/app"
printf '%s\n' 'const font = "Archivo";' > "$policy_repo/app/layout.tsx"
ln -s "$installer_tmp" "$policy_repo/escape"
ln -s /etc/passwd "$policy_repo/innocent-link"
ln -s .env "$policy_repo/env-link"
for denied_command in \
  'cat /etc/passwd' 'cat ../outside.txt' 'cat .env' 'ls "$HOME/.claude"' \
  'rg pattern /Users/example' 'head /absolute/path' 'tail ../../outside' \
  'wc /tmp/file' 'cat escape/passwd' \
  'cat *' 'cat .env*' 'ls *' 'cat sub/*' 'cat .env.*' \
  'cat .env.qa' 'head .env.preview' 'tail .env.backup' \
  'cat nested/.env.qa' 'rg token nested/.env.preview' 'grep token nested/.env.backup' \
  'cat .env.example.local' \
  'cat \.env' 'cat "sub/.env"' 'cat ./.env' \
  'rg -f .env x' 'rg --file .env x' 'cat -- .env' 'wc ~/.ssh/id_rsa' \
  'rg --file=.env x' 'rg -f=.env x' 'rg -f.env x' \
  'grep -rf.env src' 'grep -rnf.env src' 'grep -rf .env src' \
  'grep -rnf .env src' 'grep -Hf.env src' 'grep -irf.env src' \
  'grep -rf=.env src' 'grep -rnf=.env src' 'grep -Hf=.env src' 'grep -irf=.env src'; do
  if [ "$(policy_bash_decision "$denied_command")" != deny ]; then
    printf 'FAIL: policy did not deny out-of-repository or protected Bash discovery: %s\n' "$denied_command" >&2
    exit 1
  fi
done
for allowed_command in 'cat README.md' 'ls src' 'rg pattern' 'head README.md' \
  'cat -n README.md' 'rg -n pattern src' 'cat -- README.md' \
  'cat .env.example' 'head .env.sample' 'tail nested/.env.template' \
  'cat .env.local.example' 'head nested/.env.local.example' \
  "grep -Eic 'alpha|beta' README.md" 'grep -Eic "alpha|beta" README.md' \
  'grep -n "next/font\|Archivo\|Hanken\|JetBrains\|Geist" app/layout.tsx' \
  'rg credentials' 'grep -rn credentials .' 'rg .env' 'grep -rn .env src' \
  'grep -rn foo src' 'rg pattern .' \
  'rg -fpatterns.txt x' 'grep -rf patterns.txt src' \
  'find . -type f' 'find src -maxdepth 2 -type f' \
  'git remote get-url origin' 'jq -e . .claude/settings.json' \
  'jq empty .claude/settings.json'; do
  if [ "$(policy_bash_decision "$allowed_command")" != allow ]; then
    printf 'FAIL: policy did not allow repo-local Bash discovery: %s\n' "$allowed_command" >&2
    exit 1
  fi
done
if [ "$(policy_bash_decision 'shasum -a 256 README.md .claude/settings.json')" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow explicit repo-local SHA-256 evidence reads' >&2
  exit 1
fi
for denied_shasum in \
  'shasum -a 256 .env' \
  'shasum -a 256 /etc/passwd' \
  'shasum README.md' \
  'shasum -a 256 innocent-link' \
  'shasum -a 256 env-link'; do
  if [ "$(policy_bash_decision "$denied_shasum")" = allow ]; then
    printf 'FAIL: policy over-allowed unsafe or malformed shasum command: %s\n' "$denied_shasum" >&2
    exit 1
  fi
done
# F20: `git check-ignore` is a pure read, but only the single literal `-q
# .launch-control-onboard/` was allowed, so the shape a run really issues -- several
# repo-local control paths under `-v` -- was denied. The validated form keeps that
# literal working while accepting the read-only reporting flags; every operand still
# goes through the repository/secret guard.
for allowed_ignore in \
  'git check-ignore -q .launch-control-onboard/' \
  'git check-ignore .launch-control-onboard/' \
  'git check-ignore -v .claude/settings.local.json .claude/x.local.md CLAUDE.local.md .launch-control-onboard/ledger.tsv' \
  'git check-ignore --verbose --non-matching README.md' \
  'git check-ignore -n -v -- README.md' \
  'git check-ignore --no-index -v ./README.md'; do
  if [ "$(policy_bash_decision "$allowed_ignore")" != allow ]; then
    printf 'FAIL: policy did not allow a read-only git check-ignore report: %s\n' "$allowed_ignore" >&2
    exit 1
  fi
done
if [ "$(policy_bash_decision "git -C $policy_repo check-ignore -v .claude/settings.local.json .launch-control-onboard/ledger.tsv")" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow git check-ignore in its -C spelling' >&2
  exit 1
fi
for denied_ignore in 'git check-ignore -q .env' 'git check-ignore -v .env' \
  'git check-ignore -q ../outside' 'git check-ignore -v ../outside' \
  'git check-ignore -v /etc/passwd' 'git check-ignore -v nested/.env.qa' \
  'git check-ignore --stdin' 'git check-ignore --exec-path=/tmp/x -v README.md' \
  'git check-ignore' 'git check-ignore -v'; do
  if [ "$(policy_bash_decision "$denied_ignore")" != deny ]; then
    printf 'FAIL: policy over-allowed git check-ignore variant: %s\n' "$denied_ignore" >&2
    exit 1
  fi
done

# F21: a run asked for its branch as `git rev-parse --abbrev-ref HEAD`, which the
# allowlist carried only in its `git branch --show-current` spelling, and ate a denial.
# Exactly five fixed, argument-free reads are named -- a `git rev-parse *` wildcard would
# also cover revisions, pathspecs, and the option-parsing subcommands -- so any other
# rev-parse form must still fall through to review.
for allowed_rev_parse in 'git rev-parse --abbrev-ref HEAD' 'git rev-parse --show-toplevel' \
  'git rev-parse --git-dir' 'git rev-parse --absolute-git-dir' 'git rev-parse HEAD'; do
  if [ "$(policy_bash_decision "$allowed_rev_parse")" != allow ]; then
    printf 'FAIL: policy did not allow an exact read-only rev-parse: %s\n' "$allowed_rev_parse" >&2
    exit 1
  fi
  if [ "$(policy_bash_decision "git -C $policy_repo ${allowed_rev_parse#git }")" != allow ]; then
    printf 'FAIL: an exact read-only rev-parse did not allow in its -C spelling: %s\n' "$allowed_rev_parse" >&2
    exit 1
  fi
done
for unlisted_rev_parse in 'git rev-parse --verify some/ref' 'git rev-parse --parseopt' \
  'git rev-parse --sq-quote x' 'git rev-parse HEAD~1' 'git rev-parse'; do
  if [ "$(policy_bash_decision "$unlisted_rev_parse")" = allow ]; then
    printf 'FAIL: policy allowed a rev-parse form outside the exact allowlist: %s\n' "$unlisted_rev_parse" >&2
    exit 1
  fi
  if [ "$(policy_bash_decision "$unlisted_rev_parse" bypassPermissions)" != deny ]; then
    printf 'FAIL: an unlisted rev-parse form was not hard-denied under bypass: %s\n' "$unlisted_rev_parse" >&2
    exit 1
  fi
done

# SKILL.md: "Do not list, traverse, or `find` the installed onboard skill directory, and
# invoke only the canonical installed renderer without reading or enumerating its script."
# The policy enforces that only as a side effect of the repo-confinement guard, so a later
# widening of that guard could silently reopen it. Pin the boundary directly: a run must
# resolve installed references from their known `@references/*.md` paths, never by
# enumerating the directory its scripts live in.
policy_scripts_dir="$(cd "$policy_config/skills/onboard/scripts" && pwd -P)"
if [ "$(policy_bash_decision "ls -l $policy_scripts_dir")" != deny ]; then
  printf '%s\n' 'FAIL: policy allowed enumerating the installed onboard skill scripts directory' >&2
  exit 1
fi
policy_discovery_checkpoint="$policy_config/skills/onboard/scripts/discovery-checkpoint.sh"
if [ "$(policy_bash_decision "$policy_discovery_checkpoint")" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow the canonical discovery checkpoint' >&2
  exit 1
fi
if [ "$(policy_bash_decision "$policy_discovery_checkpoint extra")" != deny ]; then
  printf '%s\n' 'FAIL: policy allowed discovery checkpoint arguments' >&2
  exit 1
fi
# F25. SKILL.md's project-runner rule turns on whether `./.venv/bin/<tool>` is executable,
# and an acceptance run established that by executing the tool (`./.venv/bin/pytest
# --version`) and ate a bypass denial. The denial is correct -- running a validation tool
# outside the renderer is exactly what the sandboxed-validation section forbids -- so pin
# both halves: the execution stays denied, and the `ls -l` probe SKILL.md now names stays
# allowed, so nothing pushes a run back toward executing the tool to learn the same fact.
mkdir -p "$policy_repo/.venv/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$policy_repo/.venv/bin/pytest"
chmod +x "$policy_repo/.venv/bin/pytest"
for denied_venv_exec in './.venv/bin/pytest --version' './.venv/bin/pytest' \
  '.venv/bin/pytest --version'; do
  if [ "$(policy_bash_decision "$denied_venv_exec" bypassPermissions policy-venv-probe)" != deny ]; then
    printf 'FAIL: policy did not deny executing a venv validation tool during discovery: %s\n' \
      "$denied_venv_exec" >&2
    exit 1
  fi
done
for allowed_venv_probe in 'ls -l ./.venv/bin/pytest' 'ls -l .venv/bin/pytest'; do
  if [ "$(policy_bash_decision "$allowed_venv_probe")" != allow ]; then
    printf 'FAIL: policy did not allow the read-only venv interpreter probe: %s\n' \
      "$allowed_venv_probe" >&2
    exit 1
  fi
done

# F28, second pass. The renderer cannot see the session's permission mode, so the policy
# records it: any PreToolUse under bypassPermissions drops a .bypass marker that the
# renderer turns into the report's `permission-mode:` line. Pin both directions -- a
# bypassed session must leave the marker on an ordinary ALLOWED call (not only on a
# denial, which is the assumption that let a clean bypassed run disclose nothing), and a
# default-mode session must never leave one, or every report would claim to be unreviewed.
policy_bypass_git_dir="$(git -C "$policy_repo" rev-parse --absolute-git-dir)"
rm -f "$policy_bypass_git_dir"/launch-control-onboard-run-*.bypass
if [ "$(policy_bash_decision 'git status' bypassPermissions policy-bypass-marker)" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow an ordinary discovery command under bypass' >&2
  exit 1
fi
if [ ! -f "$policy_bypass_git_dir/launch-control-onboard-run-policy-bypass-marker.bypass" ]; then
  printf '%s\n' 'FAIL: policy did not record bypassPermissions on an allowed call, so the report cannot derive permission-mode' >&2
  exit 1
fi
if [ "$(policy_bash_decision 'git status' default policy-default-marker)" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow an ordinary discovery command in default mode' >&2
  exit 1
fi
if [ -f "$policy_bypass_git_dir/launch-control-onboard-run-policy-default-marker.bypass" ]; then
  printf '%s\n' 'FAIL: policy recorded a bypass marker for a default-mode session' >&2
  exit 1
fi

# Round-18: the two checks above answer only "was this bypass", which is why an `auto` run --
# where a classifier answers the ask-gates -- reported exactly like a reviewed default one.
# The policy now records the mode itself on an ordinary allowed call, for EVERY mode, and
# refuses to record a value that could not safely reach report text.
rm -f "$policy_bypass_git_dir"/launch-control-onboard-run-*.permission-mode
for policy_mode in auto default acceptEdits; do
  if [ "$(policy_bash_decision 'git status' "$policy_mode" "policy-mode-$policy_mode")" != allow ]; then
    printf 'FAIL: policy did not allow an ordinary discovery command in %s mode\n' "$policy_mode" >&2
    exit 1
  fi
  policy_mode_marker="$policy_bypass_git_dir/launch-control-onboard-run-policy-mode-$policy_mode.permission-mode"
  if [ ! -f "$policy_mode_marker" ]; then
    printf 'FAIL: policy did not record permission mode %s, so the report cannot name it\n' "$policy_mode" >&2
    exit 1
  fi
  if [ "$(cat "$policy_mode_marker")" != "$policy_mode" ]; then
    printf 'FAIL: policy recorded the wrong permission mode for %s: %s\n' \
      "$policy_mode" "$(cat "$policy_mode_marker")" >&2
    exit 1
  fi
done
if [ "$(policy_bash_decision 'git status' 'auto; rm -rf /' policy-mode-injection)" != allow ]; then
  printf '%s\n' 'FAIL: policy did not allow an ordinary discovery command with an unparseable mode' >&2
  exit 1
fi
if [ -f "$policy_bypass_git_dir/launch-control-onboard-run-policy-mode-injection.permission-mode" ]; then
  printf '%s\n' 'FAIL: policy recorded a permission mode that fails the charset check' >&2
  exit 1
fi
rm -f "$policy_bypass_git_dir"/launch-control-onboard-run-*.bypass

# F29. Both round-14 acceptance runs issued the Phase 5 settings audit as an absolute path
# and ate a denial, because the allowlist carried only the repo-relative literal. One run
# reissued it repo-relative; the other dropped the audit and claimed the renderer's own
# settings parse covered it -- a denial silently converting into a skipped audit. Pin both
# halves: the two spellings that resolve to the generated file stay allowed, and a path
# outside the repository stays denied, so widening this never becomes an arbitrary jq read.
mkdir -p "$policy_repo/.claude"
printf '%s\n' '{}' > "$policy_repo/.claude/settings.json"
for allowed_settings_audit in \
  'jq -e . .claude/settings.json' 'jq empty .claude/settings.json' \
  "jq -e . $policy_repo/.claude/settings.json" "jq empty $policy_repo/.claude/settings.json"; do
  if [ "$(policy_bash_decision "$allowed_settings_audit" bypassPermissions policy-settings-audit)" != allow ]; then
    printf 'FAIL: policy did not allow the read-only generated settings audit: %s\n' \
      "$allowed_settings_audit" >&2
    exit 1
  fi
done
for denied_settings_audit in \
  'jq -e . /etc/passwd' 'jq empty ../outside/.claude/settings.json' \
  "jq -e . $installer_tmp/.claude/settings.json" 'jq -e . ~/.claude/settings.json' \
  'jq -r .permissions .claude/settings.json' 'jq -e . .env'; do
  if [ "$(policy_bash_decision "$denied_settings_audit" bypassPermissions policy-settings-audit)" = allow ]; then
    printf 'FAIL: policy allowed a jq read beyond the generated settings audit: %s\n' \
      "$denied_settings_audit" >&2
    exit 1
  fi
done

for denied_find in \
  'find /Users/example -type f' 'find ../outside -type f' 'find . -type f -delete' \
  'find . -exec cat {} ;' 'find . -print' 'find . -name "*.md" -type f' \
  'find . -maxdepth nope -type f' 'find . -type f -maxdepth 2' 'find . -maxdepth 3 -type l' \
  'find "$HOME/.claude/skills/onboard" -type f'; do
  if [ "$(policy_bash_decision "$denied_find")" != deny ]; then
    printf 'FAIL: policy did not deny external or unsupported find discovery: %s\n' "$denied_find" >&2
    exit 1
  fi
done
# Shell composition — including a bare background `&` that chains a second command past a
# valid discovery prefix — must be denied before any path check runs.
for composed_command in \
  'cat README.md & env' 'cat README.md && env' 'cat README.md | env' \
  'cat README.md; env' 'cat $(echo .env)' 'ls > /tmp/x' 'cat README.md `id`' \
  'grep -Eic alpha|beta README.md' 'grep alpha < README.md'; do
  if [ "$(policy_bash_decision "$composed_command")" != deny ]; then
    printf 'FAIL: policy did not deny shell-composed Bash command: %s\n' "$composed_command" >&2
    exit 1
  fi
done
# Only the canonical installed renderer with the complete finalizer argument shape stays
# allowed outside the repository. A fake suffix match or malformed canonical call is denied.
policy_renderer="$policy_config/skills/onboard/scripts/render-report.sh"
renderer_command="ONBOARD_REQUIRED_PATHS_FILE=$policy_required ONBOARD_BASELINE_PATHS_FILE=$policy_baseline $policy_renderer $policy_ledger policy-test valid absent ready $policy_validation none complete"
if [ "$(policy_bash_decision "$renderer_command")" != allow ]; then
  printf 'FAIL: policy did not allow the canonical installed renderer invocation\n' >&2
  exit 1
fi
relative_renderer_command="ONBOARD_REQUIRED_PATHS_FILE=.launch-control-onboard/required-paths.txt ONBOARD_BASELINE_PATHS_FILE=.launch-control-onboard/baseline-paths.txt $policy_renderer .launch-control-onboard/ledger.tsv policy-test valid absent ready .launch-control-onboard/validation-commands.txt none complete"
if [ "$(policy_bash_decision "$relative_renderer_command")" != allow ]; then
  printf 'FAIL: policy did not allow repo-relative finalizer control paths\n' >&2
  exit 1
fi
for denied_renderer in \
  "/tmp/skills/onboard/scripts/render-report.sh $policy_ledger policy-test valid absent ready $policy_validation none complete" \
  "$policy_renderer $policy_ledger wrong-branch valid absent ready $policy_validation none complete" \
  "bash $policy_renderer $policy_ledger policy-test valid absent ready $policy_validation none complete"; do
  if [ "$(policy_bash_decision "$denied_renderer")" != deny ]; then
    printf 'FAIL: policy did not deny a non-canonical renderer invocation: %s\n' "$denied_renderer" >&2
    exit 1
  fi
done
# Fix 3: SKILL.md prescribes `render-report.sh --cleanup` as the degraded-mode cleanup step, so
# the policy must allow exactly that two-word canonical shape. A trailing argument, a `bash`
# prefix, or a near-miss flag stays denied.
if [ "$(policy_bash_decision "$policy_renderer --cleanup")" != allow ]; then
  printf 'FAIL: policy did not allow the canonical renderer --cleanup invocation\n' >&2
  exit 1
fi
policy_git_dir="$(git -C "$policy_repo" rev-parse --absolute-git-dir)"
: > "$policy_git_dir/launch-control-onboard-run-policy-session.active"
if [ "$(policy_bash_decision "$policy_renderer --cleanup" '' policy-session)" != deny ]; then
  printf '%s\n' 'FAIL: policy allowed cleanup to erase an active lifecycle run' >&2
  exit 1
fi
rm -f "$policy_git_dir/launch-control-onboard-run-policy-session.active"
for denied_cleanup in \
  "$policy_renderer --cleanup extra" \
  "$policy_renderer --clean" \
  "bash $policy_renderer --cleanup"; do
  if [ "$(policy_bash_decision "$denied_cleanup")" != deny ]; then
    printf 'FAIL: policy did not deny a non-canonical renderer cleanup invocation: %s\n' "$denied_cleanup" >&2
    exit 1
  fi
done
# A leading `./` is the same path as the bare spelling, but the traversal guard matched it
# as `*/./*` and refused. Runs emit that spelling constantly: one acceptance run issued
# four `./`-prefixed finds, ate four denials, and reissued all four bare seconds later.
# relative_repo_path is the single path gate, so every read tool shared the defect.
for dot_slash_allowed in 'find ./.github -type f' 'find ./.venv/bin -maxdepth 1 -type f' \
  'cat ./README.md' 'ls ./artifacts' 'wc -l ./CLAUDE.md' 'find ./ -type f'; do
  if [ "$(policy_bash_decision "$dot_slash_allowed" '')" != allow ]; then
    printf 'FAIL: an authorized read was denied for its ./ spelling: %s\n' "$dot_slash_allowed" >&2
    exit 1
  fi
done
# Stripping the leading `./` must not weaken confinement: traversal in any position, a
# protected secret, and an absolute path stay denied.
for dot_slash_denied in 'cat ./../outside.txt' 'cat ./.env' 'find ./../up -type f' \
  'cat ./docs/../../escape' 'ls ./.git/../../elsewhere' 'cat /etc/passwd'; do
  if [ "$(policy_bash_decision "$dot_slash_denied" '')" != deny ]; then
    printf 'FAIL: ./ normalization weakened repository confinement: %s\n' "$dot_slash_denied" >&2
    exit 1
  fi
done

# Runs spell repository commands as `git -C <repository> <subcommand>` with an absolute
# path. Every rule is written against the bare `git <subcommand>` form, so those missed
# BOTH lists: approved reads prompted (three per acceptance run), and `git reset --hard`
# escaped the destructive denylist into a prompt a user could click through. The prefix is
# normalized when -- and only when -- it names this repository.
for git_c_allowed in 'status --short --untracked-files=all' 'branch --show-current' \
  'ls-files --directory --others --cached -- .github'; do
  if [ "$(policy_bash_decision "git -C $policy_repo $git_c_allowed" '')" != allow ]; then
    printf 'FAIL: an approved git read did not allow in its -C spelling: git -C <repo> %s\n' "$git_c_allowed" >&2
    exit 1
  fi
done
for git_c_denied in 'reset --hard' 'push origin main' 'checkout main' 'ls-files -- ../escape' \
  'ls-files -- .env'; do
  if [ "$(policy_bash_decision "git -C $policy_repo $git_c_denied" '')" != deny ]; then
    printf 'FAIL: a destructive or escaping git command was not denied in its -C spelling: git -C <repo> %s\n' "$git_c_denied" >&2
    exit 1
  fi
done
# The normalization is scoped to this repository. A -C naming anywhere else is not
# rewritten and keeps the ordinary review path, so it can never borrow the allowlist.
if [ "$(policy_bash_decision 'git -C /tmp status' '')" = allow ]; then
  printf '%s\n' 'FAIL: git -C on a foreign directory borrowed the repository allowlist' >&2
  exit 1
fi
if [ "$(policy_bash_decision "git -C $policy_repo/.. status" '')" = allow ]; then
  printf '%s\n' 'FAIL: git -C on a parent directory borrowed the repository allowlist' >&2
  exit 1
fi

# An unlisted command falls back to a prompt normally. Under bypassPermissions no prompt
# can appear, so the same command hard-denies instead: the enforced boundary is STRICTER
# under bypass, never looser.
if [ "$(policy_bash_decision './tools/not-declared.sh' '')" != ask ]; then
  printf 'FAIL: unlisted command did not ask in the default permission mode\n' >&2
  exit 1
fi
if [ "$(policy_bash_decision './tools/not-declared.sh' bypassPermissions)" != deny ]; then
  printf 'FAIL: unlisted command was not hard-denied under bypassPermissions\n' >&2
  exit 1
fi
# LC-058: the denial explains itself without steering the user's chosen permission mode.
bypass_reason="$(jq -n --arg cwd "$policy_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,permission_mode:"bypassPermissions",tool_name:"Bash",tool_input:{command:"./tools/not-declared.sh",dangerouslyDisableSandbox:false}}' \
  | run_policy | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
case "$bypass_reason" in
  *'permission bypass cannot answer one'*) ;;
  *) printf 'FAIL: bypass deny does not say why the ask became a denial: %s\n' "$bypass_reason" >&2; exit 1 ;;
esac
case "$bypass_reason" in
  *'default permission mode'* | *rerun* | *again*)
    printf 'FAIL: bypass deny steers the permission mode or demands a repeat disclosure: %s\n' "$bypass_reason" >&2; exit 1 ;;
esac
# The policy used to refuse EVERY covered operation under bypass, before any allowlist
# branch, which made /onboard unrunnable in the permission mode a large share of users run
# by default -- and contradicted SKILL.md, which says the run may proceed. An allowlisted
# operation must now proceed under bypass exactly as it does in the default mode, so a
# bypass run needs no approvals at all.
for bypass_allowed in 'cat README.md' "$renderer_command" \
  'git status' 'git ls-files --directory --others --cached -- .github'; do
  if [ "$(policy_bash_decision "$bypass_allowed" bypassPermissions)" != allow ]; then
    printf 'FAIL: an allowlisted command did not proceed under bypassPermissions: %s\n' "$bypass_allowed" >&2
    exit 1
  fi
done
# LC-037: onboarding never runs a project's own commands. A project command is never auto-allowed:
# it reaches the normal prompt in the default mode and is hard-denied under bypassPermissions,
# where no prompt can appear. This is the model-side half of the guarantee that the renderer
# executes none of them.
for project_command in './tools/validate-pack.sh' 'npm test' 'pytest tests/unit' 'pnpm test:node' 'make lint'; do
  if [ "$(policy_bash_decision "$project_command" '')" != ask ]; then
    printf 'FAIL: a project command was auto-allowed in the default mode: %s\n' "$project_command" >&2
    exit 1
  fi
  if [ "$(policy_bash_decision "$project_command" bypassPermissions)" != deny ]; then
    printf 'FAIL: a project command was not hard-denied under bypassPermissions: %s\n' "$project_command" >&2
    exit 1
  fi
done
# The boundary that matters is untouched: `deny` is honored in every permission mode, so a
# destructive, escaping, or secret-reading operation is refused under bypass as well.
for bypass_denied in 'git reset --hard' 'cat ../outside.txt' 'cat .env' \
  'git ls-files -- ../outside' 'git ls-files -- .env' 'git ls-files --exec-path=/tmp/x'; do
  if [ "$(policy_bash_decision "$bypass_denied" bypassPermissions)" != deny ]; then
    printf 'FAIL: a covered-dangerous command was not denied under bypassPermissions: %s\n' "$bypass_denied" >&2
    exit 1
  fi
done
for bypass_tool in Read Write; do
  bypass_path="$policy_repo/README.md"
  [ "$bypass_tool" = Write ] && bypass_path="$policy_repo/CLAUDE.md"
  jq -n --arg cwd "$policy_repo" --arg tool "$bypass_tool" --arg path "$bypass_path" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,permission_mode:"bypassPermissions",tool_name:$tool,tool_input:{file_path:$path}}' \
    | run_policy > "$policy_output"
  run_rg -q '"permissionDecision":"allow"' "$policy_output"
done
# A protected secret stays denied on the Read path under bypass too.
jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,permission_mode:"bypassPermissions",tool_name:"Read",tool_input:{file_path:($cwd+"/.env")}}' \
  | run_policy > "$policy_output"
run_rg -q '"permissionDecision":"deny"' "$policy_output"
# The PermissionRequest event grants an allowlisted write under bypass rather than
# refusing it before dispatch.
permreq_bypass="$(jq -n --arg cwd "$policy_repo" '{hook_event_name:"PermissionRequest",cwd:$cwd,permission_mode:"bypassPermissions",tool_name:"Write",tool_input:{file_path:($cwd+"/CLAUDE.md")}}' | run_policy)"
if ! printf '%s' "$permreq_bypass" | grep -q '"behavior":"allow"'; then
  printf 'FAIL: PermissionRequest did not allow an allowlisted write under bypassPermissions\n' >&2
  exit 1
fi
# A tool the policy does not cover reaches the dispatch fallback: a prompt normally, a
# denial under bypass. This is what keeps bypass from passing an unreviewed operation.
if [ "$(jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,permission_mode:"bypassPermissions",tool_name:"WebFetch",tool_input:{url:"https://example.com"}}' | run_policy | jq -r '.hookSpecificOutput.permissionDecision // "none"')" != deny ]; then
  printf 'FAIL: an uncovered tool was not denied under bypassPermissions\n' >&2
  exit 1
fi
# The policy never persists a permission grant.
policy_allow_output="$(jq -n --arg cwd "$policy_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:"cat README.md",dangerouslyDisableSandbox:false}}' | run_policy)"
if printf '%s' "$policy_allow_output" | grep -q updatedPermissions; then
  printf 'FAIL: policy returned updatedPermissions\n' >&2
  exit 1
fi
rm -f "$policy_repo/escape"
test "$(shasum -a 256 "$policy_repo/.claude/settings.local.json")" = "$policy_settings_before"

# GAP-3: a single-token package-manager builtin (pnpm publish/add, yarn upgrade, ...) is not a
# repo-declared script and must never be auto-allowed, even when a matching Bash(<command>)
# permission exists. Grant the permissions anyway so the rejection is not a missing grant.
printf '%s\n' '{"permissions":{"allow":["Bash(npm test)","Bash(pytest tests/*.py)","Bash(pnpm lint)","Bash(pnpm publish)","Bash(yarn upgrade)"]}}' > "$policy_repo/.claude/settings.json"
# LC-037: even a bare script with a matching permission is a project command and is not auto-allowed.
if [ "$(policy_bash_decision 'pnpm lint')" = allow ]; then
  printf '%s\n' 'FAIL: policy auto-allowed a project command, the bare script pnpm lint' >&2
  exit 1
fi
for policy_builtin in 'pnpm publish' 'yarn upgrade'; do
  if [ "$(policy_bash_decision "$policy_builtin")" = allow ]; then
    printf 'FAIL: policy auto-allowed a package-manager builtin: %s\n' "$policy_builtin" >&2
    exit 1
  fi
done

