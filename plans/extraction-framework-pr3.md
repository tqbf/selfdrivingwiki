# Plan: Extraction Framework PR3 — Remove HTML Auto-Extraction at Ingest (#799)

**Parent plan:** [`plans/extraction-framework.md`](extraction-framework.md) (4-PR
staged plan to bring HTML + Podcast extraction to parity with PDF). This doc is
the deep dive for PR3 only — removing the auto-extraction calls that PR1 + PR2
left in place so the user always had a way to extract while the trigger UI
landed.

PR1 (merged `69fe6e9`, #802) shipped the typed enums (`HtmlExtractionBackend`,
`PodcastTranscriptionBackend`) + `ExtractionConfig.htmlBackend` / `.podcastBackend`
optional fields + Settings pickers (scaffolding only, no behavior change). PR2
(merged `b3f4a47`, #804) added the **Extract button** + **Re-extract with**
menu for HTML sources via the existing inline extraction path:
`WikiStoreModel.extractHtml(for:backend:)` reads the source bytes, runs the
chosen extractor (defuddle or tag-based), and writes a `.extraction`-origin
processed-markdown version through `appendProcessedMarkdown`. While PR2 was in
flight the ingest path **still auto-extracted** — the three `enrichWithDefuddle`
callers + the `FormatMaterializer.dispatch` HTML→Markdown sidecar computation
remained. PR3 (this) removes them now that the trigger UI is the canonical way
to extract. PR4 is the podcast framework.

## Goal

Stop auto-extracting markdown at ingest time. Non-snapshot HTML sources (URL
fetch without images, dropped `.html` files, Zotero HTML attachments) store the
raw HTML bytes only; **no `source_markdown_versions` row** is written for the
extracted technique at ingest. The user triggers extraction on demand via the
Extract button added in PR2.

**Scope boundary (AC.12):** the website-snapshot with-images path
(`storeSnapshot`) **keeps auto-extracting**. `WebsiteSnapshotExtractor`
computes markdown with image-src rewriting (the `<img src>` tokens are
rewritten to relative sibling paths before render); image-src rewriting is
inseparable from extraction — without it the user gets broken image
references. This is a different operation from "extract article markdown": it's
image-handler output, and removing it would be a significant UX regression.

## Design summary

Two edits at the ingest seam, both narrowly scoped:

1. **`FormatMaterializer.dispatch`** — for HTML, stop computing the
   `extractedMarkdown` sidecar (the tag-based `HTMLToMarkdown.convert` body
   render). Format detection (`.html`) and the title-derived filename stay so
   the source is tagged correctly + named well; only the markdown body
   computation is skipped. Uses the already-available cheap
   `HTMLToMarkdown.titleOnly(from:)` (tokenize + scan `<title>`) for the
   filename, which is what the snapshot path uses for the same purpose.
2. **`WikiStoreModel`** — remove the **three** `enrichWithDefuddle` calls from
   the non-snapshot ingest paths (`addFiles`, `addURLViaWebsite` no-images
   branch, `ingestFromZotero`). Raw HTML bytes flow straight to
   `store.addSource`; `appendExtractedMarkdown` is a no-op for HTML sources
   after PR3 because `m.extractedMarkdown` is now `nil` (it returns early on
   the existing `guard let markdown = m.extractedMarkdown, !markdown…else`
   guard).

Result: a fresh HTML source has zero rows in `source_markdown_versions`; the
Extract button from PR2 then creates the first row on demand.

Why the snapshot path is unaffected: `SourceMaterializer.materializeSnapshot`
calls `FormatMaterializer.dispatch` to detect `.html`, then for HTML pages
calls `WebsiteSnapshotExtractor.snapshot(...)` which builds its OWN
`MaterializedSource` and `FormatPlan` (line 311-321 in
`WebsiteSnapshotExtractor.swift`) overriding `extractedMarkdown` with the
image-rewritten markdown it computed via `HTMLToMarkdown.scopedTokens` +
`rewriteImageSrcs` + `HTMLToMarkdown.markdown(fromScopedTokens:)`. The
dispatch-side `extractedMarkdown` is ignored. So removing the dispatch-side
sidecar computation has **no effect** on the snapshot path's data — its markdown
still lands via `appendExtractedMarkdown(to: pageSummary, from: snapshot.page)`
in `storeSnapshot` (line 2559), which now reads the snapshot's own image-
rewritten markdown from `snapshot.page.extractedMarkdown`.

### Implementation-time finding (test-driven) — `WebsiteSnapshotExtractor`
conditional sidecar

The original plan assumed removing the three `enrichWithDefuddle` calls +
the dispatch-side sidecar computation was sufficient to stop non-snapshot HTML
auto-extraction. **It wasn't.** `WebsiteSnapshotExtractor.snapshot` always set
`page.extractedMarkdown = markdown` (even when the snapshot had no images —
the markdown was just the same tag-based conversion `dispatch` had stopped
doing). The first full-suite test run caught this:
`extractHtmlWorksOnUnextractedURLIngest` failed because URL HTML ingest was
still writing a sidecar via the snapshot path (the no-images branch's
`storeMaterialized(page)` calls `appendExtractedMarkdown`, which saw the
non-nil sidecar set by the snapshot extractor and wrote it).

Fix (one line in `WebsiteSnapshotExtractor.swift`, at the `MaterializedSource`
construction):

```swift
let pageExtractedMarkdown = images.isEmpty ? nil : markdown
let page = MaterializedSource(
    filename: filename,
    data: Data(html.utf8),
    mimeType: nil,
    provenance: provenance,
    extractedMarkdown: pageExtractedMarkdown)
```

This honors the scope boundary precisely: image-bearing snapshots STILL
write the sidecar (storeSnapshot path unchanged — `snapshot.page.extractedMarkdown`
is non-nil because `images.isEmpty` is false); no-images URL ingests do NOT
write a sidecar (the no-images branch's `storeMaterialized` →
`appendExtractedMarkdown` sees `nil` and returns early — exactly the PR3
invariant for AC.9). The `snapshotPlan.extractedMarkdown = markdown` field
is preserved unchanged so the existing
`convertedMarkdownCarriesRelativeSrcs` test (which reads
`snapshot.plan.extractedMarkdown`) keeps passing.

## Concrete changes

### 1. `FormatMaterializer.dispatch` — skip markdown body render for HTML

`Sources/WikiFSCore/Sources/FormatMaterializer.swift` lines 111-125 currently:

```swift
if mime == MimeType.html || mime == MimeType.xhtml {
    // Issue #599: preserve the original HTML bytes as the source blob
    // (mirroring PDF → pdf2md extraction). The extracted markdown rides
    // as a sidecar on the FormatPlan and is written as a
    // `.extraction`-origin processed-markdown version by the store path.
    let html = decodeText(data)
    let result = HTMLToMarkdown.convert(html)
    let resolvedStem = result.title.flatMap { nonEmpty($0) } ?? stem
    let filename = ensureExtension(sanitizeStem(resolvedStem), ext: "html")
    return FormatPlan(
        filename: filename,
        data: data,
        format: .html,
        extractedMarkdown: result.markdown)
}
```

After PR3:

```swift
if mime == MimeType.html || mime == MimeType.xhtml {
    // Issue #799 PR3: extraction no longer runs at ingest time. Still
    // detect `.html` so the source is tagged correctly, and use the
    // document `<title>` (when present) for the filename stem — same
    // naming UX as the old `convert` path, but NO markdown body computed.
    // The user triggers extraction via the Extract button (PR2).
    // The cheap `titleOnly` scan (tokenize + scan `<title>`) avoids the
    // full tag→markdown render at ingest; the snapshot path uses the same
    // call for naming before it rewrites image srcs.
    let html = decodeText(data)
    let resolvedStem = HTMLToMarkdown.titleOnly(from: html)
        .flatMap { nonEmpty($0) } ?? stem
    let filename = ensureExtension(sanitizeStem(resolvedStem), ext: "html")
    return FormatPlan(
        filename: filename,
        data: data,
        format: .html,
        extractedMarkdown: nil)
}
```

`HTMLToMarkdown.titleOnly(from:)` already exists (`Sources/WikiFSMarkdown/
HTMLToMarkdown.swift:71`) for exactly this purpose — it's the cheap title scan
without the body render. The snapshot path uses it implicitly (via the
`scopedTokens` + `extractTitle` flow). Pre-PR3, `convert` returned both
`markdown` and `title` so the title came "for free"; PR3 splits the title scan
out (it's still `O(n)` over the input length and bounded by `Tokenizer`, but
no `Renderer` pass).

### 2. Remove `enrichWithDefuddle` calls from three ingest callers

`Sources/WikiFSCore/Store/WikiStoreModel.swift`:

| Caller | Line (pre-PR3) | Change |
|--------|----------------|--------|
| `addFiles` | `:2073-2074` | Delete the `enrichWithDefuddle` call + its comment. The downstream `materializedEnriched` references become `materialized`. |
| `addURLViaWebsite` no-images branch | `:2482-2487` | Collapse the `if format == .html && images.isEmpty` block (which only existed to gate enrichment) into `pageEnriched = snapshot.page`; rename `pageEnriched` → `page`. The conditional that routes to `storeSnapshot` vs. `storeMaterialized` (line 2495-2499) **stays** — it's the snapshot-with-images scope boundary (AC.12). |
| `ingestFromZotero` | `:2666-2667` | Delete the `enrichWithDefuddle` call + its comment. The downstream `materializedEnriched` references become `materialized`. |

**What stays:** the `enrichWithDefuddle` method definition itself (`:2020`)
and its constants (`htmlToMarkdownTechnique` `:2002` is used by the
`extractHtml` trigger path's tag-based fallback; `defuddleTechnique` `:2009`
is used by the defuddle branch of `extractHtml`). Per the operator, the method
is retained so the PR2 trigger path's parallel building block is documented;
its doc comment is updated to reflect that the three ingest callers listed in
the comment are gone (it's now a private fallback building block, kept for
provenance/comment continuity with the `extractHtml(html:backend:using:)`
helper at `:3138` that does the real backend dispatch).

The `extractHtml(html:backend:using:)` static helper (`:3138`) — added in PR2
— is untouched; it dispatches to the injected `htmlMarkdownExtractor` (defuddle
backend) or `TagBasedHtmlExtractor` (tag-based backend), with the same fallback
semantics `FormatMaterializer.enrich` had. **This is the path that the Extract
button uses**; PR3 just stops the ingest path from pre-populating the
extracted chain that path writes to.

### 3. No schema migration

Pre-PR3 HTML sources already have a markdown version row (stamped with
technique `"html-to-markdown"` from `FormatMaterializer.dispatch` or
`"defuddle"` from `enrichWithDefuddle`). PR3 leaves those rows in place —
existing sources keep their pre-extracted markdown. Only NEW ingests change.
This matches the parent plan's "Out of scope" section: "Migrating existing
auto-extracted sources — their markdown versions persist. Only new ingests
change."

### 4. Downstream impacts (must document, are acceptable per #799)

After PR3 a fresh HTML source has no `source_markdown_versions` HEAD, so:

1. **Search (Tantivy BM25 + FTS5)** indexes title-only, body unsearchable
   until extracted. Not broken — degraded. The search sidecar is built from
   processed markdown; when there's no processed markdown it falls back to
   filename (the existing name-only fallback path for un-extracted/binary
   sources covers it uniformly).
2. **File Provider `.md` sibling**: no `.md` projected — the source appears as
   raw `.html` in Finder. A visible behavior change, but the user clicks
   Extract (PR2) to surface the `.md` again.
3. **Reader view**: the `SourceDetailView` Reader tab falls through to the
   HTML tab (the verbatim-bytes WebView), which is already a supported surface
   for HTML sources. No crash, no broken state.
4. **Agent ingestion**: the agent gets raw HTML bytes when it asks for the
   source's processed markdown (it falls back to the raw bytes when no
   processed-markdown HEAD exists). May degrade agent quality for HTML
   sources until the user extracts — this is the explicit "no automatic
   extraction" directive.

Each is acceptable given #799's directive: stop auto-extracting, let the user
choose the backend + trigger explicitly.

## Acceptance criteria

- **AC.9**: Ingesting a URL (no images) stores raw HTML with NO markdown sidecar
  (`source_markdown_versions` for that source id is empty).
- **AC.10**: Ingesting an HTML file from a folder via `addFiles` stores raw HTML
  with NO markdown sidecar.
- **AC.11**: Ingesting a Zotero HTML attachment stores raw HTML with NO
  markdown sidecar.
- **AC.12**: Website snapshots with images still auto-extract — the
  `storeSnapshot`→`appendExtractedMarkdown(to:from:)` path keeps writing the
  image-rewritten markdown as a `.extraction`-origin processed-markdown version.
- **AC.13**: The "Extract" button from PR2 (`model.extractHtml(for:backend:)`)
  works on these un-extracted sources — calling it on a source ingested after
  PR3 creates the first markdown version (HEAD by the default-active rule,
  technique stamped per the chosen backend).

## Tests

Three existing tests assert the OLD pre-PR3 behavior (markdown sidecar lands at
ingest). They would start failing once the dispatch change lands; PR3 rewrites
them to assert the new invariant (NO sidecar):

- **`Tests/WikiFSTests/WikiStoreModelAddURLTests.htmlURLLandsVerbatimWithMarkdownSidecar`**
  → rewrite as `htmlURLLandsVerbatimWithoutMarkdownSidecar`. Asserts
  `outcome.kind == .html`, filename `"My Doc.html"` (title via `titleOnly`),
  source bytes equal the original HTML, **no `processedMarkdownHead`**.
  (Covers AC.9.)
- **`Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.autoExtractionStillRunsAtIngestInPR2`**
  → delete. It's the explicit PR2 regression guard; its own comment acknowledges
  it "will START FAILING in PR3 — it's the regression guard that PR3's
  'remove auto-extraction' work is intentionally deleting this behavior."
- **`Tests/WikiFSTests/WikiStoreModelDropRoutingTests.weblocRoutesThroughURLIngestAsMarkdown`**
  → rewrite as `weblocRoutesThroughURLIngestAsRawHTML`. Removes the markdown
  sidecar assertion (lines 70-73); asserts no `processedMarkdownHead`. The
  file header + the `mixedBatchRoutesEachURLCorrectly` comment also drop the
  "markdown stored as a sidecar" phrasing.

Three new tests cover the new PR3 invariants not directly exercised today:

- **`Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.htmlFileIngestDoesNotAutoExtract`**
  (AC.10) — writes a real `.html` fixture to a temp file, ingests via
  `addFiles` (exercises `LocalFileMaterializer` → `FormatMaterializer.dispatch`
  HTML branch), asserts **no `processedMarkdownHead`** + source bytes preserved
  verbatim. (LocalFileMaterializer derives MIME from `UTType("html")` on macOS
  → dispatch hits the HTML branch; on Linux `UTType` is unavailable, the MIME
  is nil, dispatch falls through to binary storage, and the test passes for the
  wrong reason — same Linux limitation noted in the existing PR2 tests.
  CI is macOS-only per AGENTS.md.)
- **`Tests/WikiFSTests/WikiStoreModelZoteroIngestTests.zoteroHtmlAttachmentLandsWithoutMarkdownSidecar`**
  (AC.11) — ingests a fake HTML Zotero attachment (`contentType: "text/html"`),
  asserts source bytes preserved + **no `processedMarkdownHead`**.
- **`Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.extractHtmlWorksOnUnextractedURLIngest`**
  (AC.13) — ingests HTML via `addURL`, asserts no markdown version exists (the
  PR3 invariant), THEN calls `model.extractHtml(for:backend:.tagBased)` and
  asserts the version IS created (HEAD, `.extraction` origin,
  `"html-to-markdown"` technique) — proves the Extract button works on
  un-extracted sources.

The existing PR2 trigger tests (`extractHtmlWithTagBasedStampsHtmlToMarkdownTechnique`,
`extractHtmlWithDefuddleDegradesToTagBasedWhenExtractorNotInjected`,
`reExtractHtmlAppendsCoexistingAlternative`, `extractHtmlOnEmptySourceReturnsNil`)
are unchanged — they use `modelWithHTMLSource()` which calls `store.addSource`
directly (bypassing the materializer path entirely), so they're independent of
PR3's dispatch change.

## Build & test

```bash
make prompts && swift build       # compile (GeneratedPrompts.swift regen)
swift test                        # full suite — ~1.5 min (in-memory fixtures #658)
```

## Files touched

- **New:** none.
- **Edit (code):** `Sources/WikiFSCore/Sources/FormatMaterializer.swift` (skip
  markdown sidecar in `dispatch`; keep `.html` detection + title-based filename
  via `titleOnly`; update `SourceFormat` + `FormatPlan` doc comments to reflect
  the post-PR3 invariant),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (remove 3
  `enrichWithDefuddle` calls; collapse the `addURLViaWebsite` no-images
  branch; update the `enrichWithDefuddle` doc comment + the `extractHtml`
  doc comment that referenced the ingest-time `enrichWithDefuddle`→
  `appendExtractedMarkdown` path as a model),
  `Sources/WikiFSCore/Integrations/WebsiteSnapshotExtractor.swift`
  (conditionally set `page.extractedMarkdown` — only when the snapshot has
  images, so the no-images `addURLViaWebsite` branch stores raw HTML only;
  the storeSnapshot path with images is unchanged — see "Implementation-time
  finding" above. `snapshotPlan.extractedMarkdown` remains unchanged for
  test continuity).
- **Edit (tests):** `Tests/WikiFSTests/WikiStoreModelAddURLTests.swift`
  (rewrite the sidecar test → no-sidecar — AC.9),
  `Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.swift`
  (delete the PR2 regression-guard test; add the file-URL no-auto-extract test
  — AC.10 — + the URL-ingest + Extract-button-works test — AC.9 + AC.13;
  rename `AutoExtractionFakeFetcher` → `HTMLFakeFetcher`),
  `Tests/WikiFSTests/WikiStoreModelZoteroIngestTests.swift` (add the HTML
  attachment no-sidecar test — AC.11),
  `Tests/WikiFSTests/WikiStoreModelDropRoutingTests.swift`
  (rewrite the webloc test + comment cleanup),
  `Tests/WikiFSTests/FormatMaterializerTests.swift` (rewrite the three
  HTML dispatch-seam tests + rename `htmlSidecarMarkdownIsEmptyWhenBodyIsBlank`
  → `htmlBlankBodyPreservesBytesVerbatim`; all four now assert
  `plan.extractedMarkdown == nil`),
  `Tests/WikiFSTests/SourceMaterializerTests.swift`
  (rename `zoteroHtmlAttachmentPreservedWithMarkdownSidecar` →
  `…WithoutMarkdownSidecar`; assert `source.extractedMarkdown == nil`).
- **Edit (docs):** `PLAN.md` (master index — mark PR3 landed +
  the `WebsiteSnapshotExtractor` scope-boundary tweak),
  `PROGRESS.md` (entry for PR3), this file.

## Out of scope (covered by parent plan)

- Queue engine generalization — HTML extraction uses the inline path; the
  PDF-coupled queue stays PDF-only (deferred per parent plan).
- The `addURLViaWebsite` website-snapshot-with-images path is **unchanged** —
  snapshots with images keep auto-extracting (image-src rewriting is
  inseparable from extraction, per parent plan §PR3 decision).
- Pre-existing auto-extracted sources keep their markdown versions; only new
  ingests change.
- PR4 (podcast framework) is a separate, independently-shippable PR.
