# Linking to workbench/ documents

When a CRISPY artifact references another file in `workbench/` (research, design, outline, plan, review), render it as a GitHub permalink, not a bare path.

## How to build the link

1. Get the repo URL: `git remote get-url origin`
2. Normalize:
   - `git@github.com:OWNER/REPO.git` → `https://github.com/OWNER/REPO`
   - `https://github.com/OWNER/REPO.git` → `https://github.com/OWNER/REPO`
3. Compose: `<base>/blob/main/<path-from-repo-root>`
4. Render in markdown as: `[<path-from-repo-root>](<full URL>)` — keep the path as the link text so a broken link after a rename is still greppable.

## When to use

- All cross-document references inside artifact bodies (References sections, Historical Context, Related Research, Upstream Context, "see also" callouts).

## When NOT to use

- The final "I've written X to: ..." status line shown to the user in the terminal — use a **repo-rooted relative path** (e.g. `workbench/PROJ-44/plan/2026-04-05-PROJ-44-PLAN-foo.md`). The doc was just written and is almost certainly not pushed yet, so a permalink would 404; a relative path is also clickable in most terminals and opens the file in the user's editor.
- Code references (`path/to/file.py:123`) — those stay bare; they point at the live codebase, not at `workbench/`.
- Frontmatter fields that store paths (e.g. review `target:`) — keep as bare paths so tooling can parse them.

## Caveat

Links resolve only after the artifact is committed and pushed to `main`. Until then they 404. That's expected; do not insert a commit step inside the skill.

## Reading these links from another skill

When a skill needs to *follow* a reference inside an existing artifact (e.g., the review skill loading the upstream design doc, plan-write loading the design+research, etc.), the link in the doc may still be unpushed. So:

- **Always read locally via the path**, never via the URL. The link text is `workbench/.../foo.md` precisely so the path can be extracted and passed to `Read` / `Glob` directly.
- If you encounter a bare URL with no path link text, derive the path by stripping the `<base>/blob/<branch>/` prefix.
- Do **not** use `WebFetch` to retrieve a `workbench/` file — it will silently 404 for unpushed work and gives stale content if the local working tree has uncommitted edits.

The URL form exists for humans clicking through in a browser or rendered Confluence page; skills should treat it as decorative.
