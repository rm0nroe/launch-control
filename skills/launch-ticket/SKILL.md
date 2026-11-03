---
name: launch-ticket
description: "Deliver one ticket end to end with this repository's Launch Control delivery skill. Usage: /launch-ticket <ticket>"
argument-hint: "<ticket>"
disable-model-invocation: true
---

# Launch

`/launch-ticket <ticket>` runs this repository's generated delivery skill on one ticket, the same as
`/ticket <ticket>`.

1. Read `.claude/skills/launch/SKILL.md` from the repository root in full and follow it for
   the ticket in `$ARGUMENTS`.
2. If that file does not exist, this repository has no delivery skill yet: say so and suggest
   `/onboard --launch-control`. Do not deliver the ticket another way.
