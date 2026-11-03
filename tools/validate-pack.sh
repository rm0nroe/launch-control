#!/usr/bin/env bash
set -euo pipefail

# The declared validation contract's first command. The suite itself lives in
# tools/validate/: lib.sh defines the shared state and helpers, and each part is
# sourced in order into this shell -- the parts build on each other's fixtures
# and temp directories, so the order below is load-bearing, not cosmetic.

VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/validate" && pwd)"
# shellcheck source=validate/lib.sh
. "$VALIDATE_LIB_DIR/lib.sh"

VALIDATE_PARTS=(
  10-pack-inventory.sh
  15-launch-contract.sh
  20-policy.sh
  25-design-outline.sh
  27-codex-parity.sh
  30-guard-lifecycle.sh
  40-report-contract.sh
  45-pack-assets.sh
  50-round11.sh
  60-round12.sh
  70-round13.sh
  80-round41.sh
)

for validate_part in "${VALIDATE_PARTS[@]}"; do
  if [ ! -f "$VALIDATE_LIB_DIR/$validate_part" ]; then
    printf 'FAIL: validator part missing: tools/validate/%s\n' "$validate_part" >&2
    exit 1
  fi
done

for validate_part in "${VALIDATE_PARTS[@]}"; do
  # shellcheck source=/dev/null
  . "$VALIDATE_LIB_DIR/$validate_part"
done

if [ "$failures" -gt 0 ]; then
  printf 'Validation failed with %s issue(s).\n' "$failures" >&2
  exit 1
fi


python3 "$ROOT/tools/test-launch-process.py"
python3 "$ROOT/tools/test-launch-runtime.py"
python3 "$ROOT/tools/test-launch-handoff.py"
python3 "$ROOT/tools/test-launch-native.py"
python3 "$ROOT/tools/test-launch-delivery.py"
python3 "$ROOT/tools/test-launch-publication.py"
python3 "$ROOT/tools/test-launch-claude.py"
python3 "$ROOT/tools/test-launch-rollover.py"
python3 "$ROOT/tools/test-codex-autonomy.py"
printf '%s\n' 'Validation passed.'
