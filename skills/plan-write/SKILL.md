---
name: plan-write
description: Create a detailed tactical implementation plan from an approved structure outline
model: opus
effort: medium
---

# Implementation Plan

You are tasked with creating a detailed tactical implementation plan. The design decisions and phase structure have ALREADY been made in earlier stages (design discussion and structure outline). Your job is to add implementation detail — specific file changes, actual code snippets, and verification steps — so that an execution agent can follow the plan without ambiguity.

**Key principle**: This plan is for the agent to execute, not for the human to deeply review. The human has already aligned on direction (design) and structure (outline). Include code snippets specific enough that "the dumbest model in the world is probably not going to screw this up."

## What This Produces

A detailed implementation plan that:
- Follows the approved phase structure from the structure outline (vertical slices)
- Specifies exact file changes with before/after code snippets
- Includes automated and manual verification steps per phase
- Is complete and actionable — no open questions, no ambiguity

This document feeds into the implementation stage. Each phase will be executed in a fresh context window with this plan as input.

## Initial Response

When this command is invoked:

1. **If file paths were provided as parameters**:
   - Immediately read any provided files FULLY (use Read tool WITHOUT limit/offset)
   - Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.
   - Begin the context gathering phase

2. **If no parameters provided**, respond with:
```
I'll help you create a detailed implementation plan. This builds on your approved design and structure outline.

I need:
1. The approved structure outline (e.g., `workbench/TICKET/outline/...`)
2. The design discussion document (e.g., `workbench/TICKET/design/...`)
3. The research document(s) (e.g., `workbench/TICKET/research/...`)
4. The ticket or task description (if not already referenced in the above)

The structure outline is the most important input — the plan will follow its phase breakdown.
```

Then STOP and wait for the user's input.

## Process Steps

### Step 1: Context Gathering

1. **Read all mentioned files immediately and FULLY**:
   - Structure outline (this is your blueprint — the phases are already decided)
   - Design discussion (this has the chosen approach and reasoning)
   - Research documents (these have the factual codebase context)
   - Ticket files or any other referenced materials
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: DO NOT spawn sub-tasks before reading these files yourself in the main context
   - **NEVER** read files partially — if a file is mentioned, read it completely

2. **Verify you have what you need**:
   - Confirm you have an approved structure outline with phases
   - Confirm you have a design discussion with the chosen approach
   - Confirm you have research with file paths and codebase context
   - If any of these are missing, ask the user before proceeding

3. **Present your understanding**:
   ```
   I've read the upstream documents. Here's what I'm working with:

   **Chosen approach**: [from design discussion]
   **Phases from outline**:
   1. [Phase name] — [what it delivers]
   2. [Phase name] — [what it delivers]
   ...

   I'll now research the specific files that need to change to build the detailed plan. Any corrections before I dive in?
   ```

4. **STOP and wait.** Do not proceed until the user confirms or corrects.

### Step 2: Deep File Research

This is where the plan command earns its keep. You need to read the actual source files that will be modified so you can write accurate code snippets.

1. **Spawn parallel sub-agents to research the files for each phase**:
   Use specialized agents to deeply read the files that will change:

   - Use the **surveyor** agent to find exact file paths for each area of change listed in the outline
   - Use the **navigator** agent to understand the current implementation of files that will be modified, including cross-system impacts (it has semantic code-search MCP)
   - Use the **veteran** agent to find examples of similar implementations to model after

   Be specific in your agent prompts — reference the exact areas of change from the structure outline.

2. **Read all files identified by research tasks**:
   - After research tasks complete, read ALL files they identified as relevant
   - Read them FULLY into the main context
   - Focus on: the files that will be modified, test files that show conventions, similar implementations to model after

3. **Identify any gaps or issues**:
   - If the research reveals that the outline's phases need adjustment (e.g., a file doesn't exist where expected, a pattern has changed), raise this with the user
   - If you discover ordering dependencies not captured in the outline, flag them
   - Do NOT silently deviate from the approved structure

### Step 3: Write the Plan

Once you have deep understanding of the actual files:

1. **Determine the output location**:
   - Default: `workbench/unknown-ticket/plan/YYYY-MM-DD-PLAN-description.md`
   - If a ticket number exists: `workbench/TICKET/plan/YYYY-MM-DD-TICKET-PLAN-description.md`
   - Ask the user if they prefer a different location

2. **Write the plan** using this template. When the document references other `workbench/` files (e.g., the References section), render them as GitHub permalinks per `.claude/skills/snippets-shared-by-skills/permalinks.md`.

````markdown
# [Feature/Task Name]: Implementation Plan

**Date**: YYYY-MM-DD
**Ticket**: [if applicable]

## Overview

[Brief description of what we're implementing — the chosen approach from the design discussion, in 2-3 sentences]

## Current State

[Concise summary of relevant current state, with file:line references]

## Desired End State

[What the system looks like when complete. Specific enough to verify.]

## What We're NOT Doing

[From the design discussion — explicitly out of scope]

## Phase 1: [Name from Structure Outline]

### Overview
[What this phase delivers — carried forward from the outline]

### Changes Required

#### 1. [Component/File]
**File**: `path/to/file.ext`

**Current code** (around line N):
```[language]
// existing code that will change
```

**New code**:
```[language]
// exact code to write or modify
```

**Why**: [1 sentence — what this change accomplishes]

#### 2. [Component/File]
**File**: `path/to/another-file.ext`

[Same structure...]

### Verification

#### Automated:
- [ ] [Specific command]: `command to run`
- [ ] [Specific command]: `command to run`

#### Manual:
- [ ] [What a human checks and how]

**After automated verification passes, pause for manual confirmation before proceeding to Phase 2.**

---

## Phase 2: [Name from Structure Outline]

[Same structure as Phase 1...]

---

[Continue for each phase...]

## Testing Strategy

### New Tests to Write
- [Test file]: [What it tests]
- [Test file]: [What it tests]

### Existing Tests to Update
- [Test file]: [What changes and why]

## References

- Structure outline: [GitHub permalink — see snippets-shared-by-skills/permalinks.md, keep the path as link text]
- Design discussion: [GitHub permalink]
- Research: [GitHub permalinks]
- Ticket: [reference if applicable]
- Key source files: [most important file:line references]
````

3. **Self-review loop:**

   After the plan is written, run a bounded loop with the `skeptic` subagent before presenting to the user. Hard cap: 3 cycles. The audit trail is written to a single sidecar file, never into the plan doc itself.

   **Sidecar path**: `workbench/TICKET/review/YYYY-MM-DD-TICKET-REVIEW-{description}.md`, where `{description}` matches the plan's kebab-case description. Use `unknown-ticket` if no ticket. One file per loop run; each cycle appends a section.

   For each cycle:
   - Glob upstream documents within the ticket directory: `workbench/TICKET/outline/*.md`, `workbench/TICKET/design/*.md`, and `workbench/TICKET/research/*.md`. Read found paths into the prompt; if any glob returns nothing, note it (e.g. "design not found"). Do not block the loop on missing upstream; the skeptic will skip the corresponding cross-stage dimensions.
   - Spawn the `skeptic` subagent with parameters:
     - `target_path`: absolute path to the plan document just written
     - `upstream_paths`: list of absolute paths from the globs above (or `none` if nothing was found)
     - `iteration`: the current cycle number (1, 2, or 3)
   - Parse the structured findings the skeptic returns.
   - **Termination check** — stop the loop if EITHER:
     - `Blockers == 0` AND every Risk and Gap is marked `Trivial: true` by the skeptic, OR
     - This was iteration 3 (hard cap)
   - **Otherwise, revise**:
     - For each `BLOCKER`: do whatever the finding requires to address it. Faithfulness failures (to outline/design/research) mean reverting the deviation or escalating it explicitly. Code-completeness failures mean researching the affected file and writing the missing snippet. Missing-files findings mean adding the file to the appropriate phase. Silent-redesign findings mean resolving the embedded ambiguity in the plan text. Verification-executability failures mean rewriting the verification step to be runnable as-is. Edit the document in place.
     - For each non-trivial `RISK` or `GAP`: address it if achievable within scope. If not, record it in the sidecar's "Deferred" list for this cycle with a one-line reason. (The plan body has no Open Concerns section — deferrals live only in the sidecar.) Do not silently drop findings. Note: plans are expected to be complete — most non-trivial findings should be addressable within the loop budget.
     - **Routing exception** — for findings of these shapes, recording to the sidecar's "Deferred" list does *not* count as "addressed" and the finding remains live into the next cycle: (a) the upstream design's `## Solution Validation` is missing or non-real (escalate as a cross-stage failure — the plan should not exist on top of an unvalidated design), (b) any load-bearing claim being deferred to "the implementer", "pre-merge", or "follow-up". Resolution requires going back to fix the upstream design or resolving the ambiguity in the plan text. If you reach cycle 3 with one of these still live, the loop ends with that finding listed as an unresolved BLOCKER in the chat summary.
     - For each `Trivial: true` finding: leave it.
     - Append a cycle entry to the sidecar file (create the file if this is the first revision cycle). Use the template below.
     - Loop.

   **Sidecar template** (create on first revision cycle, append cycle sections each subsequent cycle):

   ```markdown
   ---
   date: YYYY-MM-DD
   type: self-review
   target: [absolute path to the plan doc]
   target_type: plan
   ticket: [TICKET or unknown-ticket]
   ---

   # Self-review log: [plan doc title]

   **Target**: [GitHub permalink to plan doc — see snippets-shared-by-skills/permalinks.md, keep the path as link text]

   ## Cycle 1 — YYYY-MM-DD HH:MM
   **Cross-stage checks**: outline [✓ | not found, dimension skipped], design [✓ | not found, dimension skipped], research [✓ | not found, dimension skipped]
   **Found**: [B] blockers, [R] risks, [G] gaps
   **Addressed**:
   - [BLOCKER label]: [one-line description of what changed and where in the plan]
   - ...
   **Deferred**:
   - [GAP label]: [one-line reason]
   ```

   When the loop terminates, print a brief inline summary in chat before moving to Step 4. Format:
   ```
   Self-review complete after [N] cycle(s).
   Cross-stage checks: outline [✓ | not found, dimension skipped], design [✓ | not found, dimension skipped], research [✓ | not found, dimension skipped]
   - Cycle 1: [B] blockers, [R] risks, [G] gaps — addressed [X], deferred [Y]
   - Cycle 2: ...
   Sidecar: [path to sidecar file, or "no revisions needed — no sidecar written"]
   [If hard cap reached: list any unresolved BLOCKERs explicitly so the user can act on them.]
   ```

   If the loop terminates clean on cycle 1 (no revisions), do not write a sidecar — there is nothing to audit. Do not narrate intermediate cycles in chat — only the final summary. The sidecar file is the audit trail.

### Step 4: Review and Iterate

1. **Present the plan for spot-checking**:
   ```
   I've written the implementation plan to: [path]

   This follows the phase structure from the outline. Each phase has specific file changes with code snippets and verification steps.

   Worth spot-checking:
   - Are the code snippets accurate to what you'd expect?
   - Are the verification steps sufficient?
   - Any phases where the detail level needs adjustment?
   ```

2. **Iterate based on feedback** — be ready to:
   - Adjust code snippets based on corrections
   - Add missing edge cases or verification steps
   - Clarify ambiguous changes
   - Research additional files if the user points out gaps

3. **Continue refining** until the user is satisfied.

## Guidelines

### Follow the Approved Structure
- The phase breakdown comes from the structure outline. Do NOT reorganize, split, or combine phases without flagging it to the user.
- If you think the outline needs adjustment based on what you found in the code, say so explicitly and get approval before changing.

### Code Snippets Are the Point
- Every file change should have concrete before/after code.
- Snippets should be copy-paste accurate — reference real variable names, real function signatures, real imports.
- If you're unsure about a detail, research it. Don't guess.
- Include enough surrounding context in snippets that the execution agent knows exactly where to make the change.

### Be Thorough in Research, Concise in Output
- Read all source files COMPLETELY before writing snippets.
- Use parallel sub-agents to research efficiently.
- But keep the plan focused — don't pad it with explanations of how the system works (that's in the research doc).

### No Open Questions in the Final Plan
- If you encounter open questions during planning, STOP.
- Research or ask for clarification immediately.
- Do NOT write the plan with unresolved questions.
- The implementation plan must be complete and actionable.
- Every decision must be made before finalizing the plan.

### Verification Must Be Specific
- Automated verification: exact commands that can be run.
- Manual verification: specific things to check, not vague "verify it works."
- Each phase pauses after automated verification for manual confirmation.
- During research, check whether the project has a lint or format command (e.g., in `package.json` scripts, `Makefile`, CI config). If one exists, include it as an automated verification step in every phase.

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

## Example Interaction Flow

```
User: /plan-write workbench/PROJ-44/outline/2026-04-05-PROJ-44-OUTLINE-feature-name.md workbench/PROJ-44/design/2026-04-04-PROJ-44-DESIGN-feature-name.md workbench/PROJ-44/research/2026-04-03-PROJ-44-RESEARCH-feature-name.md
Assistant: Let me read those files completely first...

[Reads all three files fully]

I've read the upstream documents. Here's what I'm working with:

**Chosen approach**: [from design]
**Phases from outline**:
1. [Phase] — [delivers X]
2. [Phase] — [delivers Y]

I'll now research the specific files that need to change. Any corrections before I dive in?

User: Looks right, go ahead.

[Spawns agents to deeply read source files for each phase]
[Reads all identified files]
[Writes the plan with specific code snippets]

I've written the implementation plan to: workbench/PROJ-44/plan/2026-04-05-PROJ-44-PLAN-feature-name.md
...
```
