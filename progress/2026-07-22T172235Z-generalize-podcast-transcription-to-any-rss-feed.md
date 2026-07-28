---
timestamp: 2026-07-22T172235Z
title: "Generalize podcast transcription to any RSS feed"
branch: null
status: historical
timestamp_source: git-commit
---

# Generalize podcast transcription to any RSS feed

## Progress


**Goal:** Accept ANY podcast RSS feed URL (not just Apple Podcasts), keeping the
Apple path intact. Tag-first via `<podcast:transcript>`, graceful fail when no
tag. Builds on merged PR #824 (RSSPodcastTranscriptService + TranscriptSubprocess).

**Plan:** `plans/podcast-generalize.md`

**Changes:**
- **Python script** (`tools/podcast-transcript/podcast-transcript`):
  `_is_apple_podcasts_url` helper routes Apple vs direct-RSS; `fetch_transcript`
  branches (Apple path unchanged; RSS path skips iTunes Lookup);
  `find_episode_in_feed(episode_id=None)` returns most recent `<item>` by
  `<pubDate>` (explicit early branch with pubDate-aware selection). 9 new Python
  tests (55 total pass).
- **De-guarding (C1 — critical):** New always-compiled
  `PodcastTranscriptTypes.swift` moves `PodcastTranscript`,
  `PodcastTranscriptFetching`, `RSSFeedTranscriptFetching`, `PodcastTranscriptError`,
  `RSSPodcastTranscriptService` out of `#if PODCAST_TRANSCRIPTS`.
  `PodcastEpisodeURL` unguarded (EpisodeRef always available).
- **SourceProvider.podcast** (`"podcast"` rawValue): new case + all enum
  property arms (displayLabel/systemImage/helpVerb/supportsRefresh/supportsTranscription).
- **RSSPodcastTranscriptService** generalized: `init(sourceURL:)` (renamed) +
  `transcript(forFeedURL:)` (H3 — feed-oriented entry, no EpisodeRef) +
  `RSSFeedTranscriptFetching` protocol for test injection.
- **transcribeRSSPodcast** helper (outside `#if`, injected fetcher per H2):
  dispatch arm in both `#if`/`#else` transcribe blocks; technique
  `"rss-podcast-transcript"`.
- **RSSFeedEpisodeURL** recognizer (always compiled) + `addPodcastFeedURL(_:)`
  intake entry point (M3 — explicit affordance, bypasses generic website fetch).
- **All exhaustive switch sites updated:** SourceRefreshService.materialize,
  isSourceRefreshable, SourceDetailView.isTranscribable + providerOriginTag (H1),
  MediaTitleFetcher.oEmbedURL. materializePodcastFeed refresh path (always compiled).
- **Tests:** `RSSPodcastTranscriptionTests.swift` (22 tests, UNGUARDED per M1) +
  SourceProviderTests `.podcast` assertions.

**Verification:**
- `swift build` — compiles (PODCAST_TRANSCRIPTS on)
- `WIKIFS_APP_STORE=1 swift build` — compiles (critical C1 gate — generic .podcast
  path works when `#if PODCAST_TRANSCRIPTS` is off)
- `swift test` — 3478 tests, 4 pre-existing ACP/quota failures (unrelated)
- `uv run pytest tests/` — 55 pass
- Apple-path regression (#824 RSSPodcastTranscriptTests) — 11 pass

---

## Verification

Historical verification remains in the progress record above.
