# Supervised Launch recovery

Read only for an explicitly activated Launch task.
Claude and Codex share the same supervised runtime. It provides operator-started recovery, not an unattended
launcher, queue, scheduler, publisher, or a security sandbox. Keep the normal five-file
Launch classification, CRISPY, workspace, review and platform routes.

## Overlay files

Launch generates this overlay in each task worktree: `launch-stage.py` through
`codex-parity.py --codex --enable-autonomy` for Codex, `launch-runtime.py render-overlay`
for Claude. `/onboard` never installs it. The overlay requires Python 3.9+ and a nonempty
declared validation contract. Never infer commands from installed tools. Record every
command's exact working directory and bounded timeout.

The Claude overlay is exactly these paths:

- `.claude/launch/verify.json`: schema below, derived from authoritative discovery.
- `.claude/hooks/launch.sh`: shared-runtime dispatch below.
- `scripts/verify.sh`: canonical checks/readiness dispatch below.

An existing verifier, hook, or config is preserved. Compare it against the intended
binding; if incompatible, block with the conflicting path. Never overwrite, chmod, or
weaken it.

Example schema (replace the example with the complete discovered contract):

```json
{
  "schema": 1,
  "checks": [{"command": "./tools/validate-pack.sh", "cwd": ".", "timeout": 600}],
  "acceptance": ["selected-task-behavior"]
}
```

`acceptance` names the evidence required before readiness. At task setup the operator
reviews that list for the selected task. Empty checks or acceptance are invalid. Timeouts are operator-selected bounds,
not source-derived gates; activation pins the entire configuration. `checks` operates on dirty implementation state. `ready`
requires a clean assigned worktree, exact candidate revision, and matching acceptance.
Unavailable required checks fail; never remove them to obtain green.

Hook wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 -I "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/launch-runtime.py" --project "$CLAUDE_PROJECT_DIR" hook
```

Verifier wrapper (invoke as `bash scripts/verify.sh checks` unless executable mode was
explicitly established when creating the new file):

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
platform="${LAUNCH_PLATFORM:-}"
if [ -z "$platform" ]; then
  for candidate in claude codex; do
    if [ -f "$PROJECT_ROOT/.$candidate/launch/verify.json" ]; then
      [ -z "$platform" ] || { echo "Set LAUNCH_PLATFORM=claude or codex for this dual-runtime project" >&2; exit 1; }
      platform="$candidate"
    fi
  done
fi
case "$platform" in
  claude) runtime="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/launch-runtime.py" ;;
  codex) runtime="${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/launch-runtime.py" ;;
  *) echo "Select a configured LAUNCH_PLATFORM=claude or codex" >&2; exit 1 ;;
esac
exec python3 -I "$runtime" --project "$PROJECT_ROOT" --platform "$platform" verify "$@"
```

Merge command entries into existing settings without replacing other handlers or
matchers. Deduplicate by event, matcher and exact command. The command is
`bash "$CLAUDE_PROJECT_DIR/.claude/hooks/launch.sh"` for each entry:

| Event | Matcher | Timeout |
|---|---|---|
| SessionStart | `startup|resume|compact|clear` | 10 seconds |
| PreCompact | absent | 10 seconds |
| Stop | absent | 10 seconds |

For an explicitly enabled Claude context-rollover queue, also register the same
command on `PreToolUse` with no matcher and timeout 10. During calibration it denies
every work tool. The sole neutral exception is native `StructuredOutput` with exactly
the expected loaded_hash, matching observed session and live queue ownership. Native
permissions still apply; this formatter grants no file, shell, network or agent work. The queue refuses
to start without this entry and opens the gate only after native session/window
readback. Ordinary runs and no-run hooks retain their existing behavior.

Once the gate opens, the same entry denies, before the tool runs, any tool the Claude adapter's
allowlist rejects (`tool_refusal` in `launch-claude.py`): subagents, MCP and other unlisted
tools, background shell, and Bash outside declared synchronous commands and command families.
So `git push`, `gh pr` and merges are refused rather than detected afterwards. The native
`StructuredOutput` formatter passes; the adapter validates it. The hook reads the controller
manifest from `LAUNCH_MANIFEST` and denies every tool if its digest no longer matches the run's
controller, or if the run's policy files (`verify.json`, the hook, `scripts/verify.sh`,
`.claude/settings.json`) changed, so an edited check cannot widen what runs. Any hook error
also denies for a queue-launched worker. This is an
allowlist hook, not a sandbox: credentials are still inherited, and same-user code started
outside the hook is out of its reach. The worker launches with `--permission-mode
bypassPermissions`, so the operator's own default mode never decides a run, and only bypass
may write the git dir's acceptance file (`dontAsk` denies it even on a hook `allow`). The hook
is therefore the only gate: admission refuses when the user, project or local Claude settings
set `disableAllHooks`. Native `permissions.deny` rules still apply in bypass mode.
The worker also launches with `--strict-mcp-config`, so no MCP server can connect mid-run and
change its tool set. A tool the hook refused does not block the run when the stream proves it
never ran: an error result plus a matching native permission denial. A refused tool with any
other outcome is still an unresolved operation.

For a prepared Claude task (`launch-target.py` with `platform: claude`), the controller is
the authority on readiness:
- Write the acceptance JSON to exactly `$(git rev-parse --absolute-git-dir)/acceptance.json`.
  It is the only file the gate admits inside the git directories; the worktree's `.git` file is
  refused too.
- Run both canonical verify commands as declared. The gate admits them for this task only.
- `awaiting_review` is a request. The controller re-runs the checks itself, reads that
  acceptance file and decides; a mismatch pauses the task.
- Then a separate read-only Claude reviewer, which you never see or address, judges the
  committed diff against the approved scope. Do not try to review yourself or spawn a reviewer;
  a `revise` verdict pauses the task with its findings.

Never register on SubagentStop. No `LAUNCH_RUN_ID` means immediate no-op. Keep
`--enable-hooks` branch protection and skill suggestions independent. Register hooks
last; preserve all other settings and permission scopes. Do not add interpreter or
shell wildcards. These hooks never run project checks themselves.

## Native Codex generation

The stage renders the same declared checks and task acceptance list into a JSON file,
plus the exact declared command lines into a text file, and calls the converter with
`--enable-autonomy --autonomy-config PATH --autonomy-commands PATH` (see
`launch-queue.md`). The converter
preflights the complete native output before writing. The rendered source must contain
the five-file Launch bundle with supervised recovery routing; an existing native
bundle must match it or generation blocks without overwriting that skill. It creates the native binding
directly, never translates Claude settings or hook frontmatter. Existing compatible
user hook JSON is merged without removing handlers or metadata. Conflicting handlers,
wrappers, configuration, inline `[hooks]`, and changed ownership receipts block.
Same-layer inline hooks are supported by Codex itself; this adapter intentionally
requires one representation to prevent accidental duplicate lifecycle bindings.

This adapter retains the existing `.codex/skills` destination. A project
`.agents/skills/launch` is a discovery conflict for this overlay and must be
resolved explicitly; never delete, rename, or overwrite that skill automatically.

Native paths are `.codex/launch/verify.json`, `.codex/hooks/launch.sh`,
`.codex/hooks.json`, `.codex/launch-control-launch-ownership.json`, and the shared
`scripts/verify.sh`. The receipt owns only files created by this operation. Equal
pre-existing wrappers can be preserved but are not adopted. Existing incompatible
verifiers are never replaced. Publication has exception rollback using the existing
converter; it is not a crash-atomic multi-file installation. Interrupted generation
requires inspection of retained originals before retrying.

The command in each native handler is `bash` followed by the shell-quoted absolute
project `.codex/hooks/launch.sh` path. The wrapper derives the project root from its own
location, resolves the installed runtime through `${CODEX_HOME:-$HOME/.codex}`, and
passes `--platform codex`. Hook input `cwd` still must match the assigned worktree.

| Event | Matcher | Timeout | Context limit |
|---|---|---|---|
| SessionStart | `startup|resume|compact|clear` | 10 seconds | 10000 tokens |
| PreCompact | `manual|auto` | 10 seconds | default |
| Stop | absent | 10 seconds | default |

Review the project and exact hook definitions through Codex `/hooks` before activating.
Never set trust receipts, enable disabled user hooks, or bypass hook trust automatically.
Restart/reload Codex after generation. Hook generation is not trusted execution proof.
The documented contract is https://learn.chatgpt.com/docs/hooks; verify actual installed
lifecycle behavior before declaring a build accepted. Unsupported or disabled hooks
block acceptance; no equivalent continuation enforcement is claimed through instructions alone.

## Explicit activation and recovery

Select one already scoped task in its isolated implementation checkout. Review its
validation config and task-specific acceptance names. Pin the installed runtime and
policy through `start`; configuration changes pause an active run for human review.
These hashes detect ordinary drift, not adversarial same-user tampering.

Set `RUNTIME` to the installed `skills/onboard/scripts/launch-runtime.py` and `PROJECT`
to the exact assigned worktree root. Set `PLATFORM=claude` or `PLATFORM=codex`.
Use an explicit Claude session UUID with Claude's `--session-id`. For Codex use the
actual session ID of the selected thread (from its session details); do not invent a
session ID or select the latest thread implicitly. Create/select that thread normally
before activation, then resume that exact ID with the task environment. This operator
step does not require a new controller or change credentials.

```bash
python3 "$RUNTIME" --project "$PROJECT" --platform "$PLATFORM" start --supervised --task TICKET --session SESSION_UUID
```

Save the returned `run` UUID as `LAUNCH_RUN_ID` in the task session environment. Export
it and `LAUNCH_PLATFORM="$PLATFORM"` only for that session, never globally.
A dual-config project requires that explicit verifier selector. The shared state pins
the platform: the other adapter cannot resume, recover, or consume that run.
Older checkpoints without a platform remain Claude-only and are never auto-migrated. An unrelated session ID cannot consume the
checkpoint. No implicit “latest checkpoint” fallback exists. The state lives in this
worktree's Git metadata under `launch/`; it never modifies BACKLOG.

At each normal phase boundary, record meaningful notes while context exists:

```bash
python3 "$RUNTIME" --project "$PROJECT" --platform "$PLATFORM" notes --run "$LAUNCH_RUN_ID" --text 'Completed work; current evidence; next exact action; unresolved decisions.'
```

PreCompact snapshots those existing notes and mechanical identity. SessionStart loads
only an exact run/session/worktree/branch/revision match. Native `/clear` starts a
new session ID: its exact run envelope and worktree may pause a running task, but
cannot load notes, bind that new ID, or resume work. Other mismatched session
events remain no-ops. Nested working directories must resolve to the assigned
Git worktree; nested repositories and symlink escapes are rejected.
A replacement session requires an operator recovery grant with its new session UUID:

```bash
python3 "$RUNTIME" --project "$PROJECT" --platform "$PLATFORM" recover --run "$LAUNCH_RUN_ID" --session NEW_SESSION_UUID --text 'Approved recovery and reconciled next action.'
```

Recovery preserves phase notes and attempts unless the operator explicitly grants `--reset-attempts`.
It renews a deadline of at most 60 minutes and acknowledges current policy hashes.
Never use it automatically to evade a cap, policy change, pause or exhausted deadline.
Five failed verification attempts persist across sessions. No second task can overwrite
an existing run. Subsequent-task admission belongs to a later slice.

## Verification and stop outcomes

```bash
bash scripts/verify.sh checks --run "$LAUNCH_RUN_ID"
bash scripts/verify.sh ready --run "$LAUNCH_RUN_ID" --candidate COMMIT_SHA --acceptance /absolute/path/to/evidence.json
```

The acceptance JSON contains `repo`, `worktree`, `branch`, `run`, `task`, and `revision`
matching the run and candidate, plus `platform` matching the selected adapter and `evidence`, a mapping from each required acceptance
name to a nonempty evidence reference. Keep it outside tracked project content. These
are supplied evidence references for human review, not independently proved assertions.
Local checks record command, cwd, exit, timing, bounded diagnostic output, tree/config
hashes and revision. A changed tree or policy invalidates readiness. Avoid placing
secrets in check output; pilot fixtures contain synthetic data only.

`ready` never commits. When committing requires authorization, persist `paused` and
request it with the concrete reviewed diff. A successful ready result becomes
`awaiting_review`, never `done` or shipped. Read the full diff and referenced evidence
at the human delivery gate. CI, deployment, and device acceptance remain separate.

```bash
python3 "$RUNTIME" --project "$PROJECT" --platform "$PLATFORM" pause --run "$LAUNCH_RUN_ID" --text 'Concrete approval boundary or user stop.'
python3 "$RUNTIME" --project "$PROJECT" --platform "$PLATFORM" block --run "$LAUNCH_RUN_ID" --text 'Missing capability or unresolved decision.'
```

Stop asks a running task to reach a phase boundary. A second consecutive blocked Stop
pauses rather than looping indefinitely. Terminal runs stop normally; hook errors
cannot advance a task. The event-time deadline is not a process watchdog: This runtime
requires supervision, and no hard aggregate token/cost containment is claimed.

Retain the active checkpoint, pinned terminal evidence and at most 15 ordinary
snapshots for the task. Interrupted atomic writes leave the prior active state usable.
Manual `/checkpoint-save` and `/checkpoint-load` files are outside retention. Keep the candidate and
all evidence when deactivating; stop only processes owned by this task.

## Explicit bounded queues

For admission of a selected set of tasks in prepared worktrees, use
[the bounded queue contract](launch-queue.md). The queue supervisor owns next-task
selection; each existing runtime still owns exactly one task and its evidence.

For one source task, that contract also documents the opt-in Codex project-policy
preparer, explicit heading/table selection, completed-prerequisite binding, canonical
generation and independent review.

## Restricted delivery preparation

The optional `delivery` target-policy binding prepares a dedicated clone and runs one
Codex task through independent review. This version stops at `awaiting_review`; it
cannot push, create a PR, merge, deploy or mark a source Done. Unbound queues keep
their existing behavior. The supported host is macOS with Codex CLI 0.162.0 and
Python 3.11 or newer. Unknown host policies and other source providers refuse admission.

Keep the grant, host policy, target policy and output manifest outside the worker clone.
The grant and manifest must share a directory. Preparation reserves
`delivery-preparation.json` there before fetching; a failed or interrupted preparation
is retained and cannot be replayed into that directory or clone.

The existing target policy gains only this optional field:

```json
{"delivery":{"grant":"/controller/grant.json","digest":"<grant-file-sha256>"}}
```

The grant has exactly these fields. Placeholder hashes and paths must be replaced with
reviewed values; the controller never approves whatever files happen to be installed.

```json
{
  "schema": 1,
  "target_digest": "<canonical-target-payload-sha256>",
  "verification": {
    "schema": 1,
    "checks": [{"command":"python3 test_totals.py","cwd":".","timeout":10}],
    "acceptance": ["behavior","independent-review"]
  },
  "repository": "owner/repo",
  "base_branch": "main",
  "base_revision": "<full-approved-commit>",
  "source": {"path":"BACKLOG.md","format":"table","heading":"# Selected","blob":"<source-git-blob>"},
  "workspace": "/owned/new-worker-clone",
  "host_policy": {"path":"/controller/reviewed-host.json","digest":"<host-policy-file-sha256>"},
  "allowed_actions": ["prepare","implement","review"],
  "minutes": 15,
  "max_attempts": 2,
  "max_launches": 1
}
```

`target_digest` hashes the complete target JSON after removing only `delivery`, using
sorted keys, compact separators and UTF-8. `target_digest()` in `launch-delivery.py`
implements that operation. Scope, source, generator arguments and every limit are
therefore frozen before preparation. The generated verification JSON must equal
`verification` exactly. Missing required actions and unknown actions reject; granting
later delivery actions does not enable them in this version.

Use the canonical generator argv beginning with the reviewed absolute Python path,
`-I`, and the adjacent `codex-parity.py`. Supply its existing explicit source,
verification, commands, selected-controller and shared-root arguments; shared root is
the new clone. Its project argument is `{worktree}`. Pin all rendered input files,
controller scripts and generator inputs in the host policy. Do not include
`--autonomy-delivery-binding` or `--autonomy-delivery-binding-digest` yourself:
preparation injects the validated pair after checking the frozen argv. Including the
grant hash inside the frozen argv would create a circular digest.

The reviewed host policy has exactly these fields:

```json
{
  "schema": 1,
  "platform": "Darwin",
  "codex_version": "codex-cli 0.162.0",
  "codex": "/runtime/codex",
  "python": "/runtime/python3",
  "git": "/runtime/git",
  "gh": "/runtime/gh",
  "path": ["/runtime/bin","/usr/bin","/bin"],
  "read_roots": ["/runtime","/reviewed/generator-inputs"],
  "read_files": ["/controller/checks.json","/controller/commands.txt"],
  "files": {"/runtime/codex":"<sha256>","/reviewed/hook.sh":"<sha256>"},
  "native_config": {"path":"/native/config.toml","execution_digest":"<execution-config-sha256>"},
  "native_overrides": ["mcp_servers.example.enabled=false"],
  "hook_commands": {"/reviewed/hook.sh":["/reviewed/hook.sh","/bin/bash","/reviewed/transitive-helper.py"]}
}
```

The `files` example is abbreviated: every selected executable, global hook definition,
configured hook interpreter/script and reviewed transitive helper must be present.
The exact configured command set, including disabled hooks, must equal `hook_commands`
keys. Direct execution and known interpreter names resolved through the declared PATH
are supported; shell operators, substitutions, `-c` and opaque wrappers reject.
Inline native hook definitions are unsupported; only `hooks.state` is admitted there.
Loaded custom agent configuration files must also be pinned. Each configured MCP server
and plugin needs its exact disabling override; startup additionally checks that the
complete paginated native tools inventory is empty.

Native TUI trust changes only narrowly validated `projects.*.trust_level` and
`hooks.state.*` trust/enabled metadata. `execution_digest()` excludes those fields and
pins every other execution setting. All configured hook code remains pinned regardless
of enabled state. Do not put native `config.toml` into the raw `files` hashes as well.
Unknown trust fields reject. A mission task's setup writes only its own project trust and
generated hook hashes into the native config, with a retained request per write. Once the task
is delivered or blocked, teardown removes each of those entries that still holds the written
value; anything changed since is left alone. A paused or pending task keeps its trust so it can
resume. No other global setting or hook is changed.

Preparation reads the explicit GitHub base/source and requires exact identity and local
source bytes. Its only credentialed Git command is a no-checkout fetch from an empty
owned directory with clean Git configuration and the reviewed `gh` helper. Candidate
checkout, generation, controller Git, host checks and generated host-hook dispatch run
inside a network-free sandbox with an explicit clean inner environment. The clone's
local commit identity comes from the authenticated GitHub account's login and noreply
address. No user Git configuration or original checkout is changed.

Worker tools can write only the assigned clone/worktree metadata and candidate files.
Queue authority, generated configuration, Git config/pointers and canonical verifier
stay read-only. They cannot read native credentials or the external grant. Required
runtime and reference reads must be explicitly listed; HOME, native-home roots,
credentials and authority directories cannot be broadly granted. The controller
revalidates bindings before Git, startup and every actual turn; unknown metadata or
configuration drift blocks without renewing counters or deadlines.

After preparation, complete normal Codex trust for the generated primary/worktree
hooks, then use the existing queue `init` and `run` commands with the emitted manifest.
One grant is permitted per controller process. Missing trust, an unsupported permission
profile, connected tools, changed inputs or surviving processes retain a blocked run.
Installed native acceptance is separate from local tests and from future publication.

## Finite missions

`launch-mission.py` delivers an approved, ordered task set one restricted child at a time,
with no per-ticket setup and no hand-written per-task content. `plan` reads the selected
BACKLOG section from GitHub at the base branch head and writes the mission file once:

```json
{"repository":"owner/repo","base_branch":"main",
 "source":{"path":"BACKLOG.md","heading":"## Selected"},
 "template":{"policy":"/controller/policy.json","grant":"/controller/grant.json"},
 "caps":{"minutes":120,"max_attempts":4,"max_launches":4,"max_tokens":30000000,
         "task_minutes":60,"task_max_attempts":2,"task_max_launches":2}}
```

Every Todo row becomes a task in priority order, with the same scope boilerplate plus the
row's Item cell and the same exact commands (the canonical verifiers and the repair review
pair); command families cover the rest. Done rows are ignored. A row that is not eligible,
has an empty Item, depends on an ID outside the section, depends on a skipped row or sits in
a dependency cycle is listed under `skipped` with its reason. A Todo row that depends on an
earlier Todo row waits until that row is Done, even when it ranks higher. `plan` never replaces
a different mission file; rerunning it on the same source is a no-op.

The template is one reviewed single-task delivery policy and grant. Each child's authority
is derived from it by a closed list of overwrites (base, blob, workspace, clamped limits, the
task's scope and commands, writeback, digests), and any other difference refuses. `init`
requires the tasks and `skipped` rows to equal what `plan` produces for the current source.
Publication refuses a candidate that changes `.github/` (workflows and the actions they run),
generated Launch files (`.codex/`, `.claude/`, `.agents/`, `scripts/verify.sh`) or an approved
dependency lockfile, compared case-insensitively. A mission written before `skipped` existed,
or before each scope named the autonomy reference, must be re-planned.

`launch-stage.py --config project.json` builds that template, so the operator writes only
project input: `repository`, `base_branch`, `source` (`path`, `heading`), `checks`, `acceptance`,
`dependencies` (`cwd`, `manifest`, `lockfile`, `build` argv, `target`), `publication`
(`required_checks`, `billing_fallback`) and `caps`. A build argv that starts with an npm name and
version (`pnpm@10.33.2`) installs that tool once under `~/.local/share/launch-control/` and puts it on
the worker PATH; codex is always pinned to 0.162.0. The stage writes `stage/` beside the config
once: dependency trees built from the base manifests and lockfiles, the rendered launch skill,
`verify.json`, `commands.txt`, the host policy derived from this host (executables, read roots,
native config, hook commands), the template policy and grant, and the planned mission. It checks
the grant with the same admission the run uses, then prints the mission digest and the `init`
command. Each task's scope names this pack's autonomy reference by absolute path. Remove `stage/`
to restage.

`launch-go.py --config project.json` is the one command. `mission/` beside the config is that
config's mission root. If it holds an `active`, `paused`, `error` or `publication_pending` mission,
`launch-go` lifts any pause (never while a run holds the mission lock) and resumes it with `run`; it
never restages and never resets limits, so an exhausted limit stops it again. A `complete` mission
is reported. `merged_source_pending` is refused and has no automatic resume: confirm the merge on
the host, mark the source row Done by hand if it is not, then move `mission/` and `stage/` aside.
Never move them while the row is still Todo: a new mission would deliver the task again.
(`reconcile` applies only to a dispatch that left no child state.) `blocked` is refused with its reason.
Otherwise it stages (or reuses an unconfirmed `stage/` built from the same `project.json`), prints
the `init --dry-run` summary and asks once;
with no terminal, pass `--approve <mission digest>` instead. Then it runs `init` and `run`.

```bash
python3 launch-mission.py --root /controller/mission plan --config project.json --out mission.json
python3 launch-mission.py --root /controller/mission init --mission mission.json --digest <sha256> --dry-run
python3 launch-mission.py --root /controller/mission init --mission mission.json --digest <sha256>
python3 launch-mission.py --root /controller/mission run
python3 launch-mission.py --root /controller/mission pause
```

`init` prints the task set, skipped rows, limits, token soft cap and stop conditions. Each later task must
start from the previous task's Done commit, whose only parent is its merge; any other head
stops the run. Attempts, launches and tokens from every child, delivered or not, count against
the run caps. A blocked task does not stop an independent later task. Outcomes are `complete`,
`blocked`, `paused` (with the limit named), `merged_source_pending` and `error`. A signal-killed
child resumes once on the next `run`; a dispatch that left no child state is never replayed
and needs `reconcile <id>`.
