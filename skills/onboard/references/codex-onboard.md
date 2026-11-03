---
name: onboard
description: Configure a project for Codex using Launch Control's shared project templates and explicit subagent model tiers. Use for onboard, init workspace, or Codex parity.
---

# Onboard for Codex

Arguments: `--dry-run`, `--launch-control`, `--codex`, `--update-agents`, repeatable
`--force-agent NAME` (requires `--update-agents`). Reject other flags before writes.
Do not combine `--launch-control` with `--update-agents`.
`--codex` is implicit in this native skill. Python 3.11+ is required.

## Discover

Read project AGENTS.md, CLAUDE.md, README, build declarations, CI, and existing
`.claude/skills`, `.claude/agents`, `.claude/commands`, and `.codex` artifacts.
Do not read secrets, credential files, or personal global instructions. The safe examples
`.env.example`, `.env.sample`, `.env.template`, and `.env.local.example` are not secrets: read
them, since shared templates resolve values such as `BACKEND_LOCAL_URL` from them. Determine the
exact declared validation commands, base branch, platforms, and review concerns.
Keep the branch and all dirty or user-authored files. Do not install dependencies,
stage, commit, push, change global config, or weaken session permissions.
Check the session's actual sandbox and approval policy before applying. Workspace-write
normally protects `.git/`, `.codex/` and `.agents/`; explicitly writable paths may differ.
Stage and preview even when the apply will be blocked: the preview writes nothing to the project.
After a successful preview, run the apply normally when its required writes are permitted.
If it needs writes outside the sandbox, request approval for that apply command alone only
when the session supports it. If approval is unavailable or denied, stop and report the
preview's proposed paths, the exact apply command and the blocked paths. Never change the
session policy to enable it.

## Generate from shared definitions

For an already onboarded project, use its existing rendered Claude artifacts as the
source. A project onboarded only by Codex has no `.claude/`: stage a rendered tree as for a new
project below, pass `--source "$STAGING/.claude"` to both commands, then remove the staging
directory. Run the converter below with `--dry-run` first. It refreshes eligible static skills, preserves other Codex
files, and never creates or changes project `.codex/config.toml`. Local agent defaults are not required.
The converter creates or upgrades checkpoint-save, checkpoint-load, and checkpoint-list from the installed templates, even when the rendered Claude tree is older. They use `<project-root>/.claude_states/`, created on first save; legacy home checkpoints remain read-only.

For a new project, read `references/checkpoint-templates.md`, `references/artifact-templates.md` and the five
`references/launch-*-template.md` files (including `launch-template.md`) completely.
Also read `references/skills-agents-and-commands.md` completely: its token table, its rule
for values that cannot be detected and its skill, agent and command tailoring tables govern
rendering here. Its `.claude/settings.json`, permission and Phase 5 audits are Claude-only.
Resolve all template values from discovery. Render the five core skills plus checkpoint-save, checkpoint-load, and checkpoint-list, inspector
and dispatcher agents, eligible commands, and five-file Launch using those same
source definitions. Stage that rendered `.claude/` tree in a disposable directory,
never in the user's project. Codex reads project guidance from `AGENTS.md`, so also stage
`$STAGING/CLAUDE.md` as exactly the generated block: read Phase 3 of
`references/claude-md-and-documentation.md` completely and render its scenario A, without
the `artifacts/` reference documents, which Codex onboarding does not create. Never write
`AGENTS.md` yourself: the converter mirrors that staged block into it with paths converted,
keeps user prose, and reports a dirty, CRLF, or symlinked `AGENTS.md` as `KEPT`. A project
`CLAUDE.md` that already carries the block wins over the staged one.
Pass `--source "$STAGING/.claude" --project "$PWD" --codex` to the converter
below. It validates the prospective artifacts before writing the absent destinations.
Fill each Launch `MODEL_INSERT` zone by the Model insertion pass in `references/launch-generation.md`.
Tailor every artifact in the staged tree before the preview. Never edit generated `.codex/`
files after the apply; report a defect found during verification instead.
Remove only your staging directory after completion.

On normal onboarding, add `.claude_states/` to a clean project `.gitignore` if not already ignored; preserve a dirty or symlinked `.gitignore` and report that follow-up instead. Never stage checkpoints.

The project-native output is `.codex/skills/` and `.codex/agents/`. Never create project `.codex/config.toml`; preserve an existing one.
Read the model mapping from `references/codex-model-tiers.json`; never invent a model
or silently inherit the root model. Preserve customized and project-tailored skill trees, including
their references; refresh unchanged released static skills through the converter. In `--launch-control` mode, touch only an absent Launch skill.

```bash
python3 "${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/codex-parity.py" --project "$PWD" --codex --dry-run
python3 "${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/codex-parity.py" --project "$PWD" --codex
```

Pass `--launch-control` to both commands when requested. Dry-run stops before all writes,
including staging. Show proposed paths and validation commands, then stop.

## Supervised native autonomy

## Updating existing agents

For `--update-agents`, skip normal artifact generation. Discover the project constraints,
render current project agents into a disposable `.claude/agents/` source tree, and do
not copy global agent bodies over project agents. Preview and apply only the agent update:

```bash
python3 "${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/codex-parity.py" --project "$PWD" --source "$STAGING/.claude" --update-agents --dry-run
python3 "${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/codex-parity.py" --project "$PWD" --source "$STAGING/.claude" --update-agents
```

Propagate only explicitly authorized, repeatable `--force-agent NAME` values to both
commands. The command updates only agents: config, skills, checkpoint-save/-load/-list
templates, and unrelated files remain untouched. Records live in
`.codex/launch-control-agent-ownership/`; backups live outside discovery in
`.codex/launch-control-backups/`. Unknown/customized agents stop the complete operation
before writes; symlinks always block. Reload Codex and verify the named role separately
from file generation.

## Native behavior and verification

Claude lifecycle hooks, settings.json permissions, and commands are not Codex syntax.
Do not copy hooks or claim Claude policy enforcement. The explicit autonomy opt-in
generates its own native hooks from the shared lifecycle contract. Commands become Codex skills;
agent tool scopes are guidance, with read-only agents additionally using the native
read-only sandbox. Parent runtime permissions remain authoritative.

Launch must retain the complete CRISPY chain and review checkpoints. Resolve those
skills from the live skill inventory; report missing dependencies rather than
claiming the chain is usable. Never install packages to satisfy them during onboarding.
Only delegate when authorized by the user or applicable instructions. Use the named
agent role when available. If it is unavailable, use explicit mapped model/effort
with `fork_turns="none"` and pass its instructions; never silently use a flagship.

After generation, parse every TOML with Python tomllib, re-read created files, check
references and unresolved placeholders. Onboarding never runs a project's own commands,
scripts or code: record the declared validation commands as documented gates, exactly as
their source prescribes, and disclose anything that looks off as a note. Report
created/preserved paths, the documented gates, missing skills, and any Codex reload
requirement. File generation does not prove a live subagent used the selected model;
report live model selection only after observing it.

## Portable project skill refresh

Normal onboarding automatically refreshes unchanged released or receipt-owned
`checkpoint-save`, `checkpoint-load`, and `checkpoint-list` bundles from the installed templates. It checks
complete contents and executable bits, preserves customized or dirty tracked bundles,
and reports those paths for review. Codex also refreshes existing `.claude/skills/` and `.agents/skills/`
copies so an old duplicate cannot silently shadow the updated `.codex` copy. An
unknown duplicate is preserved and reported. Project-tailored skills remain preserved.
Update the Launch Control installation first, then rerun `/onboard` in the target repo.
No force flag or extra confirmation is needed for a normal authorized onboarding run.
Reload the runtime after updates.

Use this standalone maintenance command to refresh only `checkpoint-save`, `checkpoint-load`, and
`checkpoint-list`. It is separate from `/onboard`; it does not change onboarding arguments,
lifecycle hooks, agents, global skills, or runtime configuration. Python 3.11+ on
macOS or Linux is required. Select each skill and `claude`, `codex`, `agents`, or `both` explicitly (`both` means Claude and Codex).

```bash
REFRESH="${CODEX_HOME:-$HOME/.codex}/skills/onboard/scripts/portable-refresh.py"
python3 "$REFRESH" preview --project "$PWD" --runtime both --skill checkpoint-save --skill checkpoint-load --skill checkpoint-list
python3 "$REFRESH" apply --project "$PWD" --runtime both --skill checkpoint-save --skill checkpoint-load --skill checkpoint-list --expect-preview APPROVED_SHA256
python3 "$REFRESH" inspect --project "$PWD"
python3 "$REFRESH" recover --project "$PWD" --operation OPERATION_ID
```

From a Claude installation, set `REFRESH` to
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts/portable-refresh.py`.
Review the preview's exact paths, changes, and ignore-file append. Replace
`APPROVED_SHA256` with its `approval_digest` only after approval; apply repeats preflight
under the project lock. Forward exactly the selected names and runtime. Conflicts stop
before selected-bundle changes; there is no force or adoption option. Identical unknown
bundles remain unowned. Old bundles without receipts upgrade only when their entire manifest matches a
released fingerprint. Unknown bundles require a reviewed manual backup/replacement.

Stop using these skills during refresh and reload the runtime afterward. Publication
is not atomic across bundles: a reader can briefly see an old, new, or absent bundle.
State, receipts, retained originals, and quarantine live under `.launch-control/refresh/`,
outside discovery. Apply reports and adds its Git exclusion; linked worktrees use their
own `.gitignore` instead of changing a shared Git exclusion file. Checkpoints and
unrelated skill files remain intact.

An incomplete operation blocks another apply. Inspect it, then use its exact
`OPERATION_ID` for explicit recovery. Recovery preserves concurrent edits, restores an
unchanged original payload before its receipt, and can be repeated after interruption.
Committed operations refuse rollback; recovered operations are unchanged on repetition.
Portable-refresh backups and quarantine are retained, never automatically deleted. Unsupported exclusive
rename, directory flush, symlinks, malformed state, and different target/state devices
fail closed. Tested process-interruption recovery does not establish power-loss durability.
