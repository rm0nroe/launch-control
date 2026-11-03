#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"decision":"block","reason":"Launch Control completion guard requires jq; install jq and retry /onboard."}'
  exit 0
fi

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"

if [ -z "$session_id" ] || [[ ! "$session_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf '%s\n' '{"decision":"block","reason":"Launch Control completion guard received an invalid session identifier."}'
  exit 0
fi

# No repository means no run state to enforce, and blocking here locks the whole session out:
# the hooks outlive /onboard, and a deleted worktree cwd then fails every prompt. The renderer
# is the unbypassable gate, so stand down.
if [ -z "$cwd" ] || ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir)"
guard_tmp="$git_dir/launch-control-onboard-guard-$session_id-$$"
mkdir -p "$guard_tmp"
actual="$guard_tmp/actual"
expected="$guard_tmp/expected"
task_tmp="$guard_tmp/tasks"
trap 'rm -rf "$guard_tmp"' EXIT
state="$git_dir/launch-control-onboard-report.expected"
run_state="$git_dir/launch-control-onboard-run-$session_id.active"
baseline_state="$git_dir/launch-control-onboard-run-$session_id.baseline"
inventory_state="$git_dir/launch-control-onboard-run-$session_id.inventory"
# Required manifest paths that reach a file through a symlink. See symlinked_manifest_paths().
symlink_state="$git_dir/launch-control-onboard-run-$session_id.symlinked"
mode_state="$git_dir/launch-control-onboard-run-$session_id.mode"
task_state="$git_dir/launch-control-onboard-run-$session_id.tasks"
discovery_state="$git_dir/launch-control-onboard-run-$session_id.discovery"
disarmed_state="$git_dir/launch-control-onboard-run-$session_id.disarmed"
render_state="$git_dir/launch-control-onboard-run-$session_id.rendered"
emission_deny_state="$git_dir/launch-control-onboard-run-$session_id.emission-denies"
# Round-17: deny counter for the reviewer-lens shape check below, carrying the same
# circuit-breaker contract as emission denies and purged with them when /onboard re-arms.
lens_deny_state="$git_dir/launch-control-onboard-run-$session_id.lens-denies"
# Round-17: deny counter for the generated-guidance rules below, same circuit-breaker contract.
guidance_deny_state="$git_dir/launch-control-onboard-run-$session_id.guidance-denies"
# Round-31: deny counter for the prospective-CLAUDE.md render gate below, same contract again.
prospective_deny_state="$git_dir/launch-control-onboard-run-$session_id.prospective-denies"
# Round-31: and one for the reviewer-lens render gate. Deliberately NOT shared with
# lens_deny_state above: that budget belongs to the write-time rule, and a run that spent it
# failing to author a lens is exactly the run that still needs the render gate to catch it.
lens_render_deny_state="$git_dir/launch-control-onboard-run-$session_id.lens-render-denies"
# Round-14 F28: written by the unattended policy when the session runs under
# bypassPermissions, read by the renderer so the report itself records that the run was
# unreviewed. Purged with the rest of the family when a later /onboard re-arms.
bypass_state="$git_dir/launch-control-onboard-run-$session_id.bypass"
# Round-18: the raw permission mode the policy observed, so the renderer can name a mode that
# is neither `default` nor `bypassPermissions` instead of rendering it as an unremarked default.
# The GAP-3 `*.mode` stale glob below does NOT sweep this file -- the name ends in `-mode`, not
# `.mode` -- so it carries its own stale purge beside the `.bypass` one.
permission_mode_state="$git_dir/launch-control-onboard-run-$session_id.permission-mode"
discovery_report="$cwd/.launch-control-onboard/discovery-report.txt"
discovery_marker="$cwd/.launch-control-onboard/discovery-checkpoint"

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

# BEGIN ONBOARD_OPTIONAL_MANIFEST
onboard_optional_manifest() {
  cat <<'EOF_OPTIONAL'
.claude/commands/fix.md
.claude/hooks/skill-eval.sh
.mcp.json
EOF_OPTIONAL
}
# END ONBOARD_OPTIONAL_MANIFEST

onboard_required_manifest() {
  local mode=default
  [ ! -f "$mode_state" ] || mode="$(cat "$mode_state")"
  if [ "$mode" = launch-control ]; then
    onboard_launch_manifest
  else
    LC_ALL=C comm -23 <(onboard_default_manifest | LC_ALL=C sort -u) \
                      <(onboard_optional_manifest | LC_ALL=C sort -u)
  fi
}

deletion_dirty_required_paths() {
  git -C "$cwd" status --short --untracked-files=all |
    awk 'substr($0, 1, 2) ~ /D/ { record = substr($0, 4); sub(/^.* -> /, "", record); print record }' |
    LC_ALL=C sort -u |
    LC_ALL=C comm -12 - <(onboard_required_manifest | LC_ALL=C sort -u)
}

# A required manifest path can name a file that is not the file onboarding owns, when one of
# its ancestors is a symlink. Every other clobber protection misses this shape:
#
#   * unattended-policy.sh rejects a symlinked ancestor only when it escapes the REPOSITORY.
#     A link to another directory inside the same repository resolves to a path still under
#     $cwd, so confinement passes it.
#   * The dirty baseline is `git status` output, and git never reports a path THROUGH a
#     symlinked directory -- it reports the target under the target's own name. So the
#     manifest spelling is absent from the baseline, nothing pins it PRESERVED, and the write
#     proceeds.
#   * deletion_dirty_required_paths only matches a `D` status.
#
# Measured: a repository whose `.claude/skills/launch` was a tracked symlink into a
# subdirectory had that subdirectory's uncommitted SKILL.md silently overwritten, and
# `git status` printed the identical line before and after -- the loss left no trace.
#
# Onboarding owns the manifest path, not whatever the link points at, so an aliased path is
# treated as existing content: preserved, never written. Emit
# `manifest path<TAB>resolved target` for each one.
#
# $cwd is resolved with `pwd -P` too. Without that, a repository under a symlinked prefix
# (macOS puts every $TMPDIR there via /var -> /private/var) reports every manifest path as
# aliased, which would pin an entire ordinary run PRESERVED.
symlinked_manifest_paths() {
  local real_cwd path parent resolved target
  real_cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || return 0
  onboard_required_manifest | while IFS= read -r path; do
    [ -n "$path" ] || continue
    parent="$cwd/$(dirname "$path")"
    [ -d "$parent" ] || continue
    resolved="$(cd "$parent" 2>/dev/null && pwd -P)" || continue
    target="$resolved/$(basename "$path")"
    [ "$target" != "$real_cwd/$path" ] || continue
    case "$target" in
      "$real_cwd"/*) target="${target#"$real_cwd"/}" ;;
    esac
    printf '%s\t%s\n' "$path" "$target"
  done
}

deny_deletion_dirty_required() {
  local paths="$1"
  # `paste -sd ', '` CYCLES its delimiter list -- five paths joined as `a,b c,d e`. The joined
  # string is pasted straight into the `git restore --` recovery line this deny dictates, so
  # every multi-path block handed the user a command git rejects outright ("pathspec
  # 'a,b' did not match any file(s) known to git"). Correct only at exactly one path, which is
  # the only count any fixture used. A single space is the delimiter git wants.
  jq -cn --arg paths "$(printf '%s' "$paths" | paste -sd ' ' -)" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Onboarding is structurally blocked by a deletion-dirty required manifest path: " + $paths + ". The manifest requires each path to exist while the dirty baseline pins it PRESERVED, so no completion report can satisfy both. Emit the exact blocked protocol listing these paths, with recovery: git restore -- " + $paths + " (or commit the deletion), then rerun /onboard.")
    }
  }'
}

snapshot_path() {
  local scope="$1" path="$2" target="$cwd/$path" type hash executable=0
  if [ -L "$target" ] || [ -f "$target" ]; then
    if [ -L "$target" ]; then
      type=symlink
    else
      type=file
      [ ! -x "$target" ] || executable=1
    fi
    # Round-24: the same unguarded hash `guard_path_state` carried. The inventory snapshots every
    # BASELINE path, which comes straight off `git status`, so one dangling symlink there failed
    # `hash-object`, and under `set -euo pipefail` that killed the pipeline this runs in and left
    # a SHORT inventory -- which the caller below only tests for existence, so it is never rebuilt,
    # and the renderer derives its preserved-baseline rows from it.
    hash="$(git -C "$cwd" hash-object --no-filters "$target" 2>/dev/null)" || hash=''
    if [ -z "$hash" ]; then
      type=protected
      hash=protected
      executable=0
    fi
  elif [ -d "$target" ]; then
    type=directory
    hash=-
  elif [ -e "$target" ]; then
    type=other
    hash=-
  else
    type=absent
    hash=-
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$path" "$type" "$hash" "$executable"
}

capture_inventory() {
  local mode scope path
  mode=default
  [ ! -f "$mode_state" ] || mode="$(cat "$mode_state")"
  scope="$guard_tmp/inventory-scope"
  : > "$scope"
  if [ "$mode" = launch-control ]; then
    onboard_launch_manifest | while IFS= read -r path; do
      printf 'MANIFEST\t%s\n' "$path"
    done >> "$scope"
  else
    onboard_default_manifest | while IFS= read -r path; do
      printf 'MANIFEST\t%s\n' "$path"
    done >> "$scope"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'BASELINE\t%s\n' "$path"
  done < "$baseline_state" >> "$scope"

  LC_ALL=C sort -t $'\t' -k2,2 -k1,1 "$scope" |
    awk -F '\t' '
      {
        path = $2
        if (path != previous && NR > 1) {
          print (manifest && baseline ? "MANIFEST_BASELINE" : manifest ? "MANIFEST" : "BASELINE") "\t" previous
          manifest = baseline = 0
        }
        if ($1 == "MANIFEST") manifest = 1
        if ($1 == "BASELINE") baseline = 1
        previous = path
      }
      END {
        if (NR > 0) print (manifest && baseline ? "MANIFEST_BASELINE" : manifest ? "MANIFEST" : "BASELINE") "\t" previous
      }
    ' |
    while IFS=$'\t' read -r scope_name path; do
      snapshot_path "$scope_name" "$path"
    done > "$inventory_state"
}

# GAP-1: capture the workspace anchor (worktree status + content fingerprints) at the discovery
# checkpoint — before any project write or pre-render validation can mutate the tree — so the
# renderer reuses a trusted pre-onboarding snapshot instead of capturing lazily at first render,
# which a manually-run declared validation command could launder first. The byte format matches
# render-report.sh worktree_status()/current_path_state() so the renderer's reuse comparison is
# exact; the renderer still falls back to lazy capture when these files are absent (degraded mode).
# Round-13 F16: `git status --short` C-quotes any path holding a space, tab, quote, backslash, or
# non-ASCII byte. Both captures below strip the status prefix and treat what is left as a real
# path, so a quoted spelling silently poisons the anchor the renderer trusts: guard_path_state
# stats a name that cannot exist and records `absent`, and capture_preserve_hashes' `[ -f ]` test
# fails and skips the path, leaving it with no hash row to verify against. Twin of the renderer's
# unquote_git_path -- these scripts share no library, exactly as guard_path_state twins
# current_path_state. See render-report.sh for why `%b` alone cannot do this.
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

guard_path_state() {
  local target="$cwd/$1" type hash executable=0
  if [ -L "$target" ] || [ -f "$target" ]; then
    if [ -L "$target" ]; then
      type=symlink
    else
      type=file
      [ ! -x "$target" ] || executable=1
    fi
    # Round-24: this hash was unguarded, and `git hash-object` fails on any path it cannot open --
    # a DANGLING symlink and a symlink to a directory are both ordinary untracked entries that
    # `git status` reports, and an unreadable file is another. Under `set -euo pipefail` that
    # failure killed the process substitution the caller reads from, which aborted the anchor
    # capture mid-loop and left a TRUNCATED fingerprint file behind -- the same false
    # `Untouched pre-existing ... captured and verified` claim as the hook-timeout kill, reachable
    # on any repository holding one broken link. The renderer's `current_path_state` twin has
    # always absorbed this into `protected`; mirror it exactly, so the two captures still agree
    # path for path and a protected entry routes to disclosure instead of reading as drift.
    hash="$(git -C "$cwd" hash-object --no-filters "$target" 2>/dev/null)" || hash=''
    if [ -z "$hash" ]; then
      type=protected
      hash=protected
      executable=0
    fi
  elif [ -d "$target" ]; then
    type=directory
    hash=-
  elif [ -e "$target" ]; then
    type=other
    hash=-
  else
    type=absent
    hash=-
  fi
  printf '%s\t%s\t%s\n' "$type" "$hash" "$executable"
}

capture_run_anchor() {
  local anchor_dir="$cwd/.launch-control-onboard"
  local status_file="$anchor_dir/worktree-status.start"
  local fingerprint_file="$anchor_dir/worktree-status.start.fingerprints"
  # Round-24: both anchor files are built under `.partial` names and moved into place only after
  # the last row is written, so their EXISTENCE means COMPLETENESS. The fingerprint file used to
  # be appended to IN PLACE, and this is exactly the call the PreToolUse timeout kills on a large
  # repository -- measured at 601,505ms against the 600,000ms ceiling on three consecutive
  # acceptance runs. The next invocation then early-returned on the truncated file (the test
  # below asked whether it EXISTED, never whether it was complete) and the renderer printed
  # `Untouched pre-existing (14,697): ... every path above was captured and verified` over an
  # anchor holding an unknowable fraction of them. Proven with a control: a mutation to a path
  # present in the status file but cut from the fingerprints rendered a report that LISTED that
  # path as untouched, while the same mutation against a complete anchor blocked the render.
  local partial_status="$status_file.partial"
  local partial_file="$fingerprint_file.partial"
  local unrepresentable_file="$anchor_dir/worktree-status.start.unrepresentable"
  local partial_unrepresentable="$unrepresentable_file.partial"
  # Capture once per run: a later checkpoint re-invocation must never reset the anchor
  # after writes have begun. A leftover `.partial` means an earlier capture was killed, and it is
  # NOT rebuilt here either: the discovery attestation that gates every project write is granted
  # immediately before this call, so a rebuild now would re-anchor on a tree the run may already
  # have written to and launder its own changes into the baseline. Leave it for the renderer,
  # which refuses to render rather than claim anything about paths it never fingerprinted.
  [ ! -e "$status_file" ] && [ ! -e "$fingerprint_file" ] &&
    [ ! -e "$partial_status" ] && [ ! -e "$partial_file" ] || return 0
  mkdir -p "$anchor_dir"
  # The marker goes up FIRST, so every step below is covered by the refusal above.
  : > "$partial_file"
  : > "$partial_unrepresentable"
  git -C "$cwd" status --short --untracked-files=all -- . ':(exclude).launch-control-onboard/**' |
    LC_ALL=C sort > "$partial_status"
  # Round-24: this loop forked TWICE per path -- `git hash-object` inside `guard_path_state` and
  # again for the `< <(...)` process substitution -- over one line per STATUS path, not per
  # managed path. A repository carrying an untracked `.venv/` produces 14,734 of them, so ~29k
  # processes inside a hook with a 600-second ceiling. Same fork-per-path class `cb2c44b` batched
  # out of the renderer's preserved-content verification. Classify with shell builtins (no fork),
  # hash the whole batch through ONE `git hash-object --stdin-paths`, and keep the per-path
  # routine for exactly what the batch cannot answer, so its results stay byte-identical.
  local anchor_class="$guard_tmp/anchor-class"
  local anchor_batch="$guard_tmp/anchor-batch"
  local anchor_hashes="$guard_tmp/anchor-hashes"
  local anchor_paired="$guard_tmp/anchor-paired"
  : > "$anchor_class"
  : > "$anchor_batch"
  : > "$anchor_hashes"
  : > "$anchor_paired"
  local record path target type hash executable
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    unquote_git_path "${record:3}"
    path="$unquoted_path"
    [ -n "$path" ] || continue
    # A decoded path holding a NEWLINE cannot be a record in a line-oriented file: the single row
    # written below would occupy as many physical lines as the name has segments, and every
    # consumer that reads `$1` per line then treats the fragments as paths of their own. Found on
    # toolshed, where one zero-byte file named from a botched heredoc became three anchor rows,
    # each fingerprinted `absent` at render time against `file` here, and the renderer blocked the
    # run with "the workspace changed outside the declared writes of this run" over commands that had written nothing.
    #
    # Keep git's own C-quoted spelling, which is single-line by construction, in a sidecar the
    # renderer discloses. Excluding it silently would be the same lie in the other direction: the
    # run genuinely cannot verify this path, and must say so.
    if [ "$path" != "${path%%$'\n'*}" ]; then
      printf '%s\n' "${record:3}" >> "$partial_unrepresentable"
      continue
    fi
    target="$cwd/$path"
    executable=0
    # Batch only what `guard_path_state` would resolve with `git hash-object`, and only when the
    # batch can carry it: `--stdin-paths` is newline-delimited, so a path holding a newline is not
    # expressible there, and an unreadable path would abort the stream and cost every LATER path
    # its hash too. `[ -r ]`, `[ -f ]`, `[ -L ]` and `[ -x ]` are builtins -- no fork. A symlink
    # is batchable only when it resolves to a regular file, because that is the only case where
    # `git hash-object` (which opens through the link) succeeds; a symlink keeps executable=0
    # exactly as the per-path routine leaves it.
    if [ -f "$target" ] && [ -r "$target" ] && [ "$path" = "${path%%$'\n'*}" ]; then
      if [ -L "$target" ]; then
        type=symlink
      else
        type=file
        [ ! -x "$target" ] || executable=1
      fi
      printf '%s\n' "$path" >> "$anchor_batch"
      printf '%s\t%s\t\t%s\n' "$path" "$type" "$executable" >> "$anchor_class"
    else
      IFS=$'\t' read -r type hash executable < <(guard_path_state "$path")
      printf '%s\t%s\t%s\t%s\n' "$path" "$type" "$hash" "$executable" >> "$anchor_class"
    fi
  done < "$partial_status"
  if [ -s "$anchor_batch" ]; then
    git -C "$cwd" hash-object --no-filters --stdin-paths < "$anchor_batch" \
      > "$anchor_hashes" 2>/dev/null || true
  fi
  # `--stdin-paths` emits one hash per line in the order it was given and ABORTS on the first
  # path it cannot open, so a short output is the only way the batch loses a path -- and it loses
  # every path after that one as well. Never pair by position without proving the counts match:
  # a race that removes one path mid-capture would otherwise shift every later path onto its
  # neighbour's hash, which reads as a whole worktree of content drift.
  if [ "$(wc -l < "$anchor_batch")" -eq "$(wc -l < "$anchor_hashes")" ]; then
    paste "$anchor_batch" "$anchor_hashes" > "$anchor_paired"
  else
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      IFS=$'\t' read -r type hash executable < <(guard_path_state "$path")
      printf '%s\t%s\n' "$path" "$hash" >> "$anchor_paired"
    done < "$anchor_batch"
  fi
  # Key the two-file pass on FILENAME, never on NR == FNR: an empty pair file makes NR == FNR
  # true for the SECOND file too, which would load the class rows into the hash map and emit
  # nothing at all.
  awk -F '\t' -v OFS='\t' -v pairedfile="$anchor_paired" '
    FILENAME == pairedfile { anchor_hash[$1] = $2; next }
    { print $1, $2, ($3 == "" ? anchor_hash[$1] : $3), $4 }
  ' "$anchor_paired" "$anchor_class" > "$partial_file"
  mv "$partial_status" "$status_file"
  mv "$partial_file" "$fingerprint_file"
  # Published last and under the same rename discipline: its existence means the capture ran to
  # completion, so an empty file is the positive statement "no unrepresentable path was seen"
  # rather than "nobody looked".
  mv "$partial_unrepresentable" "$unrepresentable_file"
}

# GAP-2: at the same pre-write moment the guard captures its manifest inventory, capture a
# trusted sha256 inventory of the dirty baseline paths (the untracked/pre-existing files the run
# promises to leave untouched). The renderer prefers this guard-captured copy over the
# agent-supplied preserve-hashes.txt, whose timing is unenforced; the agent file remains the
# degraded-mode fallback when hooks are not registered.
guard_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

capture_preserve_hashes() {
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || return 0
  [ -f "$baseline_state" ] || return 0
  local anchor_dir="$cwd/.launch-control-onboard"
  local guard_hashes="$anchor_dir/preserve-hashes.guard.txt"
  [ ! -e "$guard_hashes" ] || return 0
  mkdir -p "$anchor_dir"
  local path target digest
  : > "$guard_hashes"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    target="$cwd/$path"
    { [ -f "$target" ] && [ ! -L "$target" ]; } || continue
    digest="$(guard_sha256 "$target")" || continue
    printf '%s  %s\n' "$digest" "$path" >> "$guard_hashes"
  done < "$baseline_state"
}

# Round-15 F32: the renderer compares the prospective generated block against the on-disk
# CLAUDE.md byte-for-byte, but that comparison is satisfiable from EITHER side. A run that
# rewrites the prospective block after writing CLAUDE.md leaves two files that genuinely
# match -- byte-indistinguishable from honest regeneration -- so no content-based check can
# ever separate the two. Only provenance can, so record the order in which this run wrote
# the two governed paths. The renderer requires the last prospective write to PRECEDE the
# last CLAUDE.md write; a post-hoc rewrite inverts that and cannot be laundered by content.
# Recorded after every deny above, so a blocked write (which never happened) is never counted.
record_write_order() {
  local raw="$1" rel
  case "$raw" in
    "$cwd"/*) rel="${raw#"$cwd"/}" ;;
    /*) return 0 ;;
    ./*) rel="${raw#./}" ;;
    *) rel="$raw" ;;
  esac
  case "$rel" in
    CLAUDE.md|.launch-control-onboard/prospective-claude.md) ;;
    *) return 0 ;;
  esac
  local anchor_dir="$cwd/.launch-control-onboard"
  local order_file="$anchor_dir/write-order.guard.txt"
  # A symlinked record is attacker-shaped, not degraded: refuse to extend it and let the
  # renderer's own symlink rejection fail the render rather than appending through the link.
  [ ! -L "$order_file" ] || return 0
  mkdir -p "$anchor_dir"
  local seq=1
  if [ -f "$order_file" ]; then
    seq="$(( $(grep -c '' "$order_file" 2>/dev/null || printf 0) + 1 ))"
  fi
  printf '%s\t%s\n' "$seq" "$rel" >> "$order_file"
}

validate_discovery_report() {
  [ -f "$discovery_report" ] && [ ! -L "$discovery_report" ] || return 1
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
        # Round-33: mirrors the schema in discovery-checkpoint.sh, which gained this header with
        # the Phase 0 freshness gate. Only the HEADER is checked here. Whether every comparable
        # document was accounted for, and whether any verdict reads `contradicts`, belongs to the
        # checkpoint alone -- it is the gate that must refuse before the first write, and a report
        # that never passed it cannot carry the attestation this guard requires anyway. The two
        # copies of this awk stay identical on purpose; a looser one here is a silent divergence.
        # No apostrophes in this comment: it lives inside a single-quoted awk program.
        if (line[i] == "Preserved doc freshness:") { freshness_header++; in_sources = 0 }
        else if (line[i] == "Sources used:") { sources_header++; in_sources = 1 }
        else if (in_sources && line[i] ~ /^  [^[:space:]].* -> [^[:space:]].*$/) sources++
      }
      if (project != 1 || stack != 1 || monorepo != 1 || branch != 1 || ci != 1 ||
          existing_header != 1 || claude != 1 || settings != 1 || agents != 1 ||
          skills != 1 || commands != 1 || mcp != 1 || sources_header != 1 || sources < 1 ||
          freshness_header != 1) exit 1
    }
  ' "$discovery_report"
}

discovery_report_hash() {
  guard_sha256 "$discovery_report"
}

verify_discovery_attestation() {
  local expected_hash marker_hash
  validate_discovery_report || return 1
  [ -f "$discovery_state" ] && [ ! -L "$discovery_state" ] || return 1
  expected_hash="$(cat "$discovery_state")"
  [ -n "$expected_hash" ] || return 1
  [ "$(discovery_report_hash)" = "$expected_hash" ] || return 1
  [ -f "$discovery_marker" ] && [ ! -L "$discovery_marker" ] || return 1
  marker_hash="$(awk -F '\t' 'NR == 1 && $1 == "phase-0-discovery-complete" { print $2 }' "$discovery_marker")"
  [ "$marker_hash" = "$expected_hash" ]
}

# Round-5: shared transcript scan for the standalone discovery-report emission. Returns 0
# (missing) only when the harness supplied a readable transcript AND no assistant message
# contains both report markers; returns 1 (satisfied / unknowable) otherwise, so callers
# fail open without a transcript. Per-line tolerant parse (-R + fromjson?): one malformed
# JSONL line must not wipe the rest of the transcript text. Content may be an array of
# blocks or a bare string.
discovery_emission_missing() {
  local transcript_path transcript_assistant_text
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
  [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ ! -L "$transcript_path" ] || return 1
  transcript_assistant_text="$guard_tmp/assistant-text"
  jq -rR '
    fromjson?
    | select(.type == "assistant")
    | .message.content
    | if type == "array" then (.[] | select(type == "object" and .type == "text") | .text)
      elif type == "string" then .
      else empty end
  ' "$transcript_path" > "$transcript_assistant_text" 2>/dev/null || true
  # Round-7: the mandatory discovery-checkpoint.sh invocation re-emits the full report on
  # stdout, and that tool result is rendered to the user in the session — accept it as the
  # visible emission. Thinking-heavy model modes can produce tool-only messages with no
  # text parts at all, so assistant-text emission cannot be the only accepted form.
  jq -rR '
    fromjson?
    | select(.type == "user")
    | .message.content
    | if type == "array" then
        (.[] | select(type == "object" and .type == "tool_result") | .content
          | if type == "array" then (.[] | select(type == "object" and .type == "text") | .text)
            elif type == "string" then .
            else empty end)
      else empty end
  ' "$transcript_path" >> "$transcript_assistant_text" 2>/dev/null || true
  if ! grep -Fq '=== Workspace Discovery Report ===' "$transcript_assistant_text" ||
     ! grep -Fq '=== End Workspace Discovery Report ===' "$transcript_assistant_text"; then
    return 0
  fi
  return 1
}

# Round-37: every write-time gate below extracted `.tool_input.content`, and only a `Write`
# payload carries that field. An `Edit` carries `old_string`/`new_string` instead, so the
# extraction yielded the empty string and the rule skipped itself — silently, with no deny and
# no diagnostic. Live on rymonroe.com (run 255c3163) all six generated-guidance mutations were
# Edits, the round-17 `code-review` rule never saw one of them, and render-report.sh refused
# with `generated guidance contains stale exact skill name code-review` — precisely the burned
# render the rule exists to prevent. Round-35 FIX B only appeared to work in round 36 because
# that run wrote a file which did not exist yet; on an already-onboarded repository Edit is the
# natural tool, so all three gates were one tool choice away from the renderer backstop.
#
# Prints the content the tool call WOULD leave on disk. Returns non-zero when that cannot be
# resolved with certainty — an unrecognized payload shape, or an Edit whose old_string is not in
# the file on disk (which the harness will reject anyway). A caller that cannot resolve content
# stands down to the renderer rather than judging a guess, the same contract every other
# not-yet-decidable branch in this file follows.
#
# The replacement is literal, never a regex: jq's split/1 takes a plain string, so splitting on
# old_string and rejoining is byte-for-byte what Edit does, and a `.` or `[` in the prose can
# never become a metacharacter. The on-disk side is staged through a file and read with
# `--rawfile` because `$( )` strips trailing newlines, and an old_string anchored at the end of
# the file needs them intact.
#
# Both branches go through split/join and NOTHING here uses an index. That is load-bearing, not
# style: jq's `index/1` on a string returns a BYTE offset while `$s[a:b]` slices by CODEPOINT, so
# the obvious `$s[0:$at] + $new + $s[($at + ($old|length)):]` splices N characters late on any
# file holding N multi-byte characters before the match. Caught replaying the three real Edits
# from rymonroe.com run 3642a3b0 against launch/SKILL.md, whose em-dashes shifted the cut mid-
# word and produced `dua<new>ll.` — the ASCII-only fixtures could not see it. Replacing only the
# first occurrence is `$parts[0] + $new + ($parts[1:] | join($old))`: the tail is rejoined with
# the ORIGINAL old_string, so every later occurrence survives untouched.
resolved_write_content() {
  local target="$1" disk_file="$guard_tmp/resolve-disk"
  case "$target" in
    /*) ;;
    *) target="$cwd/$target" ;;
  esac
  if [ -f "$target" ]; then
    cat "$target" > "$disk_file" 2>/dev/null || return 1
  else
    : > "$disk_file"
  fi
  printf '%s' "$input" | jq -r --rawfile disk "$disk_file" '
    def literal_replace($s; $old; $new; $all):
      if ($old | length) == 0 then error("empty old_string")
      else ($s | split($old)) as $parts
        | if ($parts | length) < 2 then error("old_string absent")
          elif $all then ($parts | join($new))
          else $parts[0] + $new + ($parts[1:] | join($old))
          end
      end;
    .tool_input as $write
    | if ($write.content | type) == "string" then $write.content
      elif ($write.edits | type) == "array" then
        reduce $write.edits[] as $edit ($disk;
          literal_replace(.; $edit.old_string // ""; $edit.new_string // "";
            ($edit.replace_all // false)))
      elif ($write.old_string | type) == "string" then
        literal_replace($disk; $write.old_string; $write.new_string // "";
          ($write.replace_all // false))
      else error("unrecognized write payload")
      end
  ' 2>/dev/null
}

# Round-17: the reviewer-lens shape was enforced only by render-report.sh, the terminal
# operation. A malformed bullet therefore cost a whole render — on a repository whose gates
# take minutes, ~20 minutes and a full re-run of the validation suite — and the run had to
# reconstruct the bullet long after the authoring context was gone. The rule is decidable the
# moment the file is written, so decide it there. The renderer keeps its own copy: this hook is
# advisory infrastructure a degraded session may not run, and only the renderer check is
# unbypassable. Decided against the content the write would LEAVE on disk, so an Edit is judged
# exactly as a Write is — see resolved_write_content() above.
#
# Echoes the reason a lens is malformed and returns 0; returns 1 when the lens is well-formed.
# The reason must always name the accepted form — a guard that says only "wrong" while nothing
# says "right" is the round-11 deadlock shape.
reviewer_lens_shape_error() {
  local content_file="$1" bullets bullet evidence_path
  if grep -Fq 'DETECTED_REVIEW_LENS' "$content_file"; then
    printf '%s' 'it still contains the unresolved DETECTED_REVIEW_LENS token'
    return 0
  fi
  if ! grep -Fqx '## Project-specific review lens' "$content_file"; then
    printf '%s' 'it has no `## Project-specific review lens` section'
    return 0
  fi
  bullets="$(awk '
    /^## Project-specific review lens$/ { in_lens = 1; next }
    in_lens && /^## / { exit }
    in_lens && /^- / { print }
  ' "$content_file")"
  if [ "$(printf '%s\n' "$bullets" | grep -c '^- ')" -lt 2 ]; then
    printf '%s' 'the lens has fewer than two bullets'
    return 0
  fi
  while IFS= read -r bullet; do
    [ -n "$bullet" ] || continue
    if ! printf '%s\n' "$bullet" | grep -Eq '^- .*Evidence: `[^`]+`\.$'; then
      printf 'this bullet does not end with exactly one evidence path: "%s"' "${bullet:0:80}"
      return 0
    fi
    evidence_path="$(printf '%s\n' "$bullet" | sed -E 's/^.*Evidence: `([^`]+)`\.$/\1/')"
    [ "$evidence_path" = 'Phase 0 discovery' ] && continue
    case "$evidence_path" in
      /*|../*|*/../*|*/..|./*|*/./*)
        printf 'the evidence path "%s" is not canonical repo-relative' "$evidence_path"
        return 0
        ;;
    esac
    if [ ! -f "$cwd/$evidence_path" ]; then
      printf 'the evidence path "%s" does not exist' "$evidence_path"
      return 0
    fi
  done <<EOF
$bullets
EOF
  return 1
}

# Round-17: the reviewer lens was not the only rule the renderer decided at the terminal
# operation. Two SIBLING rules about generated guidance prose burned a full render each on
# target repo A in one session — `generated guidance omits project-code-review` and
# `generated guidance names a runner spelling the generated sandbox denies` — and both are
# decidable the moment the prose is written. Same contract as the lens check: the guard is
# advisory (a degraded session runs no hook), so the renderer keeps its unbypassable copy;
# this only moves WHEN the run finds out, from after the whole validation suite to the write.
#
# Both rules depend on state the run produces as it goes — the generated review skill, the
# generated settings.json, the declared validation commands. When that state is not there yet
# the rule is not yet decidable, so it stays silent and the renderer decides it. Enforcing a
# rule whose inputs have not been written would deny a write for a contract the run has not
# reached, which is the round-11 deadlock shape.
#
# Echoes why the guidance is wrong and returns 0; returns 1 when it is acceptable (or not yet
# decidable). The reason always names the accepted form, never only the rejected one.
generated_guidance_error() {
  local guidance_path="$1" content_file="$2" declared runner_tool declared_list
  # LC-002: a merged CLAUDE.md keeps the user's own prose around the generated block, and that
  # prose is not the run's to rewrite. Judge only the block, the span render-report.sh compares
  # against the prospective block. Before the block exists the whole write is the run's own.
  if [ "$guidance_path" = CLAUDE.md ] && grep -Fqx '## Generated Quick Reference' "$content_file"; then
    awk '
      $0 == "## Generated Quick Reference" { in_block = 1 }
      in_block && /^# / { exit }
      in_block { print }
    ' "$content_file" > "$content_file.block"
    content_file="$content_file.block"
  fi
  case "$guidance_path" in
    CLAUDE.md|.claude/skills/launch/SKILL.md)
      if [ -f "$cwd/.claude/skills/project-code-review/SKILL.md" ] ||
        { [ -f "$inventory_state" ] &&
          grep -Fq '.claude/skills/project-code-review/SKILL.md' "$inventory_state"; }; then
        if grep -Fq '`code-review`' "$content_file"; then
          printf '%s' 'it names the review skill `code-review`, the pre-rename spelling. This run generates `.claude/skills/project-code-review/SKILL.md`, so every reference must read `project-code-review`'
          return 0
        fi
        if ! grep -Fq '`project-code-review`' "$content_file"; then
          printf '%s' 'it never names `project-code-review`. This run generates `.claude/skills/project-code-review/SKILL.md`, and this surface is where a reader is told the review skill exists, so it must name it in backticks'
          return 0
        fi
      fi
      ;;
  esac
  # Round-37: the runner-spelling rule that lived here is gone, along with the renderer's copy of
  # it. It required `.sandbox.enabled == true` in the project's settings, and onboarding stopped
  # generating that key in round 36, so it could only fire against a sandbox the user configured
  # themselves -- refusing guidance that is correct for anyone who never asked to be sandboxed.
  # The `project-code-review` naming rule above is unrelated and stays; that is the one which has
  # actually fired in a live run.
  return 1
}

# Round-31: the renderer refuses a completion render when the ledger carries CLAUDE.md as
# CREATED|MERGED|PRESERVED and .launch-control-onboard/prospective-claude.md is absent
# (render-report.sh:1443). Live on toolshed run 287e4c0e the run wrote the prospective block
# only after being told, then re-rendered. SKILL.md already requires that write in the phase
# before Launch renders, unconditionally and with no exemption for a run heading for
# PRESERVED, so the refusal was correct and the run was simply out of order.
#
# Round-32 correction: this gate saves NO render time, and the round-31 comment that claimed it
# did was wrong. The renderer's own check is at render-report.sh:1443 while declared-command
# execution does not begin until :1721, so the renderer refuses this pair before running a
# single declared command -- measured twice against rymonroe.com at 313 ms and 385 ms. The
# "8m12s burned render" round-31 cited was the whole /onboard RUN (8m06s from session start to
# the refusal), misattributed to the render. What this gate actually buys is the remediation
# text below -- an exact write order instead of a bare `exit 1` -- and finding out one tool call
# earlier. The renderer keeps its unbypassable copy, because a degraded session runs no hook.
#
# Decided from the ledger the invocation itself names. The renderer takes the ledger as its
# first positional argument and requires it inside $PWD/.launch-control-onboard, so extract that
# token and normalize it exactly as normalize_control_file() does. Every step that cannot be
# completed with certainty returns 1: an unparsable command, a token outside the control
# directory, a ledger not yet on disk, a symlinked one, or a ledger that does not carry
# CLAUDE.md all mean the rule is NOT YET DECIDABLE. A rule that cannot decide must stand down
# to the renderer rather than deny a contract the run has not reached -- the round-11 deadlock
# shape, which is exactly what the guidance rules above are shaped to avoid.
# The ledger is the renderer's first positional argument. Printed rather than tested so every
# gate that needs to know what THIS RUN wrote — as opposed to what merely exists on disk — reads
# it the same way. Returns non-zero on any spelling it cannot resolve, leaving the caller with
# no option but to stand down.
render_ledger_path() {
  local command="$1" renderer_path="$2" quoted_renderer tail_after ledger_token ledger_path
  quoted_renderer="\"$renderer_path\""
  case "$command" in
    *"$quoted_renderer"*) tail_after="${command#*"$quoted_renderer"}" ;;
    *"$renderer_path"*) tail_after="${command#*"$renderer_path"}" ;;
    *) return 1 ;;
  esac
  # Leading whitespace off, then the first token. A single-quoted ledger path containing spaces
  # splits wrong here and lands on a path that does not exist, which the existence test below
  # turns into a stand-down rather than a wrong deny.
  tail_after="${tail_after#"${tail_after%%[![:space:]]*}"}"
  ledger_token="${tail_after%%[[:space:]]*}"
  case "$ledger_token" in
    \"*\") ledger_token="${ledger_token#\"}"; ledger_token="${ledger_token%\"}" ;;
    \'*\') ledger_token="${ledger_token#\'}"; ledger_token="${ledger_token%\'}" ;;
  esac
  case "$ledger_token" in
    "$cwd/.launch-control-onboard/"*) ledger_path="$ledger_token" ;;
    .launch-control-onboard/*) ledger_path="$cwd/$ledger_token" ;;
    *) return 1 ;;
  esac
  case "/$ledger_path/" in */../*|*/./*) return 1 ;; esac
  { [ -f "$ledger_path" ] && [ ! -L "$ledger_path" ]; } || return 1
  printf '%s\n' "$ledger_path"
}

# True only when the ledger records `path` as written by this run. The renderer's own predicate
# (render-report.sh `doc_generated_this_run`), so the two agree on which files each may judge.
ledger_generated_this_run() {
  local ledger_path="$1" path="$2"
  awk -F '\t' -v p="$path" '($1 == "CREATED" || $1 == "MERGED") && $2 == p { found = 1 } END { exit !found }' \
    "$ledger_path"
}

prospective_claude_missing() {
  local command="$1" renderer_path="$2" ledger_path
  ledger_path="$(render_ledger_path "$command" "$renderer_path")" || return 1
  awk -F '\t' '$2 == "CLAUDE.md" && $1 ~ /^(CREATED|MERGED|PRESERVED)$/ { found = 1 } END { exit !found }' \
    "$ledger_path" || return 1
  # The renderer's own predicate, so the guard denies precisely the case it would reject with
  # "generated block is missing" and leaves its symlink and content rules to it.
  [ ! -f "$cwd/.launch-control-onboard/prospective-claude.md" ] || return 1
  return 0
}

case "$event" in
  UserPromptSubmit)
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty')"
    if [[ "$prompt" =~ ^[[:space:]]*/onboard([[:space:]]|$) ]]; then
      rm -f "$state" "$run_state" "$baseline_state" "$inventory_state" "$symlink_state" "$mode_state" "$task_state" "$discovery_state" "$disarmed_state" "$render_state" "$emission_deny_state" "$lens_deny_state" "$guidance_deny_state" "$prospective_deny_state" "$lens_render_deny_state" "$bypass_state" "$permission_mode_state"
      # GAP-3 (e2e follow-up): purge stale mode markers from abandoned cross-session runs, not
      # just this session's. A run that ended without a terminal (crash, closed tab) leaves its
      # launch-control-onboard-run-<session>.mode behind; without this glob they accumulate in
      # .git across sessions. A concurrent second onboarding in the same repo is already
      # unsupported (render-report.sh rejects multiple active runs).
      for stale_mode in "$git_dir"/launch-control-onboard-run-*.mode; do
        [ ! -e "$stale_mode" ] || rm -f "$stale_mode"
      done
      # Round-16 F34b: `.bypass` markers accumulate across sessions exactly as `.mode` markers
      # did. The renderer never noticed because it reads only the ACTIVE session's marker, but
      # the discovery checkpoint reports the mode before any `.active` marker exists — the
      # `.active` file is not stamped until the first Edit/Write, which the checkpoint gates.
      # Without this purge an abandoned bypass run would make a later default-mode run disclose
      # a bypass the renderer then denies, manufacturing the very report-contradicts-prose
      # conflict that F34a refuses to let a second render resolve. The policy re-stamps this
      # session's marker on its next PreToolUse, so clearing all of them loses nothing.
      for stale_bypass in "$git_dir"/launch-control-onboard-run-*.bypass; do
        [ ! -e "$stale_bypass" ] || rm -f "$stale_bypass"
      done
      # Round-18: the recorded permission mode is a per-run fact for the same reason the bypass
      # marker is, and an abandoned run's marker would otherwise be the only mode record a later
      # run in this repository could find. The policy re-stamps it on its next PreToolUse.
      for stale_permission_mode in "$git_dir"/launch-control-onboard-run-*.permission-mode; do
        [ ! -e "$stale_permission_mode" ] || rm -f "$stale_permission_mode"
      done
      # Round-35: each glob above names ONE suffix, but a run mints sixteen, and the renderer's
      # own reaper (render-report.sh reap_stale_run_markers) enumerates families through their
      # `.active` marker. A fragment whose family never got one is therefore unreachable by every
      # purge in the pack: the discovery attestation is written before the first gated write
      # stamps `.active`, and a deny counter is spent by runs that never render. Both were found
      # accumulating live in .git after run 266d8e60 -- inert, but forever, at one or two files
      # per abandoned run. Fixing this by adding two more suffix globs would repeat the mistake
      # that made it, so the condition is the absence of the family's `.active` marker, which is
      # precisely "no run owns this fragment" and needs no suffix list at all.
      #
      # `.active` markers survive this loop without a special case, because an `.active` file is
      # its own family key and so always answers the ownership test below in the affirmative. An
      # explicit `case` skip was written first and no mutation could kill it. That survival is
      # the point rather than an accident: a genuinely concurrent run holds a fresh `.active`,
      # and deleting its family mid-flight is the silent takeover that the renderer's reaper
      # refuses to perform even when the clock says the run looks stale. Abandoned `.active`
      # families remain that reaper's job, where the in-flight check already lives.
      # The docs-create invocation proof is keyed by the same session id and orphans the same
      # way -- the renderer deletes it on a successful render and nothing else ever does.
      for stale_fragment in "$git_dir"/launch-control-onboard-run-*.* \
                            "$git_dir"/launch-control-bootstrap-docs-*.proof; do
        [ -e "$stale_fragment" ] || continue
        # Round-37: `.disarmed` is the one fragment the ownership test below cannot protect, and
        # the one that is not an inert record. The Stop terminal removes `$run_state` and stamps
        # `$disarmed_state` in the same breath (:1539-1540), so a disarmed family is ALWAYS
        # ownerless by construction -- "no run owns this fragment" is true of every disarmed run
        # that ever completed here, including one whose session is still open. And line 933 reads
        # this file as that session's off switch, so deleting it re-arms every retained hook: the
        # next Edit/Write reaches verify_discovery_attestation, which cannot pass because Stop
        # already removed $discovery_state and .launch-control-onboard/. Measured with a control -- a
        # disarmed session's Write is allowed, a foreign session sends /onboard, and the same
        # Write is then denied and told to produce a Phase 0 discovery report for a run that is
        # over. Two sessions were live in one repository when this shipped, so the collateral is
        # ordinary, not exotic.
        #
        # Unlike the `.active` skip deleted in round 36, this one is observable: `.active` is its
        # own family key and so always answered the ownership test in the affirmative, whereas
        # `.disarmed` always answers it in the negative. Dead code there, load-bearing here.
        #
        # This session's OWN `.disarmed` is still cleared -- :839 names $disarmed_state
        # explicitly, ahead of every glob here -- so re-arming loses nothing. What accumulates is
        # one empty file per successful run per repository, cleared by the next /onboard in that
        # session. That is not the unbounded abandoned-run growth this sweep exists to stop.
        case "$stale_fragment" in
          *.disarmed) continue ;;
        esac
        fragment_session="${stale_fragment##*/}"
        # Strip the suffix, not the session id: a session id may itself contain dots, and `%.*`
        # removes only the last component, which is always the marker suffix.
        fragment_session="${fragment_session%.*}"
        fragment_session="${fragment_session#launch-control-onboard-run-}"
        fragment_session="${fragment_session#launch-control-bootstrap-docs-}"
        [ -e "$git_dir/launch-control-onboard-run-$fragment_session.active" ] ||
          rm -f "$stale_fragment"
      done
      # LC-047: the same markers under their pre-rename names. Nothing reads those names any
      # more, `.disarmed` included, so no session can be re-armed by removing one: the whole
      # family goes, along with the old proof, report and timing files.
      for legacy_fragment in "$git_dir"/groundwork-onboard-run-*.* "$git_dir"/groundwork-bootstrap-docs-*.proof \
                             "$git_dir"/groundwork-onboard-report.expected "$git_dir"/groundwork-onboard-render-timing.txt; do
        [ ! -f "$legacy_fragment" ] || [ -L "$legacy_fragment" ] || rm -f "$legacy_fragment"
      done
      # Round-23: $guard_tmp is removed by an EXIT trap, which a SIGKILL never runs -- and a hook
      # that exceeds the harness timeout is killed, not signalled. Measured live: one PreToolUse
      # invocation ran 601,506ms against the 600,000ms ceiling and left its scratch directory in
      # .git, where nothing reaped it, because until now the creation site was the only place in
      # the pack that named launch-control-onboard-guard-*. The mkdir on line 27 also precedes the
      # trap on line 31, so a kill inside that window leaks the same way; both are swept here.
      # Unlike the three inert-marker globs above, this one deletes a live WORKING directory, so
      # it must not touch an invocation still using one: a guard in an unrelated session in this
      # repository can be mid-flight when someone types /onboard, and pulling its scratch
      # directory out from under it would make its next write fail under `set -euo pipefail` and
      # block that session's tool call. THIS invocation's own directory matches the glob too.
      # Age is the discriminator, NOT the trailing PID. Reaping by `kill -0` on that PID was
      # tried first and failed on its first live test: macOS had recycled the abandoned run's
      # 90292 into an mdworker_shared within four hours, so the check reported "alive" and
      # skipped the very directory it was written to collect. PID reuse gets MORE likely the
      # longer a leaked directory sits, which makes PID identity weakest exactly where this
      # sweep is needed. An age bound has no such inversion: a guard invocation cannot outlive
      # the harness hook timeout (measured at a 600,000ms ceiling when one was killed against
      # it), so anything untouched for an hour is abandoned by definition, and our own directory
      # -- created seconds ago -- is never in range. `find -mmin` rather than a stat-based mtime
      # comparison because `stat -f %m` is macOS-only and its GNU spelling means something else
      # entirely, which cost a round-14 renderer bug.
      find "$git_dir" -mindepth 1 -maxdepth 1 -type d -name 'launch-control-onboard-guard-*' \
        -mmin +60 -exec rm -rf {} + 2>/dev/null || true
      rm -rf "$cwd/.launch-control-onboard"
      if [[ "$prompt" =~ (^|[[:space:]])--launch-control([[:space:]]|$) ]]; then
        printf '%s\n' launch-control > "$mode_state"
      else
        printf '%s\n' default > "$mode_state"
      fi
    fi
    exit 0
    ;;
esac

# Verified completion disarms every retained skill hook for unrelated later turns.
# Only UserPromptSubmit(/onboard ...), handled above, may change this session state.
[ ! -f "$disarmed_state" ] || exit 0

is_exact_blocked_protocol() {
  awk '
    { line[NR] = $0 }
    END {
      if (NR < 12 || line[1] != "=== Workspace Setup Blocked ===" || line[2] != "" ||
          line[3] !~ /^Failed \([1-9][0-9]*\):$/) exit 1

      count = line[3]
      sub(/^Failed \(/, "", count)
      sub(/\):$/, "", count)
      # `+ 0` is load-bearing. `sub()` leaves count a STRING, and `item <= count` on a string
      # is a LEXICAL compare: "2" <= "14" is false, so a report listing 14 paths parsed exactly
      # one of them and then failed on the second. Measured: counts 1-8 accepted, every count
      # from 9 up rejected -- and the rejection message tells the model its shape is wrong, so
      # the contract became unsatisfiable. Live on rymonroe.com the model emitted a correct
      # Failed (14) twice, the second time using the text the checkpoint itself dictated, was
      # refused both times, and abandoned the protocol for freeform prose. Every fixture in the
      # tree used Failed (1) or Failed (2), which is why the suite stayed green.
      count += 0
      cursor = 4
      for (item = 1; item <= count; item++) {
        if (line[cursor] !~ /^  [^[:space:]].*$/) exit 1
        cursor++
      }
      if (line[cursor++] != "" || line[cursor++] != "Reason:" ||
          line[cursor] !~ /^  [^[:space:]].*$/) exit 1
      cursor++
      if (line[cursor++] != "" || line[cursor++] != "Next:" ||
          line[cursor] !~ /^  [^[:space:]].*$/) exit 1
      cursor++
      if (line[cursor++] != "" || line[cursor++] != "=== End Workspace Setup ===" ||
          cursor - 1 != NR) exit 1
    }
  ' "$actual"
}

case "$event" in
  TaskCreated)
    task_id="$(printf '%s' "$input" | jq -r '.task_id // empty')"
    if [ -z "$task_id" ] || [[ "$task_id" == *$'\n'* ]]; then
      printf '%s\n' '{"continue":false,"stopReason":"Launch Control could not track the newly created onboarding task."}'
      exit 0
    fi
    rm -f "$state"
    if [ ! -f "$task_state" ] || ! grep -Fqx -- "$task_id" "$task_state"; then
      printf '%s\n' "$task_id" >> "$task_state"
    fi
    ;;
  TaskCompleted)
    task_id="$(printf '%s' "$input" | jq -r '.task_id // empty')"
    rm -f "$state"
    if [ -n "$task_id" ] && [ -f "$task_state" ]; then
      grep -Fvx -- "$task_id" "$task_state" > "$task_tmp" || true
      if [ -s "$task_tmp" ]; then
        mv "$task_tmp" "$task_state"
      else
        rm -f "$task_state"
      fi
    fi
    ;;
  PreToolUse)
    tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
    case "$tool_name" in
      Bash)
        command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
        config_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if [ -d "$config_root/skills/onboard/scripts" ]; then
          config_root="$(cd "$config_root" && pwd -P)"
          checkpoint="$config_root/skills/onboard/scripts/discovery-checkpoint.sh"
          if { [ "$command" = "$checkpoint" ] || [ "$command" = "\"$checkpoint\"" ]; } &&
             [ -f "$checkpoint" ] && [ ! -L "$checkpoint" ] && [ -x "$checkpoint" ]; then
            deleted_required="$(deletion_dirty_required_paths)"
            if [ -n "$deleted_required" ]; then
              deny_deletion_dirty_required "$deleted_required"
              exit 0
            fi
            if ! validate_discovery_report; then
              jq -cn '{
                hookSpecificOutput: {
                  hookEventName: "PreToolUse",
                  permissionDecision: "deny",
                  permissionDecisionReason: "Onboarding discovery checkpoint requires a complete schema-valid .launch-control-onboard/discovery-report.txt written before invocation."
                }
              }'
              exit 0
            fi
            attested_hash="$(discovery_report_hash)"
            printf '%s\n' "$attested_hash" > "$discovery_state"
            mkdir -p "$cwd/.launch-control-onboard"
            printf 'phase-0-discovery-complete\t%s\tguard-attested\n' "$attested_hash" > "$discovery_marker"
            capture_run_anchor
          fi
          renderer="$config_root/skills/onboard/scripts/render-report.sh"
          # BUG-10: proof freshness must reflect a successful render by THIS session, not a
          # mere renderer attempt. PreToolUse cannot see the exit status, so tie freshness to
          # the proof file: only a completion-shaped invocation (terminal `complete` argument,
          # mirroring is_installed_renderer_invocation) stamps the render marker AND clears any
          # stale proof left by an abnormal earlier session. A --cleanup, argument-less, or
          # otherwise malformed invocation mints no report, so it must neither stamp nor clear;
          # a completion attempt that then exits nonzero leaves the cleared proof absent, so the
          # Stop check blocks the replay instead of validating stale proof.
          # Round-16 F34a: a SECOND successful render in one session is never legitimate. An
          # acceptance run rendered, read `permission-mode: bypassPermissions` in its own
          # report, found that it contradicted a claim it had already made in prose, and
          # re-rendered "so the report follows this disclosure" — re-executing all four
          # declared gates, 8 executions instead of 4, 20 files created where the report
          # discloses 18. Nothing in the report records the repeat: `failed attempts` counts
          # failed executions, and both renders succeeded.
          #
          # The discriminator is already on disk and needs no new marker. `$state` is written
          # by the renderer itself, as its last act on a successful render; `$render_state` is
          # stamped here, per session, before the renderer runs. The pair separates every case:
          #
          #   render_state absent            -> this session has not rendered. A `$state` left
          #                                     by an abnormal earlier session is stale, so
          #                                     clear it (the BUG-10 rule below) and proceed.
          #   render_state + state present   -> this session rendered, the renderer succeeded,
          #                                     and nothing has invalidated the proof since.
          #                                     Redundant. Refuse.
          #   render_state, state absent     -> the render was blocked or exited nonzero, or a
          #                                     later Edit/Write or task change cleared the
          #                                     proof. A retry is legitimate. Allow.
          #
          # That third row is why this keys on `$state` rather than on `$render_state` alone:
          # a retry after a BLOCKED render must stay allowed, and a re-render after a real
          # workspace change is required, not merely permitted. It also closes the laundering
          # question: two renders of the SAME workspace can no longer both succeed, so there
          # is no pair of reports to choose between.
          if [ -f "$render_state" ] && [ -f "$state" ]; then
            case "$command" in
              "$renderer"\ *\ complete|"\"$renderer\""\ *\ complete|*\ "$renderer"\ *\ complete|*\ "\"$renderer\""\ *\ complete)
                jq -cn '{
                  hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: "This session already rendered a completion report and nothing has changed since, so a second render would mint a duplicate report that discloses neither the repeat nor the extra files it creates. Return the stdout of the render you already have, verbatim, as the final message. If a statement you made earlier in conversation contradicts that report, the report is the record and the correction belongs in conversation before the final message — re-rendering cannot revise prose you have already sent. Only a real change to the workspace or the task list re-enables the renderer, and after a render that was blocked or failed a retry is already allowed."
                  }
                }'
                exit 0
                ;;
            esac
          fi
          case "$command" in
            "$renderer"\ *\ complete|"\"$renderer\""\ *\ complete|*\ "$renderer"\ *\ complete|*\ "\"$renderer\""\ *\ complete)
              if [ -f "$renderer" ] && [ ! -L "$renderer" ] && [ -x "$renderer" ]; then
                # Round-31: refuse the render the renderer would refuse anyway, before it runs.
                # Checked here rather than in a block of its own so a denied invocation cannot
                # stamp the render marker below: the render never happens, so nothing about
                # this session's render state may change. Circuit breaker mirrors the guidance
                # denies -- after two, stand down and let the renderer decide it, so a run that
                # structurally cannot produce the block can never livelock at this gate.
                prospective_denies=0
                [ ! -f "$prospective_deny_state" ] ||
                  prospective_denies="$(cat "$prospective_deny_state" 2>/dev/null || printf 0)"
                if [ "$prospective_denies" -lt 2 ] && prospective_claude_missing "$command" "$renderer"; then
                  printf '%s\n' "$((prospective_denies + 1))" > "$prospective_deny_state"
                  # Round-31 follow-up: "write the block now" is complete advice ONLY when this
                  # run has not already written CLAUDE.md. The renderer checks the missing block
                  # first (render-report.sh:1443) and the F32 write order second (:1484), so a
                  # CREATED or MERGED run that takes the short advice writes the block at a LATER
                  # sequence than the CLAUDE.md it already wrote, and the next render dies on the
                  # inversion instead -- a second full validation-command run, which is the exact
                  # cost this gate exists to remove. Only PRESERVED is genuinely fixed by the
                  # short advice: Phase 3 never writes CLAUDE.md there, last_claude_seq stays 0,
                  # and the renderer's F31 idempotent-path branch exempts it. So read the same
                  # attestation the renderer reads and give the recovery that actually lands.
                  prospective_order_hint=""
                  write_order_guard="$cwd/.launch-control-onboard/write-order.guard.txt"
                  if [ -f "$write_order_guard" ] && [ ! -L "$write_order_guard" ] &&
                    [ "$(awk -F '\t' '$2 == "CLAUDE.md" { seq = $1 } END { print seq + 0 }' \
                      "$write_order_guard")" -gt 0 ]; then
                    prospective_order_hint=" This run has ALREADY written CLAUDE.md, so writing the block alone is not enough: the renderer also requires the last write of the block to precede the last write of CLAUDE.md, and a block written now would come after. Write .launch-control-onboard/prospective-claude.md first, then write CLAUDE.md again with that identical block in place, and only then re-run the render. Writing only the block sends the next render into that inversion instead."
                  fi
                  jq -cn --arg hint "$prospective_order_hint" --arg base "This run's ledger records CLAUDE.md as CREATED, MERGED, or PRESERVED, but .launch-control-onboard/prospective-claude.md does not exist, and the renderer refuses that pair as well. Write the assembled generated block to .launch-control-onboard/prospective-claude.md: first line exactly \`## Generated Quick Reference\`, then the rendered block and nothing else (no comment markers, no top-level \`# \` headings). The write is unconditional -- a run whose CLAUDE.md is PRESERVED is not exempt." '{
                    hookSpecificOutput: {
                      hookEventName: "PreToolUse",
                      permissionDecision: "deny",
                      permissionDecisionReason: ($base + $hint + " Then re-run this render unchanged.")
                    }
                  }'
                  exit 0
                fi
                # Round-31 sibling, same class one rule over. Round-17 moved the reviewer-lens
                # rule to the WRITE, which closes it only for a run that WRITES the file, and the
                # write-time rule stands down after two denies -- so a malformed lens can still
                # reach the render, where the renderer refuses it (render-report.sh:1587).
                # Round-32 correction: that renderer refusal is also BEFORE any declared command
                # runs (:1721), measured at 385 ms; round-31's "after the whole declared contract
                # has executed" was wrong and its 8m12s was the whole /onboard run. This backstop
                # buys the named schema below, not time.
                #
                # Round-32 scoping: it must key on the LEDGER, not on disk. Keyed on disk it also
                # fired on a PRESERVED user-owned reviewer, demanding an edit to a file
                # SKILL.md:78 forbids the run from writing -- a deny with no compliant response.
                # The renderer no longer fails that case either (render-report.sh, same round),
                # so a disk-keyed deny here would now block a render that would have PASSED.
                # Unresolvable ledger, or a reviewer this run did not write: stand down.
                lens_render_denies=0
                [ ! -f "$lens_render_deny_state" ] ||
                  lens_render_denies="$(cat "$lens_render_deny_state" 2>/dev/null || printf 0)"
                onboard_reviewer="$cwd/.claude/agents/inspector.md"
                lens_render_ledger="$(render_ledger_path "$command" "$renderer" || true)"
                # Absent is the renderer's own skip condition, so absence is not a failure here
                # either -- it is the rule having no premise, and it stands down.
                if [ "$lens_render_denies" -lt 2 ] && [ -f "$onboard_reviewer" ] &&
                  [ -n "$lens_render_ledger" ] &&
                  ledger_generated_this_run "$lens_render_ledger" '.claude/agents/inspector.md' &&
                  lens_render_error="$(reviewer_lens_shape_error "$onboard_reviewer")"; then
                  printf '%s\n' "$((lens_render_denies + 1))" > "$lens_render_deny_state"
                  jq -cn --arg reason "The generated code reviewer at .claude/agents/inspector.md has a malformed project-specific review lens, and the renderer refuses it as well: $lens_render_error. Required shape, written exactly: a \`## Project-specific review lens\` heading followed by at least two bullets, each one \`- <concern>. Evidence: \\\`<repo-relative path>\\\`.\`: the line ends with the backticked path and a period, the path exists in this repository and is canonical (no leading /, ./, or .. segment), and the only accepted non-path spelling is \`Phase 0 discovery\`. This run's ledger records the file as CREATED or MERGED, so it is yours to fix: rewrite it with a conforming lens and then re-run this render unchanged." '{
                    hookSpecificOutput: {
                      hookEventName: "PreToolUse",
                      permissionDecision: "deny",
                      permissionDecisionReason: $reason
                    }
                  }'
                  exit 0
                fi
                rm -f "$state"
                : > "$render_state"
              fi
              ;;
          esac
        fi
        ;;
      Edit|Write)
        write_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
        case "$write_path" in
          "$discovery_report"|.launch-control-onboard/discovery-report.txt)
            rm -f "$discovery_state"
            exit 0
            ;;
        esac
        if ! verify_discovery_attestation; then
          deny_reason="Onboarding cannot write before the complete Workspace Discovery Report is saved, schema-validated, and hash-bound by the installed discovery-checkpoint.sh."
          # Round-12: a pre-checkpoint `.gitignore` write is almost always the tail of a
          # forbidden detour — the run saw a large untracked dependency directory in the
          # baseline and set out to curate it. Naming only the ordering rule here taught the
          # last such run that the write was legitimate-but-mistimed, so it handed the write
          # to the user and emitted the blocked protocol. Name the rule that actually governs.
          case "$write_path" in
            .gitignore|*/.gitignore)
              deny_reason="$deny_reason Onboarding also never curates the user's untracked files: a large untracked dependency directory (.venv/, node_modules/) in the Phase 0 baseline is an ordinary repository state that the renderer collapses to one counted line. It is not a reason to ask the user a run-mode question, and not a reason to emit the blocked protocol. The only .gitignore rules onboarding may write are its own declared Claude-local entries, after the discovery checkpoint. Continue the run."
              ;;
          esac
          jq -cn --arg reason "$deny_reason" '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: $reason
            }
          }'
          exit 0
        fi
        # Round-5: catch a skipped standalone emission at the FIRST manifest write instead of
        # only at Stop — recovery here costs one message instead of a full redundant render
        # pass. Fails open without a transcript_path, mirroring the Stop backstop.
        # Round-7 circuit breaker: after two denies in a session, stand down and leave
        # enforcement to the Stop backstop — an agent that structurally cannot satisfy the
        # scan mid-turn (observed with thinking-only messages) must not livelock the run.
        emission_denies=0
        [ ! -f "$emission_deny_state" ] || emission_denies="$(cat "$emission_deny_state" 2>/dev/null || printf 0)"
        if [ "$emission_denies" -lt 2 ] && discovery_emission_missing; then
          printf '%s\n' "$((emission_denies + 1))" > "$emission_deny_state"
          jq -cn '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: "Onboarding cannot write before the Workspace Discovery Report has been emitted as visible assistant message text (SKILL.md Phase 0). Recovery: send one message whose TEXT is the complete marker-delimited report block and whose tool call re-runs the gate-exempt Write of .launch-control-onboard/discovery-report.txt, then retry this write in the following message. Do not send the report as a text-only message with no tool call — that ends your turn and stalls the run."
            }
          }'
          exit 0
        fi
        # Round-17: reject a malformed reviewer lens at the write, not at the render.
        # Circuit breaker mirrors the emission-deny cap directly above: after two denies the
        # hook stands down and leaves the rule to the renderer, so a run that structurally
        # cannot satisfy the shape can never livelock here.
        case "$write_path" in
          .claude/agents/inspector.md|"$cwd"/.claude/agents/inspector.md)
            lens_denies=0
            [ ! -f "$lens_deny_state" ] || lens_denies="$(cat "$lens_deny_state" 2>/dev/null || printf 0)"
            lens_content="$(resolved_write_content "$write_path" || printf '')"
            if [ "$lens_denies" -lt 2 ] && [ -n "$lens_content" ]; then
              lens_file="$guard_tmp/reviewer-lens"
              printf '%s\n' "$lens_content" > "$lens_file"
              if lens_error="$(reviewer_lens_shape_error "$lens_file")"; then
                printf '%s\n' "$((lens_denies + 1))" > "$lens_deny_state"
                jq -cn --arg reason "The generated code reviewer's project-specific review lens is malformed: $lens_error. Required shape, written exactly: a \`## Project-specific review lens\` heading followed by at least two bullets, each one \`- <concern>. Evidence: \\\`<repo-relative path>\\\`.\` — the line ends with the backticked path and a period, the path exists in this repository and is canonical (no leading /, ./, or .. segment), and the only accepted non-path spelling is \`Phase 0 discovery\`. Rewrite the lens and retry this write." '{
                  hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: $reason
                  }
                }'
                exit 0
              fi
            fi
            ;;
        esac
        # Round-17: the same move for the two generated-guidance rules, with their own deny
        # counter so a guidance the run cannot satisfy stands down to the renderer rather than
        # livelocking the write.
        guidance_rel="$write_path"
        case "$guidance_rel" in "$cwd"/*) guidance_rel="${guidance_rel#"$cwd"/}" ;; esac
        # Matched here as well as inside the function so an ordinary write costs no `jq`.
        case "$guidance_rel" in
          CLAUDE.md|.claude/skills/launch/SKILL.md|.claude/skills/testing-patterns/SKILL.md|.claude/commands/validate.md)
            guidance_denies=0
            [ ! -f "$guidance_deny_state" ] || guidance_denies="$(cat "$guidance_deny_state" 2>/dev/null || printf 0)"
            guidance_content="$(resolved_write_content "$write_path" || printf '')"
            if [ "$guidance_denies" -lt 2 ] && [ -n "$guidance_content" ]; then
              guidance_file="$guard_tmp/generated-guidance"
              printf '%s\n' "$guidance_content" > "$guidance_file"
              if guidance_error="$(generated_guidance_error "$guidance_rel" "$guidance_file")"; then
                printf '%s\n' "$((guidance_denies + 1))" > "$guidance_deny_state"
                jq -cn --arg reason "The generated guidance in $guidance_rel does not match the workspace this run is creating: $guidance_error. Rewrite that passage and retry this write." '{
                  hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: $reason
                  }
                }'
                exit 0
              fi
            fi
            ;;
        esac
        # LC-037: the write that records the project's documented gates is never denied for differing
        # from the set derived from CI. Onboarding has no say over how a project is tested; a difference
        # is disclosed in the report instead.
        if [ ! -f "$baseline_state" ]; then
          deleted_required="$(deletion_dirty_required_paths)"
          if [ -n "$deleted_required" ]; then
            deny_deletion_dirty_required "$deleted_required"
            exit 0
          fi
        fi
        rm -f "$state"
        : > "$run_state"
        if [ ! -f "$baseline_state" ]; then
          # Exclude the .launch-control-onboard control directory exactly as the renderer's
          # worktree_status() does: its own control files (the anchor, preserve-hashes, ledger,
          # …) are never legitimate baseline paths, and capturing them would demand the ledger
          # PRESERVE the guard's own scratch state.
          # `f03560a` closed this pattern at the run-anchor capture and missed it here, and a live
          # toolshed run proved the miss on the report surface: one zero-byte file whose NAME held
          # two newlines became FOUR baseline rows for two real paths, the renderer derived a
          # PRESERVED row for each fragment, and `Untouched pre-existing (213)` listed `PY` and two
          # code fragments as repository paths under a heading that claims every path above was
          # captured and verified. The count was inflated by two and three of the entries were not
          # paths at all.
          #
          # The renderer cannot recover from it: it loads this exact file (render-report.sh reads
          # the run's `.baseline` into `baseline_files`), and by then the newline IS the record
          # separator, indistinguishable from real paths. So the exclusion has to happen here,
          # before the decoded name is ever written to a line.
          #
          # A sidecar of its own rather than the anchor's: that file is published by `mv` inside
          # `capture_run_anchor`, so a second writer would either be clobbered or would depend on
          # which capture ran first. The renderer reads both and `sort -u`s them, so a path both
          # captures saw is still disclosed exactly once.
          baseline_unrepresentable="$cwd/.launch-control-onboard/baseline-paths.unrepresentable"
          mkdir -p "$cwd/.launch-control-onboard"
          : > "$baseline_unrepresentable"
          git -C "$cwd" status --short --untracked-files=all -- . ':(exclude).launch-control-onboard/**' |
            while IFS= read -r record; do
              [ -n "$record" ] || continue
              unquote_git_path "${record:3}"
              # Git's own C-quoted spelling is single-line by construction, so the disclosure
              # keeps the one form that fits. Dropping it silently would be the same lie in the
              # other direction: the run genuinely cannot account for this path and must say so.
              if [ "$unquoted_path" != "${unquoted_path%%$'\n'*}" ]; then
                printf '%s\n' "${record:3}" >> "$baseline_unrepresentable"
                continue
              fi
              printf '%s\n' "$unquoted_path"
            done | LC_ALL=C sort -u > "$baseline_state"
          # An aliased manifest path is existing content, so pin it in the same baseline every
          # other preserved path lives in. That single append is what makes the rest of the
          # machinery cover it: the renderer then demands a PRESERVED row for it ("dirty
          # baseline path must remain PRESERVED"), and capture_preserve_hashes below records
          # its digest so a write cannot pass the render either. The separate state file keeps
          # the deny below free of a per-write subshell and lets the renderer disclose which
          # link each path resolved through.
          symlinked_manifest_paths > "$symlink_state"
          if [ -s "$symlink_state" ]; then
            cut -f1 "$symlink_state" >> "$baseline_state"
            LC_ALL=C sort -u "$baseline_state" -o "$baseline_state"
            mkdir -p "$cwd/.launch-control-onboard"
            cp "$symlink_state" "$cwd/.launch-control-onboard/symlinked-manifest.guard.txt"
          fi
        fi
        # Deliberately has NO circuit breaker, unlike every other deny in this file. The others
        # stand down after two denies so a run that cannot satisfy a shape still finishes; here
        # standing down would hand back the write that destroys the file, so this one holds for
        # the whole run. It is also terminal rather than corrective: there is no rewrite of the
        # content that makes the write safe.
        if [ -s "$symlink_state" ]; then
          symlink_rel="$write_path"
          case "$symlink_rel" in "$cwd"/*) symlink_rel="${symlink_rel#"$cwd"/}" ;; esac
          symlink_target="$(awk -F '\t' -v p="$symlink_rel" '$1 == p { print $2; exit }' "$symlink_state")"
          if [ -n "$symlink_target" ]; then
            jq -cn --arg reason "The required manifest path $symlink_rel is a symlink alias: it resolves to $symlink_target, which is not a file onboarding owns. Writing it would overwrite content outside the generated workspace — in a live run this destroyed uncommitted changes and left git status unchanged — so the path is pinned PRESERVED for this entire run. Do not write it and do not retry it under any spelling. This is an ordinary preserved path, NOT a blocked condition: do not emit the blocked protocol, do not stop the run, and do not ask the user to delete or replace the symlink. List $symlink_rel under PRESERVED in the ledger, leave every other manifest path to its normal handling, and continue." '{
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason
              }
            }'
            exit 0
          fi
        fi
        if [ ! -f "$inventory_state" ]; then
          capture_inventory
        fi
        capture_preserve_hashes
        record_write_order "$write_path"
        ;;
    esac
    ;;
  Stop)
    printf '%s' "$input" | jq -j '.last_assistant_message // ""' > "$actual"
    has_success=false
    if grep -Fq '=== Workspace Setup Complete ===' "$actual"; then
      has_success=true
    fi
    mentions_blocked=false
    grep -Fq '=== Workspace Setup Blocked ===' "$actual" && mentions_blocked=true
    has_blocked=false
    is_exact_blocked_protocol && has_blocked=true

    if [ "$mentions_blocked" = true ] && [ "$has_blocked" = false ]; then
      printf '%s\n' '{"decision":"block","reason":"The blocked onboarding message does not exactly match the required Failed, Reason, Next, and closing-marker protocol."}'
      exit 0
    fi

    # Round-12: the protocol above verifies the SHAPE of Reason and Next, never their
    # content, so a blocked report could paraphrase the renderer's diagnostic into a cause
    # the machine never stated and a remedy the machine never offered. When the renderer
    # minted an exact recovery line for a recognized collision, hold the emitted Next to it.
    blocked_next_state="$cwd/.launch-control-onboard/blocked-next"
    if [ "$has_blocked" = true ] && [ -s "$blocked_next_state" ] && [ ! -L "$blocked_next_state" ]; then
      expected_next="$(head -n 1 "$blocked_next_state")"
      emitted_next="$(awk '/^Next:$/ { getline nextline; sub(/^  /, "", nextline); print nextline; exit }' "$actual")"
      if [ "$emitted_next" != "$expected_next" ]; then
        jq -cn --arg expected "$expected_next" '{
          decision: "block",
          reason: ("The blocked report rewrote the machine-derived recovery. The renderer minted this exact Next line for the collision it observed; emit it verbatim rather than a paraphrase, and never drop the option that avoids weakening the generated secret boundary: " + $expected)
        }'
        exit 0
      fi
    fi

    if [ ! -f "$run_state" ] && [ "$has_success" = false ]; then
      exit 0
    fi

    # An exact blocked protocol is a legitimate terminal state for any run,
    # including one that already wrote files. A recorded-gate rejection surfaces here as a block,
    # never as renderer success proof, so do not demand
    # proof — allow the honest block and clear session state. Blocking is conservative: it
    # can never produce a false-green completion report.
    # LC-037: the renderer runs no project command, so a project's own checks can never arrive here;
    # this path sees only the classes whose remedy belongs to the run itself.
    if [ "$has_success" = false ] && [ "$has_blocked" = true ]; then
      rm -f "$state" "$run_state" "$baseline_state" "$inventory_state" "$symlink_state" "$mode_state" "$task_state" "$discovery_state" "$render_state"
      rm -rf "$cwd/.launch-control-onboard"
      exit 0
    fi

    if [ -s "$task_state" ]; then
      printf '%s\n' '{"decision":"block","reason":"Onboarding still has incomplete UI tasks. Complete every task created by this run before invoking render-report.sh."}'
      exit 0
    fi

    if [ ! -f "$state" ]; then
      printf '%s\n' '{"decision":"block","reason":"Onboarding wrote files or claimed success without fresh renderer proof. Run the installed scripts/render-report.sh and return its stdout verbatim."}'
      exit 0
    fi

    # Renderer proof is only valid for the session that invoked the renderer. A proof
    # file left behind by an abnormal earlier session must never validate a replayed
    # completion message.
    if [ ! -f "$render_state" ]; then
      printf '%s\n' '{"decision":"block","reason":"Renderer proof is stale: this session never invoked the installed scripts/render-report.sh. Run it in this session and return its stdout verbatim."}'
      exit 0
    fi

    # GAP-4 (e2e follow-up): SKILL.md prescribes emitting the standalone Workspace Discovery
    # Report, but nothing enforced it — a rerun agent skipped it silently. Require the report
    # artifact the agent writes in Phase 0 (the emitted block, verbatim) to exist and be
    # well-formed before a completion report may finish. This is checked only for a success
    # terminal; an honest blocked protocol already returned above.
    if ! verify_discovery_attestation; then
      printf '%s\n' '{"decision":"block","reason":"Onboarding cannot complete without a schema-valid, session-bound Workspace Discovery Report. Save it before invoking discovery-checkpoint.sh and do not modify it afterward."}'
      exit 0
    fi

    # Round-4 (review finding 1): SKILL.md Phase 0 requires the Workspace Discovery Report
    # be EMITTED as a standalone assistant message, not merely written to the control file.
    # Attest via the session transcript when the harness provides one; without a
    # transcript_path this check fails open and the file/hash attestation above stands alone.
    # Round-5: the same scan also gates the first manifest write at PreToolUse, so a missed
    # emission normally fails there cheaply; this Stop check remains the backstop.
    if discovery_emission_missing; then
      printf '%s\n' '{"decision":"block","reason":"The Workspace Discovery Report was never emitted as a standalone assistant message. Emit the complete block visibly per SKILL.md Phase 0, save it verbatim, and re-run discovery-checkpoint.sh."}'
      exit 0
    fi

    cat "$state" > "$expected"
    # Claude Code omits the renderer's terminal newline from last_assistant_message.
    printf '%s' "$(cat "$expected")" > "$expected"
    if ! cmp -s "$expected" "$actual"; then
      printf '%s\n' '{"decision":"block","reason":"The completion message does not exactly match fresh renderer stdout. Return only the renderer output, with the full live branch and no preface or recap."}'
      exit 0
    fi

    # LC-037 residual: everything the re-arm sweep names except the off switch itself. The policy's
    # mode markers and the deny counters are read only before this point (the render), and the
    # policy stamps nothing once `.disarmed` exists, so leaving them only parked them in .git
    # until the next /onboard in this repository.
    rm -f "$state" "$run_state" "$baseline_state" "$inventory_state" "$symlink_state" "$mode_state" "$task_state" "$discovery_state" "$render_state" "$emission_deny_state" "$lens_deny_state" "$guidance_deny_state" "$prospective_deny_state" "$lens_render_deny_state" "$bypass_state" "$permission_mode_state"
    : > "$disarmed_state"
    rm -rf "$cwd/.launch-control-onboard"
    ;;
esac
