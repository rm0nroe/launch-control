---
name: docs-update
description: Update existing project documentation to match the current codebase. Use when docs such as `CLAUDE.md`, `README.md`, `CHANGELOG.md`, `BACKLOG.md`, or files in `artifacts/` may be stale and must be reconciled against source and recent changes.
---

# Update Docs

Use this skill when the repository already has documentation and the user wants it brought back in sync with reality.

A named document or area is the whole scope. Read only the relevant source, edit only that scope, and report other stale documents without changing them. Keep useful content; never rewrite an existing document from scratch.

If the user names a specific area, restrict the work to that document or domain. Examples:
- `CLAUDE.md`
- `architecture`
- `infrastructure`
- `changelog`
- `backlog`
- `readme`

Do not create brand-new docs unless the user explicitly asks for that. Missing docs should usually be reported as skipped.

## Workflow

1. Discover which docs exist.
   Check for:
   - `CLAUDE.md` and nested `*/CLAUDE.md`
   - `artifacts/architecture.md`
   - `artifacts/infrastructure.md`
   - `artifacts/execution-plan.md`
   - `artifacts/DECISIONS.md`
   - `artifacts/EVOLUTION.md`
   - `CHANGELOG.md`
   - `BACKLOG.md`
   - `README.md`

2. Read current project state before editing docs.
   - Read recent git history such as `git log --oneline -20`.
   - Inspect recent file churn, for example via `git diff --stat` on an appropriate range.
   - Read the relevant changed source files, not just the docs.
   - Read manifests and config files such as `package.json`, `Cargo.toml`, `pyproject.toml`, and equivalents.
   - If `CLAUDE.md` exists, read it early for repository conventions and command references.

3. Update each existing document against the codebase.
   - Read the current document first.
   - Preserve the existing structure and tone unless the user asks for a rewrite.
   - Fix stale paths, commands, env vars, architecture notes, and references to removed features.
   - Add missing new features, modules, commands, and operational notes that now exist.
   - Remove or correct information that no longer matches source.

## Document-Specific Rules

### `CLAUDE.md`

Update:
- Build, test, lint, type-check, and run commands
- Architecture and component summaries
- File paths and important conventions
- Env vars, deployment notes, and gotchas

### `artifacts/architecture.md`

Update:
- Component descriptions
- Data flow and system boundaries
- Mermaid diagrams
- APIs, protocols, and external integrations
- Technology decisions that have materially changed

### `artifacts/infrastructure.md`

Update:
- Deployment flow
- Services and runtime requirements
- Config, env vars, and secret handling
- Monitoring, health checks, and runbook steps

### `CHANGELOG.md`

Update:
- The `[Unreleased]` section
- Recent entries grouped under useful headings such as Features, Fixes, Infrastructure, and Docs
- Release notes only when there is clear source evidence

### `BACKLOG.md`

Update:
- Item statuses based on what is now complete
- Newly discovered work items or debt
- Blockers and near-term work if the project tracks them

### `README.md`

Update only when user-facing quick start, setup, structure, or doc links are stale.

### `artifacts/DECISIONS.md`

- Append new architectural decisions when the codebase clearly reflects them.
- Do not rewrite historical decisions unless they are factually wrong.

### `artifacts/EVOLUTION.md`

- Add new iteration notes when the file exists and recent work materially advanced the system.

## Output Expectations

After updating docs, report a compact summary with:
- docs updated
- docs already current
- docs not found and skipped

## Guidelines

- Read the code that changed before touching the doc that describes it.
- Do not guess. Use the repo as source of truth.
- Preserve existing formatting conventions unless they block correctness.
- Do not add emojis or gratuitous reformatting.
- Avoid deleting sections wholesale; update them to match current reality.

Read `../snippets-shared-by-skills/codex-runtime.md` for native tool and dependency resolution.
