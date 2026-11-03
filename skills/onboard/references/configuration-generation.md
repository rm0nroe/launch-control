# Configuration Generation

Read this file completely before Phase 1. It owns settings, MCP overlay, hook planning, and `.gitignore` behavior.

## Contents

- [Phase 1: Generate Configuration](#phase-1-generate-configuration)
- [1a. Settings](#1a-claudesettingsjson)
- [1b. MCP](#1b-mcpjson)
- [1c. Hooks](#1c-hooks)
- [1d. Gitignore](#1d-gitignore)

## Phase 1: Generate Configuration

### 1a. `.claude/settings.json`

This phase runs for every normal onboarding. Settings contain generated permissions,
the secret-file deny rules, and preserved pre-existing user keys. Unless
`--enable-hooks` is present, do not add, register, or modify any hook. Existing hooks
are user content and remain untouched.

Use the hooks-and-config reference loaded from the main router for structure.

**Permissions strategy:** Build the smallest `allow` list that can run the exact
detected project checks and perform read-only inspection. If file exists, merge only
missing narrow entries; never broaden a command to `tool:*` merely for convenience.
Do not pre-authorize arbitrary language runtimes or mutating Git/GitHub commands.
For validation-contract commands, use the renderer's derived spelling (pytest coverage
flags stripped, non-gating `|| true` CI commands excluded) — the finalizer requires an
exact `Bash(<command>)` permission for each contract command in that spelling.
Under a repo-root `uv.lock` or `poetry.lock`, that spelling is the project-runner form
(`uv run pytest`, `poetry run pytest`) or the venv-local `./.venv/bin/pytest`, never the
bare tool name, and the permission carries that identical string.

**Secret-file boundary:** Protect every root and nested `.env*` variant with `Read(...)`
deny rules. Those rules gate both native Read/Glob/Grep and any Bash reader that opens
the path — `cat`, `head`, `tail`, `grep`, `rg` — whenever Claude Code can resolve the
path argument. The denies match `.env.example`, `.env.sample`, `.env.template`, and
`.env.local.example` too, so read those safe examples in Phase 0, before this phase
writes the boundary; afterwards they are unreadable for the rest of the session, and no
rerun changes that. Keep variants such as `.env.example.local` protected.

**Never write a `sandbox` key, and remove an existing one from the project
`.claude/settings.json`.** Claude Code's Bash sandbox is a per-user choice: it belongs in
`.claude/settings.local.json` or user settings, which onboarding never changes.

Protect credential *data* with the exact globs listed below, never a bare
`credentials*` pattern. Deny the extensionless `credentials` file, `.credentials*`
dotfiles, and `credentials*` files carrying a credential-data suffix (`.json`, `.yaml`,
`.yml`, `.toml`, `.ini`, `.cfg`, `.conf`, `.env`, `.txt`, `.pem`, `.key`, `.p12`,
`.pfx`, `.jks`, `.keystore`, `.db`, `.sqlite`, `.enc`). Leave source files readable —
`credentials.py`, `credentials.ts`, and every other recognized source extension (`.py`,
`.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.go`, `.rb`, `.java`, `.rs`, `.php`,
`.cs`, `.kt`, `.swift`, `.c`, `.h`, `.cpp`, `.hpp`, `.sh`, `.bash`, `.sql`, `.md`) is
project code, not a credential store; denying it hides the user's own source from every
later session and breaks onboarding's own verification reads. Emit those credential
globs in `permissions.deny` (as `Read(...)`). The `./secrets/**` and `.env*` rules are
unchanged.

Claude permission syntax is part of the output contract:

- a fully specified command is `Bash(<exact command>)`, with no `:*` suffix;
- add `:*` only when the workflow intentionally permits additional arguments after the
  declared prefix;
- a no-argument command such as `pwd` is also exact;
- never change `Bash(./install.sh --dry-run)` into
  `Bash(./install.sh --dry-run:*)`.

Categories to include:

- **Build/run**: Detected package manager and build commands
- **Test**: Detected test framework runner
- **Lint/format**: Detected linter and formatter
- **Git**: Always include only read-only inspection commands. Mutating commands such
  as checkout, switch, reset, clean, add, commit, push, and PR creation must retain
  their normal permission prompt.
- **Read-only utilities**: Always (ls, cat, head, tail, wc, pwd, rg)
- **Monorepo**: If detected (nx, turbo, etc.)
- **Language runtime**: Never allow a raw interpreter wildcard such as `node:*`,
  `python:*`, or `ruby:*`. Allow an exact detected project command only when it is
  required for build, test, lint, format, or type checking.
- **Standard tools**: Always pre-authorize read-only tools (Read, Glob, Grep,
  WebFetch, Task). Write, Edit, and other mutating tools retain their normal prompt.

**Tool-level security deny list** (always, as defense in depth):

```json
[
  "Bash(rm -rf /)",
  "Bash(rm -rf /*)",
  "Bash(sudo:*)",
  "Bash(chmod 777:*)",
  "Read(/.env*)",
  "Read(/**/.env*)",
  "Read(./secrets/**)",
  "Read(./**/credentials)",
  "Read(./**/.credentials*)",
  "Read(./**/credentials*.json)",
  "Read(./**/credentials*.yaml)",
  "Read(./**/credentials*.yml)",
  "Read(./**/credentials*.toml)",
  "Read(./**/credentials*.ini)",
  "Read(./**/credentials*.cfg)",
  "Read(./**/credentials*.conf)",
  "Read(./**/credentials*.env)",
  "Read(./**/credentials*.txt)",
  "Read(./**/credentials*.pem)",
  "Read(./**/credentials*.key)",
  "Read(./**/credentials*.p12)",
  "Read(./**/credentials*.pfx)",
  "Read(./**/credentials*.jks)",
  "Read(./**/credentials*.keystore)",
  "Read(./**/credentials*.db)",
  "Read(./**/credentials*.sqlite)",
  "Read(./**/credentials*.enc)"
]
```

**Sandbox settings:** none. Never emit a `sandbox` key; remove an existing one from the
project settings (see the merge strategy in `hooks-and-config.md`).

When the repository has a formatter config, generate the whole file with that
formatter's indent character so the formatter gate passes on first write. Indent
character alone is not sufficient: line-wrapping decisions (single-line versus wrapped
arrays, column width) are repo-config-dependent and cannot be baked into any template.
After writing each generated file, if the repository exposes a formatter command that
covers that file type (for example `biome check --write <path>` or
`prettier --write <path>`), run it scoped to the generated path before entering the
validation loop and treat the formatter's output as the canonical file content. Count a
formatter-gate failure on an unformatted generated file as a validation attempt only
when this step was skipped.

Whether Bash runs sandboxed is the user's setting and outside this contract. Never
describe the generated permission rules as an OS-level boundary — they gate this
session's tools, nothing else.

### 1b. `.mcp.json`

This phase remains opt-in. A normal run reports MCP opportunities without writing or
enabling project MCP servers; `--enable-mcp` permits the relevant project overlay.

Use the mcp-detection reference loaded from the main router for the server catalog and detection criteria.

**CRITICAL — check active MCPs before adding project configuration:**
Before adding any server, inventory the project `.mcp.json`, `claude mcp list` / `get`
output when available, and MCP tools in the current session. Any
`mcp__<name>__*` tool proves that server is active, but does not prove its scope. Do NOT
duplicate a server active at local, project, user, plugin, or managed scope because
duplicate configuration causes conflicts and double-initialization attempts.
Apply these branches exactly when `--enable-mcp` was selected:

- If a relevant server is active nowhere, add its missing, secret-free project entry.
- If it is already active, do not duplicate it. In the summary, say
  `"github — already active"` unless the exact scope was independently proven.
- If it is already active but this project explicitly needs a different shared configuration,
  add a secret-free project override and identify it as an override in the summary.

If the user explicitly opts into MCP setup and the file exists: merge — add missing
servers, preserve existing config. If the user does not opt in, report detected
servers and write nothing.

### 1c. Hooks

This phase only plans the hook overlay when the user passed `--enable-hooks`. Do not
create the script or register hooks yet. Without that flag, do not create, register, or
modify hooks. Actual hook writes are deferred to Phase 4b so a newly installed
branch-protection hook cannot block onboarding's own later Edit/Write operations.

When enabled, add these inline hooks to `.claude/settings.json`:

- `PreToolUse` on `Edit|Write`: block edits on the detected base branch
- `SessionStart` on `startup|resume`: inject branch name, ticket ID, and uncommitted file count

Prepare `.claude/hooks/skill-eval.sh` from the already-loaded hooks-and-config reference and record
whether it already exists. Do not write it in this phase.

### 1d. `.gitignore`

This phase runs for every normal onboarding. `--launch-control` maintenance must not modify
`.gitignore`.

Append if not already present (check before appending):

```
# Claude Code local files
.claude/settings.local.json
.claude/*.local.*
CLAUDE.local.md
.claude_states/
.launch-control-onboard/
```

`.claude_states/` holds local session checkpoints; preserve its contents and do not stage them.

`.launch-control-onboard/` is the run's transient control directory; ignoring it keeps stray
onboarding state out of the tracked tree even when a run ends before cleanup. Before
appending a rule, test whether the path is already ignored with
`git check-ignore -q <path>` and whether an existing broader pattern already covers it.
Treat a covered rule as a no-op; do not append redundant local-file rules or report
`.gitignore` as merged. Because the file exists, never classify it under `SKIPPED`.
List it under `PRESERVED` whenever it existed before the run and remains byte/state
identical, including when a broader rule already covers the requested patterns. Dirty
baseline paths remain a protected subset of `PRESERVED`. Never stage `.gitignore`
changes automatically.
