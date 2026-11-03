---
name: docs-create
description: "Bootstrap project documentation for any codebase. Creates architecture, infrastructure, changelog, backlog, and CLAUDE.md. Usage: /docs-create [focus area]"
---

Read `../snippets-shared-by-skills/codex-runtime.md`, then `references/workflow.md` in full. Follow the workflow with those native runtime mechanics.

There is no Codex lifecycle hook here. Do not run the Claude invocation-proof hook or claim it fired. Document Claude hooks only at their actual Claude declaration sites; Codex configuration lives under `~/.codex` (or `CODEX_HOME`). Preserve the generated-path and MCP transport checks in the workflow.
