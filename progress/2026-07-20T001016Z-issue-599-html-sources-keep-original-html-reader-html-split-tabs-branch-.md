---
timestamp: 2026-07-20T001016Z
title: "2026-07-19 — Issue #599: HTML sources — keep original HTML + Reader/HTML/Split tabs (branch `html-source-tabs`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #599: HTML sources — keep original HTML + Reader/HTML/Split tabs (branch `html-source-tabs`)

## Progress


**Problem.** When an HTML page was ingested, `FormatMaterializer.dispatch`
(`Sources/WikiFSCore/Sources/FormatMaterializer.swift:81-86`) converted it to
markdown via `HTMLToMarkdown` and stored ONLY the markdown
(`format: .htmlConverted`). The original HTML bytes were discarded. The user
could only see the markdown conversion in `SourceDetailView` — no way to view
the original rendered HTML or compare it side-by-side with the markdown. PDF
sources already did the right thing (PDF bytes preserved + extracted markdown
stored as a processed version); HTML did not.

**Fix.** Treat HTML sources like PDF sources: store the original HTML bytes as
the source blob, store the extracted markdown as a `.extraction`-origin
processed-markdown version, and surface Reader (markdown) / HTML (rendered
WKWebView) / Split (both) tabs in `SourceDetailView`. No migration — existing
HTML sources stored as markdown keep working as before (no HTML tab for them;
only new HTML ingestions get the two-layer model).

### Phase 1: Storage — preserve original HTML bytes + extracted markdown sidecar

- `Sources/WikiFSCore/Sources/FormatMaterializer.swift` — `SourceFormat`
  replaces `.htmlConverted` with `.html` (semantically: HTML bytes preserved,
  not markdown-as-source). The HTML arm of `dispatch` returns the ORIGINAL
  HTML bytes as `data`, the filename ends in `.html`, and the converted
  markdown rides as a new `FormatPlan.extractedMarkdown: String?` sidecar
  (`nil` for non-HTML formats). `FormatPlan.init` defaults the sidecar to
  `nil` so existing call sites stay clean.
- `Sources/WikiFSCore/Integrations/URLFetchService.swift` — `FetchOutcome.Kind`
  renames `.htmlConverted` → `.html`; `mapFormat(_:)` updated. The outcome kind
  is internal-only (not surfaced in user-facing UI text), so the rename is
  free of UI impact; the kind still exists for asserting route fidelity in
  tests.
- `Sources/WikiFSCore/Sources/SourceMaterializer.swift` — `MaterializedSource`
  gains `extractedMarkdown: String?`. `LocalFileMaterializer.materialize()`,
  `WebsiteMaterializer.materializeWithPlan()`, and
  `ZoteroMaterializer.materialize()` thread `plan.extractedMarkdown` through.
  `WebsiteMaterializer.materializeSnapshot()` checks `plan.format == .html`
  (was `.htmlConverted`) to route into the snapshot path.
- `Sources/WikiFSCore/Integrations/WebsiteSnapshotExtractor.swift` — the
  snapshot's `page` source now preserves the ORIGINAL HTML bytes (was the
  markdown with rewritten image srcs); the snapshot markdown (with image srcs
  rewritten to stored sibling blobs) rides as the `extractedMarkdown` sidecar
  on the returned `FormatPlan` and on the `MaterializedSource`. So an HTML
  snapshot ingestion now stores: original HTML page (source blob) + image
  siblings (as before) + markdown sidecar (as a processed version).
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — new helper
  `appendExtractedMarkdown(to:from:)` writes the sidecar (when non-nil and
  non-empty) as a `SourceMarkdownOrigin.extraction` processed-markdown
  version via `store.appendProcessedMarkdown`, mirroring `seedPdfMarkdown`.
  Both store-write seams call it: `storeMaterialized` (the simple add-source
  path) and `storeSnapshot` (the shared-activity snapshot path). The
  `addURLViaWebsite` switch checks `snapshot.plan.format == .html` and strips
  `.html` for the display name (was stripping `.md`).

### Phase 2: UI — Reader / HTML / Split tabs in `SourceDetailView`

- `Sources/WikiFS/Sources/SourceDetailView.swift`:
  - `FileContentTab` enum gets a `.html` case (`"HTML"` raw value), mirroring
    `.pdf` / `.rendered` / `.media`. The tab picker shows it as a sibling of
    the PDF tab for HTML sources.
  - New `isHTMLSource` computed property — true for `text/html` /
    `application/xhtml+xml` MIME types or `.html`/`.htm`/`.xhtml` extensions.
    A legacy pre-#599 HTML source (whose storage format was `.htmlConverted`
    → stored as markdown) does NOT match here (its MIME is `text/markdown`
    and its extension is `.md`), so it stays in the markdown-only path with
    no HTML tab, satisfying the "no migration needed" rule in the issue.
  - New `htmlSourceString` helper reads `store.sourceBytes(id:)` and decodes
    UTF-8 (with a lossy fallback so non-UTF-8 still shows something).
  - `availableTabs` gains an HTML branch checked after the PDF branch (so a
    PDF whose extracted text happens to be HTML stays a PDF) and before the
    Mermaid branch (so a `.mmd` source stays on the Mermaid three-way). For
    a HTML source with extracted markdown: `[.reader, .html, .split]`; for
    a HTML source before headVersion loads (sync store read happens in
    `.onAppear`): `[.html]` — added gracefully so the user always sees at
    least the HTML tab, then the picker re-renders with all three once the
    markdown version lands.
  - `currentMarkdownContent` no longer falls through to `sourceBytes` for
    HTML sources — the raw bytes are HTML, not markdown, and rendering them
    as markdown would show raw `<html>` tags. The Reader tab shows its
    "No Processed Markdown" placeholder until `headVersion` loads.
  - `splitContent` adds an HTML branch (markdown left, WKWebView right),
    slotted between the byteless embed and Mermaid branches.
  - `tabbedContent` switch gains `case .html: htmlSourceView` and the Edit
    button's "switch to reader when entering edit mode" guard now also
    covers `.html` (mirrors `.pdf` / `.media` / `.rendered`).
  - New `htmlSourceView` view route: renders `HTMLSourceWebView` for the
    bytes, or a calm `ContentUnavailableView` placeholder when the bytes
    can't be decoded.

### Phase 3: HTML rendering — `HTMLSourceWebView`

- `Sources/WikiFS/Sources/HTMLSourceWebView.swift` (NEW, ~95 lines) — the
  WKWebView `NSViewRepresentable` for the HTML tab. Modeled after
  `MediaEmbedPlayerView`'s `EmbedWebViewRep` (a minimal `WKWebView` bridge):
  - **Security posture:** `WKWebpagePreferences.allowsContentJavaScript =
    false` disables JavaScript ENTIRELY on the rendered HTML (covers the
    parent doc AND any `<iframe>` content). `<script>` blocks, inline event
    handlers, and `javascript:` URLs all no-op. External CSS / images /
    iframes still load through the network so rendering stays faithful —
    a script-less page reads the same in the HTML tab as it would in any
    browser with JS disabled.
  - `baseURL: nil`: relative URLs in the original HTML won't resolve (the
    wiki doesn't store the page's origin URL alongside the bytes); absolute
    `https://…` URLs still load via the network. Snapshot sources keep
    their resolved-image path through the Reader tab (the markdown sidecar
    has image srcs rewritten to point at stored sibling blobs); the HTML
    tab shows the ORIGINAL HTML verbatim.
  - Same `reader.zoom` keyboard shortcuts as the markdown reader
    (`⌘+` / `⌘−` / `⌘0` / `⌘-scroll`) via `WKWebView.pageZoom` and the
    shared `ZoomShortcuts` / `ZoomScroll` modifiers — mirrors the
    `WikiReaderView` pattern.
  - `Coordinator.loadedHTML` guards against reloading the same document on
    every SwiftUI re-evaluation (mirrors `MediaEmbedPlayerView`'s
    `loadedURL` discipline).

### Tests

Updated 6 existing test files for the new behavior:

- `FormatMaterializerTests` — HTML dispatch now returns `.html` format with
  the original HTML bytes as `data` and the markdown as `extractedMarkdown`.
  Added `htmlSidecarMarkdownIsEmptyWhenBodyIsBlank` for the empty-body case.
- `URLFetchServiceTests` — `htmlStoredVerbatimWithExtractedMarkdownSidecar`,
  `genuineHTMLStoredVerbatimAsHTML` etc. assert `outcome.kind == .html` and
  byte-identical HTML bytes in the collector.
- `WikiStoreModelAddURLTests` — `htmlURLLandsVerbatimWithMarkdownSidecar`
  (was `…LandsAsMarkdownFileInList`): asserts the source bytes ARE the
  original HTML, the filename ends in `.html`, and the extracted markdown
  lands as a `.extraction`-origin processed-markdown version with the
  `"html-to-markdown"` technique tag.
- `WikiStoreModelDropRoutingTests` — `weblocRoutesThroughURLIngestAsMarkdown`,
  `remoteHTTPURLRoutesThroughURLIngest`, `mixedBatchRoutesEachURLCorrectly`
  assert the new HTML byte preservation + sidecar behavior on dropped
  `.webloc` files and direct HTTP URLs.
- `WebsiteSnapshotExtractorTests` — snapshot path now preserves original
  HTML as `page.data` and carries the rewritten markdown as
  `plan.extractedMarkdown`. `dummyPlan` updated to `.html` format.
- `SourceMaterializerTests` — `zoteroHtmlAttachmentPreservedWithMarkdownSidecar`
  (was `…ConvertsToMarkdown`): the Zotero HTML attachment preserves HTML
  bytes with the markdown as a sidecar.
- `PodcastIngestRoutingTests` + `BytelessEmbedIntegrationTests` — assert
  `outcome.kind == .html` for the routed-HTML case (was `.htmlConverted`).

### Verification

- `make version prompts` ✓
- `swift build` ✓ (clean, 0 errors / 0 warnings).
- `swift test` (full suite) — **3065 tests / 260 suites pass** (~33 s).
  No regressions.

### Backward-compat (no migration needed)

Existing HTML sources ingested pre-#599 stored the markdown as the source
blob (filename `Foo.md`). They keep working as before — the `isHTMLSource`
guard checks for HTML MIME/extension, which they don't have, so they stay on
the markdown-only path with no HTML tab. New HTML ingestions get the two-layer
model: HTML bytes preserved + markdown sidecar. No SQLite migration is
required (the data model is unchanged: the dispatched bytes can be HTML or
markdown by content; the new sidecar is a separate `source_markdown_versions`
row written via the existing `appendProcessedMarkdown` API).

### Status

PR open (branch `html-source-tabs`), not merged. Closes #599.

---

## Verification

Historical verification remains in the progress record above.
