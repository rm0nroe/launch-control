# shellcheck shell=bash
# Licensing, executable bits, README/reference-doc assertions.
# Sourced by tools/validate-pack.sh. Not standalone: shares $ROOT, $failures,
# run_rg/check_absent from tools/validate/lib.sh and state from earlier parts.
test -f "$ROOT/LICENSE"
test -f "$ROOT/NOTICE"
test -x "$ROOT/skills/onboard/scripts/render-report.sh"
test -x "$ROOT/skills/onboard/scripts/completion-guard.sh"
test -x "$ROOT/skills/onboard/scripts/unattended-policy.sh"
test -x "$ROOT/skills/onboard/scripts/discovery-checkpoint.sh"
test -x "$ROOT/skills/docs-create/scripts/invocation-proof.sh"
test -x "$ROOT/tools/test-install.sh"
test -x "$ROOT/tools/preflight-onboard.sh"
test -x "$ROOT/tools/mutation-run.sh"
test -r "$ROOT/install/launch-control-owned-digests.txt"
run_rg -q 'unknown or user-modified[[:space:][:print:]]*stops? before' "$ROOT/README.md" || \
  run_rg -q 'Unknown or user-modified differing copies stop the entire install before' "$ROOT/README.md"
run_rg -q './tools/preflight-onboard.sh' "$ROOT/README.md"
run_rg -q 'ordinary session in this checkout' "$ROOT/README.md" "$ROOT/tools/preflight-onboard.sh"
run_rg -q -- '--uninstall --dry-run' "$ROOT/README.md"
run_rg -q 'Superpowers and paths absent from the ownership manifest were preserved' "$ROOT/install.sh"
if [ -e "$ROOT/tools/launch-onboard-isolated.sh" ]; then
  printf '%s\n' 'FAIL: obsolete isolated onboard launcher still exists' >&2
  exit 1
fi
check_absent '\[yyyy\]|\[name of copyright owner\]' "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/skills"

run_rg -q 'name: launch' "$ROOT/skills/onboard/references/launch-template.md"
run_rg -q '^## Root router$' "$ROOT/skills/onboard/references/launch-acceptance-criteria.md"
run_rg -q 'project-local.*CLAUDE' "$ROOT/skills/onboard/references/launch-discovery.md"
run_rg -q 'HAS_CODE_SEARCH_MCP' \
  "$ROOT/skills/onboard/references/launch-ticket-intake-template.md"
run_rg -q 'DETECTED_TEST_FRAMEWORK' "$ROOT/skills/onboard/references/skills-agents-and-commands.md"


# Preflight runs against a synthetic ROOT: it derives ROOT from its own location, so a copy of
# the two scripts it needs is a complete, isolated installation of it.
pf_root="$installer_tmp/preflight-root"
mkdir -p "$pf_root/tools" "$pf_root/skills" "$pf_root/agents"
cp "$ROOT/tools/preflight-onboard.sh" "$ROOT/tools/launch-control-digests.sh" "$pf_root/tools/"
cp -R "$ROOT/skills/plan-write" "$pf_root/skills/plan-write"

# TC7: an installed copy that differs from source ONLY by an empty directory is equal.
# `launch_control_items_equal` used to be an independent `diff -qr`, which reports
# "Only in <dst>: <dir>" for a directory the digest's `find . -type f` cannot see. Claude
# Code creates empty `.claude/.cc-writes/` scaffolding inside installed skill dirs, so the
# two definitions disagreed on every clean tree and preflight reported a mismatch that no
# `install.sh --force` could clear. Asserted at the unit level first, because the two
# definitions disagreeing is the defect -- the preflight failure below was only its symptom.
pf_empty_src="$installer_tmp/empty-dir-src"
pf_empty_dst="$installer_tmp/empty-dir-dst"
rm -rf "$pf_empty_src" "$pf_empty_dst"
cp -R "$ROOT/skills/plan-write" "$pf_empty_src"
cp -R "$ROOT/skills/plan-write" "$pf_empty_dst"
mkdir -p "$pf_empty_dst/.cc-writes"
if ! launch_control_items_equal "$pf_empty_src" "$pf_empty_dst"; then
  printf '%s\n' 'FAIL: an empty directory on the installed side broke item equality; the digest and the equality check disagree again' >&2
  exit 1
fi

# Control for TC7: over-correcting to "always equal" must not pass. A real content
# difference in the same pair still reports a mismatch.
printf '\n<!-- divergent content -->\n' >> "$pf_empty_dst/SKILL.md"
if launch_control_items_equal "$pf_empty_src" "$pf_empty_dst"; then
  printf '%s\n' 'FAIL: item equality ignored a real content difference' >&2
  exit 1
fi

# TC8: the end-to-end symptom. A byte-identical copy carrying only Claude Code's empty
# scaffolding must leave preflight silent and exit zero.
pf_scaffold_config="$installer_tmp/preflight-scaffold-config"
rm -rf "$pf_scaffold_config"
mkdir -p "$pf_scaffold_config/skills" "$pf_scaffold_config/agents"
cp -R "$pf_root/skills/plan-write" "$pf_scaffold_config/skills/plan-write"
mkdir -p "$pf_scaffold_config/skills/plan-write/.cc-writes"
pf_scaffold_out="$installer_tmp/preflight-scaffold.out"
if ! CLAUDE_CONFIG_DIR="$pf_scaffold_config" "$pf_root/tools/preflight-onboard.sh" > "$pf_scaffold_out" 2>&1; then
  printf '%s\n' 'FAIL: preflight reported a mismatch for a copy differing only by empty Claude Code scaffolding' >&2
  cat "$pf_scaffold_out" >&2
  exit 1
fi

# --- offboard -------------------------------------------------------------------------------
# The round-11 incident is the reason this script exists: `rm -rf .claude` deleted 24 TRACKED
# files in target repo A, which commits its `.claude/` tree. These cases pin the two rules
# that came out of it -- enumerate paths, and never delete a tracked file -- plus the
# byte-exact restore of merged files, which is what makes the reset a real reset.
bash -n "$ROOT/skills/offboard/scripts/reset.sh"
reset_sh="$ROOT/skills/offboard/scripts/reset.sh"

reset_fixture() {
  # $1 = destination repo. Builds a pre-onboard commit, then layers onboard output over it.
  local repo="$1"
  mkdir -p "$repo/.claude/commands"
  git -C "$repo" init -q .
  git -C "$repo" config user.email validator@example.com
  git -C "$repo" config user.name validator
  printf '# My Project\n\nUser prose.\n' > "$repo/CLAUDE.md"
  printf 'node_modules/\n.env\n' > "$repo/.gitignore"
  printf 'user own command\n' > "$repo/.claude/commands/explore.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm pre-onboard
  mkdir -p "$repo/.claude/agents" "$repo/artifacts" "$repo/.launch-control-onboard"
  printf 'generated\n' > "$repo/.claude/agents/inspector.md"
  printf 'generated\n' > "$repo/.claude/commands/pr.md"
  printf 'generated\n' > "$repo/artifacts/architecture.md"
  printf 'ledger\n' > "$repo/.launch-control-onboard/ledger.txt"
  : > "$(git -C "$repo" rev-parse --absolute-git-dir)/launch-control-onboard-run-validator.mode"
  mkdir -p "$(git -C "$repo" rev-parse --absolute-git-dir)/launch-control"
  printf 'report\n' > "$(git -C "$repo" rev-parse --absolute-git-dir)/launch-control/onboard-report.html"
  # The generated block carries no comment markers: it is the `## Generated Quick Reference`
  # heading through the next top-level heading or EOF, and the `# Claude Code local files` rule
  # group in .gitignore. Put user prose BELOW the block (under its own top-level heading) to prove
  # the strip stops at the boundary rather than running to end of file.
  printf '## Generated Quick Reference\n\ngen\n\n# My Project\n\nUser prose.\n' \
    > "$repo/CLAUDE.md"
  printf '\n# Claude Code local files\n.claude/settings.local.json\n.claude/*.local.*\nCLAUDE.local.md\n.launch-control-onboard/\n' \
    >> "$repo/.gitignore"
}

# TC9: the default run is a preview and must change nothing.
reset_dry="$installer_tmp/reset-dry"
mkdir -p "$reset_dry"
reset_fixture "$reset_dry"
reset_dry_before="$(cd "$reset_dry" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | shasum -a 256)"
( cd "$reset_dry" && "$reset_sh" ) > "$installer_tmp/reset-dry.out" 2>&1
if [ "$(cd "$reset_dry" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | shasum -a 256)" != "$reset_dry_before" ]; then
  printf '%s\n' 'FAIL: offboard changed the tree without --apply' >&2
  exit 1
fi
run_rg -q 'Preview only' "$installer_tmp/reset-dry.out"

# TC10: --apply removes generated files, strips merged blocks byte-exactly, clears control
# state, and leaves the user's TRACKED file alone.
reset_apply="$installer_tmp/reset-apply"
mkdir -p "$reset_apply"
reset_fixture "$reset_apply"
( cd "$reset_apply" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-apply.out" 2>&1

for gone in .claude/agents/inspector.md .claude/commands/pr.md artifacts/architecture.md .launch-control-onboard; do
  if [ -e "$reset_apply/$gone" ]; then
    printf '%s\n' "FAIL: offboard left generated path behind: $gone" >&2
    exit 1
  fi
done
if [ -e "$(git -C "$reset_apply" rev-parse --absolute-git-dir)/launch-control-onboard-run-validator.mode" ]; then
  printf '%s\n' 'FAIL: offboard left an onboard run marker behind' >&2
  exit 1
fi
if [ -e "$(git -C "$reset_apply" rev-parse --absolute-git-dir)/launch-control" ]; then
  printf '%s\n' 'FAIL: offboard left the onboard visual report behind' >&2
  exit 1
fi
# The round-11 rule. A tracked file the user wrote must survive, and so must its directory.
if [ ! -f "$reset_apply/.claude/commands/explore.md" ]; then
  printf '%s\n' 'FAIL: offboard deleted a TRACKED user file -- the round-11 incident, reintroduced' >&2
  exit 1
fi
# Byte-exact restore: stripping the blocks must return both merged files to their committed
# state, so git reports no modification at all.
if [ -n "$(git -C "$reset_apply" status --porcelain -- CLAUDE.md .gitignore)" ]; then
  printf '%s\n' 'FAIL: offboard did not restore the merged files byte-for-byte' >&2
  git -C "$reset_apply" status --porcelain -- CLAUDE.md .gitignore >&2
  exit 1
fi

# TC10b (LC-061): a `/onboard --codex` workspace is removed too. Codex mirrors of the generated
# skills, commands and agents go with their agent ownership records, and so does the refresh
# receipt of every bundle removed: a receipt left behind makes the next onboard misread the fresh
# bundle as customized, or refuse to recreate it. User Codex config, refresh backups, and a
# tracked Codex skill survive.
reset_codex="$installer_tmp/reset-codex"
mkdir -p "$reset_codex"
reset_fixture "$reset_codex"
mkdir -p "$reset_codex/.codex/skills/explore"
printf 'user tracked codex skill\n' > "$reset_codex/.codex/skills/explore/SKILL.md"
printf 'model = "user"\n' > "$reset_codex/.codex/config.toml"
git -C "$reset_codex" add -A
git -C "$reset_codex" commit -qm user-codex
mkdir -p "$reset_codex/.claude/skills/checkpoint-list"
printf 'tracked note\n' > "$reset_codex/.claude/skills/checkpoint-list/notes.md"
git -C "$reset_codex" add -A
git -C "$reset_codex" commit -qm partly-tracked-bundle
for generated in .claude/skills/checkpoint-save/SKILL.md .codex/skills/checkpoint-save/SKILL.md \
  .codex/skills/pr/SKILL.md .codex/agents/inspector.toml .codex/agents/dispatcher.toml \
  .claude/skills/checkpoint-list/SKILL.md .launch-control/refresh/receipts/claude/checkpoint-list.json \
  .launch-control/refresh/receipts/claude/checkpoint-save.json .launch-control/refresh/receipts/codex/checkpoint-save.json \
  .launch-control/refresh/operations/op1/backup.txt; do
  mkdir -p "$reset_codex/$(dirname "$generated")"
  printf 'generated\n' > "$reset_codex/$generated"
done
# Only inspector carries an ownership record naming its exact bytes; dispatcher has none.
mkdir -p "$reset_codex/.codex/launch-control-agent-ownership"
printf '{"name": "inspector", "sha256": "%s", "version": 1}\n' \
  "$(shasum -a 256 "$reset_codex/.codex/agents/inspector.toml" | awk '{print $1}')" \
  > "$reset_codex/.codex/launch-control-agent-ownership/inspector.json"
# codex-parity.py mirrors the CLAUDE.md block into AGENTS.md, a path no manifest lists.
printf '## Generated Quick Reference\n\nmirrored\n' > "$reset_codex/AGENTS.md"
( cd "$reset_codex" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-codex.out" 2>&1
for gone in AGENTS.md .claude/skills/checkpoint-save .codex/skills/checkpoint-save .codex/skills/pr .codex/agents/inspector.toml \
  .codex/launch-control-agent-ownership .claude/skills/checkpoint-list/SKILL.md \
  .launch-control/refresh/receipts/claude/checkpoint-save.json .launch-control/refresh/receipts/codex; do
  if [ -e "$reset_codex/$gone" ]; then
    printf '%s\n' "FAIL: offboard left a generated Codex or receipt path behind: $gone" >&2
    exit 1
  fi
done
for kept in .codex/config.toml .codex/skills/explore/SKILL.md .launch-control/refresh/operations/op1/backup.txt \
  .codex/agents/dispatcher.toml .claude/skills/checkpoint-list/notes.md \
  .launch-control/refresh/receipts/claude/checkpoint-list.json; do
  if [ ! -f "$reset_codex/$kept" ]; then
    printf '%s\n' "FAIL: offboard removed a path it does not own or a partly kept bundle's receipt: $kept" >&2
    exit 1
  fi
done
run_rg -q 'NOT removed -- not provably generated' "$installer_tmp/reset-codex.out"
# A symlinked .codex reaches outside the repository: nothing is deleted through it.
reset_linked="$installer_tmp/reset-linked"
mkdir -p "$reset_linked" "$installer_tmp/reset-linked-outside/skills/pr"
reset_fixture "$reset_linked"
printf 'outside the repo\n' > "$installer_tmp/reset-linked-outside/skills/pr/SKILL.md"
ln -s "$installer_tmp/reset-linked-outside" "$reset_linked/.codex"
# A symlinked merge target is never rewritten: the strip would land in the file outside.
for linked in AGENTS.md CLAUDE.md; do
  printf '# Outside\n\n## Generated Quick Reference\n\ngen\n' > "$installer_tmp/reset-linked-outside/$linked"
  rm -f "$reset_linked/$linked"
  ln -s "$installer_tmp/reset-linked-outside/$linked" "$reset_linked/$linked"
done
( cd "$reset_linked" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-linked.out" 2>&1
if [ ! -f "$installer_tmp/reset-linked-outside/skills/pr/SKILL.md" ]; then
  printf '%s\n' 'FAIL: offboard deleted a file through a symlinked .codex directory' >&2
  exit 1
fi
for linked in AGENTS.md CLAUDE.md; do
  if ! LC_ALL=C grep -Fqx 'gen' "$installer_tmp/reset-linked-outside/$linked"; then
    printf '%s\n' "FAIL: offboard stripped a block through a symlinked $linked" >&2
    exit 1
  fi
done
# A tracked AGENTS.md with user prose loses only the appended block, byte-exactly.
reset_agents="$installer_tmp/reset-agents"
mkdir -p "$reset_agents"
reset_fixture "$reset_agents"
printf '# Team rules\n\nUser prose.\n' > "$reset_agents/AGENTS.md"
git -C "$reset_agents" add AGENTS.md
git -C "$reset_agents" commit -qm user-agents
printf '\n## Generated Quick Reference\n\nmirrored\n' >> "$reset_agents/AGENTS.md"
( cd "$reset_agents" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-agents.out" 2>&1
if [ -n "$(git -C "$reset_agents" status --porcelain -- AGENTS.md)" ]; then
  printf '%s\n' 'FAIL: offboard did not strip the mirrored AGENTS.md block byte-exactly' >&2
  exit 1
fi

# TC11: a merged file that was ENTIRELY the generated block, and is tracked, must survive.
# Launch Control's own CLAUDE.md has this shape, so it is the common case, not an edge case.
reset_whole="$installer_tmp/reset-whole"
mkdir -p "$reset_whole"
git -C "$reset_whole" init -q .
git -C "$reset_whole" config user.email validator@example.com
git -C "$reset_whole" config user.name validator
printf '## Generated Quick Reference\n\nall generated\n' \
  > "$reset_whole/CLAUDE.md"
printf 'seed\n' > "$reset_whole/.gitignore"
git -C "$reset_whole" add -A
git -C "$reset_whole" commit -qm pre-onboard
( cd "$reset_whole" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-whole.out" 2>&1
if [ ! -f "$reset_whole/CLAUDE.md" ]; then
  printf '%s\n' 'FAIL: offboard deleted a tracked CLAUDE.md that was entirely generated' >&2
  exit 1
fi
run_rg -q 'entirely generated but tracked by git' "$installer_tmp/reset-whole.out"

# TC11b: a repository onboarded by an OLDER Launch Control still carries the legacy comment markers.
# Reset must strip that block too, so the old onboarding can be undone by the current reset.
reset_legacy="$installer_tmp/reset-legacy"
mkdir -p "$reset_legacy/.launch-control-onboard"
git -C "$reset_legacy" init -q .
git -C "$reset_legacy" config user.email validator@example.com
git -C "$reset_legacy" config user.name validator
printf '# My Project\n\nUser prose.\n' > "$reset_legacy/CLAUDE.md"
git -C "$reset_legacy" add -A
git -C "$reset_legacy" commit -qm pre-onboard
printf '\n<!-- BEGIN GENERATED SECTION -- onboard -->\n<!-- Re-run /onboard to update. -->\nlegacy gen\n<!-- END GENERATED SECTION -- onboard -->\n' \
  >> "$reset_legacy/CLAUDE.md"
printf 'ledger\n' > "$reset_legacy/.launch-control-onboard/ledger.txt"
( cd "$reset_legacy" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-legacy.out" 2>&1
if LC_ALL=C grep -q 'GENERATED SECTION' "$reset_legacy/CLAUDE.md"; then
  printf '%s\n' 'FAIL: offboard left legacy onboard comment markers in CLAUDE.md' >&2
  exit 1
fi
if [ -n "$(git -C "$reset_legacy" status --porcelain -- CLAUDE.md)" ]; then
  printf '%s\n' 'FAIL: offboard did not strip the legacy marker block byte-exactly' >&2
  git -C "$reset_legacy" status --porcelain -- CLAUDE.md >&2
  exit 1
fi

# TC12: refuse to run anywhere but the repository root.
mkdir -p "$reset_apply/subdir"
if ( cd "$reset_apply/subdir" && "$reset_sh" ) > "$installer_tmp/reset-subdir.out" 2>&1; then
  printf '%s\n' 'FAIL: offboard ran from a subdirectory instead of refusing' >&2
  exit 1
fi
run_rg -q 'run from the repository root' "$installer_tmp/reset-subdir.out"

# TC11c: the current contract's common shape, user prose above and the heading-delimited block
# appended as the tail of the file, strips byte-exactly with no marker to find.
reset_tail="$installer_tmp/reset-tail"
mkdir -p "$reset_tail/.launch-control-onboard"
git -C "$reset_tail" init -q .
git -C "$reset_tail" config user.email validator@example.com
git -C "$reset_tail" config user.name validator
printf '# My Project\n\nUser prose.\n' > "$reset_tail/CLAUDE.md"
git -C "$reset_tail" add -A
git -C "$reset_tail" commit -qm pre-onboard
printf '\n## Generated Quick Reference\n\n### Commands\n\ngen rows\n' >> "$reset_tail/CLAUDE.md"
printf 'ledger\n' > "$reset_tail/.launch-control-onboard/ledger.txt"
( cd "$reset_tail" && "$reset_sh" --apply --yes ) > "$installer_tmp/reset-tail.out" 2>&1
if [ -n "$(git -C "$reset_tail" status --porcelain -- CLAUDE.md)" ]; then
  printf '%s\n' 'FAIL: offboard did not strip the appended heading-delimited block byte-exactly' >&2
  git -C "$reset_tail" status --porcelain -- CLAUDE.md >&2
  exit 1
fi

# Documented portable-refresh commands must name skills the CLI accepts (LC-036 review of #66:
# three docs still told readers to select the retired names, which argparse rejects).
for doc in "$ROOT/README.md" "$ROOT"/skills/onboard/references/*.md "$ROOT"/skills/*/SKILL.md; do
  for word in $(grep -oE -- '--skill [a-z-]+' "$doc" | awk '{print $2}' | sort -u); do
    case " checkpoint-save checkpoint-load checkpoint-list " in
      *" $word "*) ;;
      *) printf 'FAIL: %s documents --skill %s, which portable-refresh rejects\n' "$doc" "$word" >&2; exit 1 ;;
    esac
  done
done

# LC-036 review: the checkpoint trio is generated by a model and then compared byte for byte with
# the template. A template carrying an em or en dash is rewritten by any model following the
# user's punctuation rules, so the copy is classified customized and never upgraded again. The
# templates therefore carry neither character.
for checkpoint_template in "$ROOT/skills/onboard/references/checkpoint-templates.md"; do
  if grep -q -F -e '—' -e '–' "$checkpoint_template"; then
    printf 'FAIL: %s carries an em or en dash, which a generating model rewrites and so defeats byte-exact refresh\n' "$checkpoint_template" >&2
    exit 1
  fi
done
