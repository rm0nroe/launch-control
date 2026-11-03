# AGENTS.md

This file provides guidance to coding agents (Codex and others) working in this repository.

Hand-written notes sit above the `## Generated Quick Reference` heading; `/onboard` owns that
heading and everything below it, so keep edits to the generated block in the onboard templates.

## Running focused checks

The full `./tools/validate-pack.sh` takes roughly 13-15 minutes and is the only authoritative
run. While iterating, run the piece that covers the change:

```bash
python3 tools/test-launch-runtime.py        # any tools/test-*.py or tools/validate-*.py runs alone, no model calls
python3 tools/validate-codex-parity.py      # native Codex generation and parity
./tools/test-install.sh                     # installer fixtures
bash -c 'for p in lib 20-policy; do . tools/validate/$p.sh; done'   # one validator part
```

Validator parts in `tools/validate/` are sourced in order into one shell and reuse earlier
parts' fixtures, so only `20-policy.sh` runs alone; a later part needs its predecessors
(`lib 20-policy 30-guard-lifecycle 40-report-contract` for the report contract). A forward
reference to state a later part defines is a silent skip, not an error. Assertions abort the
run and name their own file and line.

**Digest gate.** Every shipped skill and agent is digest-owned. After editing anything under
`skills/` or `agents/`, append the item's new digest to `install/launch-control-owned-digests.txt`
(native Codex items: `install/codex-owned-digests.txt` or `install/codex-agent-digests.txt`),
or the validator fails before any behavioral case runs:

```bash
bash -c '. tools/launch-control-digests.sh; launch_control_item_digest skills/onboard'
# row format: skills onboard <sha256>
```

**Mutation-prove new assertions.** `./tools/mutation-run.sh --mutate '<shell that edits the tree>' -- <test command>`
seeds a defect, confirms it landed, handles the digest row, and restores the tree on exit. A
new check that stays green against the unfixed code covers nothing.

**Name pins.** `tools/validate/10-pack-inventory.sh` scans `README.md`, `CONTRIBUTING.md`,
`CLAUDE.md`, and `artifacts/` for retired agent names (see its `check_absent` calls); renaming
something means sweeping those docs too.

## Architecture

- **Source vs installed.** `install.sh` copies `skills/` and `agents/` into
  `${CLAUDE_CONFIG_DIR:-~/.claude}`; `./install.sh --codex` hands off to
  `tools/install-codex.py` and installs into `${CODEX_HOME:-~/.codex}`. Installed copies are
  digest-checked: drift makes `./install.sh --dry-run` exit 2, which fails the validation
  contract. Never edit the installed copy; edit here and reinstall.
- **`skills/onboard/` is the core.** `SKILL.md` is the onboarding contract and wires its own
  hooks in frontmatter (active only while the skill runs, never registered globally).
  `references/` holds the templates the generated workspace is built from, including
  `codex-model-tiers.json`. `scripts/` holds the hooks (`unattended-policy.sh` permission
  policy, `completion-guard.sh` lifecycle and write-time gates, `discovery-checkpoint.sh`),
  the renderer, `codex-parity.py`, and the `launch-*.py` autonomous delivery runtime used by
  `launch-ticket` and `launch-backlog`.
- **Completion contract.** An `/onboard` run succeeds only when
  `scripts/render-report.sh` exits 0 and the final message equals its stdout byte for byte.
  Hooks pass state to the renderer through marker files under the target's Git metadata dir.
  The renderer re-checks everything the hooks check: hooks are advisory, the renderer is the
  unbypassable gate, so a rule that exists only in a hook is not enforced.
- **Codex skills are wrappers.** `codex/skills/<name>/SKILL.md` only points at
  `snippets-shared-by-skills/codex-runtime.md` and `references/workflow.md`; the installer fills
  `workflow.md` from the Claude skill body. Edit the body in `skills/<name>/`, not the wrapper.
  `codex/core-skills.json` lists what the Codex install ships.
- **Ledgers.** `BACKLOG.md` is the maintainers' local work ledger (`LC-###` ids). It is
  gitignored: never track it, never publish it. Outside reports go through GitHub issues.
  `artifacts/*.md` are dated snapshots and can lag the code.

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
