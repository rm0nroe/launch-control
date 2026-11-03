# Ticket Intake and Design Reference

1. Search `BACKLOG.md` and `workbench/<TICKET>/`.
2. Use available GitHub, Notion, and Atlassian read tools only when the ticket requires them.
3. Use inline ticket text last.

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

Select one ticket platform from the user request, ticket or branch metadata, or package
path. If those remain ambiguous, ask one direct question. Shared work names its affected
consuming platforms in the ticket plan.

## Specialist routing

Use only the selected platform row plus the `any` row. `mobile-iOS` and
`mobile-Android` both select the `mobile` row. Rows list only detected agents.

| Platform | Detected agents |
|---|---|
| mobile | react-frontend-specialist, flow-architect, testing-quality-expert |
| web | react-frontend-specialist, workflow-designer, cms-specialist, testing-quality-expert |
| backend | graphql-backend-expert, testing-quality-expert |
| shared | nx-monorepo-expert |
| any | compliance-reviewer, performance-optimizer |

Use surveyor for definitions, navigator for flows,
veteran for existing patterns, and feature-researcher for libraries.
Use `technician` and `episodic-memory` when available for prior project work.

Clear fixes use root-cause debugging and a concise reviewed plan. Features run
`superpowers:brainstorming`; medium or large features use the full CRISPY chain.

## Parallel dispatch patterns

- Codebase discovery: locate definitions and trace flow in parallel.
- Pre-ship review: run independent relevant review lenses in parallel.
- Cross-package impact: ask detected platform specialists about separate packages in parallel.

Rule of thumb: parallelize independent reads, never dependent writes.
Use `superpowers:dispatching-parallel-agents` when available.
