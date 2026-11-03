# shellcheck shell=bash
# Completion guard: attestation, emission scan, task lifecycle, deletion gates.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
report_output="$installer_tmp/report-output.txt"
guard="$ROOT/skills/onboard/scripts/completion-guard.sh"
run_guard() {
  CLAUDE_CONFIG_DIR="$policy_config" "$guard"
}
# A session whose cwd was a worktree removed after /onboard must not be locked out: the hooks
# outlive the skill, so a block here fails every later prompt in that session.
jq -n --arg cwd "$installer_tmp/removed-worktree" \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"gone-cwd",prompt:"hi"}' \
  | run_guard > "$installer_tmp/gone-cwd.out"
if [ -s "$installer_tmp/gone-cwd.out" ]; then
  printf '%s\n' 'FAIL: the guard blocked a prompt in a session whose cwd no longer exists' >&2
  exit 1
fi
write_discovery_fixture() {
  local repo="$1" project="${2:-validator-fixture}" branch="${3:-main}" ci="${4:-none}"
  mkdir -p "$repo/.launch-control-onboard"
  # Round-33: the freshness section is derived from what is actually on disk in $repo, not
  # hardcoded, so every caller stays schema-valid whether or not it seeded CLAUDE.md or
  # artifacts/. A caller that wants a `contradicts` verdict writes its own report.
  local freshness_lines=() freshness_doc
  for freshness_doc in CLAUDE.md artifacts/architecture.md artifacts/infrastructure.md; do
    if [ -f "$repo/$freshness_doc" ] && [ ! -L "$repo/$freshness_doc" ]; then
      freshness_lines+=("  $freshness_doc: consistent")
    fi
  done
  [ "${#freshness_lines[@]}" -gt 0 ] || freshness_lines=('  (no preserved documentation)')
  printf '%s\n' \
    '=== Workspace Discovery Report ===' \
    '' \
    "Project: $project (Bash)" \
    'Stack: Bash + repository scripts + shell checks' \
    'Monorepo: no' \
    "Base branch: $branch" \
    "CI: $ci" \
    '' \
    'Existing setup:' \
    '  CLAUDE.md ............. not found — will create' \
    '  .claude/settings.json . found — will merge' \
    '  .claude/agents/ ....... 0 found — will add 2 missing' \
    '  .claude/skills/ ....... 0 found — will add 6 missing' \
    '  .claude/commands/ ..... 0 found — will add 7 missing' \
    '  .mcp.json ............. not found — report only unless enabled' \
    '' \
    'Sources used:' \
    '  checks/validate-a.sh -> declared validation command' \
    '  CLAUDE.md -> project guidance and existing generated marker' \
    '  .claude/settings.json -> existing permissions and sandbox configuration' \
    '  .claude/agents/ -> existing project agents' \
    '  .claude/skills/ -> existing project skills' \
    '  .claude/commands/ -> existing project commands' \
    '  .mcp.json -> project MCP configuration when present' \
    '' \
    'Preserved doc freshness:' \
    "${freshness_lines[@]}" \
    '' \
    '=== End Workspace Discovery Report ===' \
    > "$repo/.launch-control-onboard/discovery-report.txt"
}
checkpoint_repo="$installer_tmp/discovery-checkpoint-repo"
write_discovery_fixture "$checkpoint_repo" checkpoint-fixture main none
(cd "$checkpoint_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/discovery-checkpoint.out"
cmp -s "$checkpoint_repo/.launch-control-onboard/discovery-report.txt" "$installer_tmp/discovery-checkpoint.out"
checkpoint_hash="$(shasum -a 256 "$checkpoint_repo/.launch-control-onboard/discovery-report.txt" | awk '{ print $1 }')"
run_rg -q "^phase-0-discovery-complete[[:space:]]+$checkpoint_hash[[:space:]]+" "$checkpoint_repo/.launch-control-onboard/discovery-checkpoint"
printf '%s\n' '=== Workspace Discovery Report ===' > "$checkpoint_repo/.launch-control-onboard/discovery-report.txt"
if (cd "$checkpoint_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") >/dev/null 2>"$installer_tmp/discovery-checkpoint-malformed.err"; then
  printf '%s\n' 'FAIL: discovery checkpoint accepted a header-only report' >&2
  exit 1
fi
run_rg -q 'required complete schema' "$installer_tmp/discovery-checkpoint-malformed.err"

# Round-33 F42. The Phase 0 preserved-doc freshness gate. Live on rymonroe.com the same stale
# fact -- artifacts/infrastructure.md denying an `npm run typecheck` script package.json declares
# -- sat in TWO surfaces (that doc and CLAUDE.md prose outside the generated markers), the run
# blocked at Phase 4 after 8m40s and five written paths, and its blocked protocol named ONE of
# them. Both halves are fixtured here: the gate must refuse before the checkpoint marker exists
# (so the guard's first-write denial still stands), and it must enumerate EVERY contradiction.
f42_repo() {
  # Two statements, not one `local a= b="$a"`: bash 3.2 evaluates the whole `local` line before
  # the earlier name is set, so the second reference trips `set -u` with "unbound variable".
  local name="$1"
  local repo="$installer_tmp/f42-$name"
  rm -rf "$repo"
  mkdir -p "$repo/artifacts"
  printf '%s\n' "$name" > "$repo/CLAUDE.md"
  printf '%s\n' "$name" > "$repo/artifacts/architecture.md"
  printf '%s\n' "$name" > "$repo/artifacts/infrastructure.md"
  printf '%s' "$repo"
}
f42_report() {
  # $1 = repo, remaining args = the freshness lines verbatim
  local repo="$1"; shift
  mkdir -p "$repo/.launch-control-onboard"
  printf '%s\n' \
    '=== Workspace Discovery Report ===' \
    '' \
    'Project: f42 (Bash)' \
    'Stack: Bash + none + none' \
    'Monorepo: no' \
    'Base branch: main' \
    'CI: none' \
    '' \
    'Existing setup:' \
    '  CLAUDE.md ............. found — will merge' \
    '  .claude/settings.json . not found — will create' \
    '  .claude/agents/ ....... 0 found — will add 2 missing' \
    '  .claude/skills/ ....... 0 found — will add 6 missing' \
    '  .claude/commands/ ..... 0 found — will add 7 missing' \
    '  .mcp.json ............. not found — report only unless enabled' \
    '' \
    'Sources used:' \
    '  package.json -> declared validation commands' \
    '' \
    'Preserved doc freshness:' \
    "$@" \
    '' \
    '=== End Workspace Discovery Report ===' \
    > "$repo/.launch-control-onboard/discovery-report.txt"
}
f42_run() {
  local repo="$1" out="$2"
  (cd "$repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") >/dev/null 2>"$out"
}

# F42a: every comparable document accounted for and consistent -- the gate passes and stamps.
f42_a="$(f42_repo consistent)"
f42_report "$f42_a" \
  '  CLAUDE.md: consistent' \
  '  artifacts/architecture.md: consistent' \
  '  artifacts/infrastructure.md: consistent'
if ! f42_run "$f42_a" "$installer_tmp/f42a.err"; then
  printf '%s\n' 'FAIL: the freshness gate refused a report whose every document was consistent' >&2
  cat "$installer_tmp/f42a.err" >&2
  exit 1
fi
test -f "$f42_a/.launch-control-onboard/discovery-checkpoint"

# F42b: one contradiction blocks, names that path with a count of 1, and -- the load-bearing
# half -- leaves NO checkpoint marker, so the lifecycle guard keeps denying the first write.
f42_b="$(f42_repo one)"
f42_report "$f42_b" \
  '  CLAUDE.md: consistent' \
  '  artifacts/architecture.md: consistent' \
  '  artifacts/infrastructure.md: contradicts: package.json declares typecheck. The doc denies it.'
if f42_run "$f42_b" "$installer_tmp/f42b.err"; then
  printf '%s\n' 'FAIL: the freshness gate accepted a report recording a contradiction' >&2
  exit 1
fi
run_rg -qF 'preserved documentation contradicts live evidence (1):' "$installer_tmp/f42b.err"
run_rg -qxF '  artifacts/infrastructure.md' "$installer_tmp/f42b.err"
run_rg -qF 'Failed (1)' "$installer_tmp/f42b.err"
if [ -e "$f42_b/.launch-control-onboard/discovery-checkpoint" ]; then
  printf '%s\n' 'FAIL: a contradicting report still stamped the checkpoint marker' >&2
  exit 1
fi

# F42c: the rymonroe shape. Two surfaces carrying the same stale fact must BOTH be named, with
# a count of 2 -- naming only the first is what buys a second full onboarding run.
f42_c="$(f42_repo two)"
f42_report "$f42_c" \
  '  CLAUDE.md: contradicts: prose above the marker denies npm run typecheck' \
  '  artifacts/architecture.md: consistent' \
  '  artifacts/infrastructure.md: contradicts: package.json declares typecheck'
if f42_run "$f42_c" "$installer_tmp/f42c.err"; then
  printf '%s\n' 'FAIL: the freshness gate accepted a report recording two contradictions' >&2
  exit 1
fi
run_rg -qF 'preserved documentation contradicts live evidence (2):' "$installer_tmp/f42c.err"
run_rg -qxF '  CLAUDE.md' "$installer_tmp/f42c.err"
run_rg -qxF '  artifacts/infrastructure.md' "$installer_tmp/f42c.err"
run_rg -qF 'Failed (2)' "$installer_tmp/f42c.err"

# F42d: a document on disk with no verdict line at all. Silence is not `consistent`.
f42_d="$(f42_repo unaccounted)"
f42_report "$f42_d" \
  '  CLAUDE.md: consistent' \
  '  artifacts/architecture.md: consistent'
if f42_run "$f42_d" "$installer_tmp/f42d.err"; then
  printf '%s\n' 'FAIL: the freshness gate accepted a report that skipped a document on disk' >&2
  exit 1
fi
run_rg -qF 'freshness section does not account for artifacts/infrastructure.md' "$installer_tmp/f42d.err"

# F42e: greenfield. Nothing to compare is a state the schema must express, not a blank section.
f42_e="$installer_tmp/f42-greenfield"
rm -rf "$f42_e"
mkdir -p "$f42_e"
f42_report "$f42_e" '  (no preserved documentation)'
if ! f42_run "$f42_e" "$installer_tmp/f42e.err"; then
  printf '%s\n' 'FAIL: the freshness gate refused a greenfield repository with no preserved docs' >&2
  cat "$installer_tmp/f42e.err" >&2
  exit 1
fi
test -f "$f42_e/.launch-control-onboard/discovery-checkpoint"

# F42f: the same greenfield report shape, but a document exists. The `(no preserved
# documentation)` line must not be usable as a blanket exemption.
f42_f="$(f42_repo falseclaim)"
f42_report "$f42_f" '  (no preserved documentation)'
if f42_run "$f42_f" "$installer_tmp/f42f.err"; then
  printf '%s\n' 'FAIL: a repository with preserved docs passed on the greenfield freshness line' >&2
  exit 1
fi

# F42g: a verdict the schema does not define. Hedged prose is not a verdict.
f42_g="$(f42_repo hedged)"
f42_report "$f42_g" \
  '  CLAUDE.md: probably fine' \
  '  artifacts/architecture.md: consistent' \
  '  artifacts/infrastructure.md: consistent'
if f42_run "$f42_g" "$installer_tmp/f42g.err"; then
  printf '%s\n' 'FAIL: the freshness gate accepted an undefined verdict' >&2
  exit 1
fi
run_rg -qF "freshness verdict for CLAUDE.md must be exactly" "$installer_tmp/f42g.err"

# LC-001: Phase 1a's `Read(/.env*)` and `Read(/**/.env*)` denies match the safe example names
# too, so a run that defers reading them to artifact authoring lost them with no trace. Every
# example on disk (root) or tracked (any depth) needs exactly one `read` or `denied` line, `read`
# needs the Sources used line it fed, and `denied` holds only where the boundary already exists.
lc001_repo() {
  local repo="$installer_tmp/lc001-$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' 'API_URL=' > "$repo/.env.example"
  printf '%s' "$repo"
}
lc001_report() {
  # $1 = repo, $2 = Sources used line, remaining args = section lines (none omits the section)
  local repo="$1" source="$2"; shift 2
  local section=()
  [ "$#" -eq 0 ] || section=('' 'Safe env examples:' "$@")
  mkdir -p "$repo/.launch-control-onboard"
  printf '%s\n' \
    '=== Workspace Discovery Report ===' '' 'Project: lc001 (Bash)' 'Stack: Bash + none + none' \
    'Monorepo: no' 'Base branch: main' 'CI: none' '' 'Existing setup:' \
    '  CLAUDE.md ............. not found — will create' \
    '  .claude/settings.json . not found — will create' \
    '  .claude/agents/ ....... 0 found — will add 2 missing' \
    '  .claude/skills/ ....... 0 found — will add 6 missing' \
    '  .claude/commands/ ..... 0 found — will add 7 missing' \
    '  .mcp.json ............. not found — report only unless enabled' \
    '' 'Sources used:' '  README.md -> project purpose' "$source" \
    '' 'Preserved doc freshness:' '  (no preserved documentation)' \
    ${section[@]+"${section[@]}"} \
    '' '=== End Workspace Discovery Report ===' \
    > "$repo/.launch-control-onboard/discovery-report.txt"
}
lc001_expect() {
  # $1 = pass|fail, $2 = repo, $3 = label, $4 = stderr text a refusal must carry
  if f42_run "$2" "$installer_tmp/lc001-$3.err"; then
    [ "$1" = pass ] || { printf 'FAIL: LC-001 %s: the checkpoint accepted it\n' "$3" >&2; exit 1; }
    test -f "$2/.launch-control-onboard/discovery-checkpoint"
  else
    [ "$1" = fail ] || { printf 'FAIL: LC-001 %s: the checkpoint refused it\n' "$3" >&2; cat "$installer_tmp/lc001-$3.err" >&2; exit 1; }
    test ! -e "$2/.launch-control-onboard/discovery-checkpoint"
    run_rg -qF "$4" "$installer_tmp/lc001-$3.err"
  fi
}
lc001_a="$(lc001_repo silent)"
lc001_report "$lc001_a" '  .env.example -> API_URL'
lc001_expect fail "$lc001_a" silent 'safe env example .env.example is not accounted for'
lc001_b="$(lc001_repo read)"
lc001_report "$lc001_b" '  .env.example -> API_URL' '  .env.example: read'
lc001_expect pass "$lc001_b" read
lc001_c="$(lc001_repo unsourced)"
lc001_report "$lc001_c" '  package.json -> scripts' '  .env.example: read'
lc001_expect fail "$lc001_c" unsourced 'Sources used has no line for .env.example'
lc001_d="$(lc001_repo early-denied)"
lc001_report "$lc001_d" '  package.json -> scripts' '  .env.example: denied'
lc001_expect fail "$lc001_d" early-denied 'no .env read deny exists yet'
lc001_e="$(lc001_repo rerun)"
mkdir -p "$lc001_e/.claude"
printf '%s\n' '{"permissions":{"deny":["Read(/.env*)","Read(/**/.env*)"]}}' > "$lc001_e/.claude/settings.json"
lc001_report "$lc001_e" '  package.json -> scripts' '  .env.example: denied'
lc001_expect pass "$lc001_e" rerun
lc001_f="$(lc001_repo nested)"
mkdir -p "$lc001_f/apps/web"
printf '%s\n' 'DB_URL=' > "$lc001_f/apps/web/.env.sample"
git -C "$lc001_f" add apps/web/.env.sample
lc001_report "$lc001_f" '  .env.example -> API_URL' '  .env.example: read'
lc001_expect fail "$lc001_f" nested 'safe env example apps/web/.env.sample is not accounted for'
lc001_h="$(lc001_repo allow-only)"
mkdir -p "$lc001_h/.claude"
printf '%s\n' '{"permissions":{"allow":["Read(/.env*)"]}}' > "$lc001_h/.claude/settings.json"
lc001_report "$lc001_h" '  package.json -> scripts' '  .env.example: denied'
lc001_expect fail "$lc001_h" allow-only 'no .env read deny exists yet'
lc001_i="$(lc001_repo root-deny-nested)"
mkdir -p "$lc001_i/.claude" "$lc001_i/apps/web"
printf '%s\n' '{"permissions":{"deny":["Read(/.env*)"]}}' > "$lc001_i/.claude/settings.json"
printf '%s\n' 'DB_URL=' > "$lc001_i/apps/web/.env.sample"
git -C "$lc001_i" add apps/web/.env.sample
lc001_report "$lc001_i" '  package.json -> scripts' '  .env.example: denied' '  apps/web/.env.sample: denied'
lc001_expect fail "$lc001_i" root-deny-nested 'apps/web/.env.sample is marked denied'
lc001_j="$(lc001_repo empty-source)"
lc001_report "$lc001_j" '  .env.example -> ' '  .env.example: read'
lc001_expect fail "$lc001_j" empty-source 'Sources used has no line for .env.example'
lc001_g="$(lc001_repo hedged)"
lc001_report "$lc001_g" '  .env.example -> API_URL' '  .env.example: skimmed'
lc001_expect fail "$lc001_g" hedged "verdict for .env.example must be exactly 'read' or 'denied'"

# F42h: an old-format report with no freshness section at all fails the shared schema, in both
# copies of it -- the checkpoint's and the guard's.
f42_h="$(f42_repo oldformat)"
f42_report "$f42_h" '  CLAUDE.md: consistent' '  artifacts/architecture.md: consistent' \
  '  artifacts/infrastructure.md: consistent'
run_rg -v 'Preserved doc freshness:' "$f42_h/.launch-control-onboard/discovery-report.txt" \
  > "$f42_h/.launch-control-onboard/report.tmp"
mv "$f42_h/.launch-control-onboard/report.tmp" "$f42_h/.launch-control-onboard/discovery-report.txt"
if f42_run "$f42_h" "$installer_tmp/f42h.err"; then
  printf '%s\n' 'FAIL: the checkpoint accepted a report with no freshness section' >&2
  exit 1
fi
run_rg -q 'required complete schema' "$installer_tmp/f42h.err"

guard_repo="$installer_tmp/guard-repo"
mkdir -p "$guard_repo/skills/onboard/references" "$guard_repo/tools/fixtures" "$guard_repo/.claude" "$guard_repo/checks"
git -C "$guard_repo" init -q -b validator
git -C "$guard_repo" config user.name validator
git -C "$guard_repo" config user.email validator@example.com
touch "$guard_repo/skills/onboard/references/hooks-and-config.md" "$guard_repo/tools/fixtures/onboard-manifests.json"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$guard_repo/checks/validate-a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$guard_repo/checks/validate-b.sh"
chmod +x "$guard_repo/checks/validate-a.sh" "$guard_repo/checks/validate-b.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(./checks/validate-b.sh)"]}}' > "$guard_repo/.claude/settings.json"
git -C "$guard_repo" add .
git -C "$guard_repo" commit -qm baseline
printf '%s\n' dirty > "$guard_repo/dirty.txt"

guard_output="$installer_tmp/guard-output.json"
jq -n --arg cwd "$guard_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Edit"}' | run_guard > "$guard_output"
run_rg -q 'cannot write before the complete Workspace Discovery Report' "$guard_output"
write_discovery_fixture "$guard_repo" guard-fixture validator none
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$guard_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Edit"}' | run_guard
mkdir -p "$guard_repo/.launch-control-onboard"
guard_ledger="$guard_repo/.launch-control-onboard/guard-ledger.tsv"
printf '%s\t%s\n' \
  SKIPPED .mcp.json \
  SKIPPED .claude/hooks/skill-eval.sh > "$guard_ledger"
guard_validation="$guard_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate-a.sh' './checks/validate-b.sh' > "$guard_validation"
guard_git_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)"
report_state="$guard_git_dir/launch-control-onboard-report.expected"
guard_run_state="$guard_git_dir/launch-control-onboard-run-validator.active"
guard_baseline_state="$guard_git_dir/launch-control-onboard-run-validator.baseline"
guard_task_state="$guard_git_dir/launch-control-onboard-run-validator.tasks"
guard_discovery_state="$guard_git_dir/launch-control-onboard-run-validator.discovery"
guard_disarmed_state="$guard_git_dir/launch-control-onboard-run-validator.disarmed"
guard_inventory_state="$guard_git_dir/launch-control-onboard-run-validator.inventory"
test -f "$guard_discovery_state"
run_rg -q '^dirty\.txt$' "$guard_baseline_state"
if [ ! -s "$guard_inventory_state" ]; then
  printf '%s\n' 'FAIL: completion guard did not capture a pre-write manifest inventory' >&2
  exit 1
fi

# Round-5: the renderer derives non-manifest baseline rows (dirty.txt here) itself, so an
# honest ledger listing only manifest paths no longer fails on hand-listing gaps. A ledger
# row for a tracked file the run never modified must still fail: it is in neither the
# manifest nor the pre-run inventory.
printf '%s\t%s\n' PRESERVED checks/validate-a.sh >> "$guard_ledger"
if (cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) >/dev/null 2>"$installer_tmp/captured-baseline.err"; then
  printf '%s\n' 'FAIL: renderer accepted a ledger row outside the pre-run inventory' >&2
  exit 1
fi
run_rg -q 'ledger path is absent from the pre-run inventory: checks/validate-a\.sh' "$installer_tmp/captured-baseline.err"
printf '%s\t%s\n' \
  SKIPPED .mcp.json \
  SKIPPED .claude/hooks/skill-eval.sh > "$guard_ledger"

# A Phase 5 task must close before the renderer can mint completion proof.
jq -n --arg cwd "$guard_repo" '{hook_event_name:"TaskCreated",cwd:$cwd,session_id:"validator",task_id:"phase-5"}' | run_guard
run_rg -q '^phase-5$' "$guard_task_state"
if (cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) >/dev/null 2>"$installer_tmp/open-task.err"; then
  printf '%s\n' 'FAIL: renderer accepted an incomplete onboarding task' >&2
  exit 1
fi
run_rg -q 'onboarding tasks remain incomplete: phase-5' "$installer_tmp/open-task.err"
jq -n --arg cwd "$guard_repo" '{hook_event_name:"TaskCompleted",cwd:$cwd,session_id:"validator",task_id:"phase-5"}' | run_guard
test ! -e "$guard_task_state"

(cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) > "$report_output"
run_rg -q '^Preserved \(0\):$' "$report_output"
run_rg -q '^Untouched pre-existing \(1\):$' "$report_output"
run_rg -q '^  dirty\.txt$' "$report_output"
run_rg -q '^Skipped \(2\):$' "$report_output"
run_rg -q '^  validation: not run \(2 documented gates;' "$report_output"
run_rg -q '^  none$' "$report_output"
test "$(tail -1 "$report_output")" = '=== End Workspace Setup ==='

# Any task mutation after rendering invalidates proof and requires task closure plus a fresh render.
jq -n --arg cwd "$guard_repo" '{hook_event_name:"TaskCreated",cwd:$cwd,session_id:"validator",task_id:"late-phase-5"}' | run_guard
test ! -e "$report_state"
run_rg -q '^late-phase-5$' "$guard_task_state"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q 'incomplete UI tasks' "$guard_output"
jq -n --arg cwd "$guard_repo" '{hook_event_name:"TaskCompleted",cwd:$cwd,session_id:"validator",task_id:"late-phase-5"}' | run_guard
test ! -e "$guard_task_state"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q 'without fresh renderer proof' "$guard_output"
(cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) > "$report_output"

# A stale proof from a session that never invoked the renderer must not validate.
guard_render_state="$guard_git_dir/launch-control-onboard-run-validator.rendered"
test ! -e "$guard_render_state"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q 'Renderer proof is stale' "$guard_output"

# BUG-10: a session that DID invoke the renderer but whose render failed (no fresh proof
# written) must not validate a stale proof left by an abnormal earlier session. The proof
# from the render above stands in for that stale proof. A completion-shaped PreToolUse
# invocation stamps the render marker AND clears the stale proof, so a failed render leaves
# no proof and the replay blocks. --cleanup and argument-less shapes must not stamp or clear.
jq -n --arg cwd "$guard_repo" --arg command "$policy_config/skills/onboard/scripts/render-report.sh --cleanup" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
test ! -e "$guard_render_state"
test -e "$report_state"
jq -n --arg cwd "$guard_repo" --arg command "$policy_config/skills/onboard/scripts/render-report.sh $guard_ledger validator valid absent ready $guard_validation none complete" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
test -f "$guard_render_state"
test ! -e "$report_state"
guard_failing_ledger="$guard_repo/.launch-control-onboard/failing-ledger.tsv"
printf '%s\t%s\n' PRESERVED does-not-exist.txt > "$guard_failing_ledger"
if (cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_failing_ledger" validator valid absent ready "$guard_validation" none complete) >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: renderer minted proof from a failing ledger' >&2
  exit 1
fi
test ! -e "$report_state"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q 'without fresh renderer proof' "$guard_output"
rm -f "$guard_failing_ledger"

# Valid completion: THIS session invokes the renderer (clearing any stale proof and stamping
# the marker), the render then succeeds and writes fresh proof, and the replayed renderer
# output validates.
jq -n --arg cwd "$guard_repo" --arg command "$policy_config/skills/onboard/scripts/render-report.sh $guard_ledger validator valid absent ready $guard_validation none complete" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
(cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) > "$report_output"
# The report remains completion-critical after checkpointing: missing, malformed, symlinked,
# header-only, or post-checkpoint-modified artifacts cannot satisfy the hash-bound attestation.
guard_discovery_report="$guard_repo/.launch-control-onboard/discovery-report.txt"
rm -f "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q '"decision":"block"' "$guard_output"
run_rg -q 'Workspace Discovery Report' "$guard_output"
test -e "$report_state"

printf '%s\n' '=== Workspace Discovery Report ===' > "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
run_rg -q 'schema' "$guard_output"

printf '%s\n' '=== Workspace Discovery Report ===' '' 'Project: malformed' \
  '=== End Workspace Discovery Report ===' > "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"

# Round-33 F42i: the guard carries its own copy of the report schema, and that copy gained the
# `Preserved doc freshness:` header alongside the checkpoint. Without this case the guard-side
# requirement has no killer -- every other fixture routes through write_discovery_fixture, which
# always emits the section, so a guard that silently stopped requiring it would stay green.
write_discovery_fixture "$guard_repo" guard-fixture validator none
run_rg -v 'Preserved doc freshness:|^  \(no preserved documentation\)$' "$guard_discovery_report" \
  > "$guard_repo/.launch-control-onboard/report-no-freshness.txt"
mv "$guard_repo/.launch-control-onboard/report-no-freshness.txt" "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
run_rg -q 'schema' "$guard_output"

rm -f "$guard_discovery_report"
ln -s ../dirty.txt "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"

rm -f "$guard_discovery_report"
write_discovery_fixture "$guard_repo" guard-fixture validator none
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
printf '%s\n' '# post-checkpoint mismatch' >> "$guard_discovery_report"
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q '"decision":"block"' "$guard_output"
run_rg -q 'session-bound' "$guard_output"

write_discovery_fixture "$guard_repo" guard-fixture validator none
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard

# Round-4 (review finding 1): a valid report artifact is not enough; when the Stop
# hook supplies a transcript, the report must also have been emitted visibly.
r4_transcript_missing="$installer_tmp/r4-transcript-missing.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":[{"type":"text","text":"onboard this repo"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":".launch-control-onboard/discovery-report.txt"}}]}}' \
  > "$r4_transcript_missing"
r4_transcript_present="$installer_tmp/r4-transcript-present.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"=== Workspace Discovery Report ===\nRepository: fixture\n=== End Workspace Discovery Report ==="}]}}' \
  > "$r4_transcript_present"

jq -n --arg cwd "$guard_repo" --arg tp "$r4_transcript_missing" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",transcript_path:$tp,last_assistant_message:"not renderer output"}' \
  | run_guard > "$installer_tmp/r4-stop-missing.out"
run_rg -q 'was never emitted as a standalone assistant message' "$installer_tmp/r4-stop-missing.out"

jq -n --arg cwd "$guard_repo" --arg tp "$r4_transcript_present" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",transcript_path:$tp,last_assistant_message:"not renderer output"}' \
  | run_guard > "$installer_tmp/r4-stop-present.out"
if run_rg -q 'was never emitted as a standalone assistant message' "$installer_tmp/r4-stop-present.out"; then
  printf '%s\n' 'FAIL: guard blamed emission despite a visible transcript emission' >&2
  exit 1
fi

jq -n --arg cwd "$guard_repo" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:"not renderer output"}' \
  | run_guard > "$installer_tmp/r4-stop-absent.out"
if run_rg -q 'was never emitted as a standalone assistant message' "$installer_tmp/r4-stop-absent.out"; then
  printf '%s\n' 'FAIL: guard did not fail open when transcript_path was absent' >&2
  exit 1
fi

# Round-5: the same transcript scan gates the FIRST manifest write at PreToolUse, so a
# skipped emission fails one message in instead of after a full render. Use an isolated
# repo + session so the write-time side effects cannot disturb the validator session state.
r5_repo="$installer_tmp/r5-emission-repo"
mkdir -p "$r5_repo"
git -C "$r5_repo" init -q -b r5
write_discovery_fixture "$r5_repo" r5-fixture r5 none
jq -n --arg cwd "$r5_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$r5_repo" --arg tp "$r4_transcript_missing" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",transcript_path:$tp,tool_name:"Edit",tool_input:{file_path:"CLAUDE.md"}}' \
  | run_guard > "$installer_tmp/r5-write-missing.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r5-write-missing.out"
run_rg -q 'cannot write before the Workspace Discovery Report has been emitted' "$installer_tmp/r5-write-missing.out"
jq -n --arg cwd "$r5_repo" --arg tp "$r4_transcript_present" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",transcript_path:$tp,tool_name:"Write",tool_input:{file_path:"CLAUDE.md"}}' \
  | run_guard > "$installer_tmp/r5-write-present.out"
if run_rg -q 'cannot write before the Workspace Discovery Report' "$installer_tmp/r5-write-present.out"; then
  printf '%s\n' 'FAIL: write gate blamed emission despite a visible transcript emission' >&2
  exit 1
fi
jq -n --arg cwd "$r5_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",tool_name:"Edit",tool_input:{file_path:"CLAUDE.md"}}' \
  | run_guard > "$installer_tmp/r5-write-absent.out"
if run_rg -q 'cannot write before the Workspace Discovery Report' "$installer_tmp/r5-write-absent.out"; then
  printf '%s\n' 'FAIL: write gate did not fail open when transcript_path was absent' >&2
  exit 1
fi

# Round-15 F32: the renderer's provenance check is only as good as the record behind it, so
# pin the recording itself rather than trusting hand-written fixtures in 40-report-contract.sh.
# The two allowed CLAUDE.md writes above are recorded in order; the DENIED write that preceded
# them is not, because a blocked write never happened.
r5_write_order="$r5_repo/.launch-control-onboard/write-order.guard.txt"
test -f "$r5_write_order"
run_rg -q '^1\tCLAUDE\.md$' "$r5_write_order"
run_rg -q '^2\tCLAUDE\.md$' "$r5_write_order"
if [ "$(grep -c '' "$r5_write_order")" -ne 2 ]; then
  printf 'FAIL: guard recorded %s CLAUDE.md writes; the denied write must not be counted\n' \
    "$(grep -c '' "$r5_write_order")" >&2
  exit 1
fi
# The prospective block is recorded under its repo-relative path from an absolute file_path,
# and paths the provenance check does not govern are never recorded at all.
jq -n --arg cwd "$r5_repo" --arg tp "$r4_transcript_present" --arg path "$r5_repo/.launch-control-onboard/prospective-claude.md" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",transcript_path:$tp,tool_name:"Write",tool_input:{file_path:$path}}' \
  | run_guard >/dev/null
run_rg -q '^3\t\.launch-control-onboard/prospective-claude\.md$' "$r5_write_order"
jq -n --arg cwd "$r5_repo" --arg tp "$r4_transcript_present" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",transcript_path:$tp,tool_name:"Write",tool_input:{file_path:"README.md"}}' \
  | run_guard >/dev/null
if [ "$(grep -c '' "$r5_write_order")" -ne 3 ]; then
  printf '%s\n' 'FAIL: guard recorded a write to a path the provenance check does not govern' >&2
  exit 1
fi
check_absent README "$r5_write_order"

# Round-7: the checkpoint's stdout re-emission arrives as a tool_result — accept it as the
# visible emission (thinking-heavy model modes produce tool-only messages with no text
# parts, so assistant-text cannot be the only accepted form).
r7_transcript_toolresult="$installer_tmp/r7-transcript-toolresult.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"discovery-checkpoint.sh"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"=== Workspace Discovery Report ===\nRepository: fixture\n=== End Workspace Discovery Report ==="}]}]}}' \
  > "$r7_transcript_toolresult"
jq -n --arg cwd "$r5_repo" --arg tp "$r7_transcript_toolresult" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r5",transcript_path:$tp,tool_name:"Write",tool_input:{file_path:"CLAUDE.md"}}' \
  | run_guard > "$installer_tmp/r7-write-toolresult.out"
if run_rg -q 'cannot write before the Workspace Discovery Report' "$installer_tmp/r7-write-toolresult.out"; then
  printf '%s\n' 'FAIL: write gate rejected a checkpoint tool_result emission' >&2
  exit 1
fi
jq -n --arg cwd "$r5_repo" --arg tp "$r7_transcript_toolresult" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"r5",transcript_path:$tp,last_assistant_message:"not renderer output"}' \
  | run_guard > "$installer_tmp/r7-stop-toolresult.out"
if run_rg -q 'was never emitted as a standalone assistant message' "$installer_tmp/r7-stop-toolresult.out"; then
  printf '%s\n' 'FAIL: stop backstop rejected a checkpoint tool_result emission' >&2
  exit 1
fi

# Round-7 circuit breaker: after two emission denies in a session the write gate stands
# down (Stop backstop still enforces), so a scan-incompatible agent cannot livelock.
r7cb_repo="$installer_tmp/r7cb-repo"
mkdir -p "$r7cb_repo"
git -C "$r7cb_repo" init -q -b r7cb
write_discovery_fixture "$r7cb_repo" r7cb-fixture r7cb none
jq -n --arg cwd "$r7cb_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r7cb",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
for r7cb_attempt in 1 2; do
  jq -n --arg cwd "$r7cb_repo" --arg tp "$r4_transcript_missing" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r7cb",transcript_path:$tp,tool_name:"Edit",tool_input:{file_path:"CLAUDE.md"}}' \
    | run_guard > "$installer_tmp/r7cb-deny-$r7cb_attempt.out"
  run_rg -q 'cannot write before the Workspace Discovery Report has been emitted' "$installer_tmp/r7cb-deny-$r7cb_attempt.out"
done
jq -n --arg cwd "$r7cb_repo" --arg tp "$r4_transcript_missing" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r7cb",transcript_path:$tp,tool_name:"Edit",tool_input:{file_path:"CLAUDE.md"}}' \
  | run_guard > "$installer_tmp/r7cb-standdown.out"
if run_rg -q 'cannot write before the Workspace Discovery Report' "$installer_tmp/r7cb-standdown.out"; then
  printf '%s\n' 'FAIL: emission write gate did not stand down after two denies' >&2
  exit 1
fi
jq -n --arg cwd "$r7cb_repo" --arg tp "$r4_transcript_missing" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"r7cb",transcript_path:$tp,last_assistant_message:"not renderer output"}' \
  | run_guard > "$installer_tmp/r7cb-stop.out"
# The stand-down never weakens Stop: with no renderer proof the backstop blocks before the
# emission scan is even consulted, and the emission scan itself still blocks any run that
# reaches the proof stage without a visible emission (covered by r4-stop-missing above).
run_rg -q '"decision":"block"' "$installer_tmp/r7cb-stop.out"

# Round-8: the discovery checkpoint flags an onboard marker block inside AGENTS.md so the
# staleness contract fires even on runs that never reach the agent-generation path (a
# pure-preserve rerun generates no agents and previously never read AGENTS.md).
r8_repo="$installer_tmp/r8-stale-agents-repo"
write_discovery_fixture "$r8_repo" r8-fixture main none
printf '%s\n' 'user authored content' \
  '## Generated Quick Reference' \
  'stale generated rows' > "$r8_repo/AGENTS.md"
(cd "$r8_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/r8-stale.out"
run_rg -q '^STALE-AGENTS-CANDIDATE: AGENTS\.md contains an onboard-generated block' "$installer_tmp/r8-stale.out"
run_rg -q '^=== End Workspace Discovery Report ===' "$installer_tmp/r8-stale.out"
# A block left by an OLDER onboard (legacy comment markers) is still flagged, so a repository
# onboarded before the heading-delimited contract is not silently treated as clean.
printf '%s\n' 'user authored content' \
  '<!-- BEGIN GENERATED SECTION -- onboard -->' \
  'stale generated rows' \
  '<!-- END GENERATED SECTION -- onboard -->' > "$r8_repo/AGENTS.md"
(cd "$r8_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/r8-stale-legacy.out"
run_rg -q '^STALE-AGENTS-CANDIDATE: AGENTS\.md contains an onboard-generated block' "$installer_tmp/r8-stale-legacy.out"
printf '%s\n' 'user authored content without any generated section' > "$r8_repo/AGENTS.md"
(cd "$r8_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/r8-clean.out"
cmp -s "$r8_repo/.launch-control-onboard/discovery-report.txt" "$installer_tmp/r8-clean.out"
if run_rg -q 'STALE-AGENTS-CANDIDATE' "$installer_tmp/r8-clean.out"; then
  printf '%s\n' 'FAIL: checkpoint flagged an AGENTS.md that has no onboard generated block' >&2
  exit 1
fi
run_rg -q 'STALE-AGENTS-CANDIDATE' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
run_rg -q 'never put a backtick in' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"

# Round-9: the renderer itself surfaces a stale onboard marker block in AGENTS.md as a
# guaranteed-visible report section with a manual-regeneration Next entry. Model-relayed
# pre-report notes proved droppable: the round-8 acceptance run read the stale block and
# still rendered `Next: none`.
r9_fixture() {
  local repo="$1"
  mkdir -p "$repo/.claude" "$repo/checks"
  git -C "$repo" init -q -b validator
  git -C "$repo" config user.name validator
  git -C "$repo" config user.email validator@example.com
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/checks/validate-a.sh"
  chmod +x "$repo/checks/validate-a.sh"
  printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' > "$repo/.claude/settings.json"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  mkdir -p "$repo/.launch-control-onboard"
  printf 'SKIPPED\t.mcp.json\n' > "$repo/.launch-control-onboard/ledger.tsv"
  printf '%s\n' './checks/validate-a.sh' > "$repo/.launch-control-onboard/validation-commands.txt"
  : > "$repo/.launch-control-onboard/required-paths.txt"
  : > "$repo/.launch-control-onboard/baseline-paths.txt"
}
r9_render() {
  local repo="$1"
  (cd "$repo" && ONBOARD_REQUIRED_PATHS_FILE="$repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
    valid absent ready .launch-control-onboard/validation-commands.txt none complete)
}
r9_stale_repo="$installer_tmp/r9-stale-repo"
r9_fixture "$r9_stale_repo"
printf '%s\n' 'user rules' \
  '## Generated Quick Reference' \
  'stale generated rows' > "$r9_stale_repo/AGENTS.md"
r9_render "$r9_stale_repo" > "$installer_tmp/r9-stale.out"
run_rg -q '^Stale AGENTS\.md:' "$installer_tmp/r9-stale.out"
run_rg -q '^  regenerate the stale AGENTS\.md generated block manually' "$installer_tmp/r9-stale.out"
if run_rg -q '^  none$' "$installer_tmp/r9-stale.out"; then
  printf '%s\n' 'FAIL: stale-AGENTS report still rendered Next: none' >&2
  exit 1
fi
r9_clean_repo="$installer_tmp/r9-clean-repo"
r9_fixture "$r9_clean_repo"
r9_render "$r9_clean_repo" > "$installer_tmp/r9-clean.out"
if run_rg -q 'Stale AGENTS' "$installer_tmp/r9-clean.out"; then
  printf '%s\n' 'FAIL: renderer emitted a stale-AGENTS section without a generated block' >&2
  exit 1
fi
run_rg -q '^  none$' "$installer_tmp/r9-clean.out"
run_rg -q 'Stale AGENTS\.md` section' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
# LC-061: in Codex mode the trusted finalizer regenerates AGENTS.md's block from CLAUDE.md, so a
# regenerated block is not reported stale. When it could not regenerate (no CLAUDE.md block to
# mirror), the stale block is still reported: suppression follows what the finalizer did.
r9_codex_repo="$installer_tmp/r9-codex-repo"
mkdir -p "$r9_codex_repo"
printf '%s\n' '## Generated Quick Reference' '' 'Use Claude Code.' \
  '- `artifacts/architecture.md`' '- `artifacts/infrastructure.md`' > "$r9_codex_repo/CLAUDE.md"
r9_fixture "$r9_codex_repo"
printf '%s\n' 'user rules' '## Generated Quick Reference' 'stale generated rows' > "$r9_codex_repo/AGENTS.md"
printf 'requested\n' > "$r9_codex_repo/.launch-control-onboard/codex-requested"
r9_render "$r9_codex_repo" > "$installer_tmp/r9-codex.out"
if run_rg -q 'Stale AGENTS' "$installer_tmp/r9-codex.out"; then
  printf '%s\n' 'FAIL: renderer reported AGENTS.md stale after the finalizer regenerated it' >&2
  exit 1
fi
run_rg -q '^Use Claude Code\.$' "$r9_codex_repo/AGENTS.md"
run_rg -q '^user rules$' "$r9_codex_repo/AGENTS.md"
r9_nosource_repo="$installer_tmp/r9-nosource-repo"
r9_fixture "$r9_nosource_repo"
printf '%s\n' 'user rules' '## Generated Quick Reference' 'stale generated rows' > "$r9_nosource_repo/AGENTS.md"
printf 'requested\n' > "$r9_nosource_repo/.launch-control-onboard/codex-requested"
r9_render "$r9_nosource_repo" > "$installer_tmp/r9-nosource.out"
run_rg -q '^Stale AGENTS\.md:' "$installer_tmp/r9-nosource.out"

# The Stop hook accepts the renderer's own completion report: no decision is emitted and every
# piece of run state is cleared except the disarm marker.
# LC-037 residual: a live run reaches Stop with the policy's mode markers and any deny counters
# it spent already on disk. The success terminal never cleared them, so every finished run left
# them in .git until the next /onboard in that repository (five sets found live, all disarmed).
for guard_spent_suffix in bypass permission-mode emission-denies lens-denies guidance-denies \
                          prospective-denies lens-render-denies; do
  printf '1\n' > "$guard_git_dir/launch-control-onboard-run-validator.$guard_spent_suffix"
done
jq -n --arg cwd "$guard_repo" --rawfile message "$report_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
test ! -s "$guard_output"
test ! -e "$report_state"
test ! -e "$guard_run_state"
test ! -e "$guard_baseline_state"
test ! -e "$guard_task_state"
test ! -e "$guard_discovery_state"
test -f "$guard_disarmed_state"
for guard_left in "$guard_git_dir"/launch-control-onboard-run-validator.*; do
  if [ "$guard_left" != "$guard_disarmed_state" ]; then
    printf 'FAIL: successful Stop left run marker %s in .git\n' "${guard_left##*/}" >&2
    exit 1
  fi
done

# Successful completion disarms retained skill hooks for unrelated turns in the same
# session. The policy must emit no decision, and the lifecycle guard must not recreate
# active/baseline/task state or intercept the later Stop.
jq -n --arg cwd "$guard_repo" --arg outside "$installer_tmp/outside.txt" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Read",tool_input:{file_path:$outside}}' \
  | run_policy > "$policy_output"
test ! -s "$policy_output"
jq -n --arg cwd "$guard_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Write"}' | run_guard > "$guard_output"
test ! -s "$guard_output"
test ! -e "$guard_run_state"
test ! -e "$guard_baseline_state"
test ! -e "$guard_task_state"
jq -n --arg cwd "$guard_repo" --arg message 'Unrelated work after onboarding.' \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' | run_guard > "$guard_output"
test ! -s "$guard_output"

# A second /onboard in the same session explicitly re-arms both hooks before discovery.
jq -n --arg cwd "$guard_repo" --arg prompt '/onboard --launch-control' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"validator",prompt:$prompt}' | run_guard > "$guard_output"
test ! -s "$guard_output"
test ! -e "$guard_disarmed_state"
jq -n --arg cwd "$guard_repo" --arg outside "$installer_tmp/outside.txt" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Read",tool_input:{file_path:$outside}}' \
  | run_policy > "$policy_output"
run_rg -q 'limited to the current repository' "$policy_output"

# A writing run that manually composes success without invoking the renderer is blocked.
mkdir -p "$guard_repo/.claude/skills/launch/references"
printf '%s\n' '---' 'name: launch' 'description: Guard lifecycle fixture' '---' > "$guard_repo/.claude/skills/launch/SKILL.md"
for launch_reference in delivery implementation ticket-intake verification; do
  printf '%s\n' 'Guard lifecycle fixture.' > \
    "$guard_repo/.claude/skills/launch/references/$launch_reference.md"
done
write_discovery_fixture "$guard_repo" guard-fixture validator none
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$guard_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Write"}' | run_guard
mkdir -p "$guard_repo/.launch-control-onboard"
printf '%s\n' './checks/validate-a.sh' './checks/validate-b.sh' > "$guard_validation"
printf '%s\t%s\n' \
  PRESERVED dirty.txt \
  PRESERVED .claude/skills/launch/SKILL.md \
  PRESERVED .claude/skills/launch/references/delivery.md \
  PRESERVED .claude/skills/launch/references/implementation.md \
  PRESERVED .claude/skills/launch/references/ticket-intake.md \
  PRESERVED .claude/skills/launch/references/verification.md > "$guard_ledger"
jq -n --arg cwd "$guard_repo" --arg message '=== Workspace Setup Complete ===

Checks:
  branch: truncated

=== End Workspace Setup ===' \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' | run_guard > "$guard_output"
run_rg -q '"decision":"block"' "$guard_output"
run_rg -q 'without fresh renderer proof' "$guard_output"

# Fresh renderer proof still rejects a paraphrased or truncated-branch final message.
jq -n --arg cwd "$guard_repo" --arg command "$policy_config/skills/onboard/scripts/render-report.sh $guard_ledger validator valid absent ready $guard_validation none complete" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
(cd "$guard_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$guard_ledger" validator valid absent ready "$guard_validation" none complete) > "$report_output"
truncated_output="$installer_tmp/truncated-output.txt"
while IFS= read -r line; do
  printf '%s\n' "${line//validator/validato}"
done < "$report_output" > "$truncated_output"
jq -n --arg cwd "$guard_repo" --rawfile message "$truncated_output" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:($message | sub("\\n$"; ""))}' | run_guard > "$guard_output"
run_rg -q '"decision":"block"' "$guard_output"
run_rg -q 'does not exactly match fresh renderer stdout' "$guard_output"
rm -f "$report_state" "$guard_run_state" "$guard_baseline_state" "$guard_task_state" "$guard_discovery_state"

# A well-formed blocked protocol is a legitimate terminal state after writes: a required
# validation failure surfaces as a block, and the guard must allow it without demanding
# renderer success proof. Blocking can never produce a false-green completion report.
write_discovery_fixture "$guard_repo" guard-fixture validator none
jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$guard_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Write"}' | run_guard
test -f "$guard_run_state"
malformed_blocked='The required format would begin with === Workspace Setup Blocked === and end with === End Workspace Setup ===.'
jq -n --arg cwd "$guard_repo" --arg message "$malformed_blocked" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' | run_guard > "$guard_output"
run_rg -q 'does not exactly match the required' "$guard_output"
test -f "$guard_run_state"

blocked_message='=== Workspace Setup Blocked ===

Failed (1):
  ./install.sh --dry-run

Reason:
  Installed skills/checkpoint-load does not match a released Launch Control digest.

Next:
  Review the installed skills/checkpoint-load ownership mismatch before replacement.

=== End Workspace Setup ==='
jq -n --arg cwd "$guard_repo" --arg message "$blocked_message" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' | run_guard > "$guard_output"
test ! -s "$guard_output"
test ! -e "$guard_run_state"
test ! -e "$guard_discovery_state"
test ! -e "$guard_disarmed_state"

# LC-037: the renderer runs no project command, so it discloses none and the guard no longer holds a
# blocked report's `Failed` items against a disclosed-commands list. The helpers below remain for the
# count-parsing cases that follow.
guard_rearm_for_failed_check() {
  write_discovery_fixture "$guard_repo" guard-fixture validator none
  jq -n --arg cwd "$guard_repo" --arg command "$policy_discovery_checkpoint" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
  jq -n --arg cwd "$guard_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Write"}' | run_guard
}

# Round-32 F39. Every fixture above states `Failed (1)` or `Failed (2)`, and the protocol parser
# compared the loop counter against the count as a STRING: "2" <= "14" is false lexically, so a
# report listing 14 paths parsed one item and failed on the second. Counts 1-8 were accepted and
# every count from 9 up was rejected, with a message telling the model its SHAPE was wrong — an
# unsatisfiable contract. Measured live on rymonroe.com, where a deleted `.claude/` workspace
# produced exactly 14 failed paths: two correct reports refused, the second one built from the
# checkpoint's own dictated text, after which the model abandoned the protocol entirely.
guard_blocked_with_count() {
  local count="$1" declared="${2:-$1}" item
  printf '%s\n' '=== Workspace Setup Blocked ===' '' "Failed ($declared):"
  for ((item = 1; item <= count; item++)); do
    printf '  .claude/generated/path-%02d.md\n' "$item"
  done
  printf '%s\n' '' 'Reason:' '  Every required manifest path is deleted in the worktree.' '' \
    'Next:' '  git restore -- .claude' '' '=== End Workspace Setup ==='
}

# 9 is the first count the string compare rejected; 14 is the live one; 21 crosses the next
# decade so a fix that merely special-cased two-digit counts still fails here.
for guard_blocked_count in 9 14 21; do
  guard_rearm_for_failed_check
  jq -n --arg cwd "$guard_repo" --arg message "$(guard_blocked_with_count "$guard_blocked_count")" \
    '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' \
    | run_guard > "$guard_output"
  if [ -s "$guard_output" ]; then
    printf 'FAIL: a well-formed blocked report listing %s paths was rejected\n' \
      "$guard_blocked_count" >&2
    cat "$guard_output" >&2
    exit 1
  fi
  test ! -e "$guard_run_state"
done

# Negative controls: the count must still be verified against the items actually listed, above
# the old boundary as well as below it. A parser that stopped counting would accept both.
for guard_blocked_pair in '13 14' '15 14'; do
  set -- $guard_blocked_pair
  guard_rearm_for_failed_check
  jq -n --arg cwd "$guard_repo" --arg message "$(guard_blocked_with_count "$1" "$2")" \
    '{hook_event_name:"Stop",cwd:$cwd,session_id:"validator",last_assistant_message:$message}' \
    | run_guard > "$guard_output"
  if ! run_rg -q 'does not exactly match the required' "$guard_output"; then
    printf 'FAIL: a blocked report listing %s items under Failed (%s) was accepted\n' "$1" "$2" >&2
    cat "$guard_output" >&2
    exit 1
  fi
  test -f "$guard_run_state"
done
rm -f "$guard_run_state" "$guard_discovery_state"

# A deletion-dirty required manifest path fails fast at the discovery checkpoint (and at
# the first write) instead of surviving until the renderer's final baseline gate.
failfast_repo="$installer_tmp/failfast-repo"
mkdir -p "$failfast_repo"
git -C "$failfast_repo" init -q -b main
git -C "$failfast_repo" config user.name validator
git -C "$failfast_repo" config user.email validator@example.com
printf '%s\n' guidance > "$failfast_repo/CLAUDE.md"
printf '%s\n' notes > "$failfast_repo/notes.txt"
printf '%s\n' '{}' > "$failfast_repo/.mcp.json"
git -C "$failfast_repo" add .
git -C "$failfast_repo" commit -qm baseline
failfast_git_dir="$(git -C "$failfast_repo" rev-parse --absolute-git-dir)"
failfast_discovery_state="$failfast_git_dir/launch-control-onboard-run-failfast.discovery"
failfast_baseline_state="$failfast_git_dir/launch-control-onboard-run-failfast.baseline"
failfast_rearm() {
  jq -n --arg cwd "$failfast_repo" --arg prompt '/onboard' \
    '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"failfast",prompt:$prompt}' | run_guard
}
failfast_checkpoint() {
  write_discovery_fixture "$failfast_repo" failfast main none
  jq -n --arg cwd "$failfast_repo" --arg command "$policy_discovery_checkpoint" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"failfast",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
}

rm "$failfast_repo/CLAUDE.md"
failfast_rearm
failfast_checkpoint > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
run_rg -q 'deletion-dirty required manifest path' "$guard_output"
run_rg -Fq 'CLAUDE.md' "$guard_output"
run_rg -q 'git restore' "$guard_output"
test ! -e "$failfast_discovery_state"

# Round-32 F40. The recovery line this deny dictates is pasted straight into `git restore --`,
# and the join used `paste -sd ', '`, whose delimiter list CYCLES: three paths came out as
# `a,b c`. git rejects that outright ("pathspec 'a,b' did not match any file(s) known to git"),
# so every multi-path block handed the user a command that cannot run. Correct at exactly one
# path, which is the only count any fixture used — and 14 is the count a deleted `.claude/`
# workspace actually produces. Asserting the whole joined string keeps a re-introduced
# delimiter list from passing.
printf '%s\n' 'node_modules/' > "$failfast_repo/.gitignore"
mkdir -p "$failfast_repo/artifacts"
printf '%s\n' '# Architecture' > "$failfast_repo/artifacts/architecture.md"
git -C "$failfast_repo" add .gitignore artifacts/architecture.md
git -C "$failfast_repo" commit -qm 'more required manifest paths'
rm "$failfast_repo/.gitignore" "$failfast_repo/artifacts/architecture.md"
failfast_rearm
failfast_checkpoint > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
if ! run_rg -qF -- 'git restore -- .gitignore CLAUDE.md artifacts/architecture.md' "$guard_output"; then
  printf '%s\n' 'FAIL: the multi-path recovery command is not a runnable git restore invocation' >&2
  cat "$guard_output" >&2
  exit 1
fi
git -C "$failfast_repo" restore .gitignore artifacts/architecture.md

# Repairing the worktree unblocks the checkpoint.
git -C "$failfast_repo" restore CLAUDE.md
failfast_checkpoint > "$guard_output"
test ! -s "$guard_output"
test -f "$failfast_discovery_state"

# A deleted non-manifest path does not trip the gate.
failfast_rearm
rm "$failfast_repo/notes.txt"
failfast_checkpoint > "$guard_output"
test ! -s "$guard_output"
test -f "$failfast_discovery_state"
git -C "$failfast_repo" restore notes.txt

# A deleted optional manifest path (absent -> absent stays PRESERVED-satisfiable) does not trip the gate.
failfast_rearm
rm "$failfast_repo/.mcp.json"
failfast_checkpoint > "$guard_output"
test ! -s "$guard_output"
test -f "$failfast_discovery_state"
git -C "$failfast_repo" restore .mcp.json

# A staged deletion is equally structurally blocked.
failfast_rearm
git -C "$failfast_repo" rm -q CLAUDE.md
failfast_checkpoint > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
run_rg -Fq 'CLAUDE.md' "$guard_output"
test ! -e "$failfast_discovery_state"
git -C "$failfast_repo" restore --staged CLAUDE.md
git -C "$failfast_repo" restore CLAUDE.md

# Defense in depth: a deletion between checkpoint and first write is denied before any
# guard state mutation.
failfast_rearm
failfast_checkpoint > "$guard_output"
test ! -s "$guard_output"
rm "$failfast_repo/CLAUDE.md"
jq -n --arg cwd "$failfast_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"failfast",tool_name:"Write"}' | run_guard > "$guard_output"
run_rg -q '"permissionDecision":"deny"' "$guard_output"
run_rg -q 'deletion-dirty required manifest path' "$guard_output"
test ! -e "$failfast_baseline_state"
git -C "$failfast_repo" restore CLAUDE.md

# GAP-3: a fresh /onboard purges every stale launch-control-onboard-run-*.mode marker in the git
# directory, not just the current session's, so abandoned cross-session runs do not accumulate.
mode_repo="$installer_tmp/mode-repo"
mkdir -p "$mode_repo"
git -C "$mode_repo" init -q -b main
git -C "$mode_repo" config user.name validator
git -C "$mode_repo" config user.email validator@example.com
mode_git_dir="$(git -C "$mode_repo" rev-parse --absolute-git-dir)"
: > "$mode_git_dir/launch-control-onboard-run-stale-one.mode"
: > "$mode_git_dir/launch-control-onboard-run-stale-two.mode"
# LC-047: a repo onboarded before the rename keeps its old-name markers, `.disarmed` included.
for legacy_suffix in disarmed bypass permission-mode guidance-denies; do
  : > "$mode_git_dir/groundwork-onboard-run-f5150071.$legacy_suffix"
done
jq -n --arg cwd "$mode_repo" --arg prompt '/onboard' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"mode-current",prompt:$prompt}' | run_guard
test ! -e "$mode_git_dir/launch-control-onboard-run-stale-one.mode"
test ! -e "$mode_git_dir/launch-control-onboard-run-stale-two.mode"
for legacy_suffix in disarmed bypass permission-mode guidance-denies; do
  test ! -e "$mode_git_dir/groundwork-onboard-run-f5150071.$legacy_suffix"
done
test -f "$mode_git_dir/launch-control-onboard-run-mode-current.mode"
run_rg -q '^default$' "$mode_git_dir/launch-control-onboard-run-mode-current.mode"
for launch_control_prompt in '/onboard --launch-control' '  /onboard --launch-control --dry-run'; do
  rm -f "$mode_git_dir/launch-control-onboard-run-mode-current.mode"
  jq -n --arg cwd "$mode_repo" --arg prompt "$launch_control_prompt" \
    '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"mode-current",prompt:$prompt}' | run_guard
  run_rg -q '^launch-control$' "$mode_git_dir/launch-control-onboard-run-mode-current.mode"
done
# LC-048: --enable-autonomy is no longer an onboarding mode; Launch builds its own overlay.
rm -f "$mode_git_dir/launch-control-onboard-run-mode-current.mode"
jq -n --arg cwd "$mode_repo" --arg prompt '/onboard --enable-autonomy' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"mode-current",prompt:$prompt}' | run_guard
run_rg -q '^default$' "$mode_git_dir/launch-control-onboard-run-mode-current.mode"

# Round-35: the three globs above name ONE suffix each, but a run mints sixteen, and the
# renderer's own reaper enumerates families through `.active`. A session that reaches discovery
# and dies leaves `.discovery` before any `.active` exists to key it to; a run that spends a deny
# budget without rendering leaves `.guidance-denies`. Neither is reachable by any purge, and both
# were found accumulating live in rymonroe.com's .git after run 266d8e60. The sweep is gated on
# the ABSENCE of the family's `.active` marker rather than on a suffix list -- an enumeration is
# what failed here -- so the risky half of this fixture is what it must NOT delete: a family
# whose `.active` is present belongs to a live or renderer-reapable run and must survive whole.
orphan_repo="$installer_tmp/orphan-repo"
mkdir -p "$orphan_repo"
git -C "$orphan_repo" init -q -b main
git -C "$orphan_repo" config user.name validator
git -C "$orphan_repo" config user.email validator@example.com
orphan_git_dir="$(git -C "$orphan_repo" rev-parse --absolute-git-dir)"
# Every suffix completion-guard.sh can mint, minus `.active` itself, as an ownerless fragment.
# `.disarmed` is deliberately absent and has its own block below: round 36 swept it and round 37
# proved that a regression, because it is a live off switch rather than an inert record.
orphan_suffixes=(
  baseline inventory symlinked mode tasks discovery rendered
  emission-denies lens-denies guidance-denies prospective-denies lens-render-denies
  contract-denies bypass permission-mode
)
for orphan_suffix in "${orphan_suffixes[@]}"; do
  : > "$orphan_git_dir/launch-control-onboard-run-orphan.$orphan_suffix"
done
# The docs-create proof is keyed by the same session id and orphans the same way.
: > "$orphan_git_dir/launch-control-bootstrap-docs-orphan.proof"
# Positive control: a family that still owns an `.active` marker keeps every fragment. A
# regression to a blanket `launch-control-onboard-run-*.*` glob deletes a concurrent run's baseline
# out from under it, which is the silent takeover render-report.sh's reaper refuses to perform.
: > "$orphan_git_dir/launch-control-onboard-run-live.active"
: > "$orphan_git_dir/launch-control-onboard-run-live.baseline"
: > "$orphan_git_dir/launch-control-onboard-run-live.discovery"
: > "$orphan_git_dir/launch-control-bootstrap-docs-live.proof"
# A session id may legally contain dots (the policy charset check allows them), so recovering
# the family name must strip the SUFFIX, not everything after the first dot. Getting that
# backwards reads a dotted family as ownerless and deletes a live run's fragments.
: > "$orphan_git_dir/launch-control-onboard-run-dotted.v2.active"
: > "$orphan_git_dir/launch-control-onboard-run-dotted.v2.baseline"
: > "$orphan_git_dir/launch-control-onboard-run-orphan.v2.discovery"
# Round-37: a DIFFERENT session that already completed onboarding here. Its `.disarmed` is
# ownerless by construction -- the Stop terminal removes `.active` and stamps `.disarmed`
# together -- so the ownership test cannot protect it, and round 36 swept it. That deletion
# re-arms a session that is still open: line 933 reads this file as its off switch. It also keeps
# an inert sibling, which MUST still be swept, so the exemption cannot be widened into an
# amnesty for the whole family.
: > "$orphan_git_dir/launch-control-onboard-run-finished-elsewhere.disarmed"
: > "$orphan_git_dir/launch-control-onboard-run-finished-elsewhere.permission-mode"
# The re-arming session's OWN `.disarmed` is deliberately NOT re-asserted here. `test ! -e
# "$guard_disarmed_state"` at :943 already pins that same-session path, and a mutation dropping
# $disarmed_state from the :839 re-arm list dies there before reaching this block -- measured.
# One statement of a property is enough.
jq -n --arg cwd "$orphan_repo" --arg prompt '/onboard' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"orphan-current",prompt:$prompt}' | run_guard
for orphan_suffix in "${orphan_suffixes[@]}"; do
  if [ -e "$orphan_git_dir/launch-control-onboard-run-orphan.$orphan_suffix" ]; then
    printf '%s\n' "FAIL: /onboard left an ownerless run fragment behind: .$orphan_suffix" >&2
    exit 1
  fi
done
if [ -e "$orphan_git_dir/launch-control-bootstrap-docs-orphan.proof" ]; then
  printf '%s\n' 'FAIL: /onboard left an ownerless docs-create proof behind' >&2
  exit 1
fi
if [ -e "$orphan_git_dir/launch-control-onboard-run-orphan.v2.discovery" ]; then
  printf '%s\n' 'FAIL: /onboard left an ownerless fragment of a dotted session id behind' >&2
  exit 1
fi
for orphan_survivor in \
  "$orphan_git_dir/launch-control-onboard-run-live.active" \
  "$orphan_git_dir/launch-control-onboard-run-live.baseline" \
  "$orphan_git_dir/launch-control-onboard-run-live.discovery" \
  "$orphan_git_dir/launch-control-onboard-run-dotted.v2.active" \
  "$orphan_git_dir/launch-control-onboard-run-dotted.v2.baseline" \
  "$orphan_git_dir/launch-control-bootstrap-docs-live.proof"; do
  if [ ! -e "$orphan_survivor" ]; then
    printf '%s\n' "FAIL: /onboard purged a fragment owned by an active run: $(basename "$orphan_survivor")" >&2
    exit 1
  fi
done
# Round-37: the other session's off switch survived, while its inert sibling did not.
if [ ! -e "$orphan_git_dir/launch-control-onboard-run-finished-elsewhere.disarmed" ]; then
  printf '%s\n' 'FAIL: /onboard purged another session'"'"'s .disarmed off switch, re-arming a run that already completed' >&2
  exit 1
fi
if [ -e "$orphan_git_dir/launch-control-onboard-run-finished-elsewhere.permission-mode" ]; then
  printf '%s\n' 'FAIL: the .disarmed exemption leaked into its family: an ownerless inert fragment survived' >&2
  exit 1
fi
# The property the suffix checks above cannot state: the disarmed session is still disarmed. A
# suffix survival check passes on a file that has been emptied, renamed, or ignored; only a write
# proves the guard still reads it. Without the exemption this Write is DENIED and told to produce
# a Phase 0 discovery report for a run that already ended -- the measured regression itself.
# Honest note: no mutation kills this check UNIQUELY. Every mutant that re-arms the other session
# also deletes its `.disarmed`, so the survival check above fires first, and a mutant that breaks
# the :933 read instead dies in the same-session block at :935-943. It is kept because it is the
# only assertion here that states the user-visible symptom rather than a file's existence, so a
# future refactor that moves the off switch out of `.disarmed` cannot satisfy the suffix checks
# while leaving a finished session gated.
orphan_disarmed_output="$installer_tmp/orphan-disarmed-output.txt"
jq -n --arg cwd "$orphan_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"finished-elsewhere",tool_name:"Write",tool_input:{file_path:"src/app.ts"}}' \
  | run_guard > "$orphan_disarmed_output"
if [ -s "$orphan_disarmed_output" ]; then
  printf '%s\n' 'FAIL: a session that already completed onboarding was gated again after an unrelated /onboard re-arm:' >&2
  cat "$orphan_disarmed_output" >&2
  exit 1
fi

# The re-arm still stamps this run's own mode, after the sweep rather than into its path.
test -f "$orphan_git_dir/launch-control-onboard-run-orphan-current.mode"
run_rg -q '^default$' "$orphan_git_dir/launch-control-onboard-run-orphan-current.mode"

# Round-23: the guard's own $guard_tmp scratch directory is cleaned by an EXIT trap, which a
# SIGKILL never runs, so a hook killed at the harness timeout leaves it in .git forever. A fresh
# /onboard now reaps abandoned ones, selecting by AGE. Three cases in one fixture because the
# risky half of this purge is what it must NOT delete: an aged directory with content (proving
# rm -rf, not rmdir), an aged empty one (the shape observed live), and a freshly created one
# standing in for a concurrent guard invocation still writing to it, which must survive.
# The aged pair is backdated with `touch -t` rather than the PID suffix carrying the meaning --
# an earlier revision reaped by `kill -0` on that suffix and failed its first live test when
# macOS recycled the abandoned PID into an unrelated process, so the fixture pins the property
# that replaced it. Suffixes here are deliberately a live PID on an OLD directory and a bogus
# one on the fresh directory, so a regression back to PID-based selection fails both halves.
guardtmp_repo="$installer_tmp/guard-tmp-repo"
mkdir -p "$guardtmp_repo"
git -C "$guardtmp_repo" init -q -b main
git -C "$guardtmp_repo" config user.name validator
git -C "$guardtmp_repo" config user.email validator@example.com
guardtmp_git_dir="$(git -C "$guardtmp_repo" rev-parse --absolute-git-dir)"
guardtmp_aged_full="$guardtmp_git_dir/launch-control-onboard-guard-deadsession-$$"
guardtmp_aged_empty="$guardtmp_git_dir/launch-control-onboard-guard-othersession-999998"
guardtmp_fresh="$guardtmp_git_dir/launch-control-onboard-guard-livesession-999997"
mkdir -p "$guardtmp_aged_full" "$guardtmp_aged_empty" "$guardtmp_fresh"
printf '%s\n' scratch > "$guardtmp_aged_full/assistant-text"
touch -t 202601010000 "$guardtmp_aged_full" "$guardtmp_aged_empty"
jq -n --arg cwd "$guardtmp_repo" --arg prompt '/onboard' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"guardtmp-current",prompt:$prompt}' | run_guard
if [ -e "$guardtmp_aged_full" ]; then
  printf '%s\n' 'FAIL: /onboard left an abandoned guard scratch directory with content behind' >&2
  exit 1
fi
if [ -e "$guardtmp_aged_empty" ]; then
  printf '%s\n' 'FAIL: /onboard left an abandoned empty guard scratch directory behind' >&2
  exit 1
fi
if [ ! -d "$guardtmp_fresh" ]; then
  printf '%s\n' 'FAIL: /onboard reaped a guard scratch directory a concurrent invocation is still using' >&2
  exit 1
fi
rm -rf "$guardtmp_fresh"

expect_report_failure() {
  local name="$1" repo="$2"
  shift 2
  if (cd "$repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$@") >/dev/null 2>"$installer_tmp/$name.err"; then
    printf 'FAIL: report negative case succeeded: %s\n' "$name" >&2
    exit 1
  fi
}

mkdir -p "$guard_repo/.launch-control-onboard"
printf '%s\n' './checks/validate-a.sh' './checks/validate-b.sh' > "$guard_validation"
printf '%s\t%s\n' \
  PRESERVED dirty.txt \
  SKIPPED .mcp.json \
  SKIPPED .claude/hooks/skill-eval.sh > "$guard_ledger"
expect_report_failure truncated-branch "$guard_repo" "$guard_ledger" validato valid absent ready "$guard_validation" none complete
expect_report_failure empty-dependency "$guard_repo" "$guard_ledger" validator valid absent 'missing: ' "$guard_validation" none complete


# Round-16 F34a: a SECOND successful render in one session is refused, and only that case is.
# The guard reads two markers the run already leaves behind -- `.rendered` (stamped here, per
# session) and the renderer's own proof -- and the three-way split between them IS the
# contract, so pin all three rows. A blanket deny keyed on `.rendered` alone would pass rows 1
# and 2 and silently break row 3, which is the documented recovery from a blocked render.
r16_repo="$installer_tmp/r16-redundant-render-repo"
mkdir -p "$r16_repo/.launch-control-onboard"
git -C "$r16_repo" init -q -b r16
r16_git_dir="$r16_repo/.git"
r16_state="$r16_git_dir/launch-control-onboard-report.expected"
r16_render_state="$r16_git_dir/launch-control-onboard-run-r16.rendered"
r16_command="$policy_config/skills/onboard/scripts/render-report.sh $r16_repo/.launch-control-onboard/ledger.tsv r16 valid absent ready $r16_repo/.launch-control-onboard/validation-commands.txt none complete"
r16_render() {
  jq -n --arg cwd "$r16_repo" --arg command "$r16_command" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r16",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
}

# Row 1 -- this session has not rendered. A proof file left by an abnormal earlier session is
# stale and must be cleared, never counted as this session's render (BUG-10, preserved).
: > "$r16_state"
rm -f "$r16_render_state"
r16_render > "$installer_tmp/r16-first.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r16-first.out"; then
  printf '%s\n' 'FAIL: guard refused a session first render over a stale cross-session proof' >&2
  exit 1
fi
test -f "$r16_render_state"
test ! -e "$r16_state"

# Row 2 -- rendered, and the renderer wrote proof: the report already exists and nothing has
# invalidated it. Redundant, refused.
: > "$r16_state"
r16_render > "$installer_tmp/r16-second.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r16-second.out"
run_rg -q 'already rendered a completion report' "$installer_tmp/r16-second.out"
# The refusal has to leave the proof it protects intact, or the Stop check would reject the
# very report the run was just told to return.
test -f "$r16_state"

# Row 3 -- rendered, but no proof: the render was blocked or exited nonzero, or a later write
# invalidated it. A retry is the documented recovery and stays allowed.
rm -f "$r16_state"
r16_render > "$installer_tmp/r16-retry.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r16-retry.out"; then
  printf '%s\n' 'FAIL: guard refused a retry after a blocked or failed render' >&2
  exit 1
fi
run_rg -q 'Once means once' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"

# Round-16 F34b: the discovery checkpoint states the permission mode from the policy's own
# record, so a run never has to read it off the shape of a denial. Absence of the record is
# not an attestation (F28), so the quiet case must stay byte-identical to the plain report.
r16b_repo="$installer_tmp/r16-bypass-repo"
mkdir -p "$r16b_repo"
git -C "$r16b_repo" init -q -b r16b
write_discovery_fixture "$r16b_repo" r16b-fixture main none
r16b_git_bypass="$r16b_repo/.git/launch-control-onboard-run-r16b.bypass"
(cd "$r16b_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/r16b-nobypass.out"
if run_rg -q 'PERMISSION-MODE' "$installer_tmp/r16b-nobypass.out"; then
  printf '%s\n' 'FAIL: checkpoint reported a permission mode with no policy record' >&2
  exit 1
fi
cmp -s "$r16b_repo/.launch-control-onboard/discovery-report.txt" "$installer_tmp/r16b-nobypass.out"
: > "$r16b_git_bypass"
(cd "$r16b_repo" && "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh") > "$installer_tmp/r16b-bypass.out"
run_rg -q '^PERMISSION-MODE: bypassPermissions -- recorded by the unattended policy\.$' "$installer_tmp/r16b-bypass.out"
run_rg -q 'Never infer the mode from the shape of a denial' "$installer_tmp/r16b-bypass.out"
# LC-058: one factual mention; the banner neither steers the user's chosen mode nor demands a repeat.
sed -n '/^PERMISSION-MODE:/,$p' "$installer_tmp/r16b-bypass.out" > "$installer_tmp/r16b-banner.out"
run_rg -q 'say so once' "$installer_tmp/r16b-banner.out"
if run_rg -qi 'again|default permission mode|rerun' "$installer_tmp/r16b-banner.out"; then
  printf '%s\n' 'FAIL: the bypass banner pushes the default mode or demands a second disclosure' >&2
  exit 1
fi
run_rg -q '^=== End Workspace Discovery Report ===' "$installer_tmp/r16b-bypass.out"
run_rg -q 'PERMISSION-MODE: bypassPermissions' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"

# The marker must not outlive the run that earned it. An abandoned bypass run used to leave
# its `.bypass` behind exactly as GAP-3's `.mode` markers did; a later default-mode run would
# then disclose a bypass the renderer denies, manufacturing the report-contradicts-prose
# conflict that F34a now refuses to let a second render resolve.
: > "$r16b_git_bypass"
r16b_git_perm="$r16b_repo/.git/launch-control-onboard-run-r16b.permission-mode"
printf '%s\n' auto > "$r16b_git_perm"
jq -n --arg cwd "$r16b_repo" \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"r16b-next",prompt:"/onboard"}' | run_guard
test ! -e "$r16b_git_bypass"
# Round-18: the recorded permission mode is a per-run fact for the same reason the bypass
# marker is, so an abandoned run must not leave one behind for a later run to render as its
# own. The policy re-stamps it on the next PreToolUse, so purging loses nothing.
test ! -e "$r16b_git_perm"

# Round-16 F34a recovery path: refusing the second render must not strand the run. The deny
# tells it to "return the stdout of the render you already have, verbatim" — so the proof that
# refusal protects has to still satisfy Stop. Nothing above proves that end to end: the rows
# pinned earlier stop at the PreToolUse decision. This needs its own repository because an
# ACCEPTING Stop sets the disarmed marker, which would make the guard a no-op for every later
# case in a shared one.
r16c_repo="$installer_tmp/r16-recovery-repo"
mkdir -p "$r16c_repo/.claude" "$r16c_repo/checks" "$r16c_repo/.launch-control-onboard"
git -C "$r16c_repo" init -q -b validator
git -C "$r16c_repo" config user.name validator
git -C "$r16c_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r16c_repo/checks/validate-a.sh"
chmod +x "$r16c_repo/checks/validate-a.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' > "$r16c_repo/.claude/settings.json"
git -C "$r16c_repo" add .
git -C "$r16c_repo" commit -qm baseline
write_discovery_fixture "$r16c_repo" r16c-fixture validator none
jq -n --arg cwd "$r16c_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r16c",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$r16c_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r16c",tool_name:"Edit"}' | run_guard
r16c_ledger="$r16c_repo/.launch-control-onboard/guard-ledger.tsv"
printf '%s\t%s\n' SKIPPED .mcp.json SKIPPED .claude/hooks/skill-eval.sh > "$r16c_ledger"
r16c_validation="$r16c_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate-a.sh' > "$r16c_validation"
r16c_git_dir="$(git -C "$r16c_repo" rev-parse --absolute-git-dir)"
r16c_state="$r16c_git_dir/launch-control-onboard-report.expected"
r16c_command="$policy_config/skills/onboard/scripts/render-report.sh $r16c_ledger validator valid absent ready $r16c_validation none complete"
r16c_out="$installer_tmp/r16c-report.txt"

# Render once, for real, so the proof is the renderer's own output rather than a fixture.
jq -n --arg cwd "$r16c_repo" --arg command "$r16c_command" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r16c",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
(cd "$r16c_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$r16c_ledger" validator valid absent ready "$r16c_validation" none complete) > "$r16c_out"
test -s "$r16c_state"

# The second render is refused ...
jq -n --arg cwd "$r16c_repo" --arg command "$r16c_command" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r16c",tool_name:"Bash",tool_input:{command:$command}}' \
  | run_guard > "$installer_tmp/r16c-second.out"
run_rg -q 'already rendered a completion report' "$installer_tmp/r16c-second.out"

# ... and the first render's stdout still completes the run. If the refusal clobbered the
# proof, or ran the renderer's PreToolUse side effects before denying, this would block and
# the guard would have made the report unreturnable.
jq -n --arg cwd "$r16c_repo" --rawfile message "$r16c_out" \
  '{hook_event_name:"Stop",cwd:$cwd,session_id:"r16c",last_assistant_message:($message | sub("\\n$"; ""))}' \
  | run_guard > "$installer_tmp/r16c-stop.out"
if run_rg -q '"decision":"block"' "$installer_tmp/r16c-stop.out"; then
  printf '%s\n' 'FAIL: a refused second render left the first report unreturnable at Stop' >&2
  exit 1
fi
test ! -e "$r16c_state"


# Round-17: the reviewer-lens shape is decided at the Write, not only at the render. A run
# that authors a bullet without its evidence path used to learn so from render-report.sh —
# the terminal operation — and paid a whole render for it. Each case below uses its OWN
# session id: the deny counter is per session, so sharing one would let an earlier case
# spend the circuit-breaker budget and make a later "allowed" assertion vacuous.
r17_repo="$installer_tmp/r17-lens-repo"
mkdir -p "$r17_repo/.claude/agents"
git -C "$r17_repo" init -q
printf '%s\n' '# fixture' > "$r17_repo/README.md"
printf '%s\n' '#!/usr/bin/env bash' > "$r17_repo/install.sh"
git -C "$r17_repo" add .
git -C "$r17_repo" commit -qm baseline

r17_reviewer='.claude/agents/inspector.md'
r17_bad="$(printf '## Project-specific review lens\n- Python here runs on 3.9, so PEP 604 unions are not a style preference\n- Shell scripts set -euo pipefail. Evidence: `install.sh`.\n')"
r17_good="$(printf '## Project-specific review lens\n- Hooks gate the live session. Evidence: `README.md`.\n- Shell scripts set -euo pipefail. Evidence: `install.sh`.\n')"

r17_write() { # session content outfile
  write_discovery_fixture "$r17_repo" r17-fixture validator none
  jq -n --arg cwd "$r17_repo" --arg command "$policy_discovery_checkpoint" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' | run_guard
  jq -n --arg cwd "$r17_repo" --arg p "$r17_reviewer" --arg c "$2" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Write",tool_input:{file_path:$p,content:$c}}' \
    | run_guard > "$3"
}

# A bullet with no evidence path is denied at the write, and the denial names the accepted
# shape — a guard that says only "wrong" while nothing says "right" is the round-11 deadlock.
r17_write r17a "$r17_bad" "$installer_tmp/r17-bad.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17-bad.out"
run_rg -q 'does not end with exactly one evidence path' "$installer_tmp/r17-bad.out"
run_rg -q 'Required shape, written exactly' "$installer_tmp/r17-bad.out"

# An unresolved token is the same class and denies too.
r17_write r17b '## Project-specific review lens
DETECTED_REVIEW_LENS' "$installer_tmp/r17-token.out"
run_rg -q 'unresolved DETECTED_REVIEW_LENS token' "$installer_tmp/r17-token.out"

# An evidence path that does not exist in the repository denies.
r17_write r17c '## Project-specific review lens
- One. Evidence: `no/such/file.md`.
- Two. Evidence: `README.md`.' "$installer_tmp/r17-path.out"
run_rg -q 'does not exist' "$installer_tmp/r17-path.out"

# A well-formed lens is not denied. Fresh session, so the circuit breaker is not the reason.
r17_write r17d "$r17_good" "$installer_tmp/r17-good.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17-good.out"; then
  printf '%s\n' 'FAIL: the write-time lens check denied a well-formed review lens' >&2
  exit 1
fi

# Circuit breaker: after two denies the hook stands down so a run that structurally cannot
# satisfy the shape can never livelock, leaving the rule to the renderer backstop.
r17_write r17e "$r17_bad" "$installer_tmp/r17-cb1.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17-cb1.out"
r17_write r17e "$r17_bad" "$installer_tmp/r17-cb2.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17-cb2.out"
r17_write r17e "$r17_bad" "$installer_tmp/r17-cb3.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17-cb3.out"; then
  printf '%s\n' 'FAIL: the write-time lens check never stands down and can livelock a run' >&2
  exit 1
fi

# SKILL.md states the bullet shape at the point of use, not only 80 lines earlier.
run_rg -q 'without recalling it from' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"

# Round-17: the two SIBLING generated-guidance rules move to the write for the same reason the
# lens did. Both burned a full render each on target repo A in one session. Each case gets
# its own session id — the deny counter is per session, and a shared one makes every later
# "allowed" assertion vacuous once the circuit breaker has been spent.
r17g_repo="$installer_tmp/r17-guidance-repo"
mkdir -p "$r17g_repo/.claude/skills/project-code-review" "$r17g_repo/.claude/skills/launch" \
  "$r17g_repo/.claude/skills/testing-patterns" "$r17g_repo/.launch-control-onboard"
git -C "$r17g_repo" init -q
printf '%s\n' '# fixture' > "$r17g_repo/README.md"
printf '%s\n' '# review skill' > "$r17g_repo/.claude/skills/project-code-review/SKILL.md"
git -C "$r17g_repo" add .
git -C "$r17g_repo" commit -qm baseline

r17g_write() { # session path content outfile
  write_discovery_fixture "$r17g_repo" r17g-fixture validator none
  jq -n --arg cwd "$r17g_repo" --arg command "$policy_discovery_checkpoint" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' | run_guard
  jq -n --arg cwd "$r17g_repo" --arg p "$2" --arg c "$3" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Write",tool_input:{file_path:$p,content:$c}}' \
    | run_guard > "$4"
}

# Guidance that never names the review skill this run generates is denied at the write, and the
# denial names the spelling it wants rather than only rejecting the one it got.
r17g_write r17g-a .claude/skills/launch/SKILL.md 'Run the reviewer before opening a PR.' \
  "$installer_tmp/r17g-omit.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17g-omit.out"
run_rg -q 'it never names .project-code-review.' "$installer_tmp/r17g-omit.out"

# The pre-rename spelling is the same class and denies too.
r17g_write r17g-b CLAUDE.md 'Self-review with `code-review` before a PR.' "$installer_tmp/r17g-stale.out"
run_rg -q 'the pre-rename spelling' "$installer_tmp/r17g-stale.out"

# Naming it is accepted.
r17g_write r17g-c CLAUDE.md 'Self-review with `project-code-review` before a PR.' "$installer_tmp/r17g-named.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17g-named.out"; then
  printf '%s\n' 'FAIL: guidance naming project-code-review was denied' >&2
  exit 1
fi

# NOT YET DECIDABLE is not the same as wrong. Before this run has generated the review skill
# there is no rule to enforce, and denying there would deny a write for a contract the run has
# not reached — the round-11 deadlock shape, relocated to the guard.
r17g_undecidable="$installer_tmp/r17-guidance-bare"
mkdir -p "$r17g_undecidable/.claude" "$r17g_undecidable/.launch-control-onboard"
git -C "$r17g_undecidable" init -q
printf '%s\n' '# fixture' > "$r17g_undecidable/README.md"
git -C "$r17g_undecidable" add .
git -C "$r17g_undecidable" commit -qm baseline
write_discovery_fixture "$r17g_undecidable" r17g-bare validator none
jq -n --arg cwd "$r17g_undecidable" --arg command "$policy_discovery_checkpoint" --arg s r17g-d \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$r17g_undecidable" --arg p CLAUDE.md --arg c 'Run the reviewer before a PR.' --arg s r17g-d \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Write",tool_input:{file_path:$p,content:$c}}' \
  | run_guard > "$installer_tmp/r17g-undecidable.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r17g-undecidable.out"; then
  printf '%s\n' 'FAIL: the write-time guidance check denied a rule whose inputs the run has not written yet' >&2
  exit 1
fi

# Round-37: the runner-spelling fixture that stood here is gone with the rule it covered. It
# seeded `{"sandbox":{"enabled":true}}` into the project settings by hand, which is the tell --
# onboarding stopped generating that key in round 36, so the only way to exercise the rule was to
# write the key the pack no longer writes. The `project-code-review` naming rule in the same
# function is still covered by the r17g-b/c/stale cases above.

# Round-37: every one of the three write-time gates above read `.tool_input.content`, which only a
# `Write` carries. An `Edit` carries old_string/new_string, so the field was empty and each rule
# skipped itself with no deny and no diagnostic -- three gates, all blind to the tool a run
# actually reaches for once a file exists. Live on rymonroe.com (run 255c3163) all six guidance
# mutations were Edits and render-report.sh refused with `generated guidance contains stale exact
# skill name code-review`: the exact render the round-17 rule was built to save. Every case below
# drives an EDIT payload against a file already on disk, which is the shape the Write fixtures
# above can never reproduce.
r37e_edit() { # repo session path old new outfile
  write_discovery_fixture "$1" r37e-fixture validator none
  jq -n --arg cwd "$1" --arg command "$policy_discovery_checkpoint" --arg s "$2" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' | run_guard
  jq -n --arg cwd "$1" --arg p "$3" --arg o "$4" --arg n "$5" --arg s "$2" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Edit",tool_input:{file_path:$p,old_string:$o,new_string:$n}}' \
    | run_guard > "$6"
}

# GATE 1, the reviewer lens. The file already holds a well-formed lens; the Edit strips one
# bullet's evidence path. The rule must judge the content the edit LEAVES, not the fragment.
printf '%s\n' "$r17_good" > "$r17_repo/.claude/agents/inspector.md"
r37e_edit "$r17_repo" r37e-a "$r17_reviewer" \
  '- Hooks gate the live session. Evidence: `README.md`.' \
  '- Hooks gate the live session' "$installer_tmp/r37e-lens.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r37e-lens.out"
run_rg -q 'does not end with exactly one evidence path' "$installer_tmp/r37e-lens.out"

# An Edit that leaves the lens well-formed is not denied -- the gate judges the result, so it must
# not fire merely because the tool was an Edit.
r37e_edit "$r17_repo" r37e-b "$r17_reviewer" \
  '- Hooks gate the live session. Evidence: `README.md`.' \
  '- Hooks gate the live session. Evidence: `install.sh`.' "$installer_tmp/r37e-lens-ok.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r37e-lens-ok.out"; then
  printf '%s\n' 'FAIL: the write-time lens check denied an Edit that leaves a well-formed lens' >&2
  exit 1
fi

# GATE 2, generated guidance. This is the live defect reproduced exactly: CLAUDE.md already names
# the review skill correctly and the Edit rewrites it to the pre-rename spelling.
printf '%s\n' 'Self-review with `project-code-review` before a PR.' > "$r17g_repo/CLAUDE.md"
r37e_edit "$r17g_repo" r37e-c CLAUDE.md '`project-code-review`' '`code-review`' \
  "$installer_tmp/r37e-guidance.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r37e-guidance.out"
run_rg -q 'the pre-rename spelling' "$installer_tmp/r37e-guidance.out"

# `replace_all` is Edit's other spelling and must resolve the same way. Two occurrences, both
# rewritten, and the rule sees the stale spelling it would otherwise have missed.
printf '%s\n' 'Self-review with `project-code-review`.' 'Then `project-code-review` again.' \
  > "$r17g_repo/CLAUDE.md"
write_discovery_fixture "$r17g_repo" r37e-fixture validator none
jq -n --arg cwd "$r17g_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r37e-e",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$r17g_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r37e-e",tool_name:"Edit",tool_input:{file_path:"CLAUDE.md",old_string:"`project-code-review`",new_string:"`code-review`",replace_all:true}}' \
  | run_guard > "$installer_tmp/r37e-replaceall.out"
run_rg -q 'the pre-rename spelling' "$installer_tmp/r37e-replaceall.out"

# A MultiEdit-shaped payload must not silently resolve to empty either. The batch ends on the
# stale spelling, so the gate has to apply the edits IN ORDER to see it.
printf '%s\n' 'Self-review with `project-code-review` before a PR.' > "$r17g_repo/CLAUDE.md"
write_discovery_fixture "$r17g_repo" r37e-fixture validator none
jq -n --arg cwd "$r17g_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r37e-f",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$r17g_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r37e-f",tool_name:"Edit",tool_input:{file_path:"CLAUDE.md",edits:[{old_string:"`project-code-review`",new_string:"`TEMP-TOKEN`"},{old_string:"`TEMP-TOKEN`",new_string:"`code-review`"}]}}' \
  | run_guard > "$installer_tmp/r37e-multiedit.out"
run_rg -q 'the pre-rename spelling' "$installer_tmp/r37e-multiedit.out"

# Multi-byte content. jq's `index/1` on a string returns a BYTE offset while `$s[a:b]` slices by
# CODEPOINT, so an index-based splice cuts N characters late on a file holding N multi-byte
# characters before the match. Found by replaying the three real Edits from rymonroe.com run
# 3642a3b0 against its em-dash-heavy launch/SKILL.md: the reconstruction came back spliced
# mid-word (`dua<new>ll.`) while every ASCII-only case above stayed green. The file below carries
# seven em-dashes ahead of the target, which shifts the cut past the stale spelling entirely --
# so a resolver that indexes leaves `code-review` in the resolved content and this well-formed
# Edit is DENIED. The assertion is that it is allowed.
printf '%s\n' 'Guidance — with — seven — em — dashes — before — the — target.' \
  '`code-review` is the old name. Keep `project-code-review` too.' > "$r17g_repo/CLAUDE.md"
r37e_edit "$r17g_repo" r37e-h CLAUDE.md \
  '`code-review` is the old name.' 'the review skill is named correctly.' \
  "$installer_tmp/r37e-multibyte.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r37e-multibyte.out"; then
  printf '%s\n' 'FAIL: the resolver mis-spliced a multi-byte file and denied a well-formed Edit' >&2
  exit 1
fi

# r37e-h judges the verdict only; a splice that lands wrong but still clears the token check
# passes it. Run the resolver itself and compare the reconstruction byte for byte (LC-011). Each
# file repeats old_string after the multi-byte run, so a dropped or doubled tail fails too.
r37e_resolve() { # file old new
  ( eval "$(sed -n '/^resolved_write_content() {/,/^}/p' "$guard")"
    guard_tmp="$installer_tmp" cwd="$installer_tmp"
    input="$(jq -n --arg p "$1" --arg o "$2" --arg n "$3" '{tool_input:{file_path:$p,old_string:$o,new_string:$n}}')"
    resolved_write_content "$1" )
}
printf '%s\n' 'Lead — with — dashes — then old — and old again.' > "$installer_tmp/r37e-dash.md"
r37e_resolve "$installer_tmp/r37e-dash.md" old NEW > "$installer_tmp/r37e-dash.out"
printf '%s\n\n' 'Lead — with — dashes — then NEW — and old again.' | cmp -s - "$installer_tmp/r37e-dash.out" \
  || { printf '%s\n' 'FAIL: the resolver reconstruction of an em-dash file is not byte-exact' >&2; exit 1; }
printf '%s\n' '🚀 ship 🚀 it: target here 🎉 then target' > "$installer_tmp/r37e-emoji.md"
r37e_resolve "$installer_tmp/r37e-emoji.md" target goal > "$installer_tmp/r37e-emoji.out"
printf '%s\n\n' '🚀 ship 🚀 it: goal here 🎉 then target' | cmp -s - "$installer_tmp/r37e-emoji.out" \
  || { printf '%s\n' 'FAIL: the resolver reconstruction of an emoji file is not byte-exact' >&2; exit 1; }

# NOT RESOLVABLE is not the same as wrong. An Edit whose old_string is absent from the file will
# be rejected by the harness anyway, and the guard must stand down rather than judge a guess --
# the same contract every other not-yet-decidable branch in this file follows.
printf '%s\n' 'Self-review with `project-code-review` before a PR.' > "$r17g_repo/CLAUDE.md"
r37e_edit "$r17g_repo" r37e-g CLAUDE.md 'a string that is not in the file' '`code-review`' \
  "$installer_tmp/r37e-nomatch.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r37e-nomatch.out"; then
  printf '%s\n' 'FAIL: the write-time gates judged an Edit whose old_string is not in the file' >&2
  exit 1
fi

# LC-002: on a merged CLAUDE.md the naming rule judged the whole file. The user's own prose
# outside the generated block -- a note that the `code-review` GitHub app also comments, say --
# denied every Edit of the block, however correct, and told the model to rewrite text the run
# does not own. The rule covers only the generated block: `## Generated Quick Reference` up to
# the next top-level heading, the span render-report.sh compares against the prospective block.
# User prose sits on both sides so a resolver that bounds only one end still denies.
printf '%s\n' '# Team notes' '' 'The `code-review` GitHub app comments on every PR.' '' \
  '## Generated Quick Reference' '' 'Self-review with `project-code-review` before a PR.' '' \
  '# More team notes' '' 'Ask `code-review` for a second look.' > "$r17g_repo/CLAUDE.md"
r37e_edit "$r17g_repo" lc002-a CLAUDE.md 'before a PR.' 'before opening a PR.' \
  "$installer_tmp/lc002-user-prose.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/lc002-user-prose.out"; then
  printf '%s\n' 'FAIL: the guidance rule denied an Edit of the generated block over user prose outside it' >&2
  exit 1
fi

# Scoping must not disarm the rule inside the block: the stale spelling written there still denies.
r37e_edit "$r17g_repo" lc002-b CLAUDE.md '`project-code-review` before' '`code-review` before' \
  "$installer_tmp/lc002-stale-in-block.out"
run_rg -q 'the pre-rename spelling' "$installer_tmp/lc002-stale-in-block.out"

# And the block itself must name the skill; the user's prose naming it does not count.
printf '%s\n' '# Team notes' '' 'We adopted `project-code-review` last year.' '' \
  '## Generated Quick Reference' '' 'Self-review before a PR.' > "$r17g_repo/CLAUDE.md"
r37e_edit "$r17g_repo" lc002-c CLAUDE.md 'before a PR.' 'before opening a PR.' \
  "$installer_tmp/lc002-omit-in-block.out"
run_rg -q 'it never names .project-code-review.' "$installer_tmp/lc002-omit-in-block.out"

# Round-24: the run-start anchor must be complete or absent, never truncated. The fingerprint
# file used to be appended to IN PLACE while the re-capture guard tested only whether it EXISTED,
# so any capture that died mid-loop left a partial file that every later invocation accepted and
# the renderer then read as a full account -- printing `Untouched pre-existing (N): ... every path
# above was captured and verified` over paths it had never fingerprinted, and passing a mutation
# to any of them. Two kills reach that loop: the 600-second PreToolUse ceiling (measured at
# 601,505ms on three consecutive acceptance runs against a 14,734-path repository), and an
# unguarded `git hash-object` that fails under `set -e` on any path it cannot open -- a dangling
# symlink, a symlink to a directory, or an unreadable file, all ordinary `git status` entries.
# The fixture pins the three properties that close both: a complete capture leaves no `.partial`
# behind and fingerprints EVERY status path; the unopenable paths record as `protected` (matching
# the renderer's `current_path_state` twin) instead of aborting; and the batched hasher agrees
# path-for-path with an independent per-path recomputation.
r24_repo="$installer_tmp/r24-anchor-repo"
mkdir -p "$r24_repo/.claude" "$r24_repo/pre_dir"
git -C "$r24_repo" init -q -b main
git -C "$r24_repo" config user.name validator
git -C "$r24_repo" config user.email validator@example.com
printf 'original\n' > "$r24_repo/dirty.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r24_repo/noop.sh"
chmod +x "$r24_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$r24_repo/.claude/settings.json"
git -C "$r24_repo" add dirty.txt noop.sh .claude/settings.json
git -C "$r24_repo" commit -qm baseline
printf 'dirty\n' > "$r24_repo/dirty.txt"
printf 'plain\n' > "$r24_repo/pre_plain.txt"
printf 'spaced\n' > "$r24_repo/pre one.txt"
printf '%s\n' '#!/bin/sh' > "$r24_repo/pre_exec.sh"
chmod +x "$r24_repo/pre_exec.sh"
printf 'nested\n' > "$r24_repo/pre_dir/nested.txt"
printf 'second\n' > "$r24_repo/pre_second.txt"
printf 'third\n' > "$r24_repo/pre_third.txt"
printf 'unreadable\n' > "$r24_repo/pre_noread.txt"
chmod 000 "$r24_repo/pre_noread.txt"
ln -s pre_plain.txt "$r24_repo/pre_link"
ln -s pre_dir "$r24_repo/pre_dirlink"
ln -s nowhere.txt "$r24_repo/pre_dangling"
# Found live on toolshed. `git status` C-quotes a path holding a newline onto ONE line, and the
# capture below decoded it and wrote `path<TAB>type<TAB>hash<TAB>exec` -- so one status row became
# THREE physical fingerprint rows, and every consumer that reads `$1` per line then saw two
# fragments as paths of their own. The row-count invariant below is what catches it: the capture
# may not invent rows. The guard already refuses to put such a path through `--stdin-paths` for
# exactly this reason (it says so at completion-guard.sh:390) and then wrote it to its own
# line-oriented file anyway.
r24_newline_name='pre_heredoc")
print("fragment")
PY'
printf 'newline named\n' > "$r24_repo/$r24_newline_name"
write_discovery_fixture "$r24_repo" r24-fixture main none
jq -n --arg cwd "$r24_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r24",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
r24_status="$r24_repo/.launch-control-onboard/worktree-status.start"
r24_fingerprints="$r24_repo/.launch-control-onboard/worktree-status.start.fingerprints"
test -f "$r24_status"
test -f "$r24_fingerprints"
# A completed capture publishes both files by rename, so neither `.partial` may survive it.
if [ -e "$r24_status.partial" ] || [ -e "$r24_fingerprints.partial" ]; then
  printf '%s\n' 'FAIL: a completed run-start capture left a .partial anchor file behind' >&2
  exit 1
fi
# Every status path is fingerprinted: an aborted capture shows up here as a short file, which is
# exactly what the pre-fix guard produced on this fixture (9 of 17 rows, killed by the dangling
# symlink) while still presenting the result as a finished anchor.
r24_unrepresentable="$r24_repo/.launch-control-onboard/worktree-status.start.unrepresentable"
r24_status_rows="$(wc -l < "$r24_status" | tr -d ' ')"
r24_fingerprint_rows="$(wc -l < "$r24_fingerprints" | tr -d ' ')"
# Published by rename like the other two, so its existence means the capture finished and an empty
# file states "none seen" rather than "never looked".
test -f "$r24_unrepresentable"
if [ -e "$r24_unrepresentable.partial" ]; then
  printf '%s\n' 'FAIL: a completed run-start capture left a .partial unrepresentable file behind' >&2
  exit 1
fi
r24_unrepresentable_rows="$(wc -l < "$r24_unrepresentable" | tr -d ' ')"
if [ "$r24_status_rows" -lt 10 ]; then
  printf '%s\n' 'FAIL: r24 fixture did not produce a dirty tree worth anchoring' >&2
  exit 1
fi
# Every status path is accounted for exactly once: fingerprinted, or declared unrepresentable.
# Counting only the fingerprints would let the newline path be dropped silently, and counting them
# as equal would demand rows the format cannot hold.
if [ "$r24_status_rows" != "$((r24_fingerprint_rows + r24_unrepresentable_rows))" ]; then
  printf 'FAIL: run-start anchor accounted for %s + %s of %s status paths\n' \
    "$r24_fingerprint_rows" "$r24_unrepresentable_rows" "$r24_status_rows" >&2
  exit 1
fi
# Exactly the newline path, spelled the way git spells it, and no fragment of it anywhere in the
# fingerprints -- the fragments are what the defect produced.
if [ "$r24_unrepresentable_rows" != 1 ]; then
  printf 'FAIL: expected exactly one unrepresentable path, got %s\n' "$r24_unrepresentable_rows" >&2
  exit 1
fi
run_rg -qF -- '"pre_heredoc\")\nprint(\"fragment\")\nPY"' "$r24_unrepresentable"
if run_rg -q '^PY	' "$r24_fingerprints"; then
  printf '%s\n' 'FAIL: a fragment of a newline path was fingerprinted as a path of its own' >&2
  exit 1
fi
# The batch cannot open these three, so each must arrive through the per-path routine as
# `protected` -- the classification the renderer's twin already produces for them.
for r24_protected in pre_noread.txt pre_dangling pre_dirlink; do
  if ! run_rg -q "^$r24_protected	protected	protected	0\$" "$r24_fingerprints"; then
    printf 'FAIL: run-start anchor did not record %s as protected\n' "$r24_protected" >&2
    exit 1
  fi
done
# Independent recomputation: the batched hasher must agree with a plain per-path `hash-object`
# on every row it claims. Pairing by position instead of by the path the hasher echoed back
# would shift hashes onto neighbouring paths, and every row still LOOKS well-formed.
while IFS="$(printf '\t')" read -r r24_path r24_type r24_hash r24_exec; do
  [ -n "$r24_path" ] || continue
  [ "$r24_type" != protected ] || continue
  if [ "$r24_type" = file ] || [ "$r24_type" = symlink ]; then
    r24_expected="$(git -C "$r24_repo" hash-object --no-filters "$r24_repo/$r24_path")"
    if [ "$r24_hash" != "$r24_expected" ]; then
      printf 'FAIL: batched anchor hash for %s (%s) diverged from the per-path routine (%s)\n' \
        "$r24_path" "$r24_hash" "$r24_expected" >&2
      exit 1
    fi
  fi
  r24_want_exec=0
  if [ "$r24_type" = file ] && [ -x "$r24_repo/$r24_path" ]; then
    r24_want_exec=1
  fi
  if [ "$r24_exec" != "$r24_want_exec" ]; then
    printf 'FAIL: batched anchor executable bit for %s was %s, expected %s\n' \
      "$r24_path" "$r24_exec" "$r24_want_exec" >&2
    exit 1
  fi
done < "$r24_fingerprints"
chmod 644 "$r24_repo/pre_noread.txt"

# The inventory capture carried the same unguarded hash in its own `snapshot_path`, and it
# snapshots every BASELINE path -- so the dangling symlink above killed that pipeline too and left
# a SHORT inventory, which the write path only ever tests for existence and the renderer derives
# its preserved-baseline rows from. Fire the first write and demand the inventory account for
# every baseline path, not merely exist.
jq -n --arg cwd "$r24_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r24",tool_name:"Write",tool_input:{file_path:"CLAUDE.md"}}' | run_guard > /dev/null
r24_inventory="$r24_repo/.git/launch-control-onboard-run-r24.inventory"
r24_baseline_state="$r24_repo/.git/launch-control-onboard-run-r24.baseline"
test -f "$r24_inventory"
test -f "$r24_baseline_state"
while IFS= read -r r24_baseline_path; do
  [ -n "$r24_baseline_path" ] || continue
  if ! awk -F '\t' -v want="$r24_baseline_path" '$2 == want { found = 1 } END { exit !found }' \
    "$r24_inventory"; then
    printf 'FAIL: captured inventory is missing baseline path %s\n' "$r24_baseline_path" >&2
    exit 1
  fi
done < "$r24_baseline_state"
run_rg -q '	pre_dangling	protected	protected	0$' "$r24_inventory"

# `f03560a` carried the newline exclusion into the run-anchor capture above and MISSED this one,
# which writes the same decoded path into its own line-oriented file. A live toolshed run then
# printed `PY` and two code fragments as repository paths under `Untouched pre-existing`, a
# heading that claims every path above was captured and verified, with the count inflated by two.
# The renderer loads this exact file, so by the time it reads it the newline IS the record
# separator and nothing downstream can tell a fragment from a path -- the exclusion has to be here.
r24_baseline_unrepresentable="$r24_repo/.launch-control-onboard/baseline-paths.unrepresentable"
test -f "$r24_baseline_unrepresentable"
# The fragments the defect produced, asserted individually rather than by row count: a count alone
# passes if the capture drops the whole path silently, which is the same report defect wearing the
# other hat -- the run cannot account for the path and must not pretend the tree lacks it.
while IFS= read -r r24_fragment; do
  if run_rg -qxF -- "$r24_fragment" "$r24_baseline_state"; then
    printf 'FAIL: a fragment of a newline path entered the baseline as a path of its own: %s\n' \
      "$r24_fragment" >&2
    exit 1
  fi
done <<'R24_FRAGMENTS'
PY
print("fragment")
pre_heredoc")
R24_FRAGMENTS
run_rg -qF -- '"pre_heredoc\")\nprint(\"fragment\")\nPY"' "$r24_baseline_unrepresentable"
if [ "$(wc -l < "$r24_baseline_unrepresentable" | tr -d ' ')" != 1 ]; then
  printf 'FAIL: expected exactly one unrepresentable baseline path, got %s\n' \
    "$(wc -l < "$r24_baseline_unrepresentable" | tr -d ' ')" >&2
  exit 1
fi
# Its own sidecar, not the anchor's: `capture_run_anchor` publishes that one by `mv`, so a second
# writer would be clobbered or would depend on which capture ran first.
if [ "$r24_baseline_unrepresentable" = "$r24_unrepresentable" ]; then
  printf '%s\n' 'FAIL: the baseline capture shares the run-anchor sidecar it can clobber' >&2
  exit 1
fi

# A dirty set with NOTHING the batch can carry: the join that merges batched hashes back into the
# classified rows reads two files, and keying it on `NR == FNR` instead of the filename makes that
# test true for the SECOND file as well once the first is empty -- which silently swallows every
# classified row and writes an EMPTY anchor that no later count check can distinguish from a
# repository with a clean tree.
r24_slow="$installer_tmp/r24-allslow-repo"
mkdir -p "$r24_slow/.claude"
git -C "$r24_slow" init -q -b main
git -C "$r24_slow" config user.name validator
git -C "$r24_slow" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r24_slow/noop.sh"
chmod +x "$r24_slow/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$r24_slow/.claude/settings.json"
git -C "$r24_slow" add noop.sh .claude/settings.json
git -C "$r24_slow" commit -qm baseline
ln -s nowhere-one.txt "$r24_slow/pre_dangling_one"
ln -s nowhere-two.txt "$r24_slow/pre_dangling_two"
write_discovery_fixture "$r24_slow" r24-allslow main none
jq -n --arg cwd "$r24_slow" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r24slow",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
r24_slow_fp="$r24_slow/.launch-control-onboard/worktree-status.start.fingerprints"
if [ "$(wc -l < "$r24_slow/.launch-control-onboard/worktree-status.start" | tr -d ' ')" \
  != "$(wc -l < "$r24_slow_fp" | tr -d ' ')" ]; then
  printf '%s\n' 'FAIL: an all-unbatchable dirty set did not fingerprint every status path' >&2
  exit 1
fi
run_rg -q '^pre_dangling_one	protected	protected	0$' "$r24_slow_fp"
run_rg -q '^pre_dangling_two	protected	protected	0$' "$r24_slow_fp"

# A `.partial` left by a killed capture is NOT rebuilt on a later checkpoint. The attestation
# that gates every project write is granted immediately before the capture, so by the time a
# second checkpoint fires the run may already have written to the tree; re-anchoring there would
# fold the run's own output into the "pre-existing" baseline. The markers must survive untouched
# so the renderer can refuse instead.
r24_killed="$installer_tmp/r24-killed-repo"
mkdir -p "$r24_killed/.claude/.launch-control-onboard" "$r24_killed/.launch-control-onboard"
git -C "$r24_killed" init -q -b main
git -C "$r24_killed" config user.name validator
git -C "$r24_killed" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r24_killed/noop.sh"
chmod +x "$r24_killed/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$r24_killed/.claude/settings.json"
git -C "$r24_killed" add noop.sh .claude/settings.json
git -C "$r24_killed" commit -qm baseline
printf 'pre\n' > "$r24_killed/pre_a.txt"
printf 'pre\n' > "$r24_killed/pre_b.txt"
write_discovery_fixture "$r24_killed" r24-killed main none
r24_killed_status="$r24_killed/.launch-control-onboard/worktree-status.start"
r24_killed_fp="$r24_killed/.launch-control-onboard/worktree-status.start.fingerprints"
printf '%s\n' ' M truncated-by-the-kill' > "$r24_killed_status.partial"
printf 'pre_a.txt\tfile\t%s\t0\n' 0000000000000000000000000000000000000000 > "$r24_killed_fp.partial"
jq -n --arg cwd "$r24_killed" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r24killed",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
if [ -e "$r24_killed_status" ] || [ -e "$r24_killed_fp" ]; then
  printf '%s\n' 'FAIL: a checkpoint re-anchored on a tree an interrupted run may already have written to' >&2
  exit 1
fi
if [ ! -e "$r24_killed_status.partial" ] || [ ! -e "$r24_killed_fp.partial" ]; then
  printf '%s\n' 'FAIL: a checkpoint cleared the interrupted-capture markers the renderer refuses on' >&2
  exit 1
fi
run_rg -q '^ M truncated-by-the-kill$' "$r24_killed_status.partial"

# A required manifest path reached through a symlinked ancestor. Proven on a live run: a
# repository whose `.claude/skills/launch` was a tracked symlink into a subdirectory had that
# subdirectory's uncommitted SKILL.md overwritten, and `git status` printed the identical line
# before and after. Nothing caught it -- repo confinement passes a link that stays inside the
# repository, and the dirty baseline is `git status` output, which never spells a path through
# a symlinked directory. The path must be denied at the write and pinned in the baseline.
sym_repo="$installer_tmp/symlinked-manifest-repo"
mkdir -p "$sym_repo/sub/.claude/skills/launch" "$sym_repo/.claude/skills"
git -C "$sym_repo" init -q .
git -C "$sym_repo" config user.email validator@example.com
git -C "$sym_repo" config user.name validator
printf 'committed\n' > "$sym_repo/sub/.claude/skills/launch/SKILL.md"
ln -s ../../sub/.claude/skills/launch "$sym_repo/.claude/skills/launch"
git -C "$sym_repo" add -A
git -C "$sym_repo" commit -qm baseline
printf 'uncommitted work\n' >> "$sym_repo/sub/.claude/skills/launch/SKILL.md"
sym_target_before="$(shasum -a 256 "$sym_repo/sub/.claude/skills/launch/SKILL.md" | awk '{ print $1 }')"
write_discovery_fixture "$sym_repo" symlinked-manifest main none
jq -n --arg cwd "$sym_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symvalidator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
sym_output="$installer_tmp/symlinked-manifest.out"
jq -n --arg cwd "$sym_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symvalidator",tool_name:"Write",tool_input:{file_path:".claude/skills/launch/SKILL.md",content:"generated"}}' \
  | run_guard > "$sym_output"
run_rg -q '"permissionDecision":"deny"' "$sym_output"
run_rg -q 'symlink alias' "$sym_output"
run_rg -q 'sub/\.claude/skills/launch/SKILL\.md' "$sym_output"
# The deny must route the run to PRESERVED, not to the blocked protocol: predicting a clobber
# and stopping is exactly what the live run did, and SKILL.md forbids it.
run_rg -q 'NOT a blocked condition' "$sym_output"
if [ "$(shasum -a 256 "$sym_repo/sub/.claude/skills/launch/SKILL.md" | awk '{ print $1 }')" != "$sym_target_before" ]; then
  printf '%s\n' 'FAIL: the symlinked manifest write reached the target file' >&2
  exit 1
fi
sym_git_dir="$(git -C "$sym_repo" rev-parse --absolute-git-dir)"
run_rg -qx '\.claude/skills/launch/SKILL\.md' "$sym_git_dir/launch-control-onboard-run-symvalidator.baseline"
run_rg -q '^\.claude/skills/launch/SKILL\.md\tsub/\.claude/skills/launch/SKILL\.md$' \
  "$sym_repo/.launch-control-onboard/symlinked-manifest.guard.txt"

# Positive control: an ordinary repository must produce no aliasing at all.
sym_plain="$installer_tmp/symlinked-manifest-control"
mkdir -p "$sym_plain/.claude/skills/launch"
git -C "$sym_plain" init -q .
git -C "$sym_plain" config user.email validator@example.com
git -C "$sym_plain" config user.name validator
printf 'committed\n' > "$sym_plain/.claude/skills/launch/SKILL.md"
git -C "$sym_plain" add -A
git -C "$sym_plain" commit -qm baseline
write_discovery_fixture "$sym_plain" symlinked-control main none
jq -n --arg cwd "$sym_plain" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symcontrol",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
sym_control_out="$installer_tmp/symlinked-manifest-control.out"
jq -n --arg cwd "$sym_plain" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symcontrol",tool_name:"Write",tool_input:{file_path:".claude/skills/launch/SKILL.md",content:"generated"}}' \
  | run_guard > "$sym_control_out"
if run_rg -q 'symlink alias' "$sym_control_out"; then
  printf '%s\n' 'FAIL: an ordinary manifest path was reported as a symlink alias' >&2
  exit 1
fi
if [ -s "$sym_plain/.launch-control-onboard/symlinked-manifest.guard.txt" ]; then
  printf '%s\n' 'FAIL: a repository with no symlinked manifest path produced symlink disclosures' >&2
  exit 1
fi

# Second control: the repository ITSELF reached through a symlinked prefix. This is the
# ordinary case on macOS, where every $TMPDIR path arrives through /var -> /private/var, and it
# is the one the aliasing comparison gets wrong by default: resolving the candidate path with
# `pwd -P` while leaving the repository root unresolved makes the two sides disagree for EVERY
# manifest path, which would pin an entire ordinary run PRESERVED and generate nothing. The
# first control cannot catch it -- these fixtures live under $ROOT, which has no symlinked
# prefix -- so the symlink has to be built explicitly.
sym_prefix_real="$installer_tmp/sym-prefix-real"
sym_prefix_link="$installer_tmp/sym-prefix-link"
mkdir -p "$sym_prefix_real/.claude/skills/launch"
git -C "$sym_prefix_real" init -q .
git -C "$sym_prefix_real" config user.email validator@example.com
git -C "$sym_prefix_real" config user.name validator
printf 'committed\n' > "$sym_prefix_real/.claude/skills/launch/SKILL.md"
git -C "$sym_prefix_real" add -A
git -C "$sym_prefix_real" commit -qm baseline
ln -s sym-prefix-real "$sym_prefix_link"
write_discovery_fixture "$sym_prefix_link" symlinked-prefix main none
jq -n --arg cwd "$sym_prefix_link" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symprefix",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
sym_prefix_out="$installer_tmp/symlinked-prefix.out"
jq -n --arg cwd "$sym_prefix_link" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"symprefix",tool_name:"Write",tool_input:{file_path:".claude/skills/launch/SKILL.md",content:"generated"}}' \
  | run_guard > "$sym_prefix_out"
if run_rg -q 'symlink alias' "$sym_prefix_out"; then
  printf '%s\n' 'FAIL: a repository reached through a symlinked prefix reported its own manifest paths as aliased' >&2
  exit 1
fi
if [ -s "$sym_prefix_link/.launch-control-onboard/symlinked-manifest.guard.txt" ]; then
  printf '%s\n' 'FAIL: a symlinked repository prefix produced symlink disclosures' >&2
  exit 1
fi

# Round-31: the prospective CLAUDE.md marker block is decidable before the renderer starts, and
# was enforced only after it finished. Live on toolshed run 287e4c0e that cost a full render --
# two distinct renderer invocations, the first exiting 1 on `prospective CLAUDE.md marker block
# is missing`. The F38 class from round 20, and the same move `e20d26f` made for the guidance
# rules. Each case gets its OWN session id: the deny counter is per session, so a shared one
# makes every later "allowed" assertion vacuous once the breaker has been spent.
r31_repo="$installer_tmp/r31-prospective-repo"
mkdir -p "$r31_repo/.launch-control-onboard"
git -C "$r31_repo" init -q -b r31
r31_renderer="$policy_config/skills/onboard/scripts/render-report.sh"
r31_ledger="$r31_repo/.launch-control-onboard/ledger.tsv"
r31_prospective="$r31_repo/.launch-control-onboard/prospective-claude.md"
r31_command="$r31_renderer $r31_ledger r31 valid absent ready $r31_repo/.launch-control-onboard/validation-commands.txt none complete"
r31_render() { # session outfile
  jq -n --arg cwd "$r31_repo" --arg command "$r31_command" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' \
    | run_guard > "$2"
}

# The ledger carries CLAUDE.md and the block is absent: refused before the renderer runs, and the
# reason names the accepted form rather than only the rejected one.
printf '%s\t%s\n' CREATED CLAUDE.md > "$r31_ledger"
rm -f "$r31_prospective"
r31_render r31-a "$installer_tmp/r31-missing.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-missing.out"
run_rg -q '## Generated Quick Reference' "$installer_tmp/r31-missing.out"
if run_rg -q 'GENERATED SECTION -- onboard' "$installer_tmp/r31-missing.out"; then
  printf '%s\n' 'FAIL: the prospective gate still tells the run to write comment-marker scaffolding' >&2
  exit 1
fi
run_rg -q 'PRESERVED is not exempt' "$installer_tmp/r31-missing.out"
# A refused invocation never runs, so it must leave this session's render state exactly as it
# found it. Stamping here would make the F34a redundancy check treat a render that never
# happened as one that did.
test ! -e "$r31_repo/.git/launch-control-onboard-run-r31-a.rendered"

# PRESERVED is the case SKILL.md calls out by name, and the one a run is most likely to think
# exempts it: nothing was written to CLAUDE.md, so nothing feels owed. The gate treats it
# exactly as CREATED.
printf '%s\t%s\n' PRESERVED CLAUDE.md > "$r31_ledger"
r31_render r31-b "$installer_tmp/r31-preserved.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-preserved.out"

# With the block on disk the render proceeds, and the marker is stamped as it always was.
printf '%s\n' '## Generated Quick Reference' 'body' > "$r31_prospective"
r31_render r31-c "$installer_tmp/r31-present.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-present.out"; then
  printf '%s\n' 'FAIL: the prospective gate refused a render whose generated block was already written' >&2
  exit 1
fi
test -f "$r31_repo/.git/launch-control-onboard-run-r31-c.rendered"

# NOT YET DECIDABLE, twice. A ledger with no CLAUDE.md row carries no premise for the rule, and
# a ledger not yet on disk carries no information at all. Denying either would deny a render for
# a contract the run has not reached -- the round-11 deadlock shape the guidance rules are
# already built to avoid -- so both stand down to the renderer's unbypassable copy.
rm -f "$r31_prospective"
printf '%s\t%s\n' SKIPPED .mcp.json > "$r31_ledger"
r31_render r31-d "$installer_tmp/r31-noclaude.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-noclaude.out"; then
  printf '%s\n' 'FAIL: the prospective gate denied a render whose ledger never lists CLAUDE.md' >&2
  exit 1
fi
rm -f "$r31_ledger"
r31_render r31-e "$installer_tmp/r31-noledger.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-noledger.out"; then
  printf '%s\n' 'FAIL: the prospective gate denied a render before the ledger it decides from exists' >&2
  exit 1
fi

# A SYMLINKED ledger is the load-bearing half of that existence test, and the only half a
# mutant can flip: with the `-f` check gone, awk on a missing file still errors into the same
# stand-down, but awk follows a symlink and reads it happily. The renderer refuses a symlinked
# control file by name (normalize_control_file), so denying here would replace a precise
# message about the symlink with a misleading one about a marker block, for a render that was
# going to fail either way. Stand down and let the renderer say what is actually wrong.
r31_real_ledger="$installer_tmp/r31-real-ledger.tsv"
printf '%s\t%s\n' CREATED CLAUDE.md > "$r31_real_ledger"
ln -s "$r31_real_ledger" "$r31_ledger"
r31_render r31-sym "$installer_tmp/r31-symlink.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-symlink.out"; then
  printf '%s\n' 'FAIL: the prospective gate read a symlinked ledger the renderer refuses by name' >&2
  exit 1
fi
rm -f "$r31_ledger"

# A ledger outside the control directory is not this run's ledger, and the guard must not read
# an arbitrary path named on a command line. Undecidable, so it stands down.
r31_outside="$installer_tmp/r31-outside-ledger.tsv"
printf '%s\t%s\n' CREATED CLAUDE.md > "$r31_outside"
r31_outside_command="$r31_renderer $r31_outside r31 valid absent ready $r31_repo/.launch-control-onboard/validation-commands.txt none complete"
jq -n --arg cwd "$r31_repo" --arg command "$r31_outside_command" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r31-f",tool_name:"Bash",tool_input:{command:$command}}' \
  | run_guard > "$installer_tmp/r31-outside.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-outside.out"; then
  printf '%s\n' 'FAIL: the prospective gate decided from a ledger outside the run control directory' >&2
  exit 1
fi

# Circuit breaker: after two denies the gate stands down and leaves the rule to the renderer, so
# a run that structurally cannot produce the block finishes with a legible render failure rather
# than livelocking against the hook.
printf '%s\t%s\n' MERGED CLAUDE.md > "$r31_ledger"
r31_render r31-g "$installer_tmp/r31-cb1.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-cb1.out"
r31_render r31-g "$installer_tmp/r31-cb2.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-cb2.out"
r31_render r31-g "$installer_tmp/r31-cb3.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-cb3.out"; then
  printf '%s\n' 'FAIL: the prospective gate never stands down and can livelock a run' >&2
  exit 1
fi

# The deny counter is per-run state and must not outlive the run that earned it, exactly like
# the emission, lens, and guidance counters beside it.
r31_deny_state="$r31_repo/.git/launch-control-onboard-run-r31-g.prospective-denies"
test -f "$r31_deny_state"
jq -n --arg cwd "$r31_repo" \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"r31-g",prompt:"/onboard"}' | run_guard
test ! -e "$r31_deny_state"

# The renderer keeps its own copy of the rule. A degraded session runs no hook at all, so moving
# the rule earlier must never be mistaken for moving it.
run_rg -qF 'prospective CLAUDE.md generated block is missing' "$ROOT/skills/onboard/scripts/render-report.sh"

# Round-31: the LIVE command form. Every r31 case above hands the guard a bare invocation, but
# SKILL.md's documented spelling carries two ONBOARD_* env prefixes and quotes every path, and
# that is the shape a real run actually emits. A token extractor that only handles the bare form
# would pass all of the above and never fire once in production -- which is precisely how the
# round-20 guidance rule failed, keyed on a file no real run had written yet.
# The re-arm case directly above purges the whole control directory, which is the behaviour it
# exists to prove -- so recreate it here rather than relying on a directory a prior case deleted.
mkdir -p "$r31_repo/.launch-control-onboard"
r31_prod_ledger="$r31_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' CREATED CLAUDE.md > "$r31_prod_ledger"
rm -f "$r31_prospective"
r31_prod_command="ONBOARD_REQUIRED_PATHS_FILE=\"$r31_repo/.launch-control-onboard/required-paths.txt\" ONBOARD_BASELINE_PATHS_FILE=\"$r31_repo/.launch-control-onboard/baseline-paths.txt\" \"$r31_renderer\" \"$r31_prod_ledger\" r31 valid absent ready \"$r31_repo/.launch-control-onboard/validation-commands.txt\" none complete"
jq -n --arg cwd "$r31_repo" --arg command "$r31_prod_command" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r31-prod",tool_name:"Bash",tool_input:{command:$command}}' \
  | run_guard > "$installer_tmp/r31-prod.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-prod.out"
run_rg -qF 'ONBOARD_REQUIRED_PATHS_FILE' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"

# Round-31 follow-up: the deny's ADVICE has to land, not just the deny. The renderer checks the
# missing block first (render-report.sh:1443) and the F32 write order second (:1484), so telling a
# CREATED or MERGED run to "write the block now" walks it into the inversion on the very next
# render -- a second full validation-command run, the exact cost this gate removes. Only PRESERVED
# is fixed by the short advice, because Phase 3 never writes CLAUDE.md there and the F31 branch
# exempts last_claude_seq 0. The recording side of write-order.guard.txt is already pinned from
# real Writes at the round-15 F32 case above; what is pinned here is this gate READING it.
mkdir -p "$r31_repo/.launch-control-onboard"
printf '%s\t%s\n' CREATED CLAUDE.md > "$r31_ledger"
rm -f "$r31_prospective"
r31_write_order="$r31_repo/.launch-control-onboard/write-order.guard.txt"

# CLAUDE.md already written this run: the advice must also require rewriting CLAUDE.md after.
printf '%s\t%s\n' 1 CLAUDE.md > "$r31_write_order"
r31_render r31-f32a "$installer_tmp/r31-f32-written.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-f32-written.out"
run_rg -qF 'ALREADY written CLAUDE.md' "$installer_tmp/r31-f32-written.out"
run_rg -qF 'write CLAUDE.md again' "$installer_tmp/r31-f32-written.out"

# No CLAUDE.md write recorded: the short advice is correct and the inversion warning would be
# false. A gate that always warns teaches a PRESERVED run to write a CLAUDE.md it must not touch.
printf '%s\t%s\n' 1 .launch-control-onboard/prospective-claude.md > "$r31_write_order"
r31_render r31-f32b "$installer_tmp/r31-f32-unwritten.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-f32-unwritten.out"
if run_rg -qF 'ALREADY written CLAUDE.md' "$installer_tmp/r31-f32-unwritten.out"; then
  printf '%s\n' 'FAIL: the gate warned about a CLAUDE.md write order that this run never recorded' >&2
  exit 1
fi

# No record at all is the same case: undecidable order, so no claim about it.
rm -f "$r31_write_order"
r31_render r31-f32c "$installer_tmp/r31-f32-norecord.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31-f32-norecord.out"
if run_rg -qF 'ALREADY written CLAUDE.md' "$installer_tmp/r31-f32-norecord.out"; then
  printf '%s\n' 'FAIL: the gate asserted a write order with no guard record to read it from' >&2
  exit 1
fi

# Round-31: the reviewer lens is the SAME hole one rule over. Round-17 moved it to the write,
# which closes it only for a run that writes the file. A run that PRESERVES a pre-existing
# .claude/agents/inspector.md never writes it, so the write-time rule gets no event, while
# the renderer's copy keyed on existence on disk and refused over a lens-less file the run had
# not touched since the previous day (rymonroe.com). Round-32 correction: that refusal was
# UNSATISFIABLE, not expensive -- the renderer exits before running any declared command, and
# the two measured refusals took 313 ms and 385 ms. Round-31's "8m12s render, npm run
# lint/typecheck/build all executed" was the whole /onboard run misattributed to the render.
r31l_repo="$installer_tmp/r31-lens-repo"
mkdir -p "$r31l_repo/.claude/agents" "$r31l_repo/.launch-control-onboard"
git -C "$r31l_repo" init -q -b r31l
printf '%s\n' '# fixture' > "$r31l_repo/README.md"
printf '%s\n' '{}' > "$r31l_repo/package.json"
r31l_reviewer="$r31l_repo/.claude/agents/inspector.md"
r31l_command="$r31_renderer $r31l_repo/.launch-control-onboard/ledger.tsv r31l valid absent ready $r31l_repo/.launch-control-onboard/validation-commands.txt none complete"
r31l_ledger="$r31l_repo/.launch-control-onboard/ledger.tsv"
# Round-32: the gate keys on the LEDGER, not on disk, so the default fixture state is a run that
# WROTE the reviewer. The PRESERVED and no-row cases get their own checks below.
printf '%s\t%s\n' CREATED .claude/agents/inspector.md > "$r31l_ledger"
r31l_render() { # session outfile
  jq -n --arg cwd "$r31l_repo" --arg command "$r31l_command" --arg s "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' \
    | run_guard > "$2"
}

# No reviewer on disk is the renderer's own skip condition, so it is the rule having no premise
# here too -- not a failure. Stand down.
r31l_render r31l-a "$installer_tmp/r31l-absent.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-absent.out"; then
  printf '%s\n' 'FAIL: the lens render gate denied a run with no code reviewer to judge' >&2
  exit 1
fi

# A reviewer this run WROTE, with no lens heading at all. Refused before the renderer starts,
# and the reason says the ledger records the file as this run's own output -- so "rewrite it"
# names a write the run is actually allowed to make.
printf '%s\n' '# Code Review Agent' '' '## Process' '- Read the diff.' > "$r31l_reviewer"
r31l_render r31l-b "$installer_tmp/r31l-nolens.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-nolens.out"
run_rg -qF 'ledger records the file as CREATED or MERGED' "$installer_tmp/r31l-nolens.out"
test ! -e "$r31l_repo/.git/launch-control-onboard-run-r31l-b.rendered"

# Round-32 F41. The same lens-less file, PRESERVED instead. This is the actual rymonroe.com
# shape: a hand-authored reviewer the run neither wrote nor -- per SKILL.md's preservation rule
# -- may write. Keyed on disk the gate denied it, demanding an edit with no compliant response,
# and the renderer failed the same file with no rerun able to clear it. Both now scope to the
# ledger, so this must proceed and stamp the render marker.
printf '%s\t%s\n' PRESERVED .claude/agents/inspector.md > "$r31l_ledger"
r31l_render r31l-f "$installer_tmp/r31l-preserved.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-preserved.out"; then
  printf '%s\n' 'FAIL: the lens render gate denied a reviewer this run preserved and may not write' >&2
  cat "$installer_tmp/r31l-preserved.out" >&2
  exit 1
fi
test -f "$r31l_repo/.git/launch-control-onboard-run-r31l-f.rendered"

# No row at all is the same answer for the same reason: the run cannot be shown to own the file.
: > "$r31l_ledger"
r31l_render r31l-g "$installer_tmp/r31l-norow.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-norow.out"; then
  printf '%s\n' 'FAIL: the lens render gate denied over a reviewer absent from the ledger' >&2
  cat "$installer_tmp/r31l-norow.out" >&2
  exit 1
fi
printf '%s\t%s\n' CREATED .claude/agents/inspector.md > "$r31l_ledger"

# A well-formed lens proceeds, and the render marker is stamped as it always was.
printf '%s\n' '# Code Review Agent' '' '## Project-specific review lens' \
  '- Shell scripts must set -euo pipefail. Evidence: `README.md`.' \
  '- Manifest edits must stay narrow. Evidence: `package.json`.' > "$r31l_reviewer"
r31l_render r31l-c "$installer_tmp/r31l-good.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-good.out"; then
  printf '%s\n' 'FAIL: the lens render gate refused a well-formed project-specific review lens' >&2
  exit 1
fi
test -f "$r31l_repo/.git/launch-control-onboard-run-r31l-c.rendered"

# Circuit breaker, and its own counter. Sharing lens_deny_state with the write-time rule would
# silence this gate for exactly the run that spent that budget failing to author a lens.
printf '%s\n' '# Code Review Agent' '' '## Process' '- Read the diff.' > "$r31l_reviewer"
r31l_render r31l-d "$installer_tmp/r31l-cb1.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-cb1.out"
r31l_render r31l-d "$installer_tmp/r31l-cb2.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-cb2.out"
r31l_render r31l-d "$installer_tmp/r31l-cb3.out"
if run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-cb3.out"; then
  printf '%s\n' 'FAIL: the lens render gate never stands down and can livelock a run' >&2
  exit 1
fi
# Spending the WRITE-time budget must not silence this gate: separate counters, separate runs.
printf '%s\n' 2 > "$r31l_repo/.git/launch-control-onboard-run-r31l-e.lens-denies"
r31l_render r31l-e "$installer_tmp/r31l-sepcounter.out"
run_rg -q '"permissionDecision":"deny"' "$installer_tmp/r31l-sepcounter.out"

# Per-run state, purged when /onboard re-arms, exactly like every counter beside it.
r31l_deny_state="$r31l_repo/.git/launch-control-onboard-run-r31l-d.lens-render-denies"
test -f "$r31l_deny_state"
jq -n --arg cwd "$r31l_repo" \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"r31l-d",prompt:"/onboard"}' | run_guard
test ! -e "$r31l_deny_state"

# The renderer keeps its own unbypassable copy: a degraded session runs no hook at all.
run_rg -qF 'code reviewer lacks project-specific review lens' "$ROOT/skills/onboard/scripts/render-report.sh"
