#!/usr/bin/env bash
set -euo pipefail

# Skill-scoped, non-persistent permission policy for /onboard. This script may
# auto-allow only the narrow operations the skill contract already authorizes.
# Explicit Claude deny/ask rules still take precedence over hook decisions.

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
permission_mode="$(printf '%s' "$input" | jq -r '.permission_mode // empty')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  exit 0
fi
cwd="$(cd "$cwd" && pwd -P)"

# Claude Code can retain skill-scoped hooks for later turns in the same session. Once
# the completion guard has verified the exact renderer output, its session marker makes
# this policy a no-op. A later /onboard prompt removes the marker through the guard's
# UserPromptSubmit hook before any discovery or write begins.
if [ -n "$session_id" ] && [[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] \
  && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir)"
  disarmed_state="$git_dir/launch-control-onboard-run-$session_id.disarmed"
  [ ! -f "$disarmed_state" ] || exit 0
  # Round-14 F28. The renderer cannot observe the session's permission mode, so the fact
  # that a run was unreviewed used to depend on the assistant volunteering it -- and twice
  # it did not. This hook sees `permission_mode` on every PreToolUse, before any denial is
  # needed, so it records the fact here and the renderer prints it in the report. Keying
  # the disclosure to the first denial does not work: a well-behaved run under bypass can
  # trip no `ask` gate at all, which is exactly what a code-explorer acceptance run did
  # once the settings-audit denial (F29) was allowlisted away.
  if [ "$permission_mode" = bypassPermissions ]; then
    : > "$git_dir/launch-control-onboard-run-$session_id.bypass" 2>/dev/null || true
  fi
  # Round-18: the bypass marker above answers only "was this bypassPermissions", and the
  # renderer branched the same way -- so every OTHER non-default mode rendered identically to
  # a human-reviewed default run. An `auto` acceptance pair proved it: both transcripts record
  # `permissionMode: auto`, both reports printed `no bypass recorded by the unattended policy`.
  # In `auto` the ask-gates are answered by a classifier, in `acceptEdits`/`dontAsk` they are
  # pre-answered; none of those is review, and the report is the artifact a reader is
  # guaranteed to see. Record the mode ITSELF so the renderer can name it instead of inferring
  # a binary. Charset-validated because the value lands in report text; the renderer validates
  # again rather than trusting a file under .git.
  if [[ "$permission_mode" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    printf '%s\n' "$permission_mode" \
      > "$git_dir/launch-control-onboard-run-$session_id.permission-mode" 2>/dev/null || true
  fi
fi

emit() {
  local decision="$1" reason="$2"
  case "$event" in
    PreToolUse)
      jq -cn --arg decision "$decision" --arg reason "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$decision,permissionDecisionReason:$reason}}'
      ;;
    PermissionRequest)
      case "$decision" in
        allow)
          jq -cn --arg reason "$reason" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"},additionalContext:$reason}}'
          ;;
        deny)
          jq -cn --arg reason "$reason" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$reason}}}'
          ;;
        ask) exit 0 ;;
      esac
      ;;
  esac
}

deny() { emit deny "$1"; exit 0; }
allow() { emit allow "$1"; exit 0; }
ask() {
  # Under bypassPermissions there is no interactive prompt, so an `ask` fallback would
  # silently execute. Hard-deny instead: the least-privilege boundary cannot defer an
  # unlisted operation to a review that will never happen.
  if [ "$permission_mode" = bypassPermissions ]; then
    deny "$1 This operation needs an ask, and permission bypass cannot answer one, so it is denied. Onboarding does not need it: continue without it, using the native-tool alternative where this message names one."
  fi
  emit ask "$1"
  exit 0
}

# A bypassPermissions session used to be refused here, before every allowlist branch, so
# onboarding could not begin at all. That over-shot the risk it was written for, and it
# contradicted SKILL.md, which says the run may proceed under bypass with disclosure.
#
# `deny` is honored in every permission mode, so the boundary that actually matters --
# out-of-repo reads, protected secrets, shell composition, and traversal -- is fully in force
# under bypass. Only `ask` degrades, and
# `ask()` above already converts it to `deny`: an operation that would prompt in the
# default mode is refused outright here. Bypass is therefore STRICTER than the default
# mode, not looser, and needs no blanket refusal.
#
# What bypass genuinely loses is review of tools this hook never sees. Any tool that
# reaches the dispatch at the end of this file and is not covered falls to `ask`, so under
# bypass it is denied. The residual gap is tools the SKILL.md frontmatter matcher does not
# route here at all; closing that is a matcher change, not a reason to refuse the run.

relative_repo_path() {
  local candidate="$1" parent resolved_parent base
  case "$candidate" in
    .|./) printf '%s\n' .; return 0 ;;
    "$cwd") printf '%s\n' .; return 0 ;;
    "$cwd"/*) candidate="${candidate#"$cwd"/}" ;;
    /*) return 1 ;;
  esac
  # A leading `./` names exactly the path its bare spelling does, and runs emit it
  # constantly (`find ./.github -type f`, `cat ./README.md`, `ls ./artifacts`). The
  # traversal guard below matched it as `*/./*` and refused, so operations the policy
  # already authorizes were denied purely on spelling -- four denials in one acceptance
  # run, each retried in its bare form seconds later. Strip it here, once, for every
  # caller: this function is the single path gate for find, cat, grep, ls, head, tail,
  # wc, rg, and git ls-files pathspecs. An embedded `/./` and every `../` stay refused,
  # so the confinement the guard exists for is unchanged.
  while :; do
    case "$candidate" in
      ./?*) candidate="${candidate#./}" ;;
      *) break ;;
    esac
  done
  case "/$candidate/" in */../*|*/./*) return 1 ;; esac

  # Reject a symlinked ancestor that escapes the repository. Suppress dirname/basename
  # stderr: a `--`-style token is a valid deny path but makes them print a usage error.
  parent="$cwd/$(dirname "$candidate" 2>/dev/null)"
  while [ ! -e "$parent" ] && [ "$parent" != "$cwd" ]; do
    parent="$(dirname "$parent" 2>/dev/null)"
  done
  resolved_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  case "$resolved_parent" in "$cwd"|"$cwd"/*) ;; *) return 1 ;; esac

  base="$(basename "$candidate" 2>/dev/null)"
  [ -n "$base" ] || return 1
  printf '%s\n' "$candidate"
}

is_protected_read() {
  local path="$1" base
  base="$(basename "$path")"
  case "$base" in
    .env.example|.env.sample|.env.template|.env.local.example) ;;
    .env|.env.*) return 0 ;;
  esac
  case "$path" in
    secrets/*|*/secrets/*) return 0 ;;
  esac
  # Only credential DATA counts as a secret here. A bare `credentials*` prefix also matched
  # ordinary source files such as `api/routers/credentials.py`, which is not a credential
  # store: in a real run that denial blocked the renderer's own `git status` verification and
  # left the user's own source unreadable in every later session. Match the extensionless and
  # dotfile forms plus credential-data suffixes; anything else (including every recognized
  # source extension: .py .ts .tsx .js .jsx .mjs .cjs .go .rb .java .rs .php .cs .kt .swift
  # .c .h .cpp .hpp .sh .bash .sql .md) stays readable.
  case "$base" in
    credentials|.credentials*) return 0 ;;
    credentials*.json|credentials*.yaml|credentials*.yml|credentials*.toml) return 0 ;;
    credentials*.ini|credentials*.cfg|credentials*.conf|credentials*.env) return 0 ;;
    credentials*.txt|credentials*.pem|credentials*.key|credentials*.p12) return 0 ;;
    credentials*.pfx|credentials*.jks|credentials*.keystore) return 0 ;;
    credentials*.db|credentials*.sqlite|credentials*.enc) return 0 ;;
  esac
  return 1
}

# Confirm every filesystem argument of a read-only discovery command (cat/ls/head/tail/
# wc/grep/rg) stays inside the repository and clear of protected secrets. Bash utilities are
# not covered by check_path_tool, so without this a prefix match on `cat `/`ls ` etc.
# would authorize out-of-repository and secret reads. Returns non-zero to force a deny.
#
# The hook sees the pre-expansion command string, so the bytes that reach the filesystem
# can differ from any token that carries a shell metacharacter (glob, brace, tilde/var
# expansion, backslash escape, or a residual quote). Such a token cannot be validated as
# the literal path it will become, so it is denied rather than interpreted. Every other
# non-flag argument — including an rg search pattern — is validated as a repo-relative
# path; a pattern that happens to name a repository path is allowed, one that escapes or
# hits a secret is denied. `--` ends option processing so a later `-`-prefixed operand is
# still checked.
#
# Validate one already-unquoted operand as a repo-relative, non-secret path. Returns
# non-zero when it carries a shell metacharacter, escapes the repository, or names a
# protected secret. Shared by the positional-operand loop and the attached-value flag
# handling so both paths deny identically.
guard_validate_operand() {
  local token="$1" relative
  case "$token" in
    *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'\'*|*'$'*|*'~'*|*'`'*|*'"'*|*"'"*) return 1 ;;
  esac
  relative="$(relative_repo_path "$token")" || return 1
  is_protected_read "$relative" && return 1
  return 0
}
bash_path_guard() {
  local cmd="$1" token file_value options_ended=false skip_pattern_operand=false \
    expect_file_operand=false
  shift                                        # drop the command name
  # Fix 4 (e2e follow-up): for grep/rg the first positional operand is the SEARCH PATTERN, not a
  # path. Validating it as a path made an in-repo recursive content grep whose pattern happens to
  # match a secret name (`rg credentials`, `grep -rn .env src`) deny as if it were reading that
  # secret file. Skip that one operand — but only when the pattern was not supplied via a
  # -e/-f/--regexp/--file flag, so `rg -f .env x` (the `.env` is a FILE argument) still validates
  # and denies. A -f/-e can also ride inside a short-flag BUNDLE (`grep -rf.env`, `grep -rnf x`);
  # grep/rg parse the first f/e in a bundle as the file/regexp flag, so those forms also mean the
  # first positional is a path, not a pattern. Every later operand stays a path and keeps full
  # validation.
  case "$cmd" in
    grep|rg)
      skip_pattern_operand=true
      for token in "$@"; do
        case "$token" in
          -e|-f|--regexp|--file|--regexp=*|--file=*|-e=*|-f=*|-e?*|-f?*|-[!-fe]*[fe]*)
            skip_pattern_operand=false; break ;;
        esac
      done
      ;;
  esac
  for token in "$@"; do
    # Strip a single layer of matching surrounding quotes.
    case "$token" in
      \"*\") token="${token#\"}"; token="${token%\"}" ;;
      \'*\') token="${token#\'}"; token="${token%\'}" ;;
    esac
    [ -n "$token" ] || continue
    # A -f/--file/-e/--regexp flag whose value was NOT attached consumes THIS operand as its
    # (pattern-file / regexp) value. That value is a real path that gets read, so validate it
    # and never treat it as the skippable search pattern.
    if [ "$expect_file_operand" = true ]; then
      expect_file_operand=false
      guard_validate_operand "$token" || return 1
      continue
    fi
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        # Bare -f/--file/-e/--regexp: the value is the NEXT operand (`rg -f .env x`).
        -f|-e|--file|--regexp) expect_file_operand=true; continue ;;
        # Attached value: `--file=V`, `-f=V`, `-fV`. For -f/--file the value is a pattern FILE
        # that gets read, so path-validate it exactly like the space-separated form — otherwise
        # `rg --file=.env x` / `rg -f=.env x` / `rg -f.env x` would slip a secret read past the
        # guard as an opaque option flag. Match the `=` forms first so the value is taken from
        # after the `=`.
        --file=*|--regexp=*|-f=*|-e=*)
          guard_validate_operand "${token#*=}" || return 1
          continue ;;
        -f?*|-e?*)
          guard_validate_operand "${token#??}" || return 1
          continue ;;
        # A -f/-e bundled BEHIND other short flags (`grep -rf.env`, `grep -Hf x`, `grep -rnf.env`):
        # grep/rg parse the first f/e in the bundle as the file/regexp flag and read the rest of
        # the token as its value, or — when f/e is the bundle's last character — the next operand.
        # Strip everything up to and including the first f/e to recover the attached value. This is
        # a security guard, so on any ambiguity it over-denies rather than passes an unread secret.
        -[!-fe]*[fe]*)
          file_value="${token#*[fe]}"
          file_value="${file_value#=}"         # grep/ugrep strip a `=` after the bundled flag
          if [ -n "$file_value" ]; then
            guard_validate_operand "$file_value" || return 1
          else
            expect_file_operand=true
          fi
          continue ;;
        -*) continue ;;                        # option flag, not a path
      esac
    fi
    # The first positional operand of a grep/rg is the search pattern; it is not read as a
    # path, so skip both the metacharacter check and the path/secret validation for it.
    if [ "$skip_pattern_operand" = true ]; then
      skip_pattern_operand=false
      continue
    fi
    # relative_repo_path (inside the helper) rejects absolute paths, `.`/`..` segments, and
    # symlinked ancestors that escape the repository, plus any shell metacharacter.
    guard_validate_operand "$token" || return 1
  done
  # A trailing bare -f/-e with no operand is malformed; deny rather than pass it silently.
  [ "$expect_file_operand" = false ] || return 1
  return 0
}

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

is_generated_write_path() {
  local candidate="$1" path
  case "$candidate" in .launch-control-onboard/*) return 0 ;; esac
  while IFS= read -r path; do
    [ "$candidate" != "$path" ] || return 0
  done < <(onboard_default_manifest)
  return 1
}

# Read-only repository inventory fallback, in exactly two shapes:
#   find <repo-relative-root> -type f|d
#   find <repo-relative-root> -maxdepth <digits> -type f|d
# `-type d` is accepted alongside `-type f` because listing directories is read-only and
# `git ls-files` is the natural spelling for "does this repository track anything under
# <path>", and its read-only siblings (status, log, diff, show-ref) are already allowed.
# Flags are restricted to the inventory set -- nothing that writes, and nothing that runs
# another program -- and every pathspec goes through the same repository/secret guard as
# cat and grep, so a pathspec can neither escape the repository nor name a protected
# secret. Discovery should still prefer native Glob; this exists so the Bash spelling is a
# reviewed allow rather than a prompt, which under permission bypass would be a denial.
is_safe_git_ls_files_command() {
  local token options_ended=false i=2
  local -a pathspecs=()
  split_simple_shell_words "$1" || return 1
  [ "${#SIMPLE_WORDS[@]}" -ge 2 ] || return 1
  [ "${SIMPLE_WORDS[0]}" = git ] && [ "${SIMPLE_WORDS[1]}" = ls-files ] || return 1
  while [ "$i" -lt "${#SIMPLE_WORDS[@]}" ]; do
    token="${SIMPLE_WORDS[$i]}"
    i=$((i + 1))
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        --cached|--others|--modified|--deleted|--directory|--no-empty-directory|--exclude-standard|-z)
          continue ;;
        -*) return 1 ;;
      esac
    fi
    pathspecs+=("$token")
  done
  [ "${#pathspecs[@]}" -gt 0 ] || return 0
  # Pass `ls` as the command name: the grep/rg pattern-operand exemption must not apply
  # here, because every ls-files operand really is a path.
  bash_path_guard ls "${pathspecs[@]}"
}

# `git check-ignore` is a pure read: it reports whether the given paths are ignored and
# writes nothing. Only the single literal `git check-ignore -q .launch-control-onboard/` was
# allowed, so the shape a run actually issues -- several repo-local control paths under
# `-v` -- was denied. Accept the read-only reporting flags and validate every operand
# through the same repository/secret guard as ls-files, so an operand can neither escape
# the repository nor name a protected secret. Anything else (a writing or unknown flag,
# no operand at all) is refused.
is_safe_git_check_ignore_command() {
  local token options_ended=false i=2
  local -a operands=()
  split_simple_shell_words "$1" || return 1
  [ "${#SIMPLE_WORDS[@]}" -ge 2 ] || return 1
  [ "${SIMPLE_WORDS[0]}" = git ] && [ "${SIMPLE_WORDS[1]}" = check-ignore ] || return 1
  while [ "$i" -lt "${#SIMPLE_WORDS[@]}" ]; do
    token="${SIMPLE_WORDS[$i]}"
    i=$((i + 1))
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        -q|--quiet|-v|--verbose|-n|--non-matching|--no-index) continue ;;
        -*) return 1 ;;
      esac
    fi
    operands+=("$token")
  done
  # check-ignore with no pathspec reads stdin (`--stdin`) or errors; require an operand
  # so every path this reports on has been through the guard.
  [ "${#operands[@]}" -gt 0 ] || return 1
  # Pass `ls` as the command name: the grep/rg pattern-operand exemption must not apply
  # here, because every check-ignore operand really is a path.
  bash_path_guard ls "${operands[@]}"
}

# repo-confined on exactly the same terms as listing files.
is_safe_find_command() {
  local root relative
  split_simple_shell_words "$1" || return 1
  case "${#SIMPLE_WORDS[@]}" in
    4)
      [ "${SIMPLE_WORDS[0]}" = find ] || return 1
      root="${SIMPLE_WORDS[1]}"
      [ "${SIMPLE_WORDS[2]}" = -type ] || return 1
      case "${SIMPLE_WORDS[3]}" in f|d) ;; *) return 1 ;; esac
      ;;
    6)
      # `.` is a legal root in the depth-limited form. It used to be banned here, which was
      # backwards: this shape is strictly narrower than the unbounded 4-word form already
      # allowed above, so denying it only pushed runs into repo-wide `find . -type f` sweeps
      # whose oversized output then landed outside the repository, where policy correctly
      # refused to read it. Confinement still comes from relative_repo_path below.
      [ "${SIMPLE_WORDS[0]}" = find ] || return 1
      root="${SIMPLE_WORDS[1]}"
      [ "${SIMPLE_WORDS[2]}" = -maxdepth ] || return 1
      [[ "${SIMPLE_WORDS[3]}" =~ ^[0-9]+$ ]] || return 1
      [ "${SIMPLE_WORDS[4]}" = -type ] || return 1
      case "${SIMPLE_WORDS[5]}" in f|d) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  relative="$(relative_repo_path "$root")" || return 1
  is_protected_read "$relative" && return 1
  return 0
}

is_safe_shasum_command() {
  local operand
  split_simple_shell_words "$1" || return 1
  [ "${#SIMPLE_WORDS[@]}" -ge 4 ] || return 1
  [ "${SIMPLE_WORDS[0]}" = shasum ] || return 1
  [ "${SIMPLE_WORDS[1]}" = -a ] || return 1
  [ "${SIMPLE_WORDS[2]}" = 256 ] || return 1
  for operand in "${SIMPLE_WORDS[@]:3}"; do
    [ ! -L "$cwd/$operand" ] || return 1
    [ -f "$cwd/$operand" ] || return 1
    guard_validate_operand "$operand" || return 1
  done
  return 0
}

is_installed_discovery_checkpoint_invocation() {
  local command="$1" config_root checkpoint
  config_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$config_root/skills/onboard/scripts" ] || return 1
  config_root="$(cd "$config_root" 2>/dev/null && pwd -P)" || return 1
  checkpoint="$config_root/skills/onboard/scripts/discovery-checkpoint.sh"
  [ -f "$checkpoint" ] || return 1
  [ ! -L "$checkpoint" ] || return 1
  [ -x "$checkpoint" ] || return 1
  split_simple_shell_words "$command" || return 1
  [ "${#SIMPLE_WORDS[@]}" -eq 1 ] || return 1
  [ "${SIMPLE_WORDS[0]}" = "$checkpoint" ]
}

is_installed_reference_read() {
  local candidate="$1" config_root references_root candidate_parent candidate_base
  config_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$config_root/skills/onboard/references" ] || return 1
  config_root="$(cd "$config_root" 2>/dev/null && pwd -P)" || return 1
  references_root="$(cd "$config_root/skills/onboard/references" 2>/dev/null && pwd -P)" || return 1

  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  case "/$candidate/" in */../*|*/./*) return 1 ;; esac
  candidate_base="$(basename "$candidate" 2>/dev/null)" || return 1
  case "$candidate_base" in *.md) ;; *) return 1 ;; esac
  candidate_parent="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
  [ "$candidate_parent" = "$references_root" ] || return 1
  [ -f "$candidate" ] || return 1
  [ ! -L "$candidate" ] || return 1
  return 0
}

check_path_tool() {
  local field="$1" candidate relative
  candidate="$(printf '%s' "$input" | jq -r --arg field "$field" '.tool_input[$field] // empty')"
  [ -n "$candidate" ] || candidate="$cwd"

  # The explicit global-guidance opt-in may read this one user file. The hook
  # cannot grant access to any sibling user path.
  if [ "$tool" = Read ] && [ "$candidate" = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" ]; then
    allow 'Onboard may read the explicitly supported global CLAUDE.md input.'
  fi

  if [ "$tool" = Read ] && is_installed_reference_read "$candidate"; then
    allow 'Onboard may read a canonical Markdown reference from its installed skill.'
  fi

  relative="$(relative_repo_path "$candidate")" || deny 'Onboard unattended access is limited to the current repository.'
  is_protected_read "$relative" && deny 'Onboard cannot read protected project secret paths.'

  case "$tool" in
    Edit|Write)
      is_generated_write_path "$relative" || deny 'Onboard may write only paths declared by its generated workspace manifest.'
      allow 'Onboard is writing a declared generated workspace path inside the repository.'
      ;;
    Read|Glob|Grep)
      allow 'Onboard is performing read-only discovery inside the repository.'
      ;;
  esac
}

SIMPLE_WORDS=()
split_simple_shell_words() {
  local text="$1" mode="${2:-strict}" char next quote='' token='' started=false index
  SIMPLE_WORDS=()
  for ((index = 0; index < ${#text}; index++)); do
    char="${text:index:1}"
    case "$quote" in
      '')
        case "$char" in
          ' '|$'\t')
            if [ "$started" = true ]; then
              SIMPLE_WORDS+=("$token")
              token=''
              started=false
            fi
            ;;
          "'"|'"') quote="$char"; started=true ;;
          ';'|'&'|'|'|'>'|'<'|$'\n'|'`') return 1 ;;
          '$')
            next="${text:index+1:1}"
            [ "$next" != '(' ] || return 1
            if [ "$mode" = strict ]; then return 1; fi
            token+="$char"; started=true
            ;;
          \\) return 1 ;;
          '~'|'*'|'?'|'['|']'|'{'|'}')
            if [ "$mode" = strict ]; then return 1; fi
            token+="$char"; started=true
            ;;
          *) token+="$char"; started=true ;;
        esac
        ;;
      "'")
        if [ "$char" = "'" ]; then quote=''; else token+="$char"; fi
        ;;
      '"')
        case "$char" in
      '"') quote='' ;;
          '`') return 1 ;;
          '$')
            next="${text:index+1:1}"
            [ "$next" != '(' ] || return 1
            if [ "$mode" = strict ]; then return 1; fi
            token+="$char"
            ;;
          \\)
            next="${text:index+1:1}"
            [ "$next" = '|' ] || return 1
            token+='\|'
            index=$((index + 1))
            ;;
          *) token+="$char" ;;
        esac
        ;;
    esac
  done
  [ -z "$quote" ] || return 1
  if [ "$started" = true ]; then
    SIMPLE_WORDS+=("$token")
  fi
  [ "${#SIMPLE_WORDS[@]}" -gt 0 ]
}

is_onboard_control_file() {
  local candidate="$1" relative target
  relative="$(relative_repo_path "$candidate")" || return 1
  case "$relative" in .launch-control-onboard/*) ;; *) return 1 ;; esac
  target="$cwd/$relative"
  [ -f "$target" ] || return 1
  [ ! -L "$target" ] || return 1
}

is_installed_renderer_invocation() {
  local command="$1" config_root renderer offset=0 branch required baseline
  config_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$config_root/skills/onboard/scripts" ] || return 1
  config_root="$(cd "$config_root" 2>/dev/null && pwd -P)" || return 1
  renderer="$config_root/skills/onboard/scripts/render-report.sh"
  [ -f "$renderer" ] || return 1
  [ ! -L "$renderer" ] || return 1
  [ -x "$renderer" ] || return 1

  split_simple_shell_words "$command" || return 1
  if [ "${#SIMPLE_WORDS[@]}" -eq 11 ]; then
    case "${SIMPLE_WORDS[0]}" in ONBOARD_REQUIRED_PATHS_FILE=*) ;;
      *) return 1 ;;
    esac
    case "${SIMPLE_WORDS[1]}" in ONBOARD_BASELINE_PATHS_FILE=*) ;;
      *) return 1 ;;
    esac
    required="${SIMPLE_WORDS[0]#ONBOARD_REQUIRED_PATHS_FILE=}"
    baseline="${SIMPLE_WORDS[1]#ONBOARD_BASELINE_PATHS_FILE=}"
    is_onboard_control_file "$required" || return 1
    is_onboard_control_file "$baseline" || return 1
    offset=2
  elif [ "${#SIMPLE_WORDS[@]}" -ne 9 ]; then
    return 1
  fi

  [ "${SIMPLE_WORDS[$offset]}" = "$renderer" ] || return 1
  is_onboard_control_file "${SIMPLE_WORDS[$((offset + 1))]}" || return 1
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)" || return 1
  [ -n "$branch" ] || return 1
  [ "${SIMPLE_WORDS[$((offset + 2))]}" = "$branch" ] || return 1
  case "${SIMPLE_WORDS[$((offset + 3))]}" in valid|'not generated') ;; *) return 1 ;; esac
  case "${SIMPLE_WORDS[$((offset + 4))]}" in absent|preserved|enabled) ;; *) return 1 ;; esac
  case "${SIMPLE_WORDS[$((offset + 5))]}" in ready|'missing: '*) ;; *) return 1 ;; esac
  is_onboard_control_file "${SIMPLE_WORDS[$((offset + 6))]}" || return 1
  [ "${SIMPLE_WORDS[$((offset + 7))]}" = none ] || return 1
  [ "${SIMPLE_WORDS[$((offset + 8))]}" = complete ] || return 1
  return 0
}

is_installed_renderer_cleanup_invocation() {
  local command="$1" config_root renderer
  config_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$config_root/skills/onboard/scripts" ] || return 1
  config_root="$(cd "$config_root" 2>/dev/null && pwd -P)" || return 1
  renderer="$config_root/skills/onboard/scripts/render-report.sh"
  [ -f "$renderer" ] || return 1
  [ ! -L "$renderer" ] || return 1
  [ -x "$renderer" ] || return 1
  split_simple_shell_words "$command" || return 1
  [ "${#SIMPLE_WORDS[@]}" -eq 2 ] || return 1
  [ "${SIMPLE_WORDS[0]}" = "$renderer" ] || return 1
  [ "${SIMPLE_WORDS[1]}" = --cleanup ]
}

lifecycle_guard_owns_cleanup() {
  [ -n "$session_id" ] && [[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || return 1
  local active_git_dir
  active_git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir)"
  [ -e "$active_git_dir/launch-control-onboard-run-$session_id.active" ] ||
    [ -e "$active_git_dir/launch-control-onboard-run-$session_id.discovery" ] ||
    [ -e "$active_git_dir/launch-control-onboard-run-$session_id.rendered" ]
}

check_bash() {
  local command
  local -a path_argv
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
  [ -n "$command" ] || deny 'Onboard received an empty Bash command.'
  # Round-37: the refusal of `dangerouslyDisableSandbox: true` is removed at the maintainer's
  # instruction. Whether Bash runs sandboxed is the user's setting, the same ownership rule that
  # took the generated `sandbox` block out in round 36; onboarding no longer has an opinion about
  # it in either direction. Everything else this function enforces is unchanged -- out-of-repo
  # reads, protected secret paths, shell composition, traversal, and the exact-command allowlist --
  # and those, not the sandbox flag, are what keep an unattended run inside the repository.

  split_simple_shell_words "$command" composition || \
    deny 'Onboard unattended Bash accepts one simple command at a time without shell composition or ambiguous quoting.'

  # Every rule below matches the bare `git <subcommand>` spelling, but runs consistently
  # issue `git -C <repository> <subcommand>` with an absolute path. That missed the
  # allowlist -- three prompts per acceptance run, for `status`, `branch`, and `ls-files`
  # that are all already approved by name -- and, worse, it missed the DENYLIST too:
  # `git -C <repo> reset --hard` does not contain " git reset " and fell through to a
  # prompt instead of a refusal. Normalize the prefix once here so both lists see the same
  # command. A `-C` naming any directory other than this repository is left untouched and
  # takes the normal review path.
  case "$command" in
    'git -C '*)
      local git_c_target git_c_rest
      if [ "${#SIMPLE_WORDS[@]}" -ge 3 ] && [ "${SIMPLE_WORDS[0]}" = git ] && [ "${SIMPLE_WORDS[1]}" = -C ]; then
        git_c_target="${SIMPLE_WORDS[2]}"
        case "$git_c_target" in
          \"*\") git_c_target="${git_c_target#\"}"; git_c_target="${git_c_target%\"}" ;;
          \'*\') git_c_target="${git_c_target#\'}"; git_c_target="${git_c_target%\'}" ;;
        esac
        if [ -d "$git_c_target" ] && [ "$(cd "$git_c_target" 2>/dev/null && pwd -P)" = "$cwd" ]; then
          git_c_rest="$(printf '%s ' "${SIMPLE_WORDS[@]:3}")"
          command="git ${git_c_rest% }"
        fi
      fi
      ;;
  esac

  case " $command " in
    *' sudo '*|*' rm '*|*' rmdir '*|*' mv '*|*' cp '*|*' curl '*|*' wget '*|*' ssh '*|*' scp '*|*' rsync '*|*' git add '*|*' git commit '*|*' git push '*|*' git pull '*|*' git checkout '*|*' git switch '*|*' git reset '*|*' git clean '*|*' gh pr '*|*' npm install '*|*' pnpm install '*|*' yarn install '*|*' brew '*|*' apt-get '*)
      deny 'Onboard unattended mode does not authorize destructive, external, dependency-installing, or repository-mutating commands.' ;;
  esac

  # Read-only discovery that takes no filesystem path argument to validate.
  #
  # `git rev-parse` is listed only as exact literals. The allowlist already carried
  # `git branch --show-current`, but a run asked the same question with
  # `git rev-parse --abbrev-ref HEAD`, ate a denial, and reissued the branch spelling
  # nine seconds later. A `git rev-parse '*` wildcard is NOT the fix: rev-parse also
  # takes path and option-parsing arguments (`--parseopt`, `--sq-quote`, arbitrary
  # revisions and pathspecs), so only these five fixed, argument-free reads are named.
  case "$command" in
    'git status'|'git status '*|'git branch --show-current'|'git show-ref'|'git show-ref '*|'git log'|'git log '*|'git diff'|'git diff '*|'git remote -v'|'git remote get-url origin'|'pwd'|'ls'|'claude plugin list'|'claude plugin list --json'| \
    'git rev-parse --abbrev-ref HEAD'|'git rev-parse --show-toplevel'|'git rev-parse --git-dir'|'git rev-parse --absolute-git-dir'|'git rev-parse HEAD')
      allow 'Onboard is running an approved read-only discovery command.' ;;
    'jq -e . .claude/settings.json'|'jq empty .claude/settings.json')
      allow 'Onboard is parsing the generated project settings without mutation.' ;;
  esac

  # Round-14 F29: the repo-relative spellings above are the documented ones, but two
  # consecutive runs reached for the absolute path first and ate a denial. One reissued it
  # repo-relative; the other dropped the permission audit entirely and reasoned that the
  # renderer's own settings parse covered it. An absolute path that resolves to the same
  # generated file is the same read, so name it rather than leaving the run to guess which
  # spelling the allowlist wants.
  #
  # Exact string comparison against "$cwd", never a `case` glob: cwd is data and may
  # contain pattern characters that would widen the match to paths outside the repository.
  if [ -n "$cwd" ] && { [ "$command" = "jq -e . $cwd/.claude/settings.json" ] ||
                        [ "$command" = "jq empty $cwd/.claude/settings.json" ]; }; then
    allow 'Onboard is parsing the generated project settings without mutation.'
  fi

  case "$command" in
    shasum\ -a\ 256\ *)
      if is_safe_shasum_command "$command"; then
        allow 'Onboard is hashing explicit repo-local preserve candidates.'
      fi
      deny 'Onboard shasum access is limited to explicit non-secret repo-local files with -a 256.' ;;
  esac

  if is_installed_discovery_checkpoint_invocation "$command"; then
    allow 'Onboard is recording the required post-report discovery checkpoint before writes.'
  fi
  case "$command" in
    *'/skills/onboard/scripts/discovery-checkpoint.sh'*)
      deny 'Onboard may invoke only the canonical installed discovery checkpoint with no arguments.' ;;
  esac

  case "$command" in
    'git ls-files'|'git ls-files '*)
      if is_safe_git_ls_files_command "$command"; then
        allow 'Onboard is listing repository-tracked paths for discovery.'
      fi
      deny 'Onboard git ls-files permits only read-only inventory flags and repo-local pathspecs; use native Glob for file discovery.' ;;
  esac

  case "$command" in
    'git check-ignore'|'git check-ignore '*)
      if is_safe_git_check_ignore_command "$command"; then
        allow 'Onboard is checking which repo-local paths the ignore rules cover.'
      fi
      deny 'Onboard git check-ignore permits only read-only reporting flags and repo-local, non-secret path operands.' ;;
  esac

  case "$command" in
    find|find\ *)
      if is_safe_find_command "$command"; then
        allow 'Onboard is running a narrowly parsed repo-local file or directory discovery fallback.'
      fi
      deny 'Onboard find fallback permits only find <repo-relative-root> [-maxdepth N] -type f|d inside the repository.' ;;
  esac

  # Read-only file discovery: allow only when every path argument stays inside the
  # repository and clear of protected secrets; otherwise deny (never a silent allow).
  case "$command" in
    'ls '*|'cat '*|'head '*|'tail '*|'wc '*|'grep '*|'rg '*)
      split_simple_shell_words "$command" || \
        deny 'Onboard read-only discovery rejects shell expansion and ambiguous path arguments.'
      path_argv=("${SIMPLE_WORDS[@]}")
      if bash_path_guard "${path_argv[0]}" "${path_argv[@]:1}"; then
        allow 'Onboard is running an approved read-only discovery command inside the repository.'
      fi
      deny 'Onboard read-only discovery must stay within the repository and avoid protected secret paths.' ;;
  esac

  case "$command" in
    'chmod +x .claude/hooks/skill-eval.sh')
      allow 'Onboard is finalizing the declared optional project hook.' ;;
  esac

  if is_installed_renderer_invocation "$command"; then
    allow 'Onboard is invoking its installed deterministic completion renderer.'
  fi
  # Fix 3 (e2e follow-up): SKILL.md prescribes `render-report.sh --cleanup` as the degraded-mode
  # (hook-less) cleanup step. Allow exactly that two-word canonical shape so it is not denied for
  # the very command the skill tells the agent to run.
  if is_installed_renderer_cleanup_invocation "$command"; then
    if lifecycle_guard_owns_cleanup; then
      deny 'The lifecycle guard owns cleanup for this active onboarding run; return renderer stdout and let Stop verify and clean proof.'
    fi
    allow 'Onboard is running the documented degraded-mode renderer cleanup.'
  fi
  case "$command" in
    *'/skills/onboard/scripts/render-report.sh'*)
      deny 'Onboard may invoke only the canonical installed renderer with the exact completion or --cleanup argument shape.' ;;
  esac

  # LC-037: onboarding never runs a project's own commands, so no validation command is
  # auto-allowed here. A project command reaches the normal permission prompt like anything else
  # outside the allowlist, and the installed renderer, which executes none of them, is the only
  # script this policy lets finalize a run.
  ask 'This command is outside the unattended onboarding allowlist and requires normal user review.'
}

case "$tool" in
  Read) check_path_tool file_path ;;
  Glob|Grep) check_path_tool path ;;
  Edit|Write) check_path_tool file_path ;;
  Bash) check_bash ;;
  *) ask 'This tool is outside the unattended onboarding allowlist.' ;;
esac
