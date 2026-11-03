# Context Discovery

Read this file completely before Phase 0. It owns repository discovery, validation-contract derivation, the discovery checkpoint, and the dependency preflight.

## Contents

- [Phase 0: Context Discovery](#phase-0-context-discovery)
- [0a. Existing Claude Code setup](#0a-detect-existing-claude-code-setup)
- [0b. Project metadata and documented gates](#0b-extract-project-metadata)
- [0c. Stack classification](#0c-identify-stack)
- [0d. Discovery report and checkpoint](#0d-print-discovery-report)
- [0e. Dependency preflight](#0e-required-dependency-preflight)

## Phase 0: Context Discovery

**Read before writing. Never guess — derive everything from source.**

### 0a. Detect Existing Claude Code Setup

Scan for and catalog each (read if present):

| Path                          | If Found                                            |
| ----------------------------- | --------------------------------------------------- |
| `CLAUDE.md`                   | NEVER overwrite — merge via delimited section       |
| `CLAUDE.local.md`             | Leave untouched                                     |
| `.claude/settings.json`       | Merge permissions/hooks — never remove existing     |
| `.claude/settings.local.json` | Leave untouched                                     |
| `.claude/agents/*.md`         | Preserve all — only add missing                     |
| `AGENTS.md`                   | Preserve — treat as authoritative agent definitions (Codex mode: the finalizer mirrors only the generated block) |
| `.claude/skills/*/SKILL.md`   | Preserve all — only add missing                     |
| `.claude/commands/*.md`       | Preserve all — only add missing                     |
| `.claude/hooks/*`             | Preserve all — only add missing                     |
| `.mcp.json`                   | Merge — add missing servers, preserve existing      |

### 0b. Extract Project Metadata

Read whichever of these exist. Extract: project purpose, tech stack, build/test/lint/dev commands, conventions.

**Build/dependency files:**
`package.json`, `pyproject.toml`, `setup.py`, `Cargo.toml`, `go.mod`, `build.gradle.kts`, `build.gradle`,
`settings.gradle.kts`, `pom.xml`, `Makefile`, `Justfile`, `Taskfile.yml`, `CMakeLists.txt`, `Gemfile`

**Documentation:**
`README.md`, `README.mdx`, `docs/README.*`, `CONTRIBUTING.md`

**CI/CD** (authoritative source for lint/test/build commands):
`.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml`, `bitbucket-pipelines.yml`

**Config files:**
`tsconfig.json`, `.eslintrc*`, `eslint.config.*`, `biome.json`, `.prettierrc*`, `rustfmt.toml`,
`.editorconfig`, `vitest.config.*`, `jest.config.*`, `cypress.config.*`, `playwright.config.*`,
`pytest.ini`, `conftest.py`, `.env.example`, `.env.sample`, `.env.template`, `.env.local.example`,
`docker-compose.yml`, `Dockerfile`,
`nx.json`, `turbo.json`, `lerna.json`, `gradle/libs.versions.toml`

Resolve `AI_EVAL_ENABLED` here in Phase 0 so every later artifact can use it. Set it
from explicit config or paired positive repository evidence: one executable
model-inference call site plus one repo-owned
prompt, model configuration, evaluation case, or output schema used by that path.
Explicit `"aiEvaluation": false` disables inference. A generic dependency name, unused
SDK import, prose mention, or lockfile model name alone is not evidence. Record both
repo-relative evidence paths and never hardcode a model vendor.

**Read the safe `.env` examples here, in Phase 0, or not at all.** `.env.example`,
`.env.sample`, `.env.template`, and `.env.local.example` are secret-free and the
unattended policy allows them, but Phase 1a's generated `Read(/.env*)` and
`Read(/**/.env*)` denies match those names too. From the moment that file lands, no tool
in the session can read them — a Bash reader no more than native Read. A run that defers
them to artifact authoring loses them as a source. `discovery-checkpoint.sh` enforces this:
every safe example at the root, or tracked at any depth, needs one line in the report's
`Safe env examples:` section. `  <path>: read` requires a matching `  <path> -> ...` line under
`Sources used:`; `  <path>: denied` is accepted only when `permissions.deny` in
`.claude/settings.json` or `.claude/settings.local.json` already covers the path (the `**/.env*`
form for a nested example), which is the case on every rerun of an onboarded project. Omit the section only when no safe example exists.

Record the project's **documented gates** from those sources. Onboarding never runs them: it
writes them down for the agents it sets up and tells the person onboarding what it found. A command
is eligible only when a repository-controlled source explicitly tells contributors or CI to run it:

1. CI workflow command;
2. package/task/build script invoked by CI or documented for validation;
3. exact command in `README*`, `CONTRIBUTING.md`, or an existing project instruction file.

File type, installed executable, config-file presence, or a tool being customary for the
language is not evidence that it is a gate. For example, shell scripts do not imply `shellcheck`,
and Python files do not imply `ruff` or `pytest`. If no lint, typecheck, format, test, or build
command is documented, record that category as absent and omit it from settings, generated
workflows, and dependency warnings. Never invent a new gate during onboarding. A project that
documents no gates at all is onboarded as it is: hand the renderer an empty commands file.

**Record each gate as the exact string its source prescribes.** Do not normalize
package-manager invocation style, respell it, wrap it, or add a directory change to make it
runnable from the repository root. Bare package-manager script forms (`pnpm lint`,
`yarn typecheck`, `bun test:run`) are valid entries; if CI or docs say `pnpm lint`, keep it
`pnpm lint`, and do not rewrite `pnpm run lint` to a bare form or the reverse. Where a project
documents its gates under a directory heading (`api/: pnpm test:node`), record what it documents
and let the agents read the heading: how a project runs its tests is the project's business, and
onboarding does not change it. The same verbatim rule governs the generated `Bash(<command>)`
permission, which must match the recorded command byte for byte.

The renderer refuses to record only what would make an unsafe allow rule for the agents onboarding
sets up: shell composition, destructive or external operations, unsupported command forms, and a
`--prefix` directory outside the repository. A documented command composed with shell operators
(`cd web && npm run lint`) cannot be recorded, so name it in the generated `/validate` guidance
instead of dropping it silently, and prefer the `npm --prefix <dir> run <script>` spelling of the
same gate when the project itself documents that form.

**Undeclared gates are machine-detected.** The renderer independently derives the eligible gates
from the repository's root package scripts **and from every nested `package.json` git tracks**, and
from its CI configuration, classifying each by the same vocabulary (`install:*`, `build`, `*:e2e`
and watch scripts are excluded), and lists any that the recorded gates omit under `Undeclared
gates`. This is a disclosure, not a block: the run completes, the report says onboarding did not
run them and makes no claim about them, and the section mints no `Next:` entry. Record a gate the
project documents; an eligible script it does not document may stay in that list for the reader to
dismiss.

**Never run a project command during onboarding.** Not through the renderer, and not yourself:
do not run a project's tests, builds, linters or formatters, and do not execute its tools to probe
them (`./.venv/bin/<tool> --version` included). Establish what exists with read-only probes such as
`ls -l ./.venv/bin/<tool>`, which discovery already permits.

### 0c. Identify Stack

From the files above, classify:

| Dimension         | Examples                                                                             |
| ----------------- | ------------------------------------------------------------------------------------ |
| Language(s)       | TypeScript, Python, Rust, Go, Kotlin, Java, Swift, C++, Ruby                         |
| Framework(s)      | React, Next.js, Express, FastAPI, Django, Spring Boot, Ktor, Actix, Rails            |
| Package manager   | yarn, pnpm, npm, pip, poetry, uv, cargo, go mod, gradle, maven, bundler              |
| Monorepo tool     | nx, turbo, lerna, cargo workspace, go workspace, gradle multi-project                |
| Test framework(s) | jest, vitest, cypress, playwright, pytest, cargo test, go test, JUnit, Kotest, RSpec |
| Linter/formatter  | eslint, biome, prettier, ruff, black, rustfmt, ktlint, detekt, spotless, rubocop     |
| CI/CD             | GitHub Actions, GitLab CI, Jenkins, CircleCI                                         |
| Base branch       | main or master (check `git show-ref`)                                                |
| Extras            | GraphQL, Docker, Kubernetes, Terraform, CDK, Storybook                               |

### 0d. Print Discovery Report

Before printing the report, capture `git status --short --untracked-files=all` as the pre-onboarding
worktree baseline. Keep those paths separate from files created or changed by this
run. `/onboard` MUST NOT switch branches or carry a dirty worktree onto another
branch. If a branch policy blocks required tracked-file writes, stop and ask the user
to choose the branch; do not switch automatically. Do not enter a worktree to get past it
either (`EnterWorktree`, `git worktree add`): the completion renderer cannot run for a
checkout other than the session's start directory, so the run strands its own report. Offer
two choices: create a branch in this checkout, or start a new session from inside a worktree.

If that baseline shows a required manifest path deleted in the index or worktree, do
not invoke the checkpoint: the guard denies `discovery-checkpoint.sh` for this
condition. Print the blocked protocol with each deleted required path under `Failed`,
`Next:` naming `git restore -- <paths>` (or committing the deletion), and stop.

```
=== Workspace Discovery Report ===

Project: <name> (<languages>)
Stack: <framework> + <pkg-manager> + <test-framework>
Monorepo: <yes/no> (<tool>)
Base branch: <main/master>
CI: <system>

Existing setup:
  CLAUDE.md ............. <found — will merge / not found — will create>
  .claude/settings.json . <found — will merge / not found — will create>
  .claude/agents/ ....... <N found — will add M missing>
  .claude/skills/ ....... <N found — will add M missing>
  .claude/commands/ ..... <N found — will add M missing>
  .mcp.json ............. <found — will merge only if enabled / not found — report only unless enabled>

Sources used:
  <file> -> <what was extracted>

Preserved doc freshness:
  CLAUDE.md: <consistent / contradicts: <the observed contradiction>>
  artifacts/architecture.md: <consistent / contradicts: <the observed contradiction>>
  artifacts/infrastructure.md: <consistent / contradicts: <the observed contradiction>>

Safe env examples:
  <path>: <read / denied>

=== End Workspace Discovery Report ===
```

**Emission gate — the report must be visible in the session before any manifest write.**
The completion guard scans the session transcript for the emitted markers at the FIRST
manifest `Edit`/`Write` and at Stop, and it accepts EITHER visible form:

1. the report block as assistant message text (preferred when your harness produces text
   parts — put the complete block, opening marker through closing marker, in the TEXT of
   the same message whose tool call performs the gate-exempt native `Write` of
   `.launch-control-onboard/discovery-report.txt`, so the turn continues); or
2. the installed `discovery-checkpoint.sh` invocation's tool result — the script re-emits
   the full report on stdout, which the session renders visibly. Running the mandatory
   checkpoint therefore satisfies the gate even in model modes that produce tool-only
   messages with no text parts.

Do NOT send the report as a text-only message with no tool call: a text-only assistant
message ends your turn and stalls the run waiting for the user. If a write is denied by
this gate, run the checkpoint (or re-run it after any report re-save) and retry the write
in your next message — after at most two denies the write gate stands down and the
Stop-hook backstop alone enforces the requirement.

Emit this complete block as a standalone assistant progress message before the dependency
preflight and before any native `Edit` or `Write`. Do not collapse it into internal
reasoning, defer it until the completion report, or replace it with a shorter summary.
As the only pre-checkpoint write, use native `Write` to save that emitted block
**verbatim** to `.launch-control-onboard/discovery-report.txt`, including the exact opening and
closing markers. The lifecycle guard allows only this control file before attestation.
Immediately afterward invoke the installed `@scripts/discovery-checkpoint.sh` by its literal
absolute path in one simple Bash tool call with no arguments. The script validates every
required field, hashes the report, binds that hash to its checkpoint marker, and re-emits the
same report visibly. The lifecycle guard binds the same hash to this session and blocks every
manifest `Edit`/`Write` when the report is missing, malformed, symlinked, changed after the
checkpoint, or mismatched with the marker. Calling the checkpoint without first emitting and
saving the report is a protocol violation.

Once the checkpoint exists (which unblocks `.launch-control-onboard/` writes) and before any
manifest `Edit`/`Write`, capture a pre-write hash inventory of every preserve-candidate
file — each path the run promises to leave untouched: existing manifest paths plus every
pre-existing untracked baseline path — into `.launch-control-onboard/preserve-hashes.txt`, one
line per file in `shasum -a 256` output format (`<sha256><two spaces><path>`), so the renderer
can content-verify each `PRESERVED` and `Untouched pre-existing` claim instead of checking
existence alone. The strength of that check depends on the mode. When the frontmatter hooks are
registered the lifecycle guard captures its own `preserve-hashes.guard.txt` at the trusted
pre-write moment — the same instant it snapshots the manifest inventory — and the renderer
verifies against that guard copy, so the content claim is hook-attested regardless of when the
assistant wrote its own file. In degraded mode no hook runs: the assistant-supplied file is the
only source and its capture timing is honor-system, so the hashes MUST be taken before the first
write for the claim to hold.

**Pre-existing docs are schema-exempt.** If `artifacts/architecture.md` or
`artifacts/infrastructure.md` already exists as user-authored content (not generated by this
run), do not require it to match the generated heading + Mermaid schema. Note it in the
Discovery Report `Existing setup` as `found — user-owned, schema-exempt` and preserve it. Only a
document this run generates via `docs-create` must satisfy the schema; the renderer hard-fails
that case and records a non-blocking warning for a user-owned doc that diverges. This preflight
runs before any write so a divergent user doc never surfaces only as a post-write BLOCKED.

**Preserved documentation must be compared here, before the checkpoint.** The report's
`Preserved doc freshness:` section carries one `  <path>: consistent` or
`  <path>: contradicts: <the observed contradiction>` line for each of `CLAUDE.md`,
`artifacts/architecture.md`, and `artifacts/infrastructure.md` that exists as a regular file,
and exactly the line `  (no preserved documentation)` when none of them do. Compare every
material Phase 0 fact the generated workspace will use — declared commands, layout, lifecycle,
and security boundaries — against what each document asserts. For `CLAUDE.md` the comparison is
over the prose OUTSIDE the generated block: the block this run writes is not evidence about
itself, and a file whose surrounding prose denies a command the block declares ships
self-contradictory. Do not infer staleness from a date or a changed HEAD.

`discovery-checkpoint.sh` validates that accounting and exits non-zero when any line reads
`contradicts`, which leaves the lifecycle guard's first-write denial in place — so this decision
costs a minute and writes nothing, instead of surfacing after the workspace is already written.
The script cannot judge agreement, only that every comparable document was accounted for; the
judgement is yours and a blanket `consistent` to clear the gate is a false attestation. When it
exits non-zero it prints every contradicting path and their count: emit the blocked protocol with
exactly those paths under `Failed (<N>)`, one per line, `Reason:` stating the contradictions the
freshness lines recorded, and `Next:` naming `docs-update` over those documents followed by a
rerun. Never name only the first contradiction — a block that reports one of two stale surfaces
buys a second full run to find the other.

If `--dry-run`, continue through the required dependency preflight in read-only mode,
print the complete planned artifact/overlay manifest, and then stop. Do not create a
temporary ledger in the project, invoke documentation generators, or write any file.
Build the preview from the same four mutually exclusive ledger statuses used by Phase 5:
each planned path or feature appears exactly once. Never list a disabled overlay such as
hooks or MCP under `Created`; classify it only under `Skipped`.

### 0e. Required dependency preflight

This preflight applies to every normal `/onboard` run and to `--launch-control` maintenance.
It MUST complete after discovery and before any project files are written.

1. Check the skills available in the current session for the `superpowers:*` namespace.
2. If availability is unclear and the `claude` CLI exists, run `claude plugin list` and
   confirm that an enabled official or Obra Superpowers provider is present.
3. If the plugin is unavailable, explain that Superpowers is a required Launch Control
   dependency and stop the run without writing partial onboarding output. Then provide:

   ```bash
   claude plugin marketplace add anthropics/claude-plugins-official
   claude plugin install superpowers@claude-plugins-official
   ```

   Tell the user to restart Claude Code and rerun the original command. Never install a
   user-global plugin automatically from `/onboard`.

For `--dry-run`, report `dependencies: ready` or the observed missing provider without
failing or writing. Every writing mode fails before partial project output when the
provider is unavailable.

For the autonomy opt-in, preflight Python 3.9+ and record exact commands and working directories
from the recorded gates, plus operator-selected bounded timeouts and nonempty
task acceptance evidence names. The renderer binds the command set; activation pins
the full config, including timeouts. An
unexpressible working-directory command blocks the opt-in; never drop it or replace
it with an inferred framework check. Reconcile existing verifiers before writes.
