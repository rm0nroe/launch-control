#!/usr/bin/env bash
set -euo pipefail

# BUG-4: hook-less-install cleanup fallback. Installations where the frontmatter Stop hook
# (completion-guard.sh) never registers cannot rely on it to purge the run's control
# directory and proof file. `render-report.sh --cleanup` removes them explicitly and exits.
# The normal render never self-deletes these — the stock Stop hook still needs the proof.
if [ "$1" = "--cleanup" ]; then
  if cleanup_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)"; then
    shopt -s nullglob
    cleanup_lifecycle_state=(
      "$cleanup_git_dir"/launch-control-onboard-run-*.active
      "$cleanup_git_dir"/launch-control-onboard-run-*.discovery
      "$cleanup_git_dir"/launch-control-onboard-run-*.rendered
    )
    shopt -u nullglob
    if [ "${#cleanup_lifecycle_state[@]}" -gt 0 ]; then
      echo "cannot clean onboarding proof while the lifecycle guard owns an active run" >&2
      exit 1
    fi
    rm -f "$cleanup_git_dir/launch-control-onboard-report.expected"
  fi
  rm -rf "$PWD/.launch-control-onboard"
  exit 0
fi

if [ "$#" -ne 8 ]; then
  echo "usage: render-report.sh LEDGER BRANCH SETTINGS HOOKS DEPENDENCIES VALIDATION_COMMANDS_FILE NEXT complete" >&2
  exit 2
fi

ledger="$1"
reported_branch="$2"
settings="$3"
hooks="$4"
dependencies="$5"
validation_commands_file="$6"
next="$7"
closing="$8"

workspace_tmp="$PWD/.launch-control-onboard"

normalize_control_file() {
  local label="$1" candidate="$2" normalized
  case "$candidate" in
    "$workspace_tmp"/*) normalized="$candidate" ;;
    .launch-control-onboard/*) normalized="$PWD/$candidate" ;;
    *) echo "$label must be inside $workspace_tmp" >&2; return 1 ;;
  esac
  case "/$normalized/" in
    */../*|*/./*) echo "$label path must not contain relative segments: $candidate" >&2; return 1 ;;
  esac
  test -f "$normalized" || { echo "$label file is missing: $candidate" >&2; return 1; }
  [ ! -L "$normalized" ] || { echo "$label file must not be a symbolic link: $candidate" >&2; return 1; }
  printf '%s\n' "$normalized"
}

ledger="$(normalize_control_file ledger "$ledger")"
test "$closing" = "complete"

# LC-037: the recorded-gate file is read for shape here, and an empty one is fine. A project that
# documents no gates is onboarded as it is; the report says that none were recorded.
validation_commands_early="$(normalize_control_file 'validation commands' "$validation_commands_file")"

# BEGIN ONBOARD_DEFAULT_MANIFEST
onboard_default_manifest() {
  cat <<'EOF_MANIFEST'
.claude/agents/inspector.md
.claude/agents/dispatcher.md
.claude/commands/commit.md
.claude/commands/explore.md
.claude/commands/fix.md
.claude/commands/pr.md
.claude/commands/status.md
.claude/commands/ticket.md
.claude/commands/validate.md
.claude/hooks/skill-eval.sh
.claude/settings.json
.claude/skills/checkpoint-save/SKILL.md
.claude/skills/checkpoint-load/SKILL.md
.claude/skills/checkpoint-list/SKILL.md
.claude/skills/feature-development/SKILL.md
.claude/skills/pr-workflow/SKILL.md
.claude/skills/project-code-review/SKILL.md
.claude/skills/launch/SKILL.md
.claude/skills/launch/references/delivery.md
.claude/skills/launch/references/implementation.md
.claude/skills/launch/references/ticket-intake.md
.claude/skills/launch/references/verification.md
.claude/skills/systematic-debugging/SKILL.md
.claude/skills/testing-patterns/SKILL.md
.gitignore
.mcp.json
CLAUDE.md
artifacts/architecture.md
artifacts/infrastructure.md
EOF_MANIFEST
}
# END ONBOARD_DEFAULT_MANIFEST

onboard_launch_manifest() {
  printf '%s\n' \
    '.claude/skills/launch/SKILL.md' \
    '.claude/skills/launch/references/delivery.md' \
    '.claude/skills/launch/references/implementation.md' \
    '.claude/skills/launch/references/ticket-intake.md' \
    '.claude/skills/launch/references/verification.md'
}

# Round-11: the secret boundary onboarding itself generates (`sandbox.filesystem.denyRead`)
# takes effect the moment `.claude/settings.json` is written, and from then on this process
# cannot read the very paths it protected. A tracked, dirty `.env` therefore hashed clean
# before the write and unreadable after it, which the PRESERVED comparison read as "content
# changed" and blocked an otherwise complete run. An unreadable path is not a changed path:
# record it as `protected` so the comparison can tell "could not be read" apart from
# "differs", and disclose in the report exactly what stayed unverified.
#
# The denial must be probed, never inferred from the stat-based file tests: the sandbox
# refuses `stat` as well as `open`, so `[ -f ]`, `[ -e ]`, and `[ -L ]` all report false for a
# denied path and it would otherwise classify as `absent` — indistinguishable from a real
# deletion, and still a false "content changed" against a readable pre-run capture. Only the
# read attempt itself tells the two apart, so it runs first, and its failure is trusted over
# any test that claims the path is not there.
path_read_denied() {
  local denial
  denial="$(git hash-object --no-filters "$1" 2>&1 >/dev/null)" || true
  printf '%s' "$denial" | grep -Eqi 'operation not permitted|permission denied'
}

# Round-13 F16: `git status --short` C-QUOTES any path holding a space, tab, quote, backslash, or
# non-ASCII byte -- it wraps the path in literal double quotes and backslash-escapes the contents.
# Every consumer that stats such a path fails to resolve it, and fails SILENTLY: the path
# fingerprints as `absent` both before and after validation, so no delta is ever seen. Observed
# effect: a validation command could rewrite an already-dirty file whose name contains a space and
# the render still emitted `=== Workspace Setup Complete ===`, while the plain-path control
# blocked. The same string also reached the report, where the collapse splits on `/` and turned
# `".venv` into a second, differently-spelled top-level directory.
#
# Decode at EXTRACTION, not at capture: the raw status records are only ever compared against each
# other (cmp/comm), so leaving them quoted stays self-consistent and keeps the record format every
# gate is written against. That is also why this is not `git status --porcelain -z`, which would
# change that format and add rename-record handling for no gain here.
#
# A `sed` + `printf '%b'` pipeline is NOT sufficient: `%b` leaves `\"` undecoded, and chaining
# substitutions for `\"` and `\\` double-unescapes `\\"`. Scan left to right instead, resolving
# `\"`, `\\`, and octal (which `%b` accepts only in its `\0nnn` spelling, never git's bare `\nnn`
# -- decoding `\303\251` without that leading zero silently yields the literal text back), and
# passing `\t`, `\n`, and `\r` through for `%b`.
#
# Sets `unquoted_path` rather than printing: this runs once per status record, and a repository
# with a committed-adjacent virtualenv puts tens of thousands of those in one loop (F7's lesson) --
# a command substitution here would cost a fork apiece. An unquoted path takes the first branch and
# costs nothing.
unquote_git_path() {
  local raw="$1" body out escaped octal
  case "$raw" in
    '"'*'"') ;;
    *) unquoted_path="$raw"; return 0 ;;
  esac
  body="${raw:1:${#raw}-2}"
  out=''
  while [ -n "$body" ]; do
    case "$body" in
      '\'*)
        escaped="${body:1:1}"
        case "$escaped" in
          '"') out="$out\""; body="${body:2}" ;;
          '\') out="$out\\\\"; body="${body:2}" ;;
          [0-7])
            octal="${body:1:3}"
            case "$octal" in
              [0-7][0-7][0-7]) out="$out\\0$octal"; body="${body:4}" ;;
              *) out="$out\\$escaped"; body="${body:2}" ;;
            esac
            ;;
          # `\t`, `\n`, `\r` -- leave intact, %b resolves them.
          *) out="$out\\$escaped"; body="${body:2}" ;;
        esac
        ;;
      *)
        out="$out${body:0:1}"
        body="${body:1}"
        ;;
    esac
  done
  printf -v unquoted_path '%b' "$out"
}

#
# This runs once per inventory path, and a repository with a committed-adjacent virtualenv or
# node_modules puts tens of thousands of paths in that inventory, so the probe must never be
# the default path: it costs a process per call. Hash first, since a readable file needs that
# call anyway, and probe only when the cheap answer is inconclusive — a hash that failed, or
# stat tests claiming the path is not there.
current_path_state() {
  local path="$1" type hash executable=0
  if [ -L "$path" ] || [ -f "$path" ]; then
    if [ -L "$path" ]; then
      type=symlink
    else
      type=file
      [ ! -x "$path" ] || executable=1
    fi
    hash="$(git hash-object --no-filters "$path" 2>/dev/null)" || hash=''
    if [ -z "$hash" ]; then
      type=protected
      hash=protected
      executable=0
    fi
  elif [ -d "$path" ]; then
    type=directory
    hash=-
  elif [ -e "$path" ]; then
    type=other
    hash=-
  elif path_read_denied "$path"; then
    type=protected
    hash=protected
  else
    type=absent
    hash=-
  fi
  printf '%s\t%s\t%s\n' "$type" "$hash" "$executable"
}

# Round-12: `current_path_state` costs one `git hash-object` process per call, and the loops
# below run it once per inventory path. A repository carrying an untracked `.venv/` puts
# ~14.5k paths in that inventory and is walked three times, so a render spent ~78 minutes at
# 0:28 of CPU — almost pure fork/exec. Runs were abandoned mid-render because of it, and an
# abandoned run is exactly what orphans the `.active` marker that used to brick the
# repository. Hash the readable regular files through ONE `--stdin-paths` process instead.
#
# `git hash-object --stdin-paths` aborts the whole batch at the first path it cannot read,
# emitting hashes only for the paths before it, so a naive batch silently mis-pairs every
# remaining path with the wrong hash. Pair only as many hashes as were actually returned,
# mark the offending path unresolved, and resume after it.
batch_hash_paths() {
  local in="$1" out="$2" total=0 start=1 got=0 next
  local chunk="$renderer_tmp/batch.chunk" res="$renderer_tmp/batch.res"
  : > "$out"
  total="$(grep -c '' "$in" 2>/dev/null || true)"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  while [ "$start" -le "$total" ]; do
    tail -n +"$start" "$in" > "$chunk"
    git hash-object --no-filters --stdin-paths < "$chunk" > "$res" 2>/dev/null || true
    got="$(grep -c '' "$res" 2>/dev/null || true)"
    case "$got" in ''|*[!0-9]*) got=0 ;; esac
    if [ "$got" -gt 0 ]; then
      paste <(head -n "$got" "$chunk") "$res" >> "$out"
    fi
    next=$((start + got))
    if [ "$next" -le "$total" ]; then
      # The path git stopped on: emit it with an empty hash so the caller resolves it the
      # slow, exact way (which is what classifies a denied read as `protected`).
      printf '%s\t\n' "$(sed -n "${next}p" "$in")" >> "$out"
      next=$((next + 1))
    fi
    start="$next"
  done
}

# Emit `path<TAB>type<TAB>hash<TAB>executable` for every path in $1, preserving
# `current_path_state` semantics exactly: symlinks are never dereferenced, directories and
# absent paths keep their classification, and any path the batch could not hash falls back to
# the per-path routine so a denied read still probes and classifies `protected`.
fingerprint_paths() {
  local in="$1" out="$2" path hash exec_bit t h e
  local plain="$renderer_tmp/fp.plain" other="$renderer_tmp/fp.other"
  local hashes="$renderer_tmp/fp.hashes"
  : > "$out"; : > "$plain"; : > "$other"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # These tests are shell builtins — no fork. A sandbox that denies stat makes them all
    # report false, which routes the path to the per-path branch and its read probe.
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      printf '%s\n' "$path" >> "$plain"
    else
      printf '%s\n' "$path" >> "$other"
    fi
  done < "$in"
  batch_hash_paths "$plain" "$hashes"
  while IFS=$'\t' read -r path hash; do
    [ -n "$path" ] || continue
    if [ -n "$hash" ]; then
      exec_bit=0
      [ ! -x "$path" ] || exec_bit=1
      printf '%s\tfile\t%s\t%s\n' "$path" "$hash" "$exec_bit" >> "$out"
    else
      IFS=$'\t' read -r t h e < <(current_path_state "$path")
      printf '%s\t%s\t%s\t%s\n' "$path" "$t" "$h" "$e" >> "$out"
    fi
  done < "$hashes"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    IFS=$'\t' read -r t h e < <(current_path_state "$path")
    printf '%s\t%s\t%s\t%s\n' "$path" "$t" "$h" "$e" >> "$out"
  done < "$other"
  LC_ALL=C sort -o "$out" "$out"
}

repo_has_ci_config() {
  if [ -d .github/workflows ]; then
    local nullglob_was_set=false
    if shopt -q nullglob; then nullglob_was_set=true; fi
    shopt -s nullglob
    local ci_workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
    [ "$nullglob_was_set" = true ] || shopt -u nullglob
    [ "${#ci_workflows[@]}" -eq 0 ] || return 0
  fi
  local ci
  for ci in .gitlab-ci.yml Jenkinsfile .circleci/config.yml bitbucket-pipelines.yml azure-pipelines.yml; do
    [ ! -f "$ci" ] || return 0
  done
  return 1
}

ci_config_files() {
  local nullglob_was_set=false ci
  if shopt -q nullglob; then nullglob_was_set=true; fi
  shopt -s nullglob
  local files=(.github/workflows/*.yml .github/workflows/*.yaml)
  [ "$nullglob_was_set" = true ] || shopt -u nullglob
  for ci in .gitlab-ci.yml Jenkinsfile .circleci/config.yml bitbucket-pipelines.yml azure-pipelines.yml; do
    [ ! -f "$ci" ] || files+=("$ci")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  printf '%s\n' "${files[@]}"
}

# Extract simple, renderer-supported commands that CI invokes literally. The match is
# deliberately narrower than a shell parser: composed lines are not eligible for the
# finalizer, and package installation/deploy commands are filtered below. Keeping the
# original package-manager spelling makes the derived set byte-exact.
ci_declared_commands() {
  local ci_file
  while IFS= read -r ci_file; do
    [ -n "$ci_file" ] || continue
    awk '
      /^[[:space:]]*#/ { next }
      # Round-10: a workflow step label is prose, not a command — "name: Lint with flake8"
      # must not mint a bare `flake8` contract entry.
      /^[[:space:]]*-?[[:space:]]*name:/ { next }
      # Round-10: a CI line that swallows its own exit status is non-gating in CI, so it
      # must not enter the gating local contract (e.g. `mypy src/ || true`).
      /\|\|[[:space:]]*true([[:space:]]|$)/ { next }
      {
        line = $0
        while (match(line, /(npm run|pnpm run|yarn run|bun run|pnpm|yarn|bun)[[:space:]]+[A-Za-z0-9:_-]+/)) {
          print substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
        }
        line = $0
        while (match(line, /(cargo (test|check|clippy)|go (test|vet)|pytest|make|\.\/gradlew|mvn|uv run|poetry run|bundle exec|npx tsc)[[:space:]]*[^;&|#]*/)) {
          command = substr(line, RSTART, RLENGTH)
          sub(/[[:space:]]+$/, "", command)
          # "npx tsc" needs a word boundary: npx tsc-alias / npx tsc-files are build
          # helpers, not the TypeScript compiler, and must not enter the derived contract.
          if (command !~ /^npx tsc[^[:space:]]/) {
            print command
          }
          line = substr(line, RSTART + RLENGTH)
        }
        # Round-10: Python lint/typecheck tools CI invokes literally. Arguments are
        # required so a prose mention of the bare tool name never becomes a command.
        # Scans the residual left by the previous loop, not the full line, so a
        # runner-wrapped invocation (`poetry run mypy src/`) is not extracted twice.
        while (match(line, /(flake8|mypy|ruff|pylint)[[:space:]]+[^;&|#]+/)) {
          command = substr(line, RSTART, RLENGTH)
          sub(/[[:space:]]+$/, "", command)
          print command
          line = substr(line, RSTART + RLENGTH)
        }
        if (match($0, /\.\/[^[:space:];&|#]+\.sh([[:space:]]+--?[^[:space:];&|#]+)*/)) {
          print substr($0, RSTART, RLENGTH)
        }
      }
    ' "$ci_file"
  done < <(ci_config_files)
}

# LC-049: the package-script commands a GitHub workflow runs under a `working-directory:`, as
# `<dir>\t<command>`. ci_declared_commands above reads lines, not jobs, so it drops the directory:
# target repo C's CI runs `pnpm test:node` with `defaults.run.working-directory: api`, and the bare
# string it derives can never clear the nested `api/test:node` disclosure. A step's directory wins
# over its job's, which wins over the workflow's; a command with no directory is not emitted.
# ponytail: line-based YAML, like the extractor above. Flow-style `defaults: {run: ...}`, anchors
# and matrix directories are not read; they fall back to today's disclosure, never to a block.
ci_scoped_commands() {
  local ci_file
  while IFS= read -r ci_file; do
    case "$ci_file" in .github/workflows/*) ;; *) continue ;; esac
    awk '
      function flush(   dir, i) {
        dir = step_dir != "" ? step_dir : (job_dir != "" ? job_dir : wf_dir)
        if (dir != "") for (i = 1; i <= count; i++) print dir "\t" buffered[i]
        count = 0
        step_dir = ""
      }
      BEGIN { quote = sprintf("%c", 39); job_indent = -1; steps_indent = -1; item_indent = -1 }
      /^[[:space:]]*(#|$)/ { next }
      {
        match($0, /^ */)
        indent = RLENGTH
        text = substr($0, indent + 1)
        dir_value = ""
        if (text ~ /^(- )?working-directory:/) {
          dir_value = text
          sub(/^(- )?working-directory:[[:space:]]*/, "", dir_value)
          sub(/[[:space:]]+#.*$/, "", dir_value)
          sub(/[[:space:]]+$/, "", dir_value)
          gsub("^[\"" quote "]|[\"" quote "]$", "", dir_value)
        }
      }
      indent == 0 {
        flush()
        section = text
        sub(/:.*/, "", section)
        job_indent = -1; steps_indent = -1; item_indent = -1; job_dir = ""
        next
      }
      section == "defaults" { if (dir_value != "") wf_dir = dir_value; next }
      section != "jobs" { next }
      job_indent < 0 { job_indent = indent }
      indent == job_indent { flush(); job_dir = ""; steps_indent = -1; item_indent = -1; next }
      text ~ /^steps:/ { flush(); steps_indent = indent; item_indent = -1; next }
      steps_indent >= 0 && item_indent < 0 && text ~ /^- / { item_indent = indent }
      steps_indent >= 0 && (indent < item_indent || (indent == item_indent && text !~ /^- /)) {
        flush(); steps_indent = -1; item_indent = -1
      }
      steps_indent >= 0 && indent == item_indent { flush() }
      dir_value != "" { if (steps_indent >= 0) step_dir = dir_value; else job_dir = dir_value; next }
      steps_indent < 0 { next }
      text ~ /^(- )?name:/ { next }
      /\|\|[[:space:]]*true([[:space:]]|$)/ { next }
      {
        line = $0
        while (match(line, /(npm run|pnpm run|yarn run|bun run|pnpm|yarn|bun)[[:space:]]+[A-Za-z0-9:_-]+/)) {
          buffered[++count] = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
        }
      }
      END { flush() }
    ' "$ci_file"
  done < <(ci_config_files)
}

validation_command_class() {
  local command="$1" lowered script
  lowered="$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    # Round-13 F17: a watch script never exits, so it can never be a gate — and it would
    # otherwise classify as `test` on the `*test*` arm below (`test:watch`).
    *install*|*publish*|*deploy*|*release*|*watch*) printf '%s\n' excluded ;;
    *e2e*|*end-to-end*|*playwright*|*cypress*) printf '%s\n' ci-owned ;;
    npm\ run\ build*|pnpm\ run\ build*|yarn\ run\ build*|bun\ run\ build*|pnpm\ build*|yarn\ build*|bun\ build*) printf '%s\n' ci-owned ;;
    ruff\ format*) printf '%s\n' excluded ;;
    *lint*|*clippy*|flake8|flake8\ *|ruff|ruff\ *) printf '%s\n' lint ;;
    *typecheck*|*type-check*|*check-types*|*tsc*|mypy|mypy\ *) printf '%s\n' typecheck ;;
    *test*|pytest*) printf '%s\n' test ;;
    cargo\ check*|go\ vet*) printf '%s\n' typecheck ;;
    ./*.sh*) printf '%s\n' local ;;
    *)
      script="${lowered#* }"
      case "$script" in format|format:*|fmt|fmt:*) printf '%s\n' excluded ;; *) printf '%s\n' excluded ;; esac
      ;;
  esac
}

# Round-10: pytest coverage flags exist to feed the CI-owned coverage-upload step
# (codecov and friends) and hard-require the pytest-cov plugin, which CI installs and a
# local machine often lacks. Coverage reporting is CI-owned like build and e2e: the
# derived local contract uses the coverage-stripped spelling of the CI test command.
strip_ci_owned_coverage_flags() {
  case "$1" in
    pytest\ *--cov*|uv\ run\ pytest\ *--cov*|poetry\ run\ pytest\ *--cov*)
      printf '%s' "$1" | awk '{
        out = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^--cov/) continue
          out = out (out == "" ? "" : " ") $i
        }
        print out
      }'
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Round-11: CI runs its tools inside CI's own provisioned environment, so a CI line spells
# them bare. Locally the same bare spelling resolves against PATH instead of the project
# environment. Prefixing the project runner is therefore a derivation normalization, exactly
# like coverage-flag stripping: without it the derived contract and the runner-spelling guard
# below would demand different spellings of the same command, and a lockfile-managed
# repository with CI could satisfy neither.
apply_project_runner_spelling() {
  local runner=''
  if [ -f uv.lock ]; then
    runner=uv
  elif [ -f poetry.lock ]; then
    runner=poetry
  fi
  if [ -n "$runner" ]; then
    case "$1" in
      uv\ run\ *|poetry\ run\ *|./*) ;;
      *)
        case "${1%% *}" in
          pytest|mypy|flake8|ruff|pylint) printf '%s\n' "$runner run $1"; return ;;
        esac
        ;;
    esac
  fi
  printf '%s\n' "$1"
}

# Round-16: the repository-root `.env*` files Phase 1a's generated policy denies reads of.
# The exact example/sample/template spellings are allowed by the unattended policy and are not
# secrets, so they are excluded here, although the settings denies block them too (LC-001). Filesystem existence is the test, not git tracking: a real
# `.env` is normally untracked and the denial fires on the file being there.
denied_root_env_paths() {
  local path
  for path in .env .env.*; do
    [ -f "$path" ] || continue
    case "$path" in
      .env.example|.env.sample|.env.template|.env.local.example) continue ;;
    esac
    printf '%s\n' "$path"
  done | LC_ALL=C sort
}

command_is_pytest() {
  local rest="$1"
  rest="${rest#uv run }"
  rest="${rest#poetry run }"
  case "${rest%% *}" in
    pytest|*/pytest) return 0 ;;
  esac
  return 1
}

# Round-16: predict the secret-boundary collision instead of discovering it by executing into
# it. pytest >=8 collects the rootdir Dir before descending to the declared test path, so a
# denied repository-root `.env` fails collection ("ERROR collecting .", exit 4) whatever the
# tests read -- the failure is on the path, and no declared value can satisfy it. The remedy
# is always the same exclusion (`--ignore=<that env file>`, verified to weaken no boundary),
# so derive it into the EXPECTED gate. LC-037: the derived set is disclosed, never enforced, and
# nothing here is run. SKILL.md states the same rule at
# contract-authoring time so the first render declares it and nothing has to be rejected at all.
apply_denied_env_exclusion() {
  local command="$1" path
  if ! command_is_pytest "$command"; then
    printf '%s\n' "$command"
    return
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$command" in
      *"--ignore=$path"*) continue ;;
    esac
    command="$command --ignore=$path"
  done < <(denied_root_env_paths)
  printf '%s\n' "$command"
}

derive_ci_validation_contract() {
  local command class
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    class="$(validation_command_class "$command")"
    case "$class" in
      lint|typecheck|test|local)
        apply_denied_env_exclusion \
          "$(apply_project_runner_spelling "$(strip_ci_owned_coverage_flags "$command")")"
        ;;
    esac
  done < <(ci_declared_commands) | LC_ALL=C sort -u
}

derive_ci_owned_contract() {
  local command class
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    class="$(validation_command_class "$command")"
    [ "$class" != ci-owned ] || printf '%s\n' "$command"
  done < <(ci_declared_commands) | LC_ALL=C sort -u
}

ci_contract_has_standard_three() {
  local command class have_lint=false have_typecheck=false have_test=false
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    class="$(validation_command_class "$command")"
    case "$class" in
      lint) have_lint=true ;;
      typecheck) have_typecheck=true ;;
      test) have_test=true ;;
    esac
  done < <(derive_ci_validation_contract)
  [ "$have_lint" = true ] && [ "$have_typecheck" = true ] && [ "$have_test" = true ]
}

# The lockfile ladder that decides how a package script is spelled. Empty when no lockfile
# identifies the manager, which is what keeps derive_no_ci_build_contract's behaviour unchanged.
package_manager_run_prefix() {
  if [ -f pnpm-lock.yaml ]; then
    printf '%s' 'pnpm '
  elif [ -f yarn.lock ]; then
    printf '%s' 'yarn '
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then
    printf '%s' 'bun run '
  elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
    printf '%s' 'npm run '
  fi
}

derive_no_ci_build_contract() {
  [ -f package.json ] && command -v jq >/dev/null 2>&1 || return 0
  jq -e '.scripts.build | type == "string" and length > 0' package.json >/dev/null 2>&1 || return 0
  local prefix
  prefix="$(package_manager_run_prefix)"
  [ -n "$prefix" ] || return 0
  printf '%s\n' "${prefix}build"
}

# Round-33 F43. Every eligible package script the repository's own tracked ROOT documentation
# names as a gate, spelled as the command a contract would declare, derived independently of what
# the run recorded. Every derivation that yields an expected set unions this in, so documented
# gates a record omits are disclosed. Callers must have run build_doc_gate_fragments first.
derive_documented_script_gates() {
  local candidate_script candidate_command
  while IFS=$'\t' read -r candidate_script candidate_command; do
    [ -n "$candidate_script" ] || continue
    root_gate_doc_needles "$candidate_script" > "$doc_gate_needles"
    [ -n "$(doc_fragment_source root "$doc_gate_needles")" ] || continue
    printf '%s\n' "$candidate_command"
  done < <(derive_script_gate_candidates)
}

# Round-13 F17: the derived-gate disclosure below only has an expected set when the renderer can derive an
# expected contract, and for a whole class of repositories it cannot: target repo A HAS CI
# workflows, so repo_has_ci_config is true, but they run scheduled pipelines with no lint/test/build
# gate, and the package fallback needs a root build script it does not have. Both derivations come
# back empty, so enforcement was skipped entirely -- silently, with no disclosure that no check ran.
# The run then declared one gate and omitted `npm run test:carousel`, which is eligible under both
# remaining sources SKILL.md names (root package scripts, and AGENTS.md), and which was the one
# command that would have failed. Nothing could notice.
#
# Derive the eligible package scripts independently so an omission becomes visible. This DISCLOSES
# rather than blocks: a false positive must cost a report line, never an unonboardable repository.
# Emits `<script name>\t<spelled command>`; the name is what the comparison keys on, so a contract
# declaring `npm test` is not accused of omitting `npm run test`.
derive_script_gate_candidates() {
  [ -f package.json ] && command -v jq >/dev/null 2>&1 || return 0
  local prefix script command class
  prefix="$(package_manager_run_prefix)"
  # A package.json with no lockfile still has scripts worth naming. Nothing here is executed, so
  # the conventional spelling is enough for a disclosure even when the manager is unidentified.
  [ -n "$prefix" ] || prefix='npm run '
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    case "$script" in *[!A-Za-z0-9:_-]*) continue ;; esac
    command="$prefix$script"
    class="$(validation_command_class "$command")"
    case "$class" in
      lint|typecheck|test) printf '%s\t%s\n' "$script" "$command" ;;
    esac
  done < <(jq -r '.scripts // {} | keys[]' package.json 2>/dev/null) | LC_ALL=C sort -u
}

# Round-13 F18: the root-only derivation above is blind in exactly the repository class F17 was
# written for. Target repo A's own discovery reports `Monorepo: yes (npm workspaces)`, and its
# CLAUDE.md names `npm run lint` and `npm run build` from `web/` as real pre-PR gates -- yet
# `web/package.json` is invisible to derive_script_gate_candidates, so the round-13 acceptance run
# disclosed one undeclared gate where four eligible scripts exist. A repository whose gates live
# ONLY in nested packages derives nothing from CI and nothing from the root scripts: the same
# silent skip F17 exists to end, one directory level down.
#
# Tracked nested manifests only. `git ls-files` already excludes node_modules, build output, and
# anything else the repository ignores, so no depth cap or prune list is needed -- and `-z` keeps a
# spaced path from arriving C-quoted (round-13 F16). The root manifest carries no slash and so is
# never matched here.
#
# Emits `<key>\t<spelled command>\t<reason>`. The key is `<dir>/<script>`, a namespace a bare root
# script name can never collide with, so declaring root `npm run test` neither clears nor is
# accused of `web/test`.
derive_nested_script_gate_candidates() {
  command -v jq >/dev/null 2>&1 || return 0
  local manifest dir script command class
  while IFS= read -r -d '' manifest; do
    dir="${manifest%/package.json}"
    [ -n "$dir" ] && [ "$dir" != "$manifest" ] || continue
    case "/$dir/" in */node_modules/*) continue ;; esac
    [ -f "$manifest" ] || continue
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      case "$script" in *[!A-Za-z0-9:_-]*) continue ;; esac
      # The spelling is classified the same way the root scripts are; `--prefix` shifts only the
      # directory, so `npm --prefix web run build` still falls out as excluded rather than a gate.
      command="npm --prefix $dir run $script"
      class="$(validation_command_class "$command")"
      case "$class" in
        lint|typecheck|test) ;;
        *) continue ;;
      esac
      # A directory the contract grammar cannot spell (whitespace or shell metacharacters would
      # make `--prefix <dir>` ambiguous, and the policy rejects the composition outright) still
      # gets a line. Naming an unrunnable command would be a trap; naming nothing would be the
      # silent omission this whole check exists to end.
      case "$dir" in
        *[!A-Za-z0-9./_-]*|/*|*..*)
          printf '%s\t%s\t%s\n' "$dir/$script" "$script (in $dir)" \
            "$dir/package.json, run by hand from $dir (its path is not expressible in the contract grammar)"
          ;;
        *)
          printf '%s\t%s\t%s\n' "$dir/$script" "$command" \
            "$dir/package.json"
          ;;
      esac
    done < <(jq -r '.scripts // {} | keys[]' "$manifest" 2>/dev/null)
  done < <(git ls-files -z -- '*/package.json' 2>/dev/null) | LC_ALL=C sort -u
}

# Round-14 F23, as amended by LC-037: a root script the repository's own documentation names as a
# gate joins the expected set (derive_documented_script_gates), so a record that omits it is
# disclosed under `Undeclared gates`. It never blocks: onboarding has no say over how a project is
# tested.
#
# The matching is deliberately conservative: it reads only root-level *tracked* documentation, only
# the exact spellings documentation actually uses, and it drops CLAUDE.md's own onboard-generated
# section -- a rerun that read its own prior output as repository evidence would be self-confirming.

# Documentation, reduced to the command fragments a spelling can be matched against. Each record is
# `<source file>\troot\t<fragment>`, emitted only for fragments that no `cd <dir>` in the same
# command has scoped to a subdirectory, so `cd web && npm run lint` never satisfies a root `lint`
# gate that the same document never mentions.
# `$doc_gate_fragments` is assigned at the collection site below, where `$renderer_tmp` exists.
build_doc_gate_fragments() {
  local doc
  : > "$doc_gate_fragments"
  while IFS= read -r -d '' doc; do
    # Repository root only; `git ls-files` already confines this to tracked files, so an untracked
    # scratch README can never mint a blocking gate.
    case "$doc" in */*) continue ;; esac
    [ -f "$doc" ] || continue
    # shellcheck disable=SC2016
    awk -v src="$doc" '
      function normalize(s) {
        gsub(/[ \t]+/, " ", s)
        sub(/^ /, "", s)
        sub(/ $/, "", s)
        return s
      }
      # The onboard-generated block is heading-delimited (`## Generated Quick Reference` through the
      # next top-level heading or EOF). Legacy comment markers from older onboard versions are
      # honoured too. Neither is repository-declared evidence.
      index($0, "BEGIN GENERATED SECTION -- onboard") { generated = 1; next }
      index($0, "END GENERATED SECTION -- onboard") { generated = 0; next }
      $0 == "## Generated Quick Reference" { generated = 1; next }
      generated && /^# / { generated = 0 }
      generated { next }
      {
        line = $0
        gsub(/[][`(),;|"'"'"']/, "\n", line)
        parts = split(line, part, "\n")
        for (i = 1; i <= parts; i++) {
          fragment = normalize(part[i])
          if (fragment == "") continue
          segments = split(fragment, segment, "&&")
          scoped = 0
          for (j = 1; j <= segments; j++) {
            piece = normalize(segment[j])
            if (piece == "") continue
            if (piece ~ /^cd / || index(piece, " cd ") > 0) { scoped = 1; continue }
            if (!scoped) print src "\troot\t" piece
          }
        }
      }
    ' "$doc" >> "$doc_gate_fragments"
  done < <(git ls-files -z -- 'AGENTS.md' 'CLAUDE.md' 'CONTRIBUTING.md' 'README*' 2>/dev/null)
}

# The first documentation file naming any of the spellings in `$2` (one per line), or nothing. The
# spelling must sit on a word boundary inside the fragment: `npm run lint` names the `lint` script
# and must not be read as naming `lint:fix`, and a trailing flag (`npm run lint --fix`) still counts.
#
# The spellings arrive as a FILE, not as `-v`: a `-v` value is parsed as a string literal, and the
# awk macOS ships rejects a literal newline inside one outright ("newline in string"). Keyed on
# FILENAME rather than NR == FNR, for the reason lib.sh records — an empty first file makes
# NR == FNR true for the second one too.
doc_fragment_source() {
  local scope="$1" needle_file="$2"
  awk -F '\t' -v scope="$scope" -v needlefile="$needle_file" '
    FILENAME == needlefile { if ($0 != "") needle[++count] = $0; next }
    $2 != scope { next }
    {
      for (i = 1; i <= count; i++) {
        if (needle[i] == "") continue
        start = index($3, needle[i])
        while (start > 0) {
          before = (start == 1) ? " " : substr($3, start - 1, 1)
          stop = start + length(needle[i])
          after = (stop > length($3)) ? " " : substr($3, stop, 1)
          if (before == " " && after == " ") { print $1; exit }
          advance = index(substr($3, start + 1), needle[i])
          start = (advance > 0) ? start + advance : 0
        }
      }
    }
  ' "$needle_file" "$doc_gate_fragments"
}

# The spellings documentation uses for a root script. `npm <script>` is not among them — it is not a
# runnable npm form — but `npm test` is, and it is the one bare spelling docs do write.
root_gate_doc_needles() {
  local script="$1" runner
  for runner in 'npm run' 'pnpm run' 'yarn run' 'bun run' pnpm yarn bun; do
    printf '%s %s\n' "$runner" "$script"
  done
  [ "$script" != test ] || printf '%s\n' 'npm test'
}

# The package script a declared command invokes, if any. Covers the `run` forms, the `test`
# builtin, and the bare `pnpm|yarn|bun <script>` spellings the contract already accepts.
# Round-13 F18: also the `npm --prefix <dir> run <script>` form, which is the one spelling the
# nested disclosure names and therefore the one that has to clear it. Its key is `<dir>/<script>`,
# matching derive_nested_script_gate_candidates.
declared_script_name() {
  local command="$1" rest prefix_dir
  case "$command" in
    npm\ --prefix\ *\ run\ *)
      rest="${command#npm --prefix }"
      prefix_dir="${rest%% *}"
      rest="${rest#"$prefix_dir" run }"
      rest="${rest%% *}"
      case "$prefix_dir" in ''|*[!A-Za-z0-9./_-]*|/*|*..*) return 0 ;; esac
      prefix_dir="${prefix_dir%/}"
      case "$rest" in ''|*[!A-Za-z0-9:_-]*) return 0 ;; esac
      printf '%s\n' "$prefix_dir/$rest"
      return 0
      ;;
    npm\ run\ *|pnpm\ run\ *|yarn\ run\ *|bun\ run\ *) rest="${command#* run }" ;;
    npm\ test|npm\ test\ *|pnpm\ test|pnpm\ test\ *|yarn\ test|yarn\ test\ *|bun\ test|bun\ test\ *) rest=test ;;
    pnpm\ *|yarn\ *|bun\ *) rest="${command#* }" ;;
    *) return 0 ;;
  esac
  rest="${rest%% *}"
  case "$rest" in ''|*[!A-Za-z0-9:_-]*) return 0 ;; esac
  printf '%s\n' "$rest"
}

# Round-35 FIX B. The whole derivation above, behind one entry point, so the completion guard can
# reach the SAME answer at Write time without a second implementation of it. Sets the globals
# `expected_validation` and `package_validation_fallback`; an empty `expected_validation` means no
# independent command source exists and every caller must stand down rather than block.
#
# A copy of this logic in completion-guard.sh was the obvious shape and is the wrong one: the two
# would drift, and the drift would surface as a guard that denies the exact contract the renderer
# then demands -- a deadlock with no in-band remedy, which is the round-11 failure this pack has
# already paid for once.
derive_expected_validation_contract() {
  local contract_scratch="$1"
  local documented_gates
  doc_gate_fragments="$contract_scratch/doc-gate-fragments"
  doc_gate_needles="$contract_scratch/doc-gate-needles"
  build_doc_gate_fragments
  expected_validation=''
  package_validation_fallback=false
  if [ -f install/mcp.reference.json ] && [ -f tools/validate-pack.sh ] && [ -f install.sh ]; then
    expected_validation="$(printf '%s\n' './tools/validate-pack.sh' './install.sh --dry-run' | LC_ALL=C sort)"
  elif repo_has_ci_config; then
    expected_validation="$(derive_ci_validation_contract)"
    if [ -z "$expected_validation" ]; then
      # Round-4 (review finding 3): a uses:-only composite/reusable workflow declares no
      # run commands. That is not an onboarding failure — fall back to the package-metadata
      # derivation; when that is empty too there is no independent command source and the
      # legacy explicit-file path applies (expected_validation stays empty, enforcement skips).
      expected_validation="$(derive_no_ci_build_contract)"
      [ -z "$expected_validation" ] || package_validation_fallback=true
    fi
  else
    expected_validation="$(derive_no_ci_build_contract)"
  fi
  # Round-33 F43: union the documented gates into whatever derivation ran, once, here. Applying it
  # inside the package branch alone was not enough -- the CI branch deadlocks the same way, proven
  # on a fixture whose workflow runs `npm run lint` and whose CLAUDE.md also names `npm run
  # typecheck`: declaring {lint} is refused by the documented-gate rule and declaring
  # {lint,typecheck} by the derived-set rule (LC-037: both are now disclosures, never refusals). Any branch that derives a non-empty expectation can
  # disagree with the documented-gate rule, so the reconciliation belongs where they all meet.
  #
  # A documented `build` cannot enter this union and needs no filter: derive_script_gate_candidates
  # emits only the lint, typecheck, and test classes, so build is not a candidate in the first
  # place. That matters under CI, where build is CI-owned and the loop below rejects declaring it --
  # admitting it here would rebuild the same contradiction from the other side. An explicit strip
  # was written for that case and then removed: no fixture could exercise it, because the class
  # filter already makes it unreachable.
  if [ -n "$expected_validation" ]; then
    documented_gates="$(derive_documented_script_gates)"
    if [ -n "$documented_gates" ]; then
      expected_validation="$(printf '%s\n%s\n' "$expected_validation" "$documented_gates" |
        grep '[^[:space:]]' | LC_ALL=C sort -u)"
    fi
  fi
}


branch="$(git branch --show-current)"
if [ -z "$branch" ]; then
  echo "cannot derive current branch" >&2
  exit 1
fi
if [ "$reported_branch" != "$branch" ]; then
  echo "reported branch does not match live branch: $reported_branch != $branch" >&2
  exit 1
fi

# Round-14 F24: this accepted the caller's word. Two acceptance runs of the same skill reported the
# same field two different ways — code-explorer reported `settings-json: valid` having never run jq
# at all, target repo A ran `jq -e` first — and the renderer could not tell them apart, because
# it only checked that the token was spelled from the allowed set. Every other status on the Checks
# block is machine-derived; a caller-authored status value must never be able to mint success here
# either. Verify both values against the filesystem, in the same jq idiom derive_hook_status uses
# below.
case "$settings" in
  valid)
    if [ ! -f .claude/settings.json ]; then
      echo "reported settings-json valid, but .claude/settings.json does not exist" >&2
      exit 1
    fi
    if ! jq -e . .claude/settings.json >/dev/null 2>&1; then
      echo "reported settings-json valid, but .claude/settings.json does not parse" >&2
      exit 1
    fi
    ;;
  'not generated')
    # `-e` follows the link; the `-L` arm additionally catches a dangling one, which is a
    # settings.json that exists as far as any reader is concerned.
    if [ -e .claude/settings.json ] || [ -L .claude/settings.json ]; then
      echo "reported settings-json not generated, but .claude/settings.json exists" >&2
      exit 1
    fi
    ;;
  *) echo "invalid settings-json value: $settings" >&2; exit 1 ;;
esac
case "$hooks" in absent|preserved|enabled) ;; *) echo "invalid hooks value: $hooks" >&2; exit 1 ;; esac
case "$dependencies" in
  ready) ;;
  'missing: '*)
    missing_dependency="${dependencies#missing: }"
    [ -n "$missing_dependency" ] || { echo "missing dependency name is empty" >&2; exit 1; }
    ;;
  *) echo "invalid dependencies value: $dependencies" >&2; exit 1 ;;
esac
test "$next" = "none" || { echo "invalid next value: $next" >&2; exit 1; }

derive_hook_status() {
  local hook_count=0 canonical_registration=false canonical_script=false
  if [ -f .claude/settings.json ]; then
    jq -e . .claude/settings.json >/dev/null 2>&1 || {
      echo "cannot derive hook status from invalid .claude/settings.json" >&2
      return 1
    }
    hook_count="$(jq '(.hooks // {}) | if type == "object" then length else 0 end' .claude/settings.json)"
    if jq -e '
      [.. | objects | .command? // empty]
      | any(. == "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-eval.sh\"")
    ' .claude/settings.json >/dev/null 2>&1; then
      canonical_registration=true
    fi
  fi
  if [ -f .claude/hooks/skill-eval.sh ] && [ ! -L .claude/hooks/skill-eval.sh ] && [ -x .claude/hooks/skill-eval.sh ]; then
    canonical_script=true
  fi
  if [ "$canonical_registration" = true ] && [ "$canonical_script" != true ]; then
    echo "configured Launch Control skill-eval hook is missing its canonical executable" >&2
    return 1
  fi
  if [ "$canonical_registration" = true ] && [ "$canonical_script" = true ]; then
    printf '%s\n' enabled
  elif [ "$hook_count" -gt 0 ] || [ "$canonical_script" = true ]; then
    printf '%s\n' preserved
  else
    printf '%s\n' absent
  fi
}

derived_hooks="$(derive_hook_status)"
if [ "$hooks" != "$derived_hooks" ]; then
  echo "reported hooks value does not match final settings/filesystem: $hooks != $derived_hooks" >&2
  exit 1
fi
hooks="$derived_hooks"

git_dir="$(git rev-parse --absolute-git-dir)"
# Round-14 F28: in degraded mode no hook runs at all, so the default states only that no mode
# was recorded. LC-058: the line states the session's mode as a fact and never grades the run
# for it; onboarding respects the mode the user chose.
permission_mode_check='none recorded'
# Round-15 F32: the prospective/on-disk byte comparison below is satisfiable from either side,
# so the report states what the guard actually attested about write ORDER rather than implying
# the comparison alone proves the block was freshly rendered. Absence of the guard record is
# not proof of honest ordering -- in degraded mode no hook runs -- so the default states only
# what was recorded. Runs that make no CLAUDE.md claim overwrite this with `not applicable`.
claude_md_provenance='no write order recorded by the completion guard'
renderer_tmp="$git_dir/launch-control-onboard-render-$$"
mkdir -p "$renderer_tmp"
# Round-17: a live render on target repo A took 397s while every stage measured
# standalone accounted for ~13s of it, and nothing recorded where the rest went. Four
# hypotheses (per-path hashing, repository size, an interactive gate on open stdin, sandbox
# syscall overhead) were each refuted by measurement, and the gap stayed unexplained because
# the renderer reports no timing at all. It does now, to a FILE: stdout is byte-compared by
# the guard at Stop and stderr carries the block diagnostics, so neither can carry this.
# Overwritten per invocation, and deliberately NOT removed by --cleanup — it is the artifact
# that explains a slow run after the fact.
render_timing_file="$git_dir/launch-control-onboard-render-timing.txt"
: > "$render_timing_file" 2>/dev/null || render_timing_file=/dev/null
render_stage_mark=$SECONDS
# `SECONDS` is a bash builtin present in 3.2, which is what /usr/bin/env bash resolves to on
# a stock macOS; `EPOCHREALTIME` is bash 5 only and aborts under `set -u` here.
mark_render_stage() {
  printf '%s\t%s\n' "$((SECONDS - render_stage_mark))" "$1" >> "$render_timing_file" 2>/dev/null || true
  render_stage_mark=$SECONDS
}
tmp="$renderer_tmp/ledger.sorted"
report="$renderer_tmp/report"
# Round-11: baseline paths the generated deny boundary hid from this run's own verification.
# They are reported, never silently treated as content-verified.
protected_unverified_file="$renderer_tmp/protected-unverified"
: > "$protected_unverified_file"
# Paths whose git-decoded NAME holds a newline. A separate channel from the one above on purpose:
# that group's note asserts one specific cause -- the generated secret boundary denied the read --
# and `f03560a` routed these here without checking that the group made a claim about WHY. It does,
# and for these the claim is false: nothing denied anything, the name simply cannot be a record in
# any of the line-oriented files this machinery is built from. Same defect class as the `Failed`
# provenance bug (`91dc993`): a report asserting a cause the machine never established.
#
# Every entry is git's own C-quoted spelling, which is single-line by construction, so this file
# stays line-oriented even though the paths it names could not be. Deliberately NOT keyed by a
# delimiter with a per-entry reason: F16 exists because these decoded names can hold literal tabs
# and spaces, so a two-column format would plant a fresh instance of the bug being fixed here.
unrepresentable_file="$renderer_tmp/unrepresentable"
: > "$unrepresentable_file"
# Round-12 F14: new untracked files a declared validation command emitted. Disclosed, not blocked
# — see the worktree comparison below for why overwriting existing state is a different class.
validation_output_file="$renderer_tmp/validation-output"
: > "$validation_output_file"
# Round-17: a `set -u` abort inside this script exited 0 with EMPTY stdout — a renderer whose
# entire purpose is refusing to fail open, failing open. The Stop comparison would still catch
# it downstream (empty output cannot match the expected report), but nothing here refused.
# Success now REQUIRES that the report was actually emitted, whatever path reached the exit.
report_emitted=false
render_exit_guard() {
  local status=$?
  if [ "$status" -eq 0 ] && [ "$report_emitted" != true ]; then
    echo "renderer exited without emitting a completion report" >&2
    status=1
  fi
  rm -rf "$renderer_tmp"
  exit "$status"
}
trap render_exit_guard EXIT

LC_ALL=C sort -u "$ledger" > "$tmp"

awk -F '\t' '
  NF != 2 || $1 !~ /^(CREATED|MERGED|SKIPPED|PRESERVED)$/ || $2 == "" || $2 ~ / \([^)]*\)$/ || $2 ~ / — / || $2 ~ /^(launch|hooks|MCP)$/ {
    print "invalid ledger record: " $0 > "/dev/stderr"
    failed = 1
  }
  END { exit failed }
' "$tmp"

awk -F '\t' '
  {
    path = $2
    statuses[path] = statuses[path] " " $1
    counts[path]++
  }
  END {
    for (path in counts) if (counts[path] > 1) {
      print "path appears in multiple statuses:" path statuses[path] > "/dev/stderr"
      failed = 1
    }
    exit failed
  }
' "$tmp"

while IFS=$'\t' read -r status path; do
  observed_path="$path"
  case "$status" in
    CREATED|MERGED|PRESERVED)
      # Round-11: a path the generated secret boundary denies fails `[ -e ]` the same way a
      # missing path does, because the sandbox refuses stat as well as open. Probe the denial
      # before calling it absent, or a protected baseline path reads as a lie about existence.
      if [ ! -e "$observed_path" ] && ! path_read_denied "$observed_path"; then
        echo "ledger path does not exist: $path" >&2
        exit 1
      fi
      ;;
    SKIPPED)
      if [ -e "$observed_path" ]; then
        echo "existing path cannot be skipped: $path" >&2
        exit 1
      fi
      ;;
  esac
done < "$tmp"

if [ -n "${ONBOARD_REQUIRED_PATHS_FILE:-}" ]; then
  ONBOARD_REQUIRED_PATHS_FILE="$(
    normalize_control_file 'required paths' "$ONBOARD_REQUIRED_PATHS_FILE"
  )"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || { echo "required path does not exist: $path" >&2; exit 1; }
    awk -F '\t' -v path="$path" '$2 == path && $1 != "SKIPPED" { found = 1 } END { exit !found }' "$tmp" || {
      echo "required path is missing from completed ledger: $path" >&2
      exit 1
    }
  done < "$ONBOARD_REQUIRED_PATHS_FILE"
fi

baseline_files=()
# Round-13 F16: a baseline capture is `git status --short` output with the status prefix stripped,
# so any path git C-quoted arrives here still quoted -- from the agent file (SKILL.md instructs
# plain `git status --short --untracked-files=all`) and, before this round, from the guard too.
# Every later consumer treats these as real paths: ledger derivation, manifest membership, the
# `Untouched pre-existing` listing, and the preserve-hash verification. Decode once, on load, so
# no consumer has to know. Files with nothing quoted are passed through untouched and cost one
# grep; only a file that actually contains a quoted path is rewritten.
normalize_baseline_quoting() {
  local source_file="$1" normalized line
  LC_ALL=C grep -q '^"' "$source_file" 2>/dev/null || { printf '%s' "$source_file"; return 0; }
  normalized="$renderer_tmp/baseline-unquoted.$(printf '%s' "$source_file" | cksum | awk '{ print $1 }')"
  : > "$normalized"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    unquote_git_path "$line"
    # Decoding is what breaks a newline-holding name: `$normalized` is line-oriented, so one
    # quoted record becomes N rows and every consumer downstream -- ledger derivation, manifest
    # membership, `Untouched pre-existing`, the preserve-hash verification -- reads the fragments
    # as paths of their own. The guard's own capture is excluded at the source
    # (completion-guard.sh), so the input that still reaches here quoted is the agent-supplied
    # `ONBOARD_BASELINE_PATHS_FILE`, produced by the plain `git status --short` SKILL.md asks for.
    if [ "$unquoted_path" != "${unquoted_path%%$'\n'*}" ]; then
      printf '%s\n' "$line" >> "$unrepresentable_file"
      continue
    fi
    printf '%s\n' "$unquoted_path" >> "$normalized"
  done < "$source_file"
  printf '%s' "$normalized"
}
# Round-5: non-manifest baseline paths (pre-existing files onboarding never manages) are
# implicitly PRESERVED — the only status the guards below accept for them. Derive those
# ledger rows from the baseline captures instead of demanding the agent hand-list every
# path: first renders repeatedly failed on exactly that gap. In hooked mode the inventory
# honesty check still content-verifies every derived row, and the preserve-hash
# verification applies in both modes, so nothing shifts from verified to trusted. Manifest
# paths (including dirty manifest-baseline ones) must still be listed explicitly.
# Idempotent: rows already present in the ledger are never duplicated.
# Round-12 F7: this ran one `grep` and one `awk` per baseline path, and the `awk` rescanned a
# ledger that the loop itself was growing by a row per iteration — quadratic work on top of
# two forks per path. A 15k-path baseline spent ~6 minutes here per call, and the function is
# called twice. `6f9bfbb` batched the fingerprinting and left this loop untouched, which is
# why target repo A still rendered in 27m24s. Resolve the whole set in one awk pass.
derive_baseline_preserved_rows() {
  local manifest_paths_early="$renderer_tmp/manifest-paths.early" baseline_file
  local baseline_all="$renderer_tmp/baseline.all" derived="$renderer_tmp/baseline.derived"
  if [ -n "${captured_mode:-}" ] && [ -f "${captured_mode}" ] && [ "$(cat "$captured_mode")" = launch-control ]; then
    onboard_launch_manifest
  else
    onboard_default_manifest
  fi | LC_ALL=C sort -u > "$manifest_paths_early"
  : > "$baseline_all"
  for baseline_file in ${baseline_files[@]+"${baseline_files[@]}"}; do
    [ -f "$baseline_file" ] || continue
    cat "$baseline_file" >> "$baseline_all"
  done
  # `seen` carries every path the ledger already carries under ANY status, which is what the
  # per-path routine tested, and it also absorbs the rows this pass emits — so a path listed
  # twice across baseline files is derived once, exactly as the growing-ledger check did.
  # The rows land in a separate file and are appended after awk returns: awk must never be
  # reading the ledger while the same command's redirection is writing to it.
  # Round-12 F10: in hooked mode `baseline_files` already carries the guard's own capture, which
  # `git status --untracked-files=all` records one row per FILE. A caller reading plain
  # `git status --short` sees the same tree collapsed to a single `dir/` entry and declares that
  # -- the only spelling a Write can practically produce for target repo A's 14k-file
  # `.venv/`. Deriving a row for it too would put a path in the report that is not a file and
  # inflate the `Untouched pre-existing` count by one over the paths actually preserved, so when
  # the captured inventory already covers the directory, the collapsed entry is redundant: drop
  # it. An uncovered directory form is NOT dropped; it falls through to the inventory check,
  # which reports it against the baseline file it came from.
  local inventory_cover="$renderer_tmp/baseline.inventory-cover"
  : > "$inventory_cover"
  if [ -n "${captured_inventory:-}" ] && [ -f "${captured_inventory}" ]; then
    awk -F '\t' '
      $2 == "" { next }
      { p = $2
        while (match(p, /\/[^\/]*$/)) {
          print substr(p, 1, RSTART)
          p = substr(p, 1, RSTART - 1)
        }
      }
    ' "$captured_inventory" | LC_ALL=C sort -u > "$inventory_cover"
  fi
  awk -F '\t' -v OFS='\t' -v mf="$manifest_paths_early" -v lf="$tmp" -v cf="$inventory_cover" '
    FILENAME == cf { covered[$0] = 1; next }
    FILENAME == mf { manifest[$0] = 1; next }
    FILENAME == lf { if ($2 != "") seen[$2] = 1; next }
    $0 == "" { next }
    $0 in manifest { next }
    $0 in seen { next }
    ($0 ~ /\/$/) && ($0 in covered) { next }
    { seen[$0] = 1; print "PRESERVED", $0 }
  ' "$inventory_cover" "$manifest_paths_early" "$tmp" "$baseline_all" > "$derived"
  [ ! -s "$derived" ] || cat "$derived" >> "$tmp"
}

if [ -n "${ONBOARD_BASELINE_PATHS_FILE:-}" ]; then
  ONBOARD_BASELINE_PATHS_FILE="$(
    normalize_control_file 'baseline paths' "$ONBOARD_BASELINE_PATHS_FILE"
  )"
  baseline_files+=("$(normalize_baseline_quoting "$ONBOARD_BASELINE_PATHS_FILE")")
fi
shopt -s nullglob
active_runs=("$git_dir"/launch-control-onboard-run-*.active)
shopt -u nullglob

# Round-12: a session that dies between its first write and its Stop hook leaves its
# `.active` marker behind forever. The count-only check below then reads that corpse as a
# concurrent run and refuses every later onboarding of the repository, with no way out but
# a manual `rm` the message never named.
#
# The renderer is never handed a session id, so ownership is established by freshness, not
# identity. The lifecycle guard re-truncates this run's own marker on every write it gates,
# so a live run's marker mtime advances continuously and only the final render window is
# quiet — minutes, against a multi-hour threshold. A marker older than that threshold
# therefore cannot be this run's own, and is safe to reap. Freshness is deliberately the
# only test: the `.discovery` attestation is a hash of the discovery report's CONTENT, so a
# rerun over an unchanged repository mints the same hash as the corpse it is trying to
# clear, and an identity check built on it would protect the very marker that must go.
ONBOARD_STALE_RUN_SECONDS="${ONBOARD_STALE_RUN_SECONDS:-14400}"

marker_age_seconds() {
  local marker="$1" mtime now
  # GNU and BSD `stat` disagree on the format flag, and the disagreement is not a clean
  # failure: on GNU, `-f` means --file-system, so `stat -f %m` reports the FILESYSTEM and
  # prints a block beginning `  File: ...`. That fed `$((now - mtime))` an expression whose
  # first token was `File`, and under `set -u` the renderer died with `File: unbound
  # variable` -- on Linux only, which is how it reached CI green on macOS. Try GNU first
  # (BSD `stat` rejects `-c` outright, so the fallback is a real failure there), and require
  # the result to be digits, so no future stat dialect can reach the arithmetic as prose.
  mtime="$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || printf '')"
  case "$mtime" in
    '' | *[!0-9]*) return 1 ;;
  esac
  now="$(date +%s)"
  printf '%s\n' "$((now - mtime))"
}

# Review follow-up: marker mtime advances only on GATED WRITES, and a validation command runs
# entirely inside one renderer invocation with none. A run whose validation legitimately takes
# longer than the threshold — a large suite, a cold toolchain provision — is therefore
# indistinguishable from an abandoned one by age alone, and reaping it would delete the live
# run's marker family out from under it: a silent concurrent takeover, strictly worse than the
# hard block with a named recovery that this reaper replaced. A render in flight leaves its PID
# in its own scratch directory name, so ask that instead of trusting the clock.
another_render_in_flight() {
  local dir pid cmd dirs
  shopt -s nullglob
  dirs=("$git_dir"/launch-control-onboard-render-*)
  shopt -u nullglob
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    pid="${dir##*-}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    # Confirm the PID is still a renderer, not an unrelated process that reused the number.
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in *render-report.sh*) return 0 ;; esac
  done
  return 1
}

reap_stale_run_markers() {
  local marker age
  # Never reap while another render is working: its quiet marker means "busy", not "dead".
  if another_render_in_flight; then
    echo "another onboarding render is in flight; leaving every run marker in place" >&2
    return 0
  fi
  for marker in "${active_runs[@]}"; do
    age="$(marker_age_seconds "$marker")" || continue
    # A fresh marker is either this run's own or a genuinely concurrent run. Never reaped.
    [ "$age" -gt "$ONBOARD_STALE_RUN_SECONDS" ] || continue
    echo "reaping a stale onboarding run marker abandoned $((age / 60))m ago: $(basename "$marker")" >&2
    rm -f "${marker%.active}".*
  done
  return 0
}

if [ "${#active_runs[@]}" -gt 1 ]; then
  reap_stale_run_markers
  shopt -s nullglob
  active_runs=("$git_dir"/launch-control-onboard-run-*.active)
  shopt -u nullglob
fi
if [ "${#active_runs[@]}" -gt 1 ]; then
  echo "multiple active onboarding runs share this repository" >&2
  for stale_candidate in "${active_runs[@]}"; do
    echo "  active marker: $(basename "$stale_candidate") (last touched $(marker_age_seconds "$stale_candidate" || printf '?')s ago)" >&2
  done
  echo "if no other onboarding session is running, one of these was abandoned by a session that never reached its Stop hook; remove that run's marker family with: rm \"$git_dir\"/launch-control-onboard-run-<session-id>.*" >&2
  exit 1
fi
if [ "${#active_runs[@]}" -eq 1 ]; then
  captured_baseline="${active_runs[0]%.active}.baseline"
  captured_inventory="${active_runs[0]%.active}.inventory"
  captured_mode="${active_runs[0]%.active}.mode"
  test -f "$captured_baseline"
  test -f "$captured_inventory"
  baseline_files+=("$(normalize_baseline_quoting "$captured_baseline")")
  captured_tasks="${active_runs[0]%.active}.tasks"
  if [ -s "$captured_tasks" ]; then
    echo "onboarding tasks remain incomplete: $(paste -sd, "$captured_tasks")" >&2
    exit 1
  fi
  active_session="$(basename "${active_runs[0]}" .active)"
  active_session="${active_session#launch-control-onboard-run-}"
  bootstrap_proof="$git_dir/launch-control-bootstrap-docs-$active_session.proof"
  # Round-14 F28: the unattended policy records bypassPermissions the first time it sees
  # the session, so this line is derived rather than volunteered. Two acceptance runs
  # presented a completion report under bypass with no disclosure anywhere -- the report
  # is the one artifact a reader is guaranteed to see, so it carries the fact.
  if [ -f "$git_dir/launch-control-onboard-run-$active_session.bypass" ]; then
    permission_mode_check='bypassPermissions -- ask-gates were denied, not asked'
  elif [ -f "$git_dir/launch-control-onboard-run-$active_session.permission-mode" ]; then
    # Round-18: name whatever mode the policy recorded. The bypass branch above still wins,
    # because under bypass the policy converts `ask` to a hard denial and that stricter fact
    # is what the reader needs. A marker whose content fails the charset check is treated as
    # absent rather than blocking the render: the default wording claims nothing either way,
    # which is the honest reading of a record that cannot be trusted.
    recorded_permission_mode="$(head -n 1 "$git_dir/launch-control-onboard-run-$active_session.permission-mode" 2>/dev/null || printf '')"
    case "$recorded_permission_mode" in
      *[!A-Za-z0-9_-]* | '')
        : ;;
      *)
        permission_mode_check="$recorded_permission_mode" ;;
    esac
  fi

  if [ -f "$captured_mode" ]; then
    mode="$(cat "$captured_mode")"
    expected_manifest="$renderer_tmp/manifest.expected"
    observed_manifest="$renderer_tmp/manifest.observed"
    case "$mode" in
      default) onboard_default_manifest ;;
      launch-control) onboard_launch_manifest ;;
      *) echo "invalid captured onboarding mode: $mode" >&2; exit 1 ;;
    esac | LC_ALL=C sort -u > "$expected_manifest"
    awk -F '\t' '$1 == "MANIFEST" || $1 == "MANIFEST_BASELINE" { print $2 }' "$captured_inventory" |
      LC_ALL=C sort -u > "$observed_manifest"
    cmp -s "$expected_manifest" "$observed_manifest" || {
      echo "captured onboarding inventory does not match the active manifest" >&2
      exit 1
    }
  fi

  # Round-5: derive implicit PRESERVED rows for non-manifest baseline paths before the
  # inventory check below demands them. See derive_baseline_preserved_rows.
  derive_baseline_preserved_rows

  # Round-12: this loop ran two processes per inventory path — an `awk` ledger lookup and a
  # `current_path_state` fingerprint — so a repository with an untracked `.venv/` spent ~29k
  # processes here. Resolve both in bulk first: batch the fingerprints, then join ledger
  # status and after-state onto the inventory in one pass, so the loop body forks nothing.
  inventory_paths="$renderer_tmp/inventory.paths"
  inventory_after="$renderer_tmp/inventory.after"
  inventory_joined="$renderer_tmp/inventory.joined"
  awk -F '\t' '$2 != "" { print $2 }' "$captured_inventory" | LC_ALL=C sort -u > "$inventory_paths"
  fingerprint_paths "$inventory_paths" "$inventory_after"
  awk -F '\t' -v OFS='\t' -v lf="$tmp" -v af="$inventory_after" '
    FILENAME == lf { if (!($2 in status)) status[$2] = $1; next }
    FILENAME == af { atype[$1] = $2; ahash[$1] = $3; aexec[$1] = $4; next }
    $2 == "" { next }
    # A path with no ledger row must carry a sentinel, never an empty column: `read` with
    # IFS=<tab> collapses consecutive tabs (tab is IFS whitespace), so an empty field would
    # silently shift every later column left and hand ledger_status the after-type.
    { print $1, $2, $3, $4, $5, ($2 in status ? status[$2] : "__NOSTATUS__"), atype[$2], ahash[$2], aexec[$2] }
  ' "$tmp" "$inventory_after" "$captured_inventory" > "$inventory_joined"

  while IFS=$'\t' read -r scope path before_type before_hash before_executable \
      ledger_status after_type after_hash after_executable; do
    [ -n "$path" ] || continue
    [ "$ledger_status" != "__NOSTATUS__" ] || ledger_status=''
    if [ -z "$ledger_status" ]; then
      if [ -f "$captured_mode" ]; then
        echo "inventory path is missing from ledger: $path" >&2
        exit 1
      fi
      continue
    fi
    case "$ledger_status" in
      CREATED)
        [ "$before_type" = absent ] && [ "$after_type" = file ] || {
          echo "dishonest CREATED status for $path: expected absent before and file after" >&2
          exit 1
        }
        ;;
      MERGED)
        [ "$before_type" = file ] && [ "$after_type" = file ] &&
          { [ "$before_hash" != "$after_hash" ] || [ "$before_executable" != "$after_executable" ]; } || {
          echo "dishonest MERGED status for $path: expected an existing file with changed content or executable state" >&2
          exit 1
        }
        ;;
      PRESERVED)
        if [ "$after_type" = protected ] && [ "$before_type" != absent ]; then
          # Round-11: the generated deny boundary hid this path from the run's own read, so
          # its content cannot be compared. The run never held write permission for it
          # either — the unattended policy admits only manifest paths — so the honest
          # outcome is to disclose the unverified path, not to claim it content-verified and
          # not to block a run whose only obstacle is a boundary onboarding just created.
          printf '%s\n' "$path" >> "$protected_unverified_file"
        else
          [ "$before_type" = "$after_type" ] &&
            [ "$before_hash" = "$after_hash" ] &&
            [ "$before_executable" = "$after_executable" ] || {
            echo "dishonest PRESERVED status for $path: pre-run type, content, or executable state changed" >&2
            exit 1
          }
        fi
        ;;
      SKIPPED)
        [ "$before_type" = absent ] && [ "$after_type" = absent ] || {
          echo "dishonest SKIPPED status for $path: expected absent before and after" >&2
          exit 1
        }
        ;;
    esac
    case "$scope" in
      BASELINE|MANIFEST_BASELINE)
        [ "$ledger_status" = PRESERVED ] || {
          echo "dirty baseline path must remain PRESERVED: $path" >&2
          exit 1
        }
        ;;
    esac
  done < "$inventory_joined"

  # Round-12 F7: one `awk` over the whole captured inventory per ledger row. Derivation has
  # already put one row in the ledger per baseline path by this point, so on a 15k-path
  # baseline this was 15k processes each scanning 15k rows. One pass, first offender wins.
  # Round-12 F10: derivation has already folded baseline-paths.txt into the ledger by this point,
  # so a defect in the caller's BASELINE file surfaced here as a complaint about the LEDGER,
  # telling the caller to "list only manifest paths" for a row the renderer itself derived.
  # Target repo A obeyed the wrong file: it truncated baseline-paths.txt from twelve paths to
  # two, dropping ten pre-existing paths out of the report's disclosure. Name the file the path
  # actually came from.
  local_baseline_all="$renderer_tmp/baseline.all"
  [ -f "$local_baseline_all" ] || : > "$local_baseline_all"
  missing_from_inventory="$(awk -F '\t' -v inv="$captured_inventory" -v bf="$local_baseline_all" '
    FILENAME == inv { present[$2] = 1; next }
    FILENAME == bf { if ($0 != "") declared[$0] = 1; next }
    $2 == "" { next }
    $2 in present { next }
    { print (($2 in declared) ? "BASELINE" : "LEDGER") "\t" $2; exit }
  ' "$captured_inventory" "$local_baseline_all" "$tmp")"
  if [ -n "$missing_from_inventory" ]; then
    missing_source="${missing_from_inventory%%$'\t'*}"
    missing_path="${missing_from_inventory#*$'\t'}"
    if [ "$missing_source" = BASELINE ]; then
      echo "declared baseline path is absent from the pre-run inventory: $missing_path (this path came from the baseline paths file, not the ledger; every declared baseline path must be a path the pre-run inventory captured, or a directory form covering at least one such path)" >&2
    else
      echo "ledger path is absent from the pre-run inventory: $missing_path (tracked files the run did not modify belong in neither the inventory nor the ledger — list only manifest paths; untracked baseline paths are derived automatically)" >&2
    fi
    exit 1
  fi

  for doc in artifacts/architecture.md artifacts/infrastructure.md; do
    if awk -F '\t' -v path="$doc" '$1 == "CREATED" && $2 == path { found = 1 } END { exit !found }' "$tmp"; then
      test -f "$bootstrap_proof" || { echo "new documentation lacks docs-create invocation proof: $doc" >&2; exit 1; }
      grep -Fqx -- "$doc" "$bootstrap_proof" || { echo "docs-create did not write required document: $doc" >&2; exit 1; }
    fi
  done
fi

# Round-5: degraded-mode runs skip the hooked branch above, so derive the implicit
# PRESERVED baseline rows here too before enforcing them (idempotent in hooked mode).
derive_baseline_preserved_rows
# Round-12 F7: the third per-path baseline walk — one `awk` over the ledger per baseline path,
# against a ledger derivation has just grown to one row per baseline path. Same set membership,
# one pass, reporting the first offending path exactly as the per-path check did.
for baseline_file in ${baseline_files[@]+"${baseline_files[@]}"}; do
  test -f "$baseline_file"
done
if [ "${#baseline_files[@]}" -gt 0 ]; then
  # Round-12 F10: a declared directory form the captured inventory already covers is dropped by
  # derivation rather than given a row of its own, so it has no PRESERVED row to find here. It is
  # still fully accounted for — every file beneath it came from the guard's own capture and is
  # preserved individually. Exempt exactly that case, nothing wider.
  unpreserved_baseline="$(awk -F '\t' -v lf="$tmp" \
    -v cf="$renderer_tmp/baseline.inventory-cover" '
    FILENAME == cf { covered[$0] = 1; next }
    FILENAME == lf { if ($1 == "PRESERVED" && $2 != "") preserved[$2] = 1; next }
    $0 == "" { next }
    $0 in preserved { next }
    ($0 ~ /\/$/) && ($0 in covered) { next }
    { print $0; exit }
  ' "$renderer_tmp/baseline.inventory-cover" "$tmp" ${baseline_files[@]+"${baseline_files[@]}"})"
  if [ -n "$unpreserved_baseline" ]; then
    echo "baseline path is not preserved in ledger: $unpreserved_baseline (manifest paths must be listed explicitly; non-manifest baseline paths are derived automatically, so this failure means the path was listed under a non-PRESERVED status)" >&2
    exit 1
  fi
fi

architecture=artifacts/architecture.md
infrastructure=artifacts/infrastructure.md

# GAP-2 (e2e follow-up): the artifacts/*.md heading + Mermaid schema gate must hard-fail only
# for a document this run generated (CREATED or MERGED). A pre-existing user-owned doc may use
# a different heading scheme (e.g. numbered headings); blocking it here fires AFTER every file
# is written, leaving BLOCKED as the only exit. For a user-owned doc, record a warning surfaced
# in the completion report instead. Phase 0 records such docs as schema-exempt before any write.
doc_warnings="$renderer_tmp/doc-warnings"
: > "$doc_warnings"
doc_generated_this_run() {
  awk -F '\t' -v path="$1" '($1 == "CREATED" || $1 == "MERGED") && $2 == path { found = 1 } END { exit !found }' "$tmp"
}
if [ -f "$architecture" ]; then
  if doc_generated_this_run "$architecture"; then
    for heading in '## Overview' '## Technology Decisions' '## System Architecture' '## Component Deep Dives' '## Data Model'; do
      grep -Fqx "$heading" "$architecture" || { echo "architecture documentation lacks required section: $heading" >&2; exit 1; }
    done
    grep -Fq '```mermaid' "$architecture" || { echo "architecture documentation lacks a Mermaid component/data-flow diagram" >&2; exit 1; }
  else
    doc_missing=''
    for heading in '## Overview' '## Technology Decisions' '## System Architecture' '## Component Deep Dives' '## Data Model'; do
      grep -Fqx "$heading" "$architecture" || doc_missing="${doc_missing:+$doc_missing, }$heading"
    done
    grep -Fq '```mermaid' "$architecture" || doc_missing="${doc_missing:+$doc_missing, }a Mermaid diagram"
    [ -z "$doc_missing" ] ||
      printf '%s\n' "artifacts/architecture.md: missing $doc_missing; agents read this doc for context, so add them" >> "$doc_warnings"
  fi
fi
if [ -f "$infrastructure" ]; then
  if doc_generated_this_run "$infrastructure"; then
    for heading in '## Configuration' '## Security' '## Runbook'; do
      grep -Fqx "$heading" "$infrastructure" || { echo "infrastructure documentation lacks required section: $heading" >&2; exit 1; }
    done
  else
    doc_missing=''
    for heading in '## Configuration' '## Security' '## Runbook'; do
      grep -Fqx "$heading" "$infrastructure" || doc_missing="${doc_missing:+$doc_missing, }$heading"
    done
    [ -z "$doc_missing" ] ||
      printf '%s\n' "artifacts/infrastructure.md: missing $doc_missing; agents read this doc for context, so add them" >> "$doc_warnings"
  fi
fi
if [ -f CLAUDE.md ]; then
  for doc in artifacts/architecture.md artifacts/infrastructure.md; do
    grep -Fq "$doc" CLAUDE.md || { echo "CLAUDE.md does not reference generated document: $doc" >&2; exit 1; }
  done
fi
if awk -F '\t' '$2 == "CLAUDE.md" && $1 ~ /^(CREATED|MERGED|PRESERVED)$/ { found = 1 } END { exit !found }' "$tmp"; then
  prospective_claude="$workspace_tmp/prospective-claude.md"
  test -f "$prospective_claude" || {
    echo "prospective CLAUDE.md generated block is missing: $prospective_claude" >&2
    exit 1
  }
  [ ! -L "$prospective_claude" ] || {
    echo "prospective CLAUDE.md generated block must not be a symbolic link" >&2
    exit 1
  }
  # The generated block carries no comment scaffolding: it starts at the `## Generated Quick
  # Reference` heading and runs to the next top-level (`# `) heading or end of file. A rerun over
  # a file written by an older onboard must migrate its legacy comment markers away.
  ! LC_ALL=C grep -q 'GENERATED SECTION -- onboard' CLAUDE.md || {
    echo "CLAUDE.md still carries legacy onboard comment markers; the generated block is heading-delimited and must contain no marker scaffolding" >&2
    exit 1
  }
  [ "$(grep -Fxc '## Generated Quick Reference' CLAUDE.md || true)" -eq 1 ] || {
    echo "CLAUDE.md must contain exactly one onboard generated block (one '## Generated Quick Reference' heading)" >&2
    exit 1
  }
  [ "$(head -n 1 "$prospective_claude")" = '## Generated Quick Reference' ] &&
    ! LC_ALL=C grep -q 'GENERATED SECTION -- onboard' "$prospective_claude" &&
    ! LC_ALL=C grep -q '^# ' "$prospective_claude" || {
      echo "prospective CLAUDE.md content must contain only the generated block: first line '## Generated Quick Reference', no top-level headings, no comment markers" >&2
      exit 1
    }
  actual_claude_marker="$renderer_tmp/claude-generated-block.actual"
  awk '
    $0 == "## Generated Quick Reference" { in_block = 1 }
    in_block && /^# / { exit }
    in_block { print }
  ' CLAUDE.md > "$actual_claude_marker"
  cmp -s "$prospective_claude" "$actual_claude_marker" || {
    echo "CLAUDE.md generated block does not match freshly rendered prospective content" >&2
    exit 1
  }
  # Round-15 F32: cmp above proves the two surfaces agree, never WHICH one was made to agree.
  # A run that rewrites the prospective block to match an already-written CLAUDE.md produces a
  # byte-identical pair, so require the guard-attested write order instead: the last write to
  # the prospective block must precede the last write to CLAUDE.md. See record_write_order()
  # in completion-guard.sh. Two runs violated the prose-only rule before this was enforced.
  write_order_guard="$workspace_tmp/write-order.guard.txt"
  if [ -f "$write_order_guard" ] && [ ! -L "$write_order_guard" ]; then
    last_prospective_seq="$(awk -F '\t' \
      '$2 == ".launch-control-onboard/prospective-claude.md" { seq = $1 } END { print seq + 0 }' \
      "$write_order_guard")"
    last_claude_seq="$(awk -F '\t' '$2 == "CLAUDE.md" { seq = $1 } END { print seq + 0 }' \
      "$write_order_guard")"
    if [ "$last_claude_seq" -eq 0 ]; then
      # The idempotent path (F31): Phase 3 is read-only for CLAUDE.md, so a PRESERVED run
      # writes the prospective block and never touches CLAUDE.md. Nothing to invert.
      claude_md_provenance='guard-attested -- CLAUDE.md unwritten this run'
    elif [ "$last_prospective_seq" -eq 0 ]; then
      echo "CLAUDE.md was written but the guard recorded no prospective block write" >&2
      exit 1
    elif [ "$last_prospective_seq" -gt "$last_claude_seq" ]; then
      echo "prospective CLAUDE.md generated block was rewritten after CLAUDE.md was written, so the byte comparison cannot attest that the block was freshly rendered" >&2
      exit 1
    else
      claude_md_provenance='guard-attested -- prospective block written before CLAUDE.md'
    fi
  fi
  if repo_has_ci_config && ci_contract_has_standard_three; then
    if grep -Fqi '4 CI gates' "$actual_claude_marker"; then
      echo "CLAUDE.md generated block retains stale build-as-local-gate wording" >&2
      exit 1
    fi
    grep -Fqx '### Local validation commands' "$actual_claude_marker" || {
      echo "CLAUDE.md onboard marker lacks the canonical local validation heading" >&2
      exit 1
    }
    grep -Fqx '### CI-owned checks' "$actual_claude_marker" || {
      echo "CLAUDE.md onboard marker lacks the canonical CI-owned checks heading" >&2
      exit 1
    }
    while IFS= read -r contract_command; do
      [ -n "$contract_command" ] || continue
      grep -Fq "$contract_command" "$actual_claude_marker" || {
        echo "CLAUDE.md onboard marker omits derived local validation command: $contract_command" >&2
        exit 1
      }
    done < <(derive_ci_validation_contract)
    while IFS= read -r ci_command; do
      [ -n "$ci_command" ] || continue
      grep -Fq "$ci_command" "$actual_claude_marker" || {
        echo "CLAUDE.md onboard marker omits CI-owned command: $ci_command" >&2
        exit 1
      }
    done < <(derive_ci_owned_contract)
    awk '
      /`\/validate`/ && /[Ll]ocal/ { found = 1 }
      END { exit !found }
    ' "$actual_claude_marker" || {
      echo "CLAUDE.md /validate guidance does not describe the local-only gate set" >&2
      exit 1
    }
  fi
else
  claude_md_provenance='not applicable -- this run makes no CLAUDE.md claim'
fi
if [ -f .claude/skills/project-code-review/SKILL.md ]; then
  for guidance in CLAUDE.md .claude/skills/launch/SKILL.md; do
    test -f "$guidance" || { echo "renamed project-code-review guidance surface is missing: $guidance" >&2; exit 1; }
    # GAP-2 sibling. These are content rules for guidance THIS RUN authored. A repository that
    # already carries its own `.claude/` skills has every one of them PRESERVED (SKILL.md:78),
    # so the run cannot rewrite the surface it is being failed over: BLOCKED is the only exit
    # and no rerun can clear it. The defect is that the refusal is UNSATISFIABLE, not that it is
    # expensive -- this block runs well before the declared commands at :1721, so it never cost
    # a validation pass. Measured on rymonroe.com, whose preserved launch/SKILL.md names
    # neither spelling.
    if ! doc_generated_this_run "$guidance"; then
      if grep -Fq '`code-review`' "$guidance"; then
        printf '%s\n' "$guidance: still names the old skill \`code-review\`; rename it to \`project-code-review\`" >> "$doc_warnings"
      fi
      if ! grep -Fq '`project-code-review`' "$guidance"; then
        printf '%s\n' "$guidance: never names the \`project-code-review\` skill, so agents may not find it; add a line pointing to it" >> "$doc_warnings"
      fi
      continue
    fi
    # LC-002: a MERGED CLAUDE.md keeps the user's prose around the generated block, and refusing
    # over that prose is unsatisfiable the same way. A CREATED one is exactly the block, so any
    # text outside it is the run's own and is still judged.
    guidance_scope="$guidance"
    if [ "$guidance" = CLAUDE.md ] &&
      awk -F '\t' '$1 == "MERGED" && $2 == "CLAUDE.md" { found = 1 } END { exit !found }' "$tmp"; then
      guidance_scope="$actual_claude_marker"
    fi
    if grep -Fq '`code-review`' "$guidance_scope"; then
      echo "generated guidance contains stale exact skill name code-review: $guidance" >&2
      exit 1
    fi
    grep -Fq '`project-code-review`' "$guidance_scope" || {
      echo "generated guidance omits project-code-review: $guidance" >&2
      exit 1
    }
  done
fi
for doc in "$architecture" "$infrastructure"; do
  if [ -f "$doc" ] && awk -F '\t' -v path="$doc" '$1 == "CREATED" && $2 == path { found = 1 } END { exit !found }' "$tmp"; then
    grep -Fqi 'Generated snapshot' "$doc" || { echo "new documentation lacks generated snapshot wording: $doc" >&2; exit 1; }
    if grep -Fqi 'Existing snapshot' "$doc"; then
      echo "new documentation incorrectly labels itself as an existing snapshot: $doc" >&2
      exit 1
    fi
  fi
done

reviewer=.claude/agents/inspector.md
# GAP-2 sibling. The lens schema below describes a file onboarding generates, so it judges only
# a reviewer this run wrote. A PRESERVED, hand-authored reviewer is never judged: SKILL.md:78 pins
# every pre-existing `.claude/` agent PRESERVED, so the run may not write it, and the heading is
# the template's schema, not a requirement on the user's file. LC-044: it used to become a doc
# warning, which fired on target repo C's reviewer although that file carries its own data-handling, voice,
# Worker and UI checklists under other headings -- a finding with no action behind it.
if [ -f "$reviewer" ] && ! doc_generated_this_run "$reviewer"; then
  :
elif [ -e "$reviewer" ]; then
  test -f "$reviewer" || { echo "code reviewer is not a regular file: $reviewer" >&2; exit 1; }
  grep -Fqx '## Project-specific review lens' "$reviewer" || {
    echo "code reviewer lacks project-specific review lens: $reviewer" >&2
    exit 1
  }
  if grep -Fq 'DETECTED_REVIEW_LENS' "$reviewer"; then
    echo "code reviewer contains unresolved review lens: $reviewer" >&2
    exit 1
  fi
  review_lens_lines="$renderer_tmp/reviewer-lens.lines"
  awk '
    /^## Project-specific review lens$/ { in_lens = 1; next }
    in_lens && /^## / { exit }
    in_lens && /^- / { print }
  ' "$reviewer" > "$review_lens_lines"
  review_lens_bullets="$(wc -l < "$review_lens_lines" | tr -d ' ')"
  if [ "$review_lens_bullets" -lt 2 ]; then
    echo "code reviewer needs at least two evidence-backed review lens bullets: $reviewer" >&2
    exit 1
  fi
  while IFS= read -r bullet; do
    if ! printf '%s\n' "$bullet" | grep -Eq '^- .*Evidence: `[^`]+`\.$'; then
      echo "code reviewer lens bullets must end with exactly one evidence path: $reviewer" >&2
      # Round-11: the path alone does not say which bullet is wrong, and this guard fires
      # after every file is written — a rerun that cannot locate the offending bullet just
      # fires again. Name the bullet (truncated) and the required suffix.
      echo "offending bullet: \"${bullet:0:80}\"; every bullet must end with: Evidence: \`<path>\`." >&2
      exit 1
    fi
    evidence_path="$(printf '%s\n' "$bullet" | sed -E 's/^.*Evidence: `([^`]+)`\.$/\1/')"
    if [ "$evidence_path" != 'Phase 0 discovery' ]; then
      case "$evidence_path" in
        /*|../*|*/../*|*/..|./*|*/./*) echo "code reviewer evidence must be a canonical repo-relative path: $evidence_path" >&2; exit 1 ;;
      esac
      test -f "$evidence_path" || {
        echo "code reviewer evidence path does not exist: $evidence_path" >&2
        exit 1
      }
    fi
    concern="${bullet%% Evidence:*}"
    if [ "$evidence_path" = 'install/mcp.reference.json' ] &&
       ! printf '%s\n' "$concern" | grep -Eqi 'MCP|server|transport|catalog|authentication|authenticated'; then
      echo "code reviewer evidence path does not support the stated non-MCP concern: $evidence_path" >&2
      exit 1
    fi
  done < "$review_lens_lines"
fi

# Round-11: a /fix command whose allowed-tools line carries no Bash( entry cannot run any fix
# command — it is a stub documenting a capability the workspace does not have. When no
# formatter or lint-fix command is detected the honest ledger status is SKIPPED, so reject the
# stub structurally (on the permission line) rather than by matching its prose.
fix_command=.claude/commands/fix.md
if [ -f "$fix_command" ] && doc_generated_this_run "$fix_command" &&
   ! awk '/^allowed-tools:/ { if ($0 ~ /Bash\(/) found = 1; exit } END { exit !found }' "$fix_command"; then
  echo "generated /fix command cannot run a fix command and must be SKIPPED instead of created: $fix_command" >&2
  exit 1
fi

# Same scoping as the reviewer above: these three rules check the shape of the Launch template
# THIS pack renders (stale gate wording, model-insert annotation placement). A pre-existing
# user-owned launch skill is PRESERVED and never followed that template, so failing it here
# blocks a run over a file it did not write and may not rewrite.
for launch in .claude/skills/launch/SKILL.md .claude/skills/launch/references/*.md; do
  [ -f "$launch" ] && doc_generated_this_run "$launch" || continue
  if repo_has_ci_config && ci_contract_has_standard_three && grep -Fqi '4 CI gates' "$launch"; then
    echo "Launch retains stale build-as-local-gate wording: $launch" >&2
    exit 1
  fi
  if grep -Eq -- '-->[[:space:]]+- ' "$launch"; then
    echo "Launch model-insert annotations and bullets must be on separate lines: $launch" >&2
    exit 1
  fi
  if ! awk '
    /<!-- inferred from / {
      if ($0 !~ /^<!-- inferred from [^>]+ -->$/) failed = 1
      if ((getline next_line) <= 0 || next_line !~ /^- /) failed = 1
    }
    END { exit failed }
  ' "$launch"; then
    echo "Launch model-insert annotation must be followed by one Markdown bullet: $launch" >&2
    exit 1
  fi
done

# Launch Control dogfood runs carry a mixed MCP reference catalog. Both generated
# snapshots must independently preserve its transport/auth facts and the workbench
# ownership boundary before a completion report can be rendered.
if [ "${LAUNCH_CONTROL_SELF_TEST:-0}" = "1" ] &&
   [ -f install/mcp.reference.json ] &&
   grep -Fq '"github"' install/mcp.reference.json &&
   grep -Fq '"atlassian"' install/mcp.reference.json &&
   grep -Fq '"shadcn"' install/mcp.reference.json &&
   grep -Fq '"chrome-devtools"' install/mcp.reference.json; then
  for doc in artifacts/architecture.md artifacts/infrastructure.md; do
    test -f "$doc" || { echo "required documentation path does not exist: $doc" >&2; exit 1; }
    for name in github atlassian shadcn chrome-devtools; do
      grep -Fqi "$name" "$doc" || { echo "documentation omits MCP category fact: $doc: $name" >&2; exit 1; }
    done
    grep -Eqi 'authenticated remote' "$doc" || { echo "documentation omits remote MCP auth fact: $doc" >&2; exit 1; }
    grep -Eqi 'local stdio' "$doc" || { echo "documentation omits local stdio MCP fact: $doc" >&2; exit 1; }
    grep -Fq 'workbench/<TICKET>/<stage>/' "$doc" || { echo "documentation omits workbench path ownership: $doc" >&2; exit 1; }
    grep -Eqi 'CRISPY' "$doc" || { echo "documentation omits CRISPY workbench owner: $doc" >&2; exit 1; }
    grep -Eqi '(/onboard.*(does not|never).*create|not by /onboard|not.*by.*`?/onboard)' "$doc" || {
      echo "documentation attributes workbench creation incorrectly: $doc" >&2
      exit 1
    }
    grep -Fqi '.disarmed' "$doc" || { echo "documentation omits successful lifecycle disarm: $doc" >&2; exit 1; }
    grep -Eqi 're-arm|re-arms' "$doc" || { echo "documentation omits later onboard re-arm: $doc" >&2; exit 1; }
  done
  for variant in .env.qa .env.preview .env.backup; do
    grep -Fq "$variant" artifacts/infrastructure.md || {
      echo "infrastructure documentation omits arbitrary env protection: $variant" >&2
      exit 1
    }
  done
  grep -Fq 'Read(/.env*)' artifacts/infrastructure.md || {
    echo "infrastructure documentation omits broad native env deny" >&2
    exit 1
  }
  grep -Eqi 'native Read/Glob/Grep.*blocked|blocked through native Read/Glob/Grep' artifacts/infrastructure.md || {
    echo "infrastructure documentation omits stricter native safe-example behavior" >&2
    exit 1
  }
  for doc in CLAUDE.md artifacts/architecture.md artifacts/infrastructure.md; do
    if grep -Eqi 'POSIX shell|written in POSIX' "$doc"; then
      echo "Launch Control documentation incorrectly claims POSIX shell portability: $doc" >&2
      exit 1
    fi
  done
fi

# Recorded gates (LC-037). The caller passes only the gate names the project documents; this
# process checks that each is safe to record and reports them. Nothing here is executed:
# onboarding never runs a project's own commands, so there is no exit status to derive and no
# result a caller could forge.
validation_commands_file="$(
  normalize_control_file 'validation commands' "$validation_commands_file"
)"
validation_commands_snapshot="$renderer_tmp/validation.commands"
cp "$validation_commands_file" "$validation_commands_snapshot"

if ! awk -F '\t' '
  $0 == "" { next }
  NF != 1 || $0 ~ /^[[:space:]]/ || $0 ~ /[[:space:]]$/ {
    print "invalid validation command: " $0 > "/dev/stderr"
    failed = 1
    next
  }
  seen[$0]++ { print "duplicate validation command: " $0 > "/dev/stderr"; failed = 1 }
  END { exit failed }
' "$validation_commands_snapshot"; then
  exit 1
fi

validation_total="$(grep -c '[^[:space:]]' "$validation_commands_snapshot" || true)"
# LC-037: a project with no documented gates is onboarded as it is; the report says none were recorded.

# Derive the gates the repository itself declares (CI configuration; package scripts when there is
# no CI), independently of the caller-authored file. The derived set is used only to disclose gates
# the recorded set omits, under `Undeclared gates`; it is never enforced.
derive_expected_validation_contract "$renderer_tmp"
# LC-037: a recorded set that differs from the one derived from this repository's CI is a note for
# the person onboarding, never a block: the derived gates a record omits are added to `Undeclared
# gates` below. Onboarding has no say over how the project is tested, so it neither enforces an
# exact set nor refuses to finish over one.

# Round-13 F17: runs in EVERY mode, including the one above where `expected_validation` was empty
# and nothing was checked at all. See derive_script_gate_candidates.
undeclared_gates_file="$renderer_tmp/undeclared-gates"
: > "$undeclared_gates_file"
declared_scripts_file="$renderer_tmp/declared-scripts"
: > "$declared_scripts_file"
# LC-055: a gate the documentation names but the record omits stays disclosed like any other.
# Filtering it out of the list would hide exactly the omission this section exists to show.
while IFS= read -r declared_command; do
  [ -n "$declared_command" ] || continue
  declared_script_name "$declared_command" >> "$declared_scripts_file"
done < "$validation_commands_snapshot"
# LC-049: a recorded bare command that CI runs under a working directory also clears that
# directory's nested key. Only CI evidence counts, so a root `npm run test` still never clears
# `web/test`.
ci_scoped_keys_file="$renderer_tmp/ci-scoped-keys"
: > "$ci_scoped_keys_file"
while IFS=$'\t' read -r scoped_dir scoped_command; do
  scoped_dir="${scoped_dir#./}"
  scoped_dir="${scoped_dir%/}"
  case "$scoped_dir" in ''|.|*[!A-Za-z0-9./_-]*|/*|*..*) continue ;; esac
  LC_ALL=C grep -Fqx -- "$scoped_command" "$validation_commands_snapshot" || continue
  scoped_script="$(declared_script_name "$scoped_command")"
  [ -n "$scoped_script" ] || continue
  printf '%s/%s\n' "$scoped_dir" "$scoped_script" >> "$ci_scoped_keys_file"
done < <(ci_scoped_commands)
while IFS=$'\t' read -r candidate_script candidate_command; do
  [ -n "$candidate_script" ] || continue
  if LC_ALL=C grep -Fqx -- "$candidate_script" "$declared_scripts_file"; then
    continue
  fi
  printf '%s\t%s\n' "$candidate_command" 'package.json' \
    >> "$undeclared_gates_file"
done < <(derive_script_gate_candidates)
# Round-13 F18: the nested manifests, keyed on `<dir>/<script>` and carrying their own reason
# text, since a nested gate is disclosed either as a declarable `--prefix` spelling or as a
# hand-run command whose directory the grammar cannot express.
while IFS=$'\t' read -r candidate_key candidate_command candidate_reason; do
  [ -n "$candidate_key" ] || continue
  if LC_ALL=C grep -Fqx -- "$candidate_key" "$declared_scripts_file" \
    || LC_ALL=C grep -Fqx -- "$candidate_key" "$ci_scoped_keys_file"; then
    continue
  fi
  printf '%s\t%s\n' "$candidate_command" "$candidate_reason" >> "$undeclared_gates_file"
done < <(derive_nested_script_gate_candidates)
if [ -n "${expected_validation:-}" ]; then
  while IFS= read -r expected_command; do
    [ -n "$expected_command" ] || continue
    if LC_ALL=C grep -Fqx -- "$expected_command" "$validation_commands_snapshot"; then
      continue
    fi
    printf '%s\t%s\n' "$expected_command" 'CI configuration' \
      >> "$undeclared_gates_file"
  done <<< "$expected_validation"
fi
awk -F '\t' '!seen[$1]++' "$undeclared_gates_file" > "$renderer_tmp/undeclared-gates.dedup"
mv "$renderer_tmp/undeclared-gates.dedup" "$undeclared_gates_file"

# The finalizer runs repository-declared validation through Bash only after rejecting
# shell composition and destructive/external operations. This mirrors the skill-scoped
# unattended policy so the commands file cannot turn the allowed finalizer invocation
# into an arbitrary shell escape.
# BUG-1: anchor the workspace-change comparison against a run-start baseline instead of a
# per-invocation snapshot. A command that mutates a tracked file once then leaves it dirty
# (e.g. `next build` rewriting next-env.d.ts) would otherwise match its own before/after
# snapshot on retry and launder the guard. The anchor excludes the run's own control
# directory and is captured once, then reused by every retry of the same run.
worktree_status() {
  # Round-19, deliberately NOT silenced: a live target repo A report carried a bare
  # `.env: Operation not permitted` line above `=== Workspace Setup Complete ===`, and this call
  # was the prime suspect because it is the renderer's only `git status` without a stderr
  # redirect. It is not the producer. Probed directly: `git status` on a tracked path that is
  # modified-and-unreadable prints the ordinary ` M <path>` row and NOTHING on stderr, because a
  # size change alone marks it dirty without an open; when git genuinely cannot stat a path it
  # says `fatal: unable to stat '<path>': ...`, a different shape entirely. Do not "fix" this
  # with `2>/dev/null` on that theory -- swallowing stderr here would hide a real git failure,
  # and an empty status reads as "nothing changed" to the delta comparison below.
  #
  # Round-21: the search is now CLOSED against this renderer, and the line is not ours. Two facts
  # settle it. First, the stray line is the first line of the render's OWN tool result, not a
  # neighbouring command's -- an earlier reading concatenated tool results without separators and
  # could not tell those apart. Second, the exact denial condition was reproduced here (a
  # sandbox-denied path, where `stat` fails too, not merely a mode-000 path where it succeeds) and
  # every command this script runs against such a path PREFIXES ITS OWN NAME:
  #   cat/md5/cksum/du/ls/shasum -> `<tool>: <path>: Operation not permitted`
  #   git hash-object, single-path AND --stdin-paths -> `fatal: could not open '<path>' ...`
  #   rg -> `rg: <path>: ... (os error 1)`;  file, find, and shell redirection likewise
  # No spelling reachable from this script produces the bare `<path>: <strerror>` form, so no edit
  # to this file can remove it. Validation commands are ruled out separately: their streams are
  # captured to files at the `) >"$command_stdout" 2>"$command_stderr"` redirect, and children
  # inherit that. Do not reopen this by re-probing the renderer -- identifying the producer needs
  # a probe of the layer OUTSIDE it, and that layer emitting a line above a machine-derived report
  # is not a defect this pack can fix.
  git status --short --untracked-files=all -- . ':(exclude).launch-control-onboard/**' | LC_ALL=C sort
}

run_start_status="$workspace_tmp/worktree-status.start"
run_start_fingerprints="$workspace_tmp/worktree-status.start.fingerprints"
# Paths whose git-decoded name holds a newline. Written by whichever capture ran -- the guard's
# `capture_run_anchor` or the lazy one below -- and always in git's C-quoted spelling, the one form
# that is single-line by construction. Disclosed, never fingerprinted.
run_start_unrepresentable="$workspace_tmp/worktree-status.start.unrepresentable"
# BUG-1: the status-string anchor cannot see a validation command that rewrites an
# already-dirty path — a tracked file dirty at run start shows the same ` M path` line
# before and after the rewrite, so the status comparison passes. Alongside the anchor,
# fingerprint every path present at run start (type + git-hash + executable bit, symlink-safe
# via current_path_state). Both files are captured together, once, and reused by every retry
# of the same run; a post-validation mismatch on either blocks the render.
capture_run_start_fingerprints() {
  local status_record fingerprint_path
  local paths="$renderer_tmp/run-start.paths"
  : > "$paths"
  while IFS= read -r status_record; do
    [ -n "$status_record" ] || continue
    # Round-13 F16: decode git's C-quoting before this reaches current_path_state, or a spaced
    # path fingerprints as `absent` here and again after validation, and a rewrite of it never
    # produces a delta.
    unquote_git_path "${status_record:3}"
    fingerprint_path="$unquoted_path"
    [ -n "$fingerprint_path" ] || continue
    # The guard's twin carries the same exclusion for the same reason: a decoded path holding a
    # newline cannot be one record in a line-oriented file. Here it fails silently rather than
    # loudly -- the fragments fingerprint `absent` at run start AND after validation, so no delta
    # is ever produced and a rewrite of the real path is invisible, which is exactly the blindness
    # F16 closed for spaced paths. Route it to the same disclosure instead of pretending.
    if [ "$fingerprint_path" != "${fingerprint_path%%$'\n'*}" ]; then
      printf '%s\n' "${status_record:3}" >> "$run_start_unrepresentable"
      continue
    fi
    printf '%s\n' "$fingerprint_path" >> "$paths"
  done < "$run_start_status"
  fingerprint_paths "$paths" "$run_start_fingerprints"
}
# Round-24: a `.partial` anchor file means the completion guard's run-start capture was KILLED
# mid-flight (its 600-second hook ceiling, reached on any repository near 14k status paths).
# Refuse rather than fall through to the lazy capture below: the guard grants the write-gating
# attestation immediately before that capture, so re-anchoring here would snapshot a tree this
# run has already written to and every later gate would then compare the run against its own
# output. The report's `every path above was captured and verified` claim is not recoverable
# once the pre-write moment is gone, so no report is the only honest outcome.
if [ -e "$run_start_status.partial" ] || [ -e "$run_start_fingerprints.partial" ]; then
  echo "run-start workspace anchor is incomplete" >&2
  echo "the completion guard's pre-write capture was interrupted, so this run cannot account for the pre-existing paths it never fingerprinted:" >&2
  for anchor_partial in "$run_start_status.partial" "$run_start_fingerprints.partial"; do
    [ ! -e "$anchor_partial" ] || printf '%s\n' "  $anchor_partial" >&2
  done
  echo "remove .launch-control-onboard/ and rerun /onboard" >&2
  exit 1
fi
if [ ! -f "$run_start_status" ] || [ -L "$run_start_status" ] ||
   [ ! -f "$run_start_fingerprints" ] || [ -L "$run_start_fingerprints" ]; then
  rm -f "$run_start_status" "$run_start_fingerprints" "$run_start_unrepresentable"
  : > "$run_start_unrepresentable"
  worktree_status > "$run_start_status"
  capture_run_start_fingerprints
fi
# Whichever capture produced it, an unrepresentable path is disclosed rather than verified. The two
# guard-written sidecars are read the same way: the run-start anchor's, and the baseline capture's,
# which fires at the first Write and feeds `Untouched pre-existing`. Both are already in git's
# quoted spelling, and the group below `sort -u`s them, so a path both captures saw prints once.
baseline_unrepresentable="$workspace_tmp/baseline-paths.unrepresentable"
for unrepresentable_sidecar in "$run_start_unrepresentable" "$baseline_unrepresentable"; do
  [ -f "$unrepresentable_sidecar" ] && [ ! -L "$unrepresentable_sidecar" ] || continue
  while IFS= read -r unrepresentable_record; do
    [ -n "$unrepresentable_record" ] || continue
    printf '%s\n' "$unrepresentable_record" >> "$unrepresentable_file"
  done < "$unrepresentable_sidecar"
done

# Round-12: the machine-minted `Next:` line for a blocked report. Lives in the workspace
# control directory (not the renderer's scratch) so the Stop guard can read it after this
# process exits and hold the emitted protocol to the remedy the machine actually derived.
blocked_next_file="$workspace_tmp/blocked-next"
rm -f "$blocked_next_file"
# Round-12 F13: this was defined inside the per-command validation loop, so the failure classes
# outside that loop — notably a command that mutates the workspace — could not mint a recovery
# line, and their blocked reports fell back to model prose with only its shape verified. Same gap
# F4 closed for the sandbox classes. Define it once, at the scope every caller shares.
record_blocked_next() {
  printf '%s\n' "$1" > "$blocked_next_file"
  echo "blocked-next: $1" >&2
}
# LC-037: a gate the repository's documentation names but the record omits is disclosed under
# `Undeclared gates` and no longer blocks the run.

# The run-start status + fingerprint gates below exclude the run's own declared writes (every
# CREATED or MERGED ledger path), because under a checkpoint anchor those paths legitimately appear
# as new or changed versus the pre-write anchor. That exclusion must not blind the render to a managed
# path rewritten after onboarding wrote it, so capture a per-invocation fingerprint of every managed
# path as it stands now and re-check it before the report is emitted.
managed_written="$renderer_tmp/managed-written.paths"
awk -F '\t' '$1 == "CREATED" || $1 == "MERGED" { print $2 }' "$tmp" | LC_ALL=C sort -u > "$managed_written"
managed_start_fingerprints="$renderer_tmp/managed-start.fingerprints"
: > "$managed_start_fingerprints"
while IFS= read -r managed_path; do
  [ -n "$managed_path" ] || continue
  IFS=$'\t' read -r m_type m_hash m_exec < <(current_path_state "$managed_path")
  printf '%s\t%s\t%s\t%s\n' "$managed_path" "$m_type" "$m_hash" "$m_exec" >> "$managed_start_fingerprints"
done < "$managed_written"

mark_render_stage 'run accounting (ledger, anchor, baseline, gate derivation)'
# LC-037: onboarding never runs a project's own commands. This pass only checks that each recorded
# gate is safe to record, because every recorded gate becomes an exact `Bash(<command>)` allow rule
# for the agents onboarding sets up: no shell composition, no destructive or external operation, only
# supported forms, and a `--prefix` directory confined to the repository. Nothing is executed.
validation_index=0
while IFS= read -r command; do
  [ -n "$command" ] || continue
  validation_index=$((validation_index + 1))
  # Match literal shell syntax; these patterns must not expand in the finalizer. This mirrors
  # unattended-policy.sh split_simple_shell_words strictness: reject a single `&` and any `$`
  # expansion (BUG-11), not only the doubled or command-substitution forms.
  # shellcheck disable=SC2016
  case "$command" in
    *$'\n'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$'*)
      echo "validation command contains forbidden shell composition: $command" >&2
      exit 1
      ;;
  esac
  case " $command " in
    *' sudo '*|*' rm '*|*' rmdir '*|*' mv '*|*' cp '*|*' curl '*|*' wget '*|*' ssh '*|*' scp '*|*' rsync '*|*' git add '*|*' git commit '*|*' git push '*|*' git pull '*|*' git checkout '*|*' git switch '*|*' git reset '*|*' git clean '*|*' gh pr '*|*' npm install '*|*' pnpm install '*|*' yarn install '*|*' brew '*|*' apt-get '*)
      echo "validation command is not read-only or repository-local: $command" >&2
      exit 1
      ;;
  esac
  # BUG-5: accept the bare script forms repos document verbatim (pnpm lint, pnpm typecheck,
  # pnpm test:run and the yarn/bun equivalents), where the script is a single token. The
  # existing `pnpm run *`/`pnpm test` forms still match; this only widens to bare scripts.
  # GAP-3: a single-token package-manager builtin is not a repo-declared script — reject the
  # known builtins so `pnpm publish`/`pnpm add`/`yarn upgrade` can never masquerade as a bare
  # validation script and slip through on a generated permission.
  bare_script_form=false
  case "$command" in
    pnpm\ *|yarn\ *|bun\ *)
      bare_script="${command#* }"
      case "$bare_script" in
        ''|*[!A-Za-z0-9:_-]*) ;;
        install|add|remove|publish|upgrade|update|dlx|exec|create|link|init|import|audit|outdated|config) ;;
        *) bare_script_form=true ;;
      esac
      ;;
  esac
  # Round-13 F18: `Undeclared gates` names nested package scripts as `npm --prefix <dir> run
  # <script>`, and a disclosure the reader cannot act on is a trap — declaring the named spelling
  # has to be accepted here or the report would send every monorepo into a blocked run. The
  # directory is confined to a repository-relative path holding a manifest, so this widens the
  # runnable set by one package directory the repository itself declares, and by nothing else.
  nested_prefix_form=false
  case "$command" in
    npm\ --prefix\ *\ run\ *)
      nested_prefix_rest="${command#npm --prefix }"
      nested_prefix_dir="${nested_prefix_rest%% *}"
      case "$nested_prefix_dir" in
        ''|*[!A-Za-z0-9./_-]*|/*|*..*) ;;
        *) [ -f "$nested_prefix_dir/package.json" ] && nested_prefix_form=true ;;
      esac
      if [ "$nested_prefix_form" = false ]; then
        echo "validation command names a --prefix directory that is not a repository-relative package: $command" >&2
        exit 1
      fi
      ;;
  esac
  if [ "$bare_script_form" = false ] && [ "$nested_prefix_form" = false ]; then
    case "$command" in
      npm\ run\ *|npm\ test|pnpm\ run\ *|pnpm\ test|yarn\ run\ *|yarn\ test|bun\ run\ *|bun\ test|npx\ tsc|npx\ tsc\ *|cargo\ test*|cargo\ check*|cargo\ clippy*|go\ test*|go\ vet*|make|make\ *|./gradlew\ *|mvn\ *|pytest|pytest\ *|flake8|flake8\ *|mypy|mypy\ *|ruff\ *|pylint\ *|uv\ run\ *|poetry\ run\ *|bundle\ exec\ *|bash\ ./*|./*) ;;
      *)
        echo "validation command is outside the supported repository validation forms: $command" >&2
        exit 1
        ;;
    esac
  fi
done < "$validation_commands_snapshot"

# F26 invariant. `validation_total` is counted from the snapshot file (grep -c) while the loop
# above iterates that same file, so the two can disagree — and when they do, every command the
# loop never reached is silently counted as passed. That is exactly how a run rendered
# `passed (3/3)` over a gate that exits 1: a gate inherited the loop's stdin and swallowed the
# remaining lines. The `</dev/null` on the execution line fixes that mechanism; this assertion
# closes the class, because any future divergence between "counted" and "executed" -- whatever
# causes it -- is a false green and must block instead of render.
if [ "$validation_index" -ne "$validation_total" ]; then
  printf 'BLOCKED: renderer checked %s of %s recorded gates; the report would misstate how many were recorded.\n' \
    "$validation_index" "$validation_total" >&2
  printf 'Re-run onboarding. If this repeats, the recorded gate list is being modified while it is read.\n' >&2
  exit 1
fi

# GAP-1: the run's own declared writes — every CREATED or MERGED ledger path (`managed_written`,
# built at renderer start) — legitimately appear as new or changed versus the run-start anchor,
# so they are excluded from the two run-start gates below. Under a checkpoint anchor that is
# required (the anchor predates the writes); under a lazy anchor it is harmless (the writes are
# already in the anchor). PRESERVED and SKIPPED paths are declared *unchanged*, so any drift on
# them — a pre-render manual validation rewriting a tracked non-manifest file the ledger never
# managed, e.g. next-env.d.ts — still blocks. The excluded managed class is not left unguarded:
# the per-invocation managed-path check further below re-verifies it against its renderer-start
# state, so a validation command that rewrites a generated file is still caught under both modes.

# BUG-1: compare the final worktree against the run-start anchor. Any path the run introduced
# is an extra status record versus the Phase 0 baseline and blocks the render honestly, rather
# than laundering a clean report on a retry whose per-invocation before/after happened to match.
worktree_after="$renderer_tmp/worktree-status.after"
worktree_status > "$worktree_after"
if ! cmp -s "$run_start_status" "$worktree_after"; then
  # Round-12 F14: blocking on ANY worktree change was too blunt. A declared gate that emits fresh
  # artifacts into the repository is ordinary — target repo A's pytest suite writes card_*.png
  # into an already-untracked output tree by design — and refusing that makes onboarding impossible
  # for a large class of normal repositories. Onboarding did not choose to write; it ran the command
  # the repository declares. So split the comparison by direction and by porcelain status:
  #   * a record that DISAPPEARED since run start -> blocks (a reverted or hidden path)
  #   * a record that APPEARED as anything other than untracked -> blocks (tracked file touched)
  #   * a NEW untracked file -> generated output, disclosed rather than blocked
  # The exception is the generated workspace itself: an undeclared write under `.claude/` or
  # `artifacts/` is not repository output, it is contamination of what this run is shipping, and it
  # still blocks. Overwriting an already-dirty path is unaffected — the fingerprint gate below
  # catches that, and it remains a hard block, because that is someone's data.
  worktree_delta="$renderer_tmp/worktree-status.delta"
  worktree_appeared="$renderer_tmp/worktree-status.appeared"
  worktree_vanished="$renderer_tmp/worktree-status.vanished"
  worktree_delta_raw="$renderer_tmp/worktree-status.delta.raw"
  worktree_output_raw="$renderer_tmp/worktree-status.output.raw"
  LC_ALL=C comm -13 "$run_start_status" "$worktree_after" > "$worktree_appeared"
  LC_ALL=C comm -23 "$run_start_status" "$worktree_after" > "$worktree_vanished"
  : > "$worktree_delta_raw"
  : > "$worktree_output_raw"
  # Round-13 F16: decode git's C-quoting here too. These paths are compared against
  # `managed_written` (ledger-derived, never quoted) and passed to `path_read_denied`, so a quoted
  # spelling both fails the set subtraction and mis-stats -- and it is what reached the report,
  # where the collapse then split `".venv` off as its own top-level directory.
  # Same exclusion as the run-start capture, for the same reason: `$worktree_delta_raw` is
  # line-oriented and is `comm`-ed against `$managed_written`, so a decoded newline path would
  # arrive as several fragments and be reported as several run-introduced changes. A path that
  # genuinely appeared or vanished still needs saying, so it goes to the disclosure channel in
  # git's quoted spelling instead of into a comparison that cannot hold it.
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    unquote_git_path "${record:3}"
    if [ "$unquoted_path" != "${unquoted_path%%$'\n'*}" ]; then
      printf '%s\n' "${record:3}" >> "$unrepresentable_file"
      continue
    fi
    printf '%s\n' "$unquoted_path" >> "$worktree_delta_raw"
  done < "$worktree_vanished"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    unquote_git_path "${record:3}"
    appeared_path="$unquoted_path"
    if [ "$appeared_path" != "${appeared_path%%$'\n'*}" ]; then
      printf '%s\n' "${record:3}" >> "$unrepresentable_file"
      continue
    fi
    case "$record" in
      '?? '*)
        case "$appeared_path" in
          # Harness-owned local files, excluded before the `.claude/` contamination rule can
          # see them. Claude Code writes settings.local.json when the USER answers a
          # permission prompt mid-run; onboarding never writes it and never ships it -- this
          # file's own contract says `.claude/settings.local.json` is "Leave untouched", and
          # the policy never edits it. Treating it as contamination of the shipped workspace
          # meant a user answering a prompt killed the render.
          #
          # Normal runs escaped only because Phase 5a appends these exact names to
          # .gitignore, hiding them from `git status` before the render compares. That made
          # the exclusion an accident of ordering rather than a stated rule, and it does not
          # hold where the side effect is absent: `--launch-control` is forbidden to modify
          # .gitignore, so maintenance on a repository without those rules blocked on a
          # prompt the user had every right to answer. Assert the ownership here instead.
          #
          # Neither blocked nor counted under `New untracked paths`: no gate produced it, so
          # filing it there would be a false statement about the repository's own commands.
          # The `worktree-accounting:` line already discloses that such paths are unreported.
          .claude/settings.local.json|.claude/*.local.*|CLAUDE.local.md) continue ;;
          .claude/*|artifacts/*) ;;
          *) printf '%s\n' "$appeared_path" >> "$worktree_output_raw"; continue ;;
        esac
        ;;
    esac
    printf '%s\n' "$appeared_path" >> "$worktree_delta_raw"
  done < "$worktree_appeared"
  LC_ALL=C sort -u "$worktree_delta_raw" | LC_ALL=C comm -23 - "$managed_written" > "$worktree_delta"
  # A declared managed write is never repository output either; it is this run's own doing.
  LC_ALL=C sort -u "$worktree_output_raw" | LC_ALL=C comm -23 - "$managed_written" \
    >> "$validation_output_file"
  # Round-12 F12: `git status --short` OMITS a tracked path it cannot read (and reports the denial
  # on stderr), so a path that merely became unreadable during the run loses its porcelain entry
  # exactly as a reverted path would, and this comparison charged the disappearance to the
  # validation command. Observed on target repo A: the `denyRead: ./.env*` this run generates
  # took effect mid-run, so the run's own secret boundary hid a dirty tracked `.env` from git and
  # the renderer listed `.env` under "run-introduced changes" though its content never changed.
  # Only the real writes alongside it kept that block from being a false accusation. An unreadable
  # path is unverifiable, not modified: route it to the same disclosure the preserve-hash check
  # already uses for a protected path whose digest cannot be computed.
  if [ -s "$worktree_delta" ]; then
    worktree_delta_verifiable="$renderer_tmp/worktree-status.delta.verifiable"
    : > "$worktree_delta_verifiable"
    while IFS= read -r delta_path; do
      [ -n "$delta_path" ] || continue
      if path_read_denied "$delta_path"; then
        printf '%s\n' "$delta_path" >> "$protected_unverified_file"
        continue
      fi
      printf '%s\n' "$delta_path" >> "$worktree_delta_verifiable"
    done < "$worktree_delta"
    mv "$worktree_delta_verifiable" "$worktree_delta"
  fi
  if [ -s "$worktree_delta" ]; then
    echo "the workspace changed outside the declared writes of this run" >&2
    echo "run-introduced changes (HEAD-vs-worktree delta since run start):" >&2
    cat "$worktree_delta" >&2
    record_blocked_next 'a process other than onboarding (another session, an editor, a watcher) changed these paths during the run; let it finish, or add legitimate generated output to .gitignore, then rerun /onboard'
    exit 1
  fi
fi

# BUG-1: the status comparison above only sees paths that appear or disappear. Compare the
# content fingerprints too, so a validation command that rewrote an already-dirty path
# whose porcelain status line is unchanged (a ` M path` entry stays ` M path`) still blocks
# the render. Any type, content, or executable-bit drift since run start is a run-introduced
# change and fails honestly rather than laundering a false "untouched" claim. A path the run
# declared CREATED/MERGED is an intended write (relevant only under a checkpoint anchor) and is
# excluded exactly as above.
if [ -f "$run_start_fingerprints" ] && [ ! -L "$run_start_fingerprints" ]; then
  fingerprint_delta="$renderer_tmp/worktree-status.fingerprint-delta"
  : > "$fingerprint_delta"
  # Round-12: this loop used to spend two processes per path — one `grep` to test the managed
  # exclusion and one `current_path_state` to re-fingerprint — so a 14.5k-path baseline cost
  # ~29k processes here alone. Same comparison, same outcomes, four processes: filter the
  # managed paths in one awk pass, batch the re-fingerprint, then compare both files in one
  # more pass. `protected` still routes to disclosure rather than counting as a change.
  fp_candidates="$renderer_tmp/fingerprint.candidates"
  fp_now="$renderer_tmp/fingerprint.now"
  # Key the two-file passes on FILENAME, never on NR == FNR: an empty first file makes
  # NR == FNR true for the SECOND file too, which silently loaded every candidate into the
  # exclusion set and let a rewritten dirty path through.
  awk -F '\t' -v mf="$managed_written" \
    'FILENAME == mf { managed[$0] = 1; next } $1 != "" && !($1 in managed) { print $1 }' \
    "$managed_written" "$run_start_fingerprints" > "$fp_candidates"
  fingerprint_paths "$fp_candidates" "$fp_now"
  awk -F '\t' -v protfile="$protected_unverified_file" -v deltafile="$fingerprint_delta" \
      -v nowfile="$fp_now" '
    FILENAME == nowfile { now_type[$1] = $2; now_hash[$1] = $3; now_exec[$1] = $4; seen[$1] = 1; next }
    $1 == "" || !($1 in seen) { next }
    {
      if (now_type[$1] == "protected") { print $1 >> protfile; next }
      if (now_type[$1] != $2 || now_hash[$1] != $3 || now_exec[$1] != $4) print $1 >> deltafile
    }
  ' "$fp_now" "$run_start_fingerprints"
  if [ -s "$fingerprint_delta" ]; then
    echo "the workspace changed outside the declared writes of this run" >&2
    echo "run-introduced changes (content of already-dirty paths since run start):" >&2
    LC_ALL=C sort -u "$fingerprint_delta" >&2
    record_blocked_next 'a process other than onboarding (another session, an editor, a watcher) changed these paths during the run; let it finish, or add legitimate generated output to .gitignore, then rerun /onboard'
    exit 1
  fi
fi

mark_render_stage 'worktree verification (worktree delta, fingerprint delta)'
# GAP-1 (review follow-up): re-verify the managed (CREATED/MERGED) paths excluded from the two
# run-start gates against the per-invocation fingerprint captured at renderer start (already
# post-write). A validation command that rewrites a path onboarding declared it manages — e.g.
# appends to a generated file — drifts from that start state and still blocks the render, closing
# the protection the run-start exclusion would otherwise remove under both anchor modes.
managed_fingerprint_delta="$renderer_tmp/managed.fingerprint-delta"
: > "$managed_fingerprint_delta"
while IFS=$'\t' read -r mfp_path mfp_type mfp_hash mfp_exec; do
  [ -n "$mfp_path" ] || continue
  IFS=$'\t' read -r mnow_type mnow_hash mnow_exec < <(current_path_state "$mfp_path")
  if [ "$mnow_type" != "$mfp_type" ] || [ "$mnow_hash" != "$mfp_hash" ] || [ "$mnow_exec" != "$mfp_exec" ]; then
    printf '%s\n' "$mfp_path" >> "$managed_fingerprint_delta"
  fi
done < "$managed_start_fingerprints"
if [ -s "$managed_fingerprint_delta" ]; then
  echo "the workspace changed outside the declared writes of this run" >&2
  echo "run-introduced changes (content of managed paths since renderer start):" >&2
  LC_ALL=C sort -u "$managed_fingerprint_delta" >&2
  exit 1
fi

# LC-037: onboarding never runs a project's own commands, so there is no pass or fail to report.
# The line states what was recorded and that nothing ran; the gates the record omits stay disclosed
# under `Undeclared gates`, as a note for the person onboarding and never as a failure.
if [ "$validation_total" -eq 1 ]; then
  validation_noun='gate'
else
  validation_noun='gates'
fi
validation="not run ($validation_total documented $validation_noun; onboarding never runs a project's own commands)"

# Round-13 F17: an eligible gate the contract left out is disclosed, never silently dropped.
undeclared_gate_count="$(grep -c '[^[:space:]]' "$undeclared_gates_file" || true)"
# Round-19: this section mints NO `Next:` entry. It used to emit "declare or explicitly rule
# out ...", but the pack implements no rule-out mechanism -- the phrase appeared nowhere else
# in it -- so half the instruction could not be followed and the only clearing action was to
# declare every listed script, including ones that need live credentials. A `Next:` entry is a
# promise that an action exists; disclosure without a remedy belongs in the section alone,
# which already ends "Onboarding did not run these and makes no claim about them."
undeclared_gate_next=''

# BUG-3: when a Phase 0 hash inventory exists, content-verify the preserved paths instead of
# checking existence alone (SKILL.md: both Preserved and Untouched pre-existing are verified
# against it). This is additive and degraded-mode-friendly: absent hash file falls back to the
# ledger's existence checks without any false content-verified claim. Format per line:
# <sha256><two spaces><path>. Any mismatch fails the render.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

# GAP-2: prefer the completion guard's pre-write baseline hashes over the agent-supplied file.
# The guard captures preserve-hashes.guard.txt at the same trusted pre-write moment it snapshots
# the manifest inventory, so in hooked mode the "Untouched pre-existing" content claim rests on a
# hook-attested capture instead of unenforced agent timing. The agent file is the degraded-mode
# fallback used only when no guard copy exists.
preserve_hashes_guard="$workspace_tmp/preserve-hashes.guard.txt"
preserve_hashes_agent="$workspace_tmp/preserve-hashes.txt"
preserve_hashes=""
if [ -f "$preserve_hashes_guard" ] && [ ! -L "$preserve_hashes_guard" ]; then
  preserve_hashes="$preserve_hashes_guard"
elif [ -f "$preserve_hashes_agent" ] && [ ! -L "$preserve_hashes_agent" ]; then
  preserve_hashes="$preserve_hashes_agent"
fi
if [ -n "$preserve_hashes" ]; then
  preserve_mismatch="$renderer_tmp/preserve-hash-mismatch"
  # Round-17: this verification used to fork TWICE per line -- `path_read_denied`
  # (a `git hash-object`) and `sha256_of` (a `shasum` plus its `awk`) -- and the guard writes one
  # line per BASELINE path, not per managed path. On a repository carrying an untracked `.venv/`
  # that is ~14.6k lines, so a measured render spent 501 of its 528 seconds right here while the
  # project's own validation gates took 11. Same fork-per-path class round-12 batched out of
  # `fingerprint_paths`; this loop was left behind.
  #
  # Hash the candidates through ONE `shasum` pipeline (xargs chunks to ARG_MAX) and keep the
  # per-path routine only for what the batch could not resolve -- so the denial probe, the
  # `(missing)` classification, and the uncomputable-hash failure all keep their exact former
  # semantics and their exact former order for every path that needs them.
  preserve_expected="$renderer_tmp/preserve-expected"
  preserve_batch="$renderer_tmp/preserve-batch"
  preserve_slow="$renderer_tmp/preserve-slow"
  preserve_actual="$renderer_tmp/preserve-actual"
  : > "$preserve_mismatch"
  : > "$preserve_expected"
  : > "$preserve_batch"
  : > "$preserve_slow"
  : > "$preserve_actual"
  while IFS= read -r hash_line; do
    [ -n "$hash_line" ] || continue
    expected_hash="${hash_line%%  *}"
    hashed_path="${hash_line#*  }"
    # Round-13 F16: the agent-supplied copy of this file derives its paths from the same quoted
    # `git status` output, so decode before the existence and hash checks below -- a quoted
    # spelling would report a present file as `(missing)` and fail the render.
    unquote_git_path "$hashed_path"
    hashed_path="$unquoted_path"
    if [ "$expected_hash" = "$hash_line" ] || [ -z "$hashed_path" ]; then
      echo "malformed preserve-hashes.txt line: $hash_line" >&2
      exit 1
    fi
    # The comment this replaces said a newline "cannot occur here at all: this file is
    # line-delimited". That is true of the INPUT and false of the value being guarded. The input
    # line is `<hash>  "quoted\npath"` -- one legal line -- and the decode two lines above turns it
    # into a name holding newlines, which then goes into `$preserve_expected`, itself line-oriented
    # and tab-delimited. The fragments are not files and are not read-denied, so they reach
    # `$preserve_mismatch` as `(missing)` and FAIL the render, claiming preserved paths changed.
    # Reached through the agent-supplied copy; the guard's is derived from a baseline that now
    # excludes such a path at the source.
    if [ "$hashed_path" != "${hashed_path%%$'\n'*}" ]; then
      printf '%s\n' "${hash_line#*  }" >> "$unrepresentable_file"
      continue
    fi
    printf '%s\t%s\n' "$hashed_path" "$expected_hash" >> "$preserve_expected"
    # `shasum` ESCAPES a path holding a backslash (and prefixes the line with one), so its output
    # could no longer be paired back to the path it came from. Those resolve the slow, exact way.
    case "$hashed_path" in
      *\\*) printf '%s\t%s\n' "$hashed_path" "$expected_hash" >> "$preserve_slow"; continue ;;
    esac
    # A shell builtin test -- no fork. A denied path reports false here (the sandbox refuses
    # `stat` too) and routes to the slow list, where the read probe still classifies it
    # `protected` before anything calls it missing.
    if [ -f "$hashed_path" ]; then
      printf '%s\n' "$hashed_path" >> "$preserve_batch"
    else
      printf '%s\t%s\n' "$hashed_path" "$expected_hash" >> "$preserve_slow"
    fi
  done < "$preserve_hashes"
  # A path listed twice with two different expected hashes cannot be answered from a
  # path-keyed batch. That is malformed input rather than a real capture, so it costs nothing to
  # hand the whole set to the exact per-path routine instead of silently checking one hash twice.
  if [ -s "$preserve_batch" ] &&
    [ -n "$(cut -f1 "$preserve_expected" | LC_ALL=C sort | uniq -d)" ]; then
    cat "$preserve_expected" > "$preserve_slow"
    : > "$preserve_batch"
  fi
  if [ -s "$preserve_batch" ]; then
    if command -v shasum >/dev/null 2>&1; then
      tr '\n' '\0' < "$preserve_batch" | xargs -0 shasum -a 256 -- > "$preserve_actual" 2>/dev/null || true
    elif command -v sha256sum >/dev/null 2>&1; then
      tr '\n' '\0' < "$preserve_batch" | xargs -0 sha256sum -- > "$preserve_actual" 2>/dev/null || true
    else
      # No hasher at all: every candidate goes to the per-path routine, which fails the render
      # with the exact same diagnostic it always did.
      cat "$preserve_expected" > "$preserve_slow"
      : > "$preserve_batch"
    fi
  fi
  if [ -s "$preserve_batch" ]; then
    # `<64 hex><two chars><path>` is the shared `shasum`/`sha256sum` output format. Pair by the
    # PATH the hasher echoed back, never by line position: an unreadable path is simply absent
    # from the output, and position-pairing would then compare every later path against the
    # wrong hash.
    awk -v expfile="$preserve_expected" -v actualfile="$preserve_actual" \
      -v mismatch="$preserve_mismatch" -v slow="$preserve_slow" '
      BEGIN {
        while ((getline line < expfile) > 0) {
          t = index(line, "\t")
          if (t == 0) continue
          want[substr(line, 1, t - 1)] = substr(line, t + 1)
        }
      }
      FILENAME == actualfile {
        path = substr($0, 67)
        if (path == "") next
        seen[path] = 1
        if (!(path in want)) next
        if (substr($0, 1, 64) != want[path]) print path >> mismatch
        next
      }
      !($0 in seen) { print $0 "\t" want[$0] >> slow }
    ' "$preserve_actual" "$preserve_batch"
  fi
  while IFS=$'\t' read -r hashed_path expected_hash; do
    [ -n "$hashed_path" ] || continue
    # Round-11: the generated secret boundary denies both stat and open, so a protected path
    # looks missing here and its sha256 cannot be computed. Disclose it as content-unverified
    # instead of reporting it missing or failing on an uncomputable hash.
    if path_read_denied "$hashed_path"; then
      printf '%s\n' "$hashed_path" >> "$protected_unverified_file"
      continue
    fi
    if [ ! -f "$hashed_path" ]; then
      printf '%s (missing)\n' "$hashed_path" >> "$preserve_mismatch"
      continue
    fi
    actual_hash="$(sha256_of "$hashed_path")" || {
      echo "cannot compute sha256 for preserved path (need shasum or sha256sum): $hashed_path" >&2
      exit 1
    }
    [ "$actual_hash" = "$expected_hash" ] || printf '%s\n' "$hashed_path" >> "$preserve_mismatch"
  done < "$preserve_slow"
  if [ -s "$preserve_mismatch" ]; then
    echo "preserved content verification failed (sha256 mismatch or missing):" >&2
    cat "$preserve_mismatch" >&2
    exit 1
  fi
fi

# BUG-3: build the set of pre-existing baseline paths so the ledger can separate genuinely
# managed preserved files from untracked user paths onboarding never manages.
baseline_paths_all="$renderer_tmp/baseline-paths.all"
{
  if [ "${#baseline_files[@]}" -gt 0 ]; then
    for baseline_file in ${baseline_files[@]+"${baseline_files[@]}"}; do
      [ -f "$baseline_file" ] || continue
      while IFS= read -r baseline_path; do
        [ -n "$baseline_path" ] || continue
        printf '%s\n' "$baseline_path"
      done < "$baseline_file"
    done
  fi
} | LC_ALL=C sort -u > "$baseline_paths_all"

relative_report_paths() {
  # ENVIRON, not -v: awk -v expands backslash escapes, which would mangle such a repository path.
  REPORT_PATH_PREFIX="$PWD/" awk '
    BEGIN { prefix = ENVIRON["REPORT_PATH_PREFIX"] }
    { while ((i = index($0, prefix)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(prefix)) }
    { print }
  ' "$1"
}

print_section() {
  local status="$1" label="$2" count
  count="$(awk -F '\t' -v status="$status" '$1 == status { count++ } END { print count + 0 }' "$tmp")"
  printf '%s (%s):\n' "$label" "$count"
  awk -F '\t' -v status="$status" '$1 == status { print "  " $2 }' "$tmp"
  printf '\n'
}

# BUG-3: split PRESERVED records into genuinely managed files and pre-existing baseline paths
# that onboarding never manages, so the ledger no longer conflates the two. SKILL.md keeps a
# dirty baseline path that is itself a manifest path under Preserved (a managed subset); only
# non-manifest baseline paths move to Untouched pre-existing. Resolve the active manifest the
# same way the inventory gate does — the mode captured at Phase 0, defaulting to the full
# default manifest when no mode was captured — so the split consults manifest membership, not
# baseline membership alone.
manifest_paths_all="$renderer_tmp/manifest-paths.all"
if [ -n "${captured_mode:-}" ] && [ -f "$captured_mode" ] && [ "$(cat "$captured_mode")" = launch-control ]; then
  onboard_launch_manifest
else
  onboard_default_manifest
fi | LC_ALL=C sort -u > "$manifest_paths_all"

managed_preserved="$renderer_tmp/preserved.managed"
preexisting_preserved="$renderer_tmp/preserved.preexisting"
: > "$managed_preserved"
: > "$preexisting_preserved"
# Round-12 F7: this ran one or two `grep` processes per PRESERVED row, and derivation puts one
# PRESERVED row in the ledger per baseline path — so a 15k-path baseline partitioned itself
# with ~25k processes. Same two set-membership tests, resolved in one pass.
awk -F '\t' -v OFS='\t' -v bf="$baseline_paths_all" -v mf="$manifest_paths_all" \
  -v managed="$managed_preserved" -v preexisting="$preexisting_preserved" '
  FILENAME == bf { baseline[$0] = 1; next }
  FILENAME == mf { manifest[$0] = 1; next }
  $1 != "PRESERVED" || $2 == "" { next }
  ($2 in baseline) && !($2 in manifest) { print $2 > preexisting; next }
  { print $2 > managed }
' "$baseline_paths_all" "$manifest_paths_all" "$tmp"

# Round-11: an untracked dependency directory (a virtualenv, node_modules) puts tens of
# thousands of pre-existing paths in the baseline — target repo A carries 14,400 under
# .venv/ alone. Every one is still captured and verified; only the printing collapses, and
# only past a threshold no hand-maintained workspace reaches. A report the reader cannot scan
# discloses nothing, and the alternative the run reached for — asking the user to gitignore
# the directory first — makes onboarding refuse an ordinary repository state.
PATH_GROUP_COLLAPSE_THRESHOLD=50

print_path_group() {
  # Optional third argument: a note printed after the paths and before the trailing blank line,
  # for groups whose count is derived from a mechanism narrower than the thing it describes.
  local label="$1" file="$2" note="${3:-}" count
  count="$(awk 'END { print NR + 0 }' "$file")"
  printf '%s (%s):\n' "$label" "$count"
  if [ "$count" -gt "$PATH_GROUP_COLLAPSE_THRESHOLD" ]; then
    # Collapse to one line per top-level directory, counted; paths at the repository root
    # stay listed individually so nothing a reader would act on disappears into a total.
    awk -F/ '
      NF > 1 { dir[$1]++; next }
      { file_list[++file_count] = $0 }
      END {
        for (d in dir) printf "  %s/ (%d %s)\n", d, dir[d], (dir[d] == 1 ? "path" : "paths") | "LC_ALL=C sort"
        close("LC_ALL=C sort")
        for (i = 1; i <= file_count; i++) printf "  %s\n", file_list[i]
      }
    ' "$file"
    printf '  Collapsed by top-level directory: every path above was captured and verified.\n'
  else
    while IFS= read -r grouped_path; do
      [ -n "$grouped_path" ] || continue
      printf '  %s\n' "$grouped_path"
    done < "$file"
  fi
  if [ -n "$note" ]; then
    while IFS= read -r note_line; do
      printf '  %s\n' "$note_line"
    done <<< "$note"
  fi
  printf '\n'
}

# BUG-3: the Untouched pre-existing section is emitted only when it has paths (SKILL.md:1203).
preexisting_count="$(awk 'END { print NR + 0 }' "$preexisting_preserved")"

# GAP-2: the Doc warnings section is emitted only when a user-owned artifacts doc failed the
# schema check (a non-blocking finding). A generated doc that fails the schema already exited above.
doc_warning_count="$(awk 'END { print NR + 0 }' "$doc_warnings")"

# Round-9: a stale onboard-generated block inside user-authoritative AGENTS.md surfaces here,
# in the guaranteed-visible rendered report, because model-relayed pre-report notes proved
# droppable. Detection matches discovery-checkpoint.sh (heading-delimited block, or legacy
# comment markers from older onboard versions). The model never writes AGENTS.md. In Codex mode
# the trusted finalizer below may regenerate its block (LC-061); the block counts as current only
# when the finalizer's own report says it wrote or confirmed the file, decided after it runs.
stale_agents=""
codex_mode=""
if [ -d "$PWD/.codex" ] || [ -L "$PWD/.codex" ] || [ -f "$workspace_tmp/codex-requested" ]; then
  codex_mode=1
fi
stale_agents_next='regenerate the stale AGENTS.md generated block manually (see Stale AGENTS.md)'

protected_unverified_sorted="$renderer_tmp/protected-unverified.sorted"
LC_ALL=C sort -u "$protected_unverified_file" > "$protected_unverified_sorted"
protected_unverified_count="$(grep -c '[^[:space:]]' "$protected_unverified_sorted" || true)"
# `sort -u` is what lets several capture sites name the same path without printing it twice: the
# run-start anchor, the baseline capture, and the two delta loops can all see one newline-named
# file in a single run, and each records the identical quoted spelling.
unrepresentable_sorted="$renderer_tmp/unrepresentable.sorted"
LC_ALL=C sort -u "$unrepresentable_file" > "$unrepresentable_sorted"
unrepresentable_count="$(grep -c '[^[:space:]]' "$unrepresentable_sorted" || true)"
symlinked_manifest_guard="$workspace_tmp/symlinked-manifest.guard.txt"
symlinked_manifest_sorted="$renderer_tmp/symlinked-manifest.sorted"
: > "$symlinked_manifest_sorted"
# Hooked mode only, deliberately. The guard writes this at the same trusted pre-write moment it
# pins the paths PRESERVED, and only the guard can observe that moment. In degraded mode the
# paths are still not written -- nothing generated them -- they are simply undisclosed, which
# is the same coverage limit every other guard-captured input carries here.
if [ -f "$symlinked_manifest_guard" ] && [ ! -L "$symlinked_manifest_guard" ]; then
  LC_ALL=C sort -u "$symlinked_manifest_guard" > "$symlinked_manifest_sorted"
fi
symlinked_manifest_count="$(grep -c '[^[:space:]]' "$symlinked_manifest_sorted" || true)"
validation_output_sorted="$renderer_tmp/validation-output.sorted"
LC_ALL=C sort -u "$validation_output_file" > "$validation_output_sorted"
validation_output_count="$(grep -c '[^[:space:]]' "$validation_output_sorted" || true)"

# Native Codex files have their own ownership preflight and explicit report.
# The Claude manifest and policy remain unchanged; only this trusted finalizer writes them.
codex_report="$renderer_tmp/codex-report"
: > "$codex_report"
if [ -n "$codex_mode" ]; then
  codex_args=(--project "$PWD" --codex)
  if [ -n "${captured_mode:-}" ] && [ -f "$captured_mode" ] && [ "$(cat "$captured_mode")" = launch-control ]; then
    codex_args+=(--launch-control)
  fi
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-parity.py" "${codex_args[@]}" > "$codex_report"
fi
if [ -f "$PWD/AGENTS.md" ] && [ ! -L "$PWD/AGENTS.md" ] &&
  { LC_ALL=C grep -Fqx '## Generated Quick Reference' "$PWD/AGENTS.md" 2>/dev/null ||
    LC_ALL=C grep -q 'BEGIN GENERATED SECTION -- onboard' "$PWD/AGENTS.md" 2>/dev/null; } &&
  ! printf 'CREATED %s\nMERGED %s\nPRESERVED %s\n' "$PWD/AGENTS.md" "$PWD/AGENTS.md" "$PWD/AGENTS.md" |
    LC_ALL=C grep -Fxq -f - "$codex_report"; then
  stale_agents=1
fi

# Preservation is verified above before this trusted, ownership-checked maintenance
# phase. Model-authored writes still cannot replace pre-existing skills.
skill_refresh_report="$renderer_tmp/skill-refresh-report"
: > "$skill_refresh_report"
if [ -z "${captured_mode:-}" ] || [ ! -f "$captured_mode" ] || [ "$(cat "$captured_mode")" != launch-control ]; then
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-refresh.py" onboard \
    --project "$PWD" --runtime claude > "$skill_refresh_report"
fi
# LC-045: every mode, so `--launch-control` maintenance migrates the old delivery skill too.
python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-refresh.py" retire-send-it \
  --project "$PWD" --runtime claude >> "$skill_refresh_report"
# A refreshed path must not also be reported as preserved.
while IFS= read -r line; do
  case "$line" in
    'UPGRADE '*)
      upgraded_path="${line#UPGRADE }/SKILL.md"
      upgraded_path="${upgraded_path#"$PWD/"}"
      awk -F '\t' -v OFS='\t' -v path="$upgraded_path" \
        '$2 == path { $1 = "MERGED" } { print }' "$tmp" > "$renderer_tmp/refresh-ledger"
      mv "$renderer_tmp/refresh-ledger" "$tmp"
      for preserved_file in "$managed_preserved" "$preexisting_preserved"; do
        awk -v path="$upgraded_path" '$0 != path' "$preserved_file" > "$renderer_tmp/refresh-preserved"
        mv "$renderer_tmp/refresh-preserved" "$preserved_file"
      done
      ;;
  esac
done < <(cat "$skill_refresh_report" "$codex_report")
preexisting_count="$(awk 'END { print NR + 0 }' "$preexisting_preserved")"

{
  printf '%s\n\n' '=== Workspace Setup Complete ==='
  # LC-044: the helpers print absolute targets; the report names repository paths relative,
  # like every other section. index() and substr(), so no path character acts as a pattern.
  if [ -s "$codex_report" ]; then
    printf 'Codex artifacts:\n'
    relative_report_paths "$codex_report"
    printf '\n'
  fi
  if [ -s "$skill_refresh_report" ]; then
    printf 'Project skill refresh:\n'
    relative_report_paths "$skill_refresh_report"
    printf '\n'
  fi
  print_section CREATED Created
  print_section MERGED Merged
  print_section SKIPPED Skipped
  print_path_group Preserved "$managed_preserved"
  [ "$preexisting_count" -eq 0 ] || print_path_group 'Untouched pre-existing' "$preexisting_preserved"
  # Round-12 F14: artifacts the declared gate emitted. Disclosed so a reader can see the gate is
  # not side-effect-free, which is exactly what blocking used to communicate — at the cost of
  # making the run impossible to complete.
  # Round-15 blocker 4: this group is derived from git-visible untracked paths, so a declared
  # gate's gitignored artifacts are counted by neither it nor anything else. Measured on a live
  # run: 17 files created under one output directory, 9 disclosed, the rest matched by the
  # project's own `*_metadata*.json` ignore rule. Rather than widen the mechanism to surface
  # paths the project deliberately ignores, state what the count is derived from -- the same
  # rule the permission-mode and claude-md-provenance lines follow: never let a number imply
  # more coverage than the mechanism behind it actually has.
  [ "$validation_output_count" -eq 0 ] || print_path_group 'New untracked paths' "$validation_output_sorted" \
    'Counted from git-visible untracked paths; paths the project gitignores are not counted
here, so the run may have created more than this number shows.'
  # A manifest path whose ancestor is a symlink is pinned PRESERVED by the guard, so it lands
  # in the Preserved group above like any other untouched path -- and a reader has no way to
  # tell why the path onboarding was asked to generate came back unchanged. The ledger row
  # cannot carry the reason: a trailing ` (...)` on a path line is rejected outright, so the
  # explanation needs a section of its own, the same shape the other disclosures use.
  if [ "$symlinked_manifest_count" -gt 0 ]; then
    printf 'Symlinked manifest paths (%s):\n' "$symlinked_manifest_count"
    while IFS=$'\t' read -r symlinked_path symlinked_target; do
      [ -n "$symlinked_path" ] || continue
      printf '  %s -- resolves to %s\n' "$symlinked_path" "$symlinked_target"
    done < "$symlinked_manifest_sorted"
    printf '  These paths reach a file onboarding does not own, so they were preserved, never\n'
    printf '  written. Onboarding does not change your repository layout to claim them: point\n'
    printf '  the run at the directory that owns the target, or replace the link yourself.\n\n'
  fi
  [ "$doc_warning_count" -eq 0 ] || print_path_group 'Doc warnings' "$doc_warnings"
  if [ -n "$stale_agents" ]; then
    printf 'Stale AGENTS.md:\n'
    printf '  AGENTS.md contains an onboard-generated marker block that onboarding no longer manages.\n'
    printf '  Compare the block against the current pack and regenerate it manually.\n'
    printf '  Onboarding never writes AGENTS.md; it is user-authoritative.\n\n'
  fi
  # Every member of this group reached it through a read denial -- `after_type = protected` in the
  # ledger honesty check, or an explicit `path_read_denied` probe -- so the note may name that
  # cause for all of them. Anything unverifiable for a DIFFERENT reason needs its own group, not
  # this one: the note is a claim about why, and `f03560a` made it false by reusing the group for
  # a path whose name simply would not fit on a line. Keep new causes out.
  if [ "$protected_unverified_count" -gt 0 ]; then
    printf 'Protected, content unverified (%s):\n' "$protected_unverified_count"
    while IFS= read -r protected_path; do
      [ -n "$protected_path" ] || continue
      printf '  %s\n' "$protected_path"
    done < "$protected_unverified_sorted"
    printf '  The generated secret boundary denies this run read access, so these paths are\n'
    printf '  reported unchanged by status only; their content was never read or compared.\n\n'
  fi
  if [ "$unrepresentable_count" -gt 0 ]; then
    printf 'Unrepresentable path names (%s):\n' "$unrepresentable_count"
    while IFS= read -r unrepresentable_path; do
      [ -n "$unrepresentable_path" ] || continue
      printf '  %s\n' "$unrepresentable_path"
    done < "$unrepresentable_sorted"
    printf '  These names contain a newline. Every capture and comparison this run makes is a\n'
    printf '  line-oriented file, which cannot hold such a name as one record, so each was\n'
    printf '  excluded rather than split into fragments that would be reported as paths of\n'
    printf '  their own. Shown in git'"'"'s quoted spelling. Nothing denied access to them and\n'
    printf '  nothing changed them; they were never read, compared, or counted anywhere above.\n\n'
  fi
  # LC-037: the gates the project documents, as recorded for the agents onboarding sets up. Nothing
  # here was run: onboarding never executes a project's own commands, so there is no result to show.
  if [ "$validation_total" -gt 0 ]; then
    printf 'Documented gates (%s):\n' "$validation_total"
    while IFS= read -r documented_gate; do
      [ -n "$documented_gate" ] || continue
      printf '  %s\n' "$documented_gate"
    done < "$validation_commands_snapshot"
    printf '\n'
  fi
  # Round-13 F17: package scripts eligible as gates that the recorded gates do not include.
  # LC-044: grouped under the source each was derived from, in first-seen order, instead of
  # repeating one reason on every line (target repo C printed the same reason 37 times).
  if [ "$undeclared_gate_count" -gt 0 ]; then
    printf 'Undeclared gates (%s):\n' "$undeclared_gate_count"
    awk -F '\t' '
      $1 == "" { next }
      !($2 in seen) { seen[$2] = 1; order[++sources] = $2 }
      { gates[$2] = gates[$2] "    " $1 "\n" }
      END { for (i = 1; i <= sources; i++) printf "  %s:\n%s", order[i], gates[order[i]] }
    ' "$undeclared_gates_file"
    printf '  Onboarding did not run these and makes no claim about them.\n\n'
  fi
  printf 'Checks:\n'
  # Round-22: every section above is sourced from the ledger, the manifest, and the run-start
  # baseline. A path that first appears AFTER the anchor and belongs to none of the three is not
  # accounted to any of them, and -- unlike a mutated tracked path, which GAP-1 makes block the
  # render -- it does not block either. Found via the first default-mode acceptance pair: the
  # harness wrote `.claude/settings.local.json` into BOTH repositories the moment the user
  # answered a permission prompt, and neither report mentioned it anywhere.
  #
  # The earlier spelling of this line said such a path "appears in no section above", and that
  # overclaimed: only the harness-owned local family is dropped silently (the `?? ` carve-out
  # above). Every other git-visible foreign path falls through to `$validation_output_raw` and IS
  # named, under `New untracked paths` -- which the round-22 probe recorded as unreported because a
  # developer's global excludes file hid the probe path from `git status` entirely. Round-15
  # blocker 4 settled the response for this class one section down (the `New untracked paths`
  # note): state what the count is derived from rather than widen the mechanism, which here would
  # mean diffing the whole tree against the anchor on every render and surfacing .venv,
  # node_modules, and gate churn as findings.
  printf '  worktree-accounting: ledger, manifest, and run-start baseline only -- a git-visible foreign path created during the run is named under New untracked paths; a harness-owned local file appears in no section above\n'
  printf '  branch: %s\n' "$branch"
  printf '  permission-mode: %s\n' "$permission_mode_check"
  printf '  claude-md-provenance: %s\n' "$claude_md_provenance"
  printf '  settings-json: %s\n' "$settings"
  printf '  hooks: %s\n' "$hooks"
  printf '  dependencies: %s\n' "$dependencies"
  printf '  validation: %s\n\n' "$validation"
  next_entries=()
  [ "$next" = none ] || next_entries+=("$next")
  [ -z "$undeclared_gate_next" ] || next_entries+=("$undeclared_gate_next")
  [ -z "$stale_agents" ] || next_entries+=("$stale_agents_next")
  printf 'Next:\n'
  if [ "${#next_entries[@]}" -eq 0 ]; then
    printf '  none\n'
  else
    printf '  %s\n' "${next_entries[@]}"
  fi
  printf '\n'
  printf '%s\n' '=== End Workspace Setup ==='
} > "$report"

# LC-044: a branded page drawn from the finished text, linked from the report itself. It is a
# view, never the record: any failure leaves the text report exactly as it was, minus the link.
html_report="$git_dir/launch-control/onboard-report.html"
if html_uri="$(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/report-html.py" \
    "$report" "$html_report" "$(basename "$PWD")" 2>/dev/null)" && [ -n "$html_uri" ]; then
  awk -v link="Visual report: $html_uri" \
    '$0 == "=== End Workspace Setup ===" { print link; print "" } { print }' \
    "$report" > "$renderer_tmp/report-linked"
  mv "$renderer_tmp/report-linked" "$report"
else
  html_report=''
fi

state="$git_dir/launch-control-onboard-report.expected"
state_tmp="$state.tmp.$$"
cp "$report" "$state_tmp"
mv "$state_tmp" "$state"
if [ -n "${bootstrap_proof:-}" ]; then
  rm -f "$bootstrap_proof"
fi
mark_render_stage 'report assembly'
printf '%s\t%s\n' "$SECONDS" 'TOTAL' >> "$render_timing_file" 2>/dev/null || true
cat "$report"
report_emitted=true

# Open the page for a person at a desktop; never for a Launch worker, CI, or the validator.
# `open` on Linux can be openvt, so each platform gets its own opener.
case "$(uname -s)" in Darwin) report_opener=open ;; *) report_opener=xdg-open ;; esac
if [ -n "$html_report" ] && [ -z "${LAUNCH_RUN_ID:-}" ] && [ -z "${CI:-}" ] &&
    [ -z "${LAUNCH_CONTROL_NO_OPEN:-}" ] && command -v "$report_opener" >/dev/null 2>&1; then
  "$report_opener" "$html_report" >/dev/null 2>&1 < /dev/null &
fi

# A hook-less/degraded run has no active lifecycle marker and no Stop hook that can own
# cleanup. Clean only after stdout and proof have been fully rendered. Hooked runs always
# retain an active marker here and leave both surfaces for Stop to verify atomically.
if [ "${#active_runs[@]}" -eq 0 ] && [ -f "$workspace_tmp/discovery-checkpoint" ]; then
  rm -f "$state"
  rm -rf "$workspace_tmp"
fi
