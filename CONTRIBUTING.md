# Contributing to Launch Control

Launch Control is a portable onboarding and delivery kit for coding agents. Contributions
should keep the default install safe, project-local, and useful on repositories that do
not share one company's conventions.

## Before opening a change

- Keep secrets, personal paths, machine-specific configuration, and generated project
  output out of the source tree.
- Keep optional integrations and heavyweight workflows behind explicit opt-ins.
- Preserve the distinction between project-local guidance and user-global guidance.
- Update the README or skill documentation when a flag, onboarding path, generated
  artifact, or safety boundary changes.

## Validation

From the repository root, run:

```bash
./tools/validate-pack.sh
./install.sh --dry-run
```

The validator checks shell syntax, reference JSON, generated-template balance, installer
behavior, onboarding contracts and manifests, renderer/guard behavior, and known unsafe
or stale residue. The dry run previews the default install without changing the user's Claude
configuration.

`tools/validate-pack.sh` is the entry point; the cases live in `tools/validate/`, sourced
in filename order into one shell. `lib.sh` holds the shared state (`$ROOT`, `$failures`,
`run_rg`, `check_absent`); the numbered parts build on each other's fixtures and temp
directories, so add a new case to the part that owns its subject rather than to a new
file at the end. The suite runs under `set -e`: an assertion that fails aborts the run and
names its own file and line.

Because the parts are sourced in order, a part may only use state an earlier part defined —
a forward reference is a silent skip, not an error. That also makes most parts unrunnable
alone: only `20-policy.sh` is self-contained, and later parts need what precedes them, for
example `bash -c 'for p in lib 20-policy 30-guard-lifecycle 40-report-contract; do . tools/validate/$p.sh; done'`
to exercise the report contract. `lib.sh` exports `LAUNCH_CONTROL_NO_OPEN=1`, so a partial
run never opens fixture report pages on your desktop. The full `./tools/validate-pack.sh` is the only
authoritative run; its digest gate fires before the behavioral cases, so after any skill or
agent edit append the edited item's current digest to `install/launch-control-owned-digests.txt`
(and, for native Codex, to `install/codex-owned-digests.txt` or `install/codex-agent-digests.txt`)
before re-running.

## What the pack ships

Shipping a skill means Launch Control claims digest ownership of its installed path: any drift
in the installed copy makes `./install.sh --dry-run` exit 2, which fails the declared
validation contract. Only ship a skill whose content this repository can keep true.

Do not ship a skill that restates a third-party CLI's surface. Launch Control's copy goes stale,
live sessions correct the installed file because that is what runs, and the digest breaks,
repeatedly, with no port that holds. A skill may orchestrate such a tool only if it never
becomes a second copy of the tool's interface: name the tool's own `--help` and installed
skill as the authorities instead of copying its commands. If a proposed skill cannot be
written that way, let the tool's own installer own its skill.

## Pull requests

Describe the user-visible behavior, the onboarding or installer scope affected, and the
validation performed. Do not include credentials or committed output from a target
project.

`.github/PULL_REQUEST_TEMPLATE.md` carries the expected sections and the validation
checklist. CI runs `./tools/validate-pack.sh` on Linux and macOS for every pull request,
so a change that only passes locally on one of them still fails the gate.

## Reporting problems

Bugs and proposals go through the issue forms in `.github/ISSUE_TEMPLATE/`.

Security vulnerabilities do **not** go in a public issue — report them privately through
GitHub, as described in [SECURITY.md](SECURITY.md).

## Code of conduct

Participation is governed by the [Contributor Covenant](CODE_OF_CONDUCT.md).
