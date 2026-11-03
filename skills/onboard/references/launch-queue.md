# Bounded task admission

`launch-queue.py` admits an explicitly selected set of tasks into prepared Launch
worktrees. It advances after the current worker exits successfully and the existing
runtime verifies `awaiting_review`. Publication requires the explicit restricted grant
below; the default stops at review. Deployment and source Done are not implemented by
this publisher. No recurring scheduler is installed.

Publication is Codex-only (decision D4). A manifest whose `platform` is not exactly `codex`,
including a missing or unrecognized value, never reaches the publisher: a verified
`awaiting_review` item records `publication: unsupported`, and a run that ends with every item
there reports outcome `review_ready_publication_unsupported` instead of `awaiting_review`.

A Codex queue without `delivery` stops at `awaiting_review` on the worker's own verification
receipt; the controller does not re-run the checks there, as it does for Claude. Treat that
readiness as worker-attested and re-run the declared checks before merging. Missions always
carry `delivery` and re-verify the candidate on fresh objects before publication.

Use one immutable manifest per selected repository. State and the exclusive lock live
in the repository's shared Git metadata at `launch-queue/`, so linked worktrees and
both intake sources share one admission authority. Retain this state and candidate
worktrees through human review; initializing over an existing queue is rejected.

```json
{
  "schema": 1,
  "project": "/absolute/project",
  "source": {"kind": "backlog", "path": "/absolute/project/BACKLOG.md"},
  "minutes": 30,
  "max_tasks": 2,
  "max_launches": 2,
  "max_attempts": 3,
  "command": ["claude", "-p", "{prompt}", "--session-id", "{session}", "--permission-mode", "auto"],
  "items": [
    {"id": "TASK-1", "priority": 1, "worktree": "/absolute/task-1", "scope": "Exact authorized work and acceptance."},
    {"id": "TASK-2", "priority": 2, "worktree": "/absolute/task-2", "scope": "Exact authorized work and acceptance.", "depends": []}
  ]
}
```

Each worktree must already have the generated Launch workflow, trusted hooks, and
verification contract. The manifest author supplies scope and an explicit priority;
where the source has a P-number section or native board priority, it must agree.
Equal priority uses stable ID order. Table rows must have the ID in the first column
and a standalone `[ ]`/`[x]` status cell. Headings require an explicit bold Status
field. Nested checkboxes are never tickets. Unknown statuses block admission.
`**Depends on:**` ticket IDs and manifest dependencies require source Done, not merely
another queue candidate awaiting review. Additional prose prerequisites belong in
the reviewed scope; this parser does not infer authorization from prose.

```bash
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json init
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json run
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json status
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json pause
```

The deadline, launch count, failed-check allowance, source snapshots, and claims
persist. A changed manifest cannot enlarge limits. Without the explicit context-rollover
option below, one task gets one launch and there is no automatic retry. A pause sentinel prevents admission
and stops the owned local process. Local children inherit the queue lock so a dead
controller cannot admit a sibling while its worker remains alive. Runtime recovery
must never be used to reset queue claims or evade limits.

Completed candidates are revalidated on restart. Interrupted local launches stop
for operator reconciliation even if a readiness receipt exists. An uncertain native assignment is read back, never resent. Native configuration interrupted before assignment can resume the same prepared run
only after unchanged-source and no-execution readback. Other interrupted admission
states block with retained evidence for operator investigation; they do not silently
start a replacement session. Manual runtime recovery does not create replacement
workers. This is a single-host supervisor, not a multi-host claim service or a hard
security boundary against a worker with the same filesystem credentials.

## One source task from project policy (Codex or Claude opt-in)

`launch-target.py` selects one dependency-free task from a full Markdown file, prepares
its worktree, and emits the ordinary immutable queue manifest. The operator approves
project policy rather than supplying a task ID or task worktree. The path-only policy
below retains dependency-free full-file heading behavior. Explicit format selection also
supports sections, tables and source-completed prerequisites. Source refresh, next-task
preparation, partial-preparation repair and automatic Paperclip preparation remain unsupported.

The project must have an approved full generated Launch workflow and canonical owned
primary autonomy overlay. Commit these literal root `.gitignore` rules before freezing
the base revision: `.codex/`, `scripts/verify.sh`, and `launch-control-backups/`. None of those
paths may be tracked; global or uncommitted ignores do not qualify. Preparation never
adds ignores or adopts unowned generated files. Its generator must leave the task
worktree clean at the frozen base revision.

```json
{
  "schema": 1,
  "project": "/absolute/project",
  "base_revision": "REPLACE_WITH_FULL_COMMIT_SHA",
  "source": {"path": "BACKLOG.md"},
  "scope_template": "Implement {id} within the approved project scope; record acceptance at {gitdir}/acceptance.json.",
  "caps": {
    "minutes": 30,
    "max_attempts": 2,
    "rollover": {
      "threshold": 65,
      "max_launches": 1,
      "synchronous_commands": ["git status --short"]
    }
  },
  "generator": {
    "argv": ["python3", "/absolute/approved-generator.py", "{id}", "{worktree}"]
  }
}
```

Replace the example scope and command list with reviewed task authority and the exact
finite shell lifecycle contracts needed by the generated workflow. Only `{id}` and
`{gitdir}` are scope placeholders; commands allow `{id}`, and generator arguments allow
`{id}` and `{worktree}`. Arguments execute directly, without shell interpolation.

The approved generator renders project inputs and invokes the installed adjacent
`codex-parity.py` with `--codex --enable-autonomy`, source, verification config and
command-list inputs, plus `--autonomy-controller /installed/skills/onboard/scripts/launch-runtime.py`,
`--autonomy-controller-digest SHA256`, and `--autonomy-shared-root /absolute/project`.
Generate the primary overlay first using those same options, then let the generator
select `--project {worktree}`. The converter requires matching adjacent runtime bytes,
refreshes only unchanged owned files, preserves user hooks and original ownership,
and makes identical refreshes a no-op. Both contexts route the three managed hooks
through the primary canonical wrapper.

```bash
python3 /installed/skills/onboard/scripts/launch-target.py --policy /absolute/policy.json --output /absolute/queue.json
# Inspect generated hooks and trust them through normal native Codex controls.
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json init
python3 /installed/skills/onboard/scripts/launch-queue.py --manifest /absolute/queue.json run
```

Every stable-ID heading needs explicit priority and one recognized Status. Nested
checkboxes are ignored. Unknown status or ambiguous dependency prose blocks the record;
explicit `**Depends on:** none` is supported. Duplicate IDs, missing priorities and
stable-ID table rows refuse preparation. Eligible tasks sort by priority, then ID.
No eligible task returns `"outcome": "no_eligible"` without a claim, task worktree or
manifest. The selected task uses branch `launch/id-lower` and shared Git metadata path
`launch-prepared/ID`; conflicts refuse rather than overwrite.

Preparation retains a claim before creating the worktree. It binds policy bytes, base
revision, source identity and final manifest. Queue init and run revalidate that binding;
source reordering cannot substitute another task. A failed generator or interruption
retains all evidence and blocks another preparation. Inspect and reconcile the existing
claim, queue and worktree; do not delete state to reset limits or rerun preparation over
an uncertain result. Continue an intact prepared manifest through ordinary queue commands.

### Claude policy (review-ready only)

Add `"platform": "claude"` to the same policy shape to prepare a Claude task. An absent
`platform` means Codex, so existing policies keep their meaning. A Claude policy cannot
carry `delivery`: publication is Codex-only (D4), and the run ends
`review_ready_publication_unsupported`.

Commit these literal root ignore rules: `.claude/launch/`, `.claude/hooks/launch.sh`,
`scripts/verify.sh` and `launch-control-backups/`. None of them may be tracked. The base
revision must already track `.claude/settings.json`, with the managed SessionStart,
PreCompact, Stop and all-tool PreToolUse hooks, and the five `.claude/skills/launch/`
files. Preparation refuses rather than generating or exempting a tracked file. Use the
runtime's own generator, which writes the canonical wrappers and copies the named checks.
It refuses to overwrite any existing file:

```json
"generator": {"argv": ["python3", "-I", "/installed/skills/onboard/scripts/launch-runtime.py",
  "--project", "{worktree}", "--platform", "claude", "render-overlay", "--from-config", "/absolute/verify.json"]}
```

The manifest carries `platform: claude`, `native_review: false`, no `controller`, and the
`verify.json` digest in its preparation binding. Admission refuses changed checks, which an
ignored file's clean status cannot show. A prepared Claude task always runs through native
rollover, never the gate-less `command` path.

Readiness belongs to the controller, not the worker. At admission the controller snapshots,
in memory, the verification policy, the admitted checks, both git directories, and digests of
the gitfile, `config`, `config.worktree`, `info/exclude`, `info/attributes` and `hooks/`. When
the worker reports `awaiting_review`, the controller re-runs the snapshotted checks itself, then
requires all of these:
- an unchanged snapshot;
- a clean, unchanged committed revision before and after the checks;
- valid evidence in `<gitdir>/acceptance.json`.

Its git calls ignore global and system config, replace objects, fsmonitor, hooks and
`core.excludesFile`. Its clean check compares content through a throwaway index built from
`HEAD`, and refuses any ignored untracked `.gitignore` or `.gitattributes`. An untracked
catch-all `.gitignore` hides itself and every file beside it. A worker-run `git
status` can leave stale clean stat data in the real index, and `--really-refresh` still trusts
that data. It
writes its receipt to `launch-queue/<run>-controller-receipt.json`. Any mismatch pauses the
task in the real git dir. The admission snapshot is saved in the queue state before the worker
launches, so a controller restart resumes against it. The worker's Write and Edit tools cannot
reach that file; code run by a declared check could, the same as the rest of the queue state. A
restart never takes a new snapshot, which would bless earlier tampering. Before relaunching, it
re-pins the installed Launch files and compares the git control files to the snapshot, so a
change made while the controller was down pauses before any worker runs. A queue state with no
snapshot cannot resume; prepare a new run.

Once the re-check passes, the controller runs an independent review in a separate `claude -p`
process. The reviewer starts fresh with `--safe-mode --restricted --tools Read,Glob,Grep
--strict-mcp-config --disable-slash-commands --no-session-persistence`:
- No hooks, no project or local settings, no `CLAUDE.md`, no skills, no MCP and no Bash.
- File tools stay inside the worktree.
- No `LAUNCH_*` variables, and no queue lock.

It refuses if the CLI reports any tool outside Read, Glob, Grep and StructuredOutput, any skill,
MCP server or slash command, or a plugin that is not built in. The CLI reports these only once
the turn runs, so this check comes after the fact. The flags are the control; two native probes
confirmed them (2026-10-20, claude 2.1.303).

Its prompt carries the approved scope, the snapshotted checks with the controller's exit codes,
the acceptance criteria, the candidate revision, and the base-to-`HEAD` diff. The source text
and the diff are marked as worker-written data.

The verdict is `ship` or `revise`, with the revision and findings. Readiness requires all of
these:
- `ship`;
- the receipt's revision echoed back;
- an unchanged fingerprint and identity, a clean check, and no snapshot drift after the review.

Any refusal, failure, PAUSE, deadline or token cap pauses the task. `revise` records its
findings. A restart after `revise` refuses; corrected work needs a new preparation and run,
which re-checks and re-reviews it.

Reviewer tokens join the cumulative total, including a failed turn's tokens. So do Claude
worker tokens, from the CLI's cumulative `modelUsage`. Review runs for at most 600 seconds. A
controller crash mid-review leaves `handoff_stage: reviewing`. The reviewer sees stdin close,
finishes its current turn and exits; that turn's tokens are not counted. The restart names the
reviewer pgid to check by hand, as it does for any reviewer whose cleanup was not confirmed.

A model reviewer can be steered by worker-written text. The verdict is one gate beside the
controller's own re-check and the fingerprint binding, not the only one.

The PreToolUse gate also refuses Write and Edit in four places:
- inside either git directory, except the exact `<gitdir>/acceptance.json`;
- the worktree's `.git` file;
- the gate's own files: `.claude/hooks/`, `.claude/launch/`, `.claude/settings.json`,
  `.claude/settings.local.json` and `scripts/verify.sh`;
- the installed `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, whose pinned copies are compared again
  at readiness. It reads the directories
from `LAUNCH_GIT_DIR` and `LAUNCH_GIT_COMMON_DIR`, which the controller sets at launch, and
refuses every tool if the live directories disagree. This is a hook, not a sandbox. Code run by
declared checks is not contained.

Declare both canonical verify commands in `rollover.synchronous_commands`:
`bash scripts/verify.sh checks --run "$LAUNCH_RUN_ID"` and the matching `ready` command with
`--candidate "$(git rev-parse HEAD)"` and `--acceptance "$(git rev-parse --absolute-git-dir)/acceptance.json"`.
The gate admits them only for a prepared Claude task, whose controller binding and unchanged
policy it checks first. The wrappers run the installed copies under
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`. Admission therefore refuses unless the installed
`launch-runtime.py`, `launch-claude.py` and `launch-autonomy.md` are byte-equal to the
controller's own; run `./install.sh` after any update.

### Selected sections, tables and completed prerequisites

To opt into selected intake, replace the policy source with:

```json
{"path": "BACKLOG.md", "format": "table", "heading": "## Selected work"}
```

`format` is `headings` or `table`. Omit `heading` for the whole file; when supplied it
must be the exact unique Markdown heading including its hashes. Null, missing or
ambiguous headings refuse. The section ends at the next heading of equal or higher
rank. Duplicate task IDs outside that section are excluded; duplicates inside refuse.
Fenced examples and nested checkboxes never create tasks. An unterminated fence refuses.

Heading tasks inherit the nearest priority heading. Tables require exactly
`ID | Item | Status | Tier`, optionally followed by `Depends on`. Unsupported columns
refuse; ambiguous row widths block the record. Unescaped pipes are structural even
inside code spans. Priorities must be `P<number>` or `P<number>.<A-Z>`; other Tier prose
blocks. Tasks sort by numeric priority, optional subpriority (empty before A), then ID.

Statuses recognize open/todo/ready and done/closed/completed/delivered/shipped prefixes,
or exact table `[ ]`/`[x]` cells. Contradictory clauses, unknown values and duplicate
metadata block the record. Dependencies accept explicit IDs, optionally prefixed
`shipped`, separated by commas, semicolons or `and`; `none` means no prerequisite.
A separate sentence starting `Integrates`, `Unlocks` or `Notion is` is descriptive.
Other conditional or multiline prerequisite prose blocks; it never becomes authority.

Every prerequisite must be present, unambiguous and source Done in the approved
selection. That establishes source eligibility, not independent proof that the full
prerequisite ticket was deployed or accepted. The manifest freezes its record digest.
Preparation rechecks after generation; queue init, run and native context checks refuse
changed tasks or prerequisites and retain claims/counters. Digests normalize line endings
and outer whitespace; unrelated source edits outside bound records remain possible.
No-eligible results include blocked-record reasons. This still prepares one immutable
task: neither awaiting_review nor a source status edit automatically admits another.

The manifest selects `native_review: true`. Before any model turn, native `hooks/list`
must show the same three enabled, trusted managed hooks in both contexts. Missing trust
blocks the launch with counters retained; neither the preparer nor queue edits trust
storage. Independent native review uses one read-only `inspector` named `reviewer`.
Its permitted observed shell completions are explicitly declared simple `pwd`, file-only
`cat`, or read-only Git inspection commands. Review must return standalone `ship` with
the exact candidate SHA; parent-only mutations and verifier commands cannot qualify. The
prompt tells the worker to pass the reviewer an explicit rule: never run declared checks,
tests or `scripts/verify.sh`, since any such command leaves the review unresolved.
Reviewer identity, terminal completion and usage are reconciled independently.

Readiness requires the reviewed revision and post-turn working-tree fingerprint to
remain unchanged, successful canonical verification with check process groups gone,
and closure of the native worker and observed descendants. This proves local
`awaiting_review`, not publication authority or an immutable full review interval.

## Restricted GitHub publication (explicit opt-in)

Before preparation, the approved delivery grant can include:

```json
{
  "allowed_actions": ["prepare", "implement", "review", "push", "pull_request", "publish"],
  "publication": {
    "mode": "github-base-lease",
    "deployment": "none",
    "required_checks": [],
    "billing_fallback": false
  }
}
```

These fields extend the restricted delivery grant, not the queue manifest. Freeze them
with the exact source task, repository, base branch, host policy and original budgets;
never edit or replace an admitted grant to renew authority. This path supports one
Codex task on a reviewed macOS host and an unprotected GitHub base without effective
rules. Other providers, branch rules and required deployment need separate support.
A private repository whose plan refuses the rules endpoint with the exact "Upgrade to
GitHub Pro" 403 cannot carry rulesets or protection; that refusal reads as no rules.

Publication uses the host's `gh` login, which can reach every repository that account can.
Only the controller holds it, and every credentialed call is limited in code to the granted
repository: `gh api` endpoints must be `user` or `repos/<repository>/...`, Git remotes must be
exactly `https://github.com/<repository>.git`, and pushes name only the base and task branches.
A remote that still refuses a base push (for example protection added after the rules read)
leaves the attempt retained and pending; it is never forced or resent. On a reviewed host,
`python3 -B tools/accept-launch-isolation.py` (source checkout) runs the real `codex sandbox`
against synthetic sibling files, fake credentials, the host's real credential paths and keychain
item, and an inert local endpoint, for the check, hook, restricted Git and verifier surfaces.

An empty check list is valid only when both candidate and base contain no GitHub
workflows and the exact revisions have no hosted checks or statuses. Otherwise list
each required check as `{"name":"exact check name","app_id":123}`. Missing, pending,
failed or unknown required or additional checks block publication. A skipped
additional check ran nothing and is ignored; a skipped required check blocks. The optional billing
fallback accepts only verified GitHub Actions billing startup failures with zero job
steps; it records hosted checks as unavailable, never green. Every failure-level
annotation must be the billing message; runner notices and warnings are ignored.

The merge commit is gated on the same required checks unless the grant adds
`"post_merge_checks"`. List the checks that run on the merged base commit there. An
explicit `[]` suits workflows that run only on pull requests: every check observed on
the merge commit must pass, skip, or prove a billing block, and none is required. An
empty observation stays pending, so use `[]` only where the merge commit always gets a
hosted result (for example a deployment status).

The credential-free worker and independent native reviewer finish first. The controller
reads retained review evidence without starting a model turn, verifies a fresh snapshot
using the pinned runtime and frozen checks, and matches the stored PR metadata and diff.
It publishes an exact two-parent merge with an expected-base lease, then reads back the
merge identity and verifies its revision again. A concurrent base update requires one
bounded repair, fresh review and checks before another publication attempt. Repair spends
the original attempt and launch allowances without extending either deadline. Grants with
repair capacity (`max_launches > 1` and `max_attempts > 1`) must declare the exact read-only
commands `git rev-parse HEAD^2` and `git diff HEAD^2...HEAD` in their target policy's
`rollover.synchronous_commands` before admission. The fresh post-repair reviewer confirms
the second parent equals the sealed observed base and compares against it. `origin/main`
stays at the admission baseline; its diff can include unrelated concurrent base changes.
These second-parent commands are for repaired merges, not initial candidate review.

`publication_pending` retains uncertain operations for readback without resending them.
An operator pause stops publication before its next write and leaves the item `paused`;
after the pause is removed, the next run re-enters publication from its journal.
`delivery_blocked` retains failures requiring reconciliation. `merged_source_pending`
means the merge exists; its `verified` flag becomes true only after post-merge checks
pass. Without source writeback authority, source status stays unchanged. No next task
is admitted from this outcome.
Restart reconciles an existing merge without reimplementing it. Preserve the journal,
worktrees and failed evidence; do not use runtime recovery or new grants to reset caps.

## Provisioned dependencies (explicit opt-in)

Delivery checks run without network, so a project whose checks need installed packages
declares host-built trees in the grant:

```json
{"dependencies": [{"target": "ui/node_modules", "source": "/abs/host/ui-node_modules",
  "digest": "<tree digest>", "lockfile": "ui/pnpm-lock.yaml", "lock_digest": "<sha256>"}]}
```

Build each `source` outside delivery from the base revision's lockfile, then record its
`tree_digest` (names, symlink targets, permission bits and bytes) and the lockfile's
SHA256. Sources must not overlap the workspace, home, Codex home or other protected
authority. Targets are relative, neither duplicate nor nested, and outside `.git` and
`.codex`, compared case-insensitively. Setuid and setgid files refuse. Symlink targets
are pinned, not resolved: the grant author reviews any link that leaves the tree.

Preparation copies each tree into the prepared worktree; independent verification copies
a fresh one into every verification clone. Both first require the checkout's lockfile to
match `lock_digest`, then require the copied tree to match `digest`. A candidate that changes a lockfile
blocks: re-provision and approve a new grant instead. Every target must be gitignored.
Verification clones are writable so checks can write ignored caches and build output;
their `.git` and dependency targets stay read-only. HEAD, tree, status and every
dependency digest are re-proved after the checks.

## Conditional GitHub source completion

Add `source_done` to the existing publication grant's `allowed_actions` only with an
explicit `source_writeback` object:

```json
{"repository":"owner/repo","branch":"main","path":"BACKLOG.md","heading":"# Selected","max_attempts":2}
```

Repository and branch must equal the grant's repository/base branch; path and heading
must equal its frozen table source. This slice supports only that same GitHub source.
The controller rechecks exact merged/post-merge evidence before changing one status cell
to `Done`; the worker has no source-write credentials. Every other byte is preserved.
Changes to any selected record block; unrelated prose and history edits are preserved.

The controller journals at most two conditional Contents write intents. Only a definite
HTTP409 plus a changed blob with unchanged selected records permits the second intent.
Timeouts, unknown responses and interrupted dispatch remain pending without resend.
Original deadlines apply before every write; expiry permits read-only acknowledgment
when current full content exactly matches a retained expected blob. If later edits
prevent that exact proof, keep `merged_source_pending` and the original evidence.

A successful readback records `delivered` and queue outcome `selected_task_delivered`.
Its `rediscovery` reports eligible/remaining IDs from that same selected source, without
new admissions or launches. `selection_complete` means all selected source records are
Done; it does not prove delivery evidence for every historical task or full mission
completion. New work needs its own grant. Publication-only grants retain
`merged_source_pending` with source unchanged.

## Native context rollover (explicit opt-in)

For a local backlog queue, select `"platform":"codex"` or `"platform":"claude"` and
add `"rollover":{"threshold":65,"max_launches":3}`. No command argv is used in this
mode. The threshold must be an integer from 60 through 70; the positive launch limit
counts every native process, while `max_tasks` counts admissions. All replacement
sessions keep the same task, run, worktree, deadline and failed-check allowance.

Each native user turn completes one bounded phase and returns semantic notes. The
prompt states that a phase end is not a pause: the controller sends the next phase. Actual
current context usage is measured against the native model window. Crossing the
threshold now requests checkpoint completion during the active turn. Codex receives
one native `turn/steer` bound to that exact thread and turn. Claude's existing
PreToolUse gate switches to checkpoint-only mode: further work tools are denied,
and only the complete semantic StructuredOutput with the matching loaded hash may
proceed through ordinary native permission handling. Only exact hook-recorded denials
of observed current-turn tool requests are treated as checkpoint control.

Already-started work must finish safely; both adapters allow at most 60 seconds from
the trigger to return valid notes, within the original phase and task deadlines.
Usage reports are discrete, so a large response or tool result can overshoot the
percentage before it is observed. The threshold is not a hard context cap. Missing
telemetry, rejected active steering, unresolved operations or checkpoint timeout
block continuation; none is silently treated as a completed handoff.
The controller then retires its process group,
checks known tool/process completion, seals and reads back the checkpoint, and loads
that exact hash into one fresh session before continuing. Unknown, asynchronous,
subagent (except the reconciled reviewer above), or remote tool lifecycles block replacement. This is not a sandbox against
arbitrary detached work started by same-user code.

Claude additionally requires the generated all-tool PreToolUse calibration entry in
`.claude/settings.json` described in the autonomy reference. Its first input only
calibrates the persistent session and loads checkpoint data; the tool gate opens after
matching native SessionStart and effective model/window readback. Neither adapter
changes the user's native model or permission configuration to make a run pass.

Codex 0.153.4 discovers project hooks from the primary checkout, even when executing
in a linked worktree. Worktree-only hook generation is insufficient. A reviewed,
project-owned primary hook declaration must route to the intended worktree; the queue
will reject a missing SessionStart observation before ordinary work. Do not overwrite
user hooks or point a shared production declaration at one temporary worktree. The opt-in heading path above provides canonical owned routing; other provisioning
remains a separate delivery prerequisite.

The authoritative seal is in Git-local `launch/active.json`; its Markdown derivative
is `launch/<run>/checkpoint.md`. Manual `$checkpoint-load launch-run-<run>` validates the exact seal
and absorbs its notes without rebinding a session or renewing limits. Edited views,
changed candidate/index/policy, stale identities, pauses and expired limits refuse.
Persisted checkpointed/no-launch stages can resume within their original limits;
uncertain launch or dispatch states remain blocked for reconciliation. Native compaction
before controlled rollover is retained as a separate fallback outcome, not a successful
fresh-session handoff. Paperclip replacement is unsupported by this option.

## Native Paperclip intake

Set `source` to `{"kind":"paperclip","company":"UUID","api_base":"https://host","cli":"/absolute/paperclipai"}`.
Each scoped item also needs its exact `issue` UUID and a dedicated `agent` UUID.
Use unused Todo issues and idle dedicated `claude_local` CLI agents already configured
for their assigned worktrees and normal permissions. Do not reuse completed pilot
agents or deleted workspaces. The authenticated native CLI owns credentials.

The supervisor pins session/run/worktree instructions, disables timers, sets native
concurrency one and daily runs one, and reads back the persisted configuration before assigning exactly one issue.
A mismatched configuration or paused agent blocks assignment. Paperclip owns
native launch and checkout. The next scoped issue is assigned only after the native
run succeeds and the runtime receipt is still valid. Agents are paused afterward.
An unexpected native retry, source error, or malformed response is an error, not an
empty queue. API timeouts are retained as uncertain writes for readback. The native
worker must use its own injected credentials to checkout its issue and move it to
In Review after readiness; no board-owner token goes into its prompt.

This version's native adapter is Claude CLI. Local argv is explicit; acceptance of
another client requires its own verified session binding, not just changing an
executable name. Timers, broad backlog discovery, custom boards, automatic source
rewrites, and publication are outside this contract.

### Shell lifecycle contracts for rollover

An optional `rollover.synchronous_commands` array records exact reviewed command text
whose work completes before its shell exits. Default is empty. This is a lifecycle
contract, not a tool permission grant; do not populate it by guessing that every
validation/build command is synchronous. Review referenced phase scripts and keep the
contract valid for their actual contents. The immutable queue manifest binds this list.
Native file operations retain their observed completion protocol. Any unclassified shell
command, native background indicator or recognized service/job manager stays unresolved,
even after exit zero, and prevents replacement until explicitly reconciled. Remote/service
managers need their own completion adapter. Group cleanup and launcher detection do not
prove arbitrary hidden or escaped activity idle. No whole-machine sandbox is claimed.

Codex phase completion uses the retained task deadline, as Claude does; native startup
and request acknowledgment remain separately bounded. Neither allowance resets the queue.
