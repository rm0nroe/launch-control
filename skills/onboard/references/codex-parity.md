# Codex parity

The finalizer automatically generates native artifacts when `.codex/` exists.
For explicit `--codex`, write `requested` to `.launch-control-onboard/codex-requested`
after the discovery checkpoint. In dry-run mode write nothing; list the proposed
Codex paths in discovery instead. Check Python 3.11+ before any project writes.

The finalizer calls `scripts/codex-parity.py` on the rendered Claude artifacts.
Shared source definitions generate agent TOMLs, skills, and commands as skills.
Codex reads `AGENTS.md`, not `CLAUDE.md`, so the finalizer also mirrors the verified
`CLAUDE.md` generated block into `AGENTS.md` with only its paths converted (product names stay as written): created when absent,
only the block replaced or appended otherwise. A symlinked, CRLF, or uncommitted-edited file
is reported `KEPT` and the renderer still flags a stale block in it; commit `AGENTS.md` after
onboarding so later runs can refresh it. User prose outside the block is never touched.
A Codex-only onboard has no project block, so the finalizer mirrors the block staged at
`CLAUDE.md` beside the `--source` tree instead.
Never create or change project `.codex/config.toml`. Agent models and reasoning efforts come
from `references/codex-model-tiers.json`. Never silently inherit a root model.

Existing project Codex files and whole skill directories are preserved, except for
ownership-checked upgrades of the three static skills described below. Project config
is optional and does not need local agent defaults. Existing config must remain valid TOML;
explicit hook conflicts still block autonomy. Symlink paths block conversion.

Claude hooks and settings permissions are not converted. For a Launch run the stage passes
`--enable-autonomy`, and the converter separately creates native hooks from the shared lifecycle contract;
read `launch-autonomy.md` for generation, preservation, trust and activation. Native read-only agent
sandboxing is generated, while source tool names remain guidance only. Do not claim
Claude hook enforcement in Codex. The final report lists native created/preserved
paths separately; generation is not proof of actual subagent model selection.

Use `./install.sh --codex` from Launch Control to install the 22 native user-level core
skills, shared resources, and agents. Global skill bundles use a separate Codex digest
registry: current copies are skipped, known released copies upgrade with timestamped
backups outside discovery, and unknown or modified copies stop before writes. A named
`--force-skill NAME` permits an explicitly approved replacement; symlinks still block.
Config and existing agents remain preserved. Normal project onboarding refreshes eligible static skills through the same ownership checks.
The installer never invokes Claude plugins and requires Python 3.11+; no packages.

## Explicit agent refresh

`--update-agents` updates only project agents from rendered `--source` (default
`.claude`). Generated outputs receive ownership records under
`launch-control-agent-ownership/`; unchanged recorded outputs can safely upgrade. Unknown
or customized project agents require a reviewed, repeatable `--force-agent NAME` and
are never adopted by equality alone. Config, skills, and checkpoint-save/-load/-list remain
preserved. Global agent-only refresh is `./install.sh --codex --update-agents`, using
released-source hashes plus the same preview and named force behavior.

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
