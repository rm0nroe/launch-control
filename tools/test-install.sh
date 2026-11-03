#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$ROOT/.launch-control-test-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"

case "$1 $2" in
  "plugin list")
    if [ "$FAKE_MODE" = "existing" ]; then
      echo "superpowers@superpowers-marketplace enabled"
    elif [ "$FAKE_MODE" = "disabled" ] && [ ! -f "$FAKE_STATE" ]; then
      printf '%s\n' "superpowers@claude-plugins-official" "Status: disabled"
    elif [ -f "$FAKE_STATE" ]; then
      echo "superpowers@claude-plugins-official enabled"
    fi
    ;;
  "plugin marketplace")
    test "$3" = "add"
    ;;
  "plugin install")
    if [ "$FAKE_MODE" = "failure" ]; then
      exit 9
    fi
    : > "$FAKE_STATE"
    ;;
  *)
    echo "unexpected fake claude call: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$TMP/bin/claude"

run_case() {
  local name="$1" mode="$2"
  run_case_from_root "$name" "$mode" "$ROOT" "${@:3}"
}

run_case_from_root() {
  local name="$1" mode="$2" installer_root="$3"
  local case_dir="$TMP/$name"
  mkdir -p "$case_dir"
  PATH="$TMP/bin:$PATH" \
    FAKE_MODE="$mode" \
    FAKE_STATE="$case_dir/provider-enabled" \
    FAKE_LOG="$case_dir/claude.log" \
    CLAUDE_CONFIG_DIR="$case_dir/config" \
    "$installer_root/install.sh" "${@:4}"
}

run_case existing existing >/dev/null
test -f "$TMP/existing/config/skills/onboard/SKILL.md"

# Paths are data, including shell syntax, in both the source checkout and destination.
python3 - "$ROOT" "$TMP" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
probe = scratch / 'literal-paths'
probe.mkdir()
for suffix in ('$(touch SUBSTITUTION)', '`touch BACKTICK`', '''spaces $dollar 'single' "double"'''):
    source = probe / ('source-' + suffix)
    source.mkdir()
    shutil.copy2(root / 'install.sh', source)
    for name in ('install', 'agents'):
        shutil.copytree(root / name, source / name)
    (source / 'tools').mkdir()
    shutil.copy2(root / 'tools/launch-control-digests.sh', source / 'tools')
    shutil.copytree(root / 'skills/onboard', source / 'skills/onboard')
    fixture = source / 'skills/onboard/references/path-fixture-probe.md'
    fixture.write_text('must not ship\n')
    dest = probe / ('config-' + suffix)
    env = dict(os.environ, PATH=str(scratch / 'bin') + os.pathsep + os.environ['PATH'],
               FAKE_MODE='existing', FAKE_LOG=str(probe / 'claude.log'),
               FAKE_STATE=str(probe / 'enabled'), CLAUDE_CONFIG_DIR=str(dest))
    for args in (['--dry-run'], []):
        result = subprocess.run([str(source / 'install.sh'), *args], cwd=probe, env=env,
                                text=True, capture_output=True)
        assert result.returncode == 0, (suffix, args, result.stdout, result.stderr)
        assert not (probe / 'SUBSTITUTION').exists() and not (probe / 'BACKTICK').exists(), 'path executed shell code'
        if args:
            assert not dest.exists(), 'dry run wrote its destination'
        else:
            assert (dest / 'skills/onboard/SKILL.md').is_file(), 'literal destination missing'
            assert not (dest / 'skills/onboard/references/path-fixture-probe.md').exists()

# Exercise the real optional-tools block with shell stubs; never install host tools.
script = (root / 'install.sh').read_text()
helper = script[script.index('run()'):script.index('\nmanifest_scope()')]
optional = script[script.index('# gh (GitHub CLI)'):script.index('# ---------- 3. MCP')]
stubs = r'''
c_green() { :; }; c_yellow() { :; }
have() {
  case "$1" in
    brew) [ "$MANAGER" = brew ] ;;
    apt-get) [ "$MANAGER" = apt ] ;;
    *) return 1 ;;
  esac
}
brew() { printf 'brew %s\n' "$*" >> "$CALLS"; return 7; }
sudo() { printf 'sudo %s\n' "$*" >> "$CALLS"; [ "$2" != update ] || [ "$UPDATE_FAIL" = 0 ]; }
'''
for manager, update_fail, dry in [('brew', 0, 0), ('apt', 0, 0), ('apt', 1, 0), ('apt', 0, 1)]:
    calls = probe / 'calls'
    calls.write_text('')
    env = dict(os.environ, MANAGER=manager, UPDATE_FAIL=str(update_fail), DRY_RUN=str(dry), CALLS=str(calls))
    result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + helper + stubs + optional],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    expected = [] if dry else (['brew install gh'] if manager == 'brew' else
                ['sudo apt-get update'] + ([] if update_fail else ['sudo apt-get install -y gh']))
    assert calls.read_text().splitlines() == expected, calls.read_text()
result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\nDRY_RUN=0\n' + helper + '\nrun false\necho unexpected'],
                        text=True, capture_output=True)
assert result.returncode != 0 and not result.stdout, 'required command failure was swallowed'
PY

for font_notice in ANTON BARLOW IBMPlexMono; do
  cmp "$ROOT/skills/onboard/assets/$font_notice-OFL.txt" "$TMP/existing/config/skills/onboard/assets/$font_notice-OFL.txt"
done
test "$(grep -c '^plugin install' "$TMP/existing/claude.log" || true)" -eq 0

# Every reference required by the installed router must ship with the installed skill.
while IFS= read -r router_reference; do
  test -f "$TMP/existing/config/skills/onboard/references/$router_reference"
done < <(sed -n 's|.*@references/\([A-Za-z0-9._-]*\.md\).*|\1|p' "$TMP/existing/config/skills/onboard/SKILL.md")

# Canonical source safety deltas and their bundles survive a fresh Claude install.
for canonical_skill in docs-create research-codebase docs-update review-doc offboard; do
  diff -qr "$ROOT/skills/$canonical_skill" "$TMP/existing/config/skills/$canonical_skill" >/dev/null
done
run_case existing existing >"$TMP/idempotent.txt"
if grep -q 'upgrade released\|force replace' "$TMP/idempotent.txt"; then
  echo "FAIL: unchanged Claude install was not idempotent" >&2
  exit 1
fi

run_case missing missing >/dev/null
test -f "$TMP/missing/provider-enabled"
test -f "$TMP/missing/config/skills/onboard/SKILL.md"
grep -q '^plugin install superpowers@claude-plugins-official$' "$TMP/missing/claude.log"

run_case disabled disabled >/dev/null
test -f "$TMP/disabled/provider-enabled"
grep -q '^plugin install superpowers@claude-plugins-official$' "$TMP/disabled/claude.log"

if run_case failure failure >/dev/null 2>&1; then
  echo "FAIL: installer succeeded after a Superpowers install failure" >&2
  exit 1
fi
test ! -e "$TMP/failure/config"

run_case dry-run missing --dry-run >/dev/null
test ! -e "$TMP/dry-run/config"
test ! -e "$TMP/dry-run/provider-enabled"
test "$(grep -c '^plugin install' "$TMP/dry-run/claude.log" || true)" -eq 0

legacy_intake_name='problem-to''-research'

seed_legacy_skills() {
  local case_dir="$1"
  local skills_dir="$case_dir/config/skills"
  mkdir -p \
    "$skills_dir/$legacy_intake_name" \
    "$skills_dir/$legacy_intake_name.bak-20260701-010101"
  printf '%s\n' 'custom active intake content' > "$skills_dir/$legacy_intake_name/custom-intake.txt"
  printf '%s\n' 'custom backup intake content' > "$skills_dir/$legacy_intake_name.bak-20260701-010101/custom-intake-backup.txt"
}

legacy_manifest() {
  local root="$1"
  (
    cd "$root"
    find . -print | LC_ALL=C sort
    find . -type f -exec shasum {} + | LC_ALL=C sort
  )
}

seed_discovery_backups() {
  local case_dir="$1"
  mkdir -p \
    "$case_dir/config/skills/onboard" \
    "$case_dir/config/skills/onboard.bak-20260701-030303" \
    "$case_dir/config/agents"
  printf '%s\n' 'custom current onboard content' > "$case_dir/config/skills/onboard/SKILL.md"
  printf '%s\n' 'custom prior onboard backup' > "$case_dir/config/skills/onboard.bak-20260701-030303/custom-onboard-backup.txt"
  printf '%s\n' 'custom current agent content' > "$case_dir/config/agents/navigator.md"
  printf '%s\n' 'custom prior agent backup' > "$case_dir/config/agents/navigator.md.bak-20260701-040404"
}

force_dir="$TMP/force-backup"
mkdir -p "$force_dir"
seed_discovery_backups "$force_dir"
run_case force-backup existing --force >/dev/null
test -f "$force_dir/config/skills/onboard/SKILL.md"
test -f "$force_dir/config/agents/navigator.md"
diff -qr -x '*-fixture-*.md' "$ROOT/skills/onboard" "$force_dir/config/skills/onboard" >/dev/null
diff -q "$ROOT/agents/navigator.md" "$force_dir/config/agents/navigator.md" >/dev/null
test ! -e "$force_dir/config/skills/onboard.bak-20260701-030303"
test ! -e "$force_dir/config/agents/navigator.md.bak-20260701-040404"
backup_base="$force_dir/config/launch-control-backups"
test "$(find "$backup_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1
backup_dir="$(find "$backup_base" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test "$(cat "$backup_dir/skills/onboard/SKILL.md")" = 'custom current onboard content'
test "$(cat "$backup_dir/skills/onboard.bak-20260701-030303/custom-onboard-backup.txt")" = 'custom prior onboard backup'
test "$(cat "$backup_dir/agents/navigator.md")" = 'custom current agent content'
test "$(cat "$backup_dir/agents/navigator.md.bak-20260701-040404")" = 'custom prior agent backup'
backup_before="$(legacy_manifest "$backup_base")"
run_case force-backup existing >/dev/null
test "$(legacy_manifest "$backup_base")" = "$backup_before"
test "$(find "$backup_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1

# --force over a user-modified copy alone (no `.bak-*`) is user content: its backup is kept.
force_only_dir="$TMP/force-only"
run_case force-only existing >/dev/null
printf '%s\n' 'user edit' >> "$force_only_dir/config/skills/onboard/SKILL.md"
force_only_output="$(run_case force-only existing --force)"
grep -q 'kept backup with user content' <<<"$force_only_output"
force_only_backup="$(find "$force_only_dir/config/launch-control-backups" -mindepth 1 -maxdepth 1 -type d -print -quit)"
grep -q 'user edit' "$force_only_backup/skills/onboard/SKILL.md"
test ! -e "$force_only_backup/.launch-control-backup-complete"

dry_force_dir="$TMP/dry-force-backup"
mkdir -p "$dry_force_dir"
seed_discovery_backups "$dry_force_dir"
dry_force_before="$(legacy_manifest "$dry_force_dir/config")"
dry_force_output="$(run_case dry-force-backup existing --force --dry-run)"
test "$(legacy_manifest "$dry_force_dir/config")" = "$dry_force_before"
test ! -e "$dry_force_dir/config/launch-control-backups"
grep -q 'quarantine discovery backup:' <<<"$dry_force_output"
grep -q 'force replace unknown/user-modified copy (backup outside discovery):' <<<"$dry_force_output"
grep -q '\[dry-run\] mv' <<<"$dry_force_output"

unknown_dir="$TMP/unknown"
mkdir -p "$unknown_dir/config/skills/onboard"
printf '%s\n' 'user-authored onboard skill' > "$unknown_dir/config/skills/onboard/SKILL.md"
unknown_before="$(legacy_manifest "$unknown_dir/config")"
if run_case unknown existing >"$unknown_dir/output.txt" 2>&1; then
  echo "FAIL: installer accepted an unknown/user-modified copy without --force" >&2
  exit 1
fi
test "$(legacy_manifest "$unknown_dir/config")" = "$unknown_before"
test ! -e "$unknown_dir/config/agents"
test ! -e "$unknown_dir/claude.log"
grep -q 'Install stopped before dependency or file changes.' "$unknown_dir/output.txt"
grep -q 'skills/onboard' "$unknown_dir/output.txt"

unknown_dry_before="$(legacy_manifest "$unknown_dir/config")"
if run_case unknown existing --dry-run >"$unknown_dir/dry-output.txt" 2>&1; then
  echo "FAIL: dry-run hid an unknown/user-modified copy conflict" >&2
  exit 1
fi
test "$(legacy_manifest "$unknown_dir/config")" = "$unknown_dry_before"
test ! -e "$unknown_dir/claude.log"

known_dir="$TMP/known-owned"
run_case known-owned existing >/dev/null
known_pack="$TMP/known-owned-new-pack"
# GNU cp refuses to copy a directory into its own descendant ($known_pack lives under $TMP,
# which lives under $ROOT), whereas BSD cp tolerates it. Copy the pack's top-level entries
# individually and skip the transient control directories so the copy is portable across
# GNU/BSD cp and never duplicates live scratch state into the released-pack fixture.
# Also skip .git, .claude, and .worktrees: the fixture only needs the released pack, and
# copying live repo metadata, a generated workspace, or a nested worktree checkout would
# balloon the fixture and leak protected local state into installer test input.
mkdir -p "$known_pack"
for pack_entry in "$ROOT"/* "$ROOT"/.[!.]* "$ROOT"/..?*; do
  [ -e "$pack_entry" ] || continue
  case "${pack_entry##*/}" in
    .launch-control-test-install.*|.launch-control-onboard|.git|.claude|.worktrees) continue ;;
  esac
  cp -R "$pack_entry" "$known_pack/"
done
printf '%s\n' '<!-- installer known-owned upgrade regression -->' >> "$known_pack/skills/onboard/SKILL.md"
known_output="$(run_case_from_root known-owned existing "$known_pack")"
grep -q 'upgrade released Launch Control copy (backup outside discovery): onboard' <<<"$known_output"
grep -q 'installer known-owned upgrade regression' "$known_dir/config/skills/onboard/SKILL.md"
known_backup_root="$known_dir/config/launch-control-backups"
test "$(find "$known_backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1
known_backup_dir="$(find "$known_backup_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
diff -qr -x '*-fixture-*.md' "$ROOT/skills/onboard" "$known_backup_dir/skills/onboard" >/dev/null

# Backup pruning: a successful run whose backup holds only released copies marks it complete
# and removes older complete backups of the same kind, so one version back is kept. A backup
# holding user content (the --force run above) or left unmarked (a failed or concurrent run)
# is never removed, and neither are hand-named dirs or symlinks.
test "$(cat "$known_backup_dir/.launch-control-backup-complete")" = claude
test ! -e "$backup_dir/.launch-control-backup-complete"
known_newer_pack="$TMP/known-owned-newer-pack"
cp -R "$known_pack" "$known_newer_pack"
printf 'skills onboard %s\n' "$(source "$ROOT/tools/launch-control-digests.sh" && launch_control_item_digest "$known_pack/skills/onboard")" \
  >> "$known_newer_pack/install/launch-control-owned-digests.txt"
printf '%s\n' '<!-- installer backup prune regression -->' >> "$known_newer_pack/skills/onboard/SKILL.md"
mkdir -p "$known_backup_root/20200101-000000/skills/onboard" "$known_backup_root/manual-keep" \
  "$known_backup_root/20200101-000002" "$known_backup_root/20200101-000003-10" "$TMP/prune-outside"
printf '%s\n' 'failed-run original' > "$known_backup_root/20200101-000000/skills/onboard/SKILL.md"
printf 'claude\n' > "$known_backup_root/manual-keep/.launch-control-backup-complete"
printf 'codex-skills\n' > "$known_backup_root/20200101-000002/.launch-control-backup-complete"
printf 'claude\n' > "$known_backup_root/20200101-000003-10/.launch-control-backup-complete"
printf 'claude\n' > "$TMP/prune-outside/.launch-control-backup-complete"
ln -s "$TMP/prune-outside" "$known_backup_root/20200101-000004"
prune_output="$(run_case_from_root known-owned existing "$known_newer_pack")"
grep -q "prune old backup: ${known_backup_dir##*/}" <<<"$prune_output"
test ! -e "$known_backup_dir"
test ! -e "$known_backup_root/20200101-000003-10"
test "$(cat "$known_backup_root/20200101-000000/skills/onboard/SKILL.md")" = 'failed-run original'
test -f "$known_backup_root/manual-keep/.launch-control-backup-complete"
test -f "$known_backup_root/20200101-000002/.launch-control-backup-complete"
test -L "$known_backup_root/20200101-000004"
test -f "$TMP/prune-outside/.launch-control-backup-complete"
prune_marked="$(find "$known_backup_root" -mindepth 2 -maxdepth 2 -path "$known_backup_root/2*" \
  -name .launch-control-backup-complete -exec grep -lx claude {} +)"
test "$(printf '%s\n' "$prune_marked" | wc -l | tr -d ' ')" -eq 1
diff -qr -x '*-fixture-*.md' "$known_pack/skills/onboard" "${prune_marked%/*}/skills/onboard" >/dev/null
prune_before="$(legacy_manifest "$known_backup_root")"
run_case_from_root known-owned existing "$known_newer_pack" >/dev/null
test "$(legacy_manifest "$known_backup_root")" = "$prune_before"

# LC-036: a released old-name copy is quarantined once its renamed skill is installed; a
# user's own skill under an old name (here `research`) stays in discovery.
rename_dir="$TMP/rename"
mkdir -p "$rename_dir/config/skills/review" "$rename_dir/config/skills/research"
printf '%s\n' 'released old review' > "$rename_dir/config/skills/review/SKILL.md"
printf '%s\n' 'my own research skill' > "$rename_dir/config/skills/research/SKILL.md"
source "$ROOT/tools/launch-control-digests.sh"
printf 'skills review %s\n' "$(launch_control_item_digest "$rename_dir/config/skills/review")" \
  >> "$known_pack/install/launch-control-owned-digests.txt"
quarantined_names() { sed -n 's/.*quarantine renamed skill: \([^ ]*\) ->.*/\1/p' | sort | tr '\n' ' '; }
rename_preview="$(run_case_from_root rename existing "$known_pack" --dry-run)"
test "$(quarantined_names <<<"$rename_preview")" = 'review '
test -f "$rename_dir/config/skills/review/SKILL.md"
rename_output="$(run_case_from_root rename existing "$known_pack")"
# Preview says exactly what the real run does, and a repeat install retires nothing.
test "$(quarantined_names <<<"$rename_output")" = 'review '
test ! -e "$rename_dir/config/skills/review"
test -f "$rename_dir/config/skills/review-doc/SKILL.md"
test "$(cat "$(find "$rename_dir/config/launch-control-legacy-skills" -path '*/review/SKILL.md' -print -quit)")" = 'released old review'
test "$(cat "$rename_dir/config/skills/research/SKILL.md")" = 'my own research skill'
grep -q 'keep research: not a released Launch Control copy' <<<"$rename_output"
test -z "$(run_case_from_root rename existing "$known_pack" | quarantined_names)"

# A declaration naming a released old-name copy keeps it in discovery, in preview and real run.
rename_owned="$TMP/rename-owned"
mkdir -p "$rename_owned/config/skills/review"
printf '%s\n' 'released old review' > "$rename_owned/config/skills/review/SKILL.md"
printf '%s\n' 'skills review' > "$rename_owned/config/launch-control-user-owned.txt"
test -z "$(run_case_from_root rename-owned existing "$known_pack" --dry-run | quarantined_names)"
test -z "$(run_case_from_root rename-owned existing "$known_pack" | quarantined_names)"
test -f "$rename_owned/config/skills/review/SKILL.md"

normal_backup_dir="$TMP/normal-backup"
run_case normal-backup existing >/dev/null
mkdir -p "$normal_backup_dir/config/skills/onboard.bak-20260701-050505"
printf '%s\n' 'normal-install prior backup' > "$normal_backup_dir/config/skills/onboard.bak-20260701-050505/sentinel.txt"
run_case normal-backup existing >/dev/null
test ! -e "$normal_backup_dir/config/skills/onboard.bak-20260701-050505"
normal_backup_root="$(find "$normal_backup_dir/config/launch-control-backups" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test "$(cat "$normal_backup_root/skills/onboard.bak-20260701-050505/sentinel.txt")" = 'normal-install prior backup'
# A quarantined `.bak-*` is user content: its backup is never marked, so no later run prunes it.
test ! -e "$normal_backup_root/.launch-control-backup-complete"
diff -qr -x '*-fixture-*.md' "$ROOT/skills/onboard" "$normal_backup_dir/config/skills/onboard" >/dev/null

upgrade_dir="$TMP/upgrade"
mkdir -p "$upgrade_dir"
seed_legacy_skills "$upgrade_dir"
run_case upgrade existing >/dev/null
test -f "$upgrade_dir/config/skills/research-questions/SKILL.md"
# Not `find ... | grep -q .`: when find DOES print a match, grep -q exits at the first line,
# find takes SIGPIPE, and pipefail turns the pipeline non-zero -- so the `if` goes false and
# this check silently passes in exactly the case it exists to catch. Capture, then test.
legacy_remaining="$(find "$upgrade_dir/config/skills" -mindepth 1 -maxdepth 1 \
  \( -name "$legacy_intake_name" -o -name "$legacy_intake_name.bak-*" \))"
if [ -n "$legacy_remaining" ]; then
  echo "FAIL: renamed skill remains under active discovery after upgrade" >&2
  exit 1
fi
quarantine_base="$upgrade_dir/config/launch-control-legacy-skills"
test "$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1
quarantine_dir="$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test "$(cat "$quarantine_dir/$legacy_intake_name/custom-intake.txt")" = 'custom active intake content'
test "$(cat "$quarantine_dir/$legacy_intake_name.bak-20260701-010101/custom-intake-backup.txt")" = 'custom backup intake content'

quarantine_before="$(legacy_manifest "$quarantine_base")"
run_case upgrade existing >/dev/null
test "$(legacy_manifest "$quarantine_base")" = "$quarantine_before"
test "$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1

dry_upgrade_dir="$TMP/dry-upgrade"
mkdir -p "$dry_upgrade_dir"
seed_legacy_skills "$dry_upgrade_dir"
dry_before="$(legacy_manifest "$dry_upgrade_dir/config")"
dry_output="$(run_case dry-upgrade existing --dry-run)"
test "$(legacy_manifest "$dry_upgrade_dir/config")" = "$dry_before"
test ! -e "$dry_upgrade_dir/config/launch-control-legacy-skills"
test ! -e "$dry_upgrade_dir/config/skills/research-questions"
grep -q 'quarantine renamed skill:' <<<"$dry_output"
grep -q '\[dry-run\] mv' <<<"$dry_output"

uninstall_dir="$TMP/uninstall"
run_case uninstall existing >/dev/null
mkdir -p "$uninstall_dir/config/skills/unrelated-tool"
printf '%s\n' 'user tool' > "$uninstall_dir/config/skills/unrelated-tool/SKILL.md"
uninstall_before="$(legacy_manifest "$uninstall_dir/config")"
uninstall_dry_output="$(run_case uninstall existing --uninstall --dry-run)"
test "$(legacy_manifest "$uninstall_dir/config")" = "$uninstall_before"
grep -q 'remove verified Launch Control copy:' <<<"$uninstall_dry_output"
grep -q 'No files were changed.' <<<"$uninstall_dry_output"
run_case uninstall existing --uninstall >/dev/null
test -f "$uninstall_dir/config/skills/unrelated-tool/SKILL.md"
test ! -e "$uninstall_dir/config/skills/onboard"
test ! -e "$uninstall_dir/config/agents/navigator.md"

uninstall_modified_dir="$TMP/uninstall-modified"
run_case uninstall-modified existing >/dev/null
printf '%s\n' 'user modification' >> "$uninstall_modified_dir/config/skills/onboard/SKILL.md"
modified_before="$(legacy_manifest "$uninstall_modified_dir/config")"
if run_case uninstall-modified existing --uninstall >"$uninstall_modified_dir/fail.txt" 2>&1; then
  echo "FAIL: uninstall removed an unknown/user-modified copy" >&2
  exit 1
fi
test "$(legacy_manifest "$uninstall_modified_dir/config")" = "$modified_before"
grep -q 'Uninstall stopped before file changes.' "$uninstall_modified_dir/fail.txt"
grep -q 'skills/onboard' "$uninstall_modified_dir/fail.txt"

run_case uninstall-modified existing --uninstall --force >/dev/null
test ! -e "$uninstall_modified_dir/config/skills/onboard"
uninstall_backup="$(find "$uninstall_modified_dir/config/launch-control-uninstall-backups" -type f -path '*/skills/onboard/SKILL.md' -print -quit)"
test -n "$uninstall_backup"
grep -q 'user modification' "$uninstall_backup"

user_owned_manifest() {
  local case_dir="$1"
  (
    cd "$case_dir/config"
    find skills/onboard skills/onboard.bak-20260701-060606 \
      agents/navigator.md agents/navigator.md.bak-20260701-060606 -print | LC_ALL=C sort
    find skills/onboard skills/onboard.bak-20260701-060606 \
      agents/navigator.md agents/navigator.md.bak-20260701-060606 \
      -type f -exec shasum {} + | LC_ALL=C sort
  )
}

# A declared provider is intentionally outside Launch Control ownership. Exercise the real,
# force, fixture-strip, backup-quarantine, and uninstall paths against the same directory.
user_owned_dir="$TMP/user-owned"
mkdir -p "$user_owned_dir/config/skills/onboard/references" \
  "$user_owned_dir/config/skills/onboard.bak-20260701-060606" \
  "$user_owned_dir/config/agents"
printf '%s\n' 'foreign active provider' > "$user_owned_dir/config/skills/onboard/SKILL.md"
printf '%s\n' 'foreign fixture stays' > "$user_owned_dir/config/skills/onboard/references/user-fixture-fixture.md"
printf '%s\n' 'foreign discovery backup stays' > "$user_owned_dir/config/skills/onboard.bak-20260701-060606/SKILL.md"
printf '%s\n' 'foreign agent provider' > "$user_owned_dir/config/agents/navigator.md"
printf '%s\n' 'foreign agent backup stays' > "$user_owned_dir/config/agents/navigator.md.bak-20260701-060606"
printf '%s\n' 'skills onboard' 'agents navigator.md' > "$user_owned_dir/config/launch-control-user-owned.txt"
user_owned_before="$(user_owned_manifest "$user_owned_dir")"
user_owned_output="$(run_case user-owned existing)"
test "$(user_owned_manifest "$user_owned_dir")" = "$user_owned_before"
grep -q 'preserve declared user-managed path: skills/onboard' <<<"$user_owned_output"
grep -q 'preserve declared user-managed path: agents/navigator.md' <<<"$user_owned_output"
grep -q 'Partial install complete' <<<"$user_owned_output"
user_owned_force_output="$(run_case user-owned existing --force)"
test "$(user_owned_manifest "$user_owned_dir")" = "$user_owned_before"
grep -q 'preserve declared user-managed path: skills/onboard' <<<"$user_owned_force_output"
if CLAUDE_CONFIG_DIR="$user_owned_dir/config" "$ROOT/tools/preflight-onboard.sh" >"$user_owned_dir/preflight.txt" 2>&1; then
  echo "FAIL: preflight claimed parity for a divergent declared user-managed skill" >&2
  exit 1
fi
grep -q 'intentional user-owned mismatch: skills/onboard' "$user_owned_dir/preflight.txt"
grep -q 'retained intentionally' "$user_owned_dir/preflight.txt"
run_case user-owned existing --uninstall >/dev/null
test "$(user_owned_manifest "$user_owned_dir")" = "$user_owned_before"
test -f "$user_owned_dir/config/launch-control-user-owned.txt"

# A declaration retains the renamed family too, so it cannot silently rewrite a user's
# provider while preserving its replacement name.
user_owned_legacy_dir="$TMP/user-owned-legacy"
mkdir -p "$user_owned_legacy_dir/config/skills/research-questions" \
  "$user_owned_legacy_dir/config/skills/$legacy_intake_name"
printf '%s\n' 'foreign current intake' > "$user_owned_legacy_dir/config/skills/research-questions/SKILL.md"
printf '%s\n' 'foreign legacy intake' > "$user_owned_legacy_dir/config/skills/$legacy_intake_name/SKILL.md"
printf '%s\n' 'skills research-questions' > "$user_owned_legacy_dir/config/launch-control-user-owned.txt"
run_case user-owned-legacy existing --force >/dev/null
test "$(cat "$user_owned_legacy_dir/config/skills/research-questions/SKILL.md")" = 'foreign current intake'
test "$(cat "$user_owned_legacy_dir/config/skills/$legacy_intake_name/SKILL.md")" = 'foreign legacy intake'

# LC-036: a declaration naming a retired skill (the user's own `research`) still loads.
retired_owned_dir="$TMP/retired-owned"
mkdir -p "$retired_owned_dir/config/skills/research"
printf '%s\n' 'my own research skill' > "$retired_owned_dir/config/skills/research/SKILL.md"
printf '%s\n' 'skills research' > "$retired_owned_dir/config/launch-control-user-owned.txt"
run_case retired-owned existing >/dev/null
test "$(cat "$retired_owned_dir/config/skills/research/SKILL.md")" = 'my own research skill'

malformed_owned_dir="$TMP/malformed-user-owned"
mkdir -p "$malformed_owned_dir/config"
printf '%s\n' 'skills ../onboard' > "$malformed_owned_dir/config/launch-control-user-owned.txt"
malformed_before="$(legacy_manifest "$malformed_owned_dir/config")"
if run_case malformed-user-owned existing >"$malformed_owned_dir/output.txt" 2>&1; then
  echo "FAIL: malformed user-managed declaration reached the installer" >&2
  exit 1
fi
test "$(legacy_manifest "$malformed_owned_dir/config")" = "$malformed_before"
test ! -e "$malformed_owned_dir/claude.log"
grep -q 'Invalid user-managed ownership declaration line' "$malformed_owned_dir/output.txt"

missing_owned_dir="$TMP/missing-user-owned"
mkdir -p "$missing_owned_dir/config"
printf '%s\n' 'skills onboard' > "$missing_owned_dir/config/launch-control-user-owned.txt"
if run_case missing-user-owned existing >"$missing_owned_dir/output.txt" 2>&1; then
  echo "FAIL: missing declared user-managed path reached the installer" >&2
  exit 1
fi
test ! -e "$missing_owned_dir/claude.log"
grep -q 'Declared user-managed path is missing: skills/onboard' "$missing_owned_dir/output.txt"

preflight_dir="$TMP/preflight"
run_case preflight existing >/dev/null
CLAUDE_CONFIG_DIR="$preflight_dir/config" "$ROOT/tools/preflight-onboard.sh" >"$preflight_dir/pass.txt"
grep -q 'preflight passed' "$preflight_dir/pass.txt"
printf '%s\n' 'user edit' >> "$preflight_dir/config/skills/onboard/SKILL.md"
if CLAUDE_CONFIG_DIR="$preflight_dir/config" "$ROOT/tools/preflight-onboard.sh" >"$preflight_dir/fail.txt" 2>&1; then
  echo "FAIL: dogfood preflight accepted installed/source drift" >&2
  exit 1
fi
grep -q 'differs: skills/onboard' "$preflight_dir/fail.txt"
grep -q '^  ./install.sh --force$' "$preflight_dir/fail.txt"
grep -q 'fully restart Claude Code' "$preflight_dir/fail.txt"

printf '%s\n' 'Installer regression tests passed.'
