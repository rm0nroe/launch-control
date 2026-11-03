**Optional cross-model second opinion (launch first, harvest later).** If the Codex plugin is
installed locally, launch a background Codex review of the same document before starting your own
pass, so it runs while you work — a reviewer from a different model family catches assumptions this
one shares with the document's author. This step is **optional**: it depends on tooling outside
this pack. Skip it silently when the runtime is absent, and skip it for trivial documents (<50
lines). Never block the review on it.

```bash
CODEX_ROOT=$(ls -d "$HOME/.claude/plugins/cache/openai-codex/codex/"*/ 2>/dev/null | sort -V | tail -1)
[ -n "$CODEX_ROOT" ] && node "${CODEX_ROOT}scripts/codex-companion.mjs" task "Adversarial review of the attached [type] document. Read-only. Report at most 5 findings, each classified [BLOCKER]/[RISK]/[GAP] with a quote and why it matters downstream. No solutions, no praise. Document follows:\n\n<full document text>" --background
```

Harvest with `codex-companion.mjs result <task-id>` before Step 4. Merge Codex findings into the
review: dedupe against your own (a finding both models raised is near-certain — note that), tag
Codex-only findings `[CODEX]`, and where Codex contradicts one of your findings, keep both takes and
flag the disagreement — cross-model disagreements go into the Priority Questions, never silently
resolved.
