#!/usr/bin/env bash
# Native Codex conversion has no third-party Python dependencies.
python3 "$ROOT/tools/validate-codex-parity.py"

python3 "$ROOT/tools/validate-codex-install.py"

python3 "$ROOT/tools/validate-codex-agents.py"

python3 -B "$ROOT/tools/validate-portable-refresh.py"
