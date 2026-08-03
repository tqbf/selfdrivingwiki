---
timestamp: 2026-07-22T094742Z
title: "feat: generalize transcript pipeline for podcast + YouTube (PR5 of #799)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: generalize transcript pipeline for podcast + YouTube (PR5 of #799)

## Progress


**Goal of #799:** bring HTML + Podcast extraction to parity with PDF — no
auto-extraction at ingest, user chooses backend and triggers extraction.
PR1 (merged #802) shipped the typed backend enums + Settings pickers
(scaffolding only). PR2 (merged #804) added the Extract button + Re-extract
menu for HTML sources via the inline extraction path. PR3 (merged #806)
removed auto-extraction at ingest so the Extract button is the canonical
HTML path. PR4 (merged #807) shipped the podcast framework — byteless-only
ingest, the `transcribePodcast(sourceID:fetcher:)` direct-network trigger,
and the Transcribe button gated on the signing-helper runtime check.
PR5 (this) **generalizes the podcast on-demand transcript pipeline to
YouTube**: the YouTube path is aligned with the podcast PR4 contract —
byteless-only ingest (no auto-fetch at ingest), an on-demand Transcribe
button, and provider-dispatched re-transcribe via `transcribe(sourceID:)`.

**Files touched (PR5):**
- **New:** `plans/transcript-generalization.md` (this PR's design doc — the
  investigation output mapping the current podcast + YouTube paths and
  the unified byteless-transcript-pipeline design). Committed first per
  the issue directive ("First commit: copy this plan into
  plans/transcript-generalization.md in your worktree").
- **Edit (code):** `Sources/WikiFSTypes/SourceProvider.swift` (added the
  `supportsTranscription` baseline property — sister to
  `supportsRefresh`; `true` for `.applePodcast` + `.youtube`, `false`
  otherwise. Used by `SourceDetailView.isTranscribable` as the enum
  baseline for the View-level Transcribe-button gate; the podcast runtime
  guard still layers on top at the model layer via
  `store.isSourceRefreshable(for:)`'s `.applePodcast` arm),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift`
  (the `transcribePodcast(sourceID:fetcher:)` public entry point is
  renamed `transcribe(sourceID:podcastFetcher:youtubeFetcher:)` and now a
  provider-dispatch `switch origin.provider` — the old body moved to a
  private `transcribePodcast(sourceID:origin:fetcher:)` helper; added a
  private `transcribeYouTube(sourceID:origin:fetcher:)` helper —
  reconstructs the 11-char video ID from `origin.externalIdentity` (the
  canonical ID `MediaEmbedURL.youtube` stores at ingest), falls back to
  re-parsing `origin.plan` for legacy rows, calls
  `YouTubeTranscriptService.transcript(forVideoID:)`, writes via
  `appendProcessedMarkdown(origin: .transcript, technique:
  "youtube-captions")`; paths on a phase-out build (`#else` of
  `PODCAST_TRANSCRIPTS`) keep the `.applePodcast` arm throwing
  `.notRefreshable`; added the `youtubeCaptionsTechnique` constant +
  deleted `youtubeEmbedAndTranscriptOutcome` — YouTube now routes
  uniformly through `bytelessMediaOutcome` for byteless-only ingest with
  no transcript fetch; the `youtubeFetcher` parameter stays on `addURL`
  as a back-compat no-op (mirrors `podcastFetcher`)),
  `Sources/WikiFS/Sources/SourceDetailView.swift` (added `isYouTubeEmbed`
  predicate; widened `isTranscribable` to dispatch on
  `provider.supportsTranscription` (covers `.applePodcast` + `.youtube`)
  + `store.isSourceRefreshable(for:)` for the podcast runtime guard
  (YouTube needs no signing helper — always-available branch); the
  Transcribe button, needsTranscription, and hasExtractionChip all key
  off the widened predicate so a YouTube source with no transcript now
  shows the Transcribe button; the "Re-extract with" menu gets a new
  YouTube branch (`else if isYouTubeEmbed`) listing a single "YouTube
  captions" entry that calls the parameterless `runTranscription()`
  (no `YouTubeTranscriptionBackend` enum plumbed per the plan — revisit
  when #584's Python-subprocess backend lands); `runTranscription` and
  `runTranscription(with:)` repoint from `transcribePodcast(sourceID:)`
  to `transcribe(sourceID:)`; the Transcribe button's help text is now
  provider-aware ("Fetch this video's transcript via YouTube captions"
  vs "Fetch this episode's transcript via Apple Podcasts"); the
  `runTranscription` catch clauses add `YouTubeTranscriptError.noCaptions`
  + `.playerResponseNotFound` so the row surfaces a useful message for
  YouTube failures).
- **Edit (tests):** `Tests/WikiFSTests/PodcastIngestRoutingTests.swift`
  + `SourceRefreshTests.swift` (repointed every
  `transcribePodcast(sourceID:fetcher:)` call to
  `transcribe(sourceID:podcastFetcher:)` — same fake-fetcher injection
  pattern, just routed through the new public dispatch entry point;
  behavior unchanged: byteless-only ingest, append-on-transcribe),
  `Tests/WikiFSTests/BytelessEmbedIntegrationTests.swift` (rewrote
  `youtubeURLWithTranscriptCreatesEmbedAndMarkdown` — YouTube ingest is
  now byteless-only: outcome.kind == .videoEmbed (NOT .videoTranscript),
  the synthetic metadata-only markdown page (technique
  `byteless-oembed-synthetic`) is the initial HEAD, then
  `transcribe(sourceID:)` writes a `youtube-captions` transcript version
  as the new HEAD; rewrote `youtubeURLWithNoCaptionsFallsBackToSyntheticMarkdown`
  — same byteless-only ingest contract; the no-captions case is now
  surfaced via `transcribe(sourceID:)` throwing
  `YouTubeTranscriptError.noCaptions`, not swallowed at ingest),
  `Tests/WikiFSTests/SourceProviderTests.swift` (added
  `supportsTranscriptionBaseline` + `supportsTranscriptionVsRefreshDivergence`
  tests pinning the enum property's mapping + the podcast/website/youtube
  divergence pattern),
  **new** `Tests/WikiFSTests/YouTubeTranscribeTests.swift` (5 tests:
  `transcribeWritesTranscriptHead` — AC.5 — proves the dispatch entry
  point routes `.youtube` → `transcribeYouTube`, fetches via the injected
  fetcher with the video ID reconstructed from `origin.externalIdentity`,
  writes a `youtube-captions` HEAD; `reTranscribeAppendsCoexistingAlternative`
  — AC.6 — `transcribe(sourceID:)` always appends, never clobbers; v1 and
  v2 coexist with different ids alongside the synthetic page; the
  defensive guards `transcribeNonMediaSourceThrowsNotRefreshable` —
  AC.7 — local-file throws `.notRefreshable`;
  `transcribeYouTubeWithMissingVideoIDThrowsMissingPlan` — AC.7b —
  source with no `externalIdentity` + unparsable plan throws
  `.missingPlan`; `transcribeYouTubeWithMissingFetcherThrowsNotRefreshable`
  — AC.7c — explicit `youtubeFetcher: nil` throws `.notRefreshable("youtube")`,
  since production always constructs the default).
- **Docs (master index):** `PLAN.md` (the `extraction-framework.md` row
  now notes PR5 landed — the unified `transcribe(sourceID:)` dispatch +
  YouTube on-demand transcription + deleted `youtubeEmbedAndTranscriptOutcome`;
  added a new row for `plans/transcript-generalization.md` linking to this
  PR's investigation-output design doc).

**Key design decisions:**
1. **Generalize at the dispatch seam — keep per-provider protocols.** The
   brief asked "is the input always a URL?" — answer: **no**. Podcast
   needs a typed `EpisodeRef` (parsed from the page URL); YouTube needs a
   plain `String` video ID. Forcing a single `func transcript(for url:
   URL) async throws -> String` protocol would re-parse inside each
   conformer and lose the typed slug. PR5 keeps the two existing
   per-provider `*TranscriptFetching` protocols (they're already tested)
   + generalizes at the **model dispatch seam**: one public
   `transcribe(sourceID:podcastFetcher:youtubeFetcher:)` entry point with
   a `switch origin.provider` body that routes to private per-provider
   helpers.
2. **YouTube ingest aligned to the podcast PR4 contract — byteless-only,
   NO transcript fetch.** Pre-PR5 the YouTube path auto-fetched the
   transcript at ingest (best-effort, swallowed on failure), created the
   byteless embed source, then stored the transcript as the
   `.transcript`-origin HEAD (or fell back to a synthetic metadata page
   on failure — #646). Post-PR5 YouTube routes uniformly through the
   pre-existing `bytelessMediaOutcome` (the same path used by YouTube /
   Vimeo / Spotify / SoundCloud / remote-media for byteless-embed
   sources with NO transcript fetch): just the byteless embed source +
   the synthetic metadata page from oEmbed (`writeSyntheticBytelessMarkdown`
   with `bytelessMetadataTechnique`). The synthetic page is the initial
   HEAD, the embed player is the only Reader-tab content, and the
   Transcribe button is the sole affordance to surface a real transcript.
   The `youtubeFetcher` parameter stays on `addURL` as a back-compat
   no-op (mirrors `podcastFetcher` in PR4) — the fetcher seam lives on
   `transcribe(sourceID:youtubeFetcher:)`. PR5 **deletes
   `youtubeEmbedAndTranscriptOutcome`**: the YouTube short-circuit is gone
   from both `addURL` overloads (the `#if PODCAST_TRANSCRIPTS` arm and
   the `#else` arm); YouTube now falls through to `bytelessMediaOutcome`
   like every other byteless provider.
3. **YouTube needs no signing helper — always-available transcription.**
   The View-level `isTranscribable` predicate now dispatches on
   `provider.supportsTranscription` (the new enum baseline property —
   `true` for `.applePodcast` + `.youtube`); for `.applePodcast` it
   delegates to `store.isSourceRefreshable(for:)` for the helper-binary +
   build-compile runtime guard (PR4 posture); for `.youtube` it always
   returns `true` — YouTube's pure-Swift watch-page scrape has no signing
   dependency. The model's `transcribeYouTube` helper throws
   `.missingPlan` when `origin.externalIdentity` is missing (a
   data-integrity edge case for legacy rows — ingests always set it via
   `MediaEmbedURL.youtube`) and `.notRefreshable("youtube")` when
   `youtubeFetcher` is nil (production always constructs the default;
   the throw backstops a headless caller that injects nil).
4. **The fetch backend is NOT changed.** Robust YouTube caption fetching
   (#584 — the watch-page scrape is broken on many videos) is a
   **separate follow-up PR**: the recommendation is a Python
   `youtube-transcript-api` subprocess mirroring `pdf2md`'s layout
   (option A in the plan). PR5 fixes the PIPELINE SHAPE (on-demand,
   Transcribe button, retryable via re-transcribe), NOT the fetch
   backend. The existing `YouTubeTranscriptService` (the broken scrape)
   is the conformer; `transcribeYouTube` injects a default
   `YouTubeTranscriptService(fetcher: URLSessionFetcher())` when the
   caller doesn't pass one. The Transcribe button makes the fetch
   retryable: a broken video still fails until #584 lands, but the
   failure is now surfaced in the row alongside `refreshError` (via
   `transcribeError`) AND the user can retry without re-ingesting.
5. **Backend plumbing deferred for YouTube.** The podcast path has a
   `podcastBackend` resolver wired through `WikiSession` /
   `SessionManager` / `WikiFSApp` reading `ExtractionConfig.podcastBackend`
   — picked from `PodcastTranscriptionBackend.allCases` in the
   "Re-transcribe with" menu. The plan skips the equivalent for YouTube
   (only one backend today — captions scrape; revisit when #584's Python
   subprocess lands and a `YouTubeTranscriptionBackend` enum becomes
   meaningful). The Re-extract with menu's YouTube branch lists a single
   "YouTube captions" entry that calls the parameterless
   `runTranscription()`.
6. **The synthetic metadata page (#646) is preserved even after
   removing the YouTube ingest-time transcript fetch.** When PR5 moves
   YouTube ingestion to `bytelessMediaOutcome`, the byteless-only path
   still calls `writeSyntheticBytelessMarkdown` (the function is shared
   by every byteless provider — Vimeo / Spotify / SoundCloud /
   remote-media already use it). So a YouTube-ingested source still has
   readable content in the reader + File Provider `.md` sibling +
   Tantivy index for Semantic Search — just no transcript cues until the
   user clicks Transcribe. The synthetic page coexists in the
   alternative-history list alongside the transcript version(s) the
   Transcribe button writes.

**Acceptance criteria (all verified):**
1. Single dispatch entry point — `WikiStoreModel.transcribe(sourceID:)`
   exists and routes by `origin.provider`; no caller references
   `transcribePodcast` directly. ✓ (`YouTubeTranscribeTests.transcribeWritesTranscriptHead`
   routes `.youtube` → `transcribeYouTube`; `PodcastIngestRoutingTests`
   uses the new entry point for podcasts).
2. Podcast parity preserved — byteless ingest, Transcribe button,
   re-transcribe appends; all `PodcastIngestRoutingTests` pass after the
   rename. ✓ (Podcast tests pass after repointing).
3. YouTube ingest is byteless-only — `youtubeEmbedAndTranscriptOutcome`
   is deleted; YouTube routes through `bytelessMediaOutcome`; no
   transcript fetch at ingest; the synthetic metadata page is preserved.
   ✓ (`youtubeURLWithTranscriptCreatesEmbedAndMarkdown` +
   `youtubeURLWithNoCaptionsFallsBackToSyntheticMarkdown` rewritten).
4. Transcribe button appears for YouTube — `needsTranscription` true on a
   YouTube source with no transcript; provenance chip + "Re-transcribe
   with" menu appear once a transcript exists. ✓ (the Re-extract with
   menu's new `else if isYouTubeEmbed` branch).
5. YouTube transcription is on-demand — tapping Transcribe calls
   `transcribe(sourceID:)` → `transcribeYouTube`, which reads
   `origin.externalIdentity`, fetches via `YouTubeTranscriptService`, and
   writes via `appendProcessedMarkdown(origin: .transcript, technique:
   "youtube-captions")`. ✓
6. Re-transcribe appends, never clobbers — `reTranscribeAppendsCoexistingAlternative`
   for YouTube confirms v1 + v2 coexist with different ids. ✓
7. Non-media sources throw clearly — `transcribe` on a local-file /
   Zotero / website / Spotify / Vimeo source throws `.notRefreshable`
   via the `switch provider` default. ✓
8. Build + full suite green — `make version prompts && swift build` clean
   (74s + 24s); `swift test` passes all 3413 tests (was 3410 pre-PR5;
   +3 from the new YouTubeTranscribeTests file). ✓

---

## Verification

Historical verification remains in the progress record above.
