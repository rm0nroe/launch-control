---
name: docs-update
description: Update all project documentation to reflect the current state of the codebase. Reads source files, compares against existing docs, and updates everything to match reality. Works on any project with artifacts/, CLAUDE.md, CHANGELOG.md, or BACKLOG.md.
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep
argument-hint: "[specific doc or area to focus on, or leave blank for all]"
---

# Update Docs: $ARGUMENTS

Reconcile project documentation against the codebase. Read every source file that has changed before updating docs.

## Step 0: Scope

If `$ARGUMENTS` names a document or area, that is the whole scope. Examples:
- `/docs-update CLAUDE.md` — only update CLAUDE.md
- `/docs-update architecture` — only update artifacts/architecture.md
- `/docs-update changelog` — only update CHANGELOG.md
- `/docs-update backlog` — only update BACKLOG.md

A targeted update stays targeted: read only what that document covers, touch only that document, and mention other stale docs in the summary instead of editing them. With no argument, update every document that exists.

## Step 1: Discover Documentation

Scan the current working directory for documentation files:

1. **`CLAUDE.md`** (and any nested `*/CLAUDE.md` files) — Project guidance, commands, architecture, patterns, gotchas
2. **`artifacts/architecture.md`** — System architecture, component deep dives, data model, diagrams
3. **`artifacts/infrastructure.md`** — Deployment, configuration, runbook, environment variables
4. **`artifacts/execution-plan.md`** — Execution plan, phases, task ownership (if exists)
5. **`CHANGELOG.md`** — Development history, update the `[Unreleased]` section
6. **`BACKLOG.md`** — Feature backlog, move completed items to done, add new discoveries
7. **`README.md`** — Only update if quick start commands, structure table, or doc links are stale
8. **`artifacts/DECISIONS.md`** — Architecture decision records (if exists)
9. **`artifacts/EVOLUTION.md`** — Evolution log (if exists)

If a document doesn't exist, skip it — don't create new docs unless explicitly asked.

## Step 2: Read Current State

1. Read `git log --oneline -20` to understand recent changes
2. Read `git diff --stat HEAD~10` (or appropriate range) to see what files changed recently
3. Read all source files that have changed since docs were last updated
4. Read any build/config files (`package.json`, `Cargo.toml`, `pyproject.toml`, etc.) for dependency or script changes
5. If the project has a CLAUDE.md, read it first to understand conventions

## Step 3: Update Documents

For each document that exists:

1. **Read the current document** to understand its structure and style
2. **Compare against the codebase** — identify stale information, missing new features, incorrect paths/commands
3. **Update to match reality** — fix what's wrong, add what's new, remove what's gone
4. **Preserve structure and style** — don't reformat, don't change headings, don't add emojis
5. **Don't remove sections** — update them. Add new sections only if new features/components exist
6. **Keep useful content** — an edit corrects or extends what is there; it never rewrites a document from scratch

### Document-Specific Rules

**CLAUDE.md**: Update commands, file paths, environment variables, architecture descriptions, key patterns, and gotchas. Add new patterns discovered. Remove references to deleted files/features.

**artifacts/architecture.md**: Update component descriptions, data flow diagrams, API surfaces, and technology decisions. Add new components. Update Mermaid diagrams if architecture changed.

**artifacts/infrastructure.md**: Update deployment steps, environment variables, configuration, and runbook commands. Add new services or dependencies.

**CHANGELOG.md**: Add or update the `[Unreleased]` section with changes not yet covered. Group by: Features, Fixes, Infrastructure, Docs.

**BACKLOG.md**: Move completed items from pending to done. Add new items discovered during review. Update blockers section.

**artifacts/DECISIONS.md**: Add any architectural decisions made since last update. Don't modify past decisions.

**artifacts/EVOLUTION.md**: Add any evolution iterations completed since last update.

## Step 4: Summary

After updating, print a summary:

```
DOCS UPDATED
━━━━━━━━━━━━
[filename] — [what changed in 1 line]
[filename] — [what changed in 1 line]
...
No changes needed: [list of docs that were already current]
Not found (skipped): [list of docs that don't exist]
```
