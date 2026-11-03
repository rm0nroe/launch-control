#!/usr/bin/env bash
#
# Launch Control installer
# Installs the core onboarding/delivery skill suite and its subagents into your
# user-level Claude Code config (~/.claude). Superpowers is a required dependency;
# supporting global CLIs are optional.
#
# Safe upgrades: untouched copies whose digest matches a released Launch Control version
# are backed up and replaced automatically. Unknown or user-modified copies stop the
# install before dependency or file changes. Use --force to explicitly back up and
# replace those copies. Backups live outside active discovery under
# ~/.claude/launch-control-backups/<timestamp>/. A successful run that backed up only released
# copies marks its backup complete and removes older complete ones, so one version back is
# kept; a backup holding user content (--force over an unknown copy, a quarantined .bak-*)
# or left by a failed run is never removed automatically. Renamed Launch Control skills are moved,
# never deleted, to ~/.claude/launch-control-legacy-skills/<timestamp>/ for rollback.
# Explicit local declarations in launch-control-user-owned.txt retain named colliding
# providers and produce a partial install; they never become Launch Control-owned.
# Nothing here contains secrets.
#
# Claude Code is assumed already installed. The installer preserves any working
# Superpowers provider and provisions the official plugin only when none is enabled.
#
# Usage:
#   ./install.sh                         # install or safely upgrade core skills + agents
#   ./install.sh --codex                # install or safely upgrade native core skills + agents
#   ./install.sh --force                 # replace unknown/user-modified copies with an external backup
#   ./install.sh --optional-tools         # also install optional supporting CLIs
#   ./install.sh --dry-run                # print what would happen
#   ./install.sh --uninstall              # remove only verified Launch Control-owned copies
#   ./install.sh --uninstall --dry-run    # preview the exact ownership-aware removal

set -euo pipefail

# Codex is an explicit independent install target; it never invokes Claude plugins.
if [ "${1:-}" = --codex ]; then
  shift
  exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools/install-codex.py" "$@"
fi

# ---------- config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"
OWNERSHIP_MANIFEST="$SCRIPT_DIR/install/launch-control-owned-digests.txt"
TS="$(date +%Y%m%d-%H%M%S)"

# shellcheck source=tools/launch-control-digests.sh
source "$SCRIPT_DIR/tools/launch-control-digests.sh"

FORCE=0
DRY_RUN=0
OPTIONAL_TOOLS=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --optional-tools) OPTIONAL_TOOLS=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --skills-only|--install-deps)
      echo "Unsupported flag: $arg. Superpowers is now required by default; use --optional-tools for optional CLIs."
      exit 1
      ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)"; exit 1 ;;
  esac
done

if [ "$UNINSTALL" = 1 ] && [ "$OPTIONAL_TOOLS" = 1 ]; then
  echo "--uninstall cannot be combined with --optional-tools"
  exit 1
fi

# ---------- helpers ----------
c_blue()  { printf '\033[1;34m%b\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%b\033[0m\n' "$*"; }
c_yellow(){ printf '\033[1;33m%b\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%b\033[0m\n' "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

manifest_scope() {
  if [ "$1" = "subagents" ]; then
    printf '%s\n' agents
  else
    printf '%s\n' "$1"
  fi
}

is_known_launch_control_copy() {
  local scope="$1" name="$2" item="$3" digest
  digest="$(launch_control_item_digest "$item")"
  launch_control_manifest_has_digest "$OWNERSHIP_MANIFEST" "$scope" "$name" "$digest"
}

# Resolve every differing destination before touching the plugin registry or user
# files. A normal install may replace only a byte-identical released Launch Control copy.
preflight_tree() {
  local src_root="$1" dst_root="$2" label="$3"
  local item base dst scope
  scope="$(manifest_scope "$label")"
  for item in "$src_root"/*; do
    [ -e "$item" ] || continue
    base="$(basename "$item")"
    dst="$dst_root/$base"
    if launch_control_user_owned_has "$scope" "$base"; then
      c_yellow "    preserve declared user-managed path: $scope/$base"
      continue
    fi
    [ -e "$dst" ] || continue
    launch_control_items_equal "$item" "$dst" && continue
    [ "$FORCE" = 1 ] && continue
    if ! is_known_launch_control_copy "$scope" "$base" "$dst"; then
      UNKNOWN_COPIES+=("$scope/$base")
    fi
  done
}

if [ ! -r "$OWNERSHIP_MANIFEST" ]; then
  c_red "Missing Launch Control ownership manifest: $OWNERSHIP_MANIFEST"
  exit 1
fi

if ! launch_control_load_user_owned "$CLAUDE_DIR" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/agents"; then
  exit 2
fi

uninstall_backup_root="$CLAUDE_DIR/launch-control-uninstall-backups/$TS"

uninstall_paths() {
  local mode="$1" scope name root path digest backup
  while read -r scope name; do
    [ -n "$scope" ] && [ -n "$name" ] || continue
    case "$scope" in
      skills) root="$SKILLS_DST" ;;
      agents) root="$AGENTS_DST" ;;
      *) continue ;;
    esac
    if launch_control_user_owned_has "$scope" "$name"; then
      c_yellow "    preserve declared user-managed path: $scope/$name"
      continue
    fi
    for path in "$root/$name" "$root/$name".bak-*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -L "$path" ]; then
        digest=unknown
      else
        digest="$(launch_control_item_digest "$path")"
      fi
      if [ "$digest" != unknown ] && launch_control_manifest_has_digest "$OWNERSHIP_MANIFEST" "$scope" "$name" "$digest"; then
        if [ "$mode" = scan ]; then
          continue
        fi
        c_yellow "    remove verified Launch Control copy: $scope/$(basename "$path")"
        if [ "$DRY_RUN" = 1 ]; then
          printf '  [dry-run] rm -rf "%s"\n' "$path"
        else
          rm -rf "$path"
        fi
      elif [ "$mode" = scan ]; then
        UNKNOWN_COPIES+=("$scope/$(basename "$path")")
      elif [ "$FORCE" = 1 ]; then
        backup="$uninstall_backup_root/$scope/$(basename "$path")"
        c_yellow "    preserve unknown/user-modified copy outside discovery: $scope/$(basename "$path") -> $backup"
        if [ "$DRY_RUN" = 1 ]; then
          printf '  [dry-run] mkdir -p "%s"\n' "$uninstall_backup_root/$scope"
          printf '  [dry-run] mv "%s" "%s"\n' "$path" "$backup"
        else
          mkdir -p "$uninstall_backup_root/$scope"
          mv "$path" "$backup"
        fi
      fi
    done
  done < <(awk '$1 == "skills" || $1 == "agents" { print $1, $2 }' "$OWNERSHIP_MANIFEST" | LC_ALL=C sort -u)
}

if [ "$UNINSTALL" = 1 ]; then
  UNKNOWN_COPIES=()
  uninstall_paths scan
  if [ "${#UNKNOWN_COPIES[@]}" -gt 0 ] && [ "$FORCE" != 1 ]; then
    c_red "Uninstall stopped before file changes."
    echo "These manifest-named paths do not match any released Launch Control digest:"
    printf '  - %s\n' "${UNKNOWN_COPIES[@]}"
    echo "They may contain user changes. Review them, or use --force to move them to a timestamped backup instead of deleting them."
    exit 2
  fi
  c_blue "==> Removing verified Launch Control-owned skills and agents"
  uninstall_paths apply
  c_green "Launch Control uninstall complete. Superpowers and paths absent from the ownership manifest were preserved. Declared user-managed paths were also preserved."
  if [ "$DRY_RUN" = 1 ]; then
    echo "No files were changed."
  fi
  exit 0
fi

UNKNOWN_COPIES=()
preflight_tree "$SCRIPT_DIR/skills" "$SKILLS_DST" "skills"
preflight_tree "$SCRIPT_DIR/agents" "$AGENTS_DST" "subagents"
if [ "${#UNKNOWN_COPIES[@]}" -gt 0 ]; then
  c_red "Install stopped before dependency or file changes."
  echo "These installed paths do not match any released Launch Control digest:"
  printf '  - %s\n' "${UNKNOWN_COPIES[@]}"
  echo "They may contain user changes. Review them, then rerun with --force only if replacement is intended."
  exit 2
fi

superpowers_available() {
  local output
  have claude || return 1
  if ! output="$(claude plugin list 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$output" | awk '
    BEGIN { found = 0; candidate = 0 }
    {
      line = tolower($0)
      if (line ~ /superpowers@/) {
        candidate = 1
        if (line ~ /enabled/ && line !~ /disabled/) found = 1
        next
      }
      if (candidate && line ~ /status:/) {
        if (line ~ /enabled/ && line !~ /disabled/) found = 1
        candidate = 0
      }
    }
    END { exit found ? 0 : 1 }
  '
}

ensure_superpowers() {
  c_blue "==> Verifying required Superpowers provider"
  if superpowers_available; then
    c_green "    present — preserving existing provider"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    if have claude; then
      echo "  [dry-run] claude plugin marketplace add anthropics/claude-plugins-official"
      echo "  [dry-run] claude plugin install superpowers@claude-plugins-official"
    else
      c_yellow "    'claude' CLI not found — a writing install would stop before copying files"
    fi
    return 0
  fi

  if ! have claude; then
    c_red "    required 'claude' CLI not found; no Launch Control files were installed"
    echo "Install Claude Code, then rerun ./install.sh."
    return 1
  fi

  c_yellow "    no enabled provider found — installing the official Superpowers plugin"
  if ! claude plugin marketplace add anthropics/claude-plugins-official; then
    c_yellow "    marketplace add did not succeed; attempting the official install in case it is already registered"
  fi
  if ! claude plugin install superpowers@claude-plugins-official; then
    c_red "    Superpowers installation failed; no Launch Control files were installed"
    return 1
  fi
  if ! superpowers_available; then
    c_red "    Superpowers was not enabled after installation; no Launch Control files were installed"
    return 1
  fi
  c_green "    installed and verified: superpowers@claude-plugins-official"
}

# Required dependency verification happens before any user-global file copy so a
# failure cannot leave a partial Launch Control installation.
ensure_superpowers

# ---------- 1. copy skills ----------
LAUNCH_CONTROL_SKILL_DESTS=()
LAUNCH_CONTROL_BACKUP_ROOT="$CLAUDE_DIR/launch-control-backups/$TS"
launch_control_backup_suffix=0
while [ -e "$LAUNCH_CONTROL_BACKUP_ROOT" ]; do
  launch_control_backup_suffix=$((launch_control_backup_suffix + 1))
  LAUNCH_CONTROL_BACKUP_ROOT="$CLAUDE_DIR/launch-control-backups/$TS-$launch_control_backup_suffix"
done
# Cleared when this run backs up content that no released manifest row can reproduce.
LAUNCH_CONTROL_BACKUP_PRUNABLE=1
LAUNCH_CONTROL_BACKUP_MARKER=.launch-control-backup-complete

# Runs only after a successful install. Marks this run's backup complete when it holds only
# released copies, then removes older complete backups so one version back is kept. A failed
# or concurrent run's backup carries no marker, so it is never removed here.
finish_launch_control_backup() {
  local parent sibling marker
  [ "$DRY_RUN" = 1 ] && return 0
  parent="$(dirname "$LAUNCH_CONTROL_BACKUP_ROOT")"
  [ -d "$LAUNCH_CONTROL_BACKUP_ROOT" ] && [ ! -L "$LAUNCH_CONTROL_BACKUP_ROOT" ] && [ ! -L "$parent" ] || return 0
  if [ "$LAUNCH_CONTROL_BACKUP_PRUNABLE" = 1 ]; then
    printf 'claude\n' > "$LAUNCH_CONTROL_BACKUP_ROOT/$LAUNCH_CONTROL_BACKUP_MARKER"
  else
    c_yellow "    kept backup with user content: $LAUNCH_CONTROL_BACKUP_ROOT"
  fi
  for sibling in "$parent"/*; do
    [ "$sibling" != "$LAUNCH_CONTROL_BACKUP_ROOT" ] && [ -d "$sibling" ] && [ ! -L "$sibling" ] || continue
    [[ "$(basename "$sibling")" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || continue
    marker="$sibling/$LAUNCH_CONTROL_BACKUP_MARKER"
    [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(cat "$marker")" = claude ] || continue
    rm -rf -- "$sibling"
    c_yellow "    prune old backup: $(basename "$sibling")"
  done
}

quarantine_discovery_backups() {
  local dst="$1" backup_scope="$2"
  local backup_path backup_dst
  for backup_path in "$dst".bak-*; do
    [ -e "$backup_path" ] || [ -L "$backup_path" ] || continue
    backup_dst="$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope/$(basename "$backup_path")"
    c_yellow "    quarantine discovery backup: $(basename "$backup_path") -> $backup_dst"
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [dry-run] mkdir -p \"$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope\""
      echo "  [dry-run] mv \"$backup_path\" \"$backup_dst\""
    else
      mkdir -p "$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope"
      mv "$backup_path" "$backup_dst"
      LAUNCH_CONTROL_BACKUP_PRUNABLE=0
    fi
  done
}

copy_tree() {
  local src_root="$1" dst_root="$2" label="$3"
  c_blue "==> Installing $label into $dst_root"
  run mkdir -p "$dst_root"
  local item base dst backup_scope backup_dst scope replace_reason
  backup_scope="$label"
  [ "$backup_scope" = "subagents" ] && backup_scope="agents"
  scope="$(manifest_scope "$label")"
  for item in "$src_root"/*; do
    [ -e "$item" ] || continue
    base="$(basename "$item")"
    dst="$dst_root/$base"
    if launch_control_user_owned_has "$scope" "$base"; then
      c_yellow "    preserve declared user-managed path: $scope/$base"
      continue
    fi
    quarantine_discovery_backups "$dst" "$backup_scope"
    if [ "$label" = "skills" ]; then
      LAUNCH_CONTROL_SKILL_DESTS+=("$dst")
    fi
    if [ -e "$dst" ]; then
      # Installed copies intentionally omit acceptance fixtures, so exclude them
      # from freshness checks or onboard would always appear stale.
      if launch_control_items_equal "$item" "$dst"; then
        c_yellow "    skip (exists, current): $base"
      elif [ "$FORCE" = 1 ] || is_known_launch_control_copy "$scope" "$base" "$dst"; then
        backup_dst="$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope/$base"
        if [ "$FORCE" = 1 ]; then
          replace_reason="force replace unknown/user-modified copy"
          is_known_launch_control_copy "$scope" "$base" "$dst" || LAUNCH_CONTROL_BACKUP_PRUNABLE=0
        else
          replace_reason="upgrade released Launch Control copy"
        fi
        c_yellow "    $replace_reason (backup outside discovery): $base -> $backup_dst"
        if [ "$DRY_RUN" = 1 ]; then
          echo "  [dry-run] mkdir -p \"$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope\""
          echo "  [dry-run] mv \"$dst\" \"$backup_dst\""
          echo "  [dry-run] cp -R \"$item\" \"$dst\""
        else
          mkdir -p "$LAUNCH_CONTROL_BACKUP_ROOT/$backup_scope"
          mv "$dst" "$backup_dst"
          cp -R "$item" "$dst"
        fi
      else
        # preflight_tree guarantees this is unreachable unless the destination
        # changes concurrently after preflight.
        c_red "    installed copy changed during install: $scope/$base"
        return 2
      fi
    else
      c_green "    add: $base"
      run cp -R "$item" "$dst"
    fi
  done
}

copy_tree "$SCRIPT_DIR/skills" "$SKILLS_DST" "skills"
copy_tree "$SCRIPT_DIR/agents" "$AGENTS_DST" "subagents"

# ---------- 1a. retire renamed skills from active discovery ----------
# Upgrades must not leave legacy skill directories active beside their replacements.
# Preserve the old directories and any old-name installer backups outside `skills/` so
# custom files remain available for rollback without being discovered as live skills.
retire_legacy_skill() {
  local legacy_name="$1" replacement_name="$2"
  local replacement_dst="$SKILLS_DST/$replacement_name"
  local replacement_ready=0
  local legacy_path quarantine_root

  if launch_control_user_owned_has skills "$replacement_name"; then
    c_yellow "    preserve declared user-managed legacy family: skills/$replacement_name"
    return 0
  fi

  if [ -d "$replacement_dst" ]; then
    replacement_ready=1
  elif [ "$DRY_RUN" = 1 ] && { [ ! -e "$replacement_dst" ] || [ "$FORCE" = 1 ]; }; then
    replacement_ready=1
  fi
  [ "$replacement_ready" = 1 ] || return 0

  quarantine_root="$LEGACY_QUARANTINE_ROOT"

  for legacy_path in "$SKILLS_DST/$legacy_name" "$SKILLS_DST/$legacy_name".bak-*; do
    [ -e "$legacy_path" ] || [ -L "$legacy_path" ] || continue
    c_yellow "    quarantine renamed skill: $(basename "$legacy_path") -> $quarantine_root/$(basename "$legacy_path")"
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [dry-run] mkdir -p \"$quarantine_root\""
      echo "  [dry-run] mv \"$legacy_path\" \"$quarantine_root/$(basename "$legacy_path")\""
    else
      mkdir -p "$quarantine_root"
      mv "$legacy_path" "$quarantine_root/"
    fi
  done
}

legacy_intake_name='problem-to''-research'
LEGACY_QUARANTINE_ROOT="$CLAUDE_DIR/launch-control-legacy-skills/$TS"
legacy_quarantine_suffix=0
while [ -e "$LEGACY_QUARANTINE_ROOT" ]; do
  legacy_quarantine_suffix=$((legacy_quarantine_suffix + 1))
  LEGACY_QUARANTINE_ROOT="$CLAUDE_DIR/launch-control-legacy-skills/$TS-$legacy_quarantine_suffix"
done
c_blue "==> Retiring renamed Launch Control skills from active discovery"
retire_legacy_skill "$legacy_intake_name" "research-questions"

# Launch Control renamed the pack's skills with no aliases (LC-036 phase 3). Retire an
# old-name copy only when it is a byte-identical released Launch Control copy; a user's own
# skill that happens to share the old name (`research`, `triage`) stays where it is.
# Does this install leave the renamed skill in place? An installed copy that is the pack's own
# authorizes retirement in a preview and in a real run alike. Otherwise only a preview looks
# ahead: it answers from what the real run would install.
replacement_published() {
  local new_name="$1"
  launch_control_user_owned_has skills "$new_name" && return 1
  if [ -d "$SKILLS_DST/$new_name" ] && launch_control_items_equal "$SCRIPT_DIR/skills/$new_name" "$SKILLS_DST/$new_name"; then
    return 0
  fi
  [ "$DRY_RUN" = 1 ] || return 1
  [ -d "$SCRIPT_DIR/skills/$new_name" ] || return 1
  return 0
}

retire_renamed_skill() {
  local old_name="$1" new_name="$2" legacy_path digest
  launch_control_user_owned_has skills "$old_name" && return 0
  replacement_published "$new_name" || return 0
  for legacy_path in "$SKILLS_DST/$old_name" "$SKILLS_DST/$old_name".bak-*; do
    [ -e "$legacy_path" ] || [ -L "$legacy_path" ] || continue
    digest=unknown
    [ -L "$legacy_path" ] || digest="$(launch_control_item_digest "$legacy_path")"
    if [ "$digest" != unknown ] && launch_control_manifest_has_digest "$OWNERSHIP_MANIFEST" skills "$old_name" "$digest"; then
      c_yellow "    quarantine renamed skill: $(basename "$legacy_path") -> $LEGACY_QUARANTINE_ROOT/ (now $new_name)"
      if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] mv \"$legacy_path\" \"$LEGACY_QUARANTINE_ROOT/$(basename "$legacy_path")\""
      else
        mkdir -p "$LEGACY_QUARANTINE_ROOT"
        mv "$legacy_path" "$LEGACY_QUARANTINE_ROOT/"
      fi
    else
      c_yellow "    keep $(basename "$legacy_path"): not a released Launch Control copy, so it may be yours (the pack skill is now $new_name)"
    fi
  done
}

while read -r old_skill new_skill; do
  retire_renamed_skill "$old_skill" "$new_skill"
done <<'RENAMES'
groundwork-reset offboard
decommission offboard
launch launch-ticket
mission launch-backlog
intake-to-research research-questions
research research-codebase
research-to-design design-doc
design-to-outline design-outline
outline-to-plan plan-write
plan-to-implementation plan-execute
review review-doc
bootstrap-docs docs-create
update-docs docs-update
foundations catalog
domain-facts catalog
decision-record log-decision
RENAMES

# ---------- 1b. strip dev-only fixtures ----------
# references/*-fixture-*.md files are acceptance-test snapshots taken from a real
# reference repo (command names, package layout) — useful for onboard's own testing,
# not for a teammate's live config. Never ship them.
FIXTURE_COUNT=0
for skill_dst in "${LAUNCH_CONTROL_SKILL_DESTS[@]}"; do
  [ -d "$skill_dst" ] || continue
  count="$(find "$skill_dst" -type f -path '*/references/*-fixture-*.md' 2>/dev/null | wc -l | tr -d ' ')"
  FIXTURE_COUNT=$((FIXTURE_COUNT + count))
done
if [ "$FIXTURE_COUNT" -gt 0 ]; then
  c_blue "\n==> Removing $FIXTURE_COUNT dev-only fixture file(s) (testing artifacts, not part of the shipped skill)"
  for skill_dst in "${LAUNCH_CONTROL_SKILL_DESTS[@]}"; do
    run find "$skill_dst" -type f -path '*/references/*-fixture-*.md' -delete
  done
fi

finish_launch_control_backup

if [ "$OPTIONAL_TOOLS" != 1 ]; then
  if [ -n "${LAUNCH_CONTROL_USER_OWNED[*]-}" ]; then
    c_yellow "\nPartial install complete. Declared user-managed paths were retained and do not have Launch Control source parity."
  else
    c_green "\nDone. Launch Control skills, agents, and required Superpowers provider are ready."
  fi
  echo "Restart Claude Code so it picks up the installed workspace tools."
  echo "Optional supporting CLIs were not installed; use --optional-tools if wanted."
  exit 0
fi

# ---------- 2. optional supporting CLIs ----------
c_blue "\n==> Supporting CLIs"

# All CLI installs below are guarded so a failure (npm EACCES, no brew/apt,
# network) warns and continues instead of aborting under `set -e`.

# gh (GitHub CLI) — used by launch / PR workflows when GitHub is the forge
if have gh; then
  c_green "    gh: present ($(gh --version | head -1))"
else
  c_yellow "    gh: missing"
  if have brew; then run brew install gh || true
  elif have apt-get; then
    { run sudo apt-get update && run sudo apt-get install -y gh; } || true
  else c_yellow "    install gh manually: https://cli.github.com/"; fi
  [ "$DRY_RUN" = 1 ] || have gh || c_yellow "    gh not installed (non-fatal) — install later: https://cli.github.com/"
fi

# ---------- 3. MCP servers (guidance only — no secrets, no auto-edit) ----------
c_blue "\n==> MCP servers used by these skills (optional, set up per your needs)"
cat <<'EOF'
    These skills can use MCP servers when present. They are OPTIONAL. Remote
    integrations may require user authentication through /mcp; local stdio
    servers run as child processes and do not use remote OAuth. None require
    pasting a secret into this repository.

    Recommended user-level servers (remote, OAuth):
      claude mcp add --scope user --transport http github https://api.githubcopilot.com/mcp/
      claude mcp add --scope user --transport sse atlassian https://mcp.atlassian.com/v1/sse

    Used by specific skills:
      github         -> launch, log-decision, PR workflows
      atlassian      -> log-decision (Jira/Confluence)
      shadcn         -> component search for UI work
      chrome-devtools -> optional web/E2E verification

    A secret-free reference config lives at: install/mcp.reference.json
    After adding a remote server, run /mcp in Claude Code if it requires authentication.
EOF

if [ -n "${LAUNCH_CONTROL_USER_OWNED[*]-}" ]; then
  c_yellow "\nPartial install complete. Declared user-managed paths were retained and do not have Launch Control source parity."
else
  c_green "\n=== Install complete ==="
fi
echo "Installed skills:  $SKILLS_DST"
echo "Installed agents:  $AGENTS_DST"
echo
echo "Next steps:"
echo "  1. Restart Claude Code (or run /doctor) so it loads the new skills + agents."
echo "  2. cd into any project and run /onboard for the complete Launch Control workspace."
echo "  3. Deliver with /launch-ticket <ticket>, or a BACKLOG section with /launch-backlog stage then /launch-backlog go."
echo "  4. Use /onboard --launch-control only to regenerate an existing project's delivery skill."
echo "  5. (optional) add MCP servers above, then /mcp to authenticate."
