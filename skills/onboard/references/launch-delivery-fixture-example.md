# Delivery Reference

Obtain explicit action-time authorization, then run `/ship` after every pre-delivery gate.
It performs commit (lowercase, up to 150 characters, trailers matching the base branch),
push, and pull-request creation.

Only an explicit numeric maximum in a repository-controlled convention may override
the commit default. PR titles remain under 72 characters; PR bodies contain Background,
Changes, and unchecked manual Test Plan items.

After delivery, use `gh pr diff`, `gh pr checks`, and `gh pr view --json reviewDecision`.
After merge, remove the linked worktree only when it is clean.

<!-- inferred from package.json -->
- Use the project package runner for validation commands.
<!-- inferred from dev-server process -->
- Verify the running worktree before trusting hot reload.
<!-- inferred from README.md -->
- Treat VPN-gated API timeouts as an environment blocker until connectivity is verified.
<!-- inferred from ticket attachment workflow -->
- Fetch Jira 406 attachment binaries only through an authenticated browser capability.
<!-- inferred from UI layout conventions -->
- Verify flex layout changes at the affected parent and child.
<!-- inferred from UI state flow -->
- Fix a first-frame race in initial state instead of adding a later correction.
<!-- inferred from test fixtures -->
- Record empty stubs that fail render preconditions as blocked, not failed.
<!-- inferred from CLAUDE.md -->
- When CI minutes run out, merging does not deploy the API: hand-deploy it. The UI host still deploys on merge.
