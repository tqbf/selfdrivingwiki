---
timestamp: 2026-07-22T195943Z
title: "2026-07-22 — Content-type registry PR1: filter continuous ingestion (#835-related)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-22 — Content-type registry PR1: filter continuous ingestion (#835-related)

## Progress


**Bug fixed:** `BackgroundIngestCoordinator.scanWiki` enqueued every un-ingested
source that passed `WikiStoreModel.canIngest(source)` — but `canIngest` is a
**byte availability** predicate (`hasProcessedMarkdown || byteSize > 0`), NOT a
markdown-path predicate. So a PNG / XML / random binary source with `byteSize > 0`
sailed through and got enqueued for wasted agent runs (PNG/XML have no markdown
extraction path).

**Fix:** Introduced a content-type registry (`ContentKind` enum +
`ContentCapabilities` struct in `Sources/WikiFSTypes/ContentTypeRegistry.swift`)
with a closed 12-case table that switches on the resolved kind. The coordinator's
`scanWiki` now consults `BackgroundIngestCoordinator.ingestionDecision(for:store:)`
which runs the **registry gate** (`shouldAutoIngest`) BEFORE the existing
byteless guard (`canIngest`). PNG (`image/png` → `.image`) and XML
(`application/xml` → `.binary`) are filtered out before enqueueing.

**Chokepoint NOT touched (§11-C1):** `QueueIngestionHelper.enqueueIngestion`
stays as-is in PR1. The plan-reviewer flagged a critical regression — using
`fromMIME`-only at the chokepoint would drop YouTube/podcast byteless sources
(whose synthetic `video/youtube` MIME classifies as `.binary`). The coordinator
fix alone is sufficient for PR1: PNG/XMF filtered at scan time, before they
reach the chokepoint. The chokepoint migration is deferred to PR2.

**New API:**
- `ContentKind` enum (12 cases) — `ContentTypeRegistry.swift:84`.
- `ContentKind.fromMIME(_:)` — XML exclusion (§11-C3): `text/xml` AND
  `application/xml` → `.binary`, BEFORE the `isText` / `hasPrefix("text/")` check.
- `ContentKind.resolve(mimeType:provider:ext:)` — provider-first for byteless
  embeds (`.youtube` → `.youtubeTranscript`, NOT `.binary`); MIME-first for
  byte-bearing sources; extension fallback for legacy nil-mime markdown sources
  (`.md` → `.markdown`).
- `ContentKind.capabilities: ContentCapabilities` — canExtractToMarkdown,
  shouldAutoIngest, extractionPath.
- `WikiStoreModel.shouldAutoIngest(_:)` — provider-aware wrapper
  (uses `resolve(mimeType:provider:ext:)`), infrastructure for PR2 chokepoint.
- `BackgroundIngestCoordinator.ingestionDecision(for:store:)` — internal static
  testable seam returning `IngestionDecision` (`.enqueue` /
  `.skipNonIngestible(kind:)` / `.skipByteless`). `scanWiki` calls this; tests
  call it directly via `@testable import WikiFS`.
- `BackgroundIngestCoordinator.filterIngestibleSources(_:store:)` — convenience
  batch filter returning `[PageID]` of sources to enqueue.

**Tests:** new `Tests/WikiFSTests/ContentTypeRegistryTests.swift` (40 tests —
exhaustive per-kind capability table + MIME/provider/ext resolution + XML
exclusion + closed-enum count) and `Tests/WikiFSAppTests/
BackgroundIngestCoordinatorTests.swift` (9 tests — per-source decision +
batch filter, including the C5 case where YouTube-with-transcript is enqueued
and YouTube-without is skipped). Full `swift test` suite green (3552 tests /
297 suites). Existing `IngestGateTests` chokepoint regression tests still pass
(unchanged behavior at the chokepoint).

**No DB migration.** The registry reads existing `mime_type` / `ext` /
`agents.name` columns; it adds no schema.

**Build:** `make version prompts && swift build && swift test`.

**Plan:** [`plans/content-type-registry.md`](plans/content-type-registry.md).
PR2 will migrate the UI decision sites (`SourceDetailView.isExtractable` /
`isTranscribable`, `SourcesListView.canExtract`, `AppQueueIngestionProvider`
staging) atop the registry, fix the latent HTML-extract drift in
`SourcesListView.canExtract`, and migrate the chokepoint using
`resolve(mimeType:provider:ext:)` (provider-aware — locks the §11-C1
behavior the critical finding protects).

### Content-type registry PR2 — migrate UI sites + chokepoint (PR2)

**Date:** 2026-07-22 · **Branch:** `content-type-registry-pr2` ·
**Issue:** #835 follow-up (PR2 of the §11-corrected plan)

**Summary:** Consolidates the remaining 5 ad-hoc "can this become markdown?"
sites (the 4 UI decision sites + the deferred chokepoint) onto the PR1
registry. No new behavior change except the latent HTML-extract drift fix
in `SourcesListView.canExtract` (the list menu now offers HTML extraction,
matching the detail-view Extract button) and a widened staging-reuse path
(`AppQueueIngestionProvider` now stages HTML with extracted markdown the
same way PDFs work, instead of re-staging raw HTML bytes).

**Two registry conveniences (`ContentCapabilities`):**
- `hasFileExtractionBackend` — `extractionPath == .pdfBackend || .htmlToMarkdown`.
  Drives the Extract button + staging reuse path. Distinct from
  `canExtractToMarkdown` (which also matches transcript kinds) — using the
  latter for the Extract button, as the plan §5.4 original proposed, would
  have widened the Extract button to podcasts/YouTube, breaking the
  one-button-per-source exclusivity with `needsTranscription` (both would
  be true → two borderedProminent buttons). The two are mutually exclusive
  by construction (one `ExtractionPath` per kind).
- `hasTranscriptBackend` — `extractionPath == .podcastTranscript ||
  .youtubeTranscript`. Drives the Transcribe gate and the
  `SourceProvider.supportsTranscription` delegation.

**Migrated sites (5 + 1 delegation):**
- `SourceProvider.supportsTranscription` (#10) — delegates to the registry.
  Static baseline no longer a duplicated switch; runtime guards stay layered
  on top at `isTranscribable` / `isSourceRefreshable(for:)`.
- `SourceDetailView.isExtractable` / `needsExtraction` (#4, #6) — registry
  via the new `contentKind` computed property. Stays PDF/HTML only (not
  widened to transcript kinds — preserves Extract/Transcribe exclusivity).
- `SourceDetailView.isTranscribable` (#5) — guard-checks
  `hasTranscriptBackend` first; the runtime signing-helper / `#if
  PODCAST_TRANSCRIPTS` switch still layers on top.
- `SourcesListView.canExtract` (#8) — §5.5 latent drift fix: list menu now
  offers Extract for HTML (was PDF-only).
- `SourcesListView.canIngest` (#9) — switches from byte-only to the
  chokepoint-mirrored pair (canIngest + shouldAutoIngest) so the menu hides
  for non-ingestible byte-bearing sources (PNG/XML), consistent with what
  the PR2 chokepoint does.
- `QueueIngestionHelper.enqueueIngestion` chokepoint (#3, §5.2 / §11-C1) —
  adds `shouldAutoIngest` AFTER the existing byte gate. Provider-aware via
  PR1's wrapper (`ContentKind.resolve(mimeType:provider:ext:)` — NOT
  `fromMIME` alone) so a byteless YouTube-with-transcript passes both gates
  (locks the §11-C1 regression case the original §5.2 caught).
- `AppQueueIngestionProvider` staging (#12, §5.6) — registry-driven reuse:
  PDF AND HTML now reuse extracted markdown at stage time (was PDF-only).
  Extracted as `_stagedBytesAndExt(for:originalBytes:processedMarkdownHead:)`
  `nonisolated static` seam so tests can exercise it directly.

**Sites that stay as-is (per §5.7):**
- `SourceProvider.supportsRefresh` (#11) — orthogonal (re-fetch capability,
  not markdown-path).
- `ExtractionCoordinator.current()` (#13) — backend resolver, not a
  content-type decision.
- `WikiStoreModel.canIngest(_:)` (#1) — stays the byte-availability predicate
  the manual Ingest button needs; the registry's content-type gate lives at
  the chokepoint (PR2) + the coordinator (PR1) + the list view (PR2).

**Testable seams (`internal static` + `nonisolated`):**
- `SourceDetailView.extractionAffordance(mimeType:provider:ext:)` — returns
  `.extract` / `.transcribe` / `.none`. Pure registry decision (the runtime
  guards layer elsewhere).
- `SourcesListContentGates.canExtract(source:processedMarkdownHead:)` —
  pure registry decision for the list-menu Extract item.
- `AppQueueIngestionProvider._stagedBytesAndExt(for:originalBytes:
  processedMarkdownHead:)` — pure registry decision for staging reuse.
- PR1's `BackgroundIngestCoordinator.ingestionDecision(for:store:)` /
  `filterIngestibleSources(_:store:)` already in place.

**Tests:**
- `Tests/WikiFSTests/ContentTypeRegistryTests.swift` — extended with
  partition + exclusivity invariants for the two new conveniences (5 tests
  added; PR1's 40 tests unchanged).
- `Tests/WikiFSAppTests/SourceDetailViewContentKindTests.swift` (NEW) —
  per-kind affordance, YouTube-with-provider-vs-without, closed-enum
  partition.
- `Tests/WikiFSAppTests/SourcesListContentGatesTests.swift` (NEW) — the
  headline HTML-extract drift fix, head-suppression, non-extractable kinds.
- `Tests/WikiFSAppTests/SourceProviderSupportsTranscriptionTests.swift`
  (NEW) — exhaustive provider × registry equivalence for the delegation.
- `Tests/WikiFSAppTests/AppQueueIngestionProviderStagingTests.swift` (NEW)
  — PDF/HTML reuse (incl. the PR2 widening), non-extractable kinds skip
  reuse, edge cases (non-UTF8, empty ext).
- `Tests/WikiFSAppTests/IngestGateTests.swift` extended with the §11-C7
  regression — byteless YouTube WITH transcript passes the chokepoint (not
  dropped by the new `shouldAutoIngest` gate). Plus two drops (PNG byte-
  bearing, XML byte-bearing) and a mixed batch.
- Full `swift test` suite green (3640 tests / 302 suites).

**No DB migration.** Same column reads as PR1 — PR2 is pure source/test.

**Build:**
`make version prompts && swift build && swift test`.

**Plan:** [`plans/content-type-registry.md`](plans/content-type-registry.md)
§PR2 (appended; §PR1 covers PR1's scope, §§1-11 the shared design).

## Verification

Historical verification remains in the progress record above.
