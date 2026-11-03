---
name: docs-create
description: "Bootstrap project documentation for any codebase. Creates architecture, infrastructure, changelog, backlog, and CLAUDE.md. Usage: /docs-create [focus area]"
argument-hint: "[all | architecture | infrastructure | changelog | backlog | claude-md]"
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/docs-create/scripts/invocation-proof.sh\""
---

Generate comprehensive project documentation by reading the entire codebase first, then producing documents tailored to what actually exists. This skill works on any codebase regardless of language, framework, or deployment target.

If an argument is provided, only generate that specific document: $ARGUMENTS
If no argument is provided (or "all"), generate all documents listed below.

## Step 1: Codebase Discovery

Before writing anything, thoroughly understand the project:

1. **Read `CLAUDE.md`** (if it exists) for existing project context
2. **Read `pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `Makefile`** — whatever build/dependency files exist
3. **Read `.github/workflows/`** or CI config files
4. **List all source directories** and read key entry points, config files, and core modules
5. **Read `git log --oneline -30`** for recent development context
6. **Read any existing docs** (`README.md`, `docs/`, `artifacts/`) to avoid duplicating or contradicting them
7. **Identify the deployment target** (cloud, edge device, local, serverless, etc.)
8. **Identify the tech stack** (languages, frameworks, databases, message queues, etc.)

Before documenting generated or integration surfaces, classify them from source rather
than grouping them by product category:

- A URL-based MCP entry (`type` plus `url`) is a remote integration. Describe its
  observed user-authentication flow only when the source documents one.
- A command-based MCP entry (`command` plus `args`) is a local stdio process. Do not
  describe local stdio servers as OAuth integrations or tell users to authenticate them
  through `/mcp`.
- Separate files created by the current generator from files created later by workflow
  skills. In Launch Control, `/onboard` creates only its declared manifest paths; CRISPY
  skills later create `workbench/<TICKET>/<stage>/` artifacts. Never put `workbench/`
  in the onboarding-generated target layout.
- Distinguish skill-frontmatter lifecycle hooks from settings-based hooks. Launch Control's
  completion guard is declared in `skills/onboard/SKILL.md` frontmatter and is active
  only while that skill runs. It is not registered in user config, installed config,
  or generated project settings; `--enable-hooks` controls a separate optional project
  hook overlay.

## Step 2: Generate Documents

Two safeguards govern every document below:

1. **Create only what applies or was requested.** A document earns creation when the repository has the surface it describes (deployed services for infrastructure, phases for a changelog) or the user named it in `$ARGUMENTS`. Otherwise report it as skipped with the reason.
2. **Update, never replace.** When a target document already exists, read it and edit it in place: keep its structure, tone, and still-accurate content; fix what is stale; add what is missing. Overwriting an existing document is never the path.

Create each document using the templates below. Adapt sections to fit the project — skip sections that don't apply, add sections for things unique to this codebase.

### 2a. `artifacts/architecture.md`

System architecture reference. Sections to include (adapt as needed):

1. **Overview** — One-paragraph system description: what it does, who it's for, where it runs
2. **Technology Decisions** — Each major technology choice with brief rationale
3. **System Architecture** — Mermaid diagram showing components, data flow, and boundaries. Include ports/protocols.
4. **Component Deep Dives** — For each major component/service/module: purpose, key files, interfaces, dependencies
5. **Data Model** — Core data structures, schemas, database tables, message formats
6. **Network Protocol / API Surface** — REST endpoints, pub/sub channels, gRPC services, WebSocket messages — whatever the project uses
7. **Infrastructure** — Where it runs, hardware requirements, cloud services
8. **Performance Budget** — Latency targets, throughput, memory limits (if applicable)
9. **External Integrations** — Third-party services, APIs, SDKs

If a listed section does not apply, retain the heading and state the evidenced reason
instead of silently omitting it. Every newly created architecture document must contain
`## Overview`, `## Technology Decisions`, `## System Architecture`, a Mermaid diagram,
`## Component Deep Dives`, and `## Data Model`.

When an integration catalog mixes remote and local transports, name each category and
its actual startup/auth behavior. Do not make a blanket authentication claim.

For Launch Control, this document must explicitly state both facts: GitHub and Atlassian
are authenticated remote MCP integrations, while shadcn and chrome-devtools are local
stdio servers; and CRISPY skills create `workbench/<TICKET>/<stage>/` later while
`/onboard` does not create `workbench/`.

### 2b. `artifacts/infrastructure.md`

Deployment and operations guide. Sections to include (adapt as needed):

1. **Current State** — What's deployed and where
2. **Requirements** — Hardware, OS, runtime prerequisites
3. **Service Inventory** — Table of services/processes with ports, health checks, restart policies
4. **Deployment** — Step-by-step deploy process (scripts, CI/CD, manual steps)
5. **Build** — How to build from source, including any native/compiled components
6. **Configuration** — Config file locations, environment variables, secrets management
7. **Containers / VMs / Serverless** — Docker, Kubernetes, Lambda — whatever applies
8. **Monitoring & Health** — Health checks, metrics, logging, alerting
9. **Security** — Auth, secrets, network policies, scanning
10. **Runbook** — Common operations: deploy, rollback, restart, check logs, debug

If the project has no deployed services, retain the relevant operational headings and
state that fact explicitly. Every newly created infrastructure document must contain
`## Configuration`, `## Security`, and `## Runbook` with repository-backed commands or
an explicit not-applicable explanation.

For Launch Control, the Configuration or Security section must explicitly state both facts:
GitHub and Atlassian are authenticated remote MCP integrations, while shadcn and
chrome-devtools are local stdio servers; and CRISPY skills create
`workbench/<TICKET>/<stage>/` later while `/onboard` does not create `workbench/`.

### 2c. `CHANGELOG.md`

Development history and progress tracker.

1. Read `git log` to understand the full development arc
2. Create a **Status Overview** table if the project has phases/milestones
3. Add an **`[Unreleased]`** section for changes since the last tagged release or dated entry
4. Group changes into logical categories (features, fixes, infrastructure, docs)
5. For each phase/milestone that has history, create a section with tasks and iteration notes
6. Use `[x]`/`[ ]` checkboxes for task tracking where appropriate

### 2d. `BACKLOG.md`

Feature backlog and issue tracker.

1. Use a legend: `[ ]` Pending, `[~]` In progress, `[x]` Done
2. Assign IDs to items (e.g., `PROJ-001`) for cross-referencing
3. Group items by category (e.g., Critical, API, Infrastructure, Performance, Polish)
4. For each item: ID, one-line description, completion status
5. Add a **Remaining Blockers** section summarizing what's blocking progress
6. Add a **Upcoming Work** section for known future items
7. Derive items from: TODO comments in code, open issues, incomplete features, known tech debt

### 2e. `CLAUDE.md`

Project guidance for Claude Code. Only create if one doesn't already exist. If one exists, update it.

1. **Project Overview** — What the project is, target platform, key constraints
2. **Build & Test Commands** — Every command needed to build, test, lint, type-check, run
3. **Architecture** — ASCII or text diagram of components, with brief descriptions
4. **Key Patterns** — Design patterns, conventions, naming rules used in the codebase
5. **Critical Gotchas** — Things that are surprising, non-obvious, or have caused bugs before
6. **Deployment** — How to deploy, key scripts, boot order
7. **Reference Documents** — Pointers to other docs in the repo

## Step 3: Cross-Reference

After generating all documents:

1. Ensure `CLAUDE.md` references `artifacts/architecture.md` and `artifacts/infrastructure.md`
2. Ensure `CHANGELOG.md` references `BACKLOG.md` as source of truth for outstanding items
3. Ensure no documents contradict each other
4. Verify all file paths, service names, and ports mentioned are accurate to the codebase
5. Add a short "Generated snapshot" note with the generation date and the repository
   evidence used. Never label a newly created document `Existing snapshot`. Existing
   bootstrap documents are not permanently current; use `docs-update` after material
   repository changes.
6. Verify every documented generated path against the generator manifest. Describe
   downstream workflow paths separately and name the skill or phase that creates them.
7. Verify every MCP statement against each entry's `type`/`url` or `command`/`args`
   shape; reject blanket OAuth/authentication language for mixed catalogs.
8. Verify every hook statement against its declaration site. Never describe a
   skill-frontmatter lifecycle hook as registered in `~/.claude` settings or generated
   project config.
9. When generating Launch Control's architecture and infrastructure snapshots, verify that
   each document independently names both MCP transport/auth categories and independently
   assigns `workbench/` creation to later CRISPY skills rather than `/onboard`.

## Guidelines

- **Read before writing.** Never guess at architecture — derive everything from source code.
- **Be specific.** Use actual file paths, class names, port numbers, config keys from the code.
- **Skip what doesn't apply.** A simple CLI tool doesn't need an infrastructure doc. A static site doesn't need a service inventory.
- **Use Mermaid diagrams** for architecture visualization.
- **Use tables** for service inventories, env vars, and config references.
- **Preserve existing content.** If a document already exists, update it rather than replacing it. `/onboard` may skip an existing bootstrap snapshot; `docs-update` is the explicit refresh workflow.
- **Use parallel agents** when generating multiple documents to maximize speed.
- **Run `mkdir -p artifacts/`** before writing artifact files.
