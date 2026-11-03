# Implementation Reference

Invoke `plan-execute` exactly once after workspace selection and plan approval.

## Workspace selection

Launch owns this decision before `plan-execute` starts.

{{#if WORKTREES_ENABLED}}
| Current state | Action | Invariant |
|---|---|---|
| Primary checkout, clean | `create-linked-worktree` | Create from `origin/{{BASE_BRANCH}}`; never develop on the primary checkout. |
| Primary checkout, dirty | `create-linked-worktree-preserve-primary` | Create from `origin/{{BASE_BRANCH}}` without switching, cleaning, or carrying primary changes. |
| Existing linked worktree | `stay-in-linked-worktree` | Keep its branch and path; do not create or enter another workspace. |

Detect a linked worktree by comparing absolute `git rev-parse --git-dir` and
`git rev-parse --git-common-dir`, then exclude submodules with
`git rev-parse --show-superproject-working-tree`. When creation is needed, invoke
`superpowers:using-git-worktrees`; verify `.worktrees/` is ignored first.

`plan-execute` must treat the selected workspace as immutable input. It may
report a branch mismatch, but it never switches or creates a branch on Launch's behalf.
{{/if}}
{{#unless WORKTREES_ENABLED}}
| Current state | Action | Invariant |
|---|---|---|
| Git repository with worktrees disabled | `branch-in-place` | Use the current checkout without cleaning or discarding changes. |
| Non-Git project | `stay-current-directory-non-git` | Skip branch commands and keep the current directory. |

When `git rev-parse --git-dir` succeeds, fetch the base branch without switching over
dirty work, then create the user-selected branch in place. When it fails, run no Git
command. `plan-execute` respects that selected directory and branch.
{{/unless}}

## Per-phase loop

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

Each implementation phase is one reviewable commit after its focused checks pass.
Commit at green so every phase retains a scoped review and rollback point.

```bash
{{TYPECHECK_CMD}}
{{TEST_CMD}}
{{LINT_CMD}}
git diff --stat -- {{PACKAGE_DIFF_SCOPE}}
```

Remove empty command lines when a command is not detected. For features and bugs,
write the failing test, observe the expected failure, make the minimum production change,
then observe the focused and full checks passing. Follow
`superpowers:test-driven-development`; do not proceed on a new failure.
Do not move to the next phase until the current phase's focused checks pass.

Specialist delegation is limited to detected domains: {{SPECIALIST_DOMAIN_LIST}}.

## Pre-delivery review

Run the inspector subagent over all four states:

```text
Review branch <branch> for ticket <key>. Inspect
git diff origin/{{BASE_BRANCH}}...HEAD, git diff --cached, git diff, and every
untracked path from git status --short.

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
Verdict: ship / ship-with-fixes / reroll. Under 500 words, bullets, no code.
```

For auth, payments, or regulated content, use every available relevant path:
{{#if HAS_SECURITY_REVIEW_COMMAND}}
- Run `/{{SECURITY_REVIEW_COMMAND_NAME}}`.
{{/if}}
{{#if HAS_COMPLIANCE_AGENT}}
- Run the `compliance-reviewer` subagent.
{{/if}}
{{#unless HAS_COMPLIANCE_AGENT}}
- Run the available security review path.
{{/unless}}
For performance-sensitive paths:
{{#if HAS_PERFORMANCE_AGENT}}
- Run the `performance-optimizer` subagent.
{{/if}}
{{#unless HAS_PERFORMANCE_AGENT}}
- Run the available performance review path.
{{/unless}}

Apply ship-with-fixes findings and rerun the affected checks.
