---
name: offboard
description: "Remove the workspace /onboard generated in this repository: generated files, merged generated blocks, and onboard control state. Use when resetting an acceptance repo before a fresh /onboard run, undoing an onboarding, or handing a repo back clean. Usage: /offboard [--apply]"
argument-hint: "[--apply]"
allowed-tools: Bash(bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/offboard/scripts/reset.sh"), Bash(bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/offboard/scripts/reset.sh" --apply), Bash(bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/offboard/scripts/reset.sh" --apply --yes), Read, Glob
---

# Launch Control Reset

Removes what `/onboard` wrote into **this** repository.

`./install.sh --uninstall` does not do this and cannot. It removes the *pack* from
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`; every onboarded repository keeps its generated
workspace afterwards. The two surfaces are disjoint.

## Run it

Always from the repository root:

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/offboard/scripts/reset.sh"            # preview
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/offboard/scripts/reset.sh" --apply    # execute
```

Preview is the default and changes nothing. Show the user the preview and get confirmation
before running `--apply`. Never pass `--yes` on a user's repository — it exists for the
validator.

## What it does

| Class | Action |
|---|---|
| generated file, untracked | deleted |
| generated file, **tracked by git** | **left alone**, reported — deleting a committed file is the user's call |
| `CLAUDE.md`, `AGENTS.md` carrying the `## Generated Quick Reference` block (heading through the next top-level heading or end of file), `.gitignore` carrying the `# Claude Code local files` rule group, or any of them carrying a legacy `BEGIN/END GENERATED SECTION -- onboard` comment block from an older onboard | block stripped, the rest of the file kept |
| a merged file that was *entirely* the block, untracked | deleted |
| a merged file that was *entirely* the block, tracked | left alone, reported |
| `.codex/` mirrors of manifest paths from `/onboard --codex` (skills, commands as skills) | same rules: untracked deleted, tracked left alone |
| a Codex agent TOML | deleted with its `.codex/launch-control-agent-ownership/` record only when that record names its exact bytes; otherwise left alone, reported |
| the `.launch-control/refresh/receipts/` record of every fully removed skill bundle | deleted, so the next onboard does not misread a fresh bundle; refresh backups are kept |
| any path reached through a symlinked directory | left alone, reported: deleting through the link could reach outside the repository |
| `.launch-control-onboard/`, `.git/launch-control-onboard-run-*`, `.git/launch-control/onboard-report.html` | deleted |
| anything not in the onboard manifest | never touched |

Directories are removed with `rmdir` only — non-recursive, deepest first, so a directory that
still holds anything survives.

## Why it never uses `rm -rf`

A round-11 acceptance run removed a generated workspace with `rm -rf .claude` and **deleted 24
tracked files** in target repo A, which commits its `.claude/` tree. Two rules came out
of that and both are enforced in the script:

1. Every removal is an enumerated path from the onboard manifest. Never a directory sweep.
2. A tracked file is never deleted.

`.claude/` being gitignored is a property of *some* repositories, not a guarantee.

## Reporting

Relay the script's own output. It prints what it removed, what it stripped, and — importantly —
what it deliberately did not touch. If the "NOT removed" list is non-empty, surface it: those
are files the user must decide about, usually with `git rm`.

## Limits

Adopt mode: the path set is derived from the onboard manifest and the generated blocks, because a
completed `/onboard` run leaves no receipt behind. It therefore cannot distinguish a generated
`.claude/commands/pr.md` from one the user wrote at the same path — which is why the preview
exists and why tracked files are never removed.
