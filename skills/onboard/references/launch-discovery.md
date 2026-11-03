# launch Discovery Rules

Augments onboard's Phase 0 with the signals launch generation needs beyond the base context dictionary.

## Inputs (from existing Phase 0 — already extracted)

- `PROJECT_NAME`, `BASE_BRANCH`, `PACKAGE_MANAGER`, `MONOREPO_TOOL`
- `TEST_FRAMEWORK`, `LINTER`, `FORMATTER`, `TYPECHECK_TOOL`
- `MCP_SERVERS[]` (from `.mcp.json` AND active session `mcp__*` tool prefixes)
- `AGENTS[]` (from `.claude/agents/*.md`)
- `COMMANDS[]` (from `.claude/commands/*.md`)
- `SKILLS[]` (from `.claude/skills/*/SKILL.md` and available installed skills)
- `CLAUDE_MD_FILES[]` — project-local paths and contents only; user-global files are excluded by default. With `--include-global-claude`, include only `~/.claude/CLAUDE.md`.

## Additional extraction for launch

### TYPECHECK_CMD

Resolution order:
1. CI config grep for typecheck step → exact command
2. `package.json` scripts: `type-check`, `typecheck`, `tsc`
3. Detected: `npx tsc --noEmit` (TypeScript), `mypy <src>` (Python with mypy in deps), `cargo check` (Rust), `go vet ./...` (Go)
4. Empty string if not detected

### TEST_CMD

Resolution order:
1. Monorepo: `yarn nx affected -t=test --base=<BASE_BRANCH>` if Nx detected
2. CI config grep for test step
3. `package.json` test script
4. Framework default: `pytest`, `cargo test`, `go test ./...`, `jest`, `vitest`

### LINT_CMD

Resolution order:
1. `yarn nx affected -t=lint --base=<BASE_BRANCH>` if Nx detected
2. `npx eslint <changed-files>` if eslint detected
3. `ruff check src/` if ruff detected
4. `cargo clippy` / `golangci-lint run`

### BUILD_CMD

Resolution order:
1. `yarn nx affected -t=build --base=<BASE_BRANCH>` if Nx detected
2. `package.json` build script
3. `cargo build` / `go build` / etc.

### INSTALL_CMD

Resolution order:
1. `pnpm-lock.yaml` exists → `pnpm install --frozen-lockfile`
2. `yarn.lock` exists → `yarn install --frozen-lockfile`
3. `package-lock.json` exists → `npm ci`
4. `bun.lockb` exists → `bun install --frozen-lockfile`
5. `uv.lock` exists → `uv sync`
6. `poetry.lock` exists → `poetry install`
7. `Cargo.lock` exists → `cargo fetch`
8. `go.sum` exists → `go mod download`
9. Empty string if not detected (Phase 4a worktree block emits the worktree-add but skips the install line)

### WORKTREES_ENABLED

Boolean, default **true**. Forces to `false` when any:
- `--no-worktrees` flag passed to onboard
- `git rev-parse --git-dir` fails (not a git repo)
- `git rev-parse --show-superproject-working-tree` returns a non-empty path (submodule)
- Project explicitly opts out via `.claude/onboard-config.json` `{ "worktrees": false }` (read if present)

When `false`, the rendered launch template emits the legacy in-place `git switch -c <branch>` Phase 4a and omits the Phase 6 `git worktree remove` cleanup, the Gotchas "Worktree skipped" bullet, and the Exit-criteria "Worktree removed" checkbox.

## Forge detection

Detect the repository's hosting provider from `git remote get-url origin` and the
available CLI/configuration. Set `FORGE` to `github`, `gitlab`, `bitbucket`, or `none`.
Do not render GitHub `gh pr` commands when the forge is not GitHub. For `none`, render
a local handoff instead of a push/PR command.

## AI evaluation scope

Reuse the `AI_EVAL_ENABLED` value resolved during Phase 0 context discovery. Do not
recompute it here; Phase 2a testing guidance and Phase 2d Launch must consume the same
explicit configuration or paired positive repository evidence decision. A generic
dependency name alone never activates it.

## Platform detection

Set boolean flags by package path inspection:

| Flag | Detection signal |
|---|---|
| `PLATFORM_IOS` | `packages/mobile/ios/` exists OR `*.xcodeproj` anywhere |
| `PLATFORM_ANDROID` | `packages/mobile/android/` exists OR `build.gradle` at mobile path |
| `PLATFORM_WEB` | `packages/web/`, `apps/web/`, OR `next.config.*` / `vite.config.*` at root |
| `PLATFORM_BACKEND` | `packages/*-server/`, `packages/*-api/`, OR `nest-cli.json` / `manage.py` / `Cargo.toml` with `[[bin]]` |
| `PLATFORM_SHARED` | `packages/shared/` OR `packages/lib*/` |

Set `PLATFORM_GENERAL = true` when no platform-specific signal is present.

Multiple flags can be true. If none are true, set `PLATFORM_GENERAL = true` and render
a `general/unknown` platform block. Ask the user for the platform only when a
platform-specific verification step is actually required.

## Tool capability flags

Derived from MCP_SERVERS, AGENTS, COMMANDS:

| Flag | True when |
|---|---|
| `HAS_JIRA_MCP` | `mcp__atlassian__*` in MCP_SERVERS |
| `HAS_GITHUB_MCP` | `mcp__github__*` in MCP_SERVERS |
| `HAS_CHROME_MCP` | `mcp__chrome__*` only |
| `HAS_CHROME_DEVTOOLS_MCP` | `mcp__chrome-devtools__*` only |
| `HAS_PLAYWRIGHT_MCP` | `mcp__playwright__*` |
| `HAS_GROWTHBOOK_MCP` | `mcp__growthbook__*` |
| `HAS_DATADOG_MCP` | `mcp__datadog__*` |
| `HAS_SENTRY_MCP` | `mcp__sentry__*` |
| `HAS_CODE_SEARCH_MCP` | a semantic code-search MCP (`mcp__*` code-search prefix) in MCP_SERVERS |
| `HAS_FEATURE_RESEARCHER` | a `feature-researcher` agent or skill is available |
| `HAS_COMPLIANCE_AGENT` | a compliance/security reviewer agent is available |
| `HAS_PERFORMANCE_AGENT` | a performance optimizer agent is available |
| `HAS_XCODEBUILD_MCP` | `mcp__XcodeBuildMCP__*` or `mcp__ios-simulator__*` |
| `HAS_FIGMA_MCP` | `mcp__figma__*` |
| `HAS_SLACK_MCP` | `mcp__slack__*` in MCP_SERVERS |
| `HAS_NOTION_MCP` | `mcp__notion__*` in MCP_SERVERS |
| `HAS_NOTION` | `HAS_NOTION_MCP` true, OR a `notion.so` / `notion.site` URL appears in `README.md` / `docs/` / `BACKLOG.md` (project uses Notion even without MCP — onboard should set this so the launch template surfaces manual-paste guidance) |
| `HAS_CONFLUENCE` | `HAS_JIRA_MCP` true AND an `*.atlassian.net/wiki` URL appears in `README.md` / `docs/` / `CI config` / `.gitignore` / linked design docs. Don't assume from MCP availability alone — the user may have Atlassian MCP at user level but not use Confluence for this specific project. |

## Project-specific delivery hooks (opt-in, not auto-detected)

launch can reference a project's own ship / security-review / deploy-verify commands in Phase 5–7 — but there is no universal filename for those across orgs, so onboard does **not** guess by sniffing `.claude/commands/`. A repo that happens to have a file named `ship.md` for an unrelated purpose should not get it silently wired into launch.

Instead, these hooks are declared explicitly in `.claude/onboard-config.json` under `launchHooks`, e.g.:

```json
{
  "launchHooks": {
    "ship": "ship",
    "securityReview": "security-review",
    "deployVerify": "deploy-verify"
  }
}
```

Each key is optional — declare only the hooks this project actually has. The value is the command's filename stem (without `.md`) under `.claude/commands/`.

| Flag | True when | Command name variable |
|---|---|---|
| `HAS_SHIP_COMMAND` | `launchHooks.ship` is set AND `.claude/commands/<value>.md` exists | `SHIP_COMMAND_NAME` = `<value>` |
| `HAS_SECURITY_REVIEW_COMMAND` | `launchHooks.securityReview` is set AND the file exists | `SECURITY_REVIEW_COMMAND_NAME` = `<value>` |
| `HAS_DEPLOY_VERIFY_COMMAND` | `launchHooks.deployVerify` is set AND the file exists | `DEPLOY_VERIFY_COMMAND_NAME` = `<value>` |

If `.claude/onboard-config.json` is absent, or `launchHooks` is absent/empty, all flags are `false` — Phase 5–7 render their generic (no-hook) path. A declared hook whose command file doesn't exist is also `false` (stale config, not a crash) — surface this to the user as a one-line notice during generation so they can fix the config or drop the entry.

Do **not** add org-specific staging/gate/eligibility command hooks to this table. Those belong in the project's own config or a private fork — never in the portable pack.

## Specialist agent inventory

For each `.claude/agents/<name>.md`:
- Read frontmatter `name`, `description`
- Read body for "Use when" / "Use for" sentences
- Map to platform tags by content keywords:
  - "React Native" / "RN" / "Expo" → `mobile`
  - "React" / "Next.js" / "web app" → `web`
  - "GraphQL" / "NestJS" / "resolver" → `backend`
  - "monorepo" / "Nx" / "build graph" → `shared`
  - "security" / "auth" / "regulated content" → `any`
  - "performance" / "bundle" → `any`

Output two parallel structures from the same scan:

- `AGENTS_BY_PLATFORM = { mobile: [...], web: [...], backend: [...], shared: [...], any: [...] }` — keyed object for direct lookup.
- `AGENTS_BY_PLATFORM_ROW = [{ platform: "mobile", agents: "<comma-separated names with parenthetical purpose>" }, { platform: "web", agents: "..." }, ...]` — array of row records for the template's `{{#each AGENTS_BY_PLATFORM_ROW}}` loop. Skip platforms with no detected agents.
- `AGENTS_BY_PLATFORM_FLAT` — single space-separated string of all agent names, used in the parallel-dispatch section.

## Other template-required values

These are derived during the same Phase 0 pass:

| Variable | Resolution |
|---|---|
| `PLATFORM_LIST` | Pipe-separated human-readable list of detected platforms, e.g. `mobile-iOS · mobile-Android · web · backend · shared` |
| `PACKAGE_PATH_HINTS` | Comma-separated detected package globs, e.g. `packages/mobile/*`, `packages/web/*`, `packages/graphql-server/*` |
| `PACKAGE_DIFF_SCOPE` | Path argument for `git diff --stat`, scoped to the source root of a package. For monorepos with `packages/<pkg>/src/` layout: `packages/<pkg>/src/`. For non-monorepos: `src/` or `.` (project root). |
| `SPECIALIST_DOMAIN_LIST` | Comma-separated example domain hints from detected agents, e.g. `graphql-server resolver, RN component, XState machine, etc.` |
| `ANDROID_TEST_CMD` | Resolution: `package.json` script matching `android:*:test`; fallback to `yarn android:test`; fallback to "your project's Detox flow" |
| `BACKEND_LOCAL_URL` | Resolution: parse `.env.example` or dev script for the local server URL (e.g. `http://localhost:3333/graphql` for graphql-server). Fallback to `http://localhost:<PORT>` if a port is detectable, else `<your local backend URL>` |
| `BACKEND_E2E_CMD` | Resolution: `package.json` script matching `test:gql`, `test:e2e`, `test:integration`. Empty string if not detected. |
| `FORGE` | `github`, `gitlab`, `bitbucket`, or `none` from the `origin` remote and available provider tooling. |
| `HAS_GITHUB_PR` / `HAS_GITLAB_MR` / `HAS_BITBUCKET_PR` | True only for the detected forge and its supported PR/MR workflow. |
| `PLATFORM_GENERAL` | True when no iOS, Android, web, backend, or shared signal is detected. |

## Convention extraction

For each path in `CLAUDE_MD_FILES`:
- Capture file path relative to the project root
- Capture full contents verbatim
- Output as a list of `{ source: "<path>", content: "<verbatim>" }` records

No interpretation. No bullet classification. No header parsing. Verbatim only after
the project-local scope check. Never read or embed `~/.claude/CLAUDE.md` unless
`--include-global-claude` was explicitly passed. Never include `CLAUDE.local.md`.

### Supervised autonomy

`/onboard` sets `AUTONOMY_ENABLED` false; only the Launch stage renders with it true.
