# shellcheck shell=bash
# Renderer report fidelity, recorded gates, recursive dogfood.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
# Run the producer directly: process substitution hides its exit status from callers.
python3 - "$ROOT" "$installer_tmp" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
source = (root / 'skills/onboard/scripts/render-report.sh').read_text()
function = re.search(r'^ci_config_files\(\) \{\n.*?^\}', source, re.M | re.S).group()
repo = scratch / 'ci-discovery'
repo.mkdir()
for populated in (False, True):
    if populated:
        (repo / '.github/workflows').mkdir(parents=True)
        for name in ('.github/workflows/a.yml', '.github/workflows/b.yaml', '.gitlab-ci.yml'):
            (repo / name).touch()
    for nullglob in ('s', 'u'):
        script = 'set -euo pipefail\n' + function + '\nshopt -' + nullglob + ' nullglob\nci_config_files\n'
        script += 'shopt -q nullglob' if nullglob == 's' else '! shopt -q nullglob'
        result = subprocess.run(['/bin/bash', '-c', script], cwd=repo, text=True, capture_output=True)
        assert result.returncode == 0 and not result.stderr, (result.returncode, result.stderr)
        expected = '.github/workflows/a.yml\n.github/workflows/b.yaml\n.gitlab-ci.yml\n' if populated else ''
        assert result.stdout == expected, result.stdout
PY

# Fixture repos reuse one .launch-control-onboard across scenarios; each scenario is a new
# "run", so the renderer's run-start workspace anchor and attempt counters must be reset
# whenever a scenario intentionally mutates the fixture tree between renders.
reset_run_anchor() {
  rm -f "$1/.launch-control-onboard/worktree-status.start" \
    "$1/.launch-control-onboard/worktree-status.start.fingerprints" \
    "$1/.launch-control-onboard/worktree-status.start.partial" \
    "$1/.launch-control-onboard/worktree-status.start.fingerprints.partial" \
    "$1/.launch-control-onboard/preserve-hashes.guard.txt" \
    "$1/.launch-control-onboard/write-order.guard.txt"
}

# F28, second pass. The report carries the session's permission mode, derived from the
# marker the unattended policy drops, because two acceptance runs completed under bypass
# without ever disclosing it and the renderer had no way to contradict them. Absence of the
# marker must never render as a mode -- in degraded mode no hook runs at all -- so pin
# the exact wording of both branches, not merely that some line is present.
f28_repo="$installer_tmp/permission-mode-repo"
mkdir -p "$f28_repo/.claude" "$f28_repo/.launch-control-onboard"
git -C "$f28_repo" init -q -b main
git -C "$f28_repo" config user.name validator
git -C "$f28_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$f28_repo/noop.sh"
chmod +x "$f28_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$f28_repo/.claude/settings.json"
git -C "$f28_repo" add noop.sh .claude/settings.json
git -C "$f28_repo" commit -qm baseline
printf '%s\t%s\n' PRESERVED .claude/settings.json > "$f28_repo/.launch-control-onboard/ledger.tsv"
: > "$f28_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './noop.sh' > "$f28_repo/.launch-control-onboard/validation.txt"
f28_git="$(git -C "$f28_repo" rev-parse --absolute-git-dir)"
: > "$f28_git/launch-control-onboard-run-f28session.active"
: > "$f28_git/launch-control-onboard-run-f28session.baseline"
printf 'MANIFEST\t%s\tfile\t%s\t0\n' .claude/settings.json \
  "$(git -C "$f28_repo" hash-object --no-filters "$f28_repo/.claude/settings.json")" \
  > "$f28_git/launch-control-onboard-run-f28session.inventory"
f28_render() {
  (cd "$f28_repo" && ONBOARD_BASELINE_PATHS_FILE=.launch-control-onboard/baseline-paths.txt \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv main \
    valid absent ready .launch-control-onboard/validation.txt none complete)
}
rm -f "$f28_git/launch-control-onboard-run-f28session.bypass"
f28_render > "$installer_tmp/permission-mode-default.out" 2> "$installer_tmp/permission-mode-default.err"
test ! -s "$installer_tmp/permission-mode-default.err"
run_rg -q '^  permission-mode: none recorded$' \
  "$installer_tmp/permission-mode-default.out"
: > "$f28_git/launch-control-onboard-run-f28session.bypass"
f28_render > "$installer_tmp/permission-mode-bypass.out"
run_rg -q '^  permission-mode: bypassPermissions -- ask-gates were denied, not asked$' \
  "$installer_tmp/permission-mode-bypass.out"

# Round-18: bypassPermissions was the ONLY mode the report distinguished, so every other
# mode rendered as nothing at all -- an `auto` acceptance pair proved it live. Pin all four
# branches: a recorded mode must NAME itself and nothing more, the bypass branch must still
# win when both markers exist, and an untrustworthy marker must fall back to the
# claims-nothing default rather than blocking the render or echoing junk into the report.
f28_perm="$f28_git/launch-control-onboard-run-f28session.permission-mode"
rm -f "$f28_git/launch-control-onboard-run-f28session.bypass"
printf '%s\n' auto > "$f28_perm"
f28_render > "$installer_tmp/permission-mode-auto.out"
run_rg -q '^  permission-mode: auto$' \
  "$installer_tmp/permission-mode-auto.out"
printf '%s\n' default > "$f28_perm"
f28_render > "$installer_tmp/permission-mode-explicit-default.out"
run_rg -q '^  permission-mode: default$' \
  "$installer_tmp/permission-mode-explicit-default.out"
# Both markers present: bypass is the stricter fact (it converts `ask` into a hard denial),
# so it must not be masked by the mode record the same policy writes beside it.
: > "$f28_git/launch-control-onboard-run-f28session.bypass"
printf '%s\n' bypassPermissions > "$f28_perm"
f28_render > "$installer_tmp/permission-mode-both.out"
run_rg -q '^  permission-mode: bypassPermissions -- ask-gates were denied, not asked$' \
  "$installer_tmp/permission-mode-both.out"
rm -f "$f28_git/launch-control-onboard-run-f28session.bypass"
printf '%s\n' 'auto; rm -rf /' > "$f28_perm"
f28_render > "$installer_tmp/permission-mode-junk.out"
run_rg -q '^  permission-mode: none recorded$' \
  "$installer_tmp/permission-mode-junk.out"
if run_rg -q 'rm -rf' "$installer_tmp/permission-mode-junk.out"; then
  printf '%s\n' 'FAIL: renderer echoed an untrusted permission-mode marker into the report' >&2
  exit 1
fi
rm -f "$f28_perm"
# LC-058: the line records the session's mode; it never grades the run for the mode the user chose.
for f28_out in "$installer_tmp"/permission-mode-*.out; do
  if run_rg -q 'permission-mode:.*reviewed' "$f28_out"; then
    printf 'FAIL: the permission-mode line graded the run as reviewed or not: %s\n' "$f28_out" >&2
    exit 1
  fi
done

# Round-22: found on the first default-mode acceptance pair. The harness wrote
# `.claude/settings.local.json` into BOTH acceptance repositories the moment the user answered a
# permission prompt, and neither report named it in any section. The cause is not the generated
# `.claude/*.local.*` ignore rule (that only hides it from `git status` as well) -- every section
# is sourced from the ledger, the manifest, and the run-start baseline, so a path first appearing
# after the anchor is accounted to none of the three. It also does not block, which is what
# separates it from GAP-1 below: a MUTATED tracked path blocks the render, a NEW foreign path does
# not. What happens to it then splits by ownership, and both halves are pinned here: the
# harness-owned local family is dropped silently, while any OTHER git-visible foreign path falls
# through to the `New untracked paths` group and IS named. The disclosure line must say exactly that
# -- it used to claim every such path "appears in no section above", which the stray path below
# disproves. Deliberately git-visible, not ignored -- an ignored fixture would pass for the wrong
# reason and let the narrow "gitignore" story back in.
accounting_repo="$installer_tmp/worktree-accounting-repo"
mkdir -p "$accounting_repo/.claude" "$accounting_repo/.launch-control-onboard"
git -C "$accounting_repo" init -q -b main
git -C "$accounting_repo" config user.name validator
git -C "$accounting_repo" config user.email validator@example.com
printf '%s\n' 'node_modules' > "$accounting_repo/.gitignore"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$accounting_repo/noop.sh"
chmod +x "$accounting_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$accounting_repo/.claude/settings.json"
git -C "$accounting_repo" add .gitignore noop.sh .claude/settings.json
git -C "$accounting_repo" commit -qm baseline
printf '%s\t%s\n' PRESERVED .claude/settings.json > "$accounting_repo/.launch-control-onboard/ledger.tsv"
: > "$accounting_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './noop.sh' > "$accounting_repo/.launch-control-onboard/validation.txt"
accounting_render() {
  (cd "$accounting_repo" && ONBOARD_BASELINE_PATHS_FILE=.launch-control-onboard/baseline-paths.txt \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv main \
    valid absent ready .launch-control-onboard/validation.txt none complete)
}
accounting_render > "$installer_tmp/worktree-accounting-anchor.out"
test -f "$accounting_repo/.launch-control-onboard/worktree-status.start"
# Foreign, git-visible, created strictly after the anchor -- the shape the harness produced live.
#
# This repository's .gitignore carries only `node_modules`, which is the point: it stands for a
# repository that does not have onboarding's `.claude/*.local.*` rules, exactly what `--launch-control`
# leaves behind since maintenance mode may not modify .gitignore. Until the renderer asserted
# ownership of the harness-owned family directly, this path was swept into the `.claude/`
# contamination rule and BLOCKED the render -- so a user answering a permission prompt killed
# their own run. It passed here only because a developer's global excludes file
# (`~/.config/git/ignore`, which applies with `core.excludesFile` unset) commonly hides this
# very name, which is why the fixture must never be read as proving the path was git-visible.
# It asserts visibility itself now, rather than trusting the ambient environment.
printf '%s\n' '{"permissions":{"allow":["Skill(docs-create)"]}}' > "$accounting_repo/.claude/settings.local.json"
# Neutralize the developer's global excludes rather than asserting they are absent: pinning
# `core.excludesFile` per repository makes the path git-visible on every machine, where an
# assertion would instead fail the suite for anyone carrying the common
# `**/.claude/settings.local.json` rule. The check below then confirms the neutralization
# worked, so the fixture still cannot silently revert to passing for the wrong reason.
git -C "$accounting_repo" config core.excludesFile /dev/null
if git -C "$accounting_repo" check-ignore -q .claude/settings.local.json; then
  printf '%s\n' 'FAIL: the worktree-accounting fixture path is ignored, so it cannot test a git-visible foreign path' >&2
  exit 1
fi
# A genuinely foreign path that is NOT harness-owned, to keep the carve-out from being the only
# thing under test. It must not block either, but it IS repository output and is named.
printf 'stray\n' > "$accounting_repo/stray-tool-output.txt"
accounting_render > "$installer_tmp/worktree-accounting.out"
run_rg -q '^=== End Workspace Setup ===$' "$installer_tmp/worktree-accounting.out"
run_rg -q '^  worktree-accounting: ledger, manifest, and run-start baseline only -- a git-visible foreign path created during the run is named under New untracked paths; a harness-owned local file appears in no section above$' \
  "$installer_tmp/worktree-accounting.out"
if run_rg -q 'settings\.local\.json' "$installer_tmp/worktree-accounting.out"; then
  printf '%s\n' 'FAIL: a harness-owned local file was reported; onboarding neither writes nor ships it' >&2
  exit 1
fi
# The section it lands in is the half of the disclosure line that used to be wrong, so pin the
# group header too: naming the path somewhere is not the same claim as naming it HERE.
run_rg -q '^New untracked paths \(1\):$' "$installer_tmp/worktree-accounting.out"
run_rg -q '^  stray-tool-output\.txt$' "$installer_tmp/worktree-accounting.out"

# LC-045: the generated delivery skill is `launch` now. The trusted finalizer parks a committed
# old `send-it` tree once the complete `launch` tree exists, in every mode, so maintenance runs
# migrate too; the report names the move. Both trees are committed, so accounting sees no delta.
retire_repo="$installer_tmp/lc045-retire-repo"
mkdir -p "$retire_repo/.claude" "$retire_repo/.launch-control-onboard"
git -C "$retire_repo" init -q -b main
git -C "$retire_repo" config user.name validator
git -C "$retire_repo" config user.email validator@example.com
git -C "$retire_repo" config core.excludesFile /dev/null
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$retire_repo/.claude/settings.json"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$retire_repo/noop.sh"
chmod +x "$retire_repo/noop.sh"
for retire_file in SKILL.md references/delivery.md references/implementation.md references/ticket-intake.md references/verification.md; do
  for retire_skill in send-it launch; do
    mkdir -p "$(dirname "$retire_repo/.claude/skills/$retire_skill/$retire_file")"
    printf '%s %s\n' "$retire_skill" "$retire_file" > "$retire_repo/.claude/skills/$retire_skill/$retire_file"
  done
done
git -C "$retire_repo" add -A
git -C "$retire_repo" commit -qm baseline
printf '%s\t%s\n' PRESERVED .claude/settings.json > "$retire_repo/.launch-control-onboard/ledger.tsv"
: > "$retire_repo/.launch-control-onboard/baseline-paths.txt"
printf '%s\n' './noop.sh' > "$retire_repo/.launch-control-onboard/validation.txt"
(cd "$retire_repo" && ONBOARD_BASELINE_PATHS_FILE=.launch-control-onboard/baseline-paths.txt LAUNCH_CONTROL_NO_OPEN=1 \
  "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv main \
  valid absent ready .launch-control-onboard/validation.txt none complete) > "$installer_tmp/lc045-retire.out"
run_rg -q '^RETIRE \.claude/skills/send-it \(now launch\)$' "$installer_tmp/lc045-retire.out"
test ! -e "$retire_repo/.claude/skills/send-it"
test -f "$retire_repo/.claude/skills/launch/SKILL.md"

# LC-044: the HTML view. The report links it, the page is self-contained, and the renderer opens
# it only for a person at a desktop: never for a Launch worker, CI, or this suite.
accounting_html="$(git -C "$accounting_repo" rev-parse --absolute-git-dir)/launch-control/onboard-report.html"
run_rg -q '^Visual report: file:///.*/launch-control/onboard-report\.html$' "$installer_tmp/worktree-accounting.out"
test "$(tail -3 "$installer_tmp/worktree-accounting.out" | head -1)" = \
  "$(run_rg '^Visual report: ' "$installer_tmp/worktree-accounting.out")"
test -f "$accounting_html"
# The standalone template and rendered report carry the same full font notices as the bundle.
python3 - "$ROOT" "$accounting_html" <<'PY'
import html
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
assets = root / 'skills/onboard/assets'
notices = []
for name, copyright in (
    ('ANTON', 'Copyright 2020 The Anton Project Authors'),
    ('BARLOW', 'Copyright 2017 The Barlow Project Authors'),
    ('IBMPlexMono', 'Copyright © 2017 IBM Corp. with Reserved Font Name "Plex"'),
):
    text = (assets / (name + '-OFL.txt')).read_text()
    assert copyright in text
    assert 'SIL OPEN FONT LICENSE Version 1.1' in text
    assert all(section in text for section in ('PREAMBLE', 'DEFINITIONS', 'PERMISSION & CONDITIONS', 'TERMINATION', 'DISCLAIMER'))
    notices.append(text.strip())
for path in (assets / 'completion-report.html', Path(sys.argv[2])):
    block = re.search(r'<template id="font-licenses"><pre>(.*?)</pre></template>', path.read_text(), re.S)
    assert block and html.unescape(block[1]) == '\n\n'.join(notices), str(path) + ': incomplete font notices'
assert 'contains no third-party' not in (root / 'skills/onboard/NOTICE').read_text()
PY
run_rg -q '<meta http-equiv="Content-Security-Policy" content="default-src .none.;' "$accounting_html"
if run_rg -q '(src|href)=["'"'"']?https?:|__REPORT_DATA__' "$accounting_html"; then
  printf '%s\n' 'FAIL: the HTML report loads a remote resource or kept its data placeholder' >&2
  exit 1
fi
run_rg -q 'stray-tool-output\.txt' "$accounting_html"
# LC-058: a station that can never show GO only teaches the reader to ignore the board. Every
# station needs a GO branch, and the session's permission mode and the never-run validation are
# not stations: onboarding respects the mode the user chose and never runs the project's gates.
python3 - "$ROOT/skills/onboard/assets/completion-report.html" <<'PY'
import re
import sys

page = open(sys.argv[1], encoding='utf-8').read()
stations = re.search(r'const STATIONS = \[(.*?)\];', page).group(1)
verdict = re.search(r'const verdict = \(k, v\) => \{(.*?)\n\};', page, re.S).group(1)
for key in re.findall(r"\['([\w-]+)',", stations):
    branch = re.search(r"if \(k === '" + re.escape(key) + r"'\) return ([^\n]*)", verdict)
    assert branch and "'go'" in branch.group(1), 'station can never be GO: ' + key
for gone in ('Review mode', 'Flight checks', "'permission-mode'", "'validation'", 'goCount'):
    assert gone not in page, 'completion report still carries ' + gone
PY
# Report text is data, never markup: a gate that spells a closing script tag stays inert. The
# tokenizer ends a script at `</script` followed by `>`, whitespace or `/`, in any case, so the
# gates use the last two: escaping `>` alone would leave them live. Only the page's own two
# closing tags may remain.
escape_report="$installer_tmp/html-escape-report.txt"
printf '%s\n' '=== Workspace Setup Complete ===' '' 'Documented gates (2):' "  echo '</script ><b>x'" \
  "  echo '</SCRIPT/'" '' 'Checks:' '  branch: main' '' 'Next:' '  none' '' '=== End Workspace Setup ===' > "$escape_report"
python3 "$ROOT/skills/onboard/scripts/report-html.py" "$escape_report" "$installer_tmp/html-escape.html" escape-test >/dev/null
if [ "$(run_rg -oi '</script' "$installer_tmp/html-escape.html" | wc -l | tr -d ' ')" -ne 2 ]; then
  printf '%s\n' 'FAIL: report text reached the HTML page unescaped' >&2
  exit 1
fi
run_rg -qF '\u003c/script \u003e\u003cb\u003ex' "$installer_tmp/html-escape.html"
# Opener: a stub on PATH records each call. `env -u` so a CI runner's own CI=true is not the
# reason it stays silent.
opener_dir="$installer_tmp/html-opener"
mkdir -p "$opener_dir"
for opener_name in open xdg-open; do
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$1\" >> '$opener_dir/calls'" > "$opener_dir/$opener_name"
  chmod +x "$opener_dir/$opener_name"
done
PATH="$opener_dir:$PATH" LAUNCH_RUN_ID=validator env -u CI -u LAUNCH_CONTROL_NO_OPEN \
  bash -c "$(declare -f accounting_render); accounting_repo='$accounting_repo' ROOT='$ROOT' accounting_render" >/dev/null
sleep 1
if [ -e "$opener_dir/calls" ]; then
  printf '%s\n' 'FAIL: the renderer opened the HTML report inside a Launch run' >&2
  exit 1
fi
PATH="$opener_dir:$PATH" env -u CI -u LAUNCH_CONTROL_NO_OPEN -u LAUNCH_RUN_ID \
  bash -c "$(declare -f accounting_render); accounting_repo='$accounting_repo' ROOT='$ROOT' accounting_render" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$opener_dir/calls" ] && break; sleep 0.2; done
test "$(cat "$opener_dir/calls")" = "$accounting_html"
# A page that cannot be written costs only its link line; the text report still completes.
rm -rf "$(dirname "$accounting_html")"
: > "$(dirname "$accounting_html")"
accounting_render > "$installer_tmp/worktree-accounting-nohtml.out"
run_rg -q '^=== End Workspace Setup ===$' "$installer_tmp/worktree-accounting-nohtml.out"
if run_rg -q '^Visual report:' "$installer_tmp/worktree-accounting-nohtml.out"; then
  printf '%s\n' 'FAIL: the report linked an HTML page that was never written' >&2
  exit 1
fi
rm -f "$(dirname "$accounting_html")"

# BUG-3: a dirty baseline path that is ALSO a manifest path stays under Preserved (managed),
# never Untouched pre-existing (SKILL.md contract). .gitignore is a default-manifest path;
# a dirty, PRESERVED .gitignore must render under Preserved.
dirtymani_repo="$installer_tmp/dirty-manifest-repo"
mkdir -p "$dirtymani_repo/.claude"
git -C "$dirtymani_repo" init -q -b main
git -C "$dirtymani_repo" config user.name validator
git -C "$dirtymani_repo" config user.email validator@example.com
printf 'node_modules\n' > "$dirtymani_repo/.gitignore"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dirtymani_repo/noop.sh"
chmod +x "$dirtymani_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$dirtymani_repo/.claude/settings.json"
git -C "$dirtymani_repo" add .gitignore noop.sh .claude/settings.json
git -C "$dirtymani_repo" commit -qm baseline
printf 'node_modules\ndist\n' > "$dirtymani_repo/.gitignore"
mkdir -p "$dirtymani_repo/.launch-control-onboard"
dirtymani_ledger="$dirtymani_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' PRESERVED .gitignore > "$dirtymani_ledger"
dirtymani_baseline="$dirtymani_repo/.launch-control-onboard/baseline.txt"
printf '%s\n' .gitignore > "$dirtymani_baseline"
dirtymani_validation="$dirtymani_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './noop.sh' > "$dirtymani_validation"
(cd "$dirtymani_repo" && ONBOARD_BASELINE_PATHS_FILE="$dirtymani_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$dirtymani_ledger" main valid absent ready "$dirtymani_validation" none complete) > "$installer_tmp/dirty-manifest.out"
run_rg -q '^Preserved \(1\):$' "$installer_tmp/dirty-manifest.out"
run_rg -q '^  \.gitignore$' "$installer_tmp/dirty-manifest.out"
if run_rg -q 'Untouched pre-existing' "$installer_tmp/dirty-manifest.out"; then
  printf '%s\n' 'FAIL: dirty manifest path .gitignore rendered under Untouched pre-existing' >&2
  exit 1
fi

# GAP-1: the completion guard captures the workspace anchor at the discovery checkpoint, before
# any pre-render validation can run. A tracked file mutated between the checkpoint and the first
# render is a run-introduced change measured against that pre-onboarding anchor, so the render
# must block — proving the anchor predates the mutation instead of being captured lazily at render
# time (which would launder the mutated tree into a false "untouched" baseline).
anchor_repo="$installer_tmp/anchor-checkpoint-repo"
mkdir -p "$anchor_repo/.claude" "$anchor_repo/skills/onboard/references" "$anchor_repo/tools/fixtures"
git -C "$anchor_repo" init -q -b main
git -C "$anchor_repo" config user.name validator
git -C "$anchor_repo" config user.email validator@example.com
touch "$anchor_repo/skills/onboard/references/hooks-and-config.md" "$anchor_repo/tools/fixtures/onboard-manifests.json"
printf 'original\n' > "$anchor_repo/tracked.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$anchor_repo/noop.sh"
chmod +x "$anchor_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$anchor_repo/.claude/settings.json"
git -C "$anchor_repo" add .
git -C "$anchor_repo" commit -qm baseline
# Discovery checkpoint fires: the guard captures the clean-tree anchor at this moment.
write_discovery_fixture "$anchor_repo" anchor-fixture main none
jq -n --arg cwd "$anchor_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"anchor",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
test -f "$anchor_repo/.launch-control-onboard/worktree-status.start"
test -f "$anchor_repo/.launch-control-onboard/worktree-status.start.fingerprints"
# A manual pre-render validation run then rewrites a tracked file AFTER the anchor was captured.
printf 'laundered\n' > "$anchor_repo/tracked.txt"
anchor_ledger="$anchor_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' PRESERVED tracked.txt > "$anchor_ledger"
anchor_validation="$anchor_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './noop.sh' > "$anchor_validation"
anchor_baseline="$anchor_repo/.launch-control-onboard/baseline.txt"
: > "$anchor_baseline"
if (cd "$anchor_repo" && ONBOARD_BASELINE_PATHS_FILE="$anchor_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$anchor_ledger" main valid absent ready "$anchor_validation" none complete) >/dev/null 2>"$installer_tmp/anchor-checkpoint.err"; then
  printf '%s\n' 'FAIL: renderer passed despite a tree mutation between the discovery checkpoint and render' >&2
  exit 1
fi
run_rg -q 'the workspace changed outside the declared writes of this run' "$installer_tmp/anchor-checkpoint.err"

# GAP-3: the renderer's bare-script allowance rejects package-manager builtins at the shape check,
# before execution and regardless of any generated permission. `pnpm publish` is denied even with
# Bash(pnpm publish) granted (shape rejection), while a genuine bare script like `pnpm lint` gets
# past the shape check and runs with no grant at all — proving the denylist gates on the token,
# not the grant. Round-41: the grant is no longer a precondition on rendering, so `pnpm lint`
# renders instead of being refused; that half of the pair now proves the shape check is the whole
# boundary rather than proving the permission gate.
gap3_repo="$installer_tmp/pm-builtin-repo"
mkdir -p "$gap3_repo/.claude"
git -C "$gap3_repo" init -q -b main
git -C "$gap3_repo" config user.name validator
git -C "$gap3_repo" config user.email validator@example.com
printf '%s\n' '{"permissions":{"allow":["Bash(pnpm publish)"]}}' > "$gap3_repo/.claude/settings.json"
git -C "$gap3_repo" add .claude/settings.json
git -C "$gap3_repo" commit -qm baseline
mkdir -p "$gap3_repo/.launch-control-onboard"
gap3_ledger="$gap3_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' SKIPPED .mcp.json > "$gap3_ledger"
gap3_baseline="$gap3_repo/.launch-control-onboard/baseline.txt"
: > "$gap3_baseline"
gap3_publish_validation="$gap3_repo/.launch-control-onboard/validation-publish.txt"
printf '%s\n' 'pnpm publish' > "$gap3_publish_validation"
if (cd "$gap3_repo" && ONBOARD_BASELINE_PATHS_FILE="$gap3_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$gap3_ledger" main valid absent ready "$gap3_publish_validation" none complete) >/dev/null 2>"$installer_tmp/pm-publish.err"; then
  printf '%s\n' 'FAIL: renderer accepted the package-manager builtin pnpm publish' >&2
  exit 1
fi
run_rg -q 'outside the supported repository validation forms' "$installer_tmp/pm-publish.err"
gap3_lint_validation="$gap3_repo/.launch-control-onboard/validation-lint.txt"
printf '%s\n' 'pnpm lint' > "$gap3_lint_validation"
mkdir -p "$gap3_repo/shims"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$gap3_repo/shims/pnpm"
chmod +x "$gap3_repo/shims/pnpm"
reset_run_anchor "$gap3_repo"
(cd "$gap3_repo" && PATH="$gap3_repo/shims:$PATH" ONBOARD_BASELINE_PATHS_FILE="$gap3_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$gap3_ledger" main valid absent ready "$gap3_lint_validation" none complete) >"$installer_tmp/pm-lint.out" 2>"$installer_tmp/pm-lint.err"
run_rg -q '^  validation: not run \(1 documented gate;' "$installer_tmp/pm-lint.out"
if run_rg -q 'lacks an exact generated permission' "$installer_tmp/pm-lint.err"; then
  printf '%s\n' 'FAIL: renderer again requires an exact generated permission for a contract command' >&2
  exit 1
fi

# Hook reporting is renderer-derived, not caller asserted. Unrelated user hooks are preserved;
# the canonical registration plus executable is enabled; either mismatched caller value blocks.
hook_repo="$installer_tmp/hook-status-repo"
mkdir -p "$hook_repo/.claude" "$hook_repo/.launch-control-onboard"
git -C "$hook_repo" init -q -b main
git -C "$hook_repo" config user.name validator
git -C "$hook_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$hook_repo/ok.sh"
chmod +x "$hook_repo/ok.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./ok.sh)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}' > "$hook_repo/.claude/settings.json"
git -C "$hook_repo" add -A
git -C "$hook_repo" commit -qm baseline
hook_ledger="$hook_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' PRESERVED .claude/settings.json > "$hook_ledger"
hook_baseline="$hook_repo/.launch-control-onboard/baseline.txt"
: > "$hook_baseline"
hook_validation="$hook_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './ok.sh' > "$hook_validation"
(cd "$hook_repo" && ONBOARD_BASELINE_PATHS_FILE="$hook_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$hook_ledger" main valid preserved ready "$hook_validation" none complete) >/dev/null
reset_run_anchor "$hook_repo"
if (cd "$hook_repo" && ONBOARD_BASELINE_PATHS_FILE="$hook_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$hook_ledger" main valid absent ready "$hook_validation" none complete) >/dev/null 2>"$installer_tmp/hook-preserved-mismatch.err"; then
  printf '%s\n' 'FAIL: renderer trusted a caller-asserted absent hook status' >&2
  exit 1
fi
run_rg -q 'reported hooks value does not match' "$installer_tmp/hook-preserved-mismatch.err"
mkdir -p "$hook_repo/.claude/hooks"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$hook_repo/.claude/hooks/skill-eval.sh"
chmod +x "$hook_repo/.claude/hooks/skill-eval.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./ok.sh)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-hook"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-eval.sh\""}]}]}}' > "$hook_repo/.claude/settings.json"
printf '%s\t%s\n' PRESERVED .claude/settings.json CREATED .claude/hooks/skill-eval.sh > "$hook_ledger"
reset_run_anchor "$hook_repo"
(cd "$hook_repo" && ONBOARD_BASELINE_PATHS_FILE="$hook_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$hook_ledger" main valid enabled ready "$hook_validation" none complete) >/dev/null
reset_run_anchor "$hook_repo"
if (cd "$hook_repo" && ONBOARD_BASELINE_PATHS_FILE="$hook_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$hook_ledger" main valid preserved ready "$hook_validation" none complete) >/dev/null 2>"$installer_tmp/hook-enabled-mismatch.err"; then
  printf '%s\n' 'FAIL: renderer trusted a caller-asserted preserved hook status' >&2
  exit 1
fi
run_rg -q 'reported hooks value does not match' "$installer_tmp/hook-enabled-mismatch.err"

# GAP-2 (e2e follow-up): a pre-existing user-owned artifacts doc that diverges from the generated
# heading schema does NOT block completion — the renderer records a non-blocking Doc warning
# instead. Only a doc this run generated (CREATED/MERGED) hard-fails the schema gate.
userdoc_repo="$installer_tmp/userdoc-repo"
mkdir -p "$userdoc_repo/.claude" "$userdoc_repo/artifacts" "$userdoc_repo/checks" "$userdoc_repo/.launch-control-onboard"
git -C "$userdoc_repo" init -q -b main
git -C "$userdoc_repo" config user.name validator
git -C "$userdoc_repo" config user.email validator@example.com
printf '%s\n' '# Architecture' '' '## 1. Overview' 'User-authored, numbered headings.' > "$userdoc_repo/artifacts/architecture.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$userdoc_repo/checks/ok.sh"
chmod +x "$userdoc_repo/checks/ok.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/ok.sh)"]}}' > "$userdoc_repo/.claude/settings.json"
git -C "$userdoc_repo" add -A
git -C "$userdoc_repo" commit -qm baseline
userdoc_validation="$userdoc_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './checks/ok.sh' > "$userdoc_validation"
userdoc_baseline="$userdoc_repo/.launch-control-onboard/baseline.txt"
: > "$userdoc_baseline"
# Pre-existing user-owned doc, PRESERVED: warns, does not block.
userdoc_preserved_ledger="$userdoc_repo/.launch-control-onboard/ledger-preserved.tsv"
printf '%s\t%s\n' PRESERVED artifacts/architecture.md > "$userdoc_preserved_ledger"
(cd "$userdoc_repo" && ONBOARD_BASELINE_PATHS_FILE="$userdoc_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$userdoc_preserved_ledger" main valid absent ready "$userdoc_validation" none complete) > "$installer_tmp/userdoc.out"
run_rg -q '=== Workspace Setup Complete ===' "$installer_tmp/userdoc.out"
run_rg -q '^Doc warnings \([1-9][0-9]*\):$' "$installer_tmp/userdoc.out"
# LC-044: one plain line per doc naming what is missing and why it matters, not one per heading.
run_rg -q '^  artifacts/architecture\.md: missing ## Overview, .*; agents read this doc for context, so add them$' "$installer_tmp/userdoc.out"
# The same divergent doc marked CREATED (generated this run) still hard-fails the schema gate.
userdoc_created_ledger="$userdoc_repo/.launch-control-onboard/ledger-created.tsv"
printf '%s\t%s\n' CREATED artifacts/architecture.md > "$userdoc_created_ledger"
reset_run_anchor "$userdoc_repo"
if (cd "$userdoc_repo" && ONBOARD_BASELINE_PATHS_FILE="$userdoc_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$userdoc_created_ledger" main valid absent ready "$userdoc_validation" none complete) >/dev/null 2>"$installer_tmp/userdoc-created.err"; then
  printf '%s\n' 'FAIL: renderer accepted a generated architecture doc missing the required schema' >&2
  exit 1
fi
run_rg -q 'architecture documentation lacks required section: ## Overview' "$installer_tmp/userdoc-created.err"

reviewer_repo="$installer_tmp/reviewer-repo"
mkdir -p "$reviewer_repo/.claude/agents" "$reviewer_repo/checks"
git -C "$reviewer_repo" init -q -b reviewer-test
printf '%s\n' '## Project-specific review lens' 'Generic review advice.' > "$reviewer_repo/.claude/agents/inspector.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$reviewer_repo/checks/validate.sh"
chmod +x "$reviewer_repo/checks/validate.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$reviewer_repo/.claude/settings.json"
mkdir -p "$reviewer_repo/.launch-control-onboard"
reviewer_ledger="$reviewer_repo/.launch-control-onboard/reviewer-ledger.tsv"
# Round-32: the lens and Launch schema gates are scoped to files THIS RUN wrote, so every
# hard-fail below needs a ledger that says the run wrote them. The Launch row is appended only
# once that file exists -- a ledger naming an absent path is rejected earlier, by a different
# rule. The PRESERVED counterparts -- the shape that actually blocked rymonroe.com -- are
# asserted after this group.
printf '%s\t%s\n' CREATED .claude/agents/inspector.md > "$reviewer_ledger"
reviewer_baseline="$reviewer_repo/.launch-control-onboard/reviewer-baseline.txt"
: > "$reviewer_baseline"
reviewer_validation="$reviewer_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate.sh' > "$reviewer_validation"
if (cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null 2>"$installer_tmp/generic-reviewer.err"; then
  printf '%s\n' 'FAIL: renderer accepted a generic code reviewer' >&2
  exit 1
fi
run_rg -q 'at least two evidence-backed review lens bullets' "$installer_tmp/generic-reviewer.err"
printf '%s\n' \
  '## Project-specific review lens' \
  '- Review shell quoting. Evidence: `install.sh`, `tools/validate-pack.sh`.' \
  '- Review generated frontmatter. Evidence: `skills/onboard/SKILL.md`.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
if (cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null 2>"$installer_tmp/multi-path-reviewer.err"; then
  printf '%s\n' 'FAIL: renderer accepted a reviewer lens bullet with multiple evidence paths' >&2
  exit 1
fi
run_rg -q 'exactly one evidence path' "$installer_tmp/multi-path-reviewer.err"
printf '%s\n' \
  '## Project-specific review lens' \
  '- Review exact generated permissions. Evidence: `.claude/settings.json`.' \
  '- Review declared validation behavior. Evidence: `checks/validate.sh`.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
(cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null
mkdir -p "$reviewer_repo/install"
printf '%s\n' '{"mcpServers":{}}' > "$reviewer_repo/install/mcp.reference.json"
reset_run_anchor "$reviewer_repo"
printf '%s\n' \
  '## Project-specific review lens' \
  '- Review generated sandbox permissions. Evidence: `install/mcp.reference.json`.' \
  '- Review declared validation behavior. Evidence: `checks/validate.sh`.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
if (cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null 2>"$installer_tmp/unsupported-reviewer-evidence.err"; then
  printf '%s\n' 'FAIL: renderer accepted reviewer evidence that does not support its concern' >&2
  exit 1
fi
run_rg -q 'does not support the stated non-MCP concern' "$installer_tmp/unsupported-reviewer-evidence.err"
printf '%s\n' \
  '## Project-specific review lens' \
  '- Review exact generated permissions. Evidence: `.claude/settings.json`.' \
  '- Review declared validation behavior. Evidence: `checks/validate.sh`.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
mkdir -p "$reviewer_repo/.claude/skills/launch"
printf '%s\n' '<!-- inferred from README.md --> - Invalid collapsed bullet.' \
  > "$reviewer_repo/.claude/skills/launch/SKILL.md"
printf '%s\t%s\n' CREATED .claude/skills/launch/SKILL.md >> "$reviewer_ledger"
reset_run_anchor "$reviewer_repo"
if (cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) >/dev/null 2>"$installer_tmp/collapsed-model-insert.err"; then
  printf '%s\n' 'FAIL: renderer accepted a collapsed model-insert annotation and bullet' >&2
  exit 1
fi
run_rg -q 'annotations and bullets must be on separate lines' "$installer_tmp/collapsed-model-insert.err"
printf '%s\n' '<!-- inferred from .claude/settings.json -->' '- Review exact permissions.' \
  > "$reviewer_repo/.claude/skills/launch/SKILL.md"
reviewer_required="$reviewer_repo/.launch-control-onboard/required-paths.txt"
: > "$reviewer_required"
(cd "$reviewer_repo" && \
  ONBOARD_REQUIRED_PATHS_FILE=.launch-control-onboard/required-paths.txt \
  ONBOARD_BASELINE_PATHS_FILE=.launch-control-onboard/reviewer-baseline.txt \
  "$ROOT/skills/onboard/scripts/render-report.sh" \
  .launch-control-onboard/reviewer-ledger.tsv reviewer-test valid absent ready \
  .launch-control-onboard/validation-commands.txt none complete) >/dev/null

# Round-32 F41. The three gates above -- reviewer lens, project-code-review guidance surfaces,
# Launch template shape -- all keyed on the file existing on disk, so they also judged files the
# run PRESERVED. A repository carrying its own `.claude/` has every one of them preserved
# (SKILL.md's preservation rule), so no rerun could satisfy them: the refusal was UNSATISFIABLE.
# It was not expensive -- all three checks run before declared-command execution, and the two
# renderer refusals measured against rymonroe.com took 313 ms and 385 ms. Round-31's "8m12s
# render with npm run lint/typecheck/build all executed" was the whole /onboard run misattributed
# to the render. All three are now scoped to CREATED/MERGED and warn instead. Asserting the
# report COMPLETES is the whole point; the warning rows keep the finding from vanishing silently.
printf '%s\n' '# Code Review Agent' '' '## Process' '- Read the diff.' \
  > "$reviewer_repo/.claude/agents/inspector.md"
mkdir -p "$reviewer_repo/.claude/skills/project-code-review"
printf '%s\n' '# Project code review' > "$reviewer_repo/.claude/skills/project-code-review/SKILL.md"
printf '%s\n' '<!-- inferred from README.md --> - Invalid collapsed bullet.' \
  > "$reviewer_repo/.claude/skills/launch/SKILL.md"
printf '%s\n' '# Guidance' '' 'Run `code-review` before shipping.' '' \
  'See artifacts/architecture.md and artifacts/infrastructure.md.' > "$reviewer_repo/CLAUDE.md"
reviewer_preserved_ledger="$reviewer_repo/.launch-control-onboard/reviewer-preserved.tsv"
printf '%s\t%s\n' PRESERVED .claude/agents/inspector.md \
  PRESERVED .claude/skills/launch/SKILL.md > "$reviewer_preserved_ledger"
reset_run_anchor "$reviewer_repo"
(cd "$reviewer_repo" && ONBOARD_BASELINE_PATHS_FILE="$reviewer_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$reviewer_preserved_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete) > "$installer_tmp/reviewer-preserved.out" 2>"$installer_tmp/reviewer-preserved.err" || {
  printf '%s\n' 'FAIL: renderer blocked over user-owned files this run preserved and may not write' >&2
  cat "$installer_tmp/reviewer-preserved.err" >&2
  exit 1
}
run_rg -q '=== Workspace Setup Complete ===' "$installer_tmp/reviewer-preserved.out"
run_rg -q '^Doc warnings \([1-9][0-9]*\):$' "$installer_tmp/reviewer-preserved.out"
# LC-044: a hand-written reviewer is the user's file, and the lens heading is the template's
# schema, so it is not judged at all. Target repo C's reviewer drew this warning while carrying its
# own project checklists under other headings.
# The path itself is listed under Preserved, so match the finding, not the path.
if run_rg -qi 'review lens' "$installer_tmp/reviewer-preserved.out"; then
  printf '%s\n' 'FAIL: a preserved, hand-written inspector.md drew a doc warning' >&2
  exit 1
fi
run_rg -qF 'CLAUDE.md: still names the old skill `code-review`; rename it to `project-code-review`' \
  "$installer_tmp/reviewer-preserved.out"
run_rg -qF 'launch/SKILL.md: never names the `project-code-review` skill, so agents may not find it; add a line pointing to it' \
  "$installer_tmp/reviewer-preserved.out"
rm -rf "$reviewer_repo/.claude/skills/project-code-review" "$reviewer_repo/CLAUDE.md"

docs_repo="$installer_tmp/docs-repo"
mkdir -p "$docs_repo/artifacts" "$docs_repo/.claude" "$docs_repo/checks"
git -C "$docs_repo" init -q -b docs-test
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$docs_repo/checks/validate.sh"
chmod +x "$docs_repo/checks/validate.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$docs_repo/.claude/settings.json"
git -C "$docs_repo" config user.name validator
git -C "$docs_repo" config user.email validator@example.com
git -C "$docs_repo" add .
git -C "$docs_repo" commit -qm baseline
write_discovery_fixture "$docs_repo" docs-fixture docs-test none
jq -n --arg cwd "$docs_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"docs-validator",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$docs_repo" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"docs-validator",tool_name:"Write"}' | run_guard
mkdir -p "$docs_repo/.launch-control-onboard"
cat > "$docs_repo/artifacts/architecture.md" <<'EOF'
# Architecture

> Generated snapshot from repository evidence.

## Overview
Example.
## Technology Decisions
Example.
## System Architecture
```mermaid
flowchart LR
  A --> B
```
## Component Deep Dives
Example.
## Data Model
Not applicable; no persistent data.
EOF
cat > "$docs_repo/artifacts/infrastructure.md" <<'EOF'
# Infrastructure

> Generated snapshot from repository evidence.

## Configuration
Example.
## Security
Example.
## Runbook
Example.
EOF
cat > "$docs_repo/CLAUDE.md" <<'EOF'
Project-owned guidance.

## Generated Quick Reference

See artifacts/architecture.md and artifacts/infrastructure.md.
EOF
awk '
  $0 == "## Generated Quick Reference" { in_block = 1 }
  in_block && /^# / { exit }
  in_block { print }
' "$docs_repo/CLAUDE.md" > "$docs_repo/.launch-control-onboard/prospective-claude.md"
docs_ledger="$docs_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' CREATED artifacts/architecture.md CREATED artifacts/infrastructure.md CREATED CLAUDE.md > "$docs_ledger"
docs_validation="$docs_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate.sh' > "$docs_validation"
if (cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null 2>"$installer_tmp/missing-bootstrap-proof.err"; then
  printf '%s\n' 'FAIL: renderer accepted new docs without docs-create invocation proof' >&2
  exit 1
fi
run_rg -q 'lacks docs-create invocation proof' "$installer_tmp/missing-bootstrap-proof.err"
bootstrap_proof_hook="$ROOT/skills/docs-create/scripts/invocation-proof.sh"
for doc in artifacts/architecture.md artifacts/infrastructure.md; do
  jq -n --arg cwd "$docs_repo" --arg path "$docs_repo/$doc" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"docs-validator",tool_name:"Write",tool_input:{file_path:$path}}' | "$bootstrap_proof_hook"
done
printf '%s\n' \
  '## Generated Quick Reference' \
  'stale plausible guidance' \
  > "$docs_repo/.launch-control-onboard/prospective-claude.md"
if (cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null 2>"$installer_tmp/stale-claude-marker.err"; then
  printf '%s\n' 'FAIL: renderer accepted CLAUDE.md without a fresh prospective block match' >&2
  exit 1
fi
run_rg -q 'does not match freshly rendered prospective content' "$installer_tmp/stale-claude-marker.err"
# The generated block carries no comment scaffolding. A CLAUDE.md that still holds the legacy
# onboard markers (a rerun that failed to migrate them) is refused outright, and so is a
# prospective block that would put them back.
cat > "$docs_repo/CLAUDE.md.legacy" <<'EOF'
Project-owned guidance.

<!-- BEGIN GENERATED SECTION -- onboard -->
<!-- Re-run /onboard to update. -->
## Generated Quick Reference

See artifacts/architecture.md and artifacts/infrastructure.md.
<!-- END GENERATED SECTION -- onboard -->
EOF
cp "$docs_repo/CLAUDE.md" "$docs_repo/CLAUDE.md.clean"
cp "$docs_repo/CLAUDE.md.legacy" "$docs_repo/CLAUDE.md"
if (cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null 2>"$installer_tmp/legacy-claude-marker.err"; then
  printf '%s\n' 'FAIL: renderer accepted a CLAUDE.md that still carries legacy onboard comment markers' >&2
  exit 1
fi
run_rg -q 'legacy onboard comment markers' "$installer_tmp/legacy-claude-marker.err"
cp "$docs_repo/CLAUDE.md.clean" "$docs_repo/CLAUDE.md"
rm -f "$docs_repo/CLAUDE.md.legacy" "$docs_repo/CLAUDE.md.clean"
printf '%s\n' \
  '<!-- BEGIN GENERATED SECTION -- onboard -->' \
  '## Generated Quick Reference' \
  'See artifacts/architecture.md and artifacts/infrastructure.md.' \
  '<!-- END GENERATED SECTION -- onboard -->' \
  > "$docs_repo/.launch-control-onboard/prospective-claude.md"
if (cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null 2>"$installer_tmp/marker-prospective.err"; then
  printf '%s\n' 'FAIL: renderer accepted a prospective block wrapped in comment markers' >&2
  exit 1
fi
run_rg -q 'must contain only the generated block' "$installer_tmp/marker-prospective.err"
# Two headings means two blocks: a rerun that appended instead of replacing. Refused.
printf '%s\n' '' '## Generated Quick Reference' 'duplicate' >> "$docs_repo/CLAUDE.md"
if (cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null 2>"$installer_tmp/duplicate-claude-block.err"; then
  printf '%s\n' 'FAIL: renderer accepted a CLAUDE.md carrying two generated blocks' >&2
  exit 1
fi
run_rg -q 'exactly one onboard generated block' "$installer_tmp/duplicate-claude-block.err"
cat > "$docs_repo/CLAUDE.md" <<'EOF'
Project-owned guidance.

## Generated Quick Reference

See artifacts/architecture.md and artifacts/infrastructure.md.
EOF
awk '
  $0 == "## Generated Quick Reference" { in_block = 1 }
  in_block && /^# / { exit }
  in_block { print }
' "$docs_repo/CLAUDE.md" > "$docs_repo/.launch-control-onboard/prospective-claude.md"

# Round-15 F32: the byte comparison pinned above proves the two surfaces agree, never WHICH one
# was made to agree. A run that rewrites the prospective block after writing CLAUDE.md leaves a
# matching pair that is byte-indistinguishable from honest regeneration, and two live acceptance
# runs did exactly that against a prose-only rule. The guard now records write order and the
# renderer requires the prospective write to precede the CLAUDE.md write. Every branch below
# renders byte-identical content, so only the recorded ORDER can decide them -- which is the
# whole point: no content-based fixture can cover this finding.
docs_write_order="$docs_repo/.launch-control-onboard/write-order.guard.txt"
printf '%s\t%s\n' 1 CLAUDE.md 2 .launch-control-onboard/prospective-claude.md > "$docs_write_order"
expect_report_failure f32-rewritten-prospective "$docs_repo" \
  "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete
run_rg -q 'prospective CLAUDE.md generated block was rewritten after CLAUDE.md was written' \
  "$installer_tmp/f32-rewritten-prospective.err"

# The same defect with its evidence missing rather than inverted: CLAUDE.md written, no
# prospective write recorded at all. Must not pass by falling through to the content match.
printf '%s\t%s\n' 1 CLAUDE.md > "$docs_write_order"
expect_report_failure f32-unrecorded-prospective "$docs_repo" \
  "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete
run_rg -q 'guard recorded no prospective block write' \
  "$installer_tmp/f32-unrecorded-prospective.err"

# Degraded mode: no hook ran, so no record exists. That must render as "not recorded" and never
# as an attestation -- absence of evidence is not evidence of honest ordering (the F28 rule).
rm -f "$docs_write_order"
(cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) > "$installer_tmp/f32-degraded.out"
run_rg -q '^  claude-md-provenance: no write order recorded by the completion guard$' \
  "$installer_tmp/f32-degraded.out"
if run_rg -q 'claude-md-provenance:.*attested' "$installer_tmp/f32-degraded.out"; then
  printf '%s\n' 'FAIL: a run with no guard write-order record claimed an attested provenance' >&2
  exit 1
fi

# Honest order, byte-identical content to all three cases above: passes, and says what it proved.
for doc in artifacts/architecture.md artifacts/infrastructure.md; do
  jq -n --arg cwd "$docs_repo" --arg path "$docs_repo/$doc" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"docs-validator",tool_name:"Write",tool_input:{file_path:$path}}' | "$bootstrap_proof_hook"
done
printf '%s\t%s\n' 1 .launch-control-onboard/prospective-claude.md 2 CLAUDE.md > "$docs_write_order"
(cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) > "$installer_tmp/f32-ordered.out"
run_rg -q '^  claude-md-provenance: guard-attested -- prospective block written before CLAUDE\.md$' \
  "$installer_tmp/f32-ordered.out"
rm -f "$docs_write_order"

for doc in artifacts/architecture.md artifacts/infrastructure.md; do
  jq -n --arg cwd "$docs_repo" --arg path "$docs_repo/$doc" '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"docs-validator",tool_name:"Write",tool_input:{file_path:$path}}' | "$bootstrap_proof_hook"
done
(cd "$docs_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "$docs_ledger" docs-test valid absent ready "$docs_validation" none complete) >/dev/null
test ! -e "$(git -C "$docs_repo" rev-parse --absolute-git-dir)/launch-control-bootstrap-docs-docs-validator.proof"

# F31: the prospective marker file is required on the PRESERVED path exactly as on CREATED and
# MERGED. Two repos' idempotent re-runs both blocked with `prospective CLAUDE.md marker block is
# missing` because Phase 3 owned the write and every Phase 3 scenario is a write path, so a run that
# changed no file on disk left Phase 3 with no scenario to execute and never wrote the file. Phase 2d
# now persists it, but the renderer is what makes skipping it unable to pass -- so drive the real
# renderer down the PRESERVED path instead of grepping the renderer's source for the message.
#
# This needs its own repo rather than `docs_repo` or `status_repo`: `docs_repo` wrote CLAUDE.md
# during its run, so claiming PRESERVED there trips `dishonest PRESERVED status` first, and
# `status_repo` has no CLAUDE.md at all, so its ledger never reaches the prospective check. The
# baseline below commits CLAUDE.md unchanged, which is what an idempotent re-run actually looks like.
idem_repo="$installer_tmp/idempotent-claude-repo"
mkdir -p "$idem_repo/.claude" "$idem_repo/checks"
git -C "$idem_repo" init -q -b idem-test
git -C "$idem_repo" config user.name validator
git -C "$idem_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$idem_repo/checks/validate.sh"
chmod +x "$idem_repo/checks/validate.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$idem_repo/.claude/settings.json"
# Referenced, not created: the renderer's artifacts checks are `-f` guarded, but a present CLAUDE.md
# must still name both generated documents.
cat > "$idem_repo/CLAUDE.md" <<'EOF'
# Idempotent fixture

## Generated Quick Reference

See artifacts/architecture.md and artifacts/infrastructure.md.
EOF
git -C "$idem_repo" add .
git -C "$idem_repo" commit -qm baseline
jq -n --arg cwd "$idem_repo" --arg prompt '/onboard' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"idem-proof",prompt:$prompt}' | run_guard
write_discovery_fixture "$idem_repo" idem-fixture idem-test none
jq -n --arg cwd "$idem_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"idem-proof",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$idem_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"idem-proof",tool_name:"Write"}' | run_guard
idem_inventory="$(git -C "$idem_repo" rev-parse --absolute-git-dir)/launch-control-onboard-run-idem-proof.inventory"
test -s "$idem_inventory"
mkdir -p "$idem_repo/.launch-control-onboard"
awk -F '\t' '{ print ($3 == "absent" ? "SKIPPED" : "PRESERVED") "\t" $2 }' "$idem_inventory" > "$idem_repo/.launch-control-onboard/ledger.tsv"
idem_ledger="$idem_repo/.launch-control-onboard/ledger.tsv"
run_rg -q '^PRESERVED\tCLAUDE\.md$' "$idem_ledger"
idem_validation="$idem_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate.sh' > "$idem_validation"

# The file Phase 2d owes, absent: an idempotent re-run that writes nothing still cannot report.
expect_report_failure idem-missing-prospective "$idem_repo" \
  "$idem_ledger" idem-test valid absent ready "$idem_validation" none complete
run_rg -q 'prospective CLAUDE.md generated block is missing' "$installer_tmp/idem-missing-prospective.err"

# Round-15 cross-fix interaction: F32's write-order record must not be able to disarm F31's
# signal. A record that CLAIMS the prospective block was written is not the block existing, so
# the render must still fail on the missing file rather than accepting the record as proof of it.
# This is the failure mode the round-15 audit named -- one fix quietly satisfying another's
# check -- pinned rather than reasoned about.
printf '%s\t%s\n' 1 .launch-control-onboard/prospective-claude.md 2 CLAUDE.md \
  > "$idem_repo/.launch-control-onboard/write-order.guard.txt"
expect_report_failure idem-missing-prospective-attested "$idem_repo" \
  "$idem_ledger" idem-test valid absent ready "$idem_validation" none complete
run_rg -q 'prospective CLAUDE.md generated block is missing' \
  "$installer_tmp/idem-missing-prospective-attested.err"
rm -f "$idem_repo/.launch-control-onboard/write-order.guard.txt"

# Present and matching, same ledger: proves the negative case above is the missing file rather than
# the PRESERVED status, the unchanged CLAUDE.md, or anything else in this fixture.
awk '
  $0 == "## Generated Quick Reference" { in_block = 1 }
  in_block && /^# / { exit }
  in_block { print }
' "$idem_repo/CLAUDE.md" > "$idem_repo/.launch-control-onboard/prospective-claude.md"
(cd "$idem_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" \
  "$idem_ledger" idem-test valid absent ready "$idem_validation" none complete) >/dev/null

# LC-002, renderer half. A merged CLAUDE.md counts as generated, so the stale-name refusal read
# the whole file and failed the render over the user's own prose outside the generated block:
# BLOCKED, and no rerun could clear it without rewriting text the run does not own. For MERGED
# the rule reads only the generated block, the span compared against the prospective block above.
# A CREATED CLAUDE.md is exactly the block, so the same prose there is the run's and still fails.
lc002_render() { # status (MERGED|CREATED); sets lc002_repo, lc002_args
  local status="$1"
  lc002_repo="$installer_tmp/lc002-$status-claude-repo"
  mkdir -p "$lc002_repo/.claude" "$lc002_repo/checks"
  git -C "$lc002_repo" init -q -b lc002-test
  git -C "$lc002_repo" config user.name validator
  git -C "$lc002_repo" config user.email validator@example.com
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$lc002_repo/checks/validate.sh"
  chmod +x "$lc002_repo/checks/validate.sh"
  printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$lc002_repo/.claude/settings.json"
  [ "$status" = CREATED ] ||
    printf '%s\n' '# Team notes' '' 'The `code-review` GitHub app comments on every PR.' > "$lc002_repo/CLAUDE.md"
  git -C "$lc002_repo" add .
  git -C "$lc002_repo" commit -qm baseline
  jq -n --arg cwd "$lc002_repo" --arg prompt '/onboard' --arg s "lc002-$status" \
    '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$s,prompt:$prompt}' | run_guard
  write_discovery_fixture "$lc002_repo" lc002-fixture lc002-test none
  jq -n --arg cwd "$lc002_repo" --arg command "$policy_discovery_checkpoint" --arg s "lc002-$status" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Bash",tool_input:{command:$command}}' | run_guard
  jq -n --arg cwd "$lc002_repo" --arg s "lc002-$status" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:$s,tool_name:"Write"}' | run_guard
  mkdir -p "$lc002_repo/.claude/skills/project-code-review" "$lc002_repo/.claude/skills/launch"
  printf '%s\n' '# Project code review' > "$lc002_repo/.claude/skills/project-code-review/SKILL.md"
  printf '%s\n' '# Launch' '' 'Self-review with `project-code-review` before a PR.' \
    > "$lc002_repo/.claude/skills/launch/SKILL.md"
  printf '%s\n' '## Generated Quick Reference' '' 'Self-review with `project-code-review` before a PR.' \
    'See artifacts/architecture.md and artifacts/infrastructure.md.' \
    > "$lc002_repo/.launch-control-onboard/prospective-claude.md"
  [ "$status" = MERGED ] ||
    printf '%s\n' '# Team notes' '' 'The `code-review` GitHub app comments on every PR.' > "$lc002_repo/CLAUDE.md"
  printf '\n' >> "$lc002_repo/CLAUDE.md"
  cat "$lc002_repo/.launch-control-onboard/prospective-claude.md" >> "$lc002_repo/CLAUDE.md"
  local inventory ledger="$lc002_repo/.launch-control-onboard/ledger.tsv"
  inventory="$(git -C "$lc002_repo" rev-parse --absolute-git-dir)/launch-control-onboard-run-lc002-$status.inventory"
  awk -F '\t' -v status="$status" '
    $2 == "CLAUDE.md" { print status "\t" $2; next }
    $2 ~ /^\.claude\/skills\/(project-code-review|launch)\/SKILL\.md$/ { print "CREATED\t" $2; next }
    { print ($3 == "absent" ? "SKIPPED" : "PRESERVED") "\t" $2 }
  ' "$inventory" > "$ledger"
  printf '%s\n' './checks/validate.sh' > "$lc002_repo/.launch-control-onboard/validation-commands.txt"
  lc002_args=("$ledger" lc002-test valid absent ready \
    "$lc002_repo/.launch-control-onboard/validation-commands.txt" none complete)
}
lc002_render MERGED
(cd "$lc002_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" "${lc002_args[@]}") \
  > "$installer_tmp/lc002-render.out" 2> "$installer_tmp/lc002-render.err" || {
  printf '%s\n' 'FAIL: renderer refused a merged CLAUDE.md over user prose outside the generated block' >&2
  cat "$installer_tmp/lc002-render.err" >&2
  exit 1
}
run_rg -q '=== Workspace Setup Complete ===' "$installer_tmp/lc002-render.out"
lc002_render CREATED
expect_report_failure lc002-created "$lc002_repo" "${lc002_args[@]}"
run_rg -qF 'generated guidance contains stale exact skill name code-review: CLAUDE.md' \
  "$installer_tmp/lc002-created.err"

# Round-15 F32, PRESERVED branch. F31 made Phase 3 read-only for CLAUDE.md, so an idempotent
# re-run writes the prospective block and never touches CLAUDE.md: there is no write to invert,
# and the ordering requirement must not turn F31's own target case into a blocked render.
idem_write_order="$idem_repo/.launch-control-onboard/write-order.guard.txt"
printf '%s\t%s\n' 1 .launch-control-onboard/prospective-claude.md > "$idem_write_order"
(cd "$idem_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" \
  "$idem_ledger" idem-test valid absent ready "$idem_validation" none complete) > "$installer_tmp/f32-preserved.out"
run_rg -q '^  claude-md-provenance: guard-attested -- CLAUDE\.md unwritten this run$' \
  "$installer_tmp/f32-preserved.out"
rm -f "$idem_write_order"

duplicate_ledger="$reviewer_repo/.launch-control-onboard/duplicate-ledger.tsv"
printf '%s\t%s\n' CREATED README.md PRESERVED README.md > "$duplicate_ledger"
expect_report_failure duplicate-status "$reviewer_repo" "$duplicate_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete

alias_ledger="$reviewer_repo/.launch-control-onboard/alias-ledger.tsv"
printf '%s\t%s\n' SKIPPED launch PRESERVED .claude/skills/launch/SKILL.md > "$alias_ledger"
expect_report_failure duplicate-alias "$reviewer_repo" "$alias_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete

annotated_ledger="$reviewer_repo/.launch-control-onboard/annotated-ledger.tsv"
printf '%s\t%s\n' SKIPPED '.mcp.json (not requested)' > "$annotated_ledger"
expect_report_failure annotated-path "$reviewer_repo" "$annotated_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete

missing_ledger="$reviewer_repo/.launch-control-onboard/missing-ledger.tsv"
printf '%s\t%s\n' CREATED does-not-exist > "$missing_ledger"
expect_report_failure nonexistent-path "$reviewer_repo" "$missing_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete

required_paths="$reviewer_repo/.launch-control-onboard/required-paths.txt"
printf '%s\n' .claude/settings.json > "$required_paths"
ONBOARD_REQUIRED_PATHS_FILE="$required_paths" expect_report_failure missing-required "$reviewer_repo" "$reviewer_ledger" reviewer-test valid absent ready "$reviewer_validation" none complete

# The completion guard's strict active-manifest inventory proves every status from
# pre-write type/content/executable state and rejects missing or extra records.
status_repo="$installer_tmp/status-repo"
mkdir -p "$status_repo/.claude" "$status_repo/checks"
git -C "$status_repo" init -q -b status-test
git -C "$status_repo" config user.name validator
git -C "$status_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$status_repo/checks/validate.sh"
chmod +x "$status_repo/checks/validate.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]}}' > "$status_repo/.claude/settings.json"
git -C "$status_repo" add .
git -C "$status_repo" commit -qm baseline
jq -n --arg cwd "$status_repo" --arg prompt '/onboard' \
  '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:"status-proof",prompt:$prompt}' | run_guard
write_discovery_fixture "$status_repo" status-fixture status-test none
jq -n --arg cwd "$status_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"status-proof",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
jq -n --arg cwd "$status_repo" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"status-proof",tool_name:"Write"}' | run_guard
status_git_dir="$(git -C "$status_repo" rev-parse --absolute-git-dir)"
status_inventory="$status_git_dir/launch-control-onboard-run-status-proof.inventory"
test -s "$status_inventory"
mkdir -p "$status_repo/.launch-control-onboard"
status_ledger="$status_repo/.launch-control-onboard/ledger.tsv"
while IFS=$'\t' read -r scope path before_type before_hash before_executable; do
  if [ "$before_type" = absent ]; then
    printf 'SKIPPED\t%s\n' "$path"
  else
    printf 'PRESERVED\t%s\n' "$path"
  fi
done < "$status_inventory" > "$status_ledger"
status_validation="$status_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' './checks/validate.sh' > "$status_validation"
(cd "$status_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" \
  "$status_ledger" status-test valid absent ready "$status_validation" none complete) >/dev/null

dishonest_created="$status_repo/.launch-control-onboard/dishonest-created.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" } $2 == ".claude/settings.json" { $1 = "CREATED" } { print }' \
  "$status_ledger" > "$dishonest_created"
expect_report_failure dishonest-created "$status_repo" "$dishonest_created" status-test valid absent ready "$status_validation" none complete
run_rg -q 'dishonest CREATED status' "$installer_tmp/dishonest-created.err"

dishonest_merged="$status_repo/.launch-control-onboard/dishonest-merged.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" } $2 == ".claude/settings.json" { $1 = "MERGED" } { print }' \
  "$status_ledger" > "$dishonest_merged"
expect_report_failure dishonest-merged "$status_repo" "$dishonest_merged" status-test valid absent ready "$status_validation" none complete
run_rg -q 'dishonest MERGED status' "$installer_tmp/dishonest-merged.err"

status_settings_before="$(cat "$status_repo/.claude/settings.json")"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate.sh)"]},"changed":true}' > "$status_repo/.claude/settings.json"
expect_report_failure dishonest-preserved "$status_repo" "$status_ledger" status-test valid absent ready "$status_validation" none complete
run_rg -q 'dishonest PRESERVED status' "$installer_tmp/dishonest-preserved.err"
printf '%s\n' "$status_settings_before" > "$status_repo/.claude/settings.json"

printf '%s\n' '{}' > "$status_repo/.mcp.json"
expect_report_failure dishonest-skipped "$status_repo" "$status_ledger" status-test valid absent ready "$status_validation" none complete
run_rg -q 'existing path cannot be skipped: .mcp.json' "$installer_tmp/dishonest-skipped.err"
rm -f "$status_repo/.mcp.json"

missing_status="$status_repo/.launch-control-onboard/missing-status.tsv"
awk -F '\t' '$2 != ".mcp.json"' "$status_ledger" > "$missing_status"
expect_report_failure missing-status "$status_repo" "$missing_status" status-test valid absent ready "$status_validation" none complete
run_rg -q 'inventory path is missing from ledger: .mcp.json' "$installer_tmp/missing-status.err"

extra_status="$status_repo/.launch-control-onboard/extra-status.tsv"
cp "$status_ledger" "$extra_status"
printf '%s\t%s\n' PRESERVED checks/validate.sh >> "$extra_status"
expect_report_failure extra-status "$status_repo" "$extra_status" status-test valid absent ready "$status_validation" none complete
run_rg -q 'ledger path is absent from the pre-run inventory: checks/validate.sh' "$installer_tmp/extra-status.err"

# The recorded-gate file is validated for shape before anything else: a duplicated, malformed, or
# forged entry never reaches a report. Nothing here is executed; onboarding never runs a project's
# commands. The fixture is the Launch Control repository's own two documented gates.
contract_repo="$installer_tmp/contract-repo"
mkdir -p "$contract_repo/install" "$contract_repo/tools" "$contract_repo/.launch-control-onboard" "$contract_repo/.claude"
git -C "$contract_repo" init -q -b contract-test
: > "$contract_repo/install/mcp.reference.json"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$contract_repo/tools/validate-pack.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$contract_repo/install.sh"
chmod +x "$contract_repo/tools/validate-pack.sh" "$contract_repo/install.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./tools/validate-pack.sh)","Bash(./install.sh --dry-run)"]}}' > "$contract_repo/.claude/settings.json"
printf '%s\n' seed > "$contract_repo/README.md"
contract_ledger="$contract_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' CREATED README.md > "$contract_ledger"
contract_baseline="$contract_repo/.launch-control-onboard/baseline.txt"
: > "$contract_baseline"
contract_validation="$contract_repo/.launch-control-onboard/validation-commands.txt"

render_contract() {
  (cd "$contract_repo" && ONBOARD_BASELINE_PATHS_FILE="$contract_baseline" \
    "$ROOT/skills/onboard/scripts/render-report.sh" "$contract_ledger" contract-test valid absent ready "$contract_validation" none complete)
}
expect_contract_block() {
  local name="$1"
  if render_contract >/dev/null 2>"$installer_tmp/$name.err"; then
    printf 'FAIL: renderer accepted an invalid recorded-gate file: %s\n' "$name" >&2
    exit 1
  fi
}

# A duplicated command must block.
printf '%s\n' './tools/validate-pack.sh' './tools/validate-pack.sh' > "$contract_validation"
expect_contract_block duplicate-validation
run_rg -q 'duplicate validation command' "$installer_tmp/duplicate-validation.err"

# A forged caller-authored zero status is malformed and cannot replace real execution.
printf '%s\t%s\n' 0 './tools/validate-pack.sh' 0 './install.sh --dry-run' > "$contract_validation"
expect_contract_block forged-status
run_rg -q 'invalid validation command' "$installer_tmp/forged-status.err"

# A commands path with a relative segment must block even when the resolved file is valid.
printf '%s\n' './tools/validate-pack.sh' './install.sh --dry-run' > "$contract_validation"
if (cd "$contract_repo" && ONBOARD_BASELINE_PATHS_FILE="$contract_baseline" \
    "$ROOT/skills/onboard/scripts/render-report.sh" "$contract_ledger" contract-test valid absent ready \
    "$contract_repo/.launch-control-onboard/../.launch-control-onboard/validation-commands.txt" none complete) \
    >/dev/null 2>"$installer_tmp/traversal-validation.err"; then
  printf '%s\n' 'FAIL: renderer accepted a traversal validation commands path' >&2
  exit 1
fi
run_rg -q 'must not contain relative segments' "$installer_tmp/traversal-validation.err"

# Round-14 fixtures: a small repository per scenario. Every scenario gets its own repository,
# because rewriting a tracked file between renders is itself a run-introduced change and the later
# assertions would then be testing that block instead of the behaviour under test.
r14_fixture() {
  local repo="$1"
  mkdir -p "$repo/.claude" "$repo/checks" "$repo/shims"
  git -C "$repo" init -q -b validator
  git -C "$repo" config user.name validator
  git -C "$repo" config user.email validator@example.com
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/checks/validate-a.sh"
  chmod +x "$repo/checks/validate-a.sh"
  printf '%s\n' 'shims/' > "$repo/.gitignore"
  mkdir -p "$repo/.launch-control-onboard"
  printf 'SKIPPED\t.mcp.json\n' > "$repo/.launch-control-onboard/ledger.tsv"
  : > "$repo/.launch-control-onboard/required-paths.txt"
  : > "$repo/.launch-control-onboard/baseline-paths.txt"
}
r14_commit() {
  git -C "$1" add -A
  git -C "$1" add -f .claude
  git -C "$1" commit -qm baseline
}
r14_render() {
  local repo="$1" settings="${2:-valid}"
  (cd "$repo" && PATH="$repo/shims:$PATH" \
    ONBOARD_REQUIRED_PATHS_FILE="$repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
    "$settings" absent ready .launch-control-onboard/validation-commands.txt none complete)
}

# F24. `settings-json: valid` was reportable on the caller's word alone: the renderer only checked
# that the token came from the allowed set. Today's two acceptance runs proved the gap is not
# theoretical -- code-explorer reported `valid` having never run jq at all, target repo A ran
# `jq -e` first, and the report was byte-identical either way.
r14_settings_malformed="$installer_tmp/r14-settings-malformed"
r14_fixture "$r14_settings_malformed"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"' \
  > "$r14_settings_malformed/.claude/settings.json"
r14_commit "$r14_settings_malformed"
printf '%s\n' './checks/validate-a.sh' \
  > "$r14_settings_malformed/.launch-control-onboard/validation-commands.txt"
if r14_render "$r14_settings_malformed" > /dev/null 2> "$installer_tmp/r14-settings-malformed.err"; then
  printf '%s\n' 'FAIL: renderer certified settings-json valid over an unparseable .claude/settings.json' >&2
  exit 1
fi
run_rg -q '^reported settings-json valid, but \.claude/settings\.json does not parse$' \
  "$installer_tmp/r14-settings-malformed.err"

# The same claim over a settings.json that really does parse renders.
r14_settings_ok="$installer_tmp/r14-settings-ok"
r14_fixture "$r14_settings_ok"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' \
  > "$r14_settings_ok/.claude/settings.json"
r14_commit "$r14_settings_ok"
printf '%s\n' './checks/validate-a.sh' > "$r14_settings_ok/.launch-control-onboard/validation-commands.txt"
r14_render "$r14_settings_ok" > "$installer_tmp/r14-settings-ok.out" 2> "$installer_tmp/r14-settings-ok.err"
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r14-settings-ok.out"
run_rg -q '^  settings-json: valid$' "$installer_tmp/r14-settings-ok.out"

# `valid` over a settings.json that is not there at all is the same unverified claim.
r14_settings_missing="$installer_tmp/r14-settings-missing"
r14_fixture "$r14_settings_missing"
r14_commit "$r14_settings_missing"
printf '%s\n' './checks/validate-a.sh' > "$r14_settings_missing/.launch-control-onboard/validation-commands.txt"
if r14_render "$r14_settings_missing" > /dev/null 2> "$installer_tmp/r14-settings-missing.err"; then
  printf '%s\n' 'FAIL: renderer certified settings-json valid with no .claude/settings.json at all' >&2
  exit 1
fi
run_rg -q '^reported settings-json valid, but \.claude/settings\.json does not exist$' \
  "$installer_tmp/r14-settings-missing.err"

# And the other direction: `not generated` is a claim about the filesystem too.
r14_settings_present="$installer_tmp/r14-settings-present"
r14_fixture "$r14_settings_present"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' \
  > "$r14_settings_present/.claude/settings.json"
r14_commit "$r14_settings_present"
printf '%s\n' './checks/validate-a.sh' \
  > "$r14_settings_present/.launch-control-onboard/validation-commands.txt"
if r14_render "$r14_settings_present" 'not generated' > /dev/null \
    2> "$installer_tmp/r14-settings-present.err"; then
  printf '%s\n' 'FAIL: renderer reported settings-json not generated over an existing .claude/settings.json' >&2
  exit 1
fi
run_rg -q '^reported settings-json not generated, but \.claude/settings\.json exists$' \
  "$installer_tmp/r14-settings-present.err"

# Round-17: a live render took 397s while every stage measured standalone accounted for ~13s,
# and nothing recorded where the rest went — four hypotheses were refuted by measurement before
# it became clear the renderer reports no timing at all. It now writes a per-stage timing file.
# It must go to a FILE: stdout is byte-compared by the guard at Stop, and stderr carries the
# block diagnostics, so neither can carry it without breaking a contract.
timing_repo="$installer_tmp/render-timing-repo"
mkdir -p "$timing_repo/.claude" "$timing_repo/checks" "$timing_repo/.launch-control-onboard"
git -C "$timing_repo" init -q
printf '# fixture\n' > "$timing_repo/README.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$timing_repo/checks/slow.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$timing_repo/checks/fast.sh"
chmod +x "$timing_repo/checks/slow.sh" "$timing_repo/checks/fast.sh"
printf '{"permissions":{"allow":["Bash(./checks/slow.sh)","Bash(./checks/fast.sh)"]}}\n' > "$timing_repo/.claude/settings.json"
git -C "$timing_repo" add .
git -C "$timing_repo" commit -qm baseline
printf 'CREATED\t.claude/settings.json\n' > "$timing_repo/.launch-control-onboard/ledger.tsv"
printf './checks/slow.sh\n./checks/fast.sh\n' > "$timing_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '.claude/settings.json' > "$timing_repo/.launch-control-onboard/required-paths.txt"
: > "$timing_repo/.launch-control-onboard/baseline-paths.txt"
(cd "$timing_repo" && \
  ONBOARD_REQUIRED_PATHS_FILE="$timing_repo/.launch-control-onboard/required-paths.txt" \
  ONBOARD_BASELINE_PATHS_FILE="$timing_repo/.launch-control-onboard/baseline-paths.txt" \
  "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv main valid absent ready \
  .launch-control-onboard/validation-commands.txt none complete) > "$installer_tmp/timing.out" 2> "$installer_tmp/timing.err" || {
  # The abort trap names only the line, and this render's diagnostics are the one place the
  # reason is written. Without this the nested dogfood run reports an exit code and nothing else,
  # which is exactly how the CI-only failure here stayed undiagnosed.
  printf '%s\n' 'FAIL: the render timing fixture blocked the render' >&2
  cat "$installer_tmp/timing.err" >&2
  exit 1
}
run_rg -q 'validation: not run \(2 documented gates;' "$installer_tmp/timing.out"

timing_file="$(git -C "$timing_repo" rev-parse --absolute-git-dir)/launch-control-onboard-render-timing.txt"
test -f "$timing_file"
run_rg -q 'TOTAL' "$timing_file"
run_rg -q 'run accounting' "$timing_file"
run_rg -q 'worktree verification' "$timing_file"
# Timing must never reach stdout: the guard byte-compares the report at Stop.
if run_rg -q 'TOTAL' "$installer_tmp/timing.out"; then
  printf '%s\n' 'FAIL: render timing leaked into the report stdout the guard byte-compares' >&2
  exit 1
fi

# Round-17: `ONBOARD_BASELINE_PATHS_FILE` unset left `baseline_files` empty, and bash 3.2 —
# what `/usr/bin/env bash` resolves to on stock macOS — treats an empty array expansion under
# `set -u` as unbound. The renderer aborted there and exited 0 with EMPTY stdout: the component
# whose whole purpose is refusing to fail open, failing open. Both halves are pinned.
noenv_out="$installer_tmp/render-noenv.out"
(cd "$timing_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" \
  .launch-control-onboard/ledger.tsv main valid absent ready \
  .launch-control-onboard/validation-commands.txt none complete) > "$noenv_out" 2> "$installer_tmp/render-noenv.err"
run_rg -q 'validation: not run \(2 documented gates;' "$noenv_out"
run_rg -q '=== End Workspace Setup ===' "$noenv_out"

# Success must imply an emitted report on EVERY path, not just this one: a zero exit with no
# report is the fail-open the Stop comparison would catch only downstream.
if [ ! -s "$noenv_out" ]; then
  printf '%s\n' 'FAIL: renderer exited 0 without emitting a completion report' >&2
  exit 1
fi

# `--cleanup` is the one supported zero-exit with no report, and must stay that way.
(cd "$timing_repo" && "$ROOT/skills/onboard/scripts/render-report.sh" --cleanup) > "$installer_tmp/render-cleanup.out" 2>&1
test ! -s "$installer_tmp/render-cleanup.out"

# Round-17: the preserved-content verification forked TWICE per line -- a `git hash-object` read
# probe and a `shasum` -- and the guard writes one line per BASELINE path. A measured render on a
# repository carrying an untracked `.venv/` spent 501 of its 528 seconds in that one loop while
# the project's own validation gates took 11. It now hashes candidates through ONE pipeline.
#
# Batching a verification is only safe if it cannot LOSE a path: the hasher silently omits
# anything it could not read, so the pins below fix the three ways a batch turns that omission
# into a false pass -- pairing by line position, dropping the re-check of what the hasher skipped,
# and collapsing a duplicated path into a single map entry.
pb_seq=0
pb_build() {
  pb_seq=$((pb_seq + 1))
  pb_repo="$installer_tmp/preserve-batch-repo-$pb_seq"
  mkdir -p "$pb_repo/.claude" "$pb_repo/checks" "$pb_repo/.launch-control-onboard" "$pb_repo/data"
  git -C "$pb_repo" init -q -b validator
  git -C "$pb_repo" config user.name validator
  git -C "$pb_repo" config user.email validator@example.com
  local i pb_path
  for i in $(seq 1 40); do printf 'content %s\n' "$i" > "$pb_repo/data/f$i.txt"; done
  printf 'spaced\n' > "$pb_repo/data/with space.txt"
  printf 'slashed\n' > "$pb_repo/data/with\\backslash.txt"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$pb_repo/checks/validate-a.sh"
  chmod +x "$pb_repo/checks/validate-a.sh"
  printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)"]}}' > "$pb_repo/.claude/settings.json"
  git -C "$pb_repo" add -A
  git -C "$pb_repo" commit -qm baseline
  pb_ledger="$pb_repo/.launch-control-onboard/ledger.tsv"
  pb_baseline="$pb_repo/.launch-control-onboard/baseline-paths.txt"
  pb_hashes="$pb_repo/.launch-control-onboard/preserve-hashes.guard.txt"
  : > "$pb_ledger"; : > "$pb_baseline"; : > "$pb_hashes"
  for i in $(seq 1 40); do
    printf 'PRESERVED\tdata/f%s.txt\n' "$i" >> "$pb_ledger"
    printf 'data/f%s.txt\n' "$i" >> "$pb_baseline"
    printf '%s  data/f%s.txt\n' "$(shasum -a 256 "$pb_repo/data/f$i.txt" | awk '{ print $1 }')" "$i" >> "$pb_hashes"
  done
  # A space is quoted by `git status`; a backslash is ESCAPED by the batch hasher's own output
  # format. Both spellings must survive the round trip or a clean file reports as tampered.
  for pb_path in 'with space.txt' 'with\backslash.txt'; do
    printf 'PRESERVED\tdata/%s\n' "$pb_path" >> "$pb_ledger"
    printf 'data/%s\n' "$pb_path" >> "$pb_baseline"
    printf '%s  data/%s\n' "$(shasum -a 256 "$pb_repo/data/$pb_path" | awk '{ print $1 }')" "$pb_path" >> "$pb_hashes"
  done
  : > "$pb_repo/.launch-control-onboard/required-paths.txt"
  printf '%s\n' './checks/validate-a.sh' > "$pb_repo/.launch-control-onboard/validation-commands.txt"
}
pb_render() {
  (cd "$pb_repo" && ONBOARD_REQUIRED_PATHS_FILE="$pb_repo/.launch-control-onboard/required-paths.txt" \
    ONBOARD_BASELINE_PATHS_FILE="$pb_repo/.launch-control-onboard/baseline-paths.txt" \
    "$ROOT/skills/onboard/scripts/render-report.sh" .launch-control-onboard/ledger.tsv validator \
    valid absent ready .launch-control-onboard/validation-commands.txt none complete)
}
pb_expect_tamper() {
  local pb_label="$1" pb_named="$2"
  if pb_render > /dev/null 2> "$installer_tmp/pb-$pb_label.err"; then
    printf 'FAIL: batched preserve verification passed a tampered path (%s)\n' "$pb_label" >&2
    exit 1
  fi
  run_rg -q 'preserved content verification failed' "$installer_tmp/pb-$pb_label.err"
  run_rg -qF -x "$pb_named" "$installer_tmp/pb-$pb_label.err"
}

pb_build
pb_render > "$installer_tmp/pb-clean.out" 2> "$installer_tmp/pb-clean.err" || {
  printf '%s\n' 'FAIL: a clean multi-path preserve capture blocked the render' >&2
  cat "$installer_tmp/pb-clean.err" >&2
  exit 1
}
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/pb-clean.out"
if run_rg -q 'Protected, content unverified' "$installer_tmp/pb-clean.out"; then
  printf '%s\n' 'FAIL: readable batched paths were reported as content-unverified' >&2
  exit 1
fi

# A tamper in the MIDDLE and at the END of the batch: a batch that drops its tail, or one that
# stops at the first difference, still has to name the exact path that changed.
pb_build; printf 'tampered\n' > "$pb_repo/data/f20.txt"
pb_expect_tamper midbatch 'data/f20.txt'
pb_build; printf 'tampered\n' > "$pb_repo/data/f40.txt"
pb_expect_tamper lastbatch 'data/f40.txt'
pb_build; printf 'tampered\n' > "$pb_repo/data/with space.txt"
pb_expect_tamper spacedpath 'data/with space.txt'
pb_build; printf 'tampered\n' > "$pb_repo/data/with\\backslash.txt"
pb_expect_tamper slashedpath 'data/with\backslash.txt'

# A path the capture knows about but the worktree no longer has. It lives only in the capture
# because the ledger requires its own paths to exist.
pb_build
printf '%s  data/gone.txt\n' '1111111111111111111111111111111111111111111111111111111111111111' >> "$pb_hashes"
pb_expect_tamper gonepath 'data/gone.txt (missing)'

# The batch hasher emits NOTHING for a path it cannot read, so every hash after that point shifts
# by one against the input order. Pairing by position would compare each later path against its
# predecessor's hash; this fixture puts the unreadable path in the MIDDLE so that shows up.
pb_build
mkdir -p "$pb_repo/secretdir"
printf 'SECRET=1\n' > "$pb_repo/secretdir/.env"
printf 'PRESERVED\tsecretdir/.env\n' >> "$pb_ledger"
printf 'secretdir/.env\n' >> "$pb_baseline"
{ head -n 20 "$pb_hashes"
  printf '%s  secretdir/.env\n' "$(shasum -a 256 "$pb_repo/secretdir/.env" | awk '{ print $1 }')"
  tail -n +21 "$pb_hashes"; } > "$pb_hashes.next" && mv "$pb_hashes.next" "$pb_hashes"
git -C "$pb_repo" add -A
git -C "$pb_repo" commit -qm secret
chmod 000 "$pb_repo/secretdir/.env"
pb_status=0
pb_render > "$installer_tmp/pb-protected.out" 2> "$installer_tmp/pb-protected.err" || pb_status=$?
chmod 644 "$pb_repo/secretdir/.env"
if [ "$pb_status" -ne 0 ]; then
  printf '%s\n' 'FAIL: an unreadable path inside the hash batch blocked the render' >&2
  cat "$installer_tmp/pb-protected.err" >&2
  exit 1
fi
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/pb-protected.out"
run_rg -q '^  secretdir/\.env$' "$installer_tmp/pb-protected.out"

# The same omission, isolated: an IGNORED path is invisible to `git status`, so the run-introduced
# disclosure that speaks for any other unreadable path cannot speak for this one. Only the batch's
# re-check of what the hasher skipped can, which is what makes "absent from the output" mean
# "resolve it the slow, exact way" instead of "verified".
pb_build
mkdir -p "$pb_repo/lone"
printf 'SECRET=1\n' > "$pb_repo/lone/.env"
printf 'lone/\n' > "$pb_repo/.gitignore"
git -C "$pb_repo" add .gitignore
git -C "$pb_repo" commit -qm ignore
{ head -n 10 "$pb_hashes"
  printf '%s  lone/.env\n' "$(shasum -a 256 "$pb_repo/lone/.env" | awk '{ print $1 }')"
  tail -n +11 "$pb_hashes"; } > "$pb_hashes.next" && mv "$pb_hashes.next" "$pb_hashes"
chmod 000 "$pb_repo/lone/.env"
pb_status=0
pb_render > "$installer_tmp/pb-lone.out" 2> "$installer_tmp/pb-lone.err" || pb_status=$?
chmod 644 "$pb_repo/lone/.env"
if [ "$pb_status" -ne 0 ]; then
  printf '%s\n' 'FAIL: an unreadable ignored path inside the hash batch blocked the render' >&2
  cat "$installer_tmp/pb-lone.err" >&2
  exit 1
fi
run_rg -q '^Protected, content unverified \(1\):$' "$installer_tmp/pb-lone.out"
run_rg -q '^  lone/\.env$' "$installer_tmp/pb-lone.out"

# One path, two conflicting expected hashes. A path-keyed map answers with whichever line it read
# last, so a capture whose FIRST line is the wrong one would verify clean against the second.
pb_build
{ printf '%s  data/f3.txt\n' '0000000000000000000000000000000000000000000000000000000000000000'
  cat "$pb_hashes"; } > "$pb_hashes.next" && mv "$pb_hashes.next" "$pb_hashes"
pb_expect_tamper duplicate 'data/f3.txt'

# Round-24: the renderer must refuse outright while an interrupted-capture marker is present.
# Its reuse test asked only whether the two anchor files were regular non-symlinks, so a killed
# capture -- which now leaves `.partial` names rather than a truncated file -- would otherwise
# fall through to the LAZY capture below it and re-anchor on a tree the run has already written
# to, after which every drift gate compares the run against its own output and the report signs
# off `every path above was captured and verified`. That claim is not recoverable once the
# pre-write moment is gone, so no report is the only honest outcome. Pinned both ways: the marker
# blocks a render that is otherwise clean, and the same render succeeds once it is removed.
r24r_repo="$installer_tmp/r24-render-refusal-repo"
mkdir -p "$r24r_repo/.claude"
git -C "$r24r_repo" init -q -b main
git -C "$r24r_repo" config user.name validator
git -C "$r24r_repo" config user.email validator@example.com
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$r24r_repo/noop.sh"
chmod +x "$r24r_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$r24r_repo/.claude/settings.json"
git -C "$r24r_repo" add noop.sh .claude/settings.json
git -C "$r24r_repo" commit -qm baseline
printf 'pre\n' > "$r24r_repo/pre_a.txt"
printf 'pre\n' > "$r24r_repo/pre_b.txt"
write_discovery_fixture "$r24r_repo" r24r-fixture main none
jq -n --arg cwd "$r24r_repo" --arg command "$policy_discovery_checkpoint" \
  '{hook_event_name:"PreToolUse",cwd:$cwd,session_id:"r24r",tool_name:"Bash",tool_input:{command:$command}}' | run_guard
r24r_ledger="$r24r_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' PRESERVED .claude/settings.json > "$r24r_ledger"
r24r_validation="$r24r_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './noop.sh' > "$r24r_validation"
r24r_baseline="$r24r_repo/.launch-control-onboard/baseline.txt"
printf '%s\n' pre_a.txt pre_b.txt > "$r24r_baseline"
r24r_fp="$r24r_repo/.launch-control-onboard/worktree-status.start.fingerprints"
r24r_render() {
  (cd "$r24r_repo" && ONBOARD_BASELINE_PATHS_FILE="$r24r_baseline" \
    "$ROOT/skills/onboard/scripts/render-report.sh" "$r24r_ledger" main valid absent ready \
    "$r24r_validation" none complete) > "$installer_tmp/$1.out" 2> "$installer_tmp/$1.err"
}
# The anchor here is COMPLETE; only the marker is planted. A renderer that reasons from the
# anchor files alone cannot tell this run from an honest one, which is the whole point.
printf 'pre_a.txt\tfile\t%s\t0\n' 0000000000000000000000000000000000000000 > "$r24r_fp.partial"
if r24r_render r24r-marker; then
  printf '%s\n' 'FAIL: renderer produced a report while an interrupted-capture marker was present' >&2
  exit 1
fi
run_rg -q 'run-start workspace anchor is incomplete' "$installer_tmp/r24r-marker.err"
check_absent 'Untouched pre-existing' "$installer_tmp/r24r-marker.out"
rm -f "$r24r_fp.partial"
if ! r24r_render r24r-clean; then
  printf '%s\n' 'FAIL: renderer refused a run whose interrupted-capture marker was absent' >&2
  cat "$installer_tmp/r24r-clean.err" >&2
  exit 1
fi
run_rg -q 'Untouched pre-existing' "$installer_tmp/r24r-clean.out"

# The guard pins a symlink-aliased manifest path PRESERVED, which renders it under `Preserved`
# indistinguishably from any other untouched path. The disclosure section is the only thing
# that tells a reader why a path onboarding was asked to generate came back unchanged, so it
# is asserted here independently of the guard that produces its input.
symrep_repo="$installer_tmp/symlink-report-repo"
mkdir -p "$symrep_repo/.claude/.launch-control-onboard"
git -C "$symrep_repo" init -q -b main
git -C "$symrep_repo" config user.name validator
git -C "$symrep_repo" config user.email validator@example.com
printf 'node_modules\n' > "$symrep_repo/.gitignore"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$symrep_repo/noop.sh"
chmod +x "$symrep_repo/noop.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./noop.sh)"]}}' > "$symrep_repo/.claude/settings.json"
git -C "$symrep_repo" add .gitignore noop.sh .claude/settings.json
git -C "$symrep_repo" commit -qm baseline
printf 'node_modules\ndist\n' > "$symrep_repo/.gitignore"
mkdir -p "$symrep_repo/.launch-control-onboard"
symrep_ledger="$symrep_repo/.launch-control-onboard/ledger.tsv"
printf '%s\t%s\n' PRESERVED .gitignore > "$symrep_ledger"
symrep_baseline="$symrep_repo/.launch-control-onboard/baseline.txt"
printf '%s\n' .gitignore > "$symrep_baseline"
symrep_validation="$symrep_repo/.launch-control-onboard/validation.txt"
printf '%s\n' './noop.sh' > "$symrep_validation"

# Control first: with no guard capture, the section must be absent entirely -- a section that
# printed a zero count on every ordinary run would be noise in every report Launch Control emits.
(cd "$symrep_repo" && ONBOARD_BASELINE_PATHS_FILE="$symrep_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$symrep_ledger" main valid absent ready "$symrep_validation" none complete) > "$installer_tmp/symlink-report-absent.out"
if run_rg -q 'Symlinked manifest paths' "$installer_tmp/symlink-report-absent.out"; then
  printf '%s\n' 'FAIL: the symlinked-manifest section rendered with no symlinked paths' >&2
  exit 1
fi

printf '%s\t%s\n' '.claude/skills/launch/SKILL.md' 'sub/.claude/skills/launch/SKILL.md' \
  > "$symrep_repo/.launch-control-onboard/symlinked-manifest.guard.txt"
(cd "$symrep_repo" && ONBOARD_BASELINE_PATHS_FILE="$symrep_baseline" "$ROOT/skills/onboard/scripts/render-report.sh" "$symrep_ledger" main valid absent ready "$symrep_validation" none complete) > "$installer_tmp/symlink-report.out"
run_rg -q '^Symlinked manifest paths \(1\):$' "$installer_tmp/symlink-report.out"
run_rg -q '^  \.claude/skills/launch/SKILL\.md -- resolves to sub/\.claude/skills/launch/SKILL\.md$' "$installer_tmp/symlink-report.out"
run_rg -q 'preserved, never' "$installer_tmp/symlink-report.out"
