---
timestamp: 2026-07-22T052810Z
title: "feat: remove HTML auto-extraction at ingest (PR3 of #799)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: remove HTML auto-extraction at ingest (PR3 of #799)

## Progress


**Goal of #799:** bring HTML + Podcast extraction to parity with PDF — no
auto-extraction at ingest, user chooses a backend and triggers extraction.
PR1 (merged #802) shipped the typed backend enums + Settings pickers
(scaffolding only). PR2 (merged #804) added the Extract button + Re-extract
menu for HTML sources via the inline extraction path. PR3 (this) removes
the auto-extraction that was still running at ingest so the Extract button
becomes the canonical way to extract. PR4 is the podcast framework.

**Scope boundary (AC.12):** the website-snapshot-with-images path
(`storeSnapshot` → `WebsiteSnapshotExtractor`) keeps auto-extracting because
image-src rewriting is inseparable from extraction. Non-snapshot HTML
sources (URL fetch without images, dropped `.html` files, Zotero HTML
attachments) stop auto-extracting.

**Files touched (PR3):**
- **Edit (code):** `Sources/WikiFSCore/Sources/FormatMaterializer.swift`
  (`dispatch` HTML branch skips the `HTMLToMarkdown.convert` body render;
  keeps `.html` format detection + the title-derived filename via the cheap
  `HTMLToMarkdown.titleOnly` scan; `extractedMarkdown: nil` for non-snapshot
  HTML at the dispatch seam — `SourceFormat` + `FormatPlan` doc comments
  updated to reflect the post-PR3 invariant),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (removed the
  `enrichWithDefuddle` call from `addFiles`, the `addURLViaWebsite`
  no-images branch, and `ingestFromZotero`; collapsed the no-images
  `pageEnriched`/`snapshot.page` conditional into `let page = snapshot.page`;
  updated the `enrichWithDefuddle` doc comment to note its callers are gone
  and the active HTML trigger path is `extractHtml(for:backend:)` + the
  static `extractHtml(html:backend:using:)` helper; updated the
  `extractHtml(for:backend:)` doc comment to reflect that it's now the
  CANONICAL HTML extraction path post-PR3),
  `Sources/WikiFSCore/Integrations/WebsiteSnapshotExtractor.swift`
  (`snapshot(html:finalURL:fetcher:filename:provenance:plan:)` now sets
  `page.extractedMarkdown` ONLY when the snapshot has images — the
  storeSnapshot path still gets the image-rewritten sidecar (AC.12
  unchanged); the no-images `addURLViaWebsite` branch stores raw HTML
  only because `appendExtractedMarkdown` (called by `storeMaterialized`)
  returns early on `nil`. The plan-level `snapshotPlan.extractedMarkdown`
  is preserved unchanged for the existing
  `convertedMarkdownCarriesRelativeSrcs` test that reads it).
- **Edit (tests):** `Tests/WikiFSTests/WikiStoreModelAddURLTests.swift`
  (rewrote `htmlURLLandsVerbatimWithMarkdownSidecar` →
  `htmlURLLandsVerbatimWithoutMarkdownSidecar`; asserts no
  `processedMarkdownHead` post-ingest),
  `Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.swift` (deleted
  the PR2 regression-guard `autoExtractionStillRunsAtIngestInPR2` — it
  asserted the OPPOSITE of the new PR3 invariant; its own comment
  acknowledged it would start failing in PR3. Added two new tests:
  `extractHtmlWorksOnUnextractedURLIngest` — AC.9 + AC.13, ingests HTML via
  addURL, asserts no sidecar, then calls `extractHtml` to prove the Extract
  button works on the un-extracted source. `htmlFileIngestDoesNotAutoExtract`
  — AC.10, ingests a real `.html` file via `addFiles` (LocalFileMaterializer
  path), asserts no sidecar + Extract button works. Renamed the
  `AutoExtractionFakeFetcher` helper → `HTMLFakeFetcher` for clarity.),
  `Tests/WikiFSTests/WikiStoreModelZoteroIngestTests.swift`
  (added `zoteroHtmlAttachmentLandsWithoutMarkdownSidecar` — AC.11),
  `Tests/WikiFSTests/WikiStoreModelDropRoutingTests.swift` (rewrote
  `weblocRoutesThroughURLIngestAsMarkdown` →
  `weblocRoutesThroughURLIngestAsRawHTML`; removed the markdown sidecar
  assertion + asserts no `processedMarkdownHead` post-ingest; updated the
  file header + `mixedBatchRoutesEachURLCorrectly` comment to drop the
  stale "markdown stored as a sidecar" phrasing),
  `Tests/WikiFSTests/FormatMaterializerTests.swift` (rewrote the three
  HTML-sidecar tests at the dispatch-seam level:
  `htmlStoredVerbatimWithMarkdownSidecar` → `…WithoutMarkdownSidecar`;
  `htmlWithoutTitleFallsBackToStem`; `xhtmlAlsoStoredVerbatim`; and
  renamed the `htmlSidecarMarkdownIsEmptyWhenBodyIsBlank` →
  `htmlBlankBodyPreservesBytesVerbatim` for clarity. All four now assert
  `plan.extractedMarkdown == nil`),
  `Tests/WikiFSTests/SourceMaterializerTests.swift` (renamed
  `zoteroHtmlAttachmentPreservedWithMarkdownSidecar` → `…WithoutMarkdownSidecar`;
  asserts `source.extractedMarkdown == nil` post-PR3),
  `plans/extraction-framework-pr3.md` (this PR's deep design doc).
- **Docs (master index):** `PLAN.md` (the `extraction-framework.md` row now
  notes PR3 landed — `FormatMaterializer.dispatch` skips the markdown
  sidecar, the three `enrichWithDefuddle` callers are gone,
  `WebsiteSnapshotExtractor` only sets the page sidecar when the snapshot
  has images).

**Key design decisions:**
1. **Two surgical edits at the ingest seam:** (a) `FormatMaterializer.dispatch`
   skips the HTML→Markdown body render, returning `extractedMarkdown: nil`
   for HTML — format detection (`.html`) and the title-based filename via
   `HTMLToMarkdown.titleOnly(from:)` (the cheap tokenize + scan `<title>`
   helper, already used by the snapshot path for the same naming purpose)
   are preserved; only the markdown body compute is skipped. (b) The three
   `enrichWithDefuddle` calls in `addFiles` / `addURLViaWebsite` no-images
   branch / `ingestFromZotero` are removed. Both edits together make a
   fresh HTML source land with NO `source_markdown_versions` row; the
   Extract button from PR2 (`extractHtml(for:backend:)`) creates the first
   row on demand.
2. **`WebsiteSnapshotExtractor` conditional sidecar** (the test-driven
   finding): the original plan noted "snapshots with images stay
   auto-extracting" but didn't account for the fact that
   `WebsiteSnapshotExtractor.snapshot` always sets `page.extractedMarkdown`
   (it computed the markdown regardless of images, then the no-images
   branch wrote it via `appendExtractedMarkdown`). The first test run
   caught this — `extractHtmlWorksOnUnextractedURLIngest` failed because
   the URL ingest was still writing a sidecar via the snapshot path. Fix:
   `page.extractedMarkdown = images.isEmpty ? nil : markdown`. The
   storeSnapshot path (with images) is unchanged — it still reads
   `snapshot.page.extractedMarkdown` which is non-nil when images exist
   (AC.12 holds). The `snapshotPlan.extractedMarkdown` is preserved
   unchanged so the existing `convertedMarkdownCarriesRelativeSrcs` test
   (which reads `snapshot.plan.extractedMarkdown`) still passes.
3. **The `enrichWithDefuddle` method definition is RETAINED** (per the
   operator's instruction) even though it has zero callers post-PR3 — the
   operator said it "can stay" for the PR2 trigger path, but the actual PR2
   trigger path uses the static `extractHtml(html:backend:using:)` helper
   (which I added in PR2 to dispatch between defuddle and tag-based), NOT
   `enrichWithDefuddle`. The method is now dead code; its doc comment is
   updated to reflect this honestly (it's a private building block for any
   future ingest-side defuddle enrichment, kept for comment-chain
   continuity with the active `extractHtml` path). If the operator prefers
   the method deleted in a follow-up, it's a one-line removal.
4. **No schema migration:** pre-PR3 HTML sources keep their existing
   `source_markdown_versions` rows (technique `"html-to-markdown"` from
   the old `dispatch` path, or `"defuddle"` from `enrichWithDefuddle`).
   Only NEW ingests change. This matches the parent plan's "Out of scope"
   section.

**Verification:** `make version prompts && swift build` (clean); full
`swift test` suite — **3,389 tests pass** in 283 suites (~24s after
warm-up). Covers AC.9 (`htmlURLLandsVerbatimWithoutMarkdownSidecar` +
`extractHtmlWorksOnUnextractedURLIngest`), AC.10
(`htmlFileIngestDoesNotAutoExtract`), AC.11
(`zoteroHtmlAttachmentLandsWithoutMarkdownSidecar` — model-level — +
`zoteroHtmlAttachmentPreservedWithoutMarkdownSidecar` — materializer-level),
AC.12 (snapshots with images: `convertedMarkdownCarriesRelativeSrcs` +
`overCapImageSkippedSnapshotCompletes` + the snapshot-with-images
integration tests still pass with no edits to the snapshot code path
itself), AC.13 (`extractHtmlWorksOnUnextractedURLIngest` — Extract button
creates the first markdown version on an un-extracted URL source).

## Verification

Historical verification remains in the progress record above.
