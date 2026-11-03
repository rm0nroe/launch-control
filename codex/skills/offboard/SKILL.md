---
name: offboard
description: "Remove the workspace /onboard generated in this repository: generated files, merged generated blocks, and onboard control state. Use when resetting an acceptance repo before a fresh /onboard run, undoing an onboarding, or handing a repo back clean. Usage: /offboard [--apply]"
---

Read `../snippets-shared-by-skills/codex-runtime.md`, then `references/workflow.md` in full. Follow the workflow with those native runtime mechanics.

This resets the generated project manifest and its `/onboard --codex` mirror under `.codex/` (untracked files only), plus the refresh receipts of removed bundles. It never touches `.codex/config.toml`, refresh backups, or Codex globals. Run `bash "${CODEX_HOME:-$HOME/.codex}/skills/offboard/scripts/reset.sh"` for preview; append `--apply` only after approval. The script reads the bundled manifest, independent of a Claude installation.
