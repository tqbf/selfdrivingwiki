# Transcript Pipeline Generalization Plan

> **Investigation output (read-only).** Maps the current podcast + YouTube
> transcript paths and designs a unified byteless-transcript pipeline that
> dispatches by provider. Scope: podcast (done, PR #807) + YouTube (broken,
> #584). Out of scope: Spotify / Vimeo / SoundCloud (future).

---

## 1. Current State

There are **two divergent transcript pipelines** today. The podcast one (PR #807)
is the "right" shape (transcribe-on-demand); the YouTube one is the "wrong" shape
(transcribe-at-ingest) and is also broken.

### 1a. Podcast path (PR #807, the good shape) — fully on-demand

**Ingest** (`WikiStoreModel.addURL`, the `#if PODCAST_TRANSCRIPTS` branch):
- A `podcasts.apple.com` episode URL is recognized by `PodcastEpisodeURL.parse`.
- Ingest creates a **byteless embed source** with NO transcript.
  `store.addBytelessSource(...)` with provenance:
  - `agentName` = `apple-podcast`
  - `plan` / `externalRef` = the pasted page URL
  - `externalIdentity` = the numeric episode ID (`i=` value)
  - `mimeType` = `audio/apple-podcast` (synthetic)
- The `podcastFetcher` param is an **intentional ingest-time no-op** (kept for
  back-compat / test injection). The fetcher is NOT consulted at ingest.
- Outcome `kind == .audioEmbed`, `byteSize == 0`.

**Transcribe trigger** (`WikiStoreModel.transcribePodcast(sourceID:fetcher:)`,
`#if PODCAST_TRANSCRIPTS`):
- Reads the source's `origin` via `sourceOrigin(for:)`.
- Guards `origin.provider == .applePodcast` (else throws `.notRefreshable`).
- **Reconstructs the episode URL** from `origin.plan` (the recorded page URL):
  `PodcastEpisodeURL.parse(planURLString)` recovers `EpisodeRef {id, slug}`.
- Re-injects `PodcastTranscriptFetching` (default `ApplePodcastTranscriptService.bundled()`).
- Calls `ApplePodcastMaterializer(episode:pageURL:fetcher:).materialize()`.
- Writes via `appendProcessedMarkdown(origin: .transcript, technique: "apple-ttml")`.
- Always appends (first call = HEAD; re-transcribe = coexisting alternative).
- Throws `PodcastTranscriptError.signatureUnavailable` when the helper is nil.

**Protocol** (`Sources/WikiFSCore/Integrations/ApplePodcastTranscriptService.swift`):
```swift
public protocol PodcastTranscriptFetching: Sendable {
    func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript
}
public struct PodcastTranscript: Equatable, Sendable {
    public let episodeID: String
    public let markdown: String
    public let filename: String
}
```

**Fetch mechanism** (`ApplePodcastTranscriptService`): signed bearer token
(`podcast-token-helper` subprocess dlopens the private `PodcastsFoundation`
framework → FairPlay-signed token) → AMP metadata endpoint → TTML download URL →
`TTMLTranscript.parse` → markdown. Token is refreshed once on AMP `40012`.

**UI gating** (`SourceDetailView`):
- `isPodcastEmbed` = `origin?.provider == .applePodcast`
- `isTranscribable` = `isPodcastEmbed && store.isSourceRefreshable(for:)` (the
  `isSourceRefreshable` predicate returns `false` for `.applePodcast` outside
  `#if PODCAST_TRANSCRIPTS` or when `ApplePodcastTranscriptService.bundled()` is nil)
- `needsTranscription` = `isTranscribable && !hasMarkdown` → renders the
  **Transcribe** button (`waveform` icon).
- `hasExtractionChip` widened to `(isExtractable || isTranscribable) && hasMarkdown`
  so the provenance chip + "Re-transcribe with" menu appear once a transcript exists.
- `runTranscription()` / `runTranscription(with:)` call `transcribePodcast`.
- The "Re-extract with" menu has a dedicated `else if isPodcastEmbed` branch
  listing `PodcastTranscriptionBackend.allCases`.

**Backend injection**: `WikiStoreModel.podcastBackend: PodcastTranscriptionBackend?`
mirrors `htmlBackend`, wired through `WikiSession.podcastBackendResolver` →
`SessionManager.podcastBackendResolver` → `WikiFSApp` reads
`ExtractionConfig.load(from:).podcastBackend`.

### 1b. YouTube path (broken, the bad shape) — auto-transcribes at ingest

**Ingest** (`WikiStoreModel.addURL` → `youtubeEmbedAndTranscriptOutcome`):
- A YouTube URL is recognized by `MediaEmbedURL.youtube(rawInput)` →
  `MediaEmbedMatch { agentName: "youtube", mimeType: "video/youtube",
  externalIdentity: <11-char videoID>, planURL: <pasted URL> }`.
- Creates a byteless embed source (`addBytelessSource`).
- Then **immediately attempts the transcript fetch at ingest** via
  `youtubeFetcher.transcript(forVideoID:)` (off-main `Task.detached`).
- On success writes via `appendProcessedMarkdown(origin: .transcript, technique:
  "youtube-captions")`; on failure (no captions, parse fail, network) logs and
  falls back to a metadata-only synthetic page (`bytelessMetadataTechnique`).
- The `youtubeFetcher` default is `YouTubeTranscriptService(fetcher:)`.

**Protocol** (`Sources/WikiFSCore/Integrations/YouTubeTranscriptService.swift`):
```swift
public protocol YouTubeTranscriptFetching: Sendable {
    func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript
}
public struct YouTubeTranscript: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let markdown: String
    public let filename: String
}
```

**Fetch mechanism** (`YouTubeTranscriptService`): a pure-Swift scrape —
1. GET `https://www.youtube.com/watch?v=<id>` (desktop User-Agent).
2. Extract `ytInitialPlayerResponse` JSON from inline `<script>` (brace-matching).
3. Read `captions.playerCaptionsTracklistRenderer.captionTracks[].baseUrl`.
4. Pick best track (manual English → English ASR → first).
5. Fetch caption content (prefer `&fmt=json3`, fall back to timedtext XML).
6. Parse via `TimedTextTranscript` → markdown.

**Why it's broken (#584):** the watch-page scrape is fragile. YouTube frequently
changes page structure, returns consent/redirect interstitials, rate-limits
server-side requests without proper headers, and some videos are
age/region-restricted. The `https://www.youtube.com/watch?v=GlYgs6v2YfU` test
case fails even though a transcript exists in YouTube's web UI. There is **no
Transcribe button for YouTube** — the only transcript path is the ingest-time
auto-fetch, so when it fails the source is stuck with a metadata-only page and
no retry affordance.

**Vimeo** (`VimeoTranscriptService`) is a stub that throws `.notImplemented`.

**Key asymmetry to fix:** podcast transcription moved to on-demand (ingest is
byteless-only, Transcribe button triggers the fetch). YouTube still auto-fetches
at ingest AND has no Transcribe button. Generalization aligns YouTube with the
podcast on-demand model.

---

## 2. Protocol Design

There is **no `TranscriptFetching` protocol today** — only the two parallel
protocols above. The two conformers diverge in two ways:

| Dimension | Podcast | YouTube |
|---|---|---|
| Input | `PodcastEpisodeURL.EpisodeRef` (id + slug) | `videoID: String` |
| Output | `PodcastTranscript` (episodeID, markdown, filename) | `YouTubeTranscript` (videoID, title, markdown, filename) |
| URL reconstruction | `origin.plan` → `PodcastEpisodeURL.parse` | `origin.externalIdentity` (the 11-char ID) |

### Decision: per-provider conformers + a model-level dispatch method

The input/output types genuinely differ per provider (podcast needs an
`EpisodeRef`; YouTube needs a video ID; the markdown header/filename conventions
differ). A single `func transcript(for url: URL) async throws -> String` protocol
would force a lossy lowest-common-denominator and re-parse the URL inside each
conformer. **Keep per-provider `*TranscriptFetching` protocols** (they already
exist and are tested), and instead generalize the **dispatch method** on the
model.

### Recommended shape: `transcribe(sourceID:)` dispatches on provider

Rename `transcribePodcast(sourceID:)` → `transcribe(sourceID:)` and make it a
provider switch:

```swift
@discardableResult
public func transcribe(
    sourceID: PageID
) async throws -> SourceMarkdownVersion? {
    guard let origin = sourceOrigin(for: sourceID),
          let provider = origin.provider else {
        throw SourceRefreshService.RefreshError.notRefreshable("unknown")
    }
    switch provider {
    case .applePodcast:
        return try await transcribePodcast(sourceID: sourceID, origin: origin)
    case .youtube:
        return try await transcribeYouTube(sourceID: sourceID, origin: origin)
    case .vimeo, .spotify, .soundcloud, .remoteMedia:
        throw SourceRefreshService.RefreshError.notRefreshable(origin.agentName)
    case .localFile, .website, .zotero, .markdownFolder, .legacyImport:
        throw SourceRefreshService.RefreshError.notRefreshable(origin.agentName)
    }
}
```

`transcribePodcast` and a new `transcribeYouTube` become **private** per-provider
helpers that take the already-fetched `origin` (avoids a second `sourceOrigin`
read) and each inject their own default fetcher. The public entry point is the
single `transcribe(sourceID:)`.

**Why NOT a unified `TranscriptFetching` protocol:** the question in the brief —
"is the input always a URL?" — answer is **no**. Podcast needs an `EpisodeRef`
(parsed from the page URL); YouTube needs a video ID. Forcing a `URL` input would
re-parse inside each conformer and lose the typed slug. Keep the existing
provider-specific protocols; unify at the dispatch seam (the model), not the
fetch seam. The dispatch mechanism is exactly `switch origin.provider` as the
brief anticipated.

---

## 3. URL Reconstruction per Provider

`SourceOrigin` carries `plan`, `externalRef`, `externalIdentity` (all optional
strings). Every byteless provider records different fields:

| Provider | `plan` | `externalIdentity` | How to reconstruct for transcript |
|---|---|---|---|
| `applePodcast` | `podcasts.apple.com/…?i=<id>` page URL | numeric episode ID | `PodcastEpisodeURL.parse(origin.plan)` → `EpisodeRef` |
| `youtube` | pasted watch/embed/shorts URL | **11-char video ID** | Use `origin.externalIdentity` directly as the video ID (it's already the canonical ID). The `plan` URL is a fallback if `externalIdentity` is missing. |
| `vimeo` | pasted vimeo.com URL | numeric video ID | `origin.externalIdentity` (future) |
| `spotify` | pasted open.spotify.com URL | `<type>/<id>` | (future — no public transcript API) |
| `soundcloud` | pasted track URL | full track URL | (future) |
| `remoteMedia` | media URL | media URL | N/A (no transcript) |

**Key simplification for YouTube:** unlike podcast (which must parse the page URL
back into an `EpisodeRef` because the AMP endpoint wants the numeric ID and the
filename wants the slug), YouTube's `externalIdentity` **is already the video
ID** (`MediaEmbedURL.youtube` stores the 11-char ID directly). So
`transcribeYouTube` reads `origin.externalIdentity` and passes it to
`YouTubeTranscriptService.transcript(forVideoID:)` — no URL reparsing needed.

```swift
private func transcribeYouTube(
    sourceID: PageID, origin: SourceOrigin
) async throws -> SourceMarkdownVersion? {
    // externalIdentity IS the 11-char video ID (MediaEmbedURL.youtube stores it
    // directly). Fall back to re-parsing plan if a legacy row lacks it.
    let videoID = origin.externalIdentity
        ?? MediaEmbedURL.youtube(origin.plan ?? "")?.externalIdentity
    guard let videoID else {
        throw SourceRefreshService.RefreshError.missingPlan
    }
    let fetcher = YouTubeTranscriptService(fetcher: URLSessionFetcher())
    let transcript = try await Task.detached(priority: .userInitiated) {
        try await fetcher.transcript(forVideoID: videoID)
    }.value
    do {
        return try store.appendProcessedMarkdown(
            sourceID: sourceID, content: transcript.markdown,
            origin: .transcript, note: nil, technique: "youtube-captions")
    } catch {
        DebugLog.store("transcribeYouTube appendProcessedMarkdown failed: \(error)")
        return nil
    }
}
```

---

## 4. YouTube Transcript Fetch Mechanism

Issue #584 documents that the pure-Swift `ytInitialPlayerResponse` scrape is
fragile. The issue proposes three options; investigation findings:

### Option A (RECOMMENDED by #584): Python subprocess, mirroring pdf2md

Create `tools/youtube-transcript/` (a `uv`-managed Python tool, same layout as
`tools/pdf2md/`). It shells out to a maintained library — either:
- **`youtube-transcript-api`** — lightweight, transcripts-only (preferred per #584), or
- **`yt-dlp --write-auto-sub --sub-format json3 --skip-download`** — heavier but
  more robust, also covers Vimeo.

`YouTubeTranscriptService` (or a renamed `YouTubeTranscriptService` adapter)
spawns it as a subprocess exactly like `PdfExtractionService` spawns `pdf2md`.
Output: markdown to stdout. This handles auto-generated captions, multiple
language tracks, age-restricted (with cookies), and region-locked videos.

**Why this fits the generalization:** it keeps `YouTubeTranscriptFetching` as the
Swift protocol seam (the subprocess adapter conforms to it). The model dispatch
is unchanged whether the backend is a Swift scrape or a Python subprocess — only
the concrete `YouTubeTranscriptService` implementation swaps.

### Option B: improve the Swift scrape (NOT recommended)
Fix the `extractPlayerResponse` brace-matching + add consent-page handling + a
proper desktop User-Agent + cookie jar. Doable but requires constant maintenance
against YouTube's page changes. The existing code already does this and it's
broken — doubling down on the same approach is fragile.

### Option C: `yt-dlp` only (subset of A)
Same as A but use `yt-dlp`'s `--write-auto-sub` instead of a dedicated
transcript library. Heavier dependency, broader coverage (Vimeo too).

### Recommendation for THIS generalization PR
**Decouple the two concerns:**
1. **Generalization (the pipeline shape)** — extract `transcribe(sourceID:)`
   dispatch, add the YouTube arm, move YouTube from ingest-auto-fetch to
   on-demand, gate the Transcribe button for YouTube. This is the architectural
   work and can land independently of the fetch backend.
2. **Robust fetch backend (#584)** — swap the Swift scrape for a Python
   subprocess. This is a **separate follow-up PR** because it adds a Python
   tool target + Package.swift plumbing + test fixtures.

For the generalization PR, keep the existing `YouTubeTranscriptService` (broken
scrape) as the conformer but route it through the new on-demand `transcribe`
path. The Transcribe button now exists for YouTube (so the user can retry); the
fetch still fails on broken videos, but that's #584's fix, not the
generalization's scope. **Document this explicitly in the PR description.**

---

## 5. Files to Change (Generalization PR)

### Extract the unified dispatch + align YouTube to on-demand

| File | Change |
|---|---|
| `Sources/WikiFSCore/Store/WikiStoreModel.swift` | (1) Rename `transcribePodcast(sourceID:fetcher:)` → `transcribe(sourceID:)` as the public entry point; make the old body a private `transcribePodcast(sourceID:origin:)` helper. (2) Add private `transcribeYouTube(sourceID:origin:)` helper. (3) **Remove the ingest-time transcript fetch** from `youtubeEmbedAndTranscriptOutcome` — make YouTube ingest byteless-only (mirror the podcast PR4 ingest: create the embed source, write the synthetic metadata page with `transcript: nil`, return `.videoEmbed`). Drop the `youtubeFetcher` param from `addURL` (or keep as a back-compat no-op like `podcastFetcher`). (4) The `youtubeFetcher` injection seam stays for the `transcribeYouTube` default. |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | (1) Generalize `isTranscribable` from `isPodcastEmbed && …` to cover YouTube: `(isPodcastEmbed \|\| isYouTubeEmbed) && …`. (2) Generalize `needsTranscription` likewise. (3) `hasExtractionChip` already keys on `isTranscribable` — no change once the predicate is widened. (4) The Transcribe button (`needsTranscription`) and `runTranscription()` / `runTranscription(with:)` already call the model — repoint `runTranscription` from `transcribePodcast(sourceID:)` to `transcribe(sourceID:)`. (5) The "Re-extract with" menu's `else if isPodcastEmbed` branch → `else if isTranscribable` (or a new `else if isYouTubeEmbed` arm listing a YouTube backend enum). (6) Update the error-message helpers: `SourceDetailView.swift:1026` has `case .youtube?: return "No Transcript Available"` — generalize or remove. |
| `Sources/WikiFSCore/Store/WikiStoreModel.swift` (`isSourceRefreshable`) | Decide whether the Transcribe gate for YouTube should reuse `isSourceRefreshable` (which returns `false` for `.youtube`) or use a separate `isTranscribable`-style predicate. **Recommendation:** YouTube transcription needs no signing helper, so it's always "available" — the gate is just `provider == .youtube` (and the source has a valid video ID). Add a `supportsTranscription` predicate on `SourceProvider` (parallel to `supportsRefresh`) returning `true` for `.applePodcast` + `.youtube`, and a `WikiStoreModel.isTranscribable(for:)` that layers the podcast runtime guard on top. |

### New enum + protocol alignment

| File | Change |
|---|---|
| `Sources/WikiFSTypes/SourceProvider.swift` | Add `var supportsTranscription: Bool` → `true` for `.applePodcast`, `.youtube`; `false` otherwise. (Optional: leave dispatch in the model's switch; an enum property is cleaner for the View predicate.) |
| `Sources/WikiFSCore/Integrations/YouTubeTranscriptService.swift` | No protocol change (`YouTubeTranscriptFetching` stays). If a `YouTubeTranscriptionBackend` enum is wanted for the "Re-transcribe with" menu parity with `PodcastTranscriptionBackend`, add it here (PR1-style scaffolding: single `.youtubeCaptions` case today). |

### Backend injection (optional for YouTube, since no signing helper)

YouTube needs no `podcastBackend`-style resolver (no config choice today). If a
`YouTubeTranscriptionBackend` enum is added, wire a resolver mirroring
`podcastBackendResolver` through `WikiSession` / `SessionManager` / `WikiFSApp`.
**Recommendation:** skip this for the generalization PR (only one backend);
revisit when the Python-subprocess backend lands (#584).

### Tests

| File | Change |
|---|---|
| `Tests/WikiFSTests/PodcastIngestRoutingTests.swift` | Rename `transcribePodcast(sourceID:)` call sites → `transcribe(sourceID:)`. The byteless-ingest assertions are unchanged. |
| `Tests/WikiFSTests/SourceRefreshTests.swift` | Update `podcastRefreshAppendsDerivedMarkdown` call site. |
| New `Tests/WikiFSTests/YouTubeTranscribeTests.swift` | (1) `transcribe(sourceID:)` on a YouTube source writes a transcript HEAD. (2) Re-transcribe appends a coexisting alternative. (3) `transcribe` on a non-media source throws `.notRefreshable`. (4) A YouTube source with no `externalIdentity` + unparsable plan throws `.missingPlan`. |
| `Tests/WikiFSTests/` (ingest tests for YouTube) | Update to assert YouTube ingest is now byteless-only (no transcript at ingest), mirroring `episodeURLStoresBytelessEmbedWithoutTranscript`. |

### Docs

| File | Change |
|---|---|
| `PLAN.md` | Add a row for the transcript-generalization plan. |
| `PROGRESS.md` | Entry for the generalization PR. |
| `plans/transcript-generalization.md` | Move this scratch doc into `plans/` (the implementation design). |

---

## 6. Acceptance Criteria

1. **Single dispatch entry point.** `WikiStoreModel.transcribe(sourceID:)` exists
   and routes by `origin.provider` to per-provider helpers. No caller references
   `transcribePodcast` directly.
2. **Podcast parity preserved.** The podcast path behaves identically (byteless
   ingest, Transcribe button, re-transcribe appends). All existing
   `PodcastIngestRoutingTests` pass after the rename.
3. **YouTube ingest is byteless-only.** Ingesting a YouTube URL creates the embed
   source + synthetic metadata page with NO transcript fetch (mirrors podcast
   PR4). `youtubeEmbedAndTranscriptOutcome` no longer calls the fetcher.
4. **Transcribe button appears for YouTube.** A YouTube source with no
   transcript shows the Transcribe button (`needsTranscription` true). A YouTube
   source WITH a transcript shows the provenance chip + "Re-transcribe with" menu.
5. **YouTube transcription is on-demand.** Tapping Transcribe calls
   `transcribe(sourceID:)` → `transcribeYouTube`, which reconstructs the video ID
   from `origin.externalIdentity`, fetches via `YouTubeTranscriptService`, and
   writes via `appendProcessedMarkdown(origin: .transcript, technique:
   "youtube-captions")`.
6. **Re-transcribe appends, never clobbers.** A second Transcribe on the same
   source appends a coexisting alternative (test:
   `reTranscribeAppendsCoexistingAlternative` equivalent for YouTube).
7. **Non-media sources throw clearly.** `transcribe` on a local-file / Zotero /
   website / Spotify source throws `.notRefreshable`.
8. **Build + full suite green.** `make version prompts && swift build` clean;
   `swift test` passes (3,392+ tests).

---

## 7. Out of Scope

- **Spotify / SoundCloud** — no public transcript API; future.
- **Vimeo** — `VimeoTranscriptService` is a `.notImplemented` stub; needs a
  Keychain OAuth token (#564 Phase 4 follow-up). The dispatch switch has a
  `.vimeo` arm that throws `.notRefreshable` until then.
- **Robust YouTube fetch backend (#584)** — the Python `youtube-transcript`
  subprocess tool is a **separate follow-up PR**. The generalization PR keeps the
  existing Swift scrape (broken on some videos) but makes it retryable via the
  Transcribe button. Document that a broken video still fails until #584 lands.
- **Generalizing the PDF-coupled queue engine** to handle byteless sources —
  explicitly deferred per the extraction-framework plan's "Out of scope". The
  `transcribe` path stays inline (NOT through the queue), matching PR2/PR4's
  posture.
- **`YouTubeTranscriptionBackend` resolver plumbing** — skip until a second
  backend (the Python tool) lands.

---

## Appendix: Data Model Reference

**`SourceProvider` enum** (`Sources/WikiFSTypes/SourceProvider.swift`):
`localFile`, `website`, `zotero`, `markdownFolder`, `applePodcast`, `youtube`,
`vimeo`, `spotify`, `soundcloud`, `remoteMedia`, `legacyImport`. `rawValue` is
the `agents.name` string. `supportsRefresh` = `true` only for `website` +
`applePodcast`.

**Byteless providers** (no content bytes; `byteSize == 0`; render an embed):
`applePodcast`, `youtube`, `vimeo`, `spotify`, `soundcloud`, `remoteMedia`.

**`SourceOrigin`** (`Sources/WikiFSCore/Sources/SourceMaterializer.swift:134`):
the joined active-version → activity → agent row. Fields: `agentName`,
`activityKind`, `plan`, `externalRef`, `externalIdentity`. `.provider` derives
the typed `SourceProvider` from `agentName`.

**`ExternalEmbed.target(for:)`** (`Sources/WikiFSCore/Integrations/ExternalEmbed.swift`):
the pure dispatch table from a `SourceEmbedDescriptor` (mime + externalIdentity +
agentName + planURL) to an `EmbedTarget` (iframe/audio/video URL). Order:
provider synthetic mimes → Apple Podcasts agentName → direct-remote real mimes.
YouTube builds `youtube-nocookie.com/embed/<id>` from `externalIdentity`.

**`MediaEmbedURL`** (`Sources/WikiFSCore/Integrations/MediaEmbedURL.swift`): pure
URL recognizers → `MediaEmbedMatch { agentName, mimeType, externalIdentity,
filename, planURL, activityKind }`. YouTube stores `externalIdentity = <videoID>`.

**`addBytelessSource`** (`WikiStore` protocol, `WikiStoreModel:2272`): writes the
source + provenance (agent/activity/plan/externalRef/externalIdentity) with no
content bytes.
