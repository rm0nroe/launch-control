# Launch Control backlog

Open work, ranked. This file is the durable ledger: an item leaves the open list only when a
validator gate or a live run proves it closed, not when it stops being mentioned.

**Current state (2026-10-24):** the rename is complete: the product, paths, skills and ticket IDs
say Launch Control (`LC-###`, formerly `GW-###`); old names survive only where an upgrade reads
them once. Before that,  `v0.2.0` shipped finite BACKLOG.md mission delivery in one
repository (LC-033). On Codex a mission implements, checks, reviews, merges and marks Done each
eligible row in dependency order; the Claude Code path stops at review-ready (PRD decision D4).
Acceptance evidence: the LC-033 ledger, kept in the maintainers' private design record.
Full text of every closed item below, including historical failures and requirements, is in
[BACKLOG.md at `v0.2.0`](https://github.com/rm0nroe/launch-control/blob/v0.2.0/BACKLOG.md).

**Delivery policy:** when GitHub Actions minutes are exhausted, the repository's own gates
passing locally satisfy the merge requirement. Record commands, revision and results; report
hosted CI as unavailable, not passed.

**Ranking is a claim about evidence, not a queue position.** Two P2s carried for rounds in
August were not defects at all. Investigate an item before scheduling it.

`LC-XXX` IDs record when an item entered the backlog; they do not encode priority.

---

## P2: open work

- None.

---

## P3: coverage gaps, not defects

Gates nobody has managed to trigger. Absence of a failure here is absence of evidence.

- **LC-005: nothing checks the agent's baseline file for completeness in degraded mode.**
  Filed as `ONBOARD-DEGRADED-BASELINE-COMPLETENESS` (never opened) in
  `workbench/ONBOARD-ROUND31-PROSPECTIVE-GATE/decision/2026-08-05-sites-6-7-coverage.md`. With
  hooks live, the guard's own capture covers a short file (one live sample: 199 rows against the
  guard's 213). Without hooks the report under-reports with no signal. The renderer cannot catch
  it alone: the baseline is a run-start fact and the renderer runs at the end, so the fix needs a
  new attestation (design work). Sites 6/7, the `unquote_git_path` newline branches in
  `render-report.sh`, stay fixture-only by that decision (`60-round12.sh`).
- **LC-029 residual: native Claude threshold crossing never observed.** Accepted gap under PRD
  decision D1 (ledger G1 Claude row); Claude handoff passed on calibration, load and admission.
- **LC-030 residual: delivery workers see the host's global `AGENTS.md` and skill catalog.**
  Codex memories are off for workers. Triaged 10-22 on the pinned Codex 0.162.0 with the
  delivery's overrides: a control phrase from `~/.codex/AGENTS.md` was recalled, the model saw
  217 skills, and `skills/list` returned 370. MCP does not leak (`launch-stage.py` disables each
  server by name). Per-delivery `CODEX_HOME` is not the full fix: with an empty one, 123 skills
  still load from `~/.agents/skills` (HOME-based), and it would need `auth.json` copied in, a new
  binding for the `config.toml` execution digest, which requires the config at
  `CODEX_HOME/config.toml` and pins it with `hooks.json` there (`launch-delivery.py`). `-c skills.include_instructions=false` empties the
  catalog but hides `/launch` and the Paperclip skill the worker prompt names
  (`launch-queue.py`). Cost is tokens and determinism, not a trust boundary (operator-owned
  content, as under D4). Needs a design decision; deferred until a delivery misbehaves.
- **LC-040: Codex review-only readiness is worker-attested.** A Codex queue manifest without
  `delivery` (`launch-queue.py` `Queue.__init__`) stops at review, and the Codex branch of
  `context()` trusts `receipt.ok` in the worker-writable `<gitdir>/launch/active.json`.
  Missions are unaffected: `launch-stage.py` always grants publication, which re-verifies on
  fresh objects. With native review off it is weaker still: the queue trusts the worker's
  `awaiting_review` status without even `receipt.ok` (`launch-queue.py` `finish()`).
  Documented in `launch-queue.md`. Fix (about a day, deferred until this path
  is in real use): a controller re-check inside `codex sandbox` that needs no publication
  binding. Never `controller_recheck`, which runs checks outside the sandbox.
- **LC-031 accepted under D4 (Ryan, 2026-10-22): the Claude worker has no OS boundary.** With
  no delivery binding, `launch-queue.py` launches it with `{**os.environ, ...}`, so `GH_TOKEN`
  and the operator's `gh` login pass through, and the gate allows absolute reads and sibling
  writes. The PreToolUse gate blocks `git push`, `gh pr create` and unclassified shell such as
  `curl`. The residual risk is code the worker writes into the worktree that a declared check
  or the canonical verify then runs with the inherited token, or a write to a home file such
  as `~/.zshenv` or `~/.gitconfig`. Revisit if Claude delivery runs on
  repositories the operator does not own.
- **LC-031 residual: outer hook launcher and user Codex hooks run unsandboxed.** The launcher
  (`.codex/hooks/launch.sh`) only digest-checks and loads `launch-delivery.py`, whose
  `run_hook` sandboxes the hook code; user hooks are pinned by inventory, not confined. The
  isolation acceptance (`tools/accept-launch-isolation.py`) is manual: CI has no Codex or
  seatbelt. It passed 95/95 on the pinned Codex 0.162.0. An unpinned upgrade cannot run (the
  binding refuses any other version, `launch-stage.py` `CODEX`), so rerun it on a pin bump or a
  `permission_options` change.
- **LC-020 residual: live Codex subagent model usage never measured.** Tiers are configured and
  role selection was observed; per-completion model telemetry was unavailable.

## P4: cosmetic and housekeeping

- None.

---

## Structural work: why the bug count does not converge

Fixtures are hand-written from the implementation, with the same blind spots. Mutation testing
proves the suite kills the defects that were imagined: round 38 shipped 7/7 mutants green
while the resolver corrupted real content. Each live run explores state the fixtures never
covered, so the count rotates. The realistic end state is no P1/P2 and every gate observed
firing once. These move discovery from manual runs into the validator:

1. **LC-010: replay corpus of real tool payloads.** Seed with the three `Edit` payloads from run
   `3642a3b0` and rymonroe.com's 23 KB em-dash-heavy `launch/SKILL.md`; assert byte-exact
   post-edit output. This check, run by hand, caught round 38b.
2. **LC-011: non-ASCII fixtures by default.** Em dash, smart quote, CJK and emoji in every
   fixture under `tools/validate/`. Nearly free; would have caught round 38b alone.
3. **LC-012: spike a headless `/onboard` harness.** Feasibility unknown; spike it, do not assume.
4. **LC-013: differential resolver test.** Apply each `Edit` with an independent implementation
   (Python `str.replace`) on randomized inputs and compare.

---

## Closed

- **LC-037 residual: a successful run left its mode markers and deny counters in `.git`**,
  2026-11-04: the cause was not a hook that failed to fire. The Stop success terminal removed nine
  state files and stamped `.disarmed` but never removed `.bypass`, `.permission-mode` or the five
  `*-denies` counters, and the only sweep that does is the next `/onboard` in that repository.
  All five live sets (three in target repo C, two here) carried `.disarmed`, so all were
  successful runs. The terminal now clears the same family the re-arm sweep clears, minus the
  off switch; the renderer reads those files before Stop and the policy stamps nothing once
  disarmed. `30-guard-lifecycle.sh` plants all seven and asserts only `.disarmed` survives;
  mutation-proved 7/7. `.disarmed` itself still stays, by design: it is the session's off switch
  (round 37), one empty file per successful run, cleared by that session's next `/onboard`.
- **LC-031 residual: a remote base-push refusal waited for the deadline**, 2026-11-03:
  `acknowledge_merge` read any push failure other than a stale lease as "awaits readback", so a
  `[remote rejected]` push (a ruleset or pre-receive hook added after preflight) polled until the
  publication deadline. With the base unchanged the refusal is final: it now blocks at once as
  `delivery_blocked`, still retained and never resent or forced. A transport failure, or a base
  that moved, stays `publication_pending`. Mutation-proved 3/3 in `test-launch-publication.py`.
- **LC-014: generated `/validate` did not disclose a gate already failing at onboarding**,
  2026-11-03 (dissolved, no code change): the `validation: failed (1/2)` line came from an
  onboard that ran the project's gates. Since LC-037 (#71) onboarding never runs them, so it
  never knows a gate fails; the report reads `validation: not run (<N> documented gates; ...)`,
  pinned in `30-guard-lifecycle.sh`, `40-report-contract.sh`, `70-round13.sh` and `80-round41.sh`.
- **LC-061: a re-onboard mislabeled current checkpoint skills as customized**, 2026-11-03: found
  re-onboarding this repository after `/offboard`. Offboard removed the checkpoint bundles but
  left their portable-refresh receipts, and `preview()` compared the receipt before the bytes, so
  a byte-current bundle beside an older receipt read `PRESERVED-CUSTOMIZED` and would have been
  skipped by every later template upgrade. Current or released bytes now outrank a receipt, and
  offboard now removes a removed bundle's receipt plus the untracked `/onboard --codex` mirror
  under `.codex/` (it used to leave `.codex/` behind, so a later plain `/onboard` silently
  re-entered Codex mode). Refresh backups and `.codex/config.toml` are never touched. The
  same run showed Codex got skills but no project guidance, since Codex reads `AGENTS.md` and
  onboarding never wrote it: in Codex mode the trusted finalizer now mirrors the verified
  `CLAUDE.md` generated block into `AGENTS.md` with only its paths converted, touching only that block.
  Live acceptance then showed two gaps, both fixed: offboard never stripped that `AGENTS.md` block
  (no manifest lists the file; a symlinked merge target is now never rewritten either), and a
  Codex-only `$onboard` wrote no `AGENTS.md`, so it now stages the block beside its rendered tree.
  Offboard also removes the stale onboard visual report under `.git/launch-control/`.
- **LC-059: the pack was cut to 17 skills and its crew renamed**, 2026-11-02: the `--extras`
  packs and their skills, the pack checkpoint copies, `debate`, `debate-consensus`,
  `improvement-loop`, `issue-verify`, `docs-to-confluence` and `onboard-cursor` are gone;
  `/onboard` still generates project checkpoint skills. `domain-facts` is now `catalog` and
  writes guide stars to `guide-stars/`, `decision-record` is now `log-decision`, and the new
  read-only `logbook` lists decisions newest first. The pack agents are now `surveyor`,
  `navigator`, `veteran`, `technician`, `integrator`, `skeptic` and `editor`; generated
  `code-reviewer` and `github-workflow` are now `inspector` and `dispatcher`. `NOTICE` and
  `PROVENANCE.md` credit HumanLayer for `research-codebase` and five of the agents.
- **LC-058: the completion report graded the session's permission mode**, 2026-11-02: the
  "Review mode" station was GO only in `default` mode, so every auto or bypass run showed
  CAUTION, and "Flight checks" had no GO branch at all since LC-037. Both stations are gone,
  the `permission-mode:` line states the mode as a fact, and the bypass deny message no
  longer pushes default mode. The unattended policy's safety denies are unchanged.
- **LC-057: web verification named only an MCP tool**, 2026-11-02: a target repo C `/launch` run got
  "use `mcp__chrome-devtools__*`" and nothing else; with no browser MCP the section named no
  driver. It now names the capability and a driver order, starting with the project's own
  browser tests (what worked on target repo C), and the result says which driver ran.
- **LC-056: a generated delivery gotcha dropped its condition**, 2026-11-02: target repo C's
  "merging does not deploy" applies only when Actions minutes run out and excludes Vercel
  `ui/`, but the gotcha stated it unconditionally. Gotcha bullets must now keep their source's
  condition and exceptions (Codex is pointed at the same rule), and the delivery template says
  a merge that triggers a deploy is a deploy and needs authorization as one.
- **LC-055: dead `doc_declared_omitted_file` deleted**, 2026-11-01: the renderer wrote it and
  nothing read it after #71. The 13 target repo C "duplicates" were real disclosures: a bare
  `pnpm test:x` keys to the repo root, so `npm --prefix api run test:x` stays undeclared until
  the record spells it that way. Filtering by the file would also have hidden every documented
  gate the record omits, so it was deleted with `nested_gate_doc_needles`, the unread `any`
  fragment scope and the stale "blocks" comments. Pinned in `70-round13.sh`: a doc-named nested
  gate stays disclosed (mutation-proved, a filter mutant drops it).
- **LC-054: Codex onboarding rendered templates without the tailoring rules**, 2026-11-01:
  the live `$onboard` run read only the raw templates, never `skills-agents-and-commands.md`,
  so it rendered a TypeScript-only mock rule, an empty single-file test command and an
  Atlassian default into a JavaScript repo, then hand-edited the generated `.codex/` files.
  The restricted-sandbox run stopped before the preview. Both runtimes rendered `/ticket`
  with an in-place branch. `codex-onboard.md` now routes to the tailoring rules, requires
  the preview on blocked runs and forbids post-apply edits; `/ticket` is worktree-first.
  Pinned in `tools/validate/70-round13.sh`.
- **LC-053: Codex onboarding ran the project's own commands**, 2026-11-01: `codex-onboard.md`
  told the model to run the declared gates, and a live run executed `npm run lint` and
  `npm test` in the target, against LC-037. It now records them as documented gates. Pinned
  in `tools/validate/70-round13.sh`; PR #121.
- **LC-051: a project command without frontmatter blocked the whole onboard**, 2026-10-25:
  target repo D's own `.claude/commands/*.md` have no frontmatter, which Claude Code
  allows (it uses the first line as the description). Codex generation required frontmatter,
  so `/onboard` stopped with `Codex generation failed: expected Markdown frontmatter`.
  `command_text` now gives commands Claude's fallback; skills and agents stay strict. Pinned
  in `tools/validate-codex-parity.py`.
- **LC-050: onboard routed around a branch policy with a mid-run worktree**, 2026-10-24:
  target repo C's hook blocks Edit and Write on `main`. The rule said not to switch branches
  but never named worktrees, so the run called `EnterWorktree` and wrote there. Claude Code's
  worktree guard then refused the renderer call, and after `ExitWorktree` the onboard policy
  refused it from the primary checkout, so the run could not finish. Nothing outside the
  worktree was written. `context-discovery.md` and the SKILL.md red-flag table now forbid
  entering a worktree to get past a branch policy, and the run stops and offers a branch in
  this checkout or a new session started inside a worktree. Both lines are pinned in
  `70-round13.sh`.
- **LC-049: CI gates lost their `working-directory`**, 2026-10-24: target repo C's CI runs
  `pnpm test:node` and 12 more under `defaults.run.working-directory: api`. The run recorded
  them verbatim, but the line-based CI extractor dropped the directory, so the nested
  `api/package.json` disclosure listed all 13 again as `npm --prefix api run ...` (37
  undeclared, 24 real). `ci_scoped_commands` now reads step, job and workflow
  `working-directory:` in GitHub workflows, and a recorded command CI runs in `<dir>` clears
  `<dir>/<script>`. Only CI evidence clears a key, so a root `npm run test` still never clears
  `web/test`. Replayed against target repo C at `d43e992`: 37 to 24. Not fixed: directory-scoped
  non-package gates (`./scripts/check-no-bundle-secrets.sh` lives in `ui/`, the uv gates in
  their Python subprojects) are still recorded and shown as root commands.
- **LC-048: compatibility code for users who do not exist**, 2026-10-24: Launch Control has
  one user on one machine, so code that served other installs is gone. Removed: the
  `/onboard --enable-autonomy` mode (guard mode, renderer and policy manifests, the
  `autonomy-requested` marker, Codex onboarding pass-through, the ownership receipt and
  offboard's cleanup of it); Launch still builds its own overlay per run (`launch-stage.py`
  for Codex, `launch-runtime.py render-overlay` for Claude). Also removed the LC-046/LC-047
  move-once readers whose old state no longer exists on this machine (home and project
  `groundwork-*` names, `.groundwork/refresh`, git-dir `sendit/`, the old overlay refusal,
  `~/.local/share/groundwork`, `sendItHooks`) and the `--send-it` alias. The last old-name
  state was moved first with the shipped functions. Kept: `retire-send-it` (65 generated
  `send-it/` trees remain) and the `groundwork-onboard-run-*` sweep (52 markers in 13 repos).
  The acceptance repository is now `rm0nroe/launch-control-acceptance`.
- **LC-047: internal names still said `groundwork` and Send It**, 2026-10-24: internal
  identifiers (`groundwork_*`, `GROUNDWORK_*`, the digest registry and its helper, git-dir run
  state, the `groundwork-delivery:` PR marker, the Codex profile) and the whole Send It family
  (`sendit-*`/`send-it-*` files, `SENDIT_*`, `.claude/sendit/`, the `sendit/` branch prefix, the
  `sendit-` checkpoint prefix, prose) now say `launch-control` / `launch`; ticket IDs moved from
  `GW-###` to `LC-###`, including `workbench/`. Untracked state moves once on read; an old-name
  tracked overlay is refused with "rerun /onboard". `--send-it` remains an accepted spelling of
  `--launch-control`. Evidence paths under `~/.codex/visualizations/` keep their real names.
- **LC-046: user-visible paths still said `groundwork`**, 2026-10-24: target repos and home
  dirs carried `.groundwork-onboard/`, `.groundwork/refresh/`, `groundwork-backups/` (repo,
  `.codex/`, `~/.claude/`, `~/.codex/`), `.groundwork-backup-complete`,
  `~/.claude/groundwork-legacy-skills/`, `~/.claude/groundwork-user-owned.txt`,
  `.codex/groundwork-agent-ownership/`, `.codex/groundwork-sendit-ownership.json` and the
  `groundwork.zip` archive. All are `launch-control` now. Persistent ones move once: refresh state
  (refused while an operation is unfinished, then ignored), the installer's three `~/.claude`
  names (a dry run only reports, and reads the old user-owned list), and the three Codex names.
  The per-run `.launch-control-onboard/` needs no move; the next `/onboard` adds the new ignore
  rules. 7 mutants killed.
- **LC-045: the per-repo delivery skill was still generated as `send-it`**, 2026-10-24:
  `/onboard` now writes `.claude/skills/launch/` (`.codex/skills/launch/`), named `launch` with a
  `# Launch` heading; `/launch-ticket`, the Launch runtime and every manifest follow. The spec's
  route did not fit: `retire_renamed` retires only a copy matching a released fingerprint, and
  `send-it` is rendered per repository. Instead Phase 2d merges against an old `send-it/` tree
  as the existing copy of `launch`, and `portable-refresh.py retire-send-it` (run by both
  finalizers in every mode, including `--launch-control`) parks it under
  `.launch-control/refresh/retired/` once the complete `launch` tree exists, keeping a copy with
  uncommitted tracked changes or a symlink (8 mutants killed). Not done: about 40 local repos
  still carry `send-it/` until their next `/onboard`, and Launch runs refuse a target until
  then; `/offboard` on an unmigrated repo leaves the old tree.
- **LC-044: the `/onboard` completion report was hard to act on**, 2026-10-24: documented gates
  carried a "documented, not run by onboarding" suffix on every line; target repo C printed one
  undeclared-gate reason 37 times; a hand-written `code-reviewer.md` drew a false doc warning;
  refresh and Codex paths printed absolute. Undeclared gates are now grouped by source, the
  reviewer is no longer judged, warnings read `<path>: <what is missing>; <how to fix>`, and
  paths are repository-relative (5 mutants killed). The renderer also writes a self-contained
  HTML view of the finished text to `<git dir>/launch-control/onboard-report.html`, links it
  from a `Visual report:` line, and opens it on a desktop, never under `LAUNCH_RUN_ID`, `CI` or
  `LAUNCH_CONTROL_NO_OPEN`. `40-report-contract.sh` asserts the link, CSP, no remote resources,
  script-tag escaping, the opener gate both ways, and that an unwritable page drops only the
  link (7 mutants killed). A live `/onboard` rerun in target repo C is still to do.
- **LC-036 residual: Cursor `/onboard-cursor` ran the Codex copy**, 2026-10-23: in
  `cursor-agent` 2026.10.16 the skill was listed, but as the Codex forwarder, which does not run
  the Cursor setup. Cursor loads one copy of a shared name and prefers `~/.codex` over
  `~/.claude`. `onboard-cursor` now ships only with the Claude pack; `install.sh --codex`
  retires a released Codex copy through `RENAMED` (`now onboard`) and keeps a user's own.
  `validate-codex-install.py` asserts the payload, map entry and pinned row (mutation-proved).
- **LC-043 residual: a stopped Claude worker's usage read before `close()`**, 2026-10-23: the
  worker failure path charged `latest_usage` before closing, so usage the worker wrote after
  the stop was drained by `close()` and never charged. It now charges again after `close()`,
  in a `finally`; usage is cumulative, so the second charge adds only what arrived since. The
  failure record keeps the post-close usage. New Claude `pause_usage` rollover scenario writes
  4321 tokens only on SIGTERM: charged 1000 of 5321 before the fix (3 of 3), passes 3 of 3
  after. 2 mutants killed: no post-close charge, failure record not refreshed.
- **LC-043 `test-launch-rollover.py` `KeyError: 'tokens'`**, 2026-10-22: a real under-count, not
  only a flaky test, and not caused by concurrent runs (it failed with the machine idle). The
  traceback named `review-hang`: `Claude._wait_result` polls the stop before each read, so a
  stop landing after the reviewer wrote its usage but before the controller read it left the
  review uncharged. `Claude.close()` now drains what the stopped process wrote, even if the
  kill raises, and counts only this session's top-level assistant usage from before any
  `result`, skipping messages already consumed. The reviewer charges tokens after `close()`,
  in a `finally`. `review-hang` now writes its usage only on SIGTERM, which failed 3 of 3
  before the fix and passes 3 of 3 after, and `test-launch-claude.py` pins the drain's filters.
  6 mutants killed: no drain, read before close, and each of the four filters. Worker path
  logged in P3.
- **LC-002 merged CLAUDE.md judged as a whole**, 2026-10-22: the P3 entry said the `Edit`-path
  deny was never observed and not forceable. Triage falsified that. The guidance naming rule
  read the whole post-edit file, so on a merged `CLAUDE.md` whose user prose names
  `` `code-review` `` (another tool) every correct `Edit` of the generated block was denied and
  the model told to rewrite the user's text; the renderer, which counts MERGED as generated, then
  exited 1 with "generated guidance contains stale exact skill name code-review". The reverse
  also held: user prose naming `project-code-review` satisfied the rule for a block that omitted
  it. Both rules now read only the generated block (`## Generated Quick Reference` to the next
  top-level heading): the guard for any `CLAUDE.md` holding the block (one with no block yet is
  judged whole), the renderer for a MERGED one. A CREATED `CLAUDE.md` is exactly the block by
  contract, so the renderer still judges it whole (review finding). Fixtures `lc002-a/b/c`
  (`30-guard-lifecycle.sh`) and the MERGED render plus CREATED refusal
  (`40-report-contract.sh`); 6 mutants killed: guard unscoped, omit rule unscoped, block to end
  of file, no no-block fallback, renderer unscoped, CREATED scoped.
- **LC-039 controller restart on a prepared Claude run**, 2026-10-22: the residual undersold
  it. A human `recover` never worked: it set the run to `running`, and every restart paused
  again because the admission snapshot lived only in controller memory (reproduced on 3
  restarts). The raise also stopped `run()` before any later item. The snapshot is now saved in
  the queue item at admission (`launch-queue.py`) and never re-taken. Before relaunching, a
  restart now re-pins the installed Launch files and checks the git control files against the
  snapshot (review finding: resume had skipped both). `test-launch-rollover.py`: `restart` and
  `restart-reserved` resume to review-ready, `restart-tamper` and `restart-pin` pause before
  any worker launch, and `restart-unsnapshotted` pauses with "prepare a new run". 6 mutants
  killed, including re-taking the snapshot on restart. Accepted: the snapshot is as trustworthy
  as the rest of the queue state, which code run by a declared check can reach.

- **Codex parity for the Phase 0 gates (not a gap)**, 2026-10-22: Codex onboarding enforces
  neither the freshness gate nor the LC-001 safe-example gate, by design. It never writes
  `.claude/settings.json`, so no deny ever hides the examples from a Codex run, and it never
  writes `CLAUDE.md`, `AGENTS.md` or `artifacts/`, so there is no self-contradictory output to
  block. The one real gap: its Discover step did not name the safe examples as readable, and
  the shared Launch template resolves `BACKEND_LOCAL_URL` from `.env.example`. Now it does,
  pinned in `tools/validate-codex-parity.py`.

- **LC-001 follow-up: safe `.env` examples checkpoint-enforced**, 2026-10-22: the prose rule is
  now a gate in `discovery-checkpoint.sh`. Every safe example at the root, or tracked at any
  depth, needs a `read` or `denied` line in the report's `Safe env examples:` section; `read`
  needs a non-empty `Sources used` line, and `denied` holds only where `permissions.deny`
  already covers the path (`**/` form when nested). Triage found a case the item missed: on a
  rerun the deny is already in place before Phase 0, so a gate that only accepted `read` would
  block every rerun. 10 fixtures in `30-guard-lifecycle.sh`, 8 mutants killed. Untracked nested
  examples are not enumerated.

- **LC-039 worker inherits user settings**, 2026-10-22: the Claude worker now launches with
  `--setting-sources project,local` (`launch-claude.py`). A live probe in a scratch repo showed
  what the user source had been adding: 7 SessionStart hooks, 14 user plugins, and one plugin
  MCP server (`content-studio`) that `--strict-mcp-config` let through. With the flag: no hooks,
  no MCP, only the 3 built-in plugins, and OAuth login still works. The PreToolUse gate is in
  project settings, so it still loads. `tools/test-launch-claude.py` pins the flag (2 mutants
  killed).

- **LC-003 reviewer lens on a user-owned file (accepted)**, 2026-10-22: the "likely" held. The
  lens gate covers only a `code-reviewer.md` this run wrote (round 32); a preserved user-owned
  file without the `## Project-specific review lens` heading becomes a doc warning in the report
  (`render-report.sh`), which `tools/validate/40-report-contract.sh` already asserts. That is
  what happened on rymonroe.com.

- **LC-042 refresh blocked after a reboot**, 2026-10-22: `portable-refresh.py` validated every
  journal against the worktree's `[st_dev, st_ino]`, including finished ones, and macOS
  renumbers APFS `st_dev` at mount. Every command in a project with refresh history then
  stopped with "invalid operation journal" (this repository: `16777229` became `16777231`),
  so its own `.claude/` kept the pre-LC-036 checkpoint names and `validate-pack` failed in
  the live checkout. Finished journals now skip the identity check; unresolved ones still fail
  closed. `tools/validate-portable-refresh.py` covers both (1 mutant killed).

- **LC-004 run-state accumulation (accepted)**, 2026-10-22: the claim was wrong for 2 of 3
  files. Every `/onboard` prompt deletes all sessions' `.permission-mode` markers
  (`completion-guard.sh` round 18), and `render-timing.txt` has one fixed name, overwritten per
  render. What remains is one empty `.disarmed` per completed run, kept by design: deleting it
  re-arms the hooks of a session that may still be open (round 37). `launch-control-reset` clears
  them.

- **LC-041 Codex-only rerun**, 2026-10-22: `codex-onboard.md` tells a project onboarded only by
  Codex to pass `--source` from a staged tree, and the converter's missing-source error now names
  `--source`. `tools/validate-codex-parity.py` proves a bare rerun fails without writing and a
  staged rerun is a no-op that creates no `.claude/` (2 mutants killed).

- **LC-036 phase 2 (repository rename)**, 2026-10-22: GitHub `rm0nroe/launch-control` is now
  `rm0nroe/launch-control` (the old URL redirects); the local folder, Claude memory and
  `.claude_states/` moved to `launch-control`. Internal renames were dropped, see "Removed".

- **LC-031 publication safeguards (Codex leg)**, 2026-10-22, the 3 open items of the #93/#94
  re-check: credentialed GitHub calls are limited in code to the granted repository, remote
  and branches. On 4 surfaces a real `codex sandbox` denied
  sibling files, fake and real credentials, keychain, network and env (95/95). A protected branch
  was refused by the publisher and rejected by GitHub live. 13 mutants killed. Evidence:
  the LC-031 safeguards evidence in the maintainers' private design record.

Release scope `v0.2.0` (2026-10-21), accepted by LC-033:
- **LC-033** finite BACKLOG delivery mission: Codex handoff (WORK-32), target repo C tickets
  (one dependent on the other); fixes #83-#87; ledger final #88.
- **LC-024** installed onboarding and real-project acceptance; **LC-029** context-threshold
  checkpoint and continuation; **LC-030** BACKLOG discovery and preparation; **LC-031**
  authorized delivery, Done writeback and progression. Closed at release scope; residuals
  are in P2/P3, unretained scope in "Removed".
- **LC-039** Claude delivery leg to review-ready, #76-#81, 2026-10-20 (residuals in P3).
- **LC-036** phases 1 and 3, Launch Control names and skill rename, #64-#70, 2026-10-18/19.
  New PR title, body footer and Done commit observed live on GC #712.
- **LC-038** installers keep one backup, never user content, #73, 2026-10-19. Stranded
  worktree docs landed in #91; salvage branches deleted 2026-10-21.
- **LC-037** onboarding never runs a target's code, #71/#72, 2026-10-19 (residuals in P4).

- Installed `/onboard` told the agent to read 5 `launch-*-fixture-example.md` files that
  `install.sh` strips: router lines removed, and `tools/test-install.sh` now requires every
  `@references/*.md` in the installed router to exist (mutation-proved), 2026-10-21.

Earlier:
- **LC-035** Launch scope and effort boundaries, #35, 2026-09-10.
- **LC-025** bounded selected-task admission for BACKLOG.md and Paperclip, #23, 2026-09-09.
- **LC-023** guarded project checkpoint skill refresh, #20, 2026-09-08.
- **LC-021** safe refresh of existing Codex agents (`--update-agents`), #19, 2026-09-08.
- **LC-022** project-local checkpoint, load and sessions skills, #18, 2026-09-08.
- **LC-020** native Codex onboarding and agent tiers, #16, 2026-09-06 (residual in P3).
- Contract command with no registrable permission blocked the run: fixed round 41,
  `tools/validate/80-round41.sh`.
- `preflight-onboard.sh` false mismatch on every run: fixed, `45-pack-assets.sh` TC7/TC8.
- The `ask` policy gate: proven by `tools/validate/20-policy.sh:121-122`; not forceable live.
- **LC-009** stale sandbox `allowRead` remediation in `render-report.sh`: string removed by #71.
- **LC-006** (`render-report.sh` purge decision) and **LC-007** (`refs/pull/1..9` purge list):
  no longer locatable in source and never recurred; reopen with a fresh observation.
- Preserved-surface doc warning and `validation: failed (N/M)` disclosure: both observed live
  on target repo B run `543a47fe`.

## Removed

Cut by the 2026-10-13 scope decision, not delivered:
LC-026 Notion, LC-027 scheduled watching and unattended operation, LC-028 additional
repository rollout, LC-032 concurrent workers, LC-034 optional extensions, plus the
non-retained scope of LC-024/029/030/031 (other sources and platforms, ordinary-chat
rollover, Paperclip boards, watcher refresh). Requirements are in the `v0.2.0` BACKLOG and the
remaining-delivery PRD in the maintainers' private design record.

LC-008, a live `/constellate` test in a scratch repository, dropped by Ryan 2026-10-24: never run,
and nothing depends on it.

Reversed 2026-10-24 (LC-046, LC-047). Dropped by Ryan 2026-10-22: LC-036 phase 2 internal renames (`groundwork-backups/`,
`.groundwork-onboard/`, `.claude/sendit/`, `SENDIT_*`, the `sendit/` branch prefix, the
`groundwork-delivery:` PR marker, digest manifests). No user sees these names: phase 1 removed
every visible one and the validator enforces that. The rename meant about 1,400 lines in about
80 files, an old-name reader on every state path, and migrating live target repo C state, all to
change names nobody reads. The spec's "Phase 2" section in the maintainers' private design record
keeps the plan.
