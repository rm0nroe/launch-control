---
name: launch-backlog
description: "Run a Launch Control mission from one operator project.json: stage it, go (start the staged mission with its digest, or resume a held one), hold it at the next safe point, or show its status. Usage: /launch-backlog stage|go <digest>|hold|status <project.json>"
argument-hint: "stage|go <digest>|hold|status <path/to/project.json>"
disable-model-invocation: true
---

# Mission

One command over the Launch Control mission scripts. `mission/` and `stage/` live beside the
operator's `project.json`; that config is the mission's identity.

Scripts: `S="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/onboard/scripts"`. The operator config
format and every outcome are in `$S/../references/launch-autonomy.md` (section "Finite missions").

Parse `$ARGUMENTS` as `<verb> [digest] <project.json>`. With no config path, ask for it once;
never guess one and never search the disk for one.

| Verb | Run | Then |
|---|---|---|
| `stage` | `python3 "$S/launch-go.py" --config <project.json> --stage` | Show the task list, `skipped` rows and limits, then the digest and the exact `/launch-backlog go <digest> <project.json>` line. Nothing has started. |
| `go <digest>` | `python3 "$S/launch-go.py" --config <project.json> --approve <digest>`, in the background | A wrong digest is refused and nothing starts. With a held or interrupted mission, `go` resumes it; the digest is not needed then. |
| `hold` | `python3 "$S/launch-mission.py" --root <config dir>/mission pause` | The run stops at its next safe point; `go` resumes it. |
| `status` | `python3 "$S/launch-mission.py" --root <config dir>/mission status` | Report outcome, current task and limits used. |

Rules:

- `go` needs the digest the operator saw from `stage`; never copy one from a file or a
  previous run to approve on their behalf.
- `stage` never starts or resumes anything. When a mission already exists beside the config
  it refuses: report `status` instead.
- An ended mission (`blocked`, `merged_source_pending`) is refused with its reason. Relay the
  reason and the command it names; never remove `mission/` or `stage/` to get past it.
- A mission runs for up to its `caps.minutes`. Run `go` in the background and report the final
  JSON when it exits; exit 0 means `complete`.
