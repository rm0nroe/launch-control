#!/usr/bin/env bash
set -euo pipefail

# Invoking this script is the signal the onboarding lifecycle guard
# (completion-guard.sh PreToolUse hook) watches for: on seeing this exact command
# it records the session-scoped discovery marker that unblocks the first project
# Edit/Write. This body additionally leaves a human-readable marker in the session
# workspace so the recorded checkpoint is visible, not merely asserted.

marker_dir="$PWD/.launch-control-onboard"
marker="$marker_dir/discovery-checkpoint"
report="$marker_dir/discovery-report.txt"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ -f "$report" ] && [ ! -L "$report" ] || {
  echo "complete discovery report is missing: .launch-control-onboard/discovery-report.txt" >&2
  exit 1
}

awk '
  { line[NR] = $0 }
  END {
    if (NR < 20 || line[1] != "=== Workspace Discovery Report ===" || line[2] != "" ||
        line[NR] != "=== End Workspace Discovery Report ===") exit 1
    for (i = 1; i <= NR; i++) {
      if (line[i] ~ /^Project: [^[:space:]].*$/) project++
      if (line[i] ~ /^Stack: [^[:space:]].*$/) stack++
      if (line[i] ~ /^Monorepo: (yes|no)( |$)/) monorepo++
      if (line[i] ~ /^Base branch: [^[:space:]].*$/) branch++
      if (line[i] ~ /^CI: [^[:space:]].*$/) ci++
      if (line[i] == "Existing setup:") existing_header++
      if (line[i] ~ /^  CLAUDE\.md +\.+[. ]*[^[:space:]].*$/) claude++
      if (line[i] ~ /^  \.claude\/settings\.json +\.+[. ]*[^[:space:]].*$/) settings++
      if (line[i] ~ /^  \.claude\/agents\/ +\.+[. ]*[^[:space:]].*$/) agents++
      if (line[i] ~ /^  \.claude\/skills\/ +\.+[. ]*[^[:space:]].*$/) skills++
      if (line[i] ~ /^  \.claude\/commands\/ +\.+[. ]*[^[:space:]].*$/) commands++
      if (line[i] ~ /^  \.mcp\.json +\.+[. ]*[^[:space:]].*$/) mcp++
      if (line[i] == "Preserved doc freshness:") { freshness_header++; in_sources = 0 }
      else if (line[i] == "Sources used:") { sources_header++; in_sources = 1 }
      else if (in_sources && line[i] ~ /^  [^[:space:]].* -> [^[:space:]].*$/) sources++
    }
    if (project != 1 || stack != 1 || monorepo != 1 || branch != 1 || ci != 1 ||
        existing_header != 1 || claude != 1 || settings != 1 || agents != 1 ||
        skills != 1 || commands != 1 || mcp != 1 || sources_header != 1 || sources < 1 ||
        freshness_header != 1) exit 1
  }
' "$report" || {
  echo "discovery report does not match the required complete schema" >&2
  exit 1
}

# Round-33 F1/F2. The freshness comparison between live evidence and user-owned documentation
# used to be a Phase 4 rule, so the run learned its docs contradicted the repository only after
# Phases 1-3 had written the workspace: measured on rymonroe.com at 8m40s and five written paths
# for a fact the discovery report itself printed at minute 3 (`scripts (dev/build/start/lint/
# typecheck)` against an infrastructure.md that denied the typecheck script existed). Every input
# is a Phase 0 fact, so the decision belongs here, where failing keeps the lifecycle guard's
# first-write denial in place and the run blocks having written nothing but its own report.
#
# The schema is mechanical on purpose: this script cannot judge whether a document agrees with
# the repository, only that the run accounted for every document it had to compare and said which
# way each one came out. Judgement stays with the run; the accounting is enforced.
freshness_targets="CLAUDE.md artifacts/architecture.md artifacts/infrastructure.md"
freshness_present=""
freshness_contradictions=""
for freshness_doc in $freshness_targets; do
  [ -f "$PWD/$freshness_doc" ] && [ ! -L "$PWD/$freshness_doc" ] || continue
  freshness_present="$freshness_present $freshness_doc"
  # `<path>: <verdict>`, NOT the dot-leader spelling the `Existing setup:` block uses. That block
  # already counts a `  CLAUDE.md ....` line and requires exactly one, so a dot-leader freshness
  # line for CLAUDE.md would be counted twice and fail the schema above for the wrong reason.
  freshness_line="$(awk -v doc="$freshness_doc" '
    $0 == "Preserved doc freshness:" { in_section = 1; next }
    in_section && /^[^[:space:]]/ { in_section = 0 }
    in_section && index($0, "  " doc ": ") == 1 { print; found++ }
    END { exit found == 1 ? 0 : 1 }
  ' "$report")" || {
    echo "freshness section does not account for $freshness_doc: every preserved document must carry exactly one '  $freshness_doc: consistent' or '  $freshness_doc: contradicts: <observed contradiction>' line" >&2
    exit 1
  }
  freshness_verdict="${freshness_line#"  $freshness_doc: "}"
  case "$freshness_verdict" in
    consistent) ;;
    "contradicts: "?*) freshness_contradictions="$freshness_contradictions $freshness_doc" ;;
    *)
      echo "freshness verdict for $freshness_doc must be exactly 'consistent' or 'contradicts: <observed contradiction>'" >&2
      exit 1
      ;;
  esac
done

if [ -z "$freshness_present" ]; then
  awk '
    $0 == "Preserved doc freshness:" { in_section = 1; next }
    in_section && /^[^[:space:]]/ { in_section = 0 }
    in_section && $0 == "  (no preserved documentation)" { found++ }
    END { exit found == 1 ? 0 : 1 }
  ' "$report" || {
    echo "no preserved documentation exists, so the freshness section must be exactly one line: '  (no preserved documentation)'" >&2
    exit 1
  }
fi

# Every contradiction, never just the first. A block that names one of two stale surfaces sends
# the user through a fix-and-rerun cycle per surface, at a full onboarding run each; rymonroe.com
# carried the same stale fact in artifacts/infrastructure.md and in CLAUDE.md prose outside the
# generated markers. This list and its count ARE the Failed block the run must emit -- SKILL.md
# already binds every Failed item to machine output, so printing them here makes the enumeration
# mechanical rather than a matter of the run's diligence.
if [ -n "$freshness_contradictions" ]; then
  set -- $freshness_contradictions
  printf 'preserved documentation contradicts live evidence (%s):\n' "$#" >&2
  for freshness_doc in "$@"; do
    printf '  %s\n' "$freshness_doc" >&2
  done
  printf 'Emit the blocked protocol with Failed (%s) listing exactly these paths, one per line.\n' "$#" >&2
  printf 'Reason: state the contradiction each freshness line recorded.\n' >&2
  printf 'Next: Run the docs-update skill to refresh these documents, then rerun /onboard\n' >&2
  exit 1
fi

# LC-001. Phase 1a's `Read(/.env*)` and `Read(/**/.env*)` denies match the safe example names too
# (deny outranks allow; there is no negation form), so these files are readable in Phase 0 or
# never. The rule used to be prose only, and a run that deferred them to artifact authoring lost
# them without a trace. Same idiom as the freshness gate: the targets come from disk, the run
# accounts for each one. `read` must name the Sources used line it fed; `denied` holds only where
# the boundary is already in place, which is every rerun of an onboarded project.
# ponytail: nested examples count only when tracked; an untracked nested one is not enumerated.
safe_env_examples="$(
  {
    for safe_env in .env.example .env.sample .env.template .env.local.example; do
      if [ -f "$PWD/$safe_env" ]; then printf '%s\n' "$safe_env"; fi
    done
    git -c core.quotePath=false -C "$PWD" ls-files -- ':(glob)**/.env.example' ':(glob)**/.env.sample' \
      ':(glob)**/.env.template' ':(glob)**/.env.local.example' 2>/dev/null || true
  } | LC_ALL=C sort -u
)"
# Only `permissions.deny` counts. Without jq nothing does, so the run must read the examples.
safe_env_denies="$(
  for settings_file in .claude/settings.json .claude/settings.local.json; do
    if [ -f "$PWD/$settings_file" ] && [ ! -L "$PWD/$settings_file" ] && command -v jq >/dev/null 2>&1; then
      jq -r '.permissions.deny[]? | strings' "$PWD/$settings_file" 2>/dev/null || true
    fi
  done
)"
while IFS= read -r safe_env; do
  [ -n "$safe_env" ] || continue
  safe_env_line="$(awk -v path="$safe_env" '
    $0 == "Safe env examples:" { in_section = 1; next }
    in_section && /^[^[:space:]]/ { in_section = 0 }
    in_section && index($0, "  " path ": ") == 1 { print; found++ }
    END { exit found == 1 ? 0 : 1 }
  ' "$report")" || {
    echo "safe env example $safe_env is not accounted for: the report needs a 'Safe env examples:' section with exactly one '  $safe_env: read' or '  $safe_env: denied' line" >&2
    exit 1
  }
  case "${safe_env_line#"  $safe_env: "}" in
    read)
      awk -v path="$safe_env" '
        $0 == "Sources used:" { in_section = 1; next }
        in_section && /^[^[:space:]]/ { in_section = 0 }
        in_section && index($0, "  " path " -> ") == 1 && substr($0, length(path) + 7) ~ /[^[:space:]]/ { found++ }
        END { exit found ? 0 : 1 }
      ' "$report" || {
        echo "$safe_env is marked read, but Sources used has no line for $safe_env: add '  $safe_env -> <what was extracted>'" >&2
        exit 1
      }
      ;;
    denied)
      # A root deny (`/.env*`) does not reach a nested example; only the `**/` form does.
      case "$safe_env" in
        */*) safe_env_rule='^Read\((\./|/)?\*\*/\.env\*\)$' ;;
        *) safe_env_rule='^Read\((\./|/)?(\*\*/)?\.env\*\)$' ;;
      esac
      printf '%s\n' "$safe_env_denies" | grep -Eq "$safe_env_rule" || {
        echo "$safe_env is marked denied, but no .env read deny exists yet that covers it in .claude/settings.json or .claude/settings.local.json: read it now, before Phase 1a writes the boundary" >&2
        exit 1
      }
      ;;
    *)
      echo "verdict for $safe_env must be exactly 'read' or 'denied'" >&2
      exit 1
      ;;
  esac
done <<EOF
$safe_env_examples
EOF

if command -v shasum >/dev/null 2>&1; then
  report_hash="$(shasum -a 256 "$report" | awk '{ print $1 }')"
elif command -v sha256sum >/dev/null 2>&1; then
  report_hash="$(sha256sum "$report" | awk '{ print $1 }')"
else
  echo "discovery checkpoint requires shasum or sha256sum" >&2
  exit 1
fi

mkdir -p "$marker_dir"
printf 'phase-0-discovery-complete\t%s\t%s\n' "$report_hash" "$timestamp" > "$marker"

cat "$report"

# A leftover onboard-generated block inside user-authoritative AGENTS.md is only
# reachable through the agent-generation path in SKILL.md, which a pure-preserve
# rerun never executes. Flag it here so the staleness contract fires on every run.
agents_file="$PWD/AGENTS.md"
# The block is heading-delimited (`## Generated Quick Reference`); legacy comment markers
# from older onboard versions are recognised too.
if [ -f "$agents_file" ] && [ ! -L "$agents_file" ] &&
  { LC_ALL=C grep -Fqx '## Generated Quick Reference' "$agents_file" 2>/dev/null ||
    LC_ALL=C grep -q 'BEGIN GENERATED SECTION -- onboard' "$agents_file" 2>/dev/null; }; then
  printf '\n'
  printf 'STALE-AGENTS-CANDIDATE: AGENTS.md contains an onboard-generated block.\n'
  printf 'Read AGENTS.md and judge the block against the current pack (paths, skill and\n'
  printf 'command names). The renderer surfaces the staleness in the final report as a\n'
  printf 'Stale AGENTS.md section (in Codex mode the finalizer regenerates the block\n'
  printf 'instead). Never write to AGENTS.md and never promise to regenerate it in the\n'
  printf 'discovery report.\n'
fi

# Round-16 F34b: SKILL.md requires the run to disclose permission bypass as soon as it knows,
# but never named a way to FIND OUT, so a run improvised one — it read bypass off the SHAPE of
# the denials it had received ("policy denials fired with review guidance rather than hard
# refusals") and wrote that inference into prose. That inference is exactly backwards: under
# bypass the policy converts `ask` to a hard denial, and a run that stays inside the allowlist
# trips no gate at all and would learn nothing. The unattended policy already records the fact
# on its first PreToolUse, well before this checkpoint runs, so print it here — the earliest
# guaranteed surface, on a script the run must invoke anyway, needing no probe the policy could
# refuse and no session id the run does not have.
#
# Silence is not a statement that the session is unbypassed: per the F28 rule the absence of a
# marker is never an attestation, which is why the renderer prints `none recorded` rather
# than a claim about the mode.
if checkpoint_git_dir="$(git -C "$PWD" rev-parse --absolute-git-dir 2>/dev/null)"; then
  for bypass_marker in "$checkpoint_git_dir"/launch-control-onboard-run-*.bypass; do
    [ -e "$bypass_marker" ] || continue
    printf '\n'
    printf 'PERMISSION-MODE: bypassPermissions -- recorded by the unattended policy.\n'
    printf 'This line is the record. Never infer the mode from the shape of a denial, and\n'
    printf 'never read an absent record as proof the session is unbypassed.\n'
    printf "Under bypass the policy's ask-gates are denied rather than asked; say so once\n"
    printf 'in conversation. The report carries the same fact on its permission-mode: line.\n'
    break
  done
fi
