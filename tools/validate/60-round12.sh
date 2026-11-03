# shellcheck shell=bash
# Round 12 — report fidelity: marker reaping, batching, F10-F16 disclosures.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
# ---------------------------------------------------------------------------
# Round 12 — three defects found auditing the round-11 acceptance runs.
# ---------------------------------------------------------------------------

# F1. A pre-checkpoint `.gitignore` write is the tail of a forbidden curation detour. The
# denial used to name only the ordering rule, which taught the run the write was legitimate
# but mistimed — so it handed the edit to the user and emitted the blocked protocol.
r12_guard_repo="$installer_tmp/r12-guard-repo"
mkdir -p "$r12_guard_repo/.claude"
git -C "$r12_guard_repo" init -q -b validator
git -C "$r12_guard_repo" config user.name validator
git -C "$r12_guard_repo" config user.email validator@example.com
printf '%s\n' 'seed' > "$r12_guard_repo/seed.txt"
git -C "$r12_guard_repo" add .
git -C "$r12_guard_repo" commit -qm baseline

r12_guard_out="$installer_tmp/r12-guard.json"
jq -n --arg cwd "$r12_guard_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Edit",tool_input:{file_path:($cwd+"/.gitignore")}}' |
  run_guard > "$r12_guard_out"
run_rg -q 'cannot write before the complete Workspace Discovery Report' "$r12_guard_out"
run_rg -q 'never curates the user.s untracked files' "$r12_guard_out"
run_rg -q 'not a reason to emit the blocked protocol' "$r12_guard_out"
run_rg -q 'Continue the run' "$r12_guard_out"

# The extra clause is scoped to `.gitignore` — an ordinary pre-checkpoint write still gets
# only the ordering rule, so the denial never grows unrelated prose.
jq -n --arg cwd "$r12_guard_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"validator",tool_name:"Edit",tool_input:{file_path:($cwd+"/CLAUDE.md")}}' |
  run_guard > "$installer_tmp/r12-guard-other.json"
run_rg -q 'cannot write before the complete Workspace Discovery Report' "$installer_tmp/r12-guard-other.json"
if run_rg -q 'never curates' "$installer_tmp/r12-guard-other.json"; then
  printf '%s\n' 'FAIL: the .gitignore curation clause leaked onto an unrelated pre-checkpoint write' >&2
  exit 1
fi

# F2. A session that dies between its first write and its Stop hook orphans its `.active`
# marker, which the count-only check then read as a concurrent run — bricking the repository
# for every later onboarding with no remediation the message ever named.
r12_seed_checkpoint() {
  local repo="$1" hash="$2"
  mkdir -p "$repo/.launch-control-onboard"
  printf 'phase-0-discovery-complete\t%s\t2026-07-25T00:00:00Z\n' "$hash" \
    > "$repo/.launch-control-onboard/discovery-checkpoint"
}
r12_marker() {
  local repo="$1" session="$2" age="$3" hash="${4:-}"
  local git_dir
  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir)"
  : > "$git_dir/launch-control-onboard-run-$session.active"
  [ -z "$hash" ] || printf '%s\n' "$hash" > "$git_dir/launch-control-onboard-run-$session.discovery"
  [ "$age" != stale ] || touch -t 202001010000 "$git_dir/launch-control-onboard-run-$session.active"
}

# Two abandoned markers, neither carrying this run's attestation: both are reaped and the
# render completes instead of refusing the repository forever.
r12_reap_repo="$installer_tmp/r12-reap-repo"
r11_fixture "$r12_reap_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_reap_repo/.launch-control-onboard/validation-commands.txt"
r12_seed_checkpoint "$r12_reap_repo" ownhash
r12_marker "$r12_reap_repo" deadsession-one stale
r12_marker "$r12_reap_repo" deadsession-two stale
r11_render "$r12_reap_repo" > "$installer_tmp/r12-reap.out" 2> "$installer_tmp/r12-reap.err" || {
  printf '%s\n' 'FAIL: stale orphan run markers still blocked the render' >&2
  cat "$installer_tmp/r12-reap.err" >&2
  exit 1
}
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-reap.out"
run_rg -q 'reaping a stale onboarding run marker abandoned' "$installer_tmp/r12-reap.err"
r12_reap_git="$(git -C "$r12_reap_repo" rev-parse --absolute-git-dir)"
if [ -e "$r12_reap_git/launch-control-onboard-run-deadsession-one.active" ]; then
  printf '%s\n' 'FAIL: a reaped marker survived on disk' >&2
  exit 1
fi

# Genuine concurrency still blocks — a fresh foreign marker is not reaped — and the refusal
# now names each marker and the exact recovery command.
r12_fresh_repo="$installer_tmp/r12-fresh-repo"
r11_fixture "$r12_fresh_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_fresh_repo/.launch-control-onboard/validation-commands.txt"
r12_seed_checkpoint "$r12_fresh_repo" ownhash
r12_marker "$r12_fresh_repo" livesession-one fresh
r12_marker "$r12_fresh_repo" livesession-two fresh
if r11_render "$r12_fresh_repo" > /dev/null 2> "$installer_tmp/r12-fresh.err"; then
  printf '%s\n' 'FAIL: two concurrent live onboarding runs were allowed to share a repository' >&2
  exit 1
fi
run_rg -q '^multiple active onboarding runs share this repository$' "$installer_tmp/r12-fresh.err"
run_rg -q 'active marker: launch-control-onboard-run-livesession-one\.active' "$installer_tmp/r12-fresh.err"
run_rg -q 'rm .*launch-control-onboard-run-<session-id>\.\*' "$installer_tmp/r12-fresh.err"

# This run's own marker is fresh — the lifecycle guard re-truncates it on every gated write
# — so it survives while a stale orphan beside it is reaped.
r12_own_repo="$installer_tmp/r12-own-repo"
r11_fixture "$r12_own_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_own_repo/.launch-control-onboard/validation-commands.txt"
r12_seed_checkpoint "$r12_own_repo" ownhash
r12_marker "$r12_own_repo" mysession fresh ownhash
r12_marker "$r12_own_repo" deadsession stale
r11_render "$r12_own_repo" > /dev/null 2>&1 || true
r12_own_git="$(git -C "$r12_own_repo" rev-parse --absolute-git-dir)"
if [ ! -e "$r12_own_git/launch-control-onboard-run-mysession.active" ]; then
  printf '%s\n' "FAIL: the run's own active marker was reaped as a stale orphan" >&2
  exit 1
fi
if [ -e "$r12_own_git/launch-control-onboard-run-deadsession.active" ]; then
  printf '%s\n' 'FAIL: a stale foreign marker survived beside a live one' >&2
  exit 1
fi

# The production case this fix exists for: a rerun over an UNCHANGED repository mints the
# same discovery-report hash the abandoned run left behind. Reaping must key on freshness,
# never on that attestation, or the corpse looks owned and keeps bricking the repository.
r12_collide_repo="$installer_tmp/r12-collide-repo"
r11_fixture "$r12_collide_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_collide_repo/.launch-control-onboard/validation-commands.txt"
r12_seed_checkpoint "$r12_collide_repo" samehash
r12_marker "$r12_collide_repo" abandoned-run stale samehash
r12_marker "$r12_collide_repo" second-abandoned-run stale samehash
r11_render "$r12_collide_repo" > "$installer_tmp/r12-collide.out" 2>&1 || {
  printf '%s\n' 'FAIL: an orphan sharing this run discovery hash still blocked the render' >&2
  cat "$installer_tmp/r12-collide.out" >&2
  exit 1
}
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-collide.out"

# Review follow-up: a live run's marker only advances on gated writes, so a validation command
# that legitimately runs longer than the stale threshold looks abandoned. Reaping it would be a
# silent concurrent takeover — worse than the block it replaced. A render in flight must freeze
# the reaper regardless of marker age.
r12_inflight_repo="$installer_tmp/r12-inflight-repo"
r11_fixture "$r12_inflight_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_inflight_repo/.launch-control-onboard/validation-commands.txt"
r12_seed_checkpoint "$r12_inflight_repo" ownhash
r12_marker "$r12_inflight_repo" long-running-run stale
r12_marker "$r12_inflight_repo" second-run stale
r12_inflight_git="$(git -C "$r12_inflight_repo" rev-parse --absolute-git-dir)"
# Stand in for a renderer mid-validation: a live PID whose command name the liveness probe
# recognises, advertised through the same scratch-directory convention the renderer uses.
bash -c 'exec -a render-report.sh sleep 45' &
r12_inflight_pid=$!
mkdir -p "$r12_inflight_git/launch-control-onboard-render-$r12_inflight_pid"
if r11_render "$r12_inflight_repo" > /dev/null 2> "$installer_tmp/r12-inflight.err"; then
  kill "$r12_inflight_pid" 2>/dev/null || true
  printf '%s\n' 'FAIL: markers were reaped while another render was in flight' >&2
  exit 1
fi
kill "$r12_inflight_pid" 2>/dev/null || true
wait "$r12_inflight_pid" 2>/dev/null || true
run_rg -q 'another onboarding render is in flight' "$installer_tmp/r12-inflight.err"
run_rg -q '^multiple active onboarding runs share this repository$' "$installer_tmp/r12-inflight.err"
for r12_survivor in long-running-run second-run; do
  if [ ! -e "$r12_inflight_git/launch-control-onboard-run-$r12_survivor.active" ]; then
    printf 'FAIL: a marker was reaped during an in-flight render: %s\n' "$r12_survivor" >&2
    exit 1
  fi
done
rmdir "$r12_inflight_git/launch-control-onboard-render-$r12_inflight_pid" 2>/dev/null || true

# Round-37: F3 and F6 are gone with the renderer gate and its guard twin. Both keyed on
# `.sandbox.enabled == true` in the project's settings, and every fixture here had to synthesize
# that key with `jq '.sandbox = {enabled: true, ...}'` because onboarding stopped generating it in
# round 36. What they protected was real -- a runner-prefixed gate that passes in the renderer's
# subprocess and then fails "Operation not permitted" in a sandboxed session -- but it is only a
# failure for someone who chose the sandbox, and the pack no longer chooses it for them.
#
# F4/F5 (marker reaping, in-flight renders) are above and unaffected. The `sandbox denial observed
# during run` disclosure is also untouched: that one reports denials in the LIVE session, which
# still happen, and is exercised by 50-round11.sh.

# F7. `6f9bfbb` batched the per-path FINGERPRINTING and left the per-path LEDGER work alone,
# so a 15k-path baseline still rendered in 27m24s on target repo A. Three loops walk the
# baseline one path at a time — two `derive_baseline_preserved_rows` calls and the enforcement
# loop after them — and each iteration forks a `grep` and/or an `awk` that rescans a ledger
# that is itself growing by one row per iteration. That is quadratic work on top of ~43k
# processes. The correctness tests for the batching passed because they never measured.
r12_scale_repo="$installer_tmp/r12-scale-repo"
r11_fixture "$r12_scale_repo"
mkdir -p "$r12_scale_repo/vendor"
r12_scale_count=6000
awk -v n="$r12_scale_count" 'BEGIN { for (i = 1; i <= n; i++) printf "vendor/pkg-%05d.txt\n", i }' \
  > "$r12_scale_repo/.launch-control-onboard/baseline-paths.txt"
while IFS= read -r r12_scale_path; do
  printf 'x\n' > "$r12_scale_repo/$r12_scale_path"
done < "$r12_scale_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './checks/validate-a.sh' > "$r12_scale_repo/.launch-control-onboard/validation-commands.txt"
r12_scale_start="$(date +%s)"
r11_render "$r12_scale_repo" > "$installer_tmp/r12-scale.out" 2> "$installer_tmp/r12-scale.err" || {
  printf '%s\n' 'FAIL: a large untracked baseline blocked the render' >&2
  tail -5 "$installer_tmp/r12-scale.err" >&2
  exit 1
}
r12_scale_elapsed=$(( $(date +%s) - r12_scale_start ))
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-scale.out"
# Post-batching this render is a handful of seconds. The bound is deliberately far above that
# and far below the per-path cost (~190s for this fixture, ~27min at target repo A scale),
# so it separates the two regimes without turning ordinary machine variance into a failure.
if [ "$r12_scale_elapsed" -gt 60 ]; then
  printf 'FAIL: %s-path baseline render took %ss; the per-path ledger walk is back\n' \
    "$r12_scale_count" "$r12_scale_elapsed" >&2
  exit 1
fi
# Collapsed, not dropped: every baseline path is still accounted for.
run_rg -q '^Untouched pre-existing \('"$r12_scale_count"'\):$' "$installer_tmp/r12-scale.out"
run_rg -q '^  vendor/ \('"$r12_scale_count"' paths\)$' "$installer_tmp/r12-scale.out"

# Batched derivation must agree with the per-path routine it replaces: every non-manifest
# baseline path becomes exactly one PRESERVED row, and a path listed twice is derived once —
# the per-path loop got that second property from re-reading a ledger it was growing.
r12_derive_repo="$installer_tmp/r12-derive-repo"
r11_fixture "$r12_derive_repo"
mkdir -p "$r12_derive_repo/vendor"
printf 'x\n' > "$r12_derive_repo/vendor/kept.txt"
printf 'x\n' > "$r12_derive_repo/vendor/also-kept.txt"
printf '%s\n' 'vendor/kept.txt' 'vendor/also-kept.txt' 'vendor/kept.txt' \
  > "$r12_derive_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './checks/validate-a.sh' > "$r12_derive_repo/.launch-control-onboard/validation-commands.txt"
r11_render "$r12_derive_repo" > "$installer_tmp/r12-derive.out" 2> "$installer_tmp/r12-derive.err" || {
  printf '%s\n' 'FAIL: batched baseline derivation rejected a valid ledger' >&2
  tail -5 "$installer_tmp/r12-derive.err" >&2
  exit 1
}
run_rg -q '^Untouched pre-existing \(2\):$' "$installer_tmp/r12-derive.out"
run_rg -q '^  vendor/also-kept\.txt$' "$installer_tmp/r12-derive.out"
run_rg -q '^  vendor/kept\.txt$' "$installer_tmp/r12-derive.out"

# A baseline path the ledger records under a non-PRESERVED status is still a hard failure,
# and the message still names the offending path.
r12_wrongstatus_repo="$installer_tmp/r12-wrongstatus-repo"
r11_fixture "$r12_wrongstatus_repo"
mkdir -p "$r12_wrongstatus_repo/vendor"
printf 'x\n' > "$r12_wrongstatus_repo/vendor/kept.txt"
printf '%s\n' 'vendor/kept.txt' > "$r12_wrongstatus_repo/.launch-control-onboard/baseline-paths.txt"
printf 'CREATED\tvendor/kept.txt\n' >> "$r12_wrongstatus_repo/.launch-control-onboard/ledger.tsv"
printf '%s\n' './checks/validate-a.sh' > "$r12_wrongstatus_repo/.launch-control-onboard/validation-commands.txt"
if r11_render "$r12_wrongstatus_repo" > /dev/null 2> "$installer_tmp/r12-wrongstatus.err"; then
  printf '%s\n' 'FAIL: a baseline path under a non-PRESERVED status was accepted' >&2
  exit 1
fi
run_rg -q '^baseline path is not preserved in ledger: vendor/kept\.txt ' "$installer_tmp/r12-wrongstatus.err"

# F10. The guard captures the baseline with `--untracked-files=all`, one row per FILE, so a
# caller reading plain `git status --short` — which collapses a large untracked tree to a single
# `dir/` entry, the only spelling a Write can practically produce for target repo A's
# 14k-file `.venv/` — declares a path the pre-run inventory never contains. The renderer rejected
# it, and because derivation folds baseline-paths.txt into the ledger first, the rejection was
# attributed to the LEDGER ("list only manifest paths") for a row the renderer had derived itself.
# Told to fix the ledger, the run instead truncated baseline-paths.txt from twelve paths to two,
# dropping ten pre-existing paths out of the report's disclosure. These cases need the hooked
# mode the defect appeared in: only there does a guard-captured inventory exist to check against.
r12_hooked_fixture() {
  local repo="$1" session="$2"
  mkdir -p "$repo/.claude" "$repo/checks"
  git -C "$repo" init -q -b hooked-test
  git -C "$repo" config user.name validator
  git -C "$repo" config user.email validator@example.com
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/checks/validate.sh"
  chmod +x "$repo/checks/validate.sh"
  printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$repo/.claude/settings.json"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  # Pre-existing untracked work must exist BEFORE the guard captures its baseline.
  mkdir -p "$repo/vendorlib/inner"
  printf 'x\n' > "$repo/vendorlib/one.txt"
  printf 'x\n' > "$repo/vendorlib/inner/two.txt"
  jq -n --arg cwd "$repo" --arg prompt '/onboard' \
    '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$ARGS.named.s,prompt:$prompt}' \
    --arg s "$session" | run_guard >/dev/null
  write_discovery_fixture "$repo" hooked-fixture hooked-test none
  jq -n --arg cwd "$repo" --arg command "$policy_discovery_checkpoint" --arg s "$session" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' |
    run_guard >/dev/null
  jq -n --arg cwd "$repo" --arg s "$session" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Write"}' | run_guard >/dev/null
  local git_dir inventory
  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir)"
  inventory="$git_dir/launch-control-onboard-run-$session.inventory"
  test -s "$inventory"
  # Only MANIFEST-scope paths get an explicit ledger row; BASELINE-scope paths are derived.
  awk -F '\t' '$1 ~ /^MANIFEST/ { print ($3 == "absent" ? "SKIPPED" : "PRESERVED") "\t" $2 }' \
    "$inventory" > "$repo/.launch-control-onboard/ledger.tsv"
  printf '%s\n' './checks/validate.sh' > "$repo/.launch-control-onboard/validation-commands.txt"
  : > "$repo/.launch-control-onboard/required-paths.txt"
}
r12_hooked_render() {
  local repo="$1"
  (cd "$repo" && \
    ONBOARD_REQUIRED_PATHS_FILE="$repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" \
    .launch-control-onboard/ledger.tsv hooked-test valid absent ready \
    .launch-control-onboard/validation-commands.txt none complete)
}

r12_dirform_repo="$installer_tmp/r12-dirform-repo"
r12_hooked_fixture "$r12_dirform_repo" dirform-proof
printf '%s\n' 'vendorlib/' > "$r12_dirform_repo/.launch-control-onboard/baseline-paths.txt"
r12_hooked_render "$r12_dirform_repo" > "$installer_tmp/r12-dirform.out" 2> "$installer_tmp/r12-dirform.err" || {
  printf '%s\n' 'FAIL: renderer rejected the git-status directory form of a baseline path' >&2
  tail -5 "$installer_tmp/r12-dirform.err" >&2
  exit 1
}
# The two files the guard actually captured are disclosed, and the collapsed entry adds no
# phantom row: a count of 3 here would mean the report claimed a path that is not a file.
run_rg -q '^Untouched pre-existing \(2\):$' "$installer_tmp/r12-dirform.out"
run_rg -q '^  vendorlib/inner/two\.txt$' "$installer_tmp/r12-dirform.out"
run_rg -q '^  vendorlib/one\.txt$' "$installer_tmp/r12-dirform.out"
if run_rg -q '^  vendorlib/$' "$installer_tmp/r12-dirform.out"; then
  printf '%s\n' 'FAIL: report listed a collapsed directory alongside the files it covers' >&2
  exit 1
fi

# A directory form covering nothing in the inventory is still a hard failure — but the message
# must name the file the path actually came from, not send the caller to edit the ledger.
r12_badbase_repo="$installer_tmp/r12-badbase-repo"
r12_hooked_fixture "$r12_badbase_repo" badbase-proof
printf '%s\n' 'no-such-dir/' > "$r12_badbase_repo/.launch-control-onboard/baseline-paths.txt"
if r12_hooked_render "$r12_badbase_repo" > /dev/null 2> "$installer_tmp/r12-badbase.err"; then
  printf '%s\n' 'FAIL: a baseline path covering nothing in the inventory was accepted' >&2
  exit 1
fi
run_rg -q '^declared baseline path is absent from the pre-run inventory: no-such-dir/ ' \
  "$installer_tmp/r12-badbase.err"
if run_rg -q 'list only manifest paths' "$installer_tmp/r12-badbase.err"; then
  printf '%s\n' 'FAIL: a baseline-file defect was again attributed to the ledger' >&2
  exit 1
fi

# F16. `git status --short` C-QUOTES any path holding a space, tab, quote, backslash, or non-ASCII
# byte, and every capture site stripped the status prefix and used what was left as a real path.
# Nothing resolved it, and nothing said so: the path fingerprinted as `absent` before AND after
# validation, so no delta was ever produced and a validation command could rewrite an already-dirty
# file whose name contains a space while the render emitted a clean completion report. Observed on
# target repo A, which carried two such paths under `.venv/`.
#
# The load-bearing case: both files tracked, committed, and ALREADY DIRTY at run start, so the
# porcelain line is identical before and after the rewrite and only the fingerprint gate can catch
# it. The plain path is the control -- it blocked before this fix and must still block.
r12_quote_repo="$installer_tmp/r12-quote-repo"
r11_fixture "$r12_quote_repo"
printf 'original\n' > "$r12_quote_repo/vendor-plain.txt"
printf 'original\n' > "$r12_quote_repo/vendor with space.txt"
git -C "$r12_quote_repo" add 'vendor-plain.txt' 'vendor with space.txt'
git -C "$r12_quote_repo" commit -qm vendor
r12_quote_case() {
  local target="$1" name="$2"
  git -C "$r12_quote_repo" checkout -q -- 'vendor-plain.txt' 'vendor with space.txt'
  printf 'dirty\n' > "$r12_quote_repo/vendor-plain.txt"
  printf 'dirty\n' > "$r12_quote_repo/vendor with space.txt"
  (cd "$r12_quote_repo" && git status --short --untracked-files=all | awk '{ print substr($0, 4) }') \
    > "$r12_quote_repo/.launch-control-onboard/baseline-paths.txt"
  rm -f "$r12_quote_repo/.launch-control-onboard/worktree-status.start" \
        "$r12_quote_repo/.launch-control-onboard/worktree-status.start.fingerprints"
  printf '%s\n' './checks/validate-a.sh' > "$r12_quote_repo/.launch-control-onboard/validation-commands.txt"
  # LC-037: nothing executes during a render any more, so the rewrite happens between two renders
  # of the same run. The first render captures the run-start anchor; the second reuses it, exactly
  # as a retry does, and must see the already-dirty path change underneath it.
  r11_render "$r12_quote_repo" > "$installer_tmp/$name-first.out" 2> "$installer_tmp/$name-first.err"
  printf 'REWRITTEN\n' > "$r12_quote_repo/$target"
  if r11_render "$r12_quote_repo" > "$installer_tmp/$name.out" 2> "$installer_tmp/$name.err"; then
    printf 'FAIL: a rewritten already-dirty path was not detected: %s\n' "$target" >&2
    exit 1
  fi
  run_rg -q 'run-introduced changes \(content of already-dirty paths since run start\)' \
    "$installer_tmp/$name.err"
}
r12_quote_case 'vendor-plain.txt' r12-quote-control
r12_quote_case 'vendor with space.txt' r12-quote-spaced

# F16's unfinished tail, found live on toolshed. A NEWLINE is the one member of git's C-quoting
# class that decoding does not rescue, because the decoded path cannot be written to any of the
# line-oriented files this machinery is built from: one record becomes N physical lines, and every
# consumer that reads `$1` per line then sees phantom paths. Measured: a single zero-byte file
# named from a botched heredoc turned into three fake entries (`{b!r}}")`, `print(...)`, `PY`),
# each fingerprinted `absent` now against `file` at run start, and the render BLOCKED with
# "the workspace changed outside the declared writes of this run" over a run whose validation commands had been
# disclosed-not-run and had written nothing at all. Unrecoverable for the user: the Next line tells
# them to redirect writes that never happened.
#
# Both capture sites carry it -- the guard's `capture_run_anchor` and the renderer's lazy
# `capture_run_start_fingerprints`. This case drives the renderer's.
#
# The contract: such a path is UNVERIFIABLE, not changed. It routes to the same
# `Protected, content unverified` disclosure an unreadable path uses, spelled the one way that
# fits on a line -- git's own C-quoted form -- and it must never manufacture a delta.
r12_newline_repo="$installer_tmp/r12-newline-repo"
r11_fixture "$r12_newline_repo"
r12_newline_name='{b!r}}")
print("payload keys same:")
PY'
: > "$r12_newline_repo/$r12_newline_name"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r12_newline_repo/checks/validate-a.sh"
chmod +x "$r12_newline_repo/checks/validate-a.sh"
printf '%s\n' './checks/validate-a.sh' > "$r12_newline_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r12_newline_repo" > "$installer_tmp/r12-newline.out" 2> "$installer_tmp/r12-newline.err"; then
  printf '%s\n' 'FAIL: an untouched path whose name holds a newline blocked the render' >&2
  tail -8 "$installer_tmp/r12-newline.err" >&2
  exit 1
fi
if run_rg -q 'run-introduced changes' "$installer_tmp/r12-newline.err"; then
  printf '%s\n' 'FAIL: a newline-named path nothing touched was charged as a run-introduced change' >&2
  exit 1
fi
# Disclosed, not silently dropped: the run cannot verify it, and must say so.
# It lands in a group of its OWN, not in `Protected, content unverified`. `f03560a` put it there
# because "content unverified" was true of it, without checking that the group's closing note
# asserts a specific CAUSE -- "the generated secret boundary denies this run read access" -- which
# for this path is simply false: nothing denied anything, the name will not fit on a line. That is
# the same defect class as the `Failed`-list provenance bug (`91dc993`), a report stating a cause
# the machine never established, and introducing it while fixing the fragments is what this pins.
run_rg -q '^Unrepresentable path names \(1\):$' "$installer_tmp/r12-newline.out"
run_rg -qF -- '"{b!r}}\")\nprint(\"payload keys same:\")\nPY"' "$installer_tmp/r12-newline.out"
if run_rg -q '^Protected, content unverified' "$installer_tmp/r12-newline.out"; then
  printf '%s\n' 'FAIL: an unrepresentable name was disclosed under a group that blames a read denial' >&2
  exit 1
fi
# The note that ships with the new group must state what actually happened. Asserted on the prose,
# not merely on the heading: a group whose count is right and whose explanation is wrong is exactly
# what the live run produced.
run_rg -q 'Nothing denied access to them and' "$installer_tmp/r12-newline.out"
# The phantom fragments must appear nowhere: they are not paths, and naming them as paths is the
# defect wearing a different hat.
if run_rg -q '^  PY$' "$installer_tmp/r12-newline.out"; then
  printf '%s\n' 'FAIL: a fragment of a newline path was reported as a path of its own' >&2
  exit 1
fi

# ==================================================================================
# The report surface the live toolshed run actually broke on, which the case above did NOT reach.
# That one drives the renderer's own lazy fingerprint capture; this one drives the GUARD's baseline
# capture, whose output becomes `Untouched pre-existing` -- a different producer, a different file,
# and the one that shipped broken. Measured live: `Untouched pre-existing (213)` listing `PY` and
# two code fragments as repository paths, count inflated by two, under a heading that claims every
# path above was captured and verified.
#
# The guard's file is fed to the renderer through the same `normalize_baseline_quoting` entry point
# the agent-supplied file uses (render-report.sh loads the run's `.baseline` at one call site and
# `ONBOARD_BASELINE_PATHS_FILE` at the other), so routing the guard's real output through the
# degraded-mode slot exercises the identical pipeline without standing up a full hooked render.
r12_gbase_repo="$installer_tmp/r12-gbase-repo"
r11_fixture "$r12_gbase_repo"
: > "$r12_gbase_repo/$r12_newline_name"
printf 'ordinary\n' > "$r12_gbase_repo/plain-untracked.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r12_gbase_repo/checks/validate-a.sh"
chmod +x "$r12_gbase_repo/checks/validate-a.sh"
printf '%s\n' './checks/validate-a.sh' > "$r12_gbase_repo/.launch-control-onboard/validation-commands.txt"
write_discovery_fixture "$r12_gbase_repo" r12-gbase validator none
jq -n --arg cwd "$r12_gbase_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r12gbase",tool_name:"Bash",tool_input:{command:$command}}' | run_guard > /dev/null
jq -n --arg cwd "$r12_gbase_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r12gbase",tool_name:"Write",tool_input:{file_path:"CLAUDE.md"}}' | run_guard > /dev/null
cp "$r12_gbase_repo/.git/launch-control-onboard-run-r12gbase.baseline" \
  "$r12_gbase_repo/.launch-control-onboard/baseline-paths.txt"
# The ledger keeps only the row the fixture wrote: `derive_baseline_preserved_rows` invents a
# PRESERVED row per baseline path, which is precisely how the fragments reached the live report.
# Hand-listing them instead would trip the ledger existence check and hide the defect.
# The run-anchor sidecar is removed so the disclosure below can only come from the BASELINE
# capture's own sidecar -- otherwise this case passes on the strength of `f03560a`'s fix.
rm -f "$r12_gbase_repo/.launch-control-onboard/worktree-status.start.unrepresentable"
if ! r11_render "$r12_gbase_repo" > "$installer_tmp/r12-gbase.out" 2> "$installer_tmp/r12-gbase.err"; then
  printf '%s\n' 'FAIL: a newline-named path in the guard baseline blocked the render' >&2
  tail -8 "$installer_tmp/r12-gbase.err" >&2
  exit 1
fi
# The count is the assertion the live report failed: two real paths, one of which cannot be
# represented, so exactly one is listed. Before the fix this read 4 and listed three fragments.
run_rg -q '^Untouched pre-existing \(1\):$' "$installer_tmp/r12-gbase.out"
run_rg -qx -- '  plain-untracked\.txt' "$installer_tmp/r12-gbase.out"
while IFS= read -r r12_gbase_fragment; do
  if run_rg -qxF -- "  $r12_gbase_fragment" "$installer_tmp/r12-gbase.out"; then
    printf 'FAIL: a fragment of a newline path was reported as a path: %s\n' "$r12_gbase_fragment" >&2
    exit 1
  fi
done <<'R12_GBASE_FRAGMENTS'
PY
print("payload keys same:")
{b!r}}")
R12_GBASE_FRAGMENTS
# Disclosed exactly once, by the baseline capture alone.
run_rg -q '^Unrepresentable path names \(1\):$' "$installer_tmp/r12-gbase.out"
run_rg -qF -- '"{b!r}}\")\nprint(\"payload keys same:\")\nPY"' "$installer_tmp/r12-gbase.out"

# ==================================================================================
# Site 6, the agent-supplied baseline file. SKILL.md asks for plain `git status --short
# --untracked-files=all`, which C-quotes such a name onto ONE line, so the quoted spelling reaches
# `normalize_baseline_quoting()` -- which decoded it and wrote the result into its own
# line-oriented `$normalized`. Degraded mode only, and never exercised either way before this.
r12_abase_repo="$installer_tmp/r12-abase-repo"
r11_fixture "$r12_abase_repo"
: > "$r12_abase_repo/$r12_newline_name"
printf 'ordinary\n' > "$r12_abase_repo/plain-untracked.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r12_abase_repo/checks/validate-a.sh"
chmod +x "$r12_abase_repo/checks/validate-a.sh"
printf '%s\n' './checks/validate-a.sh' > "$r12_abase_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' 'plain-untracked.txt' '"{b!r}}\")\nprint(\"payload keys same:\")\nPY"' \
  > "$r12_abase_repo/.launch-control-onboard/baseline-paths.txt"
if ! r11_render "$r12_abase_repo" > "$installer_tmp/r12-abase.out" 2> "$installer_tmp/r12-abase.err"; then
  printf '%s\n' 'FAIL: a quoted newline path in the agent baseline blocked the render' >&2
  tail -8 "$installer_tmp/r12-abase.err" >&2
  exit 1
fi
run_rg -q '^Untouched pre-existing \(1\):$' "$installer_tmp/r12-abase.out"
if run_rg -qx -- '  PY' "$installer_tmp/r12-abase.out"; then
  printf '%s\n' 'FAIL: normalize_baseline_quoting split a newline name into reported paths' >&2
  exit 1
fi
run_rg -q '^Unrepresentable path names \(1\):$' "$installer_tmp/r12-abase.out"

# ==================================================================================
# Site 7, the agent-supplied preserve-hashes file. Its in-code comment claimed "a newline cannot
# occur here at all: this file is line-delimited, so such a path could never have been written to
# it" -- true of the INPUT line (`<hash>  "quoted\npath"` is one legal line) and false of the value
# the comment guarded, because the decode two lines above turns it into a name holding newlines
# that then goes into the line-oriented, tab-delimited `$preserve_expected`. The fragments are not
# files and are not read-denied, so they reach `$preserve_mismatch` as `(missing)` and FAIL the
# render outright, claiming preserved content changed. Worse than the listing defect: unrecoverable.
r12_aph_repo="$installer_tmp/r12-aph-repo"
r11_fixture "$r12_aph_repo"
: > "$r12_aph_repo/$r12_newline_name"
printf 'ordinary\n' > "$r12_aph_repo/plain-untracked.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r12_aph_repo/checks/validate-a.sh"
chmod +x "$r12_aph_repo/checks/validate-a.sh"
printf '%s\n' './checks/validate-a.sh' > "$r12_aph_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' 'plain-untracked.txt' > "$r12_aph_repo/.launch-control-onboard/baseline-paths.txt"
r12_aph_plain="$(cd "$r12_aph_repo" && { shasum -a 256 plain-untracked.txt 2>/dev/null ||
  sha256sum plain-untracked.txt; } | awk '{ print $1 }')"
r12_aph_empty="$(printf '' | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print $1 }')"
{
  printf '%s  %s\n' "$r12_aph_plain" 'plain-untracked.txt'
  printf '%s  %s\n' "$r12_aph_empty" '"{b!r}}\")\nprint(\"payload keys same:\")\nPY"'
} > "$r12_aph_repo/.launch-control-onboard/preserve-hashes.txt"
if ! r11_render "$r12_aph_repo" > "$installer_tmp/r12-aph.out" 2> "$installer_tmp/r12-aph.err"; then
  printf '%s\n' 'FAIL: a quoted newline path in preserve-hashes failed the render' >&2
  tail -8 "$installer_tmp/r12-aph.err" >&2
  exit 1
fi
if run_rg -qF -- '(missing)' "$installer_tmp/r12-aph.err"; then
  printf '%s\n' 'FAIL: fragments of a newline path were reported as missing preserved paths' >&2
  exit 1
fi
run_rg -q '^Unrepresentable path names \(1\):$' "$installer_tmp/r12-aph.out"

# The decoded path is what reaches the report, so the listing shows a real path and the collapse
# groups it under its true top-level directory. Before the fix `".venv` split off as a second,
# differently-spelled directory beside `.venv`, and the section still claimed every path above had
# been captured and verified.
r12_quotereport_repo="$installer_tmp/r12-quotereport-repo"
r11_fixture "$r12_quotereport_repo"
mkdir -p "$r12_quotereport_repo/vendor"
printf 'x\n' > "$r12_quotereport_repo/vendor/plain.txt"
printf 'x\n' > "$r12_quotereport_repo/vendor/with space.txt"
printf 'x\n' > "$r12_quotereport_repo/vendor/caf-eacute.txt"
(cd "$r12_quotereport_repo" && git status --short --untracked-files=all | awk '{ print substr($0, 4) }') \
  > "$r12_quotereport_repo/.launch-control-onboard/baseline-paths.txt"
run_rg -q '^"vendor/with space\.txt"$' "$r12_quotereport_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './checks/validate-a.sh' > "$r12_quotereport_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r12_quotereport_repo" > "$installer_tmp/r12-quotereport.out" 2> "$installer_tmp/r12-quotereport.err"; then
  printf '%s\n' 'FAIL: a baseline holding a quoted path could not be rendered' >&2
  tail -5 "$installer_tmp/r12-quotereport.err" >&2
  exit 1
fi
run_rg -q '^  vendor/with space\.txt$' "$installer_tmp/r12-quotereport.out"
if run_rg -q '^  "vendor' "$installer_tmp/r12-quotereport.out"; then
  printf '%s\n' 'FAIL: a git-quoted path reached the report with its quotes intact' >&2
  exit 1
fi

