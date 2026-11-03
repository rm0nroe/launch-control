# onboard skill

Use when entering a new project or codebase for the first time, when a repo has no
`.claude/` directory, or when asked to "set up Claude Code", "onboard", "init
workspace", or "configure this project". The skill pre-scans a repository's existing
docs and engineering practices and generates a tailored Claude Code workspace
(skills, agents, commands, and settings) matched to what it finds, rather than
dropping in a generic template.

## Where this came from

This skill is part of **Launch Control**, a Claude Code-first onboarding and delivery kit.
It is distributed as a self-contained directory so it can be copied standalone into
`~/.claude/skills/`. The canonical source is the Launch Control repository:

- https://github.com/rm0nroe/launch-control

## License

Launch Control original material, licensed under the **Apache License, Version 2.0**. The
full license text travels with this skill in the adjacent [`LICENSE`](./LICENSE) file,
and the required attribution notice is in the adjacent [`NOTICE`](./NOTICE) file. Retain
both files when redistributing this skill.

The `onboard` skill's own text and scripts contain no third-party or separately licensed
components. Its report template embeds SIL Open Font License fonts, each with its license
text under `assets/`. The complete component boundary is documented in the Launch Control
repository's `NOTICE` and `PROVENANCE.md`.
