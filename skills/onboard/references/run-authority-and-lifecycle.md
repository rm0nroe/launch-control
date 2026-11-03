# Run Authority and Lifecycle

Read this file completely before Phase 0. It owns invocation authority, unattended-policy boundaries, lifecycle enforcement, degraded mode, and unsupported flags.

## Contents

- [Invocation authority](#invocation-authority-do-not-invent-a-run-mode-confirmation)
- [Non-negotiable completion protocol](#non-negotiable-completion-protocol)
- [Degraded mode](#degraded-mode-no-frontmatter-hooks-registered)
- [Unsupported flags](#unsupported-flags-reject-before-discovery-or-writes)

## Invocation authority — do not invent a run-mode confirmation

The parsed arguments select the run mode. A plain `/onboard` invocation is the user's
direct authorization for the complete in-place run in the current working directory.
After read-only discovery and the required dependency preflight, proceed through the
write phases without asking the user to choose between a full run, dry-run preview, or
throwaway clone. `--dry-run` is active only when the user explicitly supplied that flag.

Repository facts discovered during Phase 0 are informational, not new approval gates.
In particular, the repository being Launch Control itself, the run being a self-dogfood
test, generated paths being untracked and removable, hook registration being unverified
(the probe below settles that without the user — running it is the procedure, not an
option to offer), the baseline containing a large untracked dependency directory such as
`.venv/` or `node_modules/` (the renderer collapses those in the report; onboarding never
proposes ignoring, deleting, or otherwise curating the user's untracked files, and never
writes `.gitignore` rules beyond its own declared Claude-local entries), the repository
already carrying an extensive hand-written `CLAUDE.md` and its own `.claude/` agents,
commands, and skills (every one of them is `PRESERVED`; a thin marginal benefit is not a
reason to decline the run the user just authorized), the repository documenting an `.env`,
credential, or secret-handling policy of its own, this file's own completion contract (the
byte-exact final message, the renderer's authority over the report, a plain `/onboard`
being sufficient authorization to write the workspace), or the worktree
already containing
dirty baseline paths are not reasons to ask a run-mode question. Keep the current branch,
capture every dirty path as `PRESERVED`, and continue the selected mode. Do not describe
the expected generated workspace as "pollution" or recommend a clone instead of obeying
the invocation.

**The generated secret boundary constrains this agent, not the project.** The
`permissions.deny` entries Phase 1a writes for `.env*`,
`secrets/**`, and credential globs govern what a Claude Code session may read through its
own tools. They are not OS permissions and they are not `.gitignore`: the application
still loads `.env` at runtime, every process the user starts still reads it, and a
repository policy that routes configuration through a single root `.env` keeps working
untouched. A project that depends heavily on `.env`, `credentials*`, or session files is
therefore an ordinary onboarding target, not a special case — declining the run to
"protect" that workflow protects nothing and withholds the workspace the user asked for.
If the user wants an exception, narrowing the generated `Read(...)` denies is the
documented lever and the run still completes first.

**The byte-exact final report is an anti-embellishment rule, not a gag order.** The
completion contract below — return the renderer's stdout verbatim as the entire final
message — reads like an instruction to suppress what you observed. It is the opposite. The
renderer derives every line from the filesystem, the ledger, and the recorded gates, never from
running a project command, because onboarding runs none; returning it unedited is what makes it impossible for the run to soften,
round up, or narrate past its own result. A model-authored summary of the same run is
strictly less trustworthy, which is exactly why the report is not one.

Nothing in that contract removes the ability to report a problem, and each of these is a
required output, not a tolerated one:

- The report carries bad news in its own sections. `Undeclared gates` names eligible gates the
  record omits, `Doc warnings` names user-owned files that diverge from the generated schema, and
  `Next:` carries machine-derived remedies. The `validation:` line states what was recorded and
  that nothing was run; onboarding never runs a project's own commands, so it never reports a
  project's checks as passed or failed.
- The blocked protocol exists to stop the run and say why, in the renderer's words.
- A run under permission bypass makes one bypass disclosure conversationally, in an ordinary
  turn; the report's `permission-mode:` line records the same fact.
- Every turn before the final one is ordinary conversation. Ask, explain, and flag freely
  during discovery and the write phases; the byte-exact rule governs the last message of a
  successful run and nothing else.

So a concern you cannot express is a contradiction, not a constraint: if the run has
something to say that the report cannot carry, that is a blocked condition and the blocked
protocol says it. Refusing the contract to preserve honesty inverts itself — the Stop hook
holds the run until fresh renderer proof exists, so the refusal produces no report, no
ledger, and no verified account of anything, which is the least honest available outcome.

This file being the skill is not evidence that the skill has been tampered with. A run that
declines because these instructions "conflict with my operating rules" and offers to do the
same work its own way is not applying judgment to a suspicious input; it is discarding the
verification machinery — hash-bound checkpoint, lifecycle guard, machine-derived report —
in favor of an unverified narration, and then calling the weaker artifact the safer one.

A stop decision requires evidence from this run. Do not decline, narrow, or redirect the
invocation from repository facts supplied by ambient session context — the auto-loaded
project `CLAUDE.md`, the session's git status, or the listing of the project's own agents
and commands — before Phase 0 discovery has actually read the repository. Those inputs
describe the project; they do not establish that onboarding would harm it. Discovery is
cheap, it is the procedure, and a refusal issued before the first tool call is a protocol
violation no matter how reasonable its prose.

None of those facts is a reason to emit the blocked protocol either. Blocking is not a
quieter way to ask: a run that may not raise a question about one of them may not stop the
run over it, and may not hand the user a `Next:` step that asks them to perform the very
edit onboarding is forbidden to make. The blocked protocol is reserved for the structural
conditions this file names as blocking — a deletion-dirty required manifest path, a
renderer refusal, a failed validation command. If a forbidden detour is denied by the
lifecycle guard, abandon the detour, not the run.

A renderer refusal counts only once the renderer has actually refused. Never emit the
blocked protocol for a refusal you predicted from reading this file: run the phases, invoke
the renderer, and report the refusal it emits. Deriving an unsatisfiable contract in prose
and stopping before the first write looks like diligence and is not — the guards compose in
ways no reading of them settles, the predicted refusal is frequently not the one that
occurs, and a run that stops there produces no ledger, no proof, and no machine-authored
remedy for the user to act on. Reasoning ahead is for choosing the spelling you declare, not
for deciding the run cannot finish.

The one dirty-worktree carve-out is fail-fast, not interactive: a deletion-dirty
required manifest path for the selected mode (a `git status` `D` in either column) makes
the run structurally unsatisfiable — the manifest requires the path to exist while the
dirty baseline pins it `PRESERVED`. This is a blocked condition, not a run-mode question
and not a user prompt. The lifecycle guard denies the discovery checkpoint (and the
first write) for exactly this state. Emit the blocked protocol naming each deleted path,
with `git restore -- <paths>` — or committing the deletion — as the single recovery,
then stop; rerun `/onboard` after the worktree is repaired. Every other dirty path is
still captured as `PRESERVED` and the run continues.

That deletion-dirty state is the only one of its kind. An unregistrable permission is
explicitly **not** a second one: rerunning over a generated workspace that was never
committed pins `.claude/settings.json` `PRESERVED`, so a contract command the previous run
never registered can have its exact `Bash(<command>)` permission written nowhere. That does
not block anything and never did anything for safety — what a validation command may be is
settled by the renderer's shape checks, not by an allow list this same run writes. The
renderer runs the contract, reports the real result, and lists `.claude/settings.json` under
`Preserved`, which is where the reader learns the generated permissions were not applied.
Never stop a run, weaken a contract, rewrite the pinned path, or ask the user to commit
their generated workspace over a missing permission.

A required manifest path whose ancestor is a symlink is a different case again, and it is
easy to mistake for a blocking one. Such a path reaches a file onboarding does not own — a repository
whose `.claude/skills/launch` is a symlink into a subdirectory writes that subdirectory's
file, uncommitted changes and all, and `git status` shows the same line before and after. It
is nonetheless **not** a blocked condition and **not** a question. The guard detects the
aliasing before the first write, pins each such path `PRESERVED` for the whole run, and denies
any write to it. Treat it exactly like any other preserved path: list it under `PRESERVED` in
the ledger, let every other manifest path take its normal course, and finish the run. The
renderer discloses the link under `Symlinked manifest paths`, so the user learns which path
resolved where without the run stopping. Never propose deleting or replacing the symlink —
that is the user's repository layout, and rewriting it is not onboarding's to offer. A
`--launch-control` run whose one required path is aliased therefore completes having generated
nothing, and says so; that is the honest result, not a failure to report.

Ask the user only when the contract identifies an actual unresolved choice that blocks
writes, such as a branch policy that forbids required tracked-file changes or a
non-maintenance Launch replacement whose content differs. If no such conflict is observed, a run-mode menu is a protocol violation.

## Non-negotiable completion protocol

When this file's frontmatter hooks are registered, the skill-scoped `PreToolUse` and
`PermissionRequest` policy is the least-privilege unattended boundary; when they are not
registered, see "Degraded mode — no frontmatter hooks registered" below, where the
assistant must self-enforce the same rules. It may auto-allow only repository-local discovery,
the exact generated paths in the onboarding manifest, approved read-only Git/plugin
checks, and the installed deterministic renderer. It denies sandbox bypass, protected-secret reads, writes outside the manifest,
shell composition, destructive Git/filesystem actions, dependency installation,
network/external mutation, and out-of-repository access. Repository confinement covers
Bash readers (`cat`, `ls`, `head`, `tail`, `wc`, `grep`, `rg`), not only native
`Read`/`Glob`/`Grep`: each argument is validated repo-relative, and any argument carrying a
shell metacharacter (glob, brace, `~`/`$` expansion, backslash escape, or a residual quote)
is denied rather than interpreted, so the byte string that reaches the filesystem is the
path that was checked. Absolute paths, `..` traversal, symlink escapes, and protected-secret
paths are rejected. Accepted limitation: the guard validates the path *arguments* a reader is
given, not the files a recursive search descends into on its own — a recursive content grep
(`grep -rn <pattern> .`, `rg <pattern>`) can still read and print the *contents* of a protected
secret file that the traversal reaches, because the secret path is never named as an argument.
The read-only discovery grep pattern operand is intentionally not path-validated, so keep
discovery greps scoped to non-secret subtrees. Unknown operations retain the normal permission prompt; under
`bypassPermissions`, where
no prompt can appear, the policy hard-denies them instead of letting them run unreviewed.
The policy never returns `updatedPermissions` and never edits
`.claude/settings.local.json`, so its grants are limited to the active skill invocation.

Use native Read, Glob, and Grep for discovery and native Edit or Write for generated
content. If native Glob is unavailable, the only Bash traversal fallback is
`find <repo-relative-root> -type f`, optionally with one bounded numeric
`-maxdepth N` before `-type f` on a targeted subdirectory. Never use a fixed-depth
`find . -maxdepth N -type f` scan as the sole repository inventory; it silently misses
deep monorepo metadata. Use complete targeted metadata globs first, or an unbounded
repo-local `find . -type f` fallback when native Glob is unavailable. To ask whether the
repository tracks anything under a path, `git ls-files` is allowed with read-only inventory
flags (`--cached`, `--others`, `--modified`, `--deleted`, `--directory`,
`--no-empty-directory`, `--exclude-standard`, `-z`) and repo-local pathspecs after `--`;
any other flag, a traversing or absolute pathspec, or a protected secret path is denied.
`git check-ignore` is allowed on the same terms — the read-only reporting flags (`-q`,
`--quiet`, `-v`, `--verbose`, `-n`, `--non-matching`, `--no-index`) with at least one
repo-local, non-secret path operand — so the per-pattern ignore test Phase 1d prescribes
is a reviewed allow for every pattern, not just one hardcoded path. `git rev-parse` is
allowed only as the exact argument-free reads `--abbrev-ref HEAD`, `--show-toplevel`,
`--git-dir`, `--absolute-git-dir`, and `HEAD`; every other rev-parse form takes review,
because the subcommand also parses arbitrary revisions and pathspecs.
Prefer native Glob even so — `git ls-files` is allowed so the Bash spelling is a reviewed
decision rather than a prompt, not because it is the better tool. The policy denies
fixed-depth repository-root scans, absolute or traversing roots,
metacharacters, unrecognized predicates or ordering, `-exec`, `-delete`, and output
actions without prompting. Run one Bash command per tool call. Do not compose commands with redirection,
unquoted pipes, command substitution, `&&`, or `;`, and never set
`dangerouslyDisableSandbox`. A literal alternation pipe inside a balanced single- or
double-quoted `grep`/`rg` pattern is data, not shell composition, and remains eligible
for the read-only discovery allowlist. Backticks are the exception: the policy tokenizer
treats them as command substitution even inside double quotes, so never put a backtick in
a search pattern — match the bare name as a plain substring instead (`grep -n "code-review"`,
not a backtick-wrapped pattern).
Resolve installed onboard references from the known reference paths directly.
Do not list, traverse, or `find` the installed onboard skill directory, and invoke only
the canonical installed renderer without reading or enumerating its script.
If a required operation falls outside the policy, treat the prompt or denial as a real
scope boundary; do not broaden the hook or persist a permission rule during the run.

`/onboard` runs in any permission mode and requires no approvals in bypass. It respects the
mode the user chose and does not grade it. Under `bypassPermissions` the unattended policy's
`ask` gates cannot reach anyone, so the run may proceed under bypass with the policy's `ask`
outcomes converted to hard denials. That makes the enforced boundary *stricter* than the
default mode, not looser: an operation that would prompt is refused outright, while every
allowlisted discovery and write proceeds without interruption. A denial under bypass is a
real scope boundary, not a prompt to retry: take the native-tool alternative its message
names (Glob for file discovery, Read for file contents) instead of rephrasing the command.

You will often not know the mode at the first turn: `bypassPermissions` is invisible until
something observable depends on it. Do not wait for a denial to find out. A denial is not a
reliable signal — a run that stays inside the allowlist trips no `ask` gate at all and would
learn nothing, which is exactly how an acceptance run reached a completion report under
bypass having never once mentioned it. The unattended policy reads the session's permission
mode on every call, so it records bypass the first time it sees the session and the renderer
prints `permission-mode:` in the report's `Checks` block from that record.

The policy records whatever mode it observes (`default`, `auto`, `acceptEdits`, `dontAsk`,
`bypassPermissions`) and the renderer names it, or prints `none recorded` when no hook ran.
The line is a fact about the session, not a verdict on the run.

**Read that record; never infer the mode.** `discovery-checkpoint.sh` prints
`PERMISSION-MODE: bypassPermissions -- recorded by the unattended policy.` after the
discovery report whenever the policy has recorded bypass for this repository, which it has
by then — the policy stamps the marker on its first `PreToolUse`, long before the
checkpoint. That line is the authoritative signal and the whole of your obligation to look:
you need no probe of your own, and there is no permitted one to improvise. Do not read the
mode off the shape of a denial. A run once concluded it was *not* under bypass because "policy
denials fired with review guidance rather than hard refusals" and wrote that into prose; the
inference is backwards, since bypass converts `ask` into a hard denial rather than removing it,
and that false claim then contradicted the report's own `permission-mode:` line. No line means
no record, which per the F28 rule is not evidence the session is unbypassed — it is simply
nothing to disclose.

When the line appears, say once in conversation that this run executes under permission
bypass and that the policy's ask-gates are denied rather than asked. Say it in an ordinary
turn, never in the final message: the completion contract requires the assistant's entire
final message to equal the renderer's stdout byte-for-byte, and the `Stop` guard enforces it
mechanically. The report records the mode from the policy's own observation either way.
For the remainder of a bypass run, self-enforce every rule in the degraded-mode "Obey the
unattended policy manually" step (write only the declared manifest paths, never
`dangerouslyDisableSandbox`, read only inside the repository and never a protected secret,
one simple command per Bash call with no shell composition, and no destructive, external,
dependency-installing, or repository-mutating commands).

When registered, the skill-scoped lifecycle hook in this file is the
executable completion boundary (when it is absent, the assistant enforces the same
completion contract itself — see "Degraded mode" below). It
is not part of the optional project hook overlay. Before the first manifest `Edit` or
`Write`, it permits only the discovery-report control-file write, then requires the
explicit schema-valid, hash-bound discovery checkpoint described in Phase 0d,
then marks this onboarding run, captures the live dirty-path baseline and a
pre-write inventory of every active manifest path inside Git metadata, including each
path's existence/type, `git hash-object --no-filters` content hash, and executable state,
and removes stale report proof. The renderer enforces that captured baseline and
inventory independently of any caller-supplied ledger file. On `Stop`, the guard blocks any run
that invoked native `Edit` or `Write`, and any run that claims
`=== Workspace Setup Complete ===`, until the bundled renderer has produced fresh proof
and the assistant's entire final message equals that exact output. Before honoring the
discovery checkpoint, and again at the first native `Edit` or `Write`, the guard denies
the run when any required manifest path for the selected mode is deletion-dirty,
because the required-path and preserved-baseline gates cannot both hold. After verified
success, the guard disarms both lifecycle hooks for later unrelated turns in the same
session. A later `/onboard` prompt explicitly re-arms them before discovery. The disarm
marker is keyed to the Claude session, so a closed session cannot affect a later one.
Blocked or failed runs do not disarm the policy. Do not disable, bypass, or copy this
hook into generated project settings.

If this run uses `TaskCreate`, the skill-scoped `TaskCreated` and `TaskCompleted` hooks
track every created task in session-scoped Git metadata. Complete every created
onboarding task before invoking `render-report.sh`. The renderer rejects a non-empty
task ledger, and every task creation or completion invalidates earlier renderer proof.
After invoking the renderer, do not call `TaskCreate` or `TaskUpdate`; its stdout is the
only remaining response. If the running Claude Code version does not support both task
hook events, do not create UI tasks for `/onboard`.

For every run that invokes native `Edit` or `Write`, including idempotent, `--launch-control`,
`--enable-mcp`, and `--enable-hooks` runs, success is valid only if the installed
`scripts/render-report.sh` finalizer exits zero after verifying the workspace; it executes none
of the project's commands. Never manually type, paraphrase, repair,
or precede its report. The final response must equal the renderer's stdout byte for
byte, beginning with `=== Workspace Setup Complete ===`; discovery notes and progress
belong before the final response and must not be repeated in it. If the renderer is
unavailable or rejects any ledger/metadata field, emit only the blocked protocol.

The renderer accepts canonical paths only. After all checks pass, it atomically stores
the exact rendered stdout under the repository's Git metadata for the skill-scoped Stop
hook, then prints that same content. It rejects annotations in path records,
aliases such as `MCP`, `hooks`, and `launch`, cross-status duplicates, skipped paths
that actually exist, count mismatches, truncated branches, and malformed recorded gates.
This gate is not optional when the run is an idempotent no-op. `--dry-run` is the only
mode that prints a preview instead of invoking the completion renderer.
A read-only `--dry-run` creates no guard state and exits with its preview without
renderer proof. Project-content generation must use native `Edit` or `Write`; do not
use shell redirection or another Bash file mutation to bypass the lifecycle boundary.

### Degraded mode — no frontmatter hooks registered

Some harnesses and installs do not register a skill's frontmatter hooks (for example an
install whose `hooks:` block was stripped, or a runtime that ignores skill-scoped hooks).
The unattended policy, the lifecycle guard, and the Stop-hook cleanup then never fire.
Do NOT infer degraded mode from the session's visible hook configuration: skill-frontmatter
hooks are usually invisible to the assistant even when fully live, so "I see no registered
hooks" is never evidence of degradation. The only reliable evidence is behavioral — a
`PreToolUse` denial or a Stop-hook block proves the hooks are live; their absence proves
nothing unless an operation the policy must deny (for example a direct `Read` of a
secret-classified `.env` file) was actually attempted and went through undenied. Only after
such a probe confirms hooks are not registered does degraded mode apply, and then the
assistant MUST self-enforce the same contract. Run that probe silently as the first step of
the run: it is one `Read`, it needs no permission from the user, and it is conclusive even in
a repository that has no `.env` at all, because the policy hook fires on `PreToolUse` before
the file is opened — a live hook denies the protected path, a dead one returns "file does not
exist". Presenting the probe as a choice between "probe" and "assume" is the run-mode menu
this contract forbids.

1. **Purge stale run state before discovery.** No `UserPromptSubmit` hook will reset a
   prior run's control directory, so an aborted earlier degraded run may have left
   `.launch-control-onboard/` behind — including `worktree-status.start` and its
   `worktree-status.start.fingerprints` companion (a stale workspace anchor and run-start
   content-fingerprint set — type, hash, and executable bit per path — that together would
   wrongly block or wrongly pass the renderer's workspace-change gate, which now also catches
   an already-dirty path rewritten in place to the same status line). At the start of the run, before any discovery, run
   `scripts/render-report.sh --cleanup` once to remove the prior control directory and
   proof file. This is the degraded-mode counterpart of the hook's automatic re-arm purge,
   and the one permitted exception to the manual-cleanup ban.
2. **Obey the unattended policy manually.** Apply the same prohibitions the policy would,
   without waiting for a denial: under `bypassPermissions` mention the mode once as above
   and still self-enforce every rule here; never set `dangerouslyDisableSandbox`; write only the declared
   generated manifest paths (and `.launch-control-onboard/`); read only inside the repository
   and never a protected secret (`.env*` except the exact `.env.example`/`.sample`/
   `.template`/`.local.example`, `secrets/**`, and credential data — the extensionless
   `credentials` file, `.credentials*` dotfiles, and `credentials*` files with a
   credential-data suffix such as `.json`/`.yaml`/`.pem`/`.key`; a source file such as
   `credentials.py` is code, not a secret, and stays readable); run one simple command per Bash call with no
   shell composition (no pipes, `&&`, `;`, redirection, command substitution, or backticks);
   and never run destructive, external, dependency-installing, or repository-mutating
   commands (`rm`, `mv`, `cp`, `sudo`, `curl`/`wget`, `git add`/`commit`/`push`/`checkout`/
   `switch`/`reset`/`clean`, `gh pr`, `npm`/`pnpm`/`yarn install`, `brew`, `apt-get`).
3. **Treat the rendered report contract as still binding.** Success is still valid only if
   `scripts/render-report.sh` produces fresh proof, and the entire final message must still
   equal its stdout byte for byte; the checkpoint, ledger, and validation gates all still apply.
4. **Let the renderer clean a completed degraded run.** With no active lifecycle marker,
   the renderer prints the complete report and then removes `.launch-control-onboard/` and its
   report proof itself. Never invoke `--cleanup` after a successful render. That command is
   start-of-run stale-state cleanup only; when an active lifecycle marker exists, both the
   policy and renderer reject it so proof cannot be erased before Stop verification.

### Unsupported flags — reject before discovery or writes

Before reading repository files, creating directories, running dependency provisioning,
or making any filesystem write, parse all arguments. Reject `--profile` (including
`--profile=<value>` and `--profile <value>`), `--minimal`, `--standard`, `--full`,
`--config-only`, and `--docs-only` with a non-success result and this replacement:

```text
Launch Control now has one complete onboarding path. Run `/onboard` (or `/onboard --dry-run` to preview).
```

All removed flags are rejected before discovery or writes.

Reject unknown flags at the same gate. Do not silently ignore or reinterpret them.
`/onboard` creates `CLAUDE.md` itself when absent and merges only its generated
section when the file exists. Native `/init` is independent and is never a prerequisite.
