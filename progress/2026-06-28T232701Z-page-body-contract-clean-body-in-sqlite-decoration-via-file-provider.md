---
timestamp: 2026-06-28T232701Z
title: "2026-06-28 — Page body contract: clean body in SQLite, decoration via file provider"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — Page body contract: clean body in SQLite, decoration via file provider

## Progress


`body_markdown` in SQLite now stores only the prose body — no H1, no YAML
frontmatter. The File Provider extension generates both on the fly when serving
`.md` files to Finder and external tools. This fixes the outline-panel flicker
and makes renames safe.

**Root cause of the flicker.** `PageDetailView` had a `readerMarkdown` computed
property that stripped the leading H1 from `draftBody` before passing it to
`PageOutlineView`. Because `draftTitle` and `draftBody` are set sequentially in
`loadDrafts`, there was a render window where the new title was live but the old
body was still in place. The guard inside `readerMarkdown` failed to match,
returning the full old body (H1 included), which briefly appeared in the outline.

**New contract.** A shared `PageMarkdownFormat` enum in `WikiFSCore` owns both
directions:
- `stripped(body:title:)` — removes leading YAML frontmatter block, matching H1,
  and the blank lines that separate them from the body. Used in `loadDrafts` and
  `rename(_:to:)` so the editor and SQLite always hold clean body.
- `fileContent(for:)` — generates `---\ntitle/date frontmatter---\n\n# Title\n\n
  body` for the file provider. Calls `stripped` internally, so pages whose
  `body_markdown` still has an embedded H1 (pre-migration) produce correct
  single-title output without a DB migration.

**`Projection` changes.** Both `pageFileNode` (reported `documentSize`) and
`contents(for:)` call `PageMarkdownFormat.fileContent(for:)`, so the file size
the daemon caches and the bytes it serves are always derived from the same
formula. Frontmatter schema: `title` (double-quoted, `"` escaped) and `date`
(local `YYYY-MM-DD` from `updatedAt`).

**Editor warning.** `saveWarningBanner` in `PageDetailView` now shows an orange
warning when `draftBody` starts with `---`, pointing the user to the title field
above.

**`readerMarkdown` deleted.** The three call sites in `PageDetailView` now
reference `store.draftBody` directly; no stripping is needed because the body is
always clean.

**Migration.** Automatic and zero-downtime: stripping in `loadDrafts` is
backwards-compatible; pages converge to the new format on first load + save.

**Tests.** 12 new `PageMarkdownFormatTests` covering `stripped` (H1 match/miss,
frontmatter only, frontmatter + H1, mismatch, empty) and `fileContent` (format,
no-double-H1, empty body, title escaping). 1170 tests total, all passing.

## Verification

Historical verification remains in the progress record above.
