# Ticket Intake and Design Reference

## Source order

Stop at the first source with content. Use the installed
`snippets-shared-by-skills/source-fetchers.md` for canonical recipes.

1. Search `BACKLOG.md`, roadmap files, and `workbench/<TICKET>/`.
{{#if HAS_GITHUB_MCP}}
2. Use available `mcp__github__*` issue, pull-request, and discussion reads.
{{/if}}
{{#unless HAS_GITHUB_MCP}}
{{#if HAS_GITHUB_PR}}
2. Use `gh issue view` or `gh pr view` read-only commands.
{{/if}}
{{/unless}}
{{#if HAS_NOTION_MCP}}
3. Use available `mcp__notion__*` reads and cite the page URL.
{{/if}}
{{#unless HAS_NOTION_MCP}}
{{#if HAS_NOTION}}
3. Ask the user to paste the Notion body because no Notion MCP is available.
{{/if}}
{{/unless}}
{{#if HAS_JIRA_MCP}}
4. Use Atlassian only when the user supplies a Jira key; fetch linked Confluence when relevant.
{{#if HAS_CHROME_MCP}}
   Attachment binaries: use `mcp__chrome__use_browser` with
   `/rest/api/3/attachment/content/<ID>`.
{{/if}}
{{#if HAS_CHROME_DEVTOOLS_MCP}}
   Attachment binaries: use available `mcp__chrome-devtools__*` tools with
   `/rest/api/3/attachment/content/<ID>`.
{{/if}}
{{/if}}
5. Use ticket text supplied in the conversation.

## Confirm scope and necessity

Record the selected ticket's backlog priority, dependencies, observable outcome and exclusions
in the existing plan before implementation. Resolve conflicts with the selected outcome or
backlog order before starting; broad authorization alone is not a priority decision.

Before adding infrastructure, demonstrate the native/existing capability gap: trace the
current path and record the observed missing capability and why reuse cannot meet the outcome.
Check existing code, native platform features and installed tools first. Custom control code
must address that specific gap; speculative future needs do not justify it.

Record substantial newly discovered prerequisites in the backlog before implementing them.
Reassess whether each is necessary for the selected outcome and consistent with priority and
remaining effort; otherwise defer it. Changed outcome, architecture or budget requires an
approach/priority reassessment in the existing plan, within existing authorization. Ask only
when a substantive decision is missing; do not add repeated generic permission prompts.

## Platform selection

Select one ticket platform before choosing verification guidance:

1. User named a platform: use it.
2. Ticket or branch metadata identifies a platform: use that hint.
3. Package path identifies a platform: use the changed package.
4. Ambiguous: ask one direct question instead of guessing.

For shared work, record the affected consuming platforms in the ticket plan.

## Specialist routing

Use only the selected platform row plus the `any` row. `mobile-iOS` and
`mobile-Android` both select the `mobile` row. Rows list only agents detected under
`.claude/agents/`; an absent row means no specialist is available for that platform.

| Platform | Detected agents |
|---|---|
{{#each AGENTS_BY_PLATFORM_ROW}}
| {{this.platform}} | {{this.agents}} |
{{/each}}

## Understand the code

| Need | Route |
|---|---|
| Locate definitions | surveyor |
| Trace the live flow | navigator |
| Find existing patterns | veteran |
{{#if HAS_CODE_SEARCH_MCP}}
| Trace callers and cross-repo symbols | detected semantic code-search MCP |
{{/if}}
{{#if HAS_FEATURE_RESEARCHER}}
| Research an external library | feature-researcher |
{{/if}}
| Read a known path | direct read |

For two independent questions, dispatch in parallel. Read directly named files in the
main context before delegation. Current source outranks historical workbench notes.
Use `technician` and `episodic-memory` when available for prior project work.

## Design route

- Clear fixes: reproduce, identify root cause, write one concise reviewed dated plan.
- Fuzzy fixes: run `superpowers:systematic-debugging`, then the selected CRISPY depth.
- Features: run `superpowers:brainstorming` before code.
- Medium or large features: complete the full authored CRISPY chain from the root skill.
- Refactors: map every caller and preserve behavior with targeted regression coverage.

{{#if HAS_CONFLUENCE}}
When stakeholder signoff requires it, publish the approved design to Confluence via the Atlassian MCP, otherwise paste it in by hand.
{{/if}}
{{#unless HAS_CONFLUENCE}}
Keep the approved design in `workbench/`; no Confluence publishing step is available.
{{/unless}}

The bounded pressure-test decision and questions live in the root skill. Write resolved
answers into the existing design artifact before approval.

## Parallel dispatch patterns

- Codebase discovery: locate definitions and trace flow in parallel.
- Pre-ship review: run independent relevant review lenses in parallel.
- Cross-package impact: ask detected platform specialists about separate packages in parallel.

Rule of thumb: parallelize independent reads, never dependent writes.
Use `superpowers:dispatching-parallel-agents` when that skill is available.
