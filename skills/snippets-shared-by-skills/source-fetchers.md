# Source fetchers — stack-agnostic recipes for the CRISPY pipeline

Skills that read external source content (`research-codebase`, `research-questions`, `log-decision`, `catalog`) link to this snippet to dispatch on the source type rather than hard-coding Atlassian. Source types are checked in order; the first matching recipe wins.

## Source type → fetch recipe

| Source type | URL / reference pattern | Fetch recipe | Required tool |
|---|---|---|---|
| GitHub issue / PR / discussion | `https://github.com/{owner}/{repo}/issues/N`, `/pull/N`, `/discussions/N` | If `mcp__github__*` is available: call `mcp__github__get_issue` / `get_pull_request` / `get_discussion` with `owner`, `repo`, `number`. Else, if `gh` is installed and authenticated, use `gh issue view N --json title,body,comments,labels,state` / `gh pr view N --json title,body,comments,reviews,files` / `gh api repos/{owner}/{repo}/discussions/N`. If neither is available, ask the user to provide the source content or enable one provider. | `mcp__github__*` MCP (preferred) or authenticated `gh` CLI |
| Slack thread (root + replies) | `https://{workspace}.slack.com/archives/{CHANNEL_ID}/p{ts}` — `ts` is digits; canonical timestamp is `{ts[:-6]}.{ts[-6:]}` | Call `mcp__slack__slack_read_thread` with the channel ID and canonical ts. Preserve message order, author IDs, raw text verbatim. | `mcp__slack__*` MCP |
| Slack single message | Same pattern; treat as one message unless it's the thread root | Call `mcp__slack__slack_read_channel` for the specific ts (or `slack_read_thread` if it's a root). | `mcp__slack__*` MCP |
| Slack user profiles | Resolving `U01EXAMPLE99` → display name + role | Call `mcp__slack__slack_read_user_profile` for each unique user ID. | `mcp__slack__*` MCP |
| Notion page | `https://www.notion.so/{workspace}/{title-or-id}-{32hex}` | If `mcp__notion__*` is available, use its page-fetch or search tools. Otherwise ask the user to paste the page content directly, including any sub-pages they want included. Cite the URL and identify pasted content as user-provided. | `mcp__notion__*` MCP (preferred) or manual paste |
| Atlassian Jira ticket | `PROJ-NNN`, `ENG-NNN`, `BL-NNN`-style key, or full `https://*.atlassian.net/browse/{KEY}` URL | If Atlassian MCP is configured AND the user is using Atlassian for this project: call `mcp__atlassian__getJiraIssue` (or equivalent prefix in your session) with `cloudId` (from `getAccessibleAtlassianResources`) and `issueIdOrKey`. **Optional usage** — many projects use BACKLOG.md or GitHub issues for `BL-###`-style IDs; `getJiraIssue` returns 404 for those. Try the repo-local doc fetch first when the ticket prefix is project-specific. | `mcp__atlassian__*` MCP (optional; only when the project actually uses Atlassian) |
| Atlassian Confluence page | `https://*.atlassian.net/wiki/spaces/{SPACE}/pages/{ID}/{slug}` | If Atlassian MCP available: call `mcp__atlassian__getConfluencePage` with `cloudId` + `pageId`. Optional — only when the project actually publishes to Confluence. | `mcp__atlassian__*` MCP (optional) |
| Repo-local docs | `BACKLOG.md`, `docs/...`, `workbench/...`, `README.md`, paths inside the project | Use `Read` (without `limit`/`offset`) for full content. For repo-tracked tickets like `BL-NNN`, `Grep "BL-NNN" BACKLOG.md` to locate the row, then check `workbench/plans/BL-NNN.md` / `workbench/BL-NNN/*` for prior CRISPY artifacts. | `Read`, `Grep` tools (always available) |
| Datadog monitor / dashboard / alert | `https://*.datadoghq.com/monitors/...`, `/dashboard/...` | If a Datadog MCP is available at any scope, call the appropriate MCP tool. Otherwise ask the user to paste the relevant query / alert payload. | Datadog MCP (project-specific) |
| Inline text | User pastes content directly | Capture verbatim under "user-provided context". | None |

## Recipe selection — order of attempts

When a single source artifact is provided, classify the URL / reference using the patterns above. Match longest-prefix first:

1. **Slack URL** (`*.slack.com/archives/...`) → Slack MCP
2. **GitHub URL** (`github.com/{owner}/{repo}/...`) → GitHub MCP, fall back to `gh` CLI
3. **Notion URL** (`notion.so/...` or `notion.site/...`) → Notion MCP when available,
   otherwise manual paste
4. **Atlassian URL** (`*.atlassian.net/...`) → Atlassian MCP (if available + project uses Atlassian)
5. **Repo-local path** (starts with `/`, `./`, or matches a known repo subdir like `BACKLOG.md`, `docs/`, `workbench/`, `README.md`) → `Read`
6. **Bare ticket key** (`GH-NNN`, `PROJ-NNN`, `ENG-NNN`, `BL-NNN`, etc.):
   - If `BL-NNN` or project-specific prefix → `Grep "{KEY}" BACKLOG.md` then read related `workbench/` files
   - Else try Atlassian if available
   - Else ask the user where the ticket lives
7. **Datadog URL** → Datadog MCP if configured
8. **Anything else** → ask the user

## Failure handling

- **MCP missing / unauthenticated** (tool not registered, 401/403, "not authenticated" errors): surface a one-line message naming the missing MCP and pause. Do not invent content. Do not retry silently.
- **Channel/permission denied while authenticated** (e.g. bot not in a private channel, thread deleted, Jira project access lost): tell the user specifically what failed and ask whether to skip that source or paste the contents. Do not halt the whole skill.
- **Empty response from a successful fetch**: ask the user — common cause is the bot/account lacking access to the channel/project. Do not assume the source has no content.

## Notes

- Atlassian tool names can vary by provider version. Detect the available
  `mcp__atlassian__*` tools at runtime instead of assuming exact function names.
- Notion MCP authentication is provider-managed; the manual-paste fallback requires no
  MCP authentication.
- `GitHub permalinks for code references` lives in `@snippets-shared-by-skills/permalinks.md`, not here. This file is for *input* fetching; permalinks.md is for *output* link generation.
