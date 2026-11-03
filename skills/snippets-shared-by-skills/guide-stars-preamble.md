# Guide stars preamble

Guide stars are short, sourced, dated facts about the team's domain that hold across the
whole system (fulfillment channels, system ownership, integration partners). The `catalog`
skill writes them to `guide-stars/` at the project root.

## Load guide stars first

1. Glob `guide-stars/*.md` from the project root. If nothing matches, skip the rest of this
   preamble and carry on; a project without guide stars is normal.
2. Read every match in full, except `guide-stars/README.md`, which is only an index. The
   files are kept lean, so loading the whole directory is cheap.

## Apply them

- Treat a guide star about ownership or structure as ground truth unless the current code
  directly contradicts it.
- When a guide star and the code disagree, report the contradiction as a finding. Do not
  silently override either one.
- Ignore guide stars that do not bear on the task, and do not restate them in your output.
