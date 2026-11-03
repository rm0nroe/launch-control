# Completion Report and Ledgers

The full semantics of the completion gate: the gates a project documents and how they are
recorded and disclosed (never run), symlinked manifest paths, the four ledger statuses
(CREATED/MERGED/PRESERVED/SKIPPED), and what does and doesn't block. SKILL.md's Phase 5
states the flow (build the ledger, call the renderer, treat its output as the completion
gate); read this for how to classify any result the renderer produces.

## Contents

- [Recorded gates](#5a-recorded-gates)
- [Gate disclosure](#gate-disclosure)
- [Ledger ownership and cross-checks](#ledger-ownership-and-cross-checks)
- [Blocked protocol](#blocked-protocol)
- [Completion report protocol](#completion-report-protocol)

Phase 5 runs for every normal onboarding and for `--launch-control` maintenance. No mode may
finish immediately after writing its artifacts.

### 5a. Recorded gates

**Onboarding never runs a project's own commands.** It does not test, build, lint, format or
otherwise execute anything the project owns, and it has no say over how the project is tested.
What it does with a project's gates is record them for the agents it sets up and tell the person
onboarding what it found.

Before building or printing any completion report, write the gates the project documents (CI
configuration, package scripts, `README`, `CLAUDE.md`, `AGENTS.md`) as one exact command per line
under `.launch-control-onboard/`. An empty file is valid: a project that documents no gates is
onboarded as it is. Pass the file to the installed renderer finalizer as its
`VALIDATION_COMMANDS_FILE` argument. The finalizer **executes none of them**. It checks that each
recorded gate is safe to record, because every recorded gate becomes an exact `Bash(<command>)`
allow rule for the agents onboarding sets up, then reports what was recorded:
`validation: not run (<N> documented gates; onboarding never runs a project's own commands)`.

Record each gate as the exact string its source prescribes. Do not respell it, wrap it, or add a
directory change to make it runnable from the repository root: where a project documents a gate
under a directory heading (`api/: pnpm test:node`), record what the project documents and let the
agents read the heading. The renderer rejects, before recording, only what would make an unsafe
allow rule: shell composition, destructive or external operations, unsupported command forms, and
a `--prefix` directory outside the repository. A missing generated permission never blocks.

## Gate disclosure

Anything about the project's gates that looks off is a note for the person onboarding. It never
fails the run, blocks it, or becomes a `Next:` to-do for the project.

**Documented gates.** The recorded gates, one bare command per line. The `validation` check line
states once that none of them ran.

**Undeclared gates.** An eligible package script, or a gate derived from the project's CI
configuration, that the recorded set does not list, grouped under the source it was derived
from (`package.json`, `<dir>/package.json`, `CI configuration`). Disclosure only: onboarding makes no claim
about it, mints no `Next:` entry, and never refuses to finish over a recorded set that differs
from the one it derives.

**Symlinked manifest paths.** A required manifest path whose ancestor is a symlink resolves to
a file onboarding does not own. The guard pins it `PRESERVED` before the first write and denies
every write to it, so it appears under `Preserved` like any other untouched path — which alone
would leave a reader unable to tell why a path onboarding was asked to generate came back
unchanged. A ledger row cannot carry the reason: a trailing ` (...)` on a path line is rejected
outright. The renderer therefore lists each one under a `Symlinked manifest paths (N)` section
as `<manifest path> -- resolves to <target>`. This is a disclosure, not a block and not a
remedy: onboarding does not change repository layout to claim a path, and never proposes that
the user delete the link.

That is a disclosure rule, not a tolerance rule. Never present an `AskUserQuestion`, or any other
prompt, offering to run, accept, downgrade or hide a project's gates: onboarding does not run them.

What still blocks is what belongs to this run rather than to the project:

- **Unsafe recorded gates** — a command outside the supported forms, composed with shell
  metacharacters, not read-only or repository-local, or naming a `--prefix` directory outside the
  repository. The run re-records the gate. A missing generated permission is not in this class and
  never blocks; see the `PRESERVED` `.claude/settings.json` case above.
- **Ledger or inventory dishonesty, a tracked file the run changed outside its declared writes,
  and any claim the renderer cannot verify** — because there the report itself would be false or
  the run damaged something.

For placeholder auditing, never use a blanket search for `{{`. Generated guidance may
legitimately discuss double-brace syntax. Search only for actual unresolved onboard
tokens: `DETECTED_*` placeholders and `if`/`unless`/`each` template control markers.
The repository validator performs this canonical check; do not add a second ad hoc grep.

Audit `.claude/agents/inspector.md` as a required generated artifact. It must contain
`## Project-specific review lens`, at least two bullets beneath that heading, and no
unresolved `DETECTED_REVIEW_LENS` token. Every accepted bullet must end with exactly one
backticked repository-relative path in the shape `Evidence: `<path>`.`; multiple evidence
paths in one bullet are invalid. The bundled renderer performs the same check and refuses
completion if a reviewer **this run wrote** is generic, unresolved, or ambiguously sourced.

That audit — and the matching content rules over the `project-code-review` guidance surfaces
and the generated Launch skill — is scoped to files the ledger records as `CREATED` or
`MERGED`. A repository that already carries its own `.claude/` agents or skills has every one
of them `PRESERVED` (see the preservation rule above), so the run neither wrote them nor may
rewrite them; failing over their shape would leave `BLOCKED` as the only exit, with no rerun
able to satisfy it — the refusal is unsatisfiable, not merely expensive. A preserved artifacts
doc or guidance surface produces a `Doc warnings` row instead, phrased as
`<path>: <what is missing and why it matters>; <how to fix>`. A preserved `inspector.md` is
not judged at all: the review lens heading is the template's schema, and a hand-written reviewer
carries its own project rules under its own headings. Do not "fix" a preserved artifact to clear
a warning.

If a generated-artifact audit fails, print the blocked protocol with the exact failing path and
stop — a defective artifact is this run's own output. A default run reports
`validation: not run (<N> documented gates; ...)` and `Next: none` unless another finding mints a
`Next:` entry.

## Ledger Ownership and Cross-checks

Maintain four newline-delimited path ledgers during the run: `CREATED`, `MERGED`,
`SKIPPED`, and `PRESERVED`. Their meanings are exact:

- `CREATED` — absent before the run and a regular file after it;
- `MERGED` — a regular file existed before and its content hash or executable state changed;
- `PRESERVED` — a manifest-managed path existed before and its type, content hash, and
  executable state are identical after the run;
- `SKIPPED` — an optional manifest path was absent before and remains absent after.

`PRESERVED` covers only files onboarding manages (manifest paths). Report the run's
pre-existing untracked baseline paths that are **not** in the manifest — files onboarding
never touches, such as unrelated docs, assets, or tooling dirs caught by the Phase 0
`git status` baseline — in a separate `Untouched pre-existing (N)` section, not folded
into `Preserved`. A dirty baseline path that is itself a manifest path stays a
protected subset of `PRESERVED`; only non-manifest baseline paths move to
`Untouched pre-existing`.
The secret boundary this run generates takes effect the moment `.claude/settings.json` is
written, so a baseline path it protects — a tracked, dirty `.env` is the common case —
becomes unreadable to the renderer for the rest of the run. Unreadable is not changed: the
renderer records such a path as `protected`, keeps it in its normal baseline section, and
additionally lists it under `Protected, content unverified (N)` stating that the content was
never read or compared. That section is a disclosure, not a failure, and never a reason to
weaken the generated boundary, to re-read the path, or to ask the user to untrack a
committed secret before onboarding may run.
Do NOT hand-list non-manifest baseline paths in the ledger file: the renderer derives
those `Untouched pre-existing` rows itself from the Phase 0 baseline captures and
content-verifies them, so the ledger you write contains ONLY manifest paths under the
four statuses above. A tracked file this run did not modify (an untouched `AGENTS.md`,
`README.md`, or similar) belongs in NEITHER the ledger nor the baseline — listing one
fails the render with "ledger path is absent from the pre-run inventory".
`AGENTS.md` is never written by the model (user-authoritative, policy-denied). It
appears in run accounting only when it was already dirty in the Phase 0 baseline — then
it is baseline-derived like any other non-manifest baseline path. In Codex mode the trusted
finalizer mirrors the generated block into it after verification and lists it under
`Codex artifacts`; otherwise a stale onboard marker block inside it is a reported
follow-up finding, never a write.
Both sections are content-verified against `.launch-control-onboard/preserve-hashes.txt`.
Populate the ledgers when each action occurs; do not reconstruct a
narrative from memory at the end. Before printing, sort and deduplicate each ledger,
then compare their union with the guard-captured pre-write inventory, the post-run filesystem, and
`git status --short --untracked-files=all` against
the Phase 0 baseline. Reject missing or extra status records, status lies, truncated
paths, and nonexistent completed paths.
Before invoking the renderer, use native Write to place the finalized path ledger, the
newline-delimited validation commands, and newline-delimited required paths and baseline dirty
paths under the fixed, sandbox-writable `.launch-control-onboard/` directory in the project
root; export the required and baseline files as `ONBOARD_REQUIRED_PATHS_FILE` and
`ONBOARD_BASELINE_PATHS_FILE`, and pass the validation commands file as the renderer's
`VALIDATION_COMMANDS_FILE` argument. The renderer executes none of the commands. It derives
the live branch itself, rejects caller metadata that differs, derives the
`not run (<N> documented gates; ...)` summary from the recorded file, rejects any duplicate or
malformed entry,
enforces one status per path, confirms every required path exists and is not
skipped, and confirms every baseline dirty manifest path is preserved while reporting
non-manifest baseline paths under `Untouched pre-existing`. It rejects ledger inputs
outside that directory; when the Stop hook is registered, after the exact renderer output
passes it the completion guard removes `.launch-control-onboard/` and
`.git/launch-control-onboard-report.expected` with the other session proof. An honest
blocked protocol clears the same session state. If a run ends without either terminal —
for example after a malformed blocked message — `.launch-control-onboard/` and the
session-scoped guard files under Git metadata may remain; the next `/onboard` prompt
re-arms the guard and removes them automatically before discovery. Never remove them
manually during a run while a completion guard (Stop hook) is registered: the unattended
policy denies `rm`, and cleanup is the guard's job. In degraded mode, where no Stop hook
is registered, the renderer recognizes the validated checkpoint with no active lifecycle
marker and removes its control directory/proof only after printing the successful report.
Never invoke `--cleanup` after rendering. Do not use
ambient `mktemp`, `TMPDIR`, `/tmp`, or `/var/folders` for onboarding
validation or finalization.

Compute each heading count from its finalized newline-delimited ledger (for example,
`printf '%s\n' ... | sed '/^$/d' | wc -l`). Never estimate or type a count from memory.
Immediately before output, assert that each displayed count equals the number of path
lines in that section and that every path is printed in full. A failed assertion blocks
the completion report until corrected.

Counts are baseline-dependent, not universal acceptance constants. A `git archive`
baseline that already contains the required `.gitignore` rules correctly reports that
no merge occurred and classifies the unchanged existing file as `PRESERVED`, rather than
forcing `MERGED` or misclassifying it as skipped. `Preserved` includes every active
manifest path that existed and remained byte/state-identical, including a manifest path
that was dirty in the baseline; non-manifest pre-existing untracked baseline paths are
reported under `Untouched pre-existing` instead. QA fixtures that want to exercise a
merge or preservation case must seed that condition explicitly and assert the observed
ledger category.

## Blocked Protocol

If any required artifact write, parse, permission audit, or ledger assertion fails, do
not print `=== Workspace Setup Complete ===` and do not classify missing required files
as skipped. Print only this blocked protocol and stop:

```
=== Workspace Setup Blocked ===

Failed (<N>):
  <exact required path or validation command>

Reason:
  <concise observed failure>

Next:
  <one exact recovery command or action>

=== End Workspace Setup ===
```

The blocked protocol is byte-exact and machine-verified. The entire final message is
the protocol: the first byte of the response MUST be the first `=` of
`=== Workspace Setup Blocked ===`, and the last line MUST be exactly
`=== End Workspace Setup ===` with nothing after it. Never surround it with triple
backticks, indent it as a code block, quote it, or label it as a report. Line 2 is
blank; line 3 is exactly `Failed (<N>):` with the real positive count; each `Failed`
item is one line indented exactly two spaces containing one exact required path or
validation command and no prose. Then one blank line, `Reason:` alone on its line, and
exactly one two-space-indented line stating the observed failure; one blank line,
`Next:` alone on its line, and exactly one two-space-indented line with one exact
recovery command or action; one blank line, then the closing marker. Any deviation —
wrapper, preface, extra blank line, multi-line Reason or Next, or an unindented item —
is rejected by the Stop guard as malformed.

Every `Failed` item is a report of machine output too, and the same rule binds it. List only what
actually refused the run. Name the required path or the check the renderer's own diagnostic named.

`Reason:` and `Next:` are reports of machine output, not analysis of it. State only the
failure the tooling actually emitted. Do not name a file, function, or mechanism as the cause
unless the renderer's own diagnostic named it. If you did not observe which code triggered the
failure, say what was refused, not who refused it.

When the renderer emits a `blocked-next:` line, that text is the recovery: copy it verbatim
as the `Next:` line. The Stop guard compares them and rejects a rewrite.

## Completion Report Protocol

The completion report is a compact protocol, not a prose summary:

- print one exact path per line, with no descriptions and no brace compression;
- use canonical paths for optional artifacts even when absent:
  `.claude/skills/launch/SKILL.md`, `.claude/hooks/skill-eval.sh`, and `.mcp.json`;
  never emit the aliases `launch`, `hooks`, or `MCP`; an existing artifact is
  `CREATED`, `MERGED`, or `PRESERVED`, never `SKIPPED`;
- print the item count in each section heading;
- list a dirty manifest path under `Preserved`, and every non-manifest pre-existing
  untracked baseline path under `Untouched pre-existing`;
- derive branch and hook values from live Git state and the final parsed settings; the
  renderer independently derives `enabled` only from the canonical executable plus its exact
  settings registration, `preserved` from other retained hook state, and `absent` from no hook
  state;
- report a missing dependency only after its exact check fails;
- report validation from commands executed during this run, never from a suggested follow-up;
- omit discovery sources because Phase 0 already reported them;
- do not add commentary, explanations, memory updates, or "notes beyond the report";
- after printing the closing marker, output nothing else.

For a default run without additional flags, the ledger MUST include
`.claude/skills/launch/SKILL.md` under `CREATED`, `MERGED`, or `PRESERVED` as observed,
and account for absent MCP and hooks under `SKIPPED`. When the project declares no fix or
format command — per the `/fix` eligibility test in Phase 2c, which reads declarations and
never a linter's capabilities — `.claude/commands/fix.md` is accounted for under `SKIPPED`
and is never written: do not generate a placeholder, explanatory, or otherwise no-op `/fix`
command. The renderer enforces this structurally — a `fix.md` reported as `CREATED` or
`MERGED` must carry at least one `Bash(` entry on its `allowed-tools:` line — but that check
only rejects a stub, so it cannot substitute for the eligibility test: a command built by
appending `--fix` to an undeclared lint script passes it and is still wrong.
`testing-patterns` is still created from the recorded
gates when no unit-test framework exists.

Do not compose the final report manually. Write a tab-separated temporary ledger with
one `CREATED`, `MERGED`, `SKIPPED`, or `PRESERVED` record per line. Invoke the installed
renderer in one simple Bash tool call. Use literal absolute paths for the installed
renderer and every `.launch-control-onboard/` control file, plus the literal branch already
captured during discovery. Do not use a preliminary `renderer=...` assignment, a separate
`test -x`, command substitution, a line continuation, or a relative control-file path.
The unattended policy verifies the executable renderer path, live branch, and complete
argument shape before allowing the call.

Before this invocation, mark every task created by this onboarding run `completed`.
The renderer is the terminal operation: make no later `TaskCreate`, `TaskUpdate`,
`Edit`, or `Write` call. Task lifecycle hooks invalidate proof after any such task
mutation, so a late Phase 5 closure cannot accompany a successful completion report.

```bash
ONBOARD_REQUIRED_PATHS_FILE="/absolute/repo/.launch-control-onboard/required-paths.txt" ONBOARD_BASELINE_PATHS_FILE="/absolute/repo/.launch-control-onboard/baseline-paths.txt" "/absolute/claude-config/skills/onboard/scripts/render-report.sh" "/absolute/repo/.launch-control-onboard/ledger.tsv" "literal-current-branch" "valid-or-not-generated" "absent-preserved-or-enabled" "ready-or-missing" "/absolute/repo/.launch-control-onboard/validation-commands.txt" none complete
```

`$validation_commands_file` is the `.launch-control-onboard/` file built above, holding one
exact command per line and no caller-authored statuses. Do not substitute
`@scripts/render-report.sh` as a literal shell path and do not recreate the renderer in
prose or Markdown. Replace every descriptive placeholder in the command shape with the
literal observed value; do not pass the placeholder text itself. Pass the validation
commands file to the installed
renderer once and return that script's stdout verbatim as the entire
response: no preface, Markdown fence, timing note, or follow-up prose. If the renderer
fails, use the blocked protocol instead of a completion report.

**Once means once.** A render that exits zero is the run's only report, and the lifecycle
guard refuses a second one while its proof stands. The renderer is not a preview: it
re-verifies the whole workspace, so a needless repeat repeats that work and risks a duplicate
report that discloses neither the repeat nor anything it changed. Read the report before you decide anything about it, because
it carries facts you cannot get from the render call, and reconcile any contradiction with
what you said earlier in conversation, not with a second render: the report is the record,
and prose you have already sent cannot be revised by re-running the renderer. A retry is
still allowed after a render that was blocked or failed, and a re-render is required after
any further Edit, Write, or task change, because those invalidate the proof.

The first byte of the final response MUST be the first `=` in
`=== Workspace Setup Complete ===`, and the final byte MUST be the last newline after
`=== End Workspace Setup ===`. Never surround the renderer output with triple backticks,
indent it as a code block, quote it, or label it as a report.

```
=== Workspace Setup Complete ===

Created (<N>):
  <exact path>

Merged (<N>):
  <exact path>

Skipped (<N>):
  <exact path or feature name>

Preserved (<N>):
  <exact managed manifest path, including a dirty manifest path>

Untouched pre-existing (<N>):
  <exact non-manifest pre-existing untracked baseline path>

New untracked paths (<N>):
  <exact new untracked path that appeared in the repository during the run, unaccounted by the ledger>
  Counted from git-visible untracked paths; paths the project gitignores are not counted
  here, so the run may have created more than this number shows.

Doc warnings (<N>):
  <path>: <what is missing and why it matters>; <how to fix>

Protected, content unverified (<N>):
  <exact baseline path the generated secret boundary hides from this run>
  The generated secret boundary denies this run read access, so these paths are
  reported unchanged by status only; their content was never read or compared.

Undeclared gates (<N>):
  package.json:
    <eligible root package script the recorded gates omit>
  <dir>/package.json:
    npm --prefix <dir> run <script>
  CI configuration:
    <gate derived from CI>
  Onboarding did not run these and makes no claim about them.

Documented gates (<N>):
  <exact recorded command>

Checks:
  worktree-accounting: ledger, manifest, and run-start baseline only -- a git-visible foreign path created during the run is named under New untracked paths; a harness-owned local file appears in no section above
  branch: <current branch>
  permission-mode: <none recorded | <recorded mode, e.g. default or auto> | bypassPermissions -- ask-gates were denied, not asked>
  claude-md-provenance: <guard-attested -- prospective block written before CLAUDE.md | guard-attested -- CLAUDE.md unwritten this run | no write order recorded by the completion guard | not applicable -- this run makes no CLAUDE.md claim>
  settings-json: <valid | not generated>
  hooks: <absent | preserved | enabled>
  dependencies: <ready | missing: exact executable name>
  validation: not run (<N> documented gate[s]; onboarding never runs a project's own commands)

Next:
  none

Visual report: file://<absolute git dir>/launch-control/onboard-report.html

=== End Workspace Setup ===
```

The `Visual report` line links a self-contained HTML page the renderer draws from the finished
text above it, so the two never disagree; the text stays the record. The line is omitted when
the page cannot be written, and that never blocks the report. On a desktop the renderer also
opens the page; it does not when `LAUNCH_RUN_ID`, `CI`, or `LAUNCH_CONTROL_NO_OPEN` is set.

The `Untouched pre-existing`, `New untracked paths`, `Doc warnings`, `Documented gates`, and
`Undeclared gates` sections are each omitted when their count is zero. `Undeclared gates` mints no
`Next:` entry, and neither does `Documented gates`: they are notes for the person onboarding, so a
report whose only findings are gates ends `Next: none`. `New untracked paths` lists new untracked
paths that appeared in the repository during the run and that the ledger does not account for,
disclosed rather than blocked; a write into `.claude/` or `artifacts/` the ledger does not record
still blocks. Its count is derived from git-visible untracked paths, so paths the project itself
gitignores are counted by neither this group nor anything else, and the group says so: the number
never implies more coverage than the mechanism behind it has, exactly as the `permission-mode` and
`claude-md-provenance` lines state only what was recorded. `Doc warnings` lists any pre-existing
user-owned file that diverges from the schema this pack generates — an `artifacts/*.md` document
missing the sections agents read, or a guidance surface that does not name `project-code-review`. Every one is a non-blocking finding, because the
run did not write the file and may not rewrite it; only the same divergence in a file this run
generated hard-fails. The `validation` line states what was recorded and that nothing ran. It is
not a result: onboarding never runs a project's own commands, so it never reports a project's
checks as passed or failed.
