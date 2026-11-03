<!-- FIXTURE FILE: example generated root; testing only and stripped during install. -->
---
name: launch
description: >-
  Use when delivering a ticket end-to-end across mobile-iOS, mobile-Android, web,
  backend, and shared code. Routes only the required references and enforces review.
---

# Launch

## Apply when

- A repo-local or external ticket exists and a branch is selected or about to be created.
- The work primarily targets one package; split cross-package work when project rules require it.
- The requested scope runs from ticket understanding through reviewed delivery evidence.

Skip spikes, one-line edits, and conversational questions.

## 1. Classify and route

Write the result into `workbench/<TICKET>/plan/<date>-<slug>.md`.

| Axis | Options | Controls |
|---|---|---|
| Type | feature, fix, polish, refactor, chore | Workflow depth |
| Platform | mobile-iOS, mobile-Android, web, backend, shared | Verification capability |
| Complexity | trivial, small, medium, large | Planning depth |
| Uncertainty | clear, fuzzy | Research depth |

| Stage | Polish (clear) | Fix (clear) | Fix (fuzzy) | Feature (small) | Feature (medium/large) | Refactor |
|---|---|---|---|---|---|---|
| Full CRISPY ladder | no | no | use | light | MUST | use |
| `superpowers:brainstorming` | light | no | use | MUST | MUST | light |
| `superpowers:systematic-debugging` | no | use | MUST | no | no | no |
| `superpowers:test-driven-development` | no | situational | situational | MUST | MUST | situational |
| `plan-execute` | no | no | use | use | MUST | use |
| inspector subagent | use | use | use | use | use | use |
| `review-doc` | no | no | no | no | use on plan | no |
| `superpowers:verification-before-completion` | use | use | use | use | use | use |
| `/ship` | use | use | use | use | use | use |

## Delivery boundaries

Bind this run to one selected backlog ticket, its priority and dependencies, an observable
outcome and explicit exclusions in the existing plan. Broad autonomy authorization does
not select new work or override backlog dependencies. Reuse authorization within its scope;
ask only for a missing decision or action outside that scope.

Set finite whole-effort limits before investigation, with a start time, deadline and any
attempt/cost limits. Include investigation, review, validation, delegated children, retries,
fresh fixtures and replacement contexts. Reserve time for required checks and safe shutdown.
Carry consumed and remaining budget in the existing plan/checkpoint; fresh fixtures and
replacement contexts never reset limits. Check remaining budget before each phase or launch.
At the limit, stop new work, safely settle owned processes, preserve evidence and record the
unfinished outcome. Never weaken acceptance or report unfinished work as delivered.

## Bounded pressure test

Run only for fuzzy, large, irreversible, security-sensitive, or explicitly challenged
work. Ask at most five high-leverage questions and resolve answers into the existing
design artifact. Clear fixes, polish, chores, and one-line work bypass the gate.

## Workflow order

### 0. Ticket intake and code understanding

Read @references/ticket-intake.md.

### 1. Research and design

Use one CRISPY chain and review every authored artifact.

### 2. Workspace isolation

Read @references/implementation.md and select the workspace before implementation.

### 3. Implement

Invoke `plan-execute` exactly once. Use test-first implementation where required.

### 4. Pre-delivery verification

In @references/verification.md, locate headings first, then read only the common
instructions, the ticket's selected Platform subsection, the result record, and relevant
rendered cross-cutting capability sections such as Feature flags or the AI evaluation
contract. Do not read the file wholesale or load unrelated platform subsections. Shared
tickets also read only the consuming platform subsections named in the ticket plan.

### 5. Pre-delivery review

Use the review procedure in @references/implementation.md.

### 6. Deliver

Read @references/delivery.md after action-time authorization.

### 7. Post-deploy verification

Return to @references/verification.md and read production checks plus only this ticket's
selected platform subsection, with the same shared-consumer rule.

## Project Conventions

### From CLAUDE.md

- Use the package's focused test command before the repository-wide suite.
- Preserve user-owned files and unrelated dirty state.

## Exit criteria

- [ ] Classification and reviewers recorded.
- [ ] Implementation and runnable pre-delivery checks pass.
- [ ] Complete branch and working-tree state reviewed.
- [ ] Selected specialist, security, compliance, and performance reviews pass or are unavailable.
- [ ] At least one TC verified; remaining TCs name blockers.
- [ ] Delivery follows project conventions.
- [ ] Stored forge diff matches intended scope; local-only stubs and temporary artifacts are accounted for.
- [ ] CI and production evidence pass or are explicitly unavailable.
- [ ] Clean linked worktree removed after merge.

## Anti-patterns

- Do not skip classification or platform selection.
- Do not guess an ambiguous platform.
- Do not load or run unrelated platform guidance.
- Do not bypass repository instructions.
- Do not bypass action-time authorization.
- Do not move to a new phase while focused checks fail.
- Do not combine package delivery when project rules require a split.
- Do not deliver before user-observable verification.
- Do not infer AI behavior from a dependency name alone.
- Do not declare completion without fresh evidence.
