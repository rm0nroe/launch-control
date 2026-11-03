# Security Policy

## Supported versions

Only the current `main` branch is supported; fixes land there and are picked up
the next time you run `./install.sh`. Tags such as `v0.1.0` mark snapshots for
reference — they are not separately patched.

| Version | Supported |
| --- | --- |
| `main` | yes |
| any tag or older checkout | no — re-install from `main` |

## Reporting a vulnerability

Report privately through GitHub, not in a public issue:

**Security → Report a vulnerability**, or
[open a report directly](https://github.com/rm0nroe/launch-control/security/advisories/new).

This repository publishes no contact email on purpose; the private advisory form
is the reporting channel.

Please include:

- what an attacker gains, and what access they need to start;
- the affected file and, where possible, the line — `install.sh`,
  `skills/onboard/scripts/*.sh`, `tools/**`, or a generated artifact;
- a reproduction: the exact command, the repository shape it needs, and the
  observed result;
- whether it reproduces from a clean `./install.sh` or requires an already
  modified `~/.claude`.

You should get an acknowledgement within 7 days. Launch Control is maintained by one
person, so please allow time before disclosing publicly; you will be credited in
the fix commit unless you ask otherwise. There is no bug bounty.

## What is in scope

Launch Control is Bash and Markdown with no runtime service, so the interesting
surface is what it writes and what it permits:

- **Installer.** `./install.sh` writes into `~/.claude`. Path traversal,
  clobbering of unrelated user files, or an unknown-copy check that can be
  defeated is in scope.
- **Generated permissions.** `/onboard` writes `.claude/settings.json`. A
  generated permission broader than intended — an interpreter wildcard, a
  bypassable deny, an escape from the repo-local read boundary — is in scope.
- **Secret boundary.** The generated denies for `.env`-family paths, and the
  allowlisted `.env.example`-family exceptions. Any input that reads a real
  secret file through them is in scope.
- **Session hooks and the unattended policy.**
  `skills/onboard/scripts/unattended-policy.sh` and the guard/renderer scripts
  gate a live Claude Code session. A command that the policy should deny but
  allows — shell composition, out-of-repo access, sandbox bypass, dependency
  installation, repository or GitHub mutation — is in scope, and so is a hook
  that can be induced to execute attacker-controlled input.
- **Report integrity.** The completion guard and `render-report.sh` attest to
  what a run touched. A way to make the report affirm something false is in
  scope.

## What is out of scope

- Vulnerabilities in Claude Code itself — report those to Anthropic.
- Third-party MCP servers listed in `install/mcp.reference.json`. The catalog is
  secret-free and declares no credentials; report issues to those projects.
- Anything requiring the attacker to already have write access to your
  `~/.claude` or to the repository being onboarded.
- Findings that only apply after a user edits the installed pack by hand.
