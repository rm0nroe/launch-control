# MCP Server Detection

Only include MCP servers relevant to the detected project. Check for signals before adding each.

## Pre-Check: Existing MCP Configuration

**Before adding any server to the project `.mcp.json`, check whether it is already active
at local, project, user, plugin, or managed scope.**

Claude Code owns local and user MCP persistence; do not infer it from undocumented file
paths. Use `claude mcp list` and `claude mcp get <name>` when the CLI is available. Parse
the project `.mcp.json` directly for shared project-scope servers. Plugin-provided and
managed servers may appear only in the active session or `/mcp` inventory.

At the start of Phase 1b, also list MCP tools available in the current session. A tool
prefixed with `mcp__<name>__` proves the server is active, but does not prove its scope.

**Rule:** If a server is already active at any scope, **do not add a duplicate to the
project `.mcp.json`**. Duplicating it causes:
- Config conflicts (project config may override user's auth/credentials)
- Double-initialization attempts
- Confusion about which config is authoritative

**Exception:** Only add a project-level override if the project needs a different,
secret-free shared configuration and the user explicitly selected the project overlay.

**Workflow:**
1. Parse the existing project `.mcp.json` and inventory `claude mcp list` plus active
   `mcp__*` tool prefixes.
2. Build a skip list of servers already active at any scope; record scope only when it
   can be proven.
3. For each candidate server: if active, preserve it and avoid duplication. If inactive,
   add it only when the selected project overlay and credential rules allow it.
4. In the discovery report, state `already active` unless the exact scope is known.

## Server Catalog

### Atlassian (Jira + Confluence)

**Include when:** Branch names contain JIRA-style ticket IDs (`[A-Z]+-[0-9]+`), or `atlassian`/`.jira` appears in CI/config/docs.

```json
"atlassian": {
  "type": "sse",
  "url": "https://mcp.atlassian.com/v1/sse"
}
```

**Detection:**
```bash
git branch -a 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
```

---

### GitHub

**Include when:** Remote origin is GitHub, or `.github/` directory exists.

```json
"github": {
  "type": "http",
  "url": "https://api.githubcopilot.com/mcp/"
}
```

**Detection:**
```bash
git remote get-url origin 2>/dev/null | grep -q "github.com"
```

---

### Sentry

**Include when:** Sentry SDK in dependencies (`@sentry/`, `sentry-sdk`, `sentry`), `sentry.properties` file, or `SENTRY_DSN` in env config.

```json
"sentry": {
  "type": "http",
  "url": "https://mcp.sentry.dev/mcp"
}
```

**Detection:** Check `package.json`, `requirements.txt`, `pyproject.toml`, `Cargo.toml`, `build.gradle*`, `pom.xml` for sentry dependencies. Check `.env.example` for `SENTRY_DSN`.

---

### Datadog

**Include when:** Datadog agent config, `dd-trace` / `datadog` / `ddtrace` in dependencies, `DD_API_KEY` or `DD_SERVICE` in env config, or Datadog references in CI workflows.

Detected Datadog integration. Report the MCP setup opportunity; do not write
credential-shaped values into a project configuration.

**Detection:** Check dependencies for `dd-trace`, `ddtrace`, `datadog`, `@datadog/`. Check `.env.example` for `DD_API_KEY`, `DD_SERVICE`, `DD_ENV`. Check CI workflows for Datadog steps. Check for `datadog.yaml`, `datadog-ci` config, or `docker-compose.yml` referencing Datadog agent.

**Note:** Datadog MCP requires API + app keys. Report the required setup, but do not
write credential-shaped environment values into a project config. If the project
already has `DD_API_KEY` in `.env.example`, reference that in guidance only.

---

### Figma

**Include when:** Project has UI components — React, Vue, Svelte, React Native, iOS, Android — or Storybook config, or `figma` referenced in docs/config.

```json
"figma": {
  "type": "http",
  "url": "https://mcp.figma.com/mcp"
}
```

**Detection:** UI framework in dependencies (react, react-native, vue, svelte, @angular/core, SwiftUI). Presence of `.storybook/`, `storybook` in dependencies, or `figma` in docs/config.

---

### Chrome DevTools

**Include when:** Project is a web application (has a dev server, serves HTML/JS, or has browser-based E2E tests).

```json
"chrome-devtools": {
  "command": "npx",
  "args": ["-y", "chrome-devtools-mcp@latest"]
}
```

**Detection:** Presence of webpack/vite/next.config/nuxt.config (web bundler), `dev` script in package.json that starts a local server, or browser testing tools (cypress, playwright, puppeteer) in dependencies.

---

### GrowthBook (Feature Flags)

**Include when:** GrowthBook SDK in dependencies (`@growthbook/growthbook`, `@growthbook/growthbook-react`, `growthbook-sdk`) or GrowthBook references in code/config.

Detected GrowthBook integration. Report the MCP setup opportunity; do not write
credential-shaped values into a project configuration.

**Detection:** Check dependencies for `@growthbook/`, `growthbook`. Check `.env.example` for `GROWTHBOOK_API_HOST`, `GROWTHBOOK_CLIENT_KEY`. Check for feature flag patterns in code (`useFeature`, `useGrowthBook`, `GrowthBook`).

**Note:** Requires API key and email. Report the required setup; do not add it to the
generated project JSON.

---

## Detection Priority

When onboarding, evaluate servers in this order (most universally useful first):

1. **GitHub** — almost always relevant (any GitHub-hosted repo)
2. **Atlassian** — relevant if JIRA tickets are used
3. **Datadog** — relevant if any observability/monitoring is configured
4. **Sentry** — relevant if error tracking is in dependencies
5. **Figma** — relevant if project has UI components
6. **Chrome DevTools** — relevant if project is a web app
7. **GrowthBook** — relevant if feature flags are in dependencies

Browser-test signals may justify the Chrome DevTools MCP above, but must not produce a
speculative browser-automation MCP entry.

## Merge Strategy (explicit opt-in only)

Only run this merge after the user explicitly opts into project MCP configuration.
Otherwise report detected opportunities and write nothing.

When `.mcp.json` already exists:

1. Parse existing file
2. For each server to add: check if key already exists in `mcpServers`
3. If key exists: **preserve existing config** (user may have customized URL, auth wrapper, or env vars)
4. If key missing: add a secret-free server definition only when it does not require credentials
5. Never remove existing servers — user may have custom MCP servers configured
6. For servers requiring credentials (`datadog`, `growthbook`): report setup guidance and do not add them automatically

## Credential Handling

Servers that need API keys must be reported as setup guidance only. Do not add
placeholder values, copied values, or `env` blocks that look ready for secrets to a
generated `.mcp.json`:

Detected Datadog integration. To enable Datadog MCP, configure `DD_API_KEY` and
`DD_APP_KEY` through the user's approved secret store, then authenticate the server.

Never hardcode actual secrets. If `.env.example` documents key names, reference that
file in the setup report only. Project MCP configuration requires explicit user opt-in.

## Example Outputs

### Full-stack web app (React + Node + GitHub + Datadog + Sentry + Figma)
```json
{
  "mcpServers": {
    "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
    "atlassian": { "type": "sse", "url": "https://mcp.atlassian.com/v1/sse" },
    "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
    "figma": { "type": "http", "url": "https://mcp.figma.com/mcp" },
    "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"] }
  }
}
```
Datadog is reported separately as credential-requiring setup guidance and is not added
to the generated `.mcp.json`.

### Kotlin backend microservice (Gradle + JIRA + Datadog + Sentry)
```json
{
  "mcpServers": {
    "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
    "atlassian": { "type": "sse", "url": "https://mcp.atlassian.com/v1/sse" },
    "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" }
  }
}
```
Datadog is reported separately as credential-requiring setup guidance and is not added
to the generated `.mcp.json`.

### Python CLI tool (pip + GitHub only)
```json
{
  "mcpServers": {
    "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" }
  }
}
```
