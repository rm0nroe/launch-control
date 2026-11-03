## Background

<!-- What problem does this solve? Link the issue or ticket as a markdown
     reference link. If there is no issue, say what prompted the change. -->

## Changes

<!-- Flat bullets, one per meaningful change. Add `### <area>` subheaders only
     if the PR spans several areas. -->

-

## Test Plan

<!-- Only real manual-verification items. Do not list "validation passes" here —
     that is the checklist below, and CI runs it. -->

- [ ]

## Validation

Launch Control's declared validation contract is exactly these two commands. Do not
add gates beyond them.

- [ ] `./tools/validate-pack.sh` passes
- [ ] `./install.sh --dry-run` preview is unchanged in intent
- [ ] `./tools/preflight-onboard.sh` passes — only if this PR was exercised with a
      manual `/onboard` acceptance run

## Checklist

- [ ] Branch is off `main`; commit subjects are `type(scope): description`,
      lowercase and imperative
- [ ] No secrets, personal paths, or generated project output are in the diff
- [ ] Bash changes keep `#!/usr/bin/env bash` + `set -euo pipefail` and guard
      optional tools
- [ ] Any new generated permission stays narrow — exact commands and read-only
      inspection, never interpreter wildcards
- [ ] Docs updated where behavior changed (`README.md`, `CLAUDE.md`,
      `artifacts/`)
