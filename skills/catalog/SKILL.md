---
name: catalog
description: "Author or update a guide star: a short, sourced, dated fact about your team's domain that is globally true. Use when the user wants to capture load-bearing context that the CRISPY research, design, planning and review skills load before domain work."
model: sonnet
effort: medium
---

# Catalog

You are tasked with creating or updating a **guide star** in `guide-stars/`. The skill is `catalog`; the artefact it produces is a *guide star*.

A guide star is a load-bearing fact about your team's domain: something that is globally true across the system, not just within one ticket or one flow. `research-questions`, `research-codebase`, `design-doc`, `design-outline`, `plan-write`, `plan-execute` and `review-doc` read every guide star before they reason about domain work, so the bar is high: lean, sourced, dated, and unambiguous.

---

## What is and is not a guide star

**Is a guide star:**
- "Orders are fulfilled via partner-a or partner-b. There is no third channel."
- "Record matching is owned by `service-b`. Other services may read record data but do not write it."
- "Result events are emitted from `service-c`, not from the partner's webhook handler."

**Is NOT a guide star:**
- "We saw a bug in `processResultEvent` last week." (Specific incident, not a global fact.)
- "The retry limit on the kafka consumer is 5." (Configuration, lives in code; will drift.)
- "The team is planning to migrate from partner-b to a new partner next year." (Forward-looking, not a current truth.)
- "In PROJ-659, we decided to use feature flag X." (Decision record: belongs in `workbench/`.)

If a candidate fact fails the **"is it globally true and stable?"** test, it does not belong here. Route it to research, a decision record, or memory instead.

---

## Initial response

When this skill is invoked, respond with:

```
I'm ready to author or update a guide star. Please tell me:

1. The claim you want to capture (one or two sentences).
2. At least one source: GitHub issue/PR, Notion page, Slack-pinned message, Jira ticket (PROJ-XXX), Confluence page, repo-local doc (`BACKLOG.md`, `docs/`), code reference, or named owner.
3. (Optional) Whether this is a new guide star or an update to an existing one.

I'll check the existing guide stars, confirm it doesn't already exist, and draft the file in the required shape.
```

Then STOP and wait for input.

---

## Steps

### Step 1: Survey existing guide stars

Run `Glob guide-stars/*.md` and `Read` every match. Build a quick mental index of what is already covered.

If the user's claim overlaps with an existing guide star:
- If it **contradicts** the existing one, surface the contradiction. Ask which is correct and whether the existing guide star should be updated or replaced.
- If it **extends** the existing one, propose updating the existing file rather than creating a new one. A guide star should be one tight unit per topic.
- If it **duplicates** the existing one, say so and stop. Do not create a duplicate.

### Step 2: Apply the "is it a guide star?" test

Before writing, confirm each:

1. **Globally true.** This holds across your team's domain, not just one flow, ticket, or team.
2. **Stable.** This is unlikely to flip in the next quarter. (Configuration values and in-flight migrations fail this test.)
3. **Sourced.** The user has named at least one source. If they have not, ask for one. Do not invent a source. Do not write a guide star with `sources: [TODO]`; that is worse than no guide star at all.
4. **Compressible to ~10–20 lines.** If the fact needs more, it is research masquerading as a guide star. Push back and suggest the `research-codebase` skill instead.

If any check fails: say what failed and what to do instead (research, decision record, memory, or just don't write it). Do not proceed.

### Step 3: Determine the file path

- **New guide star:** `guide-stars/<topic-slug>.md` where the slug is 2–4 kebab-case words describing the topic, not the claim. (`fulfillment-channels.md`, not `partner-a-handles-orders.md`.)
- **Update existing:** edit the existing file in place.

### Step 4: Write the file

Use this template exactly:

```markdown
---
topic: <topic-slug, same as filename>
confidence: <high | medium>
last_verified: <YYYY-MM-DD>
sources:
  - <source 1: GitHub issue/PR URL, Notion page URL, Slack permalink, Jira key, Confluence URL, repo-local path, code ref, or named owner>
  - <source 2, optional but recommended>
---

# <Title: human-readable form of the topic>

<One or two sentences stating the fact, declaratively. No hedging unless the hedge is the fact.>

<Optional bullets enumerating the components / partners / variants the fact covers. Keep to one screen.>

## Implications when reasoning about domain work

- <One-line implication a CRISPY agent should apply when this guide star is loaded.>
- <Another implication. 2–4 bullets max. Cut anything that isn't actionable.>
```

Rules for the body:

- **Declarative.** "Orders are fulfilled via..." not "Orders may be fulfilled via..."
- **No hedging language** ("usually", "often", "in most cases") unless the variation is the fact itself, in which case state the variation explicitly.
- **No file paths or line numbers.** Guide stars outlive specific files. If you find yourself reaching for a line number, you are writing research.
- **No forward-looking statements.** "We plan to..." does not belong. State the current truth.

`confidence: high` is the default. Use `confidence: medium` only when the source is a single named owner with no document trail, and flag in the body that confirmation is pending.

### Step 5: Update the index

Edit `guide-stars/README.md`. Add (or update) the entry in the `## Index` section, in alphabetical order by topic slug:

```markdown
- [<topic-slug>](<topic-slug>.md): <one-line summary, ≤ 150 chars, mirrors the opening sentence of the guide star>
```

If updating an existing guide star, refresh the one-liner if the claim changed.

### Step 6: Update the changelog

Add a one-line entry under `## [Unreleased]` in `CHANGELOG.md`:

- For a new guide star: `Added: guide-stars/<slug>.md, <one-line summary>.`
- For an update: `Changed: guide-stars/<slug>.md, <what changed and why>.`

### Step 7: Present to the user

```
Guide star written to: guide-stars/<slug>.md
Index updated.
Changelog entry added.

Sources captured:
- <source 1>
- <source 2>

This guide star will be loaded by `research-questions`, `research-codebase`, `design-doc`, `design-outline`, `plan-write`, `plan-execute` and `review-doc` before they reason about domain work.
```

Then STOP.

---

## Guidelines

### Push back when something isn't a guide star

The default failure mode is permissiveness: accepting anything the user wants to capture. Resist it. A bloated `guide-stars/` directory loses its value because agents stop trusting the contents. Every entry that isn't globally true, stable, and sourced makes the entire mechanism weaker.

If the user insists on capturing something that fails the test, route it: research → `research-codebase` skill, ad-hoc decision → `log-decision` skill, personal preference → memory. Do not write a sub-par guide star to be agreeable.

### Sources are non-negotiable

A guide star without a source is a rumour. If the user cannot name a source, ask them to dig one up (a ticket, a Confluence page, the engineer who owns the system) and come back. Do not write the file with a placeholder source.

### Last-verified is the freshness contract

`last_verified` is today's date when the guide star is written or revised. If you edit a guide star without re-verifying the claim, do not bump `last_verified`. The whole point of the date is that an agent reading a guide star can tell whether to trust it.

### Implications are optional but valuable

The `## Implications when reasoning about domain work` section is what turns a fact into actionable context for an agent. Skip it only when the fact is so direct it cannot be misapplied. For anything that has subtle consequences (channel branching, ownership boundaries, naming conventions), include 2–4 implication bullets.

### One topic per file

If a single guide star covers two unrelated things, split it. A reader (human or agent) should be able to predict from the filename what the file says.
