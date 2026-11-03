# Launch Control — Infrastructure & Operations

> **Generated snapshot** — 2026-08-07. Evidence: `install.sh`, `README.md`,
> `CONTRIBUTING.md`, `tools/validate-pack.sh`, `tools/test-install.sh`,
> `tools/preflight-onboard.sh`, `skills/onboard/scripts/*`, `install/mcp.reference.json`,
> `.gitignore`. This is a point-in-time snapshot; re-run `docs-update` after material
> repository changes.

> **Scoped requirements update: 2026-10-31.** Installation, runtime requirements,
> and build descriptions below now include Python and native Codex. Other sections
> remain the 2026-08-07 snapshot, not a fresh infrastructure audit.

## Current State

Launch Control is a **local developer tool**, not a deployed service. There is nothing hosted:
no servers, containers, schedulers, or cloud resources. "Deployment" means installing the
pack into a user's Claude Code or native Codex configuration directory and, from a
session, generating a project-local workspace. Autonomous delivery runs an on-demand
local controller and workers; installation does not provision a background service.

## Requirements

| Prerequisite | Purpose |
|---|---|
| Claude Code or native Codex | Host for skills and agents; Claude uses lifecycle hooks. |
| `bash` | Installer, hook, policy, and shell validation scripts. |
| Python 3 | HTML report rendering; native Codex installation and autonomous delivery require 3.11+. |
| `git` | Repository detection, baseline capture, metadata state. |
| `jq` | Required by the hook scripts (policy + completion guard). |
| `rg` (ripgrep) | Discovery; the validator carries its own fallback where needed. |
| Superpowers | Claude installer verifies its plugin; native Codex reports missing external dependencies. |

Onboarding supports macOS and Linux. Autonomous delivery currently requires macOS,
Xcode command-line tools, authenticated `gh`, and Node.js/npm. Staging installs and
verifies Codex CLI 0.162.0 under `~/.local/share/launch-control/`, requiring network
access. See the README's Mission section for installed-script commands that honor
`CODEX_HOME`. These delivery requirements do not make Linux onboarding unsupported.

Onboarding does not install the target project's dependencies or build its code.
Autonomous staging can provision the dependencies explicitly declared in its reviewed
configuration. Launch Control itself has no compiled component or build step.

## Service Inventory

Not applicable — Launch Control runs no services, exposes no ports, and has no health checks or
restart policies. Installers, validation scripts, onboarding hooks, and Python delivery
controllers/workers run locally on demand; mission runs may be long-lived.

## Deployment

```bash
./install.sh              # copy the core pack into ~/.claude (digest-guarded, idempotent)
./install.sh --codex      # native core pack into ${CODEX_HOME:-$HOME/.codex}
./install.sh --dry-run    # preview install; changes nothing
./install.sh --uninstall  # remove only digest-matched Launch Control copies
```

Optional CLIs: `--optional-tools`. Restart
Claude Code after installation. When developing Launch Control itself, run
`./tools/preflight-onboard.sh` before a manual `/onboard` acceptance test — it fails fast on
any source/install mismatch.

## Build

No build. The pack is Bash + Python + Markdown, consumed directly. To package a release from the
tracked, ignore-respecting source:

```bash
git archive --format=zip --prefix=launch-control/ --output=launch-control.zip HEAD
```

## Configuration

| Config surface | Location | Notes |
|---|---|---|
| Install target | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` | Where the pack is installed. |
| Native Codex install target | `${CODEX_HOME:-$HOME/.codex}` | Independent native skills, agents, and configuration. |
| Generated project settings | `.claude/settings.json` | Narrow allow-list + secret-file `permissions.deny` rules; created per project by `/onboard`. Never contains a `sandbox` key. |
| Reference MCP catalog | `install/mcp.reference.json` | Secret-free; no tokens are ever written. |
| Local ignores | `.gitignore` | Ignores `.claude/`, `.env*` (except `.env.example`), `CLAUDE.local.md`, release artifacts. |

**MCP transports (classify by config shape, not product):** `github` and `atlassian` are
**authenticated remote** MCP integrations (`type` + `url`); complete their auth via Claude
Code `/mcp`. `shadcn` and `chrome-devtools` are **local stdio** servers (`command` + `args`
launched with `npx`) and use no remote OAuth. Never hardcode tokens in `.mcp.json`.

**Generated layout boundary:** `/onboard` creates only its declared manifest paths; it
**does not create `workbench/`**. The CRISPY skills create `workbench/<TICKET>/<stage>/`
artifacts later during delivery.

## Containers / VMs / Serverless

Not applicable. Launch Control does not ship or require Docker, Kubernetes, VMs, or serverless
functions.

## Monitoring & Health

Not applicable — nothing runs to monitor. The equivalent "health check" is the declared
validation contract (see Runbook), which confirms the pack is internally consistent.

## Security

- **Secret-file boundary.** Generated `.claude/settings.json` protects secrets entirely
  through `permissions.deny`: the project-root denies `Read(/.env*)` and `Read(/**/.env*)`
  cover arbitrary root and nested names such as `.env.qa`, `.env.preview`, and
  `.env.backup`. A single leading `/` anchors at the settings source, so inside a project
  these mean `<project root>/.env*`, never the filesystem root. They bind
  native Read/Glob/Grep and Bash readers (`cat`, `head`, `tail`, `grep`, `rg`) alike,
  whenever Claude Code can resolve the path argument.
- **Onboarding never writes a `sandbox` key and removes an existing one** from the project
  `.claude/settings.json`; earlier versions generated it. A per-project
  `sandbox.enabled: true` silently changes the execution model for every later session in
  that repository, and Codex Desktop's Claude import copies it into `.codex/config.toml` as
  `sandbox_mode`. The boundary is expressed only as denies. A user who wants the sandbox
  sets it in `.claude/settings.local.json` or user settings, which onboarding never changes.
- **The safe examples are readable in Phase 0 or not at all.** The denies also match
  `.env.example`, `.env.sample`, `.env.template`, and `.env.local.example`, so from the
  moment Phase 1a writes the settings, no tool in the session can read them. Discovery must
  read them before that write or lose them as a source.
- **Residual gap, stated plainly.** The boundary constrains the Claude Code session, not
  the project. Child processes a command spawns are outside the permission layer, and the
  application still loads `.env` at runtime exactly as before.
- **Least-privilege onboarding.** `skills/onboard/scripts/unattended-policy.sh` auto-allows
  only repo-local discovery, the fixed generated manifest, read-only Git/plugin checks, and
  the installed renderer. A project's own commands are never auto-allowed. It denies shell composition, out-of-repo access,
  protected secret paths, path traversal, dependency installation, and repository/GitHub
  mutation. It takes no position on `dangerouslyDisableSandbox` — whether Bash runs sandboxed
  is the user's setting, and the rules above are what keep an unattended run inside the
  repository. Out-of-repo denial covers Bash readers
  (`cat`/`ls`/`head`/`tail`/`wc`/`grep`/`rg`): each argument is validated
  repo-relative and any shell-metacharacter argument (glob, `~`/`$` expansion, backslash
  escape) is denied, so the literal path is the one checked. Quote-aware parsing allows a
  literal `|` inside balanced single- or double-quoted regex data while rejecting real
  pipes, redirections, and substitutions. Unknown operations keep the normal permission
  prompt and hard-deny under `bypassPermissions`, where no prompt can appear. It never
  persists a permission or edits `.claude/settings.local.json`.
- **No secrets in source.** The MCP reference is secret-free; credential-shaped placeholders
  are never written. `github`/`atlassian` are authenticated remote integrations;
  `shadcn`/`chrome-devtools` are local stdio tools.
- **Hook scoping.** The onboard completion guard is declared in `skills/onboard/SKILL.md`
  frontmatter and active only for that skill's lifecycle — it is not registered in `~/.claude`
  config, installed config, or generated project settings. `--enable-hooks` is a separate,
  opt-in project overlay. On the first write it snapshots the active manifest and dirty
  baseline with pre-run existence/type, content hash, and executable state so the renderer
  can reject dishonest `CREATED`, `MERGED`, `PRESERVED`, or `SKIPPED` classifications.
  Project writes are additionally denied until the Workspace Discovery Report is visible in
  the transcript (standalone assistant message or any tool_result — the discovery checkpoint
  re-emits it on stdout); a per-session two-deny circuit breaker stands that write gate down
  rather than livelock an incompatible model mode, while the `Stop` backstop independently
  blocks any no-proof completion.
  Verified completion removes active/mode/baseline/inventory/task/report proof, the recorded
  permission mode, deny counters and
  `.launch-control-onboard/` control state, then leaves a session-keyed `.disarmed` marker so
  unrelated same-session tools are unaffected. A later `/onboard` prompt removes that marker
  and re-arms the hooks before discovery; its first write creates fresh mode, baseline, and
  inventory state. Failed or blocked runs never disarm them.
- **User-authoritative `AGENTS.md`.** The model never writes `AGENTS.md` (the write policy
  denies it). In Codex mode the trusted finalizer mirrors the verified `CLAUDE.md` generated
  block into it, because Codex reads `AGENTS.md`; user prose is never touched. Outside Codex
  mode, a leftover onboard-generated marker block inside it is detected by the
  discovery checkpoint (`STALE-AGENTS-CANDIDATE` advisory) and surfaced by the renderer as a
  machine-emitted `Stale AGENTS.md` report section with a manual-regeneration `Next:` entry —
  the finding never depends on model prose.

## Runbook

| Operation | Command |
|---|---|
| Validate the pack (required contract) | `./tools/validate-pack.sh` |
| Preview the default install | `./install.sh --dry-run` |
| Preflight before a manual `/onboard` test | `./tools/preflight-onboard.sh` |
| Fixture-driven installer checks | `./tools/test-install.sh` |
| Install / upgrade | `./install.sh` |
| Uninstall (digest-matched only) | `./install.sh --uninstall` |
| Package a release | `git archive --format=zip --prefix=launch-control/ --output=launch-control.zip HEAD` |
| Inspect generated (gitignored) output | `git status --short --ignored .claude/` |

**Common issues.** If a hook silently blocks a session, check that `jq` is installed and that
the script exits non-zero only intentionally. If `/onboard` refuses to report success, the
renderer or Stop guard rejected the ledger, docs, `inspector` lens, or final-message
match — read the blocked protocol's exact failing path/command and correct it, then re-run.
If early writes are denied with "cannot write before the Workspace Discovery Report", run
the discovery checkpoint script (its stdout satisfies the gate); after two denies the gate
stands down on its own. Running the validator against a live `~/.claude` can fail on install
dry-run digest conflicts — use `CLAUDE_CONFIG_DIR=$(mktemp -d) ./tools/validate-pack.sh`.
Stale `$GIT_DIR/launch-control-onboard-run-*` markers from an interrupted run can confuse a
later run's guards — remove them before a fresh acceptance test.
