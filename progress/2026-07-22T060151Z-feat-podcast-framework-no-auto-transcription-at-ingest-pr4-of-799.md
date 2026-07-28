---
timestamp: 2026-07-22T060151Z
title: "feat: podcast framework — no auto-transcription at ingest (PR4 of #799)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: podcast framework — no auto-transcription at ingest (PR4 of #799)

## Progress


**Goal of #799:** bring HTML + Podcast extraction to parity with PDF — no
auto-extraction at ingest, user chooses backend and triggers extraction.
PR1 (merged #802) shipped the typed backend enums + Settings pickers
(scaffolding only). PR2 (merged #804) added the Extract button + Re-extract
menu for HTML sources via the inline extraction path. PR3 (merged #806)
removed auto-extraction at ingest so the Extract button is the canonical
HTML path. PR4 (this) is the **architectural outlier** — podcast
transcription is a network fetch (signed bearer → AMP → TTML → parse →
markdown), NOT a bytes→markdown transform, so it required a separate
code path (NOT through the PDF-coupled queue engine) and a Transcribe
button that's disabled when the signing helper is unavailable.

**Files touched (PR4):**
- **New:** `plans/extraction-framework-pr4.md` (this PR's deep design doc)
  — the 749-line plan covering the architectural difference, the three
  concrete edits, the test rewrites, and the acceptance criteria. Committed
  first per the issue directive ("First commit: write this plan into
  plans/extraction-framework-pr4.md").
- **Edit (code):** `Sources/WikiFSCore/Store/WikiStoreModel.swift` (the
  `addURL` podcast branch is rewritten — byteless-only ingest, no
  transcript fetch, no synthetic markdown placeholder; the new
  `transcribePodcast(sourceID:fetcher:)` method — a direct network
  operation that reconstructs the episode URL from `origin.plan` and
  calls `ApplePodcastMaterializer.materialize()`, writing via
  `appendProcessedMarkdown(origin: .transcript, technique: "apple-ttml")`;
  the new `podcastBackend` injection point mirroring `htmlBackend`; the
  `podcastTtmlTechnique` + `podcastEmbedMIME` constants + the
  `podcastEmbedFilename(for:)` private static helper), 
  `Sources/WikiFSEngine/WikiSession.swift` (`podcastBackendResolver`
  init param + assignment; also threads the previously-orphaned
  `htmlBackendResolver` through to the WikiSession constructor — a PR2
  plumbing gap fixed in flight),
  `Sources/WikiFSEngine/SessionManager.swift` (`podcastBackendResolver`
  factory + pass-through at the `WikiSession(...)` call site),
  `Sources/WikiFS/Window/WikiFSApp.swift` (`podcastBackendResolver` from
  `ExtractionConfig.load(from: directory).podcastBackend`),
  `Sources/WikiFS/Sources/SourceDetailView.swift` (the `isPodcastEmbed`
  / `isTranscribable` / `needsTranscription` / `hasExtractionChip`
  predicates; the new `@State isTranscribing` + `@State transcribeError`;
  the Transcribe button on podcast sources with no transcript; the
  `runTranscription()` / `runTranscription(with:)` action methods
  mirroring `runHtmlExtraction` / `runHtmlReExtraction`; the podcast
  branch in the "Re-extract with" menu showing
  `PodcastTranscriptionBackend.allCases`; the `transcribeError` row
  alongside `refreshError`).
- **Edit (tests):** `Tests/WikiFSTests/PodcastIngestRoutingTests.swift`
  (rewrote `episodeURLRoutesToTranscriptPipelineAndStoresMarkdown` →
  `episodeURLStoresBytelessEmbedWithoutTranscript` — AC.14 — asserting
  byteless-only ingest: `outcome.kind == .audioEmbed`, byteless
  `byteSize == 0`, NO `processedMarkdownHead`, fetcher was NOT consulted
  at ingest; rewrote `missingHelperGivesAClearError` →
  `transcribePodcastThrowsSignatureUnavailableWithoutHelper` — AC.16 —
  ingest now SUCCEEDS without a helper; `transcribePodcast(sourceID:)`
  throws `PodcastTranscriptError.signatureUnavailable` when fetcher is
  nil; rewrote `podcastURLStaysFirstInRoutingPrecedence` — outcome.kind
  → `.audioEmbed`, fetcher not consulted at ingest; added
  `transcribePodcastWritesTranscriptAlternative` — AC.15 — proves the
  Transcribe trigger fetches + writes a transcript HEAD on an
  un-transcribed podcast source; added
  `transcribeNonPodcastSourceThrowsNotRefreshable` — defensive guard for
  callers that bypass the View-level predicate; added
  `reTranscribeAppendsCoexistingAlternative` — `transcribePodcast`
  always appends, never clobbers; v1 and v2 coexist with different ids),
  `Tests/WikiFSTests/SourceRefreshTests.swift` (rewrote
  `podcastRefreshAppendsDerivedMarkdown` — v1 transcript now seeded via
  `transcribePodcast(sourceID:)`, not via `addURL`; then `refreshSource`
  appends v2 — same lifecycle: ingest → transcribe → at some later point
  the user clicks Refresh for a fresh transcript).
- **Docs (master index):** `PLAN.md` (the `extraction-framework.md` row
  now notes PR4 landed — byteless-only ingest + the new
  `transcribePodcast(sourceID:)` direct-network trigger + the
  SourceDetailView Transcribe button gated on the helper-binary runtime
  check).

**Key design decisions:**
1. **Ingest is byteless-only — NO transcript, NO synthetic markdown
   placeholder.** Pre-PR4 the podcast ingest path called
   `ApplePodcastMaterializer.materialize()` (which fetched + parsed the
   transcript) and stored it as a `.transcript`-origin processed-markdown
   HEAD. Post-PR4 the ingest path builds the byteless-source provenance
   directly (agentName = `apple-podcast`, plan/externalRef = the pasted
   page URL, externalIdentity = the numeric episode ID, activityKind =
   `fetch`) and calls `store.addBytelessSource` — NO fetcher consulted at
   ingest. The `podcastFetcher` parameter stays on the `addURL` signature
   for back-compat with the existing tests, but it's intentionally an
   ingest-time no-op now: the call site document the new contract
   ("the fetcher is consulted on `transcribePodcast(sourceID:)`, NOT on
   `addURL`"). The reader shows the embed player (the source has an
   `embedTarget`); the user surfaces a transcript via the Transcribe
   button.
2. **`transcribePodcast(sourceID:)` is a separate code path — NOT through
   the queue engine.** The queue reads `store.sourceBytes(id:)` and calls
   `convert(pdfData:)` for PDF extraction (`ExtractionResolution.pdfData`
   / `convert(pdfData:)` / `seedPdfMarkdown`). A byteless podcast source
   has empty `sourceBytes`, so the queue is structurally unable to feed
   the pipeline. PR4 follows PR2's posture (inline, NOT queue) with a
   different fetch protocol — the new method reconstructs the episode URL
   from `origin.plan`, re-injects `PodcastTranscriptFetching` (default
   `ApplePodcastTranscriptService.bundled()` — mirrors `refreshSource`'s
   injection point), calls `ApplePodcastMaterializer.materialize()`, and
   writes via `appendProcessedMarkdown(origin: .transcript, technique:
   "apple-ttml")`. `appendProcessedMarkdown` always appends — first call
   is HEAD, subsequent calls (re-transcribe) append coexisting
   alternatives. Mirrors the HTML `extractHtml(for:backend:)` lifecycle
   in PR2 exactly.
3. **Disabled when the helper is unavailable.** The View-level predicate
   `isTranscribable` is a one-line delegation to the existing
   `store.isSourceRefreshable(for:)` (which already encapsulates
   `provider.supportsRefresh` baseline + `ApplePodcastTranscriptService.bundled()
   != nil` runtime guard for `.applePodcast`). Outside `#if
   PODCAST_TRANSCRIPTS`, every podcast symbol is gated — the predicate
   returns `false`, the button doesn't render, the menu doesn't show the
   Re-transcribe branch. Reused the predicate; runtime check lives in
   one place (AC.16).
4. **`podcastBackend` injection mirrors `htmlBackend`.** New
   `@ObservationIgnored public var podcastBackend: PodcastTranscriptionBackend?`
   on `WikiStoreModel` + `podcastBackendResolver: @MainActor () ->
   PodcastTranscriptionBackend?` on `WikiSession` + `SessionManager` with
   `{ nil }` defaults for headless/daemon/test callers. `WikiFSApp` wires
   the resolver from `ExtractionConfig.load(from: directory).podcastBackend`
   (PR1 added the config field + Settings picker). When `podcastBackend ==
   nil`, the View-level `runTranscription` falls back to `.appleTranscript`
   directly (only backend today). Also fixed a PR2 plumbing gap in
   flight — the `htmlBackendResolver` is now actually passed through
   `SessionManager.session(for:)` to `WikiSession.init` (the PR2 code
   wired the resolver onto SessionManager but the call site never threaded
   it through, so `model.htmlBackend` was always `nil` in production; the
   tests passed because they injected `htmlBackend` directly on the model).
5. **No schema migration.** Pre-PR4 podcast sources already have a
   transcript HEAD row stamped with `origin: .transcript` and
   `technique: nil` (the old `addBytelessSource` +
   `appendProcessedMarkdown(technique: nil)` path). PR4 leaves those rows
   in place — existing sources keep their pre-fetched transcript. Only
   NEW ingests change (the byteless-embed + no-transcript invariant).

**Verification:** `make version prompts && swift build` (clean); full
`swift test` suite — **3,392 tests pass** in 283 suites (~24s). Covers
AC.14 (`episodeURLStoresBytelessEmbedWithoutTranscript`), AC.15
(`transcribePodcastWritesTranscriptAlternative`), AC.16
(`transcribePodcastThrowsSignatureUnavailableWithoutHelper`). The
existing PdfExtractionServiceTests / ApplePodcastTranscriptServiceTests /
ApplePodcastLiveTests / PodcastEpisodeURLTests / TTMLTranscriptTests
suites are unchanged — the lower-level service pipeline (token → AMP →
TTML → parse) is untouched.

## Verification

Historical verification remains in the progress record above.
