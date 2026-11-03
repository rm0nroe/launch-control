---
name: log-decision
description: Capture an ad-hoc decision (Slack thread, GitHub discussion, Notion page, Atlassian, meeting notes, RFC, follow-up DMs, doc links) as a dated, structured snapshot in workbench/
model: sonnet
effort: medium
---

# Decision Record

You are creating a **decision record**: a brief, dated snapshot of a decision being made — typically extracted from a Slack thread or GitHub discussion, but flexible across sources (Notion pages, Atlassian Jira/Confluence, meeting notes, RFCs, follow-up DMs, doc links). See `@snippets-shared-by-skills/source-fetchers.md` for the full source-type → fetch-recipe table.

This is **not** a CRISPY artifact and not a design document. It is a frozen-in-time record of *what was decided, by whom, with what context, and what was deferred*. Think two pages, not ten.

**Key principles**
- **Snapshot, not analysis.** Capture decisions; do not evaluate them.
- **Decisions, not implementations.** The record captures *that* a decision was made, not *how* it will be implemented. When the source is an RFC or design doc, link it — do not restate its mechanics, code paths, field names, or phasing. If a reader needs the implementation, they click through.
- **Interactive.** Always present a draft outline for the user to confirm before writing the final file — there is often follow-up content (meeting notes, RFCs, later DMs) the user will add to the bundle.
- **Faithful to source.** A decision belongs in the record only if you can cite where it came from. If a claim has no source, ask the user.

## Initial Response

When this skill is invoked:

1. **If `$ARGUMENTS` contains source references** (Slack URLs, file paths, ticket IDs, raw URLs), proceed to **Step 1**.
2. **If no input was provided**, respond with:

```
I'll capture an ad-hoc decision as a dated record in workbench/.

Share any combination of:
- A Slack thread URL (most common — e.g. https://workspace.slack.com/archives/C.../p17761...)
- Slack message URLs (individual messages outside the thread)
- GitHub issue / PR / discussion URLs (the comment thread that contained the decision)
- A Notion page URL (fetched through an available Notion MCP, otherwise pasted)
- File paths to meeting notes, transcripts, or pasted prose
- Atlassian Jira ticket key or Confluence URL that frames the decision
- Or just describe the decision in plain text

A ticket helps file this correctly — supported formats: `PROJ-NNN` / `GH-NNN` / Jira keys. If there's no ticket, say so and I'll use the `unknown-ticket` folder.
```

Then **STOP and wait** for the user's input.

## Step 1: Catalogue the sources

Parse `$ARGUMENTS` (and any follow-up the user gave) into a sources list. Classify each using the URL/reference patterns in `@snippets-shared-by-skills/source-fetchers.md`:

- **Slack thread URL** — pattern `https://*.slack.com/archives/{CHANNEL_ID}/p{ts}` where `ts` is digits; the canonical timestamp is `{ts[:-6]}.{ts[-6:]}`. The thread root is the message at that ts.
- **Slack message URL** — same pattern; treat as a single message unless it's the thread root.
- **GitHub issue / PR / discussion URL** — pattern `https://github.com/{owner}/{repo}/issues/N` (or `/pull/N`, `/discussions/N`). The discussion / PR review thread frequently carries decisions; treat the comment list as the equivalent of a Slack thread.
- **Notion page URL** — pattern `https://www.notion.so/...` or `https://*.notion.site/...`. Fetch through available `mcp__notion__*` page-read or search tools; if none are available, ask the user to paste the page body.
- **File path** — verify it exists and is readable.
- **Atlassian Jira ticket key / URL** (e.g. `PROJ-442`, `https://your-org.atlassian.net/browse/PROJ-442`) — only fetch via Atlassian MCP if the user said it carries decision content; otherwise list it as a reference and skip the body.
- **Atlassian Confluence URL** — same treatment.
- **Raw text** — capture verbatim under "user-provided context".

Print the catalogue to the user as a numbered list and note which sources you intend to fetch.

## Step 2: Slack MCP availability (verified inline during fetching)

The Slack MCP exposes no idempotent capability check (unlike Atlassian's `getAccessibleAtlassianResources`), so don't bother with an upfront probe — verification happens on the first real fetch in Step 3. If any Slack sources are in the catalogue, you must be ready to surface a clean failure if the MCP is missing or unauthenticated.

If the first Slack tool call fails due to the tool being unavailable, an authentication error, or a 401/403-equivalent response, respond exactly with:

```
The Slack MCP is not available or not authenticated. To use Slack sources in a decision record, you need to install and authenticate the Slack MCP server.

If you can't connect the MCP right now, paste the thread contents directly and I'll work from that.
```

Then **STOP. Do not continue.** Do not invent thread content. Do not retry silently.

## Step 3: Fetch each source

For each source in the catalogue, in parallel where possible. See `@snippets-shared-by-skills/source-fetchers.md` for the canonical fetch recipes — this section calls out the rules specific to decision-record (verbatim retention, one-hop only):

- **Slack thread**: call `mcp__slack__slack_read_thread` with the channel ID and canonical ts. Capture every reply (don't truncate); preserve order, author IDs, timestamps, and **the raw message text verbatim** — Step 8 needs the original prose to build the Source Material appendix.
- **Slack single message**: call `mcp__slack__slack_read_channel` (or thread reader if it's a thread root) for that ts. Same verbatim-retention rule applies.
- **GitHub issue / PR / discussion**: if `mcp__github__*` is available, call `mcp__github__get_issue` / `get_pull_request` / `get_discussion` and fetch the comment list. Else fall back to `gh issue view N --json title,body,comments` / `gh pr view N --json title,body,comments,reviews`. Treat the comment thread the same as a Slack thread — preserve order, authors, timestamps, and **raw comment bodies verbatim** for the Source Material appendix.
- **Notion page**: if `mcp__notion__*` is available, use its page-read or search tools and preserve the fetched content faithfully. Otherwise ask the user to paste the page body verbatim, including any sub-pages they want included. Cite the URL in References and identify pasted content as user-provided.
- **File**: read with the `Read` tool, no `limit`/`offset` — get the whole file.
- **Atlassian Jira / Confluence**: only fetch via Atlassian MCP (`mcp__atlassian__getJiraIssue` / `getConfluencePage`) if the user said the doc carries decision content; otherwise list it as a reference and skip the body. If the ticket key is project-specific (`PROJ-NNN` etc.) and not actually in Atlassian, treat it as a repo-local ticket instead — `Grep "{KEY}" BACKLOG.md`.

**Slack-fetch failure handling**:
- **MCP missing or unauthenticated** (tool not registered, 401/403, "not authenticated" errors) → emit the Step 2 message and STOP.
- **Channel/thread access denied while authenticated** (e.g. bot not in a private channel, thread deleted) → tell the user specifically what failed and ask whether to skip that source or paste the contents; do NOT halt the whole skill.
- **Empty response** → ask the user; common cause is the bot lacking access to the channel.

## Step 4: Resolve participant names

Collect the unique Slack user IDs across all fetched messages. For each, call `mcp__slack__slack_read_user_profile` to get a display name and (if available) job title. Build a participant table mapping `user_id → "Display Name | Role"`.

If a profile lacks a role/title, leave the role blank in the draft and ask the user during Step 6 confirmation. Don't fabricate a role.

## Step 5: Determine the ticket

In priority order:

1. A ticket explicitly given in `$ARGUMENTS` (e.g. `PROJ-300`, `PROJ-442`, `PROJ-1234`, `#247` for GitHub issue 247).
2. A ticket mentioned in the gathered sources. Try the common prefixes the project uses first — `PROJ-\d+`, `GH-\d+`, `ENG-\d+` — plus bare GitHub `#\d+` refs in GitHub-sourced material. If multiple appear, the **primary** ticket is the one the decision most directly belongs to; the others get cited inline in the relevant Decision section as bare ticket references. Ask the user if it's ambiguous.
3. Ask: `Which ticket / issue does this decision belong to? (PROJ-### / GH-### / Jira key / GitHub issue #N / Notion page / 'none' for unknown-ticket.)` and **STOP and wait**.

Store the chosen primary as `TICKET`. Other tickets touched by the decision are referenced inline in the body — they don't need a frontmatter field.

## Step 6: Present the draft outline (interactive — DO NOT skip)

Synthesise the gathered sources into a **draft outline** and show it to the user **before writing the file**. This is the most important step — it's where the user catches misframed decisions and adds follow-up context.

```
Here's the draft outline. Review and tell me what to change.

**Title**: [Proposed title — short, decision-shaped, e.g. "CRM Events for User Records"]
**Ticket**: [TICKET, or "unknown-ticket"]
**Date**: [date the decision was made — typically the date of the last decision-bearing message in the thread, NOT today's date]

**Background** (1 paragraph)
[2–4 sentences: what prompted the discussion, who needed what, what the constraints were.]

**Participants**
- Name — Role (resolved from Slack profile)
- ...
[Flag any unknown roles for the user to fill in.]

**Key References**
- [Title](url) — short note on what it is
- ...

**Decisions** (numbered, one heading each)
1. [Decision in declarative headline form — ≤10 words, one claim per heading. Good: "source enrichment is NOT required for MCP MVP". Bad: "team will NOT use partner-a for eligibility; Alex's partner-a PRs will not be merged" (two claims, sentence-shaped).]
   [Default ONE sentence: who confirmed and why. Add a second only if the implication isn't obvious. Do NOT restate implementation detail from the source RFC/doc — link it. Bullets/tables only when the decision *is* a structured artifact (a per-event matrix, a config-flag pair).]
2. ...

**Open Questions / Deferred**
- **[Item]** — [pick ONE of: ticket pointer, owner, or one-line reason. Not all three. No section/anchor citations.]
- ...

**Source Material** (only if Slack sources exist)
- Will appendix N decision-bearing excerpts from {thread/channel} (out of M total messages in thread).
- Excerpts to include: [one-line list naming the message authors + topic, e.g. "Author A raising the question; Author A paraphrasing Author B's framing; Author C endorsing decoupling; Author A's net-out; Author D's RFC reversal"]
- [Flag any borderline messages so the user can promote/demote.]

Want me to:
- Adjust the framing of any decision?
- Add more sources (meeting notes, RFCs, follow-up DMs)?
- Re-attribute a quote or split/merge decisions?
- Change the title or date?

Reply with edits, or "looks good, write it" to proceed.
```

Then **STOP and wait.** Iterate until the user is satisfied. Each iteration may add new sources — re-run Step 3 for any newly added source before regenerating the outline.

## Step 7: Determine the output path

- If `TICKET` is set: `workbench/{TICKET}/decision/{YYYY-MM-DD}-{TICKET}-DECISION-{slug}.md`
- If no ticket: `workbench/unknown-ticket/decision/{YYYY-MM-DD}-DECISION-{slug}.md`

Where:
- `YYYY-MM-DD` is the **decision date** confirmed in Step 6 (not today, unless they match).
- `slug` is a short kebab-case description of the decision topic (≤6 words, drop filler).

Create the parent directory if it doesn't exist.

## Step 8: Write the document

Render the confirmed outline using this template. The document body should mirror the example structure exactly — short, scannable, no flourish.

When the document references other `workbench/` files (rare for decision records, but possible), render them as GitHub permalinks per `.claude/skills/snippets-shared-by-skills/permalinks.md`. Jira, Confluence, Notion, GitHub, and other external URLs stay as bare links.

The body uses **header lines, not YAML frontmatter**, matching the design/outline/plan house style.

```markdown
# [Title] — Decision Record

**Date**: YYYY-MM-DD
**Ticket**: <PROJ-NNN | ENG-NNN | GH-#N | unknown-ticket>
**Author(s)**: [Display name — typically the user invoking this skill]

---

## Background

[1 paragraph — 2–4 sentences. What prompted the discussion, what was the constraint, what was at stake.]

---

## Participants

| Name | Role |
|---|---|
| [Name] | [Role] |
| [Name] | [Role] |

---

## Key References

- [Title](url) — short note
- [Title](url) — short note

---

## Decisions

### 1. [Decision headline — ≤10 words, declarative, one claim]

[One sentence by default. Who confirmed it and why. Cite ticket(s) inline.]

### 2. [Decision headline]

[One sentence. Add a second only if the implication isn't obvious. Do NOT restate implementation detail from the source RFC — link it. Use bullets/tables only when the decision *is* a structured artifact (per-event matrix, config-flag pair).]

---

## Open Questions / Deferred

- **[Item]** — [pick ONE of: ticket pointer (e.g. "tracked in PROJ-XXX"), owner (e.g. "owner: platform team"), or one-line reason. Not all three. No source-doc section anchors.]
- **[Item]** — [reason]

---

## Source Material

> Slack messages auto-delete after 30 days. Decision-bearing excerpts preserved verbatim from the originating thread.

### #{channel-name} — [Slack thread]({thread-url})

> **{Display Name}** ({Role}) — YYYY-MM-DD HH:MM {TZ}
> {verbatim message text — line breaks within a message preserved as separate `> ` lines}
>
> **{Display Name}** — YYYY-MM-DD HH:MM {TZ}
> {verbatim message text}

### #{channel-name} — [Slack message]({message-url})

> **{Display Name}** ({Role}) — YYYY-MM-DD HH:MM {TZ}
> {verbatim message text}
```

**Source Material rules** (only render this section if Slack sources exist — Slack auto-deletes after 30 days, so the appendix preserves the verbatim text. GitHub / Notion / Atlassian / file sources are durable and stay as `Key References` links, NOT in this appendix.):

- **One `###` subheading per Slack thread**, even if multiple decisions in the record draw from it. Do not split one thread across multiple subheadings.
- **Single-message Slack URLs** (not threads) get their own `###` subheading using "Slack message" instead of "Slack thread" in the link text.
- **File / GitHub / Notion / Confluence / Jira sources do NOT go here.** Those are durable; the appendix only exists to defeat Slack's 30-day deletion. (If a GitHub discussion has a history of being force-deleted in your project, you can mirror the Slack pattern — but otherwise keep GitHub comments as `Key References` links.)
- **Strip Slack mention syntax**: `<@U01EXAMPLE99|Jordan Lee>` renders as `Jordan Lee` (no leading `@`); `<#C01EXAMPLE99|team-channel>` renders as `#team-channel`.
- **Strip Slack URL syntax**: `<https://example.com|RFC here>` renders as `[RFC here](https://example.com)`; `<https://example.com>` renders as `https://example.com`.
- **Author + role + timestamp** comes from the Step 4 participant table; preserve the original Slack timezone (PDT/PST/UTC) — don't normalize. Role in parens is omitted if unknown.
- **One blank `>` line between messages** within the same thread to give visual separation in Confluence.
- **Bold the load-bearing phrase** (e.g. `**We decided #2 is the path we'll take.**`) when one specific sentence in a message *is* the decision moment. At most once per message; don't bold for emphasis generally.

Header-line rules:
- `**Date**: YYYY-MM-DD` — the decision date, not today's date if they differ.
- `**Ticket**: <KEY>` — the primary ticket (PROJ-NNN / ENG-NNN / GH-#N / unknown-ticket). Other touched tickets stay inline in the body.
- `**Author(s)**: ...` — the human capturing the decision (typically the invoking user). Multiple names allowed if the decision was co-recorded.
- Use `**Key**: Value` (colon outside the bold), the house metadata pattern. Do NOT use `**Key:** Value`.
- No `**Status**:` row — see Guidelines.

## Step 9: Present and iterate

Mirror the design/outline/plan post-write iteration pattern. Tell the user:

```
Decision record written: workbench/{TICKET}/decision/{filename}.md

Please review it. I want to make sure it:
- Frames each decision the way it was actually made (no over-/under-claiming)
- Attributes correctly and cites the right tickets
- Captures everything that was deferred, not just everything that was decided

What needs adjustment?
```

Iterate on the file in place until the user is satisfied. After they confirm:

```
All set. Next steps:
1. Commit the file on the working branch (or main if your project commits decision records directly).
2. If your project links docs back to source systems automatically (e.g. a JIRA sync workflow, a GitHub Action that comments on the issue) — push and let it run. Else, manually link the record from the relevant ticket / issue / page.
```

## Guidelines

### Be faithful, not generative
- Every decision must be traceable to a Slack message, a doc, or an explicit user statement. If the source is ambiguous, ask before writing.
- Do not synthesize decisions that "follow logically" from the discussion. If it wasn't decided, it goes in **Open Questions**.
- Do not paraphrase to the point of distortion. When a participant said "let's defer this", the record should say "deferred", not "rejected".

### Be terse
- The example doc is the reference for length and tone. A typical decision record is 80–150 lines including frontmatter.
- Background is one paragraph and source-agnostic — name the constraint, not the cast. Named attribution belongs in the decision body where confirmation matters, not in Background.
- Decision headings are headlines, not sentences: ≤10 words, declarative, **one claim per heading**. If a heading needs "and" or a semicolon to fit, split it into two decisions.
- Decision bodies default to ONE sentence (who confirmed, why). Add a second only if the implication isn't obvious. Implementation mechanics (code paths, field names, phasing, fail-open semantics) belong in the source RFC — link it, don't restate it.
- Open Questions entries pick **one** of: ticket pointer, owner, or one-line reason. Not all three. No source-doc section anchors like "(RFC §9 #1)".
- No "Status" field — they're never accurate after the moment.

### Interactive review is non-negotiable
- Never skip Step 6, even if the user says "just write it" in their first message. The user will frequently add follow-up sources (meeting notes, RFCs) once they see the draft.
- If the user provides additional sources mid-iteration, re-fetch (Step 3) and regenerate the outline rather than patching.

### Multi-ticket handling
- A single decision record has **one primary ticket** (where it lives in the file tree).
- Other tickets it touches are referenced inline in the relevant Decision section as bare ticket links — no separate frontmatter list. Any sync/link-back automation (Jira sync, GitHub Action) should attach a remote link only on the primary ticket; that's intentional, since secondary tickets typically already track their own work.

### Source Material curation
- **Decision-bearing only.** The appendix exists to make the documented decisions defensible after Slack auto-deletes the thread — not to preserve the full transcript. A 40-message thread typically reduces to 4–8 excerpts.
- **Include the load-bearing messages**: where the question was raised, where the framing was articulated, where each decision was confirmed (or reversed), and any cross-team agreement that hinges the decision (e.g. the consuming team's lead saying "yes, that works"). Bold the specific sentence that *is* the decision.
- **Drop the side-chatter**: scheduling pings, emoji reactions, sub-discussions that didn't influence the documented decisions, doc-link dumps that already appear in Key References. If a thread reply doesn't substantiate any documented decision, it doesn't go in the appendix.
- **If a decision was made in a meeting and only summarized in Slack**, quote the summary message; you can't reconstruct what wasn't typed.
- **When in doubt, ask the user during Step 6** which messages are load-bearing — the outline preview is where this gets resolved before the file is written.
