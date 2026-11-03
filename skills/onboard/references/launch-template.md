<!--
TEMPLATE FILE: consumed by /onboard --launch-control.
Placeholders: {{NAME}} substituted from context dictionary.
Conditionals: {{#if FLAG}}...{{/if}} included when true; unless is the inverse.
Loops: {{#each LIST}}...{{/each}} expanded with {{this.field}}.

Version: 3
v3 changelog: progressive references, one workspace owner, ordered verification,
bounded pressure testing, and conditional AI evaluation.
-->
---
name: launch
description: >-
  Use when delivering a ticket end-to-end across {{PLATFORM_LIST}}. Classifies the
  work, routes only the needed delivery references, and enforces review and
  verification. Skip one-off commands, exploration, and work without a ticket.
---

# Launch

## Apply when

- A repo-local or external ticket exists and a branch is selected or about to be created.
- The work primarily targets one package; split cross-package work when project rules require it.
- The requested scope runs from ticket understanding through reviewed delivery evidence.

Skip spikes, one-line edits, and conversational questions.

{{#if AUTONOMY_ENABLED}}
## Supervised recovery

For an explicit autonomy activation or an active `LAUNCH_RUN_ID`, read the installed
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/references/launch-autonomy.md`.
Preserve the assigned workspace and ordinary workflow below. Record phase notes;
pause at approval boundaries. Local readiness ends at `awaiting_review`, not shipped.
{{/if}}

## 1. Classify and route

Write the result into `workbench/<TICKET>/plan/<date>-<slug>.md`.

| Axis | Options | Controls |
|---|---|---|
| Type | feature, fix, polish, refactor, chore | Workflow depth |
| Platform | {{PLATFORM_LIST}} | Verification capability |
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
| {{#if HAS_SHIP_COMMAND}}`/{{SHIP_COMMAND_NAME}}`{{/if}}{{#unless HAS_SHIP_COMMAND}}push{{/unless}} | use | use | use | use | use | use |

`MUST` is mandatory. `situational` applies when coverage or regression risk warrants it.

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

Run this before design only when work is fuzzy, large, irreversible,
security-sensitive, or explicitly requests challenge. Ask at most five high-leverage
questions across outcome, assumptions and non-goals, risk and rollback, evidence, and
stop conditions. Resolve every priority answer into the existing design artifact; do
not create another mandatory document. An unanswered priority question blocks design
approval. Clear fixes, polish, chores, and one-line work bypass this gate.

## Workflow order

### 0. Ticket intake and code understanding

Read @references/ticket-intake.md and execute only the route selected by classification.

### 1. Research and design

Use the depth selected above. For the full path, run one authored chain:
`research-questions` → `research-codebase` → `design-doc` → `design-outline` →
`plan-write`. At every authored artifact boundary, run `review-doc`, resolve blocking findings, and
only then advance.

### 2. Workspace isolation

Read @references/implementation.md and complete its workspace-selection section before
invoking implementation. Launch owns workspace selection exactly once.

### 3. Implement

Continue in @references/implementation.md. Invoke `plan-execute` exactly once
after plan approval; do not also invoke `superpowers:executing-plans` or another planner.
Use test-first implementation where the classification matrix requires it.

### 4. Pre-delivery verification

In @references/verification.md, locate headings first, then read the common pre-delivery
instructions, the ticket's selected Platform subsection, the result record, and rendered
cross-cutting capability sections relevant to the ticket, such as Feature flags or the AI
evaluation contract. Do not read the file wholesale or load unrelated platform subsections.
For `shared`, also read only the consuming platform subsections explicitly named in the
ticket plan. Execute only those selected checks before any push, pull request, merge, or
deployment.

### 5. Pre-delivery review

Use the review procedure in @references/implementation.md. Apply ship-with-fixes findings
and rerun affected checks before delivery.

### 6. Deliver

Read @references/delivery.md. External writes still require action-time authorization.

### 7. Post-deploy verification

Return to @references/verification.md after delivery. Read its post-deploy section plus
only the subsection selected for this ticket, with the same `shared` consumer rule. Do
not read unrelated platform subsections or use a pre-delivery check as production proof.

## Project Conventions

{{#each CLAUDE_MD_FILES}}

### From {{this.source}}

{{this.content}}

{{/each}}
{{#unless CLAUDE_MD_FILES}}
None detected. Infer from package scripts and CI configuration during execution.
{{/unless}}

## Non-negotiable gates

- Workspace isolation precedes `plan-execute`; that skill must respect an existing linked worktree.
- No delivery path precedes runnable local and staging user-observable checks.
- A inspector verdict of ship, or applied ship-with-fixes findings, precedes delivery.
- Deterministic policy/tool authorization and probabilistic AI scoring stay separate when AI evaluation is enabled.
- Verification evidence is recorded in the plan; unverified cases name a concrete blocker.

## Exit criteria

- [ ] Classification and selected reviewers are recorded.
- [ ] All implementation phases and runnable pre-delivery checks pass.
- [ ] The complete branch, staged, unstaged, and untracked state was reviewed.
- [ ] Selected specialist, security, compliance, and performance reviews pass or are unavailable.
- [ ] At least one TC verified through the appropriate capability; remaining TCs name blockers.
- [ ] Delivery metadata follows project conventions.
- [ ] The stored forge diff matches intended scope; local-only stubs and temporary artifacts are accounted for.
- [ ] CI and post-deploy evidence pass, or their unavailable boundary is explicit.
- [ ] The linked worktree is removed after merge only when it is clean.

## Anti-patterns

- Do not let `plan-execute` switch or create branches after Launch selects the workspace.
- Do not add pressure-test ceremony to clear, low-impact work.
- Do not load task-irrelevant platform guidance.
- Do not deliver before runnable user-observable verification.
- Do not infer AI behavior from a generic dependency name alone.
- Do not declare completion from typecheck, lint, or an agent report without fresh evidence.
- Do not guess the ticket platform when the user, ticket, branch, and package path are ambiguous.
- Do not bypass repository instructions or action-time authorization.
- Do not move to a new phase while its focused checks are failing.
- Do not combine independent package delivery into one change when project rules require a split.
