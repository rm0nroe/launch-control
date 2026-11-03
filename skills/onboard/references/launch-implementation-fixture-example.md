# Implementation Reference

| Current state | Action |
|---|---|
| Primary checkout, clean | `create-linked-worktree` |
| Primary checkout, dirty | `create-linked-worktree-preserve-primary` |
| Existing linked worktree | `stay-in-linked-worktree` |

Launch owns workspace selection. `plan-execute` respects the selected linked
worktree and never switches or creates a branch on Launch's behalf.

Before each phase, retry or child/fixture launch, check scope and remaining whole-effort
budget against the existing plan. Charge investigation, review, validation and children to
the same effort; carry consumed budget across fresh fixtures and replacement contexts.
Do not implement substantial discovered prerequisites until recorded in the backlog and
reassessed for necessity, priority and remaining effort. Changed outcome, architecture or
budget triggers approach/priority reassessment before more implementation.
Repeated acceptance failures trigger approach review before another attempt; a fresh fixture
is not a budget reset. Reuse existing authorization for settled scope, and ask only for a
missing substantive decision. At the limit, stop new work, safely settle owned processes,
preserve evidence and record unfinished work; never weaken acceptance to fit the budget.

Each phase follows red, green, refactor with `superpowers:test-driven-development`, then:

```bash
cd packages/<pkg> && npx tsc --noEmit
yarn test <path/to/touched.test.tsx>
npx eslint <changed-files>
git diff --stat -- packages/<pkg>/src/
```

Commit each phase at green after its focused checks pass.
Do not move to the next phase until the current phase's focused checks pass.

The pre-delivery reviewer inspects `git diff origin/main...HEAD`, `git diff --cached`,
`git diff`, and every untracked path. Verdict: ship, ship-with-fixes, or reroll.
Context: classification, selected backlog priority/dependencies, promised observable outcome,
exclusions, native/existing capability-gap evidence, consumed/remaining whole-effort budget,
prerequisite decisions, phase changes, acceptance criteria, and uncertainties.
Review necessity as well as correctness: does this deliver the selected outcome in backlog
order, reuse native/existing capabilities, and avoid unnecessary machinery? Check discovered
prerequisites were recorded before implementation and changes in outcome, architecture or
budget received approach/priority reassessment. Fresh fixtures and replacement contexts must
carry consumed budget; repeated acceptance failures require approach review.
Plans and passing checks do not substitute for the promised outcome or priority decisions.
Flag regressions, dead code, missing tests, and platform-specific risks.
For sensitive work, run `/security-review` and `compliance-reviewer`; use
`performance-optimizer` for performance-sensitive paths.
