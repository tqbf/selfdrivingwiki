# Plan: Generalize Podcast Transcription to Any RSS Feed

> **Status:** Implementation in progress.
> **Scope:** Tag-first only (`<podcast:transcript>` RSS tags, Podcasting 2.0
> standard). Graceful failure when a podcast publishes no transcript tag.
> **Out of scope:** Whisper/speech-to-text (separate future follow-up).
> **Depends on:** PR #824 (merged into main) — its `RSSPodcastTranscriptService`
> + `TranscriptSubprocess` are the foundation this plan generalizes.

## 1. Problem Statement

PR #824 added an RSS `<podcast:transcript>` transcript fallback, but it was
**Apple-locked**: it only accepts Apple Podcasts episode URLs. The
`podcast-transcript` Python script (#812) requires an Apple Podcasts URL,
performs an iTunes Lookup API hop to resolve the RSS feed URL, and only then
parses the standard `<podcast:transcript>` tag. Everything *after* the feed URL
(RSS parsing, transcript-tag extraction, VTT/SRT/HTML/plain parsing) is already
podcast-standard and provider-agnostic.

The goal: let a user paste **any podcast RSS feed URL** and get a transcript
when the feed publishes `<podcast:transcript>` tags — while **keeping** the
existing Apple Podcasts path (both the FairPlay TTML pipeline *and* the
RSS-fallback via iTunes Lookup).

## 2. Decision 1 — Provider Model

**Add a new `.podcast` (generic RSS) case.** Do not overload `.applePodcast`.

| Aspect | `.applePodcast` | `.podcast` (new) |
|--------|-----------------|------------------|
| Input | Apple episode URL | Raw RSS feed URL |
| Feed resolution | iTunes Lookup API | Direct (the URL *is* the feed) |
| Transcript pipeline | FairPlay TTML **or** RSS fallback | RSS `<podcast:transcript>` only |
| Signing helper needed | Yes (FairPlay) | No |
| `#if PODCAST_TRANSCRIPTS` | Yes (App Store build excludes it) | **No** — works on every build (needs only `uv`) |

New rawValue: `"podcast"`. Byte-additive — no DB migration.

Switch sites that need a new arm (compiler-enforced exhaustive sites will fail
to build if missed):
- `displayLabel` / `systemImage` / `helpVerb` / `supportsRefresh` / `supportsTranscription` (SourceProvider.swift)
- `materialize(origin:)` (SourceRefreshService.swift)
- `isSourceRefreshable` (WikiStoreModel.swift)
- `transcribe(sourceID:)` dispatch (WikiStoreModel.swift, both `#if`/`#else`)
- `SourceDetailView.isTranscribable` (SourceDetailView.swift)
- `providerOriginTag(_:)` (SourceDetailView.swift) — [H1]
- `MediaTitleFetcher.oEmbedURL` (MediaTitleFetcher.swift) — non-exhaustive, manual verify

## 3. Decision 2 — Intake

Accept a **direct RSS feed URL** via a dedicated `addPodcastFeedURL(_:)` entry
point on `WikiStoreModel` (M3 — explicit affordance, not URL-sniffing, to avoid
the ambiguity problem of feed-vs-webpage). Single-item feeds auto-resolve;
multi-item feeds pick the latest by `<pubDate>`.

A new always-compiled recognizer `RSSFeedEpisodeURL` validates the feed URL.

## 4. Decision 3 — Python Script Generalization (§4 + H4)

Add a URL-shape branch in `fetch_transcript`. Keep the Apple path unchanged.

- `_is_apple_podcasts_url(url)` helper.
- `fetch_transcript` branches: Apple path unchanged; RSS path skips `get_feed_url`.
- `find_episode_in_feed(feed_url, episode_id: str | None)` — **explicit early
  branch** as the first statement when `episode_id is None`: return the most
  recent `<item>` by `<pubDate>`, fallback document order. The existing
  GUID/link/itunes:episode matching stays for the Apple path. (H4: this is a
  real contract change, not a simple branch — the current signature is
  non-optional and does substring matching that would `TypeError` on `None`.)
- `main()` / `build_parser()` — update help text.
- `ScriptOutput` JSON — `show_id`/`episode_id` emitted as `null`/omitted on the RSS path.

## 5. Decision 4 — Swift Service Wiring

### 5.1 RSSPodcastTranscriptService (generalize + de-guard)

Rename `episodeURL` → `sourceURL`. Add `transcript(forFeedURL:)` — a feed-oriented
entry that never touches `EpisodeRef` (H3). Move the service out of
`#if PODCAST_TRANSCRIPTS` (it has no FairPlay dependency).

### 5.2 transcribeRSSPodcast helper (H2)

Outside `#if PODCAST_TRANSCRIPTS`, mirrors `transcribeYouTube`:
- Accepts an injected `rssPodcastFetcher` so tests can fake it.
- Returns `nil` + logs on failure (matches sibling error discipline, not throw).
- Calls `transcript(forFeedURL:)`.

### 5.3 Dispatch arm

In both `#if`/`#else` `transcribe` switch blocks:
```swift
case .podcast:
    return try await transcribeRSSPodcast(sourceID:sourceID, origin:origin, fetcher: rssPodcastFetcher)
```

### 5.4 Intake (M3)

New `addPodcastFeedURL(_:)` entry point that bypasses the generic website fetch.
Creates a byteless `.podcast` source; no transcript at ingest (Transcribe triggers it).

## 6. De-guarding (C1 — critical)

Create `Sources/WikiFSCore/Integrations/PodcastTranscriptTypes.swift` (always
compiled, no `#if` guard) and move into it:
- `PodcastTranscript` (struct)
- `PodcastTranscriptFetching` (protocol)
- `PodcastTranscriptError` (enum — extract from TTMLTranscript.swift)
- `RSSPodcastTranscriptService` (move out of ApplePodcastTranscriptService.swift)
- `PodcastEpisodeURL.EpisodeRef` (move out of the guard; keep `parse`/`displayTitle` gated)

Only FairPlay-specific code stays gated: `ApplePodcastTranscriptService`,
`ApplePodcastAMP`, `TTMLTranscript` parse logic, `HelperPodcastTokenProvider`.

The App Store build (`WIKIFS_APP_STORE=1`) MUST compile — this is the critical gate.

## 7. Acceptance Criteria (summary)

- AC.1 Provider enum: `.podcast` round-trips; properties set; 6 compiler-enforced switch sites + 2 manually-verified.
- AC.2 Python script accepts RSS feed URLs; Apple path unchanged; `find_episode_in_feed(url, None)` returns latest/only.
- AC.3 Generic `.podcast` intake creates byteless source; no transcript at ingest.
- AC.4 Transcribe dispatch reaches RSS path; works on `WIKIFS_APP_STORE=1`; technique `rss-podcast-transcript`.
- AC.5 Graceful failure (no transcript tag) → `.noTranscriptAvailable`.
- AC.6 Apple path unchanged (regression).
- AC.7 UI gating: `isTranscribable` true for `.podcast` on every build; Transcribe button renders; no media tab.

## 8. Section 11 Corrections (applied)

C1 (critical): de-guarding chain is 5 symbols wide — see §6.
H1: `providerOriginTag` is an exhaustive switch — add `.podcast` to the URL arm.
H2: `transcribeRSSPodcast` accepts injected fetcher; nil+log on failure.
H3: reject synthetic EpisodeRef; add `transcript(forFeedURL:)`.
H4: `find_episode_in_feed` is a real contract change — add pubDate logic.
M1: new tests UNGUARDED.
M2: `ExternalEmbed` not a switch site — no change.
M3: intake is a concrete `addPodcastFeedURL` entry point.
M4: rebase moot (PR #824 already merged).
L1: AC.1 enumerates compiler-enforced vs manual sites.
L2: rename-regression test.
