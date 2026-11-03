# Skills, Agents, and Commands

Read this file completely before Phases 2a through 2c. It owns generated artifacts, template resolution, reviewer evidence, and command eligibility.

## Contents

- [Phase 2: Generate Skills, Agents, Commands](#phase-2-generate-skills-agents-commands)
- [Template resolution and audits](#phase-2-generate-skills-agents-commands)
- [2a. Skills](#2a-skills-claudeskills)
- [2b. Agents](#2b-agents-claudeagents)
- [2c. Commands](#2c-commands-claudecommands)

## Phase 2: Generate Skills, Agents, Commands

This phase runs for every normal onboarding.

For each artifact: **check if it already exists. If yes, skip the write and record its
canonical path as `PRESERVED`. Never overwrite.** The trusted finalizer subsequently
refreshes unchanged released static checkpoint-save/-load/-list bundles using ownership
checks and retained backups. Do not perform those replacements with model-authored writes. `SKIPPED` is reserved for optional
canonical paths that are absent because the capability was not selected or detected.

Use detected commands (from Phase 0) to parameterize templates.
Use the artifact-templates reference loaded from the main router for full templates.

Before rendering, resolve every legacy `DETECTED_*` token used by the already-loaded
artifact-templates reference; never leave one in a generated file:

| Template token | Context value |
|---|---|
| `DETECTED_TEST_FRAMEWORK` | `TEST_FRAMEWORK` |
| `DETECTED_TEST_CMD` / `DETECTED_TEST_CMD_PREFIX` | `TEST_CMD` and its executable prefix |
| `DETECTED_TEST_FILE_PATTERN` | project-specific single-file test syntax, or omit the argument |
| `DETECTED_TEST_WATCH_CMD` | detected watch command, or omit the section |
| `DETECTED_TEST_COVERAGE_CMD` | detected coverage command, or omit the section |
| `DETECTED_LINT_CMD` / `DETECTED_LINT_CMD_PREFIX` | `LINT_CMD` and its executable prefix |
| `DETECTED_LINT_FIX_CMD` | detected safe lint/format fix command, or omit the command |
| `DETECTED_FORMAT_CMD` / `DETECTED_FORMAT_CMD_PREFIX` | detected formatter command and executable prefix |
| `DETECTED_TYPECHECK_CMD` / `DETECTED_TYPECHECK_CMD_PREFIX` | `TYPECHECK_CMD` and its executable prefix |
| `DETECTED_BUILD_CMD` / `DETECTED_BUILD_CMD_PREFIX` | `BUILD_CMD` and its executable prefix |
| `DETECTED_DEPENDENCY_CHECK_CMD` | exact read-only command used by the generated workflow to verify a required executable, or omit the permission and check |
| `DETECTED_PKG_RUN` | detected package-manager runner (`npm run`, `pnpm`, `yarn`, etc.) |
| `DETECTED_BASE_BRANCH` | `BASE_BRANCH` |
| `DETECTED_REVIEW_LENS` | at least two evidence-backed Markdown bullets derived from Phase 0 discovery |
| `DETECTED_AI_EVAL_GUIDANCE` | when `AI_EVAL_ENABLED`, the vendor-neutral block below; otherwise remove the line |

If a value cannot be detected, remove the affected command line or section rather
than emitting an empty command or a literal placeholder.

When AI evaluation is enabled, replace `DETECTED_AI_EVAL_GUIDANCE` with:

```markdown
## AI Evaluation
- Pin the versioned model, prompt, and configuration for each run.
- Keep deterministic policy and tool-authorization tests separate from probabilistic output scoring.
- Cover representative, negative, and abuse cases; record latency, cost, and escalation results.
- Name the human owner for subjective quality and risk acceptance.
```

Generated artifacts must not contain raw onboard template controls anywhere, including
inside examples, troubleshooting tables, or prose that describes template failures.
Refer to an "orphaned closing marker" or "unbalanced conditional" in plain language
instead of reproducing an `if`, `unless`, or `each` control token. Phase 5 treats every
literal control marker as unresolved generation state, regardless of narrative intent.

Build `DETECTED_REVIEW_LENS` from repository evidence, not generic review advice. It
MUST contain at least two bullets in this exact shape:

```markdown
- <project-specific review concern>. Evidence: `<repo-relative source or Phase 0 signal>`.
```

Cover both (1) a detected language, framework, runtime, or file-format failure mode and
(2) a repository-specific validation, delivery, security, or infrastructure boundary.
Use only sources read during Phase 0, and make each cited path directly support the
concern in that bullet. A catalog may support facts about its own entries only: for
example, `install/mcp.reference.json` can evidence MCP names or transports, but it cannot
evidence generated permission or secret-file rules. If a category genuinely
has no signal, make that absence explicit and cite `Phase 0 discovery`; do not invent a
stack or silently fall back to a generic reviewer. The generated `inspector` MUST
retain the heading `## Project-specific review lens` followed by those bullets.

After tailoring an artifact, compare every command in its workflow with its
`allowed-tools` or `tools` declaration. Every read-only command the workflow tells
Claude to run MUST have a matching narrow permission. For prerequisite checks that
need a child shell, allow only the exact command (for example,
`Bash(bash -c 'type -P jq')`); never add `Bash(bash:*)` or another shell wildcard.
Mutating commands must retain their normal confirmation boundary.

Do not treat an interactive shell function or `command -v` result alone as proof that
a child script can execute a dependency. The completion gate must run the actual
declared validation command in the same non-interactive form users will invoke. If the
command supplies its own bundled fallback (as Launch Control's validator does for ripgrep),
do not report the standalone binary as a missing dependency.

Perform the same reconciliation across `.claude/settings.json`: every generated exact
validation command must use the exact permission spelling above, and no command absent
from the recorded gates may appear. Parse the final JSON with the exact
read-only command `jq -e . .claude/settings.json`, then re-read every generated
frontmatter block before reporting completion. If either audit fails, repair the
generated artifact and repeat the audit; do not report a warning as if generation
succeeded.

The policy permits that parse repo-relative and as the absolute path to the same file;
`jq empty` is accepted in place of `jq -e .`. Any other spelling is denied. A denial is not
a completed audit and not a finding about the settings file — it says the command never ran,
so reissue it in a permitted spelling. The renderer's own `settings-json:` line does not
stand in for this audit: the renderer checks that the JSON parses, while this audit checks
that every generated permission matches a recorded gate and that no undeclared command
appears. Skipping it on the grounds that the renderer covers it reports an audit that was
never performed.

### 2a. Skills (`.claude/skills/`)

Generate if missing:

| Skill                  | Tailoring                                                                   |
| ---------------------- | --------------------------------------------------------------------------- |
| `testing-patterns`     | Adapt to the detected test framework; if none exists, adapt it to the recorded gates and explicitly state that there is no unit-test framework |
| `pr-workflow`          | Use detected lint/test/build commands and base branch                       |
| `project-code-review`  | Adapt checklist to detected language/framework without shadowing built-ins  |
| `feature-development`  | Use detected commands for validation steps                                  |
| `systematic-debugging` | Language-agnostic — works everywhere                                        |

Generate `checkpoint-save`, `checkpoint-load`, and `checkpoint-list` from the checkpoint-templates reference as well. They save and find state in `<project-root>/.claude_states/`; the home-directory location is read-only legacy fallback. Preserve existing project skills. Create the state directory only when saving the first checkpoint.

### 2b. Agents (`.claude/agents/`)

Generate if missing:

| Agent             | Model  | Purpose                                 |
| ----------------- | ------ | --------------------------------------- |
| `inspector`   | sonnet | Code review tailored to detected stack  |
| `dispatcher` | haiku  | Git operations (commits, branches, PRs) |

If `AGENTS.md` exists, read it first. Only add agents that have no equivalent.
Never write to `AGENTS.md`: it is a user-authoritative file outside the generated
manifest, and the write policy denies edits to it. In Codex mode the trusted finalizer
mirrors the verified `CLAUDE.md` generated block into it (created when absent, only the block
replaced or appended otherwise, a symlinked or uncommitted-edited file preserved), because
Codex reads `AGENTS.md` and not `CLAUDE.md`; that block is then current, not stale. Outside
Codex mode, if Phase 0 found a stale onboard
generated block inside it (outdated paths, renamed skills, superseded command
lists), do not attempt to edit it and do not promise to in the discovery report —
instead record the staleness as a follow-up finding. The discovery checkpoint script
appends a `STALE-AGENTS-CANDIDATE` block to its output whenever `AGENTS.md` contains an
onboard-generated block; on seeing it, read `AGENTS.md` and judge the block against
the current pack, even on a run that generates no agents (such as a pure-preserve rerun).
The renderer itself surfaces the finding: when `AGENTS.md` carries the generated block, the
final report includes a `Stale AGENTS.md` section and lists manual regeneration under
`Next:` — this is machine-emitted and needs no assistant-authored note; relay the rendered
report verbatim as always. This skill never creates generated sections without the
`## Generated Quick Reference` heading in any user-authoritative file.
When generating `inspector`, resolve `DETECTED_REVIEW_LENS` from Phase 0 evidence.
A generic reviewer without the required heading and two evidence-backed bullets is an
incomplete artifact, not a successful fallback. The bullet shape is enforced at write
time and again by the renderer, so write it exactly, here, without recalling it from
earlier in this document:

```markdown
## Project-specific review lens

- <project-specific review concern>. Evidence: `<repo-relative path>`.
- <second concern, different axis>. Evidence: `<repo-relative path>`.
```

Every bullet ends with one backticked repo-relative path in `Evidence: \`<path>\`.`
form — trailing period inside the line, nothing after the closing backtick but that
period. The path must exist and be canonical (no leading `/`, `./`, or any `..`
segment); the single non-path spelling accepted is `Phase 0 discovery`.

### 2c. Commands (`.claude/commands/`)

Generate if missing:

| Command     | Tailoring                                          |
| ----------- | -------------------------------------------------- |
| `/pr`       | Detected lint/test/typecheck commands, base branch |
| `/validate` | Commands from CI config or package scripts         |
| `/fix`      | A declared fix or format command — see the eligibility test below |
| `/status`   | Detected base branch                               |
| `/commit`   | Stack-agnostic conventional commits                |
| `/ticket`   | Detected commands + tracker; with `--no-worktrees`, outside Git, or in a submodule, step 2 is in-place `git switch -c <ticket-id>-<description>` |
| `/explore`  | Stack-agnostic                                     |

Generated project guidance and delivery artifacts MUST expose the installed CRISPY
chain exactly as:

`research-questions` → `research-codebase` → `design-doc` → `design-outline` →
`plan-write` → `plan-execute`

Describe the review checkpoint between authored stages: run `review-doc` against the current
artifact, resolve blocking findings, and only then advance. Do not shorten the chain by
starting at design or ending at plan creation.

#### `/fix` eligibility — a declaredness test, not a judgment

`/fix` is generated only when the project **declares** a fix or format command: a package
script, task-runner target, or config-declared command whose own definition already
contains a fix or format spelling (`--fix`, `lint:fix`, `format`, `fmt`, or a formatter
binary such as `prettier`, `ruff format`, `gofmt`). Read the declaration, not the tool's
capabilities.

Otherwise `/fix` is `SKIPPED` — **even when the detected linter is known to accept
`--fix`**. Never append `--fix`, `--write`, or any fix flag to a command the project did
not declare with it. Appending a flag invents a spelling the project never wrote, and
whether a linter "supports" one is a judgment that resolves differently between runs from
identical inputs, which is why this test reads a declaration instead.

Worked cases:

| Declared | `/fix` | Why |
|---|---|---|
| `"lint:fix": "eslint . --fix"` | generated | the declaration contains `--fix` |
| `"format": "prettier --write ."` | generated | the declaration is a formatter |
| `lint = "ruff check"` plus `format = "ruff format"` | generated | `format` is declared |
| `"lint": "next lint"`, no fix or format script | `SKIPPED` | `next lint -- --fix` would be invented |
| `"lint": "eslint ."`, no fix or format script | `SKIPPED` | eslint accepting `--fix` is not a declaration |
| no lint, format, or fix command at all | `SKIPPED` | nothing to run |

A repository whose only declared gate is a bare linter therefore gets no `/fix`, and the
generated `CLAUDE.md` says so rather than leaving its absence unexplained.
