---
timestamp: 2026-07-22T042850Z
title: "feat: HTML extraction trigger (PR2 of #799)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: HTML extraction trigger (PR2 of #799)

## Progress


**Goal of #799:** bring HTML + Podcast extraction to parity with PDF — no
auto-extraction at ingest, user chooses a backend and triggers extraction.
PR1 (merged #802) shipped the typed backend enums + `ExtractionConfig.htmlBackend`
+ Settings pickers (scaffolding only). PR2 (this) adds the Extract button and
the Re-extract menu for HTML sources via the **existing inline extraction
path** (not the queue engine — that's PDF-coupled via
`ExtractionResolution.pdfData` / `convert(pdfData:)` / `seedPdfMarkdown` and
generalizing it is a deferred sub-project). PR3 will remove the three
`enrichWithDefuddle` callers at ingest; PR4 is the podcast framework.

**Critical ordering:** PR2 ships BEFORE PR3. At every intermediate state the
user must have a way to extract — either via the still-running auto-extraction
(PR2) or via the new Extract button (PR2 / PR3).

**Files touched (PR2):**
- **New:** `Sources/WikiFSMarkdown/HtmlMarkdownExtractor.swift` (moved from
  `WikiFSCore/FormatMaterializer.swift`), `Tests/WikiFSTests/WikiStoreModelHtmlExtractionTests.swift`.
- **Edit:** `Sources/WikiFSMarkdown/HTMLToMarkdown.swift` (the
  `TagBasedHtmlExtractor: HtmlMarkdownExtractor` conformer),
  `Sources/WikiFSMarkdown/HtmlExtractionBackend.swift` (no code edits — the
  doc comment already references the conformer),
  `Sources/WikiFSCore/Sources/FormatMaterializer.swift` (the protocol + result
  struct moved out, replaced with a pointer comment),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (`extractHtml` method +
  `@ObservationIgnored var htmlBackend` field + `defuddleTechnique` constant +
  private dispatch helper),
  `Sources/WikiFSEngine/WikiSession.swift` (init param + assignment),
  `Sources/WikiFSEngine/SessionManager.swift` (init param + pass-through),
  `Sources/WikiFS/Window/WikiFSApp.swift` (resolver from `ExtractionConfig`),
  `Sources/WikiFS/Sources/SourceDetailView.swift` (`isExtractable` computed
  prop generalizing `isPDF`; `needsExtraction` now `isExtractable &&
  !hasMarkdown`; the Extract button dispatches by content type to
  `runHtmlExtraction` or `runExtraction`; the provenance chip's gate widens
  from `isPDF` to `isExtractable`; the Re-extract menu's `ForEach` splits into
  HTML (`HtmlExtractionBackend.allCases` → `runHtmlReExtraction`) and PDF
  (`ExtractionBackend.allCases` → `runReExtraction`) branches),
  `plans/extraction-framework-pr2.md` (this PR's deep design doc).

**Key design decisions:**
1. **Module refactor:** `HtmlMarkdownExtractor` protocol + `HtmlExtractionResult`
   struct moved from `WikiFSCore/FormatMaterializer.swift` to a new file
   `WikiFSMarkdown/HtmlMarkdownExtractor.swift`. The issue directive placed
   the `TagBasedHtmlExtractor` conformer in `WikiFSMarkdown/HTMLToMarkdown.swift`,
   but `WikiFSMarkdown` (which depends only on `WikiFSTypes`/`WikiFSLinks`)
   couldn't see the protocol. Moving the protocol + result struct to
   `WikiFSMarkdown` (alongside the PDF `MarkdownExtractor` /
   `ExtractionBackend` siblings — same domain) honors the directive: the
   conformer in `HTMLToMarkdown.swift` now sees the protocol naturally.
   `WikiFSCore` re-exports `WikiFSMarkdown` via
   `@_exported import` (`ModuleExports.swift`), so every existing caller that
   `import WikiFSCore` continues to see these types unchanged — verified by
   the full 3,371-test suite passing.
2. **Inline extraction path, not queue:** `WikiStoreModel.extractHtml` reads
   the source's HTML bytes via `store.sourceContent(id:)`, runs the chosen
   extractor (defuddle = the injected `htmlMarkdownExtractor`, or
   `TagBasedHtmlExtractor`), writes the result via
   `appendProcessedMarkdown` with the matching technique tag
   (`"defuddle"` / `"html-to-markdown"`). `appendProcessedMarkdown` always
   appends (never clobbers) — first version is HEAD by the default-active
   rule, later versions ride as coexisting alternatives. So Extract and
   Re-extract flow through the SAME method; provenance is differentiated by
   the `technique` column and version id.
3. **Defuddle fallback:** when the user picks `.defuddle` but no
   `htmlMarkdownExtractor` is injected (CI / clean dev), the call degrades
   to `TagBasedHtmlExtractor` (mirrors `FormatMaterializer.enrich`'s
   fallback semantics at ingest) rather than silently returning nil — so the
   user always gets a markdown version on Extract.
4. **Config wiring mirrors `htmlMarkdownExtractor`:** `@ObservationIgnored
   public var htmlBackend: HtmlExtractionBackend?` on `WikiStoreModel` +
   `htmlBackendResolver: @MainActor () -> HtmlExtractionBackend?` factories
   on `WikiSession` + `SessionManager`, with `{ nil }` defaults for
   headless/daemon/test callers. `WikiFSApp` wires the resolver to
   `ExtractionConfig.load(from: directory).htmlBackend`. The model is
   deliberately NOT config-aware (config is read by `ExtractionCoordinator`
   in `WikiFSEngine`).

**Acceptance (per `plans/extraction-framework-pr2.md`):**
- **AC.5**: `"Extract" button appears on an HTML source with no markdown.
  Clicking with tag-based creates a markdown version (technique
  "html-to-markdown")` — covered by
  `WikiStoreModelHtmlExtractionTests.extractHtmlWithTagBasedStampsHtmlToMarkdownTechnique`.
  View-level gate covered by `isExtractable` predicate + Extract button dispatch.
- **AC.6**: `"Extract" with defuddle ... technique "html-to-markdown"` (when
  no extractor is injected — degrades to tag-based) — covered by
  `extractHtmlWithDefuddleDegradesToTagBasedWhenExtractorNotInjected`.
- **AC.7**: `"Re-extract with" on an HTML source creates a coexisting
  alternative` — covered by `reExtractHtmlAppendsCoexistingAlternative`
  (asserts v1.id ≠ v2.id, both in history, v2 is HEAD by default-active rule).
- **AC.8**: `Existing auto-extraction at ingest still runs` — covered by
  `autoExtractionStillRunsAtIngestInPR2` (ingests an HTML file via
  `model.addFiles`, asserts that the ingest path still wrote a markdown
  sidecar with technique `"html-to-markdown"`, and that the original HTML
  bytes are preserved as the source blob). This test is the **regression
  guard** for PR3 — when PR3 removes the `enrichWithDefuddle` callers, this
  test will start failing, which is the intended signal that the
  behavior-change landed.

**Tests added (5 new, 3,371 total pass):** all in
`WikiStoreModelHtmlExtractionTests.swift` — uses a real `GRDBWikiStore` in a
temp directory (in-memory fixtures since #658, ~1.5 min full suite). No
mocking — the inline path is simple enough to exercise end-to-end.

**Build:** `make version prompts && swift build` clean (36s); `swift test`
clean (3,371 tests in 5 suites passed after 34.33s; full run ~1.5 min).

## Verification

Historical verification remains in the progress record above.
