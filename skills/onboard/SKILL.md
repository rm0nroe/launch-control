---
name: onboard
description: >
  Use when entering a new project/codebase for the first time, when a repo has no .claude/ directory,
  or when asked to "set up Claude Code", "onboard", "init workspace", "configure this project".
  Pre-scans existing docs and engineering practices to generate a tailored Claude Code workspace.
argument-hint: "[--dry-run] [--codex] [--launch-control] [--enable-mcp] [--enable-hooks] [--include-global-claude] [--no-worktrees]"
hooks:
  UserPromptSubmit:
    - hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/completion-guard.sh\""
  TaskCreated:
    - hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/completion-guard.sh\""
  TaskCompleted:
    - hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/completion-guard.sh\""
  PreToolUse:
    - matcher: "Bash|Edit|Write|Read|Glob|Grep"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/unattended-policy.sh\""
    - matcher: "Bash|Edit|Write"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/completion-guard.sh\""
  PermissionRequest:
    - matcher: "Bash|Edit|Write|Read|Glob|Grep"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/unattended-policy.sh\""
  Stop:
    - hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/completion-guard.sh\""
---

# Onboard

Generate the complete Launch Control workspace tailored to the project's actual engineering
practices. Read the repo first, generate second, and never clobber existing content. A
normal run always installs project guidance, narrow settings, core project-local skills,
agents and commands, Launch, CRISPY documentation/review orchestration, worktree-aware
delivery, self-validation, and deterministic reporting.

## Boundary: onboarding never runs the project's code

Onboarding is read-only analysis of the target project plus setting up agents to work around it.
It never executes, tests, builds, formats or otherwise runs the project's own commands, scripts or
code, and it never asks the project to change how it runs its tests. Gates the project documents
(CI, package scripts, README, CLAUDE.md) are recorded as **documented gates** for the agents it sets
up. Anything that looks off (a gate the record omits, a documented command that would not run from
the repository root, a stale generated block) is disclosed as a note for the person onboarding; it
never fails the run, blocks it, or becomes a `Next:` to-do for the project. Delivery agents running a
project's checks while building a ticket is a separate, later activity that this boundary does not
govern.

## Arguments

$ARGUMENTS

- no flags: Generate or update the complete Launch Control workspace.
- `--codex`: Generate native Codex skills and agents alongside Claude artifacts. Never create or change project `.codex/config.toml`. Also selected automatically when `.codex/` exists. Python 3.11+ required; eligible static skills upgrade; other existing Codex files are preserved.
- `--launch-control`: Maintenance mode. Regenerate only the project-specific `/launch` delivery skill, then validate and report.
- `--enable-mcp`: Complete install plus relevant project `.mcp.json` setup after reporting detected servers.
- `--enable-hooks`: Complete install plus Launch Control branch-protection and skill-evaluation hooks.
- `--include-global-claude`: Explicitly include only `~/.claude/CLAUDE.md` in the generated delivery skill's conventions. Never include `CLAUDE.local.md` or arbitrary home-directory files. Review the imported content before committing it.
- `--dry-run`: Preview the complete run, including planned paths and dependency status, without writing files.
- `--no-worktrees`: Launch template renders the legacy in-place `git switch -c` Phase 4a instead of the worktree-first flow. Use for repos where worktrees are incompatible (single-checkout build infra, sparse-checkout filters, Vercel-deployed `.next/` cache sharing requirements). Default: worktrees ON.

## Mandatory run contract

- Parse arguments before discovery or writes. A plain `/onboard` authorizes the complete in-place run; `--dry-run` is active only when supplied. Reject removed or unknown flags before any read beyond argument parsing.
- Read the required reference for each phase completely before starting that phase. References are one level deep and are routed only from this file.
- Keep the current branch. Preserve dirty, untracked, user-authored, symlinked, and pre-existing manifest paths exactly as the routed phase contract requires. Never switch branches, stage, commit, push, install dependencies, mutate external systems, or bypass the sandbox from onboarding.
- The frontmatter lifecycle hooks are the executable boundary. Before the first manifest `Edit` or `Write`, emit and save the complete discovery report, invoke the installed discovery checkpoint, and capture the required preservation state.
- For every writing mode, including idempotent no-op and `--launch-control`, success is valid only after the installed `render-report.sh` verifies the generated workspace and returns fresh proof; it executes none of the project's commands. Return its stdout byte for byte as the entire final message. If rendering or an owned artifact fails, use only the byte-exact blocked protocol the completion reference defines.

## Codex parity

When `.codex/` exists or `--codex` is supplied, read
the Codex parity reference before discovery. The finalizer owns native generation;
do not write Codex destinations directly or extend Claude permissions to them.

## Project skill upgrades

Normal onboarding refreshes unchanged released `checkpoint-save`, `checkpoint-load`, and `checkpoint-list`
through the trusted finalizer after preservation checks. It uses installed templates,
retains backups and receipts, and reports customized or dirty tracked copies without
replacing them. Codex also checks existing `.agents/skills/` copies. Other project-tailored
skills remain preserved. Update your Launch Control installation before rerunning onboarding.

## Standalone portable refresh

For an explicitly requested checkpoint-save/-load/-list refresh, use the standalone
maintenance commands in `references/codex-parity.md`. This is separate from `/onboard`
and does not add an onboarding flag or bypass its lifecycle. Preview first, forward
the selected names/runtime and approved digest, and stop on conflicts.

## Phase router

### Before Phase 0

Read @references/codex-parity.md completely before starting Phase 0.

Read @references/run-authority-and-lifecycle.md completely before starting Phase 0.
Read @references/context-discovery.md completely before starting Phase 0.

### Before Phase 1

Read @references/configuration-generation.md completely before starting Phase 1.
Read @references/hooks-and-config.md completely before starting Phase 1.
Read @references/mcp-detection.md completely before starting Phase 1.

### Before Phases 2a through 2c

Read @references/skills-agents-and-commands.md completely before starting Phase 2a.
Read @references/artifact-templates.md completely before starting Phase 2a.
Read @references/checkpoint-templates.md completely before starting Phase 2a.

### Before Phase 2d

Read @references/launch-generation.md completely before starting Phase 2d.
Read @references/launch-discovery.md completely before starting Phase 2d.
Read @references/launch-template.md completely before starting Phase 2d.
Read @references/launch-ticket-intake-template.md completely before starting Phase 2d.
Read @references/launch-implementation-template.md completely before starting Phase 2d.
Read @references/launch-delivery-template.md completely before starting Phase 2d.
Read @references/launch-verification-template.md completely before starting Phase 2d.
Read @references/launch-acceptance-criteria.md completely before starting Phase 2d.

### Before Phases 3 and 4

Read @references/claude-md-and-documentation.md completely before starting Phase 3.

### Before Phase 5

Read @references/completion-report-and-ledgers.md completely before starting Phase 5.

## Idempotency Contract

Running `/onboard` twice MUST be safe:

| Artifact      | First run | Second run                                         |
| ------------- | --------- | -------------------------------------------------- |
| settings.json | Created   | Merged if changed; otherwise preserved             |
| CLAUDE.md     | Created   | Merged if generated section changes; otherwise preserved |
| Skills        | Created   | Static released skills refreshed by finalizer; customized and tailored skills preserved                          |
| Agents        | Created   | Preserved (already exist)                          |
| Commands      | Created   | Preserved (already exist)                          |
| .mcp.json     | Created   | Merged if changed; otherwise preserved             |
| Hooks         | Created only with `--enable-hooks` | Preserved when present; canonical path skipped when absent |
| artifacts/\*  | Created   | Preserved snapshot; refresh explicitly with `docs-update` |
| `/launch`     | Created   | Merged if regenerated content differs; otherwise preserved |

## Execution Strategy

Use parallel agents where phases are independent. Every normal run installs and exposes
the complete CRISPY ladder and review orchestration:

- Phase 0 (discovery) must complete first — everything depends on it
- Phase 1 (config) and Phase 2 (artifacts) can run in parallel
- Assemble prospective Phase 3 guidance after Phases 1, 2a, 2b, and 2c
- Phase 2d (delivery) depends on Phase 0 plus that prospective guidance, and persists it
  to `.launch-control-onboard/prospective-claude.md` before rendering Launch
- Phase 3 reads that persisted file and writes the already-assembled guidance after Phase 2d
- Phase 4 (docs) can run in parallel with Phase 3
- Phase 5 (summary) runs last

## Anti-Patterns

| Temptation                                   | Reality                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| "Overwrite CLAUDE.md — mine is better"       | User content is irreplaceable. Merge or append.                |
| "Hardcode yarn/npm commands"                 | Read the actual build config. Could be cargo, make, or poetry. |
| "Skip README — detect everything from files" | READMEs contain intent and conventions code doesn't express.   |
| "Generate all skills even if they exist"     | Duplicating causes confusion and wastes context.               |
| "Skip discovery — it's obvious"              | Discovery takes seconds. Skipping it produces generic output.  |
| "Include all MCP servers"                    | Only include servers relevant to detected integrations.        |
| "Switch branches so onboarding can write"    | Stop and ask; never move a dirty worktree between branches.     |
| "Enter a worktree so onboarding can write"   | Stop and ask; a mid-run worktree strands the completion report. |
| "A warning proves a hook exists"             | Parse final settings and report only configured hooks.          |
| "Warn that a dependency is missing"          | Run the dependency check first and report the observed result.  |

## Usage example: regenerating delivery skills for an existing project

```bash
# In a Claude Code session whose cwd is the project root:
/onboard --launch-control
```

Output:

```
=== Workspace Discovery Report ===
Project: my-project (TypeScript)
Stack: Next.js + pnpm + vitest
Platforms detected: web, backend
MCPs detected: atlassian, github, growthbook
Existing delivery skill: present — will overwrite after confirmation

=== Phase 2d: Delivery Skill Generation ===
Wrote: .claude/skills/launch/SKILL.md (247 lines)
Sources used:
  package.json -> TEST_CMD, LINT_CMD, BUILD_CMD
  .mcp.json -> HAS_JIRA_MCP, HAS_GITHUB_MCP, HAS_GROWTHBOOK_MCP
  .claude/agents/ -> 0 agents (skipping specialist table)
  CLAUDE.md -> Project Conventions
Model-inserted gotchas: 1 (vitest watch-mode hangs on save in this repo)
```
