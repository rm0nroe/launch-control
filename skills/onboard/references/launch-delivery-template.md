# Delivery Reference

## Authorization

A validated, frozen delivery grant carries standing approval for its exact controller
actions and targets. The restricted GitHub publisher independently verifies the reviewed
candidate, publishes within that grant, and records post-merge verification. Workers
finish at `awaiting_review`. An explicit `source_done` action and matching source writeback
binding permit conditional completion only after verified merge; rediscovery reports
new work without launching it. Deployment remains a separate obligation.
A merge that triggers a deploy is a deploy. Before merging, check for deploy workflows that
run on push to the base branch and for hosting integrations that promote on merge (for
example Vercel or Netlify). Outside an existing grant, obtain action-time authorization for
that deploy, not only for the merge.
For actions outside an existing grant, state the exact action and obtain explicit action-time authorization.

{{#if HAS_SHIP_COMMAND}}
Run `/{{SHIP_COMMAND_NAME}}` only after pre-delivery verification and review pass.
{{/if}}
{{#unless HAS_SHIP_COMMAND}}
{{#if HAS_GITHUB_PR}}
```bash
git push -u origin <branch>
gh pr create
```
{{/if}}
{{#if HAS_GITLAB_MR}}
Push the branch, then create the merge request with the project's GitLab workflow.
{{/if}}
{{#if HAS_BITBUCKET_PR}}
Push the branch, then create the pull request with the project's Bitbucket workflow.
{{/if}}
{{#unless HAS_GITHUB_PR}}
{{#unless HAS_GITLAB_MR}}
{{#unless HAS_BITBUCKET_PR}}
Prepare a local handoff; no supported forge delivery path was detected.
{{/unless}}
{{/unless}}
{{/unless}}
{{/unless}}

**Commit format defaults**

- Commit: `<type>(<scope>): [<TICKET>] <description>`, lowercase imperative, up to 150 characters.
- Trailers follow whatever the base branch already uses. Read `git log` and match it: if
  recent commits carry trailers, preserve that convention; if they carry none, add none.
- Only an explicit numeric maximum in a repository-controlled convention may override the default.
- Never infer a shorter limit from the observed lengths of recent commit subjects.
- PR title: `[<TICKET>] <verb> <description>`, under 72 characters.
- PR body: Background, Changes, and unchecked manual Test Plan items.
- Never add AI attribution as a portable default.

## After delivery

{{#if HAS_GITHUB_PR}}
```bash
gh pr diff <pr> --name-only
gh pr checks <pr>
gh pr view <pr> --json reviewDecision
```
{{/if}}
{{#if HAS_GITLAB_MR}}
Confirm the stored merge-request diff and pipeline status.
{{/if}}
{{#if HAS_BITBUCKET_PR}}
Confirm the stored pull-request diff and build status.
{{/if}}

The forge's stored diff is the scope authority after merge-base drift.

{{#if WORKTREES_ENABLED}}
After merge, leave the worktree and remove it only after `git status --short` is empty.
Never force removal over uncommitted files.
{{/if}}

## Project-specific delivery gotchas

<!-- MODEL_INSERT: project_specific_gotchas -->

- Destructive actions require explicit permission and exact targets.
- A rebased comparison can include unrelated base drift; verify the stored forge diff.

<!-- MODEL_INSERT: project_specific_anti_patterns -->
