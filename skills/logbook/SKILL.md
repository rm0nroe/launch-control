---
name: logbook
description: "List the project's recorded decisions, newest first, from the decision records log-decision writes under workbench/. Use when the user asks what was decided, when, or for which ticket. Usage: /logbook [TICKET | since YYYY-MM-DD | last N weeks | keyword]"
argument-hint: "[TICKET | since YYYY-MM-DD | last N weeks | keyword]"
allowed-tools: Read, Glob, Grep
---

# Logbook

Read-only. List decision records; never create, edit, move or delete one.

## Step 1: Find the records

Glob `workbench/*/decision/*-DECISION-*.md` from the project root. Each match is one record:

- **Date**: the leading `YYYY-MM-DD` of the filename.
- **Ticket**: the directory name under `workbench/` (`unknown-ticket` when the record had none).
- **Slug**: the filename text after `-DECISION-`, without `.md`.
- **Title**: the first H1 that ends in `Decision Record`, with that suffix and the dash before it
  removed. If the file has no such heading, use the slug.

Skip a match whose filename does not start with a valid date, and say how many were skipped.

## Step 2: Apply the argument

Read `$ARGUMENTS` as exactly one of these, in this order:

1. Empty: keep the 10 newest records.
2. `since YYYY-MM-DD`: keep records dated on or after that date.
3. `last N weeks`: keep records dated within the last N times 7 days, counting today.
4. A ticket key that matches a `workbench/` directory name (case-insensitive): keep that
   ticket's records.
5. Anything else is a keyword: keep records whose title, slug or ticket contains it
   (case-insensitive). If none match, Grep the record bodies for it and keep those.

A filter keeps every match, not just 10.

## Step 3: Print the log

Sort newest first by filename date, then by path. Print one row per record:

```
<date> · <ticket> · <title> · <path>
```

End with a count line: `<shown> of <total> decision records`.

If no record exists at all, print:

```
No decision records found under workbench/*/decision/. Capture one with /log-decision.
```

If records exist but none match the argument, print `No decision records match "<argument>".`
and the total count, then stop.
