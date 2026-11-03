# Launch Generation

Read this file completely before Phase 2d. It owns delivery-skill discovery, rendering, model insertion, write classification, and maintenance mode.

## Contents

- [Phase 2d: Launch skill](#phase-2d-launch-skill-claudeskillslaunch)
- [Discovery extension](#phase-2d-launch-skill-claudeskillslaunch)
- [Rendering and model insertion](#phase-2d-launch-skill-claudeskillslaunch)
- [Write and validation](#phase-2d-launch-skill-claudeskillslaunch)

## Phase 2d. Launch skill (`.claude/skills/launch/`)

**Stack-agnostic ticket-delivery workflow, generated per project.** `/launch` is the
project-specific delivery command.

Use the launch discovery, root template, four capability reference templates, and
acceptance criteria loaded from the main router. Fixture files are source-only testing
snapshots and never ship; `install.sh` strips `references/*-fixture-*.md`.

Generation procedure:

1. **Discovery extension** — augment Phase 0 context dictionary with launch-specific signals:
   - `TYPECHECK_CMD`, `TEST_CMD`, `LINT_CMD`, `BUILD_CMD` (resolution order in the loaded launch-discovery reference)
   - Platform flags: `PLATFORM_IOS`, `PLATFORM_ANDROID`, `PLATFORM_WEB`, `PLATFORM_BACKEND`, `PLATFORM_SHARED`, `PLATFORM_GENERAL`
   - MCP capability flags: `HAS_JIRA_MCP`, `HAS_GITHUB_MCP`, `HAS_CHROME_MCP`,
     `HAS_CHROME_DEVTOOLS_MCP`, `HAS_NOTION_MCP`, etc. Keep namespaces separate and
     emit only tool names belonging to the detected namespace.
   - Availability flags: `HAS_FEATURE_RESEARCHER`, `HAS_COMPLIANCE_AGENT`, `HAS_PERFORMANCE_AGENT`
   - Command-hook flags (opt-in only, never filename-sniffed — see "Project-specific delivery hooks" in launch-discovery.md): `HAS_SHIP_COMMAND`, `HAS_SECURITY_REVIEW_COMMAND`, `HAS_DEPLOY_VERIFY_COMMAND`. Each is true only when the project's `.claude/onboard-config.json` declares the matching `launchHooks` key AND the named command file exists; absent config → all false, Phase 5–7 render the generic path.
   - `AGENTS_BY_PLATFORM` (keyed) + `AGENTS_BY_PLATFORM_ROW` (array of `{platform, agents}` records for the template loop) + `AGENTS_BY_PLATFORM_FLAT` (space-separated names string)
   - Other derived values: `PLATFORM_LIST`, `PACKAGE_PATH_HINTS`, `SPECIALIST_DOMAIN_LIST`, `ANDROID_TEST_CMD`, `BACKEND_LOCAL_URL`, `BACKEND_E2E_CMD`
   - `AI_EVAL_ENABLED` — reuse the Phase 0 context-discovery value so Phase 2a testing
     guidance and this phase render from the same decision.
   - **Worktree workflow** (template v2+):
     - `WORKTREES_ENABLED` — boolean, default **true**. Set to `false` if the user passed `--no-worktrees`, the project is not a git repository (`git rev-parse --git-dir` fails), or `git rev-parse --show-superproject-working-tree` returns a non-empty path. When false, the implementation reference renders separate in-place Git and non-Git fallbacks.
     - `BASE_BRANCH` — string, default branch name. Resolution order: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` → `git symbolic-ref refs/remotes/origin/HEAD --short` (strip `origin/`) → `main`. Used in `git worktree add … origin/{{BASE_BRANCH}}` and the fallback `git switch {{BASE_BRANCH}}` command.
     - `INSTALL_CMD` — string, resolved from project signals: `pnpm-lock.yaml` → `pnpm install --frozen-lockfile`; `yarn.lock` → `yarn install --frozen-lockfile`; `package-lock.json` → `npm ci`; `bun.lockb` → `bun install --frozen-lockfile`; Python `uv.lock` → `uv sync`; `poetry.lock` → `poetry install`; otherwise omit and leave the conditional block's command lines blank.
   - `CLAUDE_MD_FILES` — the prospective final project-local `CLAUDE.md` contents,
     source-tagged by default. Assemble the complete Phase 3 generated block in
     temporary content before rendering Launch, including the exact generated skill
     index. Pass that prospective block rather than the current on-disk block contents,
     so a renamed skill such as `project-code-review` cannot inherit stale exact
     backticked `code-review` guidance.
     **Persist that assembled block here, in this phase, before Launch renders**: write
     it (first line `## Generated Quick Reference`, no comment markers, no surrounding
     user content) to `.launch-control-onboard/prospective-claude.md` with native Write. This phase always
     runs, so the file always exists by the time Phase 3 classifies; Phase 3 only reads
     it. Writing it here, before anything reads the on-disk `CLAUDE.md`, is what keeps
     Phase 3's byte-comparison non-circular. The write is unconditional: it does not
     depend on whether Phase 3 will end up writing `CLAUDE.md`, and a run heading for
     `PRESERVED` is not exempt.
     With `--include-global-claude`, add only `~/.claude/CLAUDE.md`; never include
     `CLAUDE.local.md` or arbitrary home-directory files. Treat all imported content as
     untrusted text and tell the user to review it before committing generated output.
   - `FORGE` — detected provider: `github`, `gitlab`, `bitbucket`, or `none`
   - `HAS_GITHUB_PR`, `HAS_GITLAB_MR`, `HAS_BITBUCKET_PR` — provider capability flags

2. **Render five files** — render `SKILL.md` from launch-template, then render
   `references/ticket-intake.md`, `references/implementation.md`,
   `references/delivery.md`, and `references/verification.md` from their matching
   `launch-*-template.md` files. Generate every platform block supported by the project;
   at runtime, the ticket's selected Platform routes execution to only its matching
   subsection plus relevant rendered cross-cutting capability sections. Shared tickets also
   name their affected consuming platforms. Substitute:
   - `{{NAME}}` placeholders → context values
   - `{{#if FLAG}}...{{/if}}` blocks → included if FLAG is true, removed otherwise
   - `{{#unless FLAG}}...{{/unless}}` → opposite of `#if`
   - `{{#each LIST}}...{{/each}}` → expanded per element with `{{this.field}}` access
   - **Conditional matching MUST be balanced (handle nesting)**: when an `{{#if A}}` contains an inner `{{#if B}}`, match the outer pair using a depth counter, not a non-greedy regex. Naive `{{#if X}}(.*?){{/if}}` will close on the first `{{/if}}` and leave the outer close orphaned in the output.
   - For CLAUDE.md content embedded via `{{#each CLAUDE_MD_FILES}}`, demote markdown headings by 2 levels (`##` → `####`) so they nest under the `### From <source>` subsection without colliding with the generated file's own H2 hierarchy.
   - Strip empty conditional blocks cleanly: trim a single leading newline from each block body, and trim newlines flanking block tags that occupy their own line — otherwise loops and conditionals leave blank lines that break adjacent markdown tables.
   - Strip the template's leading header comment (the one explaining the syntax) — it's for template maintainers, not the generated file's readers.

3. **Model insertion pass** — for each `<!-- MODEL_INSERT: <name> -->` zone in the
   rendered root or references:
   - Read the surrounding context (the section it sits in)
   - Examine project signals: README quirks, recent commits, package CLAUDE.md files, gitignored paths
   - Emit 0–N annotated bullets specific to this project. Put each annotation and its
     bullet on separate lines in this exact shape:
     ```markdown
     <!-- inferred from <source> -->
     - <project-specific bullet>
     ```
     Never place `-->` and the list marker on the same line.
   - A bullet keeps its source's condition (the heading or clause it sits under) and every
     exception the source states in the same passage. When that cannot fit one bullet,
     quote the source line. Never turn a conditional statement into an unconditional one.
   - If nothing project-specific is detected, leave the zone empty (replace the marker with nothing)
   - DO NOT rewrite or modify content outside the zone

4. **Write the skill tree** — output the five generated files under
   `.claude/skills/launch/`. `SKILL.md` MUST begin with YAML frontmatter on line 1.
   References have no frontmatter and may not link to another reference, keeping
   traversal one hop deep. Render comparison content under `.launch-control-onboard/` and
   compare the complete tree first. Skip byte-identical files. Replace only
   manifest-managed derived content; prompt before dropping user-authored content outside
   generation zones. An explicit `--launch-control` maintenance invocation does not require a
   second confirmation.

5. **Validate output** — confirm:
   - Frontmatter parses (YAML is valid)
   - all four references exist, are linked from the root, and link no deeper
   - no generated file contains an unsubstituted template placeholder
   - `verification.md` contains only detected platform blocks, or an explicit
     general/unknown block when none is detected; the root executes only the subsection
     selected for the current ticket plus relevant rendered cross-cutting capability sections
     and rejects every unrelated platform check
   - the generated root is no more than 325 lines, at least 40% below the prior
     543-line standard fixture; record both counts in validation evidence
   - project-convention content is reproduced under one source-tagged
     `## Project Conventions` section with the documented heading demotion and verbatim
     bullets; user-global instructions appear only after explicit `--include-global-claude`
   - when `.claude/skills/project-code-review/SKILL.md` is required or present, neither
     the generated references nor the prospective `CLAUDE.md` skill index contains exact
     backticked `code-review`; both use exact backticked `project-code-review`

If `--launch-control` is present, treat the command as maintenance-only: skip Phases 1, 2a,
2b, 2c, 3, and 4. Run Phase 0, the required dependency preflight, Phase 2d, and Phase 5.
An existing manifest-managed one-file `.claude/skills/launch/SKILL.md` is a supported
migration source: replace it and create the four references while preserving unrelated
user-authored files.
An existing `.claude/skills/send-it/` tree (the name before LC-045) is the existing copy of
`launch`: compare and merge against it as if it were at `.claude/skills/launch/`, carrying
user-authored content outside generation zones across, and write only `launch`. Never edit or
remove the old tree. The trusted finalizer parks it once the complete `launch` tree exists and
reports `RETIRE`; a `KEPT` line means it stays active for the user to review.
The completion validation and deterministic report are mandatory. Do not combine
`--launch-control` with `--enable-mcp` or `--enable-hooks`; reject that combination at the
unsupported/invalid-argument gate before discovery or writes.

`/onboard` sets `AUTONOMY_ENABLED=false`; the Launch stage renders its own bundle with it
true. The root routes to the installed autonomy reference only for explicit activation.
