---
name: plan-execute
description: Execute an approved implementation plan one phase at a time with verification
model: sonnet
effort: medium
---

# Implement Plan

You are tasked with executing an approved implementation plan. These plans were produced by earlier sessions (research, design, outline, plan) and contain phases with specific file changes, code snippets, and verification steps.

**Key principle**: The plan is your primary input. It contains the decisions, the code snippets, and the verification steps. Your job is to execute faithfully, verify thoroughly, and surface mismatches early. Do not redesign — implement.

## Initial Response

When this command is invoked:

1. **If a plan file path was provided as a parameter**:
   - Immediately read the plan FULLY (use Read tool WITHOUT limit/offset)
   - Read `@snippets-shared-by-skills/guide-stars-preamble.md` and follow it.
   - Check for existing progress markers (`- [x]`)
   - Begin the context gathering phase

2. **If no parameters provided**, respond with:
```
I'll help you implement an approved plan.

I need:
1. The plan file (e.g., `workbench/TICKET/plan/YYYY-MM-DD-TICKET-PLAN-description.md`)

The plan should contain phases with specific file changes, code snippets, and verification steps from the planning stage.

Ideally, start a fresh session for each phase to keep context clean. But if you'd like to continue through multiple phases in one session, that works too.
```

Then STOP and wait for the user's input.

## Context Gathering

Once you have the plan:

1. **Read the plan FULLY**:
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read the entire plan
   - **NEVER** read the plan partially
   - Identify all phases and their status (checked vs unchecked)
   - Note all source files referenced in the plan

2. **Read all files referenced in the current phase FULLY**:
   - Every file listed in the phase's "Changes Required" section
   - Any test files referenced
   - Any related files the plan mentions for context
   - **IMPORTANT**: Read these files WITHOUT limit/offset — you need complete context

3. **Respect the workspace selected by the orchestrator**:
   - Resolve absolute `git rev-parse --git-dir` and `git rev-parse --git-common-dir`,
     plus `git rev-parse --show-superproject-working-tree` for the submodule guard.
   - When Git dir and common dir differ and the checkout is not a submodule, keep the
     existing linked worktree, branch, and path.
   - Compare `git branch --show-current` with the plan. If they disagree, report the
     mismatch and stop; do not switch or create a branch.
   - When invoked by Launch from a primary checkout, stop and report that workspace
     isolation was not completed. Launch owns workspace selection before this skill.
   - When invoked directly, require the user to select the workspace first. This skill
     never switches the primary checkout or creates a branch.
   - **NEVER implement on `main`** — always work in the selected ticket workspace.

4. **If resuming (plan has existing checkmarks)**:
   - Trust that completed work is done
   - Pick up from the first unchecked item
   - Verify previous work only if something seems off

5. **Present your understanding**:
   ```
   I've read the plan. Here's where we are:

   **Plan**: [plan name/description]
   **Branch**: [current branch name]
   **Progress**: [N of M phases complete]
   **Current phase**: Phase [N] — [name]
   **Files to change**: [list key files for this phase]

   Ready to implement Phase [N]. Any corrections before I start?
   ```

6. **STOP and wait.** Do not begin implementation until the user confirms.

## Implementation

Execute the current phase:

1. **Follow the plan's code snippets closely** — they were written with the actual codebase in mind
2. **Implement changes in the order specified** by the plan
3. **After each file change**, verify it makes sense in context — if something feels wrong, pause
4. **Update checkboxes in the plan** as you complete each change using Edit
5. **Create a todo list** to track your progress through the phase

If reality diverges from the plan, STOP. Do not silently deviate or attempt to redesign. Present the issue clearly:
```
Issue in Phase [N]:
Expected: [what the plan says]
Found: [actual situation]
Why this matters: [explanation]

How should I proceed?
```

## Verification

After implementing a phase, run the verification steps **as specified in the plan**:

1. **Run lint/format check** — even if the plan doesn't mention it:
   - Check the project for a lint or format command (e.g., `package.json` scripts, `Makefile`, CI config)
   - If one exists, run it. Fix any errors it reports and re-run until clean.
   - If the project has no discoverable linter, skip this step.

2. **Run automated verification** listed in the plan's phase verification section
   - Fix any issues before proceeding
   - Re-run until all automated checks pass

3. **Update progress**:
   - Check off completed automated verification items in the plan using Edit
   - Update your todo list

4. **Pause for manual verification**:
   ```
   Phase [N] Complete — Ready for Manual Verification

   Automated verification passed:
   - [List automated checks that passed, from the plan]

   Please perform the manual verification steps listed in the plan:
   - [List manual verification items from the plan]

   Let me know when manual testing is complete so I can proceed to Phase [N+1].
   ```

5. **Do NOT check off manual verification items** until the user confirms they pass.

If instructed to execute multiple phases consecutively, skip the pause until the last phase. Otherwise, assume you are doing one phase per invocation.

Auto mode does not override these pause points. Manual verification happens in environments Claude cannot reach (non-prod deploys, dashboards, real traffic), so the gates are structural, not routine. Pause and wait regardless of mode.

## If You Get Stuck

When something isn't working as expected:
- First, make sure you've read and understood all the relevant code
- Consider if the codebase has evolved since the plan was written
- Present the mismatch clearly and ask for guidance

Use sub-agents sparingly — mainly for targeted debugging or exploring unfamiliar code.

## Fresh Context Per Phase

For best results, start a new session for each phase. Each session should receive:
- The plan file (to see overall progress and the current phase's details)
- The source files relevant to the current phase

This keeps context clean and avoids the "dumb zone" that comes with long conversations. Continuing through multiple phases in one session is acceptable while the context stays under roughly **~100k tokens** — past that, instruction adherence degrades regardless of the model's window size (Opus 4.7's 1M default doesn't change this; the dumb zone is anchored to absolute tokens, not a percentage of the window).

## Example Interaction Flow

```
User: /plan-execute workbench/PROJ-44/plan/2026-04-06-PROJ-44-PLAN-feature-name.md
Assistant: Let me read the plan completely first...

[Reads plan fully, reads all files referenced in Phase 1]

I've read the plan. Here's where we are:

**Plan**: PROJ-44 — Feature Name
**Progress**: 0 of 3 phases complete
**Current phase**: Phase 1 — Core Data Model
**Files to change**: src/models/feature.ts, src/db/migrations/..., src/stores/feature-store.ts

Ready to implement Phase 1. Any corrections before I start?

User: Go ahead.

[Implements Phase 1 changes, runs automated verification]

Phase 1 Complete — Ready for Manual Verification

Automated verification passed:
- [x] `npm run typecheck` — no errors
- [x] `npm test -- --grep "feature"` — 4 tests passing

Please perform the manual verification steps listed in the plan:
- [ ] Verify the migration runs cleanly on a fresh database
- [ ] Check that the new model appears in the admin UI

Let me know when manual testing is complete so I can proceed to Phase 2.
```
