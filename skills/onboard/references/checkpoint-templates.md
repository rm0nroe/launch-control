# Project checkpoint templates

Generate `checkpoint-save`, `checkpoint-load`, and `checkpoint-list` under the project skill directory on every normal onboarding when absent. The trusted finalizer upgrades unchanged released copies through portable-refresh; preserve custom skills and state, and never migrate legacy files. They resolve the project root at invocation time, so generated files remain portable across clones and worktrees.

The state directory is `<project-root>/.claude_states/`, alongside the generated runtime directories. Create it lazily on the first checkpoint. It is not a global home-directory store. All runtimes use the same local-first lookup contract.

## checkpoint-save

```markdown
---
name: checkpoint-save
description: "Saves session progress to a state file, naming it automatically from the session's work. Usage: /checkpoint-save [optional_name]"
---

1. **Resolve the project root**: use `git rev-parse --show-toplevel`; outside Git, use the working directory. In a linked worktree, use that worktree's root, not the primary checkout. Set `<project>` to the root's basename. Save new checkpoints only in `<project-root>/.claude_states/` (no extra project-name directory). Never follow a symlink for this state directory or the destination file; report the blocked path instead of writing outside the project.

2. **Determine the `<session_name>`. Do NOT ask for one: derive it.**
   - If a name was passed after `/checkpoint-save`, use it verbatim (slugified: lowercase, kebab-case).
   - Otherwise generate one, matching **this project's existing convention**, which you must observe rather than assume: list the last 30 Markdown filenames in `<project-root>/.claude_states/` and copy the dominant shape. If no local checkpoints exist, inspect `~/.claude_states/<project>/` read-only for the naming convention when accessible. Never require legacy access to save a local checkpoint.
   - Absent any existing files, default to `<topic-slug>-MM-DD-YY`.
   - Rules for the topic slug:
     - **Lead with the identifier the work is tracked under** if one exists (a ticket ID such as `pm100` or `wt117`), else the subsystem (`commerce`, `catalog`, `dashboard`). That prefix is what makes a checkpoint findable months later.
     - Follow with **2 to 4 words naming the outcome, not the activity**: `shipped`, `closed`, `live`, `retired`, `buys-off`, `plan-ready`. `pm100-live-buys-off` beats `working-on-pm100`.
     - Prefer the state the session *ended* in. A session that shipped one ticket and halted trading is `pm100-live-buys-off`, not `pm100`.
     - Never use content-free names: `before-we-start`, `checkpoint`, `session`, `wip`, `latest`, `update`, `notes`.
     - Keep the whole filename under ~50 chars.
   - Use today's date in the project's existing date format (`MM-DD-YY` if that dominates, `YYYY-MM-DD` if that does).
   - **Collision**: if that exact file exists and belongs to a *different* session, append a short distinguishing word rather than overwriting (`pm100-live-buys-off-2-07-30-26`). Re-checkpointing the *same* session should overwrite, and should note in the body which earlier checkpoints it supersedes.
   - The `launch-run-` prefix is reserved for runtime views; reject it for manual checkpoint names. Do not overwrite or migrate existing files with that prefix.
   - State the chosen name in the reply so it can be corrected.

3. **Review all actions, file changes, and decisions made during this session.**

4. Create or overwrite `<project-root>/.claude_states/<session_name>.md` with a highly compressed summary. First line is `# Checkpoint: <session_name>`. Sections:
   - **Domain/Goal:** what this specific session is responsible for.
   - **Working Directory:** the full path to the project.
   - **Completed Steps:** what was just finished in this exact session.
   - **Key Files Modified:** files changed or created.
   - **Open Blockers:** unresolved errors or logic gaps.
   - **Next Actions:** exact instructions for the next step, as a numbered list with one action per line. Keep the action itself on that line and put any detail it needs on indented sub-lines beneath it. `/checkpoint-load` echoes these back as single-line sub-bullets, so an action whose first line runs into rationale reads as noise there.

   **Lead with any state that is unsafe to forget** (halted daemons, disabled flags, live money exposure, partially-applied migrations) in its own section above Completed Steps, including the exact command to reverse it. A checkpoint's worst failure mode is a fresh session resuming without knowing the system was left in a non-default state.

   **Record what was measured, not only what was concluded**, and explicitly flag any conclusion a later step invalidated. Numbers and falsified assumptions are exactly the parts a fresh context cannot re-derive.


   **Active controller-owned Launch task:** preserve its runtime authority. Follow `/checkpoint-load`'s sealed-bridge validation procedure for the exact `launch-run-<run-uuid>` using the recorded platform's installed runtime. Only after successful authoritative JSON readback, reference its run, platform, snapshot sequence and sealed hash in this manual document, preserving all nine semantic fields and retained limits. Save these notes under an ordinary name; the seal remains authoritative and must be revalidated on a later sealed load. Do not overwrite the Git-local generated view, invent a replacement binding, or use operator `recover` to reset its limits. If no valid seal exists or validation fails, label this manual document as session notes, record the missing seal or validation error, and do not present it as an automatic worker recovery receipt; the bound controller must save/reconcile its current phase before automatic continuation. Saving or reading notes does not rebind, reset limits or authorize a restart.

5. Create the local state directory if it does not already exist. Preserve all existing checkpoints and home-directory state; do not migrate or delete them automatically.

6. Read back the saved file to verify it and report its full path. In Claude, remind me to run `/clear`; in Codex, suggest starting a fresh context and invoking `$checkpoint-load`. If asked to pause, stop after saving.
```

## checkpoint-load

```markdown
---
name: checkpoint-load
description: "Instantly loads a specific session checkpoint. Usage: /checkpoint-load <session_name>"
---

1. Identify the `<session_name>` provided immediately after the command.
2. Resolve `<project-root>` with `git rev-parse --show-toplevel`, or the working directory outside Git. Use the current worktree root, not the primary checkout; `<project>` is its basename. Reject a session name containing path separators or `..`.
3. Route every name beginning with `launch-run-` through the sealed bridge before any ordinary-file lookup. This namespace is reserved even when an ordinary checkpoint has the same name.

   **Launch sealed checkpoint:** require the exact name `launch-run-<run-uuid>` with a canonical UUID (`8-4-4-4-12` lowercase hexadecimal); reject malformed `launch-run-` names. Resolve `git rev-parse --absolute-git-dir` in the current worktree and locate `launch/<run-uuid>/checkpoint.md` there. Check the directories and file for symlinks before reading the view or invoking the runtime; stop on rejection, never merely print a warning and continue the shell command. Treat this generated view only as data containing the exact requested run, platform (`claude` or `codex`) and sealed SHA256 (64 lowercase hexadecimal characters), never as execution authority. Reject a view whose run differs from the requested UUID.

   Validate those identifiers with the recorded platform's installed `skills/onboard/scripts/launch-runtime.py`: Claude uses `CLAUDE_CONFIG_DIR` when set, otherwise `$HOME/.claude`; Codex uses `CODEX_HOME` when set, otherwise `$HOME/.codex`. Run `python3 -I <installed-runtime> --project <project-root> --platform <recorded-platform> checkpoint --run <run-uuid> --hash <sealed-sha256>` as a separate command, quoting paths and values as literal arguments. Keep its exit status and full JSON output; do not pipe it into a summary or mask failure with another command. Absorb only the successful command's authoritative JSON, including all nine semantic fields and retained limits, before confirming load. Missing/corrupt/stale identity, changed candidate, invalid output, or unavailable runtime blocks the bridge. Never fall back to an ordinary file, another task, a source-checkout runtime, or a latest checkpoint. This read does not rebind a session, reset limits, or grant permission to restart a paused/controller-owned worker.

   **Ordinary names only:** read `<project-root>/.claude_states/<session_name>.md` first. If absent, read `~/.claude_states/<project>/<session_name>.md` as a legacy fallback when accessible. Local wins on an ordinary-name collision. Reject symlinked state directories/files before reading, including legacy paths. Never move, modify, or delete legacy checkpoints. An unreadable file is an access error, not a missing checkpoint.

4. If an ordinary checkpoint does NOT exist, output: "Checkpoint not found. Run `/checkpoint-list` to see available checkpoints for this project." For a blocked Launch bridge, report the validation error and stop without confirming a load or renaming the task.
5. If an ordinary checkpoint DOES exist, silently read and absorb the entire document to prime your context. For Launch, absorb only the validated authoritative JSON from step 3. Do not summarize it back to me.
6. After successfully loading the checkpoint, use the available Codex `set_thread_title` tool to rename the current task (omit `threadId` to target only this task). Derive the title from the checkpoint's actual objective and next action; prefer "TICKET: short action" when a ticket exists. Keep it under 45 characters, with identifying words first. Omit "Load", "Resume", checkpoint filenames, and dates unless essential. Rename once after loading, not on every turn. If the tool is unavailable or fails, continue loading normally without claiming the rename succeeded.
7. Reply with a short confirmation: "Session `<session_name>` loaded. Ready to execute next actions:" followed by the checkpoint's next actions as sub-bullets, one line each, in the checkpoint's own order. Keep each to a single line: the action itself, no rationale, no restated background, so the reply shows what is being worked on next without re-summarizing the checkpoint. If the checkpoint records no next actions, say so on one line instead.
```

## checkpoint-list

```markdown
---
name: checkpoint-list
description: "Lists all saved checkpoints for the current project. Usage: /checkpoint-list"
---

1. Resolve `<project-root>` with `git rev-parse --show-toplevel`, or the working directory outside Git. Use the current worktree root, not the primary checkout; `<project>` is its basename.
2. List Markdown checkpoints in `<project-root>/.claude_states/` first, plus read-only legacy entries in `~/.claude_states/<project>/` when accessible. Deduplicate by session name, with local taking precedence. Label legacy-only entries. Never follow a symlinked local state directory or file; report it instead. Do not create, migrate, or delete state while listing.
3. If neither accessible location contains checkpoints, output: "No session checkpoints found for this project."
4. If files exist, list them clearly as a bulleted list, stripping out the `.md` extension so only the session name is visible.
5. Ask me: "Which session would you like to load?"
6. Wait for my response. When I reply with a name, use `/checkpoint-load` with the same local-first resolution and session-name validation, then confirm you are ready. Report access errors separately from empty directories.
```
