#!/usr/bin/env bash

# Shared digest helpers for installer ownership checks and dogfood parity checks.
# Callers own shell options and error handling.
#
# Dev-only acceptance snapshots (`*/references/*-fixture-*.md`) are excluded from ownership:
# they never ship, because install.sh deletes them from every install, so an installed copy
# that still carried one would fail parity for a shipping reason.

launch_control_item_digest() {
  local item="$1"
  if [ -d "$item" ]; then
    (
      cd "$item" || exit 1
      find . -type f ! -path '*/references/*-fixture-*.md' -print \
        | LC_ALL=C sort \
        | while IFS= read -r file; do
            printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$file"
          done
    ) | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 "$item" | awk '{print $1}'
  fi
}

# Equality is the digest, and ONLY the digest. This used to be an independent `diff -qr`,
# which disagreed with `launch_control_item_digest` about empty directories: the digest walks
# `find . -type f` and cannot see them, while `diff -qr` reports "Only in <dst>: <dir>".
# Claude Code creates empty `.claude/.cc-writes/` scaffolding inside installed skill dirs,
# so the two definitions disagreed on every clean tree -- `preflight-onboard.sh` reported a
# mismatch no `install.sh --force` could clear, and both installer call sites fell through to
# a needless backup-and-replace of byte-identical skills. The digest was already the
# ownership authority in both of those fallthroughs; the second definition only manufactured
# disagreement, so it is gone rather than patched to agree.
#
# The deliberate ceiling: digest equality ignores empty directories (the point), file modes,
# and symlinks, because `-type f` matches neither. The shipped pack contains no symlinks --
# an installed symlink where source has a regular file changes the file LIST, so the digest
# still catches that. Adding a symlink to the source tree would need this revisited.
#
# One trap this move made load-bearing: the retired `diff` excluded the fixture glob by
# BASENAME anywhere in the tree, while the digest above excludes it only under a
# `references/` directory. Every such file currently lives there, so the two agreed. A future
# `*-fixture-*.md` placed outside `references/` would be counted here and deleted from the
# install, breaking parity on every clean tree -- keep them under `references/`.
launch_control_items_equal() {
  local source_item="$1" installed_item="$2"
  if [ -d "$source_item" ]; then
    [ -d "$installed_item" ] || return 1
  else
    [ -f "$installed_item" ] || return 1
  fi
  [ "$(launch_control_item_digest "$source_item")" = "$(launch_control_item_digest "$installed_item")" ]
}

launch_control_manifest_has_digest() {
  local manifest="$1" scope="$2" name="$3" digest="$4"
  awk -v scope="$scope" -v name="$name" -v digest="$digest" '
    $1 == scope && $2 == name && $3 == digest { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$manifest"
}

# A user can explicitly retain a colliding provider in the local Claude config
# without teaching Launch Control to own it. The declaration is deliberately local:
# shipped manifests only recognize released Launch Control hashes.
LAUNCH_CONTROL_USER_OWNED=()

# LC-036 retired these skill names. A declaration that names one still protects the user's own
# skill of that name, though the pack no longer ships a source directory for it.
LAUNCH_CONTROL_RETIRED_SKILLS=" groundwork-onboard groundwork-reset decommission launch mission intake-to-research research research-to-design design-to-outline outline-to-plan plan-to-implementation review bootstrap-docs update-docs workbench-to-confluence checkpoint load sessions synthesize triage foundations constellate capability-loop "

launch_control_user_owned_has() {
  local scope="$1" name="$2" entry
  for entry in "${LAUNCH_CONTROL_USER_OWNED[@]-}"; do
    [ "$entry" = "$scope $name" ] && return 0
  done
  return 1
}

launch_control_load_user_owned() {
  local config_dir="$1" skills_source="$2" agents_source="$3"
  local declaration="$config_dir/launch-control-user-owned.txt"
  local line scope name entry source destination
  LAUNCH_CONTROL_USER_OWNED=()
  [ -e "$declaration" ] || [ -L "$declaration" ] || return 0
  if [ -L "$declaration" ] || [ ! -f "$declaration" ]; then
    printf 'Invalid user-managed ownership declaration: %s must be a regular file.\n' "$declaration" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ ^(skills|agents)[[:space:]]+([a-z][a-z0-9-]*(\.md)?)$ ]]; then
      printf 'Invalid user-managed ownership declaration line: %s\n' "$line" >&2
      return 1
    fi
    scope="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    case "$scope" in
      skills)
        source="$skills_source/$name"
        destination="$config_dir/skills/$name"
        [ -d "$source" ] || [[ "$LAUNCH_CONTROL_RETIRED_SKILLS" == *" $name "* ]]
        ;;
      agents)
        source="$agents_source/$name"
        destination="$config_dir/agents/$name"
        [ -f "$source" ]
        ;;
    esac || {
      printf 'Invalid user-managed ownership declaration path: %s %s\n' "$scope" "$name" >&2
      return 1
    }
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      printf 'Declared user-managed path is missing: %s/%s\n' "$scope" "$name" >&2
      return 1
    fi
    entry="$scope $name"
    if launch_control_user_owned_has "$scope" "$name"; then
      printf 'Duplicate user-managed ownership declaration: %s\n' "$entry" >&2
      return 1
    fi
    LAUNCH_CONTROL_USER_OWNED+=("$entry")
  done < "$declaration"
}
