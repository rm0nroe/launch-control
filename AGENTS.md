## Generated Quick Reference

Launch Control is a Claude Code-first onboarding and delivery kit: a portable pack of global
skills and agents plus the project-local workspace they generate, with native Codex
installation also supported. It uses Bash, Python, and Markdown. There is no pack
build step or package manager; scripts use Bash, Git, jq, and Python 3.
Native Codex and autonomous delivery require Python 3.11+.

## Stack

- **Languages:** Bash (hooks and validation), Python (installers, rendering, delivery runtime), Markdown (skills and docs)
- **Package manager:** none
- **Test framework:** none (validation is script-based, see Commands)
- **CI:** GitHub Actions: `.github/workflows/validate.yml` runs `./tools/validate-pack.sh` on `ubuntu-latest` and `macos-latest` for every push to `main` and every pull request
- **Base branch:** `main`

## Commands

The repository's declared validation contract is exactly:

```bash
./tools/validate-pack.sh      # shell syntax, reference JSON, template balance, onboarding contracts, renderer/guard
./install.sh --dry-run        # preview the default install; no user config is changed
```

`/validate` runs this local gate set. There is no lint, type-check, unit-test, or build
command in this repository; do not infer additional gates from installed tools or file types.

Developer preflight before a manual `/onboard` acceptance test:

```bash
./tools/preflight-onboard.sh  # fails fast on any source/install mismatch
```

## What onboarding does to a target project

`/onboard` reads a target project and sets up agents around it. It never runs, tests, builds,
lints or formats the project's own code, and it has no say over how the project is tested. It
records the gates the project documents and discloses anything that looks off as a note. The
commands above are this repository's own gates, not something onboarding runs elsewhere.

## Code style & conventions

- Bash scripts use `#!/usr/bin/env bash` and `set -euo pipefail`; guard optional tools (e.g. `jq`) before use.
- Hook scripts exit non-zero only to intentionally block; they gate the user's live session.
- Keep generated `settings.json` permissions narrow: exact validation commands + read-only inspection, never interpreter wildcards.
- Keep secrets, personal paths, and generated project output out of the tracked source tree.

## Git workflow

- Branch from `main`; feature branches follow `type/short-description` or `TICKET-123-description`.
- Commit subject: `type(scope): description`, all lowercase, imperative, up to 150 characters (default). Types: `feat`, `fix`, `refactor`, `style`, `docs`, `test`, `chore`.
- PR title: `[TICKET] verb + description`, under 72 characters (default).
- Branch rules are conventions; no enforcement hook is configured.
- Mutating git/gh actions (commit, push, PR) require explicit confirmation; onboarding never performs them.

## Generated workspace

### Skills (`.codex/skills/`)
- `testing-patterns`: script-based validation patterns (no unit-test framework)
- `pr-workflow`: PR readiness against the validation contract
- `project-code-review`: self-review checklist for shell/markdown/hook changes
- `feature-development`: end-to-end change workflow
- `systematic-debugging`: reproduce, locate, fix, verify
- `checkpoint-save`, `checkpoint-load`, `checkpoint-list`: project-local session checkpoints in `.claude_states/`
- `launch`: project-specific ticket delivery orchestrator

### Agents (`.codex/agents/`)
- `inspector` (sonnet): review tailored to this pack's shell/template failure modes
- `dispatcher` (haiku): commits, branches, PRs

### Commands (`.claude/commands/`)
- `/pr` `/validate` `/status` `/commit` `/ticket` `/explore`
- `/fix` is not generated: this repository declares no formatter or lint-fix command.

## CRISPY delivery chain

The installed pipeline skills run in this order, with an adversarial `review-doc` checkpoint
between authored stages:

```
research-questions → research-codebase → design-doc → design-outline
   → plan-write → plan-execute
```

Run `review-doc` against each authored artifact, resolve blocking findings, then advance.
CRISPY skills create `workbench/<TICKET>/<stage>/` artifacts during delivery; `/onboard`
does not create `workbench/`.

## MCP integration

This repository declares no project `.mcp.json`. Launch Control's secret-free reference
catalog (`install/mcp.reference.json`) classifies servers by transport: GitHub and
Atlassian are authenticated remote integrations (complete auth via `/mcp`); shadcn and
chrome-devtools are local stdio servers launched with `npx` and use no remote OAuth.
Run `/onboard --enable-mcp` to add a relevant project `.mcp.json`.

## Reference documents

- `artifacts/architecture.md`: system architecture snapshot
- `artifacts/infrastructure.md`: configuration, security, and runbook snapshot
- `BACKLOG.md`: open defects and coverage gaps, ranked; the durable work ledger
