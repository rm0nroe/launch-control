# Launch Generation Acceptance Criteria

Run these against the generated `.claude/skills/launch/` tree.

## Root router

- [ ] `SKILL.md` begins with valid YAML frontmatter and `# Launch`.
- [ ] Classification contains Type, Platform, Complexity, and Uncertainty.
- [ ] The CRISPY matrix retains every mandatory skill and review gate.
- [ ] The bounded pressure test triggers only for fuzzy, large, irreversible,
      security-sensitive, or explicitly challenged work and asks at most five questions.
- [ ] Clear fixes, polish, chores, and one-line work bypass the pressure test.
- [ ] Workflow order is intake, design, workspace isolation, implementation,
      pre-delivery verification, review, delivery, then post-deploy verification.
- [ ] The root links directly to ticket-intake, implementation, delivery, and
      verification references; references do not link deeper.
- [ ] The standard generated root is at most 325 lines, at least 40% below the
      prior 543-line fixture.

## Ticket intake

- [ ] Repo-local, forge, Notion, Jira, and inline sources render only when supported.
- [ ] Code location, flow, and pattern routes remain available.
- [ ] Full CRISPY, light plan, brainstorming, and systematic-debugging routes remain intact.
- [ ] Resolved pressure-test decisions go into the existing design artifact.
- [ ] Ticket platform selection follows user, ticket or branch, package path, then one
      direct ambiguity question; shared work names affected consuming platforms.

## Implementation

- [ ] Clean primary, dirty primary, and existing linked-worktree states are covered.
- [ ] Worktree-disabled Git and non-Git projects render separate safe fallbacks.
- [ ] Launch alone selects the workspace before `plan-execute`.
- [ ] `plan-execute` never switches or creates a branch on Launch's behalf.
- [ ] Typecheck, test, lint, diff-stat, TDD, specialist, and full-state review guidance remains.
- [ ] Each phase commits at green after focused checks for scoped review and rollback.
- [ ] Review covers committed branch, staged, unstaged, and untracked work.

## Delivery and verification

- [ ] No delivery command appears before runnable local and staging checks.
- [ ] Configured ship and forge-specific paths render only when detected.
- [ ] Commit, trailer, PR body, stored-diff, CI, and clean-worktree removal rules remain.
- [ ] Verification includes only detected platforms or general/unknown.
- [ ] The ticket's selected platform executes only its matching verification subsection;
      a negative routing fixture rejects every unrelated platform check.
- [ ] Relevant rendered cross-cutting capability sections, including feature flags and AI
      evaluation, still run without loading unrelated platform subsections.
- [ ] Detected browser, observability, security, compliance, and performance routes retain their exact capability namespaces.
- [ ] Post-deploy checks are labeled separately and run only after delivery.
- [ ] Result records distinguish verified, blocked, skipped, and unavailable evidence.

## AI evaluation

- [ ] Explicit `aiEvaluation: true` or paired repository evidence activates the contract.
- [ ] Explicit false, generic dependency-only, and no-AI fixtures do not activate it.
- [ ] The contract is vendor-neutral and requires versioned model/prompt/config,
      representative and abuse cases, quality criteria, latency, cost, escalation,
      and a human owner.
- [ ] Deterministic policy/tool-authorization tests remain separate from probabilistic scoring.
- [ ] `testing-patterns` receives AI evaluation guidance only when the flag is active.

## Generated-tree integrity

- [ ] Every generated file has all placeholders and conditionals resolved.
- [ ] Root model inserts are absent; project-specific inserts live in delivery.
- [ ] Project-convention content is reproduced in one source-tagged
      `## Project Conventions` section with documented heading demotion; its bullets stay
      verbatim and user-global instructions remain opt-in.
- [ ] Default and `--launch-control` manifests account for all five generated files.
- [ ] The complete 72-item pre-split contract fixture maps one-for-one to executable
      validator assertions.
- [ ] `--launch-control` migrates a prior one-file generated tree to five files without changing
      unrelated user-authored content.
- [ ] Installed copies strip every `*-fixture-*.md` test artifact.
