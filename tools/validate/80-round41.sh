# shellcheck shell=bash
# Round 41 — a missing generated permission never blocks a run.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures, $installer_tmp,
# run_rg/check_absent from tools/validate/lib.sh and reset_run_anchor from 40-report-contract.sh.
#
# Observed live on target repo B: a rerun over a generated workspace that had never been
# committed pinned `.claude/settings.json` PRESERVED under the dirty-baseline rule, so the
# contract command `npm run test:avatar-motion:unit` — absent from the previous run's allow list
# — could register its exact `Bash(<command>)` permission nowhere. The renderer refused the whole
# render over that, and the run reported a complete, healthy workspace as blocked, handing the
# user a `Next:` that asked them to commit generated output. The pin is correct and stays; the
# precondition it collided with is gone. The shape checks are the execution boundary, and they
# never depended on a file this same run writes.
r41_repo="$installer_tmp/r41-unregistrable-permission"
mkdir -p "$r41_repo/.claude" "$r41_repo/.launch-control-onboard" "$r41_repo/shims"
git -C "$r41_repo" init -q -b main
printf 'seed\n' > "$r41_repo/seed.txt"
git -C "$r41_repo" add seed.txt
git -C "$r41_repo" commit -qm baseline
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r41_repo/shims/npm"
chmod +x "$r41_repo/shims/npm"
# The generated workspace from an earlier run: uncommitted, therefore dirty in the pre-run
# baseline, therefore PRESERVED — and its allow list predates the contract command below.
printf '%s\n' '{"permissions":{"allow":["Bash(npm run lint)"]}}' > "$r41_repo/.claude/settings.json"
printf 'PRESERVED\t.claude/settings.json\n' > "$r41_repo/.launch-control-onboard/ledger.tsv"
: > "$r41_repo/.launch-control-onboard/required-paths.txt"
printf '.claude/settings.json\n' > "$r41_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' 'npm run test:avatar-motion:unit' > "$r41_repo/.launch-control-onboard/validation-commands.txt"
(cd "$r41_repo" && PATH="$r41_repo/shims:$PATH" \
  ONBOARD_REQUIRED_PATHS_FILE="$r41_repo/.launch-control-onboard/required-paths.txt" \
  ONBOARD_BASELINE_PATHS_FILE="$r41_repo/.launch-control-onboard/baseline-paths.txt" \
  "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv main \
  valid absent ready .launch-control-onboard/validation-commands.txt none complete) \
  > "$installer_tmp/r41-unregistrable.out" 2> "$installer_tmp/r41-unregistrable.err"
run_rg -q '=== Workspace Setup Complete ===' "$installer_tmp/r41-unregistrable.out"
# The gate is recorded and reported as documented; onboarding never executes it.
run_rg -q '^  validation: not run \(1 documented gate;' "$installer_tmp/r41-unregistrable.out"
# And the reader still learns the generated permissions were not applied.
run_rg -q '^  \.claude/settings\.json$' "$installer_tmp/r41-unregistrable.out"
if run_rg -q 'permission' "$installer_tmp/r41-unregistrable.err"; then
  printf '%s\n' 'FAIL: renderer still diagnoses the unregistrable permission' >&2
  exit 1
fi

# The precondition must not come back in any spelling. It is easy to re-add as "safety" — it
# reads like one — so pin its absence rather than only its symptom.
check_absent 'lacks an exact generated permission' "$ROOT/skills/onboard/scripts/render-report.sh"
check_absent 'pinned PRESERVED by the dirty-baseline rule' "$ROOT/skills/onboard/scripts/render-report.sh"

# The doctrine has to agree, or the run predicts a block the renderer no longer emits.
run_rg -q 'An unregistrable permission is' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
check_absent 'A second structurally unsatisfiable state' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
check_absent 'lacking its exact generated permission' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
