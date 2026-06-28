# Page Body Contract

## Problem

Wiki page files as served by the File Provider extension contain three layers of
decoration that belong to the format, not the content: a YAML frontmatter block,
an H1 title, and the body prose. Historically all three could end up mixed
together inside the SQLite `body_markdown` column, which caused several problems:

**Outline flicker.** `PageDetailView` had a `readerMarkdown` computed property
that stripped the H1 from `draftBody` before passing it to the outline. Because
`draftTitle` and `draftBody` are separate `@Observable` properties set
sequentially in `loadDrafts`, there was a render window where the new title was
set but the old body was still in place. `readerMarkdown` would then fail its
match guard and return the old body—including its H1—producing a transient wrong
heading in the outline panel.

**H1 duplication in the file provider.** The file provider served
`page.bodyMarkdown` verbatim. If a page had been created with `# Title` in its
body (common for older pages), the external file contained the H1 once. After
any rename it fell out of sync silently.

**Frontmatter exposure in the editor.** Nothing prevented a user from typing a
YAML frontmatter block at the top of the editor. That content would be saved
into `body_markdown`, round-tripped into future loads, and interpreted as content
rather than metadata—confusing the renderer and the outline parser.

## Decision

**The SQLite `body_markdown` column is the canonical body only — no H1, no
frontmatter.** The file provider is the sole place where the full, decorated
markdown file is assembled. A new shared helper (`PageMarkdownFormat`) owns both
directions:

- **Stripping** (SQLite ← external): remove frontmatter and any leading H1 that
  matches the page title before storing or exposing to the editor.
- **Generation** (SQLite → file provider): prepend YAML frontmatter and an H1
  before serving to the file system.

This makes `draftBody` always clean, eliminating both the outline flicker
(nothing to strip means no mismatched intermediate state) and the H1/frontmatter
duplication.

## Frontmatter schema

```yaml
---
title: "Page Title"
date: YYYY-MM-DD        # updatedAt in local timezone
---
```

Minimal and compatible with standard static-site generators (Jekyll, Hugo) and
Obsidian. The title is double-quoted with `"` → `\"` escaping. The date is the
page's `updatedAt` formatted as `YYYY-MM-DD` in the user's local timezone,
matching what the in-app date display shows.

## Implementation

### `Sources/WikiFSCore/PageMarkdownFormat.swift` (new)

Public `enum PageMarkdownFormat` with two entry points shared by the app and the
file provider extension:

- `stripped(body: String, title: String) -> String` — strips leading YAML
  frontmatter (opening `---` through closing `---`), skips blank lines, strips
  the H1 if it matches the title exactly, skips blank lines again. Returns the
  body unchanged if none of those patterns are present.
- `fileContent(for page: WikiPage) -> String` — generates
  `frontmatter + blank line + # Title + blank line + stripped(body)`. Calls
  `stripped` internally so bodies that still contain an embedded H1 (from before
  this change) produce correct output with no double title.

### `Sources/WikiFSCore/WikiStoreModel.swift`

- `loadDrafts`: passes `page.bodyMarkdown` through
  `PageMarkdownFormat.stripped(body:title:)` before assigning to `draftBody`.
  Migration is automatic: the next save after loading persists the clean body.
- `rename(_:to:)`: reads `page.bodyMarkdown` from SQLite and strips before
  saving with the new title, so a rename also cleans up any embedded H1 from an
  old format.

### `Sources/WikiFSFileProvider/Projection.swift`

- `pageFileNode(for:page:)`: sizes the node using `PageMarkdownFormat.fileContent`
  instead of the raw body, so the reported `documentSize` and the served bytes are
  derived from the same formula.
- `contents(for:)`: returns `Data(PageMarkdownFormat.fileContent(for: page).utf8)`.

Both call the same function; size == content is guaranteed for any given DB
snapshot.

### `Sources/WikiFS/PageDetailView.swift`

- Deleted the `readerMarkdown` computed property (which existed solely to strip
  the H1 before passing to the reader and outline). All three call sites now
  reference `store.draftBody` directly.
- `saveWarningBanner`: when `store.draftBody.hasPrefix("---")`, shows an orange
  warning explaining that frontmatter is generated automatically and will be
  stripped on next load, directing the user to the title field.

## Migration

No schema migration required. The stripping in `loadDrafts` is backward-
compatible: pages whose `body_markdown` was stored without an H1 are unaffected;
pages that do contain `# Title` are silently cleaned on first load, and the
cleaned body is persisted on the next save. All pages converge to the new
contract within one load/edit cycle.

## Tests

`Tests/WikiFSTests/PageMarkdownFormatTests.swift` covers:

- `stripped` with H1 matching and not matching the title
- `stripped` with frontmatter only, frontmatter + H1, and neither
- `stripped` when the H1 is present but does not match (H1 is preserved)
- `fileContent` containing correct frontmatter and H1
- `fileContent` with a body that already has an embedded H1 (no duplication)
- `fileContent` with an empty body
- `fileContent` with a title containing `"` characters (escaping)
