---
name: launch-backlog
description: "Run a Launch Control mission from one operator project.json: stage it, go (start the staged mission with its digest, or resume a held one), hold it at the next safe point, or show its status. Usage: $launch-backlog stage|go <digest>|hold|status <project.json>"
---

Read `../snippets-shared-by-skills/codex-runtime.md`, then `references/workflow.md` in full. Follow the workflow with those native runtime mechanics.

Use `S="${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts"` wherever the workflow names the Claude scripts path.
