---
name: research-codebase
description: Document codebase as-is with workbench directory for historical context
model: opus
effort: high
---

<!-- Modified from HumanLayer (https://github.com/humanlayer/humanlayer), Apache-2.0, Copyright 2025-2026 QueryTale, Inc. d/b/a HumanLayer. Changed for Launch Control. -->

# Research Codebase

You are tasked with conducting comprehensive research across the codebase to answer user questions by spawning parallel sub-agents and synthesizing their findings.

## CRITICAL: YOUR ONLY JOB IS TO DOCUMENT AND EXPLAIN THE CODEBASE AS IT EXISTS TODAY
- DO NOT suggest improvements or changes unless the user explicitly asks for them
- DO NOT perform root cause analysis unless the user explicitly asks for them
- DO NOT propose future enhancements unless the user explicitly asks for them
- DO NOT review the implementation or identify problems
- DO NOT recommend refactoring, optimization, or architectural changes
- ONLY describe what exists, where it exists, how it works, and how components interact
- You are creating a technical map/documentation of the existing system

## Initial Setup:

When this command is invoked, respond with:
```
I'm ready to research the codebase. Please provide your research question or area of interest, and I'll analyze it thoroughly by exploring relevant components and connections.
```

Then wait for the user's research query.

## Steps to follow after receiving the research query:

1. **Read any directly mentioned files first:**
   - If the user mentions specific files (tickets, docs, JSON), read them FULLY first
   - Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: Read these files yourself in the main context before spawning any sub-tasks
   - This ensures you have full context before decomposing the research

2. **Analyze and decompose the research question:**
   - Break down the user's query into composable research areas
   - Take time to ultrathink about the underlying patterns, connections, and architectural implications the user might be seeking
   - Identify specific components, patterns, or concepts to investigate
   - Create a research plan using TodoWrite to track all subtasks
   - Consider which directories, files, or architectural patterns are relevant

3. **Spawn parallel sub-agent tasks for comprehensive research:**
   - Create multiple Task agents to research different aspects concurrently
   - We now have specialized agents that know how to do specific research tasks:

   **For codebase research:**
   - Use the **surveyor** agent to find WHERE files and components live
   - Use the **navigator** agent to understand HOW specific code works, including cross-service interactions (it has semantic code-search MCP)
   - Use the **veteran** agent to find examples of existing patterns (without evaluating them)

   **IMPORTANT**: All agents are documentarians, not critics. They will describe what exists without suggesting improvements or identifying issues.

   **For workbench directory:**
   - Use the **technician** agent to discover what documents exist about the topic
   - Use the **integrator** agent to extract key insights from specific documents (only the most relevant ones)

   **For web research (only if user explicitly asks):**
   - Use the built-in WebSearch and WebFetch tools (or the Explore agent) for external documentation and resources
   - IF you delegate web research to a subagent, instruct it to return LINKS with their findings, and please INCLUDE those links in your final report

   **For retrieving ticket / spec / decision content from external sources:**
   - Dispatch on the source type using the recipes in `@snippets-shared-by-skills/source-fetchers.md` — covers GitHub issues/PRs/discussions, Slack threads, Notion pages, Atlassian Jira/Confluence (optional), repo-local docs (`BACKLOG.md`, `workbench/`, `docs/`), and Datadog monitors. The fetcher snippet picks the right tool based on URL pattern; you don't need to know which MCP is wired up.

   **For exploring other repositories and services (if relevant):**
   - Treat unclear imported packages, API endpoints, and upstream connections as unresolved ownership questions
   - Use available **semantic code-search** MCP, repository context, and internal documentation to determine the owner before documenting them as such

   The key is to use these agents intelligently:
   - Start with locator agents to find what exists
   - Then use analyzer agents on the most promising findings to document how they work
   - Run multiple agents in parallel when they're searching for different things
   - Each agent knows its job - just tell it what you're looking for
   - Don't write detailed prompts about HOW to search - the agents already know
   - Remind agents they are documenting, not evaluating or improving

4. **Wait for all sub-agents to complete and synthesize findings:**
   - IMPORTANT: Wait for ALL sub-agent tasks to complete before proceeding
   - Compile all sub-agent results (both codebase and workbench findings)
   - Prioritize live codebase findings as primary source of truth
   - Use workbench/ findings as supplementary historical context
   - Connect findings across different components
   - Include specific file paths and line numbers for reference
   - Highlight patterns, connections, and architectural decisions
   - Answer the user's specific questions with concrete evidence

5. **Gather metadata for the research document:**
   - **Determine the primary repository**: Review all code references and file paths collected by sub-agents in step 4. Count which repository appears most frequently in the findings. The primary repository is the one where the majority of referenced code lives — this is often a different repo from the local one (`team-knowledge` is a documentation repo, not usually the subject of research).
     - If most references came from semantic code-search MCP results, the repository name is typically embedded in class/method paths (e.g., `repo-name/src/...`)
     - If most references are local files in the current working directory, use the local git repo
   - **Get the primary repository's commit**: Once you've identified the primary repository:
     - If it's the local repo: use `git rev-parse HEAD` for the commit SHA
     - If it's a remote repo explored via semantic code-search: determine the GitHub org from the local repo's remote URL (e.g., `git remote get-url origin` to extract the org), then use `gh api repos/{org}/{repo}/commits/main --jq .sha` to get the latest commit SHA. If that fails, note the commit as "unknown" rather than using the local repo's commit.
   - **Get the primary repository's branch**: Use `main` as the default for remote repos, or `git branch --show-current` for the local repo.
   - Use the available shell to gather: the current date/time with timezone, plus a filename-safe timestamp, the current system user
   - Filename: `workbench/ENG-XXX/research/YYYY-MM-DD-ENG-XXX-RESEARCH-description.md`
     - Format: `workbench/ENG-XXX/research/YYYY-MM-DD-ENG-XXX-RESEARCH-description.md` where:
       - YYYY-MM-DD is today's date
       - ENG-XXX is the ticket number (use "unknown-ticket" if no ticket)
       - RESEARCH is the document type label (always uppercase)
       - description is a brief kebab-case description of the research topic
     - Examples:
       - With ticket: `workbench/PROJ-1478/research/2025-01-08-PROJ-1478-RESEARCH-parent-child-tracking.md`
       - Without ticket: `workbench/unknown-ticket/research/2025-01-08-RESEARCH-authentication-flow.md`

6. **Generate research document:**
   - Use the metadata gathered in step 4
   - When the document references other `workbench/` files (Historical Context, Related Research, etc.), render them as GitHub permalinks per `.claude/skills/snippets-shared-by-skills/permalinks.md`.
   - Structure the document with YAML frontmatter followed by content:
     ```markdown
     ---
     date: [Current date and time with timezone in ISO format]
     researcher: [Researcher name from the current system user]
     git_commit: [Current commit hash]
     branch: [Current branch name]
     repository: [Repository name]
     topic: "[User's Question/Topic]"
     tags: [research, codebase, relevant-component-names]
     status: complete
     last_updated: [Current date in YYYY-MM-DD format]
     last_updated_by: [Researcher name]
     ---

     # Research: [User's Question/Topic]

     **Date**: [Current date and time with timezone from step 4]
     **Researcher**: [Researcher name from the current system user]
     **Git Commit**: [Current commit hash from step 4]
     **Branch**: [Current branch name from step 4]
     **Repository**: [Repository name]

     ## Research Question
     [Original user query]

     ## Summary
     [High-level documentation of what was found, answering the user's question by describing what exists]

     ## Detailed Findings

     ### [Component/Area 1]
     - Description of what exists ([file.ext:line](link))
     - How it connects to other components
     - Current implementation details (without evaluation)

     ### [Component/Area 2]
     ...

     ## Code References
     - `path/to/file.py:123` - Description of what's there
     - `another/file.ts:45-67` - Description of the code block

     ## Architecture Documentation
     [Current patterns, conventions, and design implementations found in the codebase]

     ## Historical Context (from workbench/)
     [Relevant insights from workbench/ directory — render each reference as a GitHub permalink per snippets-shared-by-skills/permalinks.md]
     - [workbench/.../something.md](https://github.com/OWNER/REPO/blob/main/workbench/.../something.md) - Historical decision about X
     - [workbench/.../notes.md](https://github.com/OWNER/REPO/blob/main/workbench/.../notes.md) - Past exploration of Y

     ## Related Research
     [GitHub permalinks to other research documents in workbench/ENG-XXX/research/ — see snippets-shared-by-skills/permalinks.md]

     ## Open Questions
     [Any areas that need further investigation. Items deferred from the self-review loop are recorded here with a one-line reason.]
     ```

7. **Add GitHub permalinks (if applicable):**
   - For each code reference in the document, generate a permalink using the repository that file belongs to — not necessarily the local repo.
   - For **local repo** files: check if on main branch or if commit is pushed (`git branch --show-current`, `git status`), then use `gh repo view --json owner,name` to build `https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`
   - For **remote repo** files (found via semantic code-search): use the primary repository's owner/name and commit SHA from step 5 to build `https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`
   - Replace file references with permalinks in the document

8. **Self-review loop:**

   After the document is written (and permalinks added), run a bounded loop with the `skeptic` subagent before presenting to the user. Hard cap: 3 cycles. The audit trail is written to a single sidecar file, never into the research doc itself.

   **Sidecar path**: `workbench/TICKET/review/YYYY-MM-DD-TICKET-REVIEW-{description}.md`, where `{description}` matches the research doc's kebab-case description. Use `unknown-ticket` if no ticket. One file per loop run; each cycle appends a section.

   For each cycle:
   - Spawn the `skeptic` subagent with parameters:
     - `target_path`: absolute path to the research document just written
     - `upstream_paths`: none (research is the first CRISPY stage; there are no upstream documents)
     - `iteration`: the current cycle number (1, 2, or 3)
   - Parse the structured findings the skeptic returns.
   - **Termination check** — stop the loop if EITHER:
     - `Blockers == 0` AND every Risk and Gap is marked `Trivial: true` by the skeptic, OR
     - This was iteration 3 (hard cap)
   - **Otherwise, revise**:
     - For each `BLOCKER`: do whatever the finding requires to address it. Coverage gaps mean spawning new sub-agents (surveyor/navigator/technician) for the missed area. Objectivity failures mean rewording. Evidence-quality failures mean finding the missing file:line reference. Edit the document in place.
     - For each non-trivial `RISK` or `GAP`: address it if achievable within scope. If not, record it explicitly in the research doc's `## Open Questions` section with a one-line reason for deferring. Do not silently drop findings.
     - **Routing exception** — for findings of these shapes, recording to `## Open Questions` does *not* count as "addressed" and the finding remains live into the next cycle: (a) unverified empirical claim about external-system behavior that the research is documenting as fact, (b) any load-bearing claim being deferred to "the implementer", "pre-merge", or "follow-up". Resolution requires actually running the check / spawning a new sub-agent to verify, and updating the doc with the result. If you reach cycle 3 with one of these still live, the loop ends with that finding listed as an unresolved BLOCKER in the chat summary.
     - For each `Trivial: true` finding: leave it. Loop budget is for real problems.
     - Append a cycle entry to the sidecar file (create the file if this is the first revision cycle). Use the template below.
     - Loop.

   **Sidecar template** (create on first revision cycle, append cycle sections each subsequent cycle):

   ```markdown
   ---
   date: YYYY-MM-DD
   type: self-review
   target: [absolute path to the research doc]
   target_type: research
   ticket: [TICKET or unknown-ticket]
   ---

   # Self-review log: [research doc title]

   **Target**: [GitHub permalink to research doc — see snippets-shared-by-skills/permalinks.md, keep the path as link text]

   ## Cycle 1 — YYYY-MM-DD HH:MM
   **Found**: [B] blockers, [R] risks, [G] gaps
   **Addressed**:
   - [BLOCKER label]: [one-line description of what changed and where in the research doc]
   - ...
   **Deferred**:
   - [GAP label]: [one-line reason — e.g. "out of scope for this research topic", "recorded in Open Questions"]
   ```

   When the loop terminates, print a brief inline summary in chat before moving to step 9 (readability pass). Format:
   ```
   Self-review complete after [N] cycle(s).
   - Cycle 1: [B] blockers, [R] risks, [G] gaps — addressed [X], deferred [Y]
   - Cycle 2: ...
   Sidecar: [path to sidecar file, or "no revisions needed — no sidecar written"]
   [If hard cap reached: note any unresolved items now recorded in Open Questions.]
   ```

   If the loop terminates clean on cycle 1 (no revisions), do not write a sidecar — there is nothing to audit. Do not narrate intermediate cycles in chat — only the final summary. The sidecar file is the audit trail.

9. **Readability pass:**

   After the substance review loop terminates (clean or hard-cap), invoke `editor` once on the final research document. Single pass, no loop.

   - Spawn the `editor` subagent with parameters:
     - `target_path`: absolute path to the research document just written
     - `doc_type`: `research-codebase`
   - Parse the structured findings the agent returns.
   - **Apply MAJOR findings inline.** Edit the document to address each MAJOR per the agent's one-line direction. Do not invoke the agent again to verify — single pass.
   - **MINOR findings are optional.** Apply them if revision is cheap; skip if it's distracting from substance. Do not record skipped MINORs anywhere — readability findings are mechanical, not audit-worthy.
   - **No sidecar.** Readability output is mechanical and does not need an audit trail.
   - **Skip on follow-up updates.** This pass runs only on initial research-doc creation, not when appending follow-up sections in step 11.

   If the agent returns `Type: UNKNOWN`, pass `doc_type: research` explicitly and re-invoke. If it returns `Type: plan`, that's a misroute — investigate before continuing.

   When the readability pass completes, print a brief inline summary in chat before moving to step 10. Format:
   ```
   Readability pass complete.
   - [X] MAJOR findings addressed
   - [Y] MINOR findings ([Z] applied, [W] skipped)
   ```

10. **Sync and present findings:**
   - Present a concise summary of findings to the user
   - Include key file references for easy navigation
   - Ask if they have follow-up questions or need clarification

11. **Handle follow-up questions:**
   - If the user has follow-up questions, append to the same research document
   - Update the frontmatter fields `last_updated` and `last_updated_by` to reflect the update
   - Add `last_updated_note: "Added follow-up research for [brief description]"` to frontmatter
   - Add a new section: `## Follow-up Research [timestamp]`
   - Spawn new sub-agents as needed for additional investigation
   - Continue updating the document and syncing

## Important notes:
- Always use parallel Task agents to maximize efficiency and minimize context usage
- Always run fresh codebase research - never rely solely on existing research documents
- The workbench/ directory provides historical context to supplement live findings
- Focus on finding concrete file paths and line numbers for developer reference
- Research documents should be self-contained with all necessary context
- Each sub-agent prompt should be specific and focused on read-only documentation operations
- Document cross-component connections and how systems interact
- Include temporal context (when the research was conducted)
- Link to GitHub when possible for permanent references
- Keep the main agent focused on synthesis, not deep file reading
- Have sub-agents document examples and usage patterns as they exist
- Explore all of workbench/ directory, not just research subdirectory
- **CRITICAL**: You and all sub-agents are documentarians, not evaluators
- **REMEMBER**: Document what IS, not what SHOULD BE
- **NO RECOMMENDATIONS**: Only describe the current state of the codebase
- **File reading**: Always read mentioned files FULLY (no limit/offset) before spawning sub-tasks
- **Critical ordering**: Follow the numbered steps exactly
  - ALWAYS read mentioned files first before spawning sub-tasks (step 1)
  - ALWAYS wait for all sub-agents to complete before synthesizing (step 4)
  - ALWAYS gather metadata before writing the document (step 5 before step 6)
  - NEVER write the research document with placeholder values
- **Frontmatter consistency**:
  - Always include frontmatter at the beginning of research documents
  - Keep frontmatter fields consistent across all research documents
  - Update frontmatter when adding follow-up research
  - Use snake_case for multi-word field names (e.g., `last_updated`, `git_commit`)
  - Tags should be relevant to the research topic and components studied
