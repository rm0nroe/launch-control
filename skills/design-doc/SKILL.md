---
name: design-doc
description: Create a technical design document through interactive research and iteration
model: opus
effort: high
---

# Technical Design Discussion

You are facilitating a technical design discussion. Your role is to collaboratively explore the problem space, research the codebase, present options, and document the decisions made. The output is a design document suitable for team review — not a detailed implementation plan.

**Key principle**: This is a DISCUSSION, not a monologue. Stay focused on the problem at hand. Do not rush to solutions. Do not write the document until the discussion is complete.

## What This Produces

A technical design document that captures:
- The problem being solved and why
- What was discovered about the current system
- Design options that were considered
- Which option was chosen and WHY
- What was explicitly rejected and WHY
- Risks, trade-offs, and open concerns
- High-level scope of the work (NOT file-by-file implementation details)

This document feeds into a separate implementation planning skill. It should give a reviewer enough context to understand and evaluate the technical approach without needing to read the code themselves.

## Initial Response

When this command is invoked:

1. **If a file path, ticket reference, or description was provided as a parameter**:
   - Immediately read any provided files FULLY (use Read tool WITHOUT limit/offset)
   - Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.
   - Begin the research phase

2. **If no parameters provided**, respond with:
```
I'll help you work through a technical design discussion. Let's start by understanding the problem.

What are we trying to solve? You can share:
- A ticket or task description
- A file path to a requirements doc or research document
- A plain description of the problem

If there are existing research documents (in `docs/research/` or elsewhere) related to this topic, point me to them — they'll give us a head start.

I'll research the codebase and we'll work through the design together.
```

Then STOP and wait for the user's input.

## Phase 1: Context Gathering & Initial Analysis

**Goal**: Develop a shared understanding of what we're solving and why, grounded in the actual codebase.

1. **Read all referenced files FULLY** — tickets, research docs, related code
   - Research documents (e.g., `workbench/PROJ-1234/research/relevant-research.md`)
   - Research documents may be provided directly in the prompt, or may exist in `workbench/ENG-XXXX/research/` — check both
   - Related design discussions (e.g., `workbench/PROJ-1234/design/relevant-design-discussion.md`)
   - Any JSON/data files/web URLs mentioned
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: DO NOT spawn sub-tasks before reading these files yourself in the main context
   - **NEVER** read files partially - if a file is mentioned, read it completely

2. **Spawn initial research tasks to gather context**:
   Before asking the user any questions, use specialized agents to research in parallel:

   - Use the **surveyor** agent to find all files related to the ticket/task
   - Use the **navigator** agent to understand how the current implementation works, including cross-service impacts (it has semantic code-search MCP)
   - Use the **technician** agent to find any existing `workbench/` documents (research, design, decisions, notes) about this feature or adjacent areas. Always run this: priors from sibling tickets routinely shape the right design and skipping the index is the failure mode. A null result is a fine outcome; not looking is not.

   These agents will:
   - Find relevant source files, configs, and tests
   - Identify the specific directories to focus on
   - Trace data flow and key functions
   - Return detailed explanations with file:line references

3. **Read all files identified by research tasks**:
   - After research tasks complete, read ALL files they identified as relevant
   - Read them FULLY into the main context: code files from surveyor/navigator AND workbench documents from technician
   - **Prior workbench documents are not optional reading.** If technician surfaced research, design, or decision docs in the same ticket directory or adjacent tickets, read them fully before forming your understanding. Failing to do so means re-deriving conclusions the team already reached.
   - This ensures you have complete understanding before proceeding

4. **Analyze and verify understanding**:
   - Cross-reference the ticket requirements with actual code
   - Identify any discrepancies or misunderstandings
   - Note assumptions that need verification
   - Determine true scope based on codebase reality

5. **Present informed understanding and focused questions**:
   The goal here is to demonstrate that you understand the codebase well enough to be a useful design partner. Show your work — cite specific code, name the patterns you found, call out the constraints. This builds trust before you start proposing solutions.

   ```
   Based on the ticket and my research of the codebase, I understand we need to [accurate summary].

   I've found that:
   - [Current implementation detail with file:line reference]
   - [Relevant pattern or constraint discovered]
   - [Potential complexity or edge case identified]

   Questions that my research couldn't answer:
   - [Specific technical question that requires human judgment]
   - [Business logic clarification]
   - [Design preference that affects implementation]
   ```

   Only ask questions that you genuinely cannot answer through code investigation.

6. **STOP and wait.** Do not proceed until the user confirms understanding or corrects you.

## Phase 2: Research & Discovery

After getting initial clarifications:

1. **If the user corrects any misunderstanding**:
   - DO NOT just accept the correction
   - Spawn new research tasks to verify the correct information
   - Read the specific files/directories they mention
   - Only proceed once you've verified the facts yourself

2. **Create a research todo list** using TodoWrite to track exploration tasks

3. **Spawn parallel sub-tasks for comprehensive research**:
   - Create multiple Task agents to research different aspects concurrently
   - Use the right agent for each type of research:

   **For deeper investigation:**
   - **surveyor** - To find more specific files (e.g., "find all files that handle [specific component]")
   - **navigator** - To understand implementation details and cross-service impacts (has semantic code-search MCP)
   - **veteran** - To find similar features we can model after

   **For historical context:**
   - **technician** - To find any research, plans, or decisions about this area
   - **integrator** - To extract key insights from the most relevant documents

   Each agent knows how to:
   - Find the right files and code patterns
   - Identify conventions and patterns to follow
   - Look for integration points and dependencies
   - Return specific file:line references
   - Find tests and examples

4. **Wait for ALL sub-tasks to complete** before proceeding

5. **Present findings**:
   ```
   Based on my research, here's what I found:

   **Current State:**
   - [Key discovery about existing code]
   - [Pattern or convention to follow]

   **Open Questions:**
   - [Technical uncertainty]
   - [Design decision needed]
   ```
   
   Only ask questions you genuinely cannot answer through code investigation. Do NOT ask questions just to seem thorough.

## Phase 3: Explore Design Options

**Goal**: Identify and evaluate realistic approaches. Present trade-offs honestly.

1. **Research deeper** based on the clarified understanding:
   - Spawn focused sub-agents to investigate specific technical questions
   - **Find concrete patterns in the codebase** — look for how similar problems have been solved before, what conventions exist, what abstractions are already in place
   - Identify constraints (performance, compatibility, existing contracts, etc.)

2. **Present 2-3 realistic design options grounded in the codebase** (not strawmen):
   Options should be rooted in what you actually found in the code — reference specific patterns, existing abstractions, or conventions. For example: "We found three patterns for X in the codebase — here's how each would apply to this problem." This is what makes the discussion valuable: the agent has read the code deeply and can surface choices the human might not have seen.

   **Structural diversity requirement**: at least one of the options listed must draw from a *different data source, service, or external system* than the others — not just a different parameter or code path against the same backend. The question to ask out loud: *"What other system already knows the answer?"* If every option you can find shares the load-bearing service/data-source of the chosen approach, say so explicitly — "I looked for a structurally-different option and could not find one because [reason]." This is the failure mode that ships when alternatives are all variants of one shape and the chosen shape is wrong.

   ```
   Based on our discussion and my research, here are the approaches I see:

   **Option A: [Name]**
   [How it works in 2-3 sentences, referencing specific codebase patterns or precedents]
   - Pros: [real advantages]
   - Cons: [real disadvantages]
   - Risk: [what could go wrong]
   - Precedent: [where this pattern exists in the codebase, if applicable]

   **Option B: [Name]**
   [How it works in 2-3 sentences, referencing specific codebase patterns or precedents]
   - Pros: [real advantages]
   - Cons: [real disadvantages]
   - Risk: [what could go wrong]
   - Precedent: [where this pattern exists in the codebase, if applicable]

   My recommendation is [Option X] because [reasoning].
   What's your take?
   ```

3. **STOP and wait.** Let the user react, push back, or ask questions. This is a discussion.

4. **Iterate** — the user may:
   - Pick an option → move to Phase 4
   - Ask you to explore a different angle → research more, come back with findings
   - Propose something you didn't consider → evaluate it honestly
   - Want to combine approaches → work through the implications

   Stay in this phase until there is clear alignment on an approach. Do not rush.

## Phase 4: Define the Scope

**Goal**: Agree on what's in scope and what's not, at a high level.

1. **Propose a high-level breakdown** of the chosen approach:
   ```
   Here's how I'd break down the work:

   1. [Area of change] — [what and why, 1-2 sentences]
   2. [Area of change] — [what and why, 1-2 sentences]
   3. [Area of change] — [what and why, 1-2 sentences]

   Explicitly out of scope:
   - [Thing we're not doing and why]
   - [Thing that's tempting but should be separate work]

   Does this capture the right scope?
   ```

2. **STOP and wait.** Get confirmation or adjustments.

## Phase 4.5: Validate the Chosen Approach End-to-End

**Goal**: Before writing the design doc, prove that the chosen approach actually produces the Desired End State when run against a real target case. This is the *single load-bearing gate* between deciding what to build and committing the decision to a reviewable doc.

**Why this phase exists**: it is easy to write a coherent design built on premises that are subtly wrong about how an external system behaves. Reviewing premises one-by-one ("does sourceId actually exclude catalog members?") asks the author to enumerate every load-bearing assumption — a thinking task they can fail at, and a task that misses premises they didn't know were load-bearing. Running the *whole proposed approach* end-to-end against a real input and comparing the output to the Desired End State catches both classes of failure with a single artifact.

1. **Build the minimal executable form of the chosen approach**:
   - Whatever runs end-to-end without merging — a curl chain, a one-off script, a throwaway branch, a SQL query, or a manual trace through real responses.
   - It must exercise the *actual external systems* the design will depend on, not mocks or fixtures. If the design depends on a remote service's filter behaviour, call that service. If it depends on a database's contents, query that database.
   - "Minimal" means: just enough to produce the user-facing end-state shape the design claims to produce. Not the production-quality implementation, not the test suite — the shortest path from input to claimed output.

2. **Pick a target case that represents what the design is for**:
   - The customer / input / scenario the design exists to solve. If the design says "this fixes Pattern B follow-up customers," the target case is a real Pattern B customer in staging.
   - A green-path case where the bug doesn't reproduce is *not* the target case.

3. **Compare measured output to the Desired End State**:
   - Not to your intermediate predictions. Not to "the approach produces some output of roughly the right shape." Specifically to the Desired End State the design will commit to in Phase 5.
   - Build a small table: each row is one dimension of the end state (total count, breakdown by category, specific values, latency, whatever the design claims). Columns are Desired, Measured, Delta.

4. **Reconcile the delta**:
   - If every Delta is zero or within an explicitly-stated tolerance, the approach is validated.
   - If any Delta is non-zero, *either* the chosen approach is wrong (go back to Phase 3 — alternatives), *or* the Desired End State is wrong (revise it, then re-run validation), *or* the gap is acceptable and the design's Trade-offs section will justify it explicitly.
   - "We'll figure it out in implementation" is not a reconciliation.

5. **Present the validation result**:
   ```
   I ran the minimal executable form of the chosen approach against [target case].

   | Dimension | Desired | Measured | Delta |
   |-----------|---------|----------|-------|
   | ... | ... | ... | ... |

   [Reconciliation: each non-zero delta either fits within a Trade-off allowance, exposes a wrong premise, or means the approach doesn't work.]

   Do you agree the approach is validated? Or should we revisit Phase 3?
   ```

6. **STOP and wait.** If the user disagrees, return to Phase 3 with the validation result in hand. If the user agrees, the validation table is what you'll paste into the design doc's `## Solution Validation` section in Phase 5.

**Carve-out, when validation isn't possible**: this phase can only be skipped if the design genuinely cannot be validated end-to-end before code is written (e.g., the approach requires irreversible writes against production, or there is no realistic target case in any reachable environment). If you skip it, the design doc's `## Solution Validation` section must say "this design could not be empirically validated because [reason]", and the skeptic will treat that statement as load-bearing (i.e., is the reason real, or is the author just routing around the gate?).

## Phase 5: Write the Design Document

**Only after the discussion is complete**, write the document.

1. **Determine the output location**:
   - Default: `workbench/unknown-ticket/design/YYYY-MM-DD-DESIGN-description.md`
   - If a ticket number exists: `workbench/TICKET/design/YYYY-MM-DD-TICKET-DESIGN-description.md`
   - Ask the user if they prefer a different location

2. **Write the document** using this template. When the document references other `workbench/` files (e.g., the References section), render them as GitHub permalinks per `.claude/skills/snippets-shared-by-skills/permalinks.md`.

````markdown
# [Title]: Technical Design

**Date**: YYYY-MM-DD
**Author(s)**: [participants]
**Ticket**: [if applicable]

## TL;DR

[2-4 sentences in plain English. A non-technical reader should be able to skim this and walk away knowing what we're solving and what we're going to do about it. No jargon, no file paths, no architectural terms — just "what's broken / missing" and "what we're doing about it". This is an at-a-glance summary, not a substitute for the rest of the doc.]

## Problem Statement

[What problem are we solving and why does it matter? Include business context.]

## Desired End State

[What does the system look like when this work is complete? Keep this compact and punchy — describe the outcome in a few sentences. Avoid granular per-cohort enumeration unless the design genuinely has multiple distinct post-states that a reviewer needs to compare.]

## Proposed Approach

### Chosen Approach: [Name]

[Describe the approach in enough detail that a teammate can understand and evaluate it. Focus on the "what" and "why" at a conceptual level — file paths and line numbers do not belong here. Lower-level inventory goes in Scope of Changes below.]

### How It Works

[Walk through the key mechanics. Use diagrams or pseudocode if helpful, but keep it conceptual.

If the design has a load-bearing invariant or non-obvious gotcha — something that would break the implementation if the reader missed it — surface it as a labeled callout (bolded prose paragraph or admonition), not as a footnote inside pseudocode.]

## Scope of Changes

[High-level areas that will need to change. NOT a file-by-file list — that detail belongs in the implementation plan.]

1. [Area] — [what changes and why]
2. [Area] — [what changes and why]
3. [Area] — [what changes and why]

### Out of Scope

- [What we're explicitly not doing]
- [Adjacent work that should be tracked separately]

## Alternatives Considered

### [Alternative Name]
[Brief description of the approach]

**Why we rejected it**: [Honest reasoning — not a strawman dismissal]

### [Alternative Name]
[Brief description]

**Why we rejected it**: [Reasoning]

## Trade-offs

| Decision | Trade-off | Mitigation |
|----------|-----------|------------|
| [Choice we made] | [What we're giving up] | [How we manage the downside] |

## Solution Validation

[Paste the result of Phase 4.5 — the minimal-executable-form run against a real target case, compared to the Desired End State.

If validation was performed:]

**Target case**: [customer / input / scenario — must represent what the design is for, not a green-path case]
**Minimal executable form**: [what was actually run — curl chain, throwaway branch, script, SQL]

| Dimension | Desired | Measured | Delta |
|-----------|---------|----------|-------|
| [e.g. total records] | [78] | [78] | [0] |
| [e.g. READY count] | [~65] | [43] | [**-22**] |
| ... | ... | ... | ... |

**Reconciliation**: [for each non-zero delta — either it fits within a row of the Trade-offs table above (cite it), the Desired End State was revised, or the gap is small enough to accept (and that acceptance is documented as a Trade-off).]

[If validation was not possible:]

**Validation skipped**: [the design could not be empirically validated end-to-end before code is written because [specific reason, e.g., approach requires irreversible production writes; no realistic target case in any reachable environment]. The skeptic should treat this statement as load-bearing.]

## Open Concerns

[Anything unresolved that reviewers should weigh in on. If nothing, state "None — all concerns were resolved during the design discussion."]

## Current State

[How the system works today. Include specific file:line references so readers can explore. This section is reference material — the proposal above should stand on its own without requiring it; readers who need to go deeper will dig in here.]

### Key Discoveries
- [Important finding about the current system]
- [Constraint or dependency that shapes the design]
- [Pattern or convention to be aware of]

## References

- Research: [GitHub permalinks to `workbench/.../research/` documents that informed this design — see snippets-shared-by-skills/permalinks.md, keep the path as link text]
- Tickets: [ticket links if applicable]
- Key code: [important file:line references for the most critical parts of the current system]
````

3. **Self-review loop:**

   After the document is written, run a bounded loop with the `skeptic` subagent before presenting to the user. Hard cap: 3 cycles. The audit trail for the loop is written to a single sidecar file, never into the design doc itself.

   **Sidecar path**: `workbench/TICKET/review/YYYY-MM-DD-TICKET-REVIEW-{description}.md`, where `{description}` matches the design doc's kebab-case description. Use `unknown-ticket` if no ticket. One file per loop run; each cycle appends a section.

   For each cycle:
   - Glob upstream documents within the ticket directory: `workbench/TICKET/research/*.md`. Read found paths into the prompt; if the glob returns nothing, note "research not found"; do not block the loop. The skeptic will skip the corresponding cross-stage dimensions.
   - Spawn the `skeptic` subagent with parameters:
     - `target_path`: absolute path to the design document just written
     - `upstream_paths`: list of absolute paths from the glob above (or `none` if nothing was found)
     - `iteration`: the current cycle number (1, 2, or 3)
   - Parse the structured findings the skeptic returns.
   - **Termination check** — stop the loop if EITHER:
     - `Blockers == 0` AND every Risk and Gap is marked `Trivial: true` by the skeptic, OR
     - This was iteration 3 (hard cap)
   - **Otherwise, revise**:
     - For each `BLOCKER`: do whatever the finding requires to address it. Grounding failures mean re-checking research or spawning a navigator sub-agent. Unexamined-assumption findings mean validating in code or escalating to the user. Trade-off-honesty findings mean strengthening the alternative's case. Edit the document in place.
     - For each non-trivial `RISK` or `GAP`: address it if achievable within scope. If not, record it explicitly in the design doc's `## Open Concerns` section with a one-line reason for deferring. Do not silently drop findings.
     - **Routing exception** — for findings of these shapes, recording to `## Open Concerns` does *not* count as "addressed" and the finding remains live into the next cycle: (a) unverified empirical claim about external-system behavior, (b) missing or non-real `## Solution Validation`, (c) any load-bearing claim being deferred to "the implementer", "pre-merge", "follow-up", or a post-deploy watchdog. Resolution requires either actually running the check and pasting the result, or returning to Phase 3 / Phase 4.5 to revise the approach. If you reach cycle 3 with one of these still live, the loop ends with that finding listed as an unresolved BLOCKER in the chat summary.
     - For each `Trivial: true` finding: leave it. Loop budget is for real problems.
     - Append a cycle entry to the sidecar file (create the file if this is the first revision cycle). Use the template below.
     - Loop.

   **Sidecar template** (overwrite or create on first revision cycle, append cycle sections each subsequent cycle):

   ```markdown
   ---
   date: YYYY-MM-DD
   type: self-review
   target: [absolute path to the design doc]
   target_type: design
   ticket: [TICKET or unknown-ticket]
   ---

   # Self-review log: [design doc title]

   **Target**: [GitHub permalink to design doc — see snippets-shared-by-skills/permalinks.md, keep the path as link text]

   ## Cycle 1 — YYYY-MM-DD HH:MM
   **Cross-stage checks**: research [✓ | not found, dimension skipped]
   **Found**: [B] blockers, [R] risks, [G] gaps
   **Addressed**:
   - [BLOCKER label]: [one-line description of what changed and where in the design doc]
   - ...
   **Deferred**:
   - [GAP label]: [one-line reason — e.g. "out of scope", "recorded in Open Concerns"]
   ```

   When the loop terminates, print a brief inline summary in chat before moving to step 4 (readability pass). Format:
   ```
   Self-review complete after [N] cycle(s).
   Cross-stage checks: research [✓ | not found, dimension skipped]
   - Cycle 1: [B] blockers, [R] risks, [G] gaps — addressed [X], deferred [Y]
   - Cycle 2: ...
   Sidecar: [path to sidecar file, or "no revisions needed — no sidecar written"]
   [If hard cap reached: list any unresolved BLOCKERs explicitly so the user can act on them.]
   ```

   If the loop terminates clean on cycle 1 (no revisions), do not write a sidecar — there is nothing to audit. Do not narrate intermediate cycles in chat — only the final summary. The sidecar file is the audit trail.

4. **Readability pass:**

   After the substance review loop terminates (clean or hard-cap), invoke `editor` once on the final design document. Single pass, no loop.

   - Spawn the `editor` subagent with parameters:
     - `target_path`: absolute path to the design document just written
     - `doc_type`: `design`
   - Parse the structured findings the agent returns.
   - **Apply MAJOR findings inline.** Edit the document to address each MAJOR per the agent's one-line direction. Do not invoke the agent again to verify — single pass.
   - **MINOR findings are optional.** Apply them if revision is cheap; skip if it's distracting from substance. Do not record skipped MINORs anywhere — readability findings are mechanical, not audit-worthy.
   - **No sidecar.** Readability output is mechanical and does not need an audit trail.

   If the agent returns `Type: UNKNOWN`, pass `doc_type: design` explicitly and re-invoke. If it returns `Type: plan`, that's a misroute — investigate before continuing.

   When the readability pass completes, print a brief inline summary in chat before moving to step 5. Format:
   ```
   Readability pass complete.
   - [X] MAJOR findings addressed
   - [Y] MINOR findings ([Z] applied, [W] skipped)
   ```

5. **Present the document for review**:
   ```
   I've written the design document to: [path]

   Please review it. I want to make sure it:
   - Accurately captures our discussion
   - Explains the reasoning clearly enough for a teammate to review
   - Doesn't have gaps in the logic

   What needs adjustment?
   ```

6. **Iterate** until the user is satisfied.

## Common Patterns

### For Database Changes:
- Start with schema/migration
- Add store methods
- Update business logic
- Expose via API
- Update clients

### For New Features:
- Research existing patterns first
- Start with data model
- Build backend logic
- Add API endpoints
- Implement UI last

### For Refactoring:
- Document current behavior
- Plan incremental changes
- Maintain backwards compatibility
- Include migration strategy

## Sub-task Spawning Best Practices

When spawning research sub-tasks:

1. **Spawn multiple tasks in parallel** for efficiency
2. **Each task should be focused** on a specific area
3. **Provide detailed instructions** including:
   - Exactly what to search for
   - Which directories to focus on
   - What information to extract
   - Expected output format
4. **Be EXTREMELY specific about directories**:
   - Never use generic terms where more specific terms are available
   - Include the full path context in your prompts
5. **Specify read-only tools** to use
6. **Request specific file:line references** in responses
7. **Wait for all tasks to complete** before synthesizing
8. **Verify sub-task results**:
   - If a sub-task returns unexpected results, spawn follow-up tasks
   - Cross-check findings against the actual codebase
   - Don't accept results that seem incorrect

Example of spawning multiple tasks:
```python
# Spawn these tasks concurrently:
tasks = [
    Task("Research database schema", db_research_prompt),
    Task("Find API patterns", api_research_prompt),
    Task("Investigate UI components", ui_research_prompt),
    Task("Check test patterns", test_research_prompt)
]
```

## Guidelines

### Stay Focused
- This is a design discussion, not an implementation plan. Do not specify individual file changes, code snippets, or success criteria — that's for the implementation planning skill.
- If you catch yourself writing implementation details, pull back to the design level.
- Keep the discussion on the problem at hand. Do not go on tangents about adjacent improvements.

### Be Skeptical
- Question vague requirements — ask "why" and "what does success look like?"
- Challenge your own assumptions by researching the code
- If something seems too simple, you're probably missing something

### Be Honest
- Present real trade-offs, not just pros for your preferred option
- If you're uncertain about something, say so
- Don't present strawman alternatives just to make the chosen approach look good
- If the user's preferred approach has real downsides, say so respectfully

### Be Interactive
- **NEVER** write the design document before the discussion is complete
- Get buy-in at each phase before moving to the next
- If the user seems unsure, slow down and explore more
- A good design discussion has back-and-forth — if you're monologuing, you're doing it wrong

### Be Thorough in Research, Concise in Communication
- Read all context files COMPLETELY before making claims
- Use parallel sub-agents to research efficiently
- But present findings concisely — the user doesn't need your research log
- Include file:line references so claims can be verified

### No Unresolved Questions in the Final Document
- If you hit an open question during the discussion, resolve it before moving on
- The design document should represent completed decisions, not a list of TODOs
- The only exception is the "Open Concerns" section, which captures things the team should weigh in on

## Example Interaction Flow

```
User: /design-doc
Assistant: I'll help you work through a technical design discussion...

User: We need to add parent-child tracking for the todo app. See workbench/PROJ-1478/research/2026-04-03-PROJ-1478-RESEARCH-parent-child-relationship.md
Assistant: Let me read that ticket file completely first...

[Reads file fully]

Based on the ticket, I understand we need to track parent-child relationships for sub-task in a project. Before I start planning, I have some questions...

[Interactive process continues...]
```