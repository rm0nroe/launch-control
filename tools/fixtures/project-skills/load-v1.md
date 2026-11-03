---
name: load
description: "Instantly loads a specific session checkpoint. Usage: /load <session_name>"
---

1. Identify the `<session_name>` provided immediately after the command.
2. Resolve `<project-root>` with `git rev-parse --show-toplevel`, or the working directory outside Git. Use the current worktree root, not the primary checkout; `<project>` is its basename. Reject a session name containing path separators or `..`.
3. Read `<project-root>/.claude_states/<session_name>.md` first. If absent, read `~/.claude_states/<project>/<session_name>.md` as a legacy fallback when accessible. Local wins on a name collision. Do not follow a symlinked local state directory or file; report it instead. Never move, modify, or delete legacy checkpoints. An unreadable file is an access error, not a missing checkpoint.
4. If the file does NOT exist, output: "Checkpoint not found. Run `/sessions` to see available checkpoints for this project."
5. If the file DOES exist, silently read and absorb the entire document to prime your context. Do not summarize it back to me.
6. Reply with a short confirmation: "Session `<session_name>` loaded. Ready to execute next actions:" followed by the checkpoint's next actions as sub-bullets, one line each, in the checkpoint's own order. Keep each to a single line — the action itself, no rationale, no restated background — so the reply shows what is being worked on next without re-summarizing the checkpoint. If the checkpoint records no next actions, say so on one line instead.
