## Phase 4a — `![[source:…]]` embed parsing + binary content rendering

Lands the first demoable Phase 4 behavior: Obsidian-style `![[source:Name]]`
embed syntax renders a source's content inline in the WKWebView page reader —
`<img>` for images, `<video>`/`<audio>` for media, `<iframe>` for PDFs.

### What changed

**Parsing.** `WikiLinkSpan.isEmbedPrefix` detects a clean `!` prefix before
`[[` (guards against escaped `\![[` and double-bang `!![[` edge cases).
`WikiLinkParser.ParsedLink` gains `isEmbed: Bool`. The `parse()` dedup key
includes the embed/cite role so cite + embed to the same source coexist as
separate edges. Page embeds (`![[Page]]`) are invalid and skipped.

**Edge writing.** `replaceLinks` writes `role='embed'` for embed source links
via a second INSERT statement. The `source_links_edge` unique index means cite +
embed to the same `(from, to)` are distinct rows.

**Rendering.** `WikiLinkMarkdown.linkified()` gains an optional `embedInfo`
closure; when it encounters `![[source:…]]`, it emits inline HTML dispatched on
MIME type (`<img>`, `<video controls>`, `<audio controls>`, `<iframe>`).
Unresolved/unknown-MIME/no-resolver embeds fall back to a standard cite link.
`ReaderMarkdown.prepared()` and `WikiReaderView` thread the closure through,
precomputing an embed map on the main actor (same pattern as `isResolved`).

**Blob serving.** New `BlobSchemeHandler: WKURLSchemeHandler` resolves
`wiki-blob://source/<id>` → `WikiStoreModel.sourceContentAndMIME(id:)` → serves
blob bytes + MIME type. Registered in `WikiReaderWebView.init()` before the
first page load. Unknown IDs → 404; byteless sources → empty 200.

### Test coverage

28 new tests (1605 total, baseline 1577):
- **AC.1** — embed source link detected with `isEmbed=true`
- **AC.2** — page embed returns empty list
- **AC.3** — cite + embed to same source → 2 rows; duplicate embeds → 1 row
- **AC.4** — linkified produces correct HTML per MIME type; fallbacks verified
- **AC.5** — BlobSchemeHandler serves correct bytes/MIME; 404 for unknown; empty 200 for byteless
- Edge cases: `\![[`, `!![[`, `! [[`, embed-in-sentence, page-bang-consumed
- WikiLinkRewriter preserves `!` on rename (`![[source:Old]]` → `![[source:New]]`)
- MarkdownLinter: no false positives on `![[source:…]]`
- **AC.6** (live WKWebView paint) — manual-only, per plan
