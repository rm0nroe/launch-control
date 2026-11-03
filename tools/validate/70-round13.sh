# shellcheck shell=bash
# Round 13 — contract completeness: F17 undeclared gates, F18 nested gates.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
# F17. The exact-set contract check only fires when the renderer can derive an expected set, and
# for a whole class of repositories it derives nothing: target repo A HAS CI workflows, so
# repo_has_ci_config is true, but they run scheduled pipelines with no lint/test/build gate, and
# the package fallback needs a root build script it does not have. Enforcement was skipped
# entirely and silently, so the run's choice of gates was unverified -- it declared one gate and
# omitted `npm run test:carousel`, eligible under both remaining sources SKILL.md names and the one
# command that would have failed. Eligible-but-undeclared package scripts are now disclosed.
# LC-044: undeclared gates print grouped under the source they were derived from, so a line is
# asserted by its group, not by a reason suffix repeated on every line.
undeclared_gate_listed() {
  UG_SOURCE="  $2:" UG_COMMAND="    $3" awk '
    BEGIN { src = ENVIRON["UG_SOURCE"]; cmd = ENVIRON["UG_COMMAND"] }
    /^Undeclared gates \(/ { in_section = 1; next }
    in_section && /^[^ ]/ { in_section = 0 }
    in_section && /^  [^ ]/ { group = $0; next }
    in_section && group == src && $0 == cmd { found = 1 }
    END { exit !found }
  ' "$1"
}
# Round-13 F18 follow-up: one fixture per contract variant. Rewriting `.claude/settings.json` in
# a repository a render has already run over is itself a run-introduced change to a tracked path,
# so the second render blocks and emits no report at all -- which is why the "declaring clears it"
# case below silently proved nothing until the report-exists assertion was added.
r12_undeclared_fixture() {
  local repo="$1"
  r11_fixture "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'name: pipeline\non: schedule\njobs:\n  run:\n    steps:\n      - uses: actions/checkout@v4\n' \
    > "$repo/.github/workflows/pipeline.yml"
  # Every excluded class is represented so the classifier boundaries are pinned, not assumed.
  cat > "$repo/package.json" <<'JSON'
{
  "name": "undeclared-probe",
  "scripts": {
    "test:carousel": "node test.js",
    "install:carousel": "npm install",
    "lint": "eslint .",
    "test:watch": "vitest --watch",
    "test:e2e": "playwright test",
    "dev": "./start.sh"
  }
}
JSON
  : > "$repo/package-lock.json"
  git -C "$repo" add .github package.json package-lock.json
  git -C "$repo" commit -qm scripts
}
r12_undeclared_repo="$installer_tmp/r12-undeclared-repo"
r12_undeclared_fixture "$r12_undeclared_repo"
printf '%s\n' './checks/validate-a.sh' > "$r12_undeclared_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r12_undeclared_repo" > "$installer_tmp/r12-undeclared.out" 2> "$installer_tmp/r12-undeclared.err"; then
  printf '%s\n' 'FAIL: an undeclared eligible gate blocked the render instead of being disclosed' >&2
  tail -5 "$installer_tmp/r12-undeclared.err" >&2
  exit 1
fi
run_rg -q '^Undeclared gates \(2\):$' "$installer_tmp/r12-undeclared.out"
undeclared_gate_listed "$installer_tmp/r12-undeclared.out" package.json 'npm run lint'
undeclared_gate_listed "$installer_tmp/r12-undeclared.out" package.json 'npm run test:carousel'
# LC-044: the reason is the group header, never a suffix repeated on each line.
if run_rg -q 'not in the recorded gates' "$installer_tmp/r12-undeclared.out"; then
  printf '%s\n' 'FAIL: undeclared gates still repeat their reason on every line' >&2
  exit 1
fi
run_rg -q '^  Onboarding did not run these and makes no claim about them\.$' "$installer_tmp/r12-undeclared.out"
# Round-19: this section mints NO `Next:` entry. The retired one told the reader to "declare or
# explicitly rule out" the gates, but no rule-out mechanism exists anywhere in the pack, so the
# entry promised an action half of which could not be taken. Disclosure stays; the promise goes.
# The `=== Workspace Setup Complete ===` precondition comes first -- round-13 F19: never assert
# what output OMITS without first proving the output exists, or an empty file passes.
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-undeclared.out"
if run_rg -q 'rule out the gates' "$installer_tmp/r12-undeclared.out"; then
  printf '%s\n' 'FAIL: the undeclared-gates section still mints a Next: entry for an action the pack does not implement' >&2
  exit 1
fi
if ! run_rg -q '^  none$' "$installer_tmp/r12-undeclared.out"; then
  printf '%s\n' 'FAIL: a report whose only finding is an undeclared gate did not render Next: none' >&2
  exit 1
fi
# Classifier boundaries: install, watch, e2e, and non-gate scripts must never be listed.
for r12_excluded in 'install:carousel' 'test:watch' 'test:e2e' 'dev'; do
  if run_rg -q "npm run $r12_excluded " "$installer_tmp/r12-undeclared.out"; then
    printf 'FAIL: %s was listed as an eligible gate\n' "$r12_excluded" >&2
    exit 1
  fi
done

# Declaring the gate clears it from the disclosure, and the script-name keying means a contract
# spelled `npm test` is never accused of omitting `npm run test`.
r12_declared_repo="$installer_tmp/r12-declared-repo"
r12_undeclared_fixture "$r12_declared_repo"
printf '%s\n' './checks/validate-a.sh' 'npm run lint' 'npm run test:carousel' \
  > "$r12_declared_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(npm run lint)","Bash(npm run test:carousel)"]}}' \
  > "$r12_declared_repo/.claude/settings.json"
r11_render "$r12_declared_repo" > "$installer_tmp/r12-declared.out" 2> "$installer_tmp/r12-declared.err" || true
# A blocked render emits no report, which would satisfy the absence check below for the wrong
# reason. Pin that a report was actually produced first.
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-declared.out"
if run_rg -q '^Undeclared gates' "$installer_tmp/r12-declared.out"; then
  printf '%s\n' 'FAIL: a declared gate was still reported as undeclared' >&2
  exit 1
fi

# F18. The derivation above reads the ROOT package.json only, which is blind in exactly the
# repository class F17 was written for: target repo A's discovery reports `Monorepo: yes`,
# its CLAUDE.md names `npm run lint` and `npm run build` from `web/` as pre-PR gates, and the
# round-13 acceptance run disclosed one undeclared gate where four eligible scripts exist. A
# repository whose gates live only in nested packages derives nothing from CI and nothing from the
# root scripts -- the same silent skip, one directory level down.
# Each contract variant gets its own repository. Rewriting `.claude/settings.json` in place
# between renders is itself a run-introduced change to a tracked path, so a reused fixture would
# block on the workspace-change gate and every later assertion would be testing that block
# instead of the disclosure.
r13_nested_fixture() {
  local repo="$1"
  r11_fixture "$repo"
  mkdir -p "$repo/.github/workflows" "$repo/web" "$repo/deep/pkg" \
    "$repo/vendored/node_modules/dep" "$repo/sp ace"
  printf 'name: pipeline\non: schedule\njobs:\n  run:\n    steps:\n      - uses: actions/checkout@v4\n' \
    > "$repo/.github/workflows/pipeline.yml"
  # Root declares no gate at all: the whole point is that everything eligible is one level down.
  printf '%s\n' '{"name":"nested-probe","scripts":{"dev":"./start.sh"}}' > "$repo/package.json"
  cat > "$repo/web/package.json" <<'JSON'
{
  "name": "web",
  "scripts": {
    "lint": "next lint",
    "test": "vitest",
    "build": "next build",
    "dev": "next dev",
    "test:watch": "vitest --watch"
  }
}
JSON
  printf '%s\n' '{"scripts":{"typecheck":"tsc --noEmit"}}' > "$repo/deep/pkg/package.json"
  printf '%s\n' '{"scripts":{"test":"should never be read"}}' \
    > "$repo/vendored/node_modules/dep/package.json"
  printf '%s\n' '{"scripts":{"lint":"eslint ."}}' > "$repo/sp ace/package.json"
  : > "$repo/package-lock.json"
  # LC-055: documentation naming a nested gate the record omits must not take it out of the
  # disclosure; `npm --prefix web run lint` stays listed below.
  printf '%s\n' '# Gates' '' 'Run `cd web && npm run lint` before a PR.' > "$repo/AGENTS.md"
  # The vendored tree is force-added on purpose, so the node_modules exclusion is exercised
  # rather than satisfied for free by the fixture's .gitignore.
  git -C "$repo" add .github package.json package-lock.json AGENTS.md web deep 'sp ace'
  git -C "$repo" add -f vendored
  git -C "$repo" commit -qm nested
}
r13_nested_repo="$installer_tmp/r13-nested-repo"
r13_nested_fixture "$r13_nested_repo"
printf '%s\n' './checks/validate-a.sh' > "$r13_nested_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r13_nested_repo" > "$installer_tmp/r13-nested.out" 2> "$installer_tmp/r13-nested.err"; then
  printf '%s\n' 'FAIL: an undeclared nested gate blocked the render instead of being disclosed' >&2
  tail -5 "$installer_tmp/r13-nested.err" >&2
  exit 1
fi
run_rg -q '^Undeclared gates \(4\):$' "$installer_tmp/r13-nested.out"
undeclared_gate_listed "$installer_tmp/r13-nested.out" web/package.json 'npm --prefix web run lint'
undeclared_gate_listed "$installer_tmp/r13-nested.out" web/package.json 'npm --prefix web run test'
undeclared_gate_listed "$installer_tmp/r13-nested.out" deep/pkg/package.json 'npm --prefix deep/pkg run typecheck'
# A path the contract grammar cannot spell is still disclosed -- as a hand-run command, never as
# an unrunnable one the policy would reject if the reader declared it.
undeclared_gate_listed "$installer_tmp/r13-nested.out" \
  'sp ace/package.json, run by hand from sp ace (its path is not expressible in the contract grammar)' 'lint (in sp ace)'
if run_rg -q 'prefix sp ace' "$installer_tmp/r13-nested.out"; then
  printf '%s\n' 'FAIL: an unspellable nested directory was minted as a --prefix command' >&2
  exit 1
fi
# git ls-files never lists an ignored dependency tree, and the derivation must not reach one.
if run_rg -q 'node_modules' "$installer_tmp/r13-nested.out"; then
  printf '%s\n' 'FAIL: a nested node_modules manifest was scanned for gates' >&2
  exit 1
fi
for r13_excluded in 'build' 'dev' 'test:watch'; do
  if run_rg -q "prefix web run $r13_excluded" "$installer_tmp/r13-nested.out"; then
    printf 'FAIL: nested %s was listed as an eligible gate\n' "$r13_excluded" >&2
    exit 1
  fi
done

# Key namespacing: a root-spelled `npm run test` is a different gate from `web/test` and must
# not silently clear it. This is the failure mode that made the round-13 report read as complete.
r13_rootkey_repo="$installer_tmp/r13-rootkey-repo"
r13_nested_fixture "$r13_rootkey_repo"
printf '%s\n' './checks/validate-a.sh' 'npm run test' \
  > "$r13_rootkey_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(npm run test)"]}}' \
  > "$r13_rootkey_repo/.claude/settings.json"
r11_render "$r13_rootkey_repo" > "$installer_tmp/r13-rootkey.out" 2> "$installer_tmp/r13-rootkey.err" || true
# Anchored on the disclosure's own group: the root spelling sits in `Documented gates`, so a bare
# match would pass on the wrong line.
if ! undeclared_gate_listed "$installer_tmp/r13-rootkey.out" web/package.json 'npm --prefix web run test'; then
  printf '%s\n' 'FAIL: a root npm run test cleared the nested web/test disclosure' >&2
  tail -5 "$installer_tmp/r13-rootkey.err" >&2
  exit 1
fi

# Declaring the exact spelling the disclosure names clears that line -- and the policy accepts it,
# so the disclosure can never send a monorepo into a blocked run.
r13_declared_repo="$installer_tmp/r13-declared-repo"
r13_nested_fixture "$r13_declared_repo"
printf '%s\n' './checks/validate-a.sh' 'npm --prefix web run lint' \
  > "$r13_declared_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(npm --prefix web run lint)"]}}' \
  > "$r13_declared_repo/.claude/settings.json"
r11_render "$r13_declared_repo" > "$installer_tmp/r13-nested-declared.out" 2> "$installer_tmp/r13-nested-declared.err" || true
if run_rg -q 'outside the supported repository validation forms' "$installer_tmp/r13-nested-declared.err"; then
  printf '%s\n' 'FAIL: the policy rejected the very spelling the disclosure tells the reader to declare' >&2
  exit 1
fi
# Assert the report exists before asserting what it omits: a blocked render emits no report at
# all, which would satisfy an absence check for the wrong reason.
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r13-nested-declared.out"
if undeclared_gate_listed "$installer_tmp/r13-nested-declared.out" web/package.json 'npm --prefix web run lint'; then
  printf '%s\n' 'FAIL: a declared nested gate was still reported as undeclared' >&2
  exit 1
fi

# LC-049: a bare gate CI runs under `working-directory:` belongs to that directory. Target repo C's
# CI runs `pnpm test:node` with `defaults.run.working-directory: api`; the run recorded it verbatim,
# and the report then disclosed `npm --prefix api run test:node` as undeclared, 13 gates listed
# twice. Only CI evidence clears a nested key: the rootkey case above stays uncleared.
r13_ciscope_repo="$installer_tmp/r13-ciscope-repo"
r13_nested_fixture "$r13_ciscope_repo"
cat > "$r13_ciscope_repo/.github/workflows/ci.yml" <<'YAML'
name: ci
on: pull_request
jobs:
  web-test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: web
    steps:
      - uses: actions/checkout@v4
      - run: pnpm test
  root-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pnpm lint
  deep-typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Typecheck
        run: pnpm typecheck
        working-directory: ./deep/pkg/
YAML
git -C "$r13_ciscope_repo" add .github
git -C "$r13_ciscope_repo" commit -qm ciscope
printf '%s\n' './checks/validate-a.sh' 'pnpm lint' 'pnpm test' 'pnpm typecheck' \
  > "$r13_ciscope_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(pnpm lint)","Bash(pnpm test)","Bash(pnpm typecheck)"]}}' \
  > "$r13_ciscope_repo/.claude/settings.json"
r11_render "$r13_ciscope_repo" > "$installer_tmp/r13-ciscope.out" 2> "$installer_tmp/r13-ciscope.err" || true
if ! run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r13-ciscope.out"; then
  printf '%s\n' 'FAIL: the CI-scoped gate fixture produced no report' >&2
  tail -5 "$installer_tmp/r13-ciscope.err" >&2
  exit 1
fi
if undeclared_gate_listed "$installer_tmp/r13-ciscope.out" web/package.json 'npm --prefix web run test'; then
  printf '%s\n' 'FAIL: a gate CI runs under job defaults working-directory was still reported as undeclared' >&2
  exit 1
fi
if undeclared_gate_listed "$installer_tmp/r13-ciscope.out" deep/pkg/package.json 'npm --prefix deep/pkg run typecheck'; then
  printf '%s\n' 'FAIL: a gate CI runs under step working-directory was still reported as undeclared' >&2
  exit 1
fi
# `root-lint` sets no directory, so the previous job's must not carry over and clear `web/lint`.
if ! undeclared_gate_listed "$installer_tmp/r13-ciscope.out" web/package.json 'npm --prefix web run lint'; then
  printf '%s\n' 'FAIL: a job working-directory leaked into the next job and cleared web/lint' >&2
  exit 1
fi

# A --prefix that leaves the repository is not a package directory the repository declares.
r13_escape_repo="$installer_tmp/r13-escape-repo"
r13_nested_fixture "$r13_escape_repo"
printf '%s\n' './checks/validate-a.sh' 'npm --prefix ../elsewhere run lint' \
  > "$r13_escape_repo/.launch-control-onboard/validation-commands.txt"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/validate-a.sh)","Bash(npm --prefix ../elsewhere run lint)"]}}' \
  > "$r13_escape_repo/.claude/settings.json"
if r11_render "$r13_escape_repo" > /dev/null 2> "$installer_tmp/r13-escape.err"; then
  printf '%s\n' 'FAIL: a --prefix directory outside the repository was accepted' >&2
  exit 1
fi
run_rg -q 'names a --prefix directory that is not a repository-relative package' "$installer_tmp/r13-escape.err"

# LC-037: onboarding never runs a project's own commands. A repository whose CI declares a gate the
# recorded set omits is onboarded as it is; the derived gate is disclosed for the person onboarding.
r12_ciset_repo="$installer_tmp/r12-ciset-repo"
r11_fixture "$r12_ciset_repo"
mkdir -p "$r12_ciset_repo/.github/workflows"
printf 'name: ci\non: push\njobs:\n  test:\n    steps:\n      - run: npm run lint\n' \
  > "$r12_ciset_repo/.github/workflows/ci.yml"
git -C "$r12_ciset_repo" add .github
git -C "$r12_ciset_repo" commit -qm ci
printf '%s\n' './checks/validate-a.sh' > "$r12_ciset_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r12_ciset_repo" > "$installer_tmp/r12-ciset.out" 2> "$installer_tmp/r12-ciset.err"; then
  printf '%s\n' 'FAIL: a recorded set that differs from the CI-derived one blocked the render' >&2
  tail -5 "$installer_tmp/r12-ciset.err" >&2
  exit 1
fi
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r12-ciset.out"
undeclared_gate_listed "$installer_tmp/r12-ciset.out" 'CI configuration' 'npm run lint'
run_rg -q '^  validation: not run \(1 documented gate;' "$installer_tmp/r12-ciset.out"

# The core guarantee. A recorded gate that would write a file and fail if it ever ran is never
# executed: the file does not appear, the report completes, and nothing reports a failure.
r37_canary_repo="$installer_tmp/r37-canary-repo"
r11_fixture "$r37_canary_repo"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$PWD/canary-ran"' 'exit 1' > "$r37_canary_repo/checks/canary.sh"
chmod +x "$r37_canary_repo/checks/canary.sh"
printf '%s\n' '{"permissions":{"allow":["Bash(./checks/canary.sh)"]}}' > "$r37_canary_repo/.claude/settings.json"
git -C "$r37_canary_repo" add .
git -C "$r37_canary_repo" commit -qm canary
printf '%s\n' './checks/canary.sh' > "$r37_canary_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r37_canary_repo" > "$installer_tmp/r37-canary.out" 2> "$installer_tmp/r37-canary.err"; then
  printf '%s\n' 'FAIL: a recorded gate that would fail blocked the render' >&2
  tail -5 "$installer_tmp/r37-canary.err" >&2
  exit 1
fi
if [ -e "$r37_canary_repo/canary-ran" ]; then
  printf '%s\n' 'FAIL: onboarding executed a project command' >&2
  exit 1
fi
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r37-canary.out"
run_rg -q '^Documented gates \(1\):$' "$installer_tmp/r37-canary.out"
run_rg -q '^  \./checks/canary\.sh$' "$installer_tmp/r37-canary.out"
# LC-044: the header and the validation line already say nothing ran; no per-line suffix.
if run_rg -q 'documented, not run by onboarding' "$installer_tmp/r37-canary.out"; then
  printf '%s\n' 'FAIL: documented gates still repeat "documented, not run by onboarding" on every line' >&2
  exit 1
fi
run_rg -q "^  validation: not run \(1 documented gate; onboarding never runs a project's own commands\)\$" "$installer_tmp/r37-canary.out"
for r37_gone in 'Validation failures' 'Validation not verified' 'Environment gaps'; do
  if run_rg -q "^$r37_gone" "$installer_tmp/r37-canary.out"; then
    printf 'FAIL: the report still has a %s section though nothing ran\n' "$r37_gone" >&2
    exit 1
  fi
done

# A project that documents no gates is onboarded as it is.
r37_empty_repo="$installer_tmp/r37-empty-repo"
r11_fixture "$r37_empty_repo"
: > "$r37_empty_repo/.launch-control-onboard/validation-commands.txt"
if ! r11_render "$r37_empty_repo" > "$installer_tmp/r37-empty.out" 2> "$installer_tmp/r37-empty.err"; then
  printf '%s\n' 'FAIL: a project with no documented gates blocked the render' >&2
  tail -5 "$installer_tmp/r37-empty.err" >&2
  exit 1
fi
run_rg -q '^=== Workspace Setup Complete ===$' "$installer_tmp/r37-empty.out"
run_rg -q "^  validation: not run \(0 documented gates; onboarding never runs a project's own commands\)\$" "$installer_tmp/r37-empty.out"
if run_rg -q '^Documented gates' "$installer_tmp/r37-empty.out"; then
  printf '%s\n' 'FAIL: an empty record listed documented gates' >&2
  exit 1
fi

# Every recorded gate becomes an exact Bash allow rule for the agents onboarding sets up, so the
# safety checks stay: shell composition, destructive or external operations, and unsupported forms
# are refused even though nothing is executed.
r37_unsafe_case() {
  local name="$1" gate="$2" expected="$3" repo="$installer_tmp/r37-unsafe-$1"
  r11_fixture "$repo"
  printf '%s\n' "$gate" > "$repo/.launch-control-onboard/validation-commands.txt"
  if r11_render "$repo" > /dev/null 2> "$installer_tmp/r37-unsafe-$name.err"; then
    printf 'FAIL: an unsafe recorded gate was accepted: %s\n' "$gate" >&2
    exit 1
  fi
  run_rg -q "$expected" "$installer_tmp/r37-unsafe-$name.err"
}
# The composition case uses a gate no other check would refuse (a supported form with a pipe), so
# only the composition check can be the reason it is rejected.
r37_unsafe_case composition 'npm run lint | tee out.txt' 'forbidden shell composition'
r37_unsafe_case destructive 'rm -rf node_modules' 'not read-only or repository-local'
r37_unsafe_case unsupported 'python3 do_something.py' 'outside the supported repository validation forms'

# Decoder coverage for every escape class git emits. `%b` alone is not enough: it leaves `\"`
# undecoded, and it accepts octal only as `\0nnn`, never git's bare `\nnn` -- decoding
# `caf\303\251` without that leading zero silently yields the literal text back.
r12_unquote_probe="$installer_tmp/r12-unquote-probe.sh"
{
  printf '%s\n' 'set -euo pipefail'
  awk '/^unquote_git_path\(\) \{/, /^\}/' "$ROOT/skills/onboard/scripts/render-report.sh"
  printf '%s\n' 'check() {'
  printf '%s\n' '  unquote_git_path "$1"'
  printf '%s\n' '  if [ "$unquoted_path" != "$2" ]; then'
  printf '%s\n' '    printf "FAIL: unquote_git_path %s -> [%s], expected [%s]\n" "$1" "$unquoted_path" "$2" >&2'
  printf '%s\n' '    exit 1'
  printf '%s\n' '  fi'
  printf '%s\n' '}'
  printf '%s\n' 'check "vendor/plain.txt" "vendor/plain.txt"'
  printf '%s\n' 'check "\"vendor/with space.txt\"" "vendor/with space.txt"'
  printf '%s\n' 'check "\"a\\tb.txt\"" "$(printf "a\tb.txt")"'
  printf '%s\n' 'check "\"caf\\303\\251.txt\"" "$(printf "caf\303\251.txt")"'
  printf '%s\n' 'check "\"quote\\\"name.txt\"" "quote\"name.txt"'
  printf '%s\n' 'check "\"back\\\\slash.txt\"" "back\\slash.txt"'
  printf '%s\n' 'check "\"back\\\\\\\"both.txt\"" "back\\\"both.txt"'
} > "$r12_unquote_probe"
if ! bash "$r12_unquote_probe" > "$installer_tmp/r12-unquote.out" 2> "$installer_tmp/r12-unquote.err"; then
  printf '%s\n' 'FAIL: unquote_git_path does not decode every git C-quote escape class' >&2
  cat "$installer_tmp/r12-unquote.err" >&2
  exit 1
fi
# The guard carries its own twin; the two must not drift.
r12_guard_unquote="$installer_tmp/r12-guard-unquote.sh"
{
  printf '%s\n' 'set -euo pipefail'
  awk '/^unquote_git_path\(\) \{/, /^\}/' "$ROOT/skills/onboard/scripts/completion-guard.sh"
  sed -n '/^check() {/,$p' "$r12_unquote_probe"
} > "$r12_guard_unquote"
if ! bash "$r12_guard_unquote" > /dev/null 2> "$installer_tmp/r12-guard-unquote.err"; then
  printf '%s\n' "FAIL: the completion guard's unquote_git_path twin has drifted from the renderer's" >&2
  cat "$installer_tmp/r12-guard-unquote.err" >&2
  exit 1
fi

# F5. Batched fingerprinting must be byte-equivalent to the per-path routine it replaces.
# The renderer walked every inventory path with one `git hash-object` process (and, in the
# inventory loop, an `awk` ledger lookup too), so a 14.5k-path baseline cost tens of
# thousands of processes and ~78 minutes of wall clock at ~0:28 of CPU.
r12_fp_repo="$installer_tmp/r12-fingerprint-repo"
mkdir -p "$r12_fp_repo/sub" "$r12_fp_repo/adir"
git -C "$r12_fp_repo" init -q -b main
git -C "$r12_fp_repo" config user.name validator
git -C "$r12_fp_repo" config user.email validator@example.com
printf 'plain\n' > "$r12_fp_repo/plain.txt"
printf '#!/usr/bin/env bash\n' > "$r12_fp_repo/exec.sh"; chmod +x "$r12_fp_repo/exec.sh"
ln -sf plain.txt "$r12_fp_repo/link.txt"
printf 'nested\n' > "$r12_fp_repo/sub/nested.txt"

# Drive the renderer's own helpers so the test exercises shipped code, not a copy of it.
r12_fp_probe="$installer_tmp/r12-fp-probe.sh"
cat > "$r12_fp_probe" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
renderer_tmp="$(mktemp -d)"
trap 'rm -rf "$renderer_tmp"' EXIT
# Load only the helper definitions from the installed renderer.
eval "$(awk '/^path_read_denied\(\) \{$/,/^}$/' "$RENDER")"
eval "$(awk '/^current_path_state\(\) \{$/,/^}$/' "$RENDER")"
eval "$(awk '/^batch_hash_paths\(\) \{$/,/^}$/' "$RENDER")"
eval "$(awk '/^fingerprint_paths\(\) \{$/,/^}$/' "$RENDER")"
fingerprint_paths "$1" "$2"
# Per-path reference for the same input, in the same sorted order.
: > "$3"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  IFS=$'\t' read -r t h e < <(current_path_state "$p")
  printf '%s\t%s\t%s\t%s\n' "$p" "$t" "$h" "$e" >> "$3"
done < "$1"
LC_ALL=C sort -o "$3" "$3"
PROBE
chmod +x "$r12_fp_probe"

r12_fp_in="$installer_tmp/r12-fp-in.txt"
printf '%s\n' plain.txt exec.sh link.txt sub/nested.txt adir gone.txt > "$r12_fp_in"
(cd "$r12_fp_repo" && RENDER="$ROOT/skills/onboard/scripts/render-report.sh" \
  "$r12_fp_probe" "$r12_fp_in" "$installer_tmp/r12-fp-batched.tsv" "$installer_tmp/r12-fp-perpath.tsv")
if ! diff -q "$installer_tmp/r12-fp-batched.tsv" "$installer_tmp/r12-fp-perpath.tsv" >/dev/null; then
  printf '%s\n' 'FAIL: batched fingerprints diverged from the per-path routine' >&2
  diff "$installer_tmp/r12-fp-perpath.tsv" "$installer_tmp/r12-fp-batched.tsv" >&2 || true
  exit 1
fi
# Each classification the batch must preserve, including the symlink it may never dereference.
run_rg -q '^plain\.txt\tfile\t[0-9a-f]{40}\t0$' "$installer_tmp/r12-fp-batched.tsv"
run_rg -q '^exec\.sh\tfile\t[0-9a-f]{40}\t1$' "$installer_tmp/r12-fp-batched.tsv"
run_rg -q '^link\.txt\tsymlink\t' "$installer_tmp/r12-fp-batched.tsv"
run_rg -q '^adir\tdirectory\t-\t0$' "$installer_tmp/r12-fp-batched.tsv"
run_rg -q '^gone\.txt\tabsent\t-\t0$' "$installer_tmp/r12-fp-batched.tsv"

# A path the sandbox hides mid-batch aborts `git hash-object --stdin-paths` for every path
# after it. The denial must classify `protected` and must not shift any other path's hash.
# Deny via the PARENT directory: the sandbox refuses stat as well as open, and chmod 000 on
# the file itself only denies open - the wrong simulation (round-11).
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$r12_fp_repo/denied"
  printf 'secret\n' > "$r12_fp_repo/denied/hidden.txt"
  chmod 000 "$r12_fp_repo/denied"
  printf '%s\n' plain.txt denied/hidden.txt sub/nested.txt > "$r12_fp_in"
  (cd "$r12_fp_repo" && RENDER="$ROOT/skills/onboard/scripts/render-report.sh" \
    "$r12_fp_probe" "$r12_fp_in" "$installer_tmp/r12-fp-denied.tsv" "$installer_tmp/r12-fp-denied-ref.tsv")
  chmod 755 "$r12_fp_repo/denied"
  # The paths on either side of the denial keep their true hashes.
  r12_plain_hash="$(cd "$r12_fp_repo" && git hash-object --no-filters plain.txt)"
  r12_nested_hash="$(cd "$r12_fp_repo" && git hash-object --no-filters sub/nested.txt)"
  run_rg -q "^plain\.txt\tfile\t$r12_plain_hash\t0$" "$installer_tmp/r12-fp-denied.tsv"
  run_rg -q "^sub/nested\.txt\tfile\t$r12_nested_hash\t0$" "$installer_tmp/r12-fp-denied.tsv"
  if run_rg -q '^denied/hidden\.txt\tfile\t' "$installer_tmp/r12-fp-denied.tsv"; then
    printf '%s\n' 'FAIL: an unreadable path was hashed as an ordinary file' >&2
    exit 1
  fi
fi

# LC-037: the doctrine is pinned, not only enforced. Onboarding never runs a project's own commands,
# and the documents that route a run must say so and must not describe execution that no longer
# exists.
run_rg -q 'is a reason to emit the blocked protocol either' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'abandon the detour, not the run' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'A renderer refusal counts only once the renderer has actually refused' "$ROOT/skills/onboard/references/run-authority-and-lifecycle.md"
run_rg -q 'are reports of machine output, not analysis of it' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q 'copy it verbatim' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q "^## Boundary: onboarding never runs the project's code$" "$ROOT/skills/onboard/SKILL.md"
run_rg -q 'Onboarding never runs a project.s own commands' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q 'Record each gate as the exact string its source prescribes' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q '\*\*Record each gate as the exact string its source prescribes' "$ROOT/skills/onboard/references/context-discovery.md"
run_rg -q 'Never run a project command during onboarding' "$ROOT/skills/onboard/references/context-discovery.md"
# LC-053: the native Codex reference once told the model to run the declared gates, and a live
# run executed `npm test` and `npm run lint` in the target (2026-11-01).
run_rg -q 'Onboarding never runs a project.s own commands' "$ROOT/skills/onboard/references/codex-onboard.md"
check_absent "run the project's declared validation" "$ROOT/skills/onboard/references/codex-onboard.md"
# LC-054: the same live run rendered the raw templates without the tailoring rules, then
# hand-edited the generated .codex/ files; the blocked run skipped the preview; and both
# runtimes rendered /ticket with an in-place branch despite worktree-first delivery.
run_rg -q 'Also read `references/skills-agents-and-commands.md` completely' "$ROOT/skills/onboard/references/codex-onboard.md"
run_rg -q 'Stage and preview even when the apply will be blocked' "$ROOT/skills/onboard/references/codex-onboard.md"
run_rg -q 'Never edit generated `\.codex/`' "$ROOT/skills/onboard/references/codex-onboard.md"
run_rg -q 'git worktree add \.\./<repo>-<ticket-id> -b <ticket-id>-<description>' "$ROOT/skills/onboard/references/artifact-templates.md"
run_rg -q 'with `--no-worktrees`, outside Git, or in a submodule' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"
check_absent 'typed mocks' "$ROOT/skills/onboard/references/artifact-templates.md"
check_absent 'git pull && git checkout -b' "$ROOT/skills/onboard/references/artifact-templates.md"
check_absent 'via Atlassian MCP' "$ROOT/skills/onboard/references/artifact-templates.md"
# LC-056: a target repo C delivery gotcha lifted "Merging does not deploy" out of a section that
# applies only when Actions minutes run out, and dropped its "Vercel still deploys ui/" exception.
# Insertion bullets keep their source's condition, and every rendered Launch checks whether a
# merge deploys: the merge-deploy rule sits before the first conditional block, so no flag drops it.
run_rg -q 'Never turn a conditional statement into an unconditional one' "$ROOT/skills/onboard/references/launch-generation.md"
run_rg -q 'Model insertion pass.*references/launch-generation.md' "$ROOT/skills/onboard/references/codex-onboard.md"
awk '/\{\{#/ { exit 1 } /A merge that triggers a deploy is a deploy/ { found = 1; exit } END { exit !found }' \
  "$ROOT/skills/onboard/references/launch-delivery-template.md"
# A branch policy that blocks writes must not be routed around with a mid-run worktree:
# the renderer refuses a checkout other than the session start (target repo C, 2026-10-24).
run_rg -q 'Do not enter a worktree to get past it' "$ROOT/skills/onboard/references/context-discovery.md"
run_rg -q '"Enter a worktree so onboarding can write"' "$ROOT/skills/onboard/SKILL.md"
run_rg -q 'Documented gates \(<N>\):' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
run_rg -q 'New untracked paths \(<N>\):' "$ROOT/skills/onboard/references/completion-report-and-ledgers.md"
for r37_stale in 'Validation failures \(<N>\)' 'Validation not verified \(<N>\)' 'Environment gaps \(<N>\)' \
    'The finalizer executes every command itself' 'declared validation contract and returns fresh proof' \
    'not in the declared contract' 'contract derivation' 'point the validation command'; do
  if run_rg -q "$r37_stale" "$ROOT/skills/onboard/references/completion-report-and-ledgers.md" "$ROOT/skills/onboard/SKILL.md" "$ROOT/skills/onboard/scripts/render-report.sh"; then
    printf 'FAIL: the onboard doctrine still describes executing the project commands: %s\n' "$r37_stale" >&2
    exit 1
  fi
done
test ! -e "$ROOT/skills/onboard/references/validation-sandbox-collisions.md"
