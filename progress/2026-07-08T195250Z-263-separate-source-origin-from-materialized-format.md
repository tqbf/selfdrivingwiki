---
timestamp: 2026-07-08T195250Z
title: "2026-07-08 — #263: Separate source origin from materialized format"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #263: Separate source origin from materialized format

## Progress


**Shipped (code-only refactor; 1974 tests green).** Extracted the format-dispatch
logic from `URLFetchService.plan(for:)` into a standalone, URL-independent
`FormatMaterializer.dispatch(data:contentType:stem:extensionHint:)`. Every
byte-producing origin now routes through it.

**What shipped:**
- **`FormatMaterializer.swift`** (new) — `SourceFormat` enum, `FormatPlan`
  struct, `FormatMaterializer.dispatch(...)`. The pure format dispatcher: sniffs
  ambiguous types, converts HTML→Markdown, stores PDF/text/binary verbatim,
  derives filename from `stem` + `extensionHint`. No URL/store/network
  dependency (AC.7: source-grep test enforces this).
- **`URLFetchService.swift`** — `plan(for:)` is now a thin wrapper:
  `nameHint(for:)` extracts `(stem, extHint)` from `response.finalURL` →
  `FormatMaterializer.dispatch` → `mapFormat` to `FetchOutcome.Kind`. Thin
  forwarders for all moved helpers (`normalizedMIME`, `decodeText`, `shouldSniff`,
  `sniffContentType`, `sanitizeStem`, `ensureExtension`, `textExtension`,
  `binaryExtension`) so existing consumers + tests compile unchanged.
- **`SourceMaterializer.swift`** — `WebsiteMaterializer.materializeWithPlan()`
  returns `FormatPlan` (calls `FormatMaterializer.dispatch` directly).
  `WebsiteSnapshot.plan` type → `FormatPlan`. `LocalFileMaterializer` migrated
  to call `FormatMaterializer.dispatch` directly (no synthetic `FetchResponse`).
  **`ZoteroMaterializer` now routes through `FormatMaterializer.dispatch`** —
  fixing the bypass (HTML attachments convert to Markdown; PDFs get extension
  inference + sniffing).
- **`WebsiteSnapshotExtractor.swift`** — takes `FormatPlan`, checks
  `plan.format == .htmlConverted`.
- **`WikiStoreModel.swift`** — `addURLViaWebsite` reads `snapshot.plan.format`,
  maps to `FetchOutcome.Kind`.
- **Tests:** `FormatMaterializerTests` (20 new pure dispatch tests — AC.1/AC.7);
  `SourceMaterializerTests.zoteroProviderSetsItemKeyProvenance` strengthened
  (asserts filename + bytes — AC.4); new `zoteroHtmlAttachmentConvertsToMarkdown`
  (AC.3); `WikiStoreModelZoteroIngestTests` `attachment(key:filename:)` helper
  gains `contentType:` parameter; `WebsiteSnapshotExtractorTests` updated to
  `FormatPlan`.

**Behavior change:** Zotero HTML attachments now convert to Markdown (bugfix).
Existing Zotero sources are unaffected (only new ingests change).

**Gate:** `swift test` exit 0 — 1954 tests in 159 suites.

## Verification

Historical verification remains in the progress record above.
