---
name: design-outline
description: Create a high-level structure outline with vertical phases and test checkpoints
model: sonnet
effort: medium
---

# Structure Outline

You are tasked with creating a high-level structure outline — a phase breakdown that defines HOW we get from the current state to the desired end state. This is NOT a detailed implementation plan. Think of it as C header files: signatures and types, not implementation. Roughly 2 pages, not 8.

**Key principle**: Phases must be VERTICAL slices, not horizontal layers. Vertical = DB migration + service layer + API + UI for one feature slice. Horizontal = all DB changes, then all service changes, then all API changes. Vertical gives you something testable at each checkpoint. Horizontal gives you 1,200 lines of untestable code.

## What This Produces

A concise structure outline that captures:
- A brief summary of what we're building and the chosen approach (from the design discussion)
- Vertical phases, each with a clear deliverable
- Automated and manual verification steps per phase
- Enough detail for a human to catch structural problems — wrong ordering, missing phases, bad decomposition

This document feeds into a separate detailed planning step. It should NOT contain code snippets, specific file-level changes, or implementation details.

## Initial Response

When this command is invoked:

1. **If file paths or a task description were provided as parameters**:
   - Immediately read any provided files FULLY (use Read tool WITHOUT limit/offset)
   - Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.
   - Begin the research phase

2. **If no parameters provided**, respond with:
```
I'll help you create a structure outline — a high-level phase breakdown with test checkpoints.

To do this well, I need:
1. The approved design discussion document (e.g., `workbench/TICKET/design/...`)
2. The research document(s) that informed the design
3. The ticket or task description (can be a file path or pasted directly)

The design discussion is the most important input — it contains the chosen approach I'll be structuring into phases.
```

Then STOP and wait for the user's input.

## Process Steps

### Step 1: Context Gathering & Initial Analysis

1. **Read all mentioned files immediately and FULLY**:
   - Design discussion documents (e.g., `workbench/TICKET/design/...`)
   - Research documents (e.g., `workbench/unknown-ticket/research/...` or `workbench/TICKET/research/...`)
   - Ticket files or any other referenced materials
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: DO NOT spawn sub-tasks before reading these files yourself in the main context
   - **NEVER** read files partially - if a file is mentioned, read it completely

2. **Spawn targeted research tasks if needed**:
   Only if the design discussion or research documents leave gaps in understanding, use specialized agents to fill them:

   - Use the **surveyor** agent to find files related to specific areas
   - Use the **navigator** agent to understand implementation details, including cross-system impacts (it has semantic code-search MCP)
   - Use the **veteran** agent to find similar patterns to model after
   - If relevant, use the **technician** agent to find related decisions or plans

3. **Read all files identified by research tasks**:
   - After research tasks complete, read ALL files they identified as relevant
   - Read them FULLY into the main context

4. **Verify understanding against the design discussion**:
   - Confirm you understand the chosen approach
   - Confirm you understand the current state and desired end state
   - Identify the scope boundaries (what's in, what's out)
   - Note any ordering constraints or dependencies between areas of change

5. **Present your understanding**:
   ```
   Based on the design discussion and my research, I understand:

   **Chosen approach**: [summary from design discussion]
   **Current state**: [brief summary]
   **Desired end state**: [brief summary]
   **Scope**: [what's in and out]

   Before I propose the phase breakdown, let me confirm:
   - [Any clarifying question about ordering or dependencies]
   - [Any question about what constitutes a testable checkpoint]
   ```

   Only ask questions you genuinely cannot answer from the provided documents.

6. **STOP and wait.** Do not proceed until the user confirms or corrects.

### Step 2: Propose the Structure Outline

Once understanding is confirmed:

1. **Present the phase breakdown for discussion**:
   ```
   Here's my proposed structure:

   **Phase 1: [Descriptive Name]**
   [1-2 sentences: what this phase delivers as a vertical slice]
   - Automated: [what commands verify it]
   - Manual: [what a human checks]

   **Phase 2: [Descriptive Name]**
   [1-2 sentences: what this phase delivers as a vertical slice]
   - Automated: [what commands verify it]
   - Manual: [what a human checks]

   **Phase 3: [Descriptive Name]**
   [1-2 sentences: what this phase delivers as a vertical slice]
   - Automated: [what commands verify it]
   - Manual: [what a human checks]

   Does this phasing make sense? Is the ordering right? Should any phases be split or combined?
   ```

2. **STOP and wait.** This is the highest-leverage review point for structure. Let the user react.

3. **Iterate** — the user may:
   - Approve → move to Step 3
   - Reorder phases → adjust and re-present
   - Split or combine phases → adjust and re-present
   - Question the vertical slicing → explain or adjust
   - Add missing verification steps → incorporate them

   Stay in this step until there is clear alignment on the phase structure.

### Step 3: Write the Structure Outline Document

After the structure is approved:

1. **Determine the output location**:
   - Default: `workbench/unknown-ticket/outline/YYYY-MM-DD-OUTLINE-description.md`
   - If a ticket number exists: `workbench/TICKET/outline/YYYY-MM-DD-TICKET-OUTLINE-description.md`
   - Ask the user if they prefer a different location

2. **Write the document** using this template. When the document references other `workbench/` files (e.g., the References section), render them as GitHub permalinks per `.claude/skills/snippets-shared-by-skills/permalinks.md`.

````markdown
# [Feature/Task Name]: Structure Outline

**Date**: YYYY-MM-DD
**Ticket**: [if applicable]

## TL;DR

[2-4 sentences in plain English. A non-technical reader should be able to skim this and walk away knowing what we're building and roughly how the work is shaped. No jargon, no file paths, no phase numbers — just "what's changing" and "what the rollout looks like at a glance". This is a skim-level summary, not a substitute for the rest of the doc.]

## Summary

[2-3 sentences: what we're building, the chosen approach from the design discussion, and why. More technical than the TL;DR — this is for the reader who's about to read the whole outline.]

## Current State → Desired End State

**Current**: [1-2 sentences]
**Desired**: [1-2 sentences]

## Phase Breakdown

### Phase 1: [Descriptive Name]

**Delivers**: [What is testable/usable after this phase completes — one sentence]

**Areas of change**:
- [Area/component] — [what changes, 1 sentence]
- [Area/component] — [what changes, 1 sentence]

**Verification**:
- Automated:
  - [ ] [Command or check]
  - [ ] [Command or check]
- Manual:
  - [ ] [What a human verifies]

---

### Phase 2: [Descriptive Name]

**Delivers**: [What is testable/usable after this phase completes]

**Areas of change**:
- [Area/component] — [what changes, 1 sentence]
- [Area/component] — [what changes, 1 sentence]

**Verification**:
- Automated:
  - [ ] [Command or check]
  - [ ] [Command or check]
- Manual:
  - [ ] [What a human verifies]

---

[Continue for each phase...]

## Out of Scope

- [Explicitly not included]
- [Adjacent work that should be tracked separately]

## Dependencies & Ordering Notes

[Any constraints on phase ordering, external dependencies, or blockers]

## References

- Design discussion: [GitHub permalink to design document — see snippets-shared-by-skills/permalinks.md, keep the path as link text]
- Research: [GitHub permalinks to research documents]
- Ticket: [ticket reference if applicable]
````

3. **Self-review loop:**

   After the document is written, run a bounded loop with the `skeptic` subagent before presenting to the user. Hard cap: 3 cycles. The audit trail is written to a single sidecar file, never into the outline doc itself.

   **Sidecar path**: `workbench/TICKET/review/YYYY-MM-DD-TICKET-REVIEW-{description}.md`, where `{description}` matches the outline's kebab-case description. Use `unknown-ticket` if no ticket. One file per loop run; each cycle appends a section.

   For each cycle:
   - Glob upstream documents within the ticket directory: `workbench/TICKET/design/*.md` and `workbench/TICKET/research/*.md`. Read found paths into the prompt; if either glob returns nothing, note it (e.g. "design not found"). Do not block the loop on missing upstream; the skeptic will skip the corresponding cross-stage dimensions.
   - Spawn the `skeptic` subagent with parameters:
     - `target_path`: absolute path to the outline document just written
     - `upstream_paths`: list of absolute paths from the globs above (or `none` if nothing was found)
     - `iteration`: the current cycle number (1, 2, or 3)
   - Parse the structured findings the skeptic returns.
   - **Termination check** — stop the loop if EITHER:
     - `Blockers == 0` AND every Risk and Gap is marked `Trivial: true` by the skeptic, OR
     - This was iteration 3 (hard cap)
   - **Otherwise, revise**:
     - For each `BLOCKER`: do whatever the finding requires to address it. Vertical-slice violations mean restructuring the phase. Phase-ordering issues mean reordering and updating "Dependencies & Ordering Notes". Completeness gaps against the design mean adding missing phases. Verification-realism failures mean rewriting the Automated/Manual checks. Edit the document in place.
     - For each non-trivial `RISK` or `GAP`: address it if achievable within scope. If not, record it in the sidecar's "Deferred" list for this cycle with a one-line reason. (The outline body has no Open Concerns section — deferrals live only in the sidecar.) Do not silently drop findings.
     - **Routing exception** — for findings of these shapes, recording to the sidecar's "Deferred" list does *not* count as "addressed" and the finding remains live into the next cycle: (a) the upstream design's `## Solution Validation` is missing or non-real (escalate as a cross-stage failure rather than deferring the outline-level finding), (b) any load-bearing claim being deferred to "the implementer", "pre-merge", or "follow-up". Resolution requires going back to fix the upstream design or running the verification yourself and updating the outline. If you reach cycle 3 with one of these still live, the loop ends with that finding listed as an unresolved BLOCKER in the chat summary.
     - For each `Trivial: true` finding: leave it.
     - Append a cycle entry to the sidecar file (create the file if this is the first revision cycle). Use the template below.
     - Loop.

   **Sidecar template** (create on first revision cycle, append cycle sections each subsequent cycle):

   ```markdown
   ---
   date: YYYY-MM-DD
   type: self-review
   target: [absolute path to the outline doc]
   target_type: outline
   ticket: [TICKET or unknown-ticket]
   ---

   # Self-review log: [outline doc title]

   **Target**: [GitHub permalink to outline doc — see snippets-shared-by-skills/permalinks.md, keep the path as link text]

   ## Cycle 1 — YYYY-MM-DD HH:MM
   **Cross-stage checks**: design [✓ | not found, dimension skipped], research [✓ | not found, dimension skipped]
   **Found**: [B] blockers, [R] risks, [G] gaps
   **Addressed**:
   - [BLOCKER label]: [one-line description of what changed and where in the outline]
   - ...
   **Deferred**:
   - [GAP label]: [one-line reason]
   ```

   When the loop terminates, print a brief inline summary in chat before moving to step 4 (readability pass). Format:
   ```
   Self-review complete after [N] cycle(s).
   Cross-stage checks: design [✓ | not found, dimension skipped], research [✓ | not found, dimension skipped]
   - Cycle 1: [B] blockers, [R] risks, [G] gaps — addressed [X], deferred [Y]
   - Cycle 2: ...
   Sidecar: [path to sidecar file, or "no revisions needed — no sidecar written"]
   [If hard cap reached: list any unresolved BLOCKERs explicitly so the user can act on them.]
   ```

   If the loop terminates clean on cycle 1 (no revisions), do not write a sidecar — there is nothing to audit. Do not narrate intermediate cycles in chat — only the final summary. The sidecar file is the audit trail.

4. **Readability pass:**

   After the substance review loop terminates (clean or hard-cap), invoke `editor` once on the final outline document. Single pass, no loop.

   - Spawn the `editor` subagent with parameters:
     - `target_path`: absolute path to the outline document just written
     - `doc_type`: `outline`
   - Parse the structured findings the agent returns.
   - **Apply MAJOR findings inline.** Edit the document to address each MAJOR per the agent's one-line direction. Do not invoke the agent again to verify — single pass.
   - **MINOR findings are optional.** Apply them if revision is cheap; skip if it's distracting from substance. Do not record skipped MINORs anywhere — readability findings are mechanical, not audit-worthy.
   - **No sidecar.** Readability output is mechanical and does not need an audit trail.

   If the agent returns `Type: UNKNOWN`, pass `doc_type: outline` explicitly and re-invoke. If it returns `Type: plan`, that's a misroute — investigate before continuing.

   When the readability pass completes, print a brief inline summary in chat before moving to step 5. Format:
   ```
   Readability pass complete.
   - [X] MAJOR findings addressed
   - [Y] MINOR findings ([Z] applied, [W] skipped)
   ```

5. **Present the document for review**:
   ```
   I've written the structure outline to: [path]

   Please review it. This is the blueprint that a detailed plan will be built from, so I want to make sure:
   - The phases are in the right order
   - Each phase is a proper vertical slice with something testable at the end
   - The verification steps will actually catch problems
   - Nothing is missing or out of place

   What needs adjustment?
   ```

6. **Iterate** until the user is satisfied.

## Guidelines

### Stay at the Right Altitude
- This is a STRUCTURE outline, not a detailed plan. Do not include code snippets, specific file changes, or line-level details.
- Each phase should describe WHAT it delivers, not HOW to implement it.
- If you catch yourself writing implementation details, pull back to the structural level.
- Think: "Is this enough for someone to catch a bad decomposition?" — not "Is this enough for someone to write the code?"

### Vertical Slices Are Non-Negotiable
- Every phase must produce something testable end-to-end.
- If a phase only touches one layer (e.g., "all database migrations"), it's horizontal — restructure it.
- A good test: after each phase, could someone use/test the feature slice it delivers?

### Be Interactive
- Present the phase breakdown BEFORE writing the document.
- Get buy-in on the structure before committing it to a file.
- If the user pushes back, adjust — don't defend.

### Be Thorough in Research, Concise in Output
- Read all input documents COMPLETELY before proposing structure.
- Use parallel sub-agents to fill knowledge gaps efficiently.
- But keep the outline concise — ~2 pages, not 8.

### No Open Questions in the Final Document
- If you hit an open question during discussion, resolve it before writing.
- The structure outline should represent completed structural decisions.

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

## Common Patterns

### For Database Changes:
- **Capability slice**: Let a user save and view one notification preference end to end.
- **Implementation steps inside the slice**: Add a backward-compatible migration, then the store method, business logic, API contract, and client control needed for that preference. Keep the old read path valid until the slice is verified.
- **Verification**: Run the migration forward and through rollback on a representative database, then change the preference through the client and read the stored value back through the API.

### For New Features:
- **Capability slice**: Let an administrator suspend one account and see its status.
- **Implementation steps inside the slice**: Research the existing pattern, add only the data model, backend logic, API endpoint, and UI needed for suspension, then defer other account actions to later slices.
- **Verification**: Suspend a fixture account through the UI, confirm the API and stored state agree, and verify the account can no longer use the restricted capability.

### For Refactoring:
- **Capability slice**: Move one checkout path to the new pricing service without changing its observable result.
- **Implementation steps inside the slice**: Capture current behavior, route that path through the replacement service and its API/client boundary, preserve backward compatibility, and state the migration and rollback strategy before moving another path.
- **Verification**: Run the same checkout cases before and after the slice, compare their user-visible output, and exercise the compatibility fallback.

## Example Interaction Flow

```
User: /design-outline workbench/PROJ-1478/design/2026-04-03-PROJ-1478-DESIGN-design.md workbench/PROJ-1478/research/2026-04-02-PROJ-1478-RESEARCH-data-model.md
Assistant: Let me read those files completely first...

[Reads files fully]

Based on the design discussion, I understand we chose [approach X] for [feature]. Before I propose phases, let me confirm...

[Interactive process continues until phases are agreed upon, then writes the document]
```
