---
timestamp: 2026-06-16T135648Z
title: "2026-06-16 — Preview polish: clickable `[[wiki-links]]` — DONE ✅ (live-checked)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — Preview polish: clickable `[[wiki-links]]` — DONE ✅ (live-checked)

## Progress


Surfaced during the Phase C gate: the in-app Markdown preview rendered
`[[Photosynthesis]]` as literal dead text because `AttributedString(markdown:)`
is CommonMark and has no `[[…]]` concept. The link *graph* was already correct
(`page_links` / `links.jsonl`); this was purely a preview/navigation gap. The
on-disk / mounted body STAYS literal `[[…]]` — this is an in-app render concern
only, nothing is written back.

What landed:
- `WikiFSCore/WikiLinkMarkdown.swift` — pure, view-free transform
  `linkified(_:isResolved:)` that rewrites every `[[Title]]` / `[[Target|alias]]`
  span into a real Markdown link on a private `wiki://` scheme
  (`[[Photosynthesis]]` → `[Photosynthesis](wiki://page?title=Photosynthesis)`;
  alias displays the alias, links by the URL-encoded target). Reuses
  `WikiLinkParser`'s exact bracket grammar; rewrites EVERY occurrence (the parser
  de-dupes for the graph, the preview must not). Skips spans inside inline code
  (`` `…` ``) and fenced ``` blocks so code samples stay literal. Resolution is
  injected as a closure, so a resolved target gets host `page` (navigates) and a
  missing one host `missing` (rendered dimmed, inert).
- `WikiFS/MarkdownPreview.swift` — linkifies each block through the model's
  `pageExists`, dims unresolved (`wiki://missing`) link runs to `.secondary`, and
  installs an `OpenURLAction` that drives `store.selectPage(byTitle:)` for our
  scheme (`.handled`) while letting real external URLs fall through
  (`.systemAction`).
- `WikiFSCore/WikiStoreModel.swift` — `selectPage(byTitle:)` (resolve title→id,
  lowest-ULID on duplicates, navigate through the SAME `select(_:)` seam the
  sidebar uses so the outgoing page flushes first) + `pageExists(title:)`.
- Tests: `WikiLinkMarkdownTests` (transform: forms, encoding, code-span/fence
  protection, escaping, idempotence, URL round-trip) + `WikiLinkNavigationTests`
  (resolve-to-id, missing no-op, duplicate→lowest-ULID, flush-on-navigate). Suite
  green at 207. `make` builds + signs clean.

Still DRAFT until the live check: click a resolved `[[link]]` in the running app
and confirm it selects that page; confirm a missing link reads dimmed and inert.

## Verification

Historical verification remains in the progress record above.
