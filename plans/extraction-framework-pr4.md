# Plan: Extraction Framework PR4 — Podcast Framework (#799)

**Parent plan:** [`plans/extraction-framework.md`](extraction-framework.md) (the
4-PR staged plan to bring HTML + Podcast extraction to parity with PDF —
no auto-extraction at ingest, user chooses backend and triggers extraction).
This doc is the deep dive for PR4 only — the podcast framework, the last of
the four PRs.

PR1 (merged `69fe6e9`, #802) shipped the typed enums
(`HtmlExtractionBackend`, `PodcastTranscriptionBackend`) + the
`ExtractionConfig.htmlBackend` / `.podcastBackend` optional fields + the
Settings pickers (scaffolding only, no behavior change). PR2 (merged
`b3f4a47`, #804) added the Extract button + Re-extract menu for HTML sources
via the existing inline extraction path (`WikiStoreModel.extractHtml(for:backend:)`).
PR3 (merged `3f02d9f`, #806) removed HTML auto-extraction at ingest
(`FormatMaterializer.dispatch` skips the HTML→Markdown sidecar; the three
`enrichWithDefuddle` callers are gone; `WebsiteSnapshotExtractor` only sets the
page sidecar when the snapshot has images — the AC.12 scope boundary). PR4
(this) is the podcast framework — the architectural outlier, the only
content-type whose extraction is a network fetch rather than a bytes→markdown
transform.

## Goal

Stop auto-transcribing Apple Podcasts episodes at ingest. After PR4 a fresh
podcast URL creates a **byteless embed source** (like YouTube/Vimeo/Spotify/
SoundCloud/remote-media) with **no processed-markdown version** — the user
clicks **Transcribe** in `SourceDetailView` to trigger the network fetch
(signed bearer token → AMP metadata → TTML download → parse → markdown)
explicitly. Re-transcribe is offered through the provenance chip's
"Re-transcribe with" menu, mirroring the PDF/HTML lifecycle.

## Architectural difference from HTML/PDF (plan-reviewer finding)

Podcast transcription is **fundamentally different** from PDF/HTML extraction
in three ways that the parent plan flagged:

- **Not bytes→markdown**: the transcript comes from Apple's network API
  (`ApplePodcastTranscriptService.transcript(for:)` → AMP metadata → TTML
  download → parse). There are **no stored bytes** to convert; the "backend"
  picks the network pipeline, not a converter. A byteless podcast source has
  empty `sourceContent`.
- **Queue engine incompatibility**: the queue reads `store.sourceBytes(id:)`
  and calls `convert(pdfData:)` for PDF extraction (`ExtractionResolution.pdfData`
  / `convert(pdfData:)` / `seedPdfMarkdown`). For a byteless podcast source,
  `sourceBytes` returns empty and the queue is structurally unable to feed
  the pipeline. The podcast trigger must be a **separate code path**, NOT
  through the queue.
- **Behind `#if PODCAST_TRANSCRIPTS`**: the signing helper
  (`HelperPodcastTokenProvider`, shells out to `podcast-token-helper`) may not
  be present — particularly in App Store builds
  (`WIKIFS_APP_STORE=1`). The Transcribe button must be **disabled**  
  (not crash) when the helper is unavailable, mirroring how
  `WikiStoreModel.isSourceRefreshable(for:)` already gates the podcast
  arm of the existing Refresh button on
  `ApplePodcastTranscriptService.bundled() != nil`.
  
This is why the PR2 trigger for HTML (the inline `extractHtml(for:backend:)`
path) is the closest sibling, and why PR4 keeps the same architectural
posture (inline, NOT queue) with a different fetch protocol — rather than
extending the queue or the `MarkdownExtractor` protocol.

## Design summary

Three concrete edits:

1. **Ingest path**: `WikiStoreModel.addURL` podcast branch currently calls
   `ApplePodcastMaterializer.materialize()` (which calls
   `ApplePodcastTranscriptService.transcript(for:)`) and stores the transcript
   markdown as a `.extraction`-origin processed-markdown HEAD. After PR4 it
   ✋ STOPS calling the materializer — it builds the byteless-source
   provenance directly from the parsed episode URL (agentName =
   `apple-podcast`, plan/externalRef = the pasted page URL,
   externalIdentity = the numeric episode ID, activityKind = `fetch`) and
   calls `store.addBytelessSource`. **No transcript markdown**, **no
   synthetic byteless markdown page**. A fresh podcast source arrives with
   ZERO rows in `source_markdown_versions` — exactly mirroring the
   post-PR3 HTML invariant. The `podcastFetcher` parameter on `addURL`
   becomes a no-op at ingest (kept on the signature for back-compat — the
   existing tests still inject it and assert what happens; the new contract
   is "the fetcher is consulted on `transcribePodcast(sourceID:)`, NOT on
   `addURL`").

2. **Transcribe trigger**: new
   `WikiStoreModel.transcribePodcast(sourceID:)` method — a direct network
   operation, NOT through the queue.

   - Reads the source's provenance via `store.sourceOrigin(sourceID:)`
     (reconstructs the episode URL from `origin.plan`, NOT from
     `externalIdentity` — the plan URL is the canonical
     `podcasts.apple.com/...?i=<id>` page that the user pasted, and
     `PodcastEpisodeURL.parse(_:)` recovers the episode ID + slug from it;
     `externalIdentity` alone is the numeric ID, which isn't a clickable
     link for the Origin row). Mirrors the existing
     `SourceRefreshService.materializePodcast(origin:)` reconstruction.
   - Re-injects `PodcastTranscriptFetching` (default
     `ApplePodcastTranscriptService.bundled()`, mirroring `refreshSource`'s
     pattern; tests inject a fake). Throws
     `PodcastTranscriptError.signatureUnavailable` when the helper isn't
     present — so the View-level handler can surface the same error
     string the existing Refresh button does.
   - Calls `ApplePodcastMaterializer.materialize()` (which calls
     `fetcher.transcript(for:)`) — reusing the existing orchestrator end-to-end
     (token → AMP → TTML → parse → markdown).
   - Stores the transcript via `store.appendProcessedMarkdown(content:,
     origin: .transcript, note: nil, technique: "apple-ttml")`.
     `appendProcessedMarkdown` always appends (never clobbers): the first
     call creates the HEAD; subsequent calls (a re-transcribe) append
     coexisting alternatives. Re-transcribe is the SAME method; provenance
     is differentiated by the `technique` column + version ID.

3. **UI**: `SourceDetailView` shows a **Transcribe** button on a podcast
   source with no transcript markdown — visible alongside (`!`) the
   Extract button on PDFs and HTML. The provenance chip's existing
   `isExtractable, hasMarkdown, let head = headVersion` gate is widened
   to include podcast sources; the "Re-extract with" menu gains a podcast
   branch that lists `PodcastTranscriptionBackend.allCases` (currently
   just `.appleTranscript`; extensible to Whisper / Rev.ai / etc. in future
   PRs). The button is **disabled** when:

   - `#if !PODCAST_TRANSCRIPTS` (the helper binary's source isn't compiled
     in at all — every existing podcast symbol is `#if`-gated, so the
     button isn't even visible in that config), OR
   - `ApplePodcastTranscriptService.bundled()` returns `nil` at runtime
     (the helper binary isn't found beside the executable). The View-level
     predicate `isPodcastTranscribable` is a thin wrapper over the existing
     `store.isSourceRefreshable(for:)` (which already encapsulates the
     `provider.supportsRefresh` baseline + the `ApplePodcastTranscriptService.bundled()
     != nil` runtime guard for `.applePodcast`). The gate is reused, not
     duplicated; the runtime check lives in one place.

   The `WikiStoreModel.podcastBackend` injection point mirrors
   `htmlBackend` exactly: `@ObservationIgnored public var podcastBackend:
   PodcastTranscriptionBackend?`, resolved at app wiring time from
   `ExtractionConfig.podcastBackend` via the new
   `podcastBackendResolver: @MainActor () -> PodcastTranscriptionBackend?`
   factories on `WikiSession` + `SessionManager` (with `{ nil }` defaults
   for headless/daemon/test callers). `WikiFSApp` wires the resolver from
   the same `ExtractionConfig.load(from:)` site where it already wires
   `htmlBackend`. When `podcastBackend == nil`, the View-level
   `runTranscription` uses `.appleTranscript` directly (only one backend
   today).

## Concrete changes

### 1. `WikiStoreModel.addURL` podcast branch — byteless-only ingest

`Sources/WikiFSCore/Store/WikiStoreModel.swift` lines 2185-2231 currently:

```swift
if let episode = PodcastEpisodeURL.parse(rawInput) {
    guard let svc = podcastFetcher else {
        throw PodcastTranscriptError.signatureUnavailable(
            "Apple Podcasts transcripts need the signing helper, which isn't available in this build.")
    }
    let pageURL = URLFetchService.normalizeURL(rawInput)
        ?? URL(string: "https://podcasts.apple.com")!
    let provider = ApplePodcastMaterializer(episode: episode, pageURL: pageURL, fetcher: svc)
    let transcript = try await provider.materialize()
    // §11 byteless model ...
    guard let prov = transcript.provenance else { ... }
    let summary = try store.addBytelessSource(
        filename: transcript.filename, mimeType: transcript.mimeType,
        provenance: prov, role: .primary)
    let markdown = String(data: transcript.data, encoding: .utf8) ?? ""
    try store.appendProcessedMarkdown(
        sourceID: summary.id, content: markdown, origin: .transcript, note: nil, technique: nil)
    // Issue #621: resolve a human-readable display name from the episode slug
    let resolvedTitle = PodcastEpisodeURL.displayTitle(from: episode.slug)
        .map { WikiNameRules.sanitized($0) }
    if let title = resolvedTitle {
        do { try store.setSourceDisplayName(id: summary.id, displayName: title) } catch { ... }
    }
    openTab(.source(summary.id), title: resolvedTitle ?? summary.effectiveName)
    return URLFetchService.FetchOutcome(
        filename: transcript.filename,
        byteSize: transcript.data.count,
        kind: .podcastTranscript)
}
```

After PR4:

```swift
if let episode = PodcastEpisodeURL.parse(rawInput) {
    // Issue #799 PR4: stop auto-transcribing at ingest. The episode URL
    // creates a byteless embed source (like YouTube/Vimeo/Spotify/SoundCloud/
    // remote-media) with NO transcript. The user clicks "Transcribe" in
    // SourceDetailView to trigger the network fetch (signed bearer → AMP →
    // TTML → parse → markdown) explicitly. The `podcastFetcher` parameter
    // is intentionally NOT consulted here — it's re-injected on
    // transcribePodcast(sourceID:). Same provenance shape as before
    // (agentName = apple-podcast, plan/externalRef = pasted page URL,
    // externalIdentity = the numeric episode ID) so ExternalEmbed continues
    // to host-swap planURL → embed.podcasts.apple.com.
    let pageURL = URLFetchService.normalizeURL(rawInput)
        ?? URL(string: "https://podcasts.apple.com")!
    let summary = try store.addBytelessSource(
        filename: Self.podcastEmbedFilename(for: episode),
        mimeType: Self.podcastEmbedMIME,
        provenance: SourceProvenance(
            agentName: SourceProvider.applePodcast.rawValue,
            activityKind: "fetch",
            plan: pageURL.absoluteString,
            externalRef: pageURL.absoluteString,
            externalIdentity: episode.id),
        role: .primary)
    // Issue #621: the source's display name is the un-slugified episode
    // title (still resolved from the URL slug — same offline helper as
    // before). Unchanged from pre-PR4; it has nothing to do with whether
    // a transcript was fetched.
    let resolvedTitle = PodcastEpisodeURL.displayTitle(from: episode.slug)
        .map { WikiNameRules.sanitized($0) }
    if let title = resolvedTitle {
        do { try store.setSourceDisplayName(id: summary.id, displayName: title) } catch {
            DebugLog.store("apple-podcast slug title setSourceDisplayName failed (source=\(summary.id.rawValue)): \(error)")
        }
    }
    // No transcript markdown is written — the source's
    // source_markdown_versions stays empty until the user transcribes.
    // Mirrors the post-PR3 HTML invariant and the YouTube-without-captions
    // path BEFORE the #646 synthetic-page work. The Reader falls through
    // to the embed-player view (no "No Processed Markdown" stub) because
    // the source has an `embedTarget`.
    openTab(.source(summary.id), title: resolvedTitle ?? summary.effectiveName)
    return URLFetchService.FetchOutcome(
        filename: summary.filename,
        byteSize: 0,
        kind: .audioEmbed)
}
```

Two private constants support the new path:

```swift
/// The synthetic MIME for a byteless Apple Podcasts episode source. Keyed
/// on the provider's `agentName` in `ExternalEmbed.target(for:)` (NOT the
/// MIME), so this is a near-cosmetic label — `audio/apple-podcast` is the
/// convention chosen because SyntheticProvider view-source-renderers and
/// `MediaEmbedMatch`-shaped providers (youtube/vimeo/spotify/soundcloud)
/// use the matching `audio|video/<provider>` shape. Issue #799 PR4.
private static let podcastEmbedMIME = "audio/apple-podcast"

/// Build the byteless-source filename for an episode: `<slug>-<id>` when
/// the URL carried a slug, else `podcast-<id>`. Mirrors the YouTube/Vimeo
/// `youtube-<id>` / `vimeo-<id>` convention (issue #799 PR4). The
/// `-transcript.md` suffix is deliberately NOT used — that's reserved for
/// the transcript **markdown version**'s filename (written by the
/// Transcribe trigger through `ApplePodcastMaterializer.materialize()`,
/// not here).
private static func podcastEmbedFilename(for episode: PodcastEpisodeURL.EpisodeRef) -> String {
    let stem = episode.slug.map { "\($0)-\(episode.id)" } ?? "podcast-\(episode.id)"
    return FilenameEscaping.escapeTitle(stem)
}
```

`FetchOutcome.kind` changes from `.podcastTranscript` to `.audioEmbed` —
the source is now an embed (no transcript fetched), matching the Spotify/
SoundCloud audio-embed return value. Tests that asserted
`.podcastTranscript` are rewritten to assert `.audioEmbed` (one assertion
in `PodcastIngestRoutingTests`).

### 2. `WikiStoreModel.transcribePodcast(sourceID:)` — direct network trigger

`Sources/WikiFSCore/Store/WikiStoreModel.swift` — append beside
`extractHtml(for:backend:)` (mirroring its shape, dispatch, and provenance
discipline):

```swift
/// Podcast transcription trigger (issue #799 PR4). Inline — does NOT
/// route through the queue engine (the queue is PDF-coupled via
/// `ExtractionResolution.pdfData` / `convert(pdfData:)` /
/// `seedPdfMarkdown`; podcast transcription is a NETWORK FETCH with a
/// different input shape — there are no stored bytes to convert, the
/// "backend" picks the network pipeline). Generalizing the queue is a
/// deferred sub-project per the parent plan's "Out of scope" section.
///
/// Reconstructs the episode URL from `origin.plan` (the page URL recorded
/// at ingest — `PodcastEpisodeURL.parse(_:)` recovers the numeric
/// episode ID + the slug), re-injects `PodcastTranscriptFetching` (default
/// `ApplePodcastTranscriptService.bundled()` — mirrors `refreshSource`'s
/// injection point), calls `ApplePodcastMaterializer.materialize()` (which
/// runs the full token → AMP → TTML → parse → markdown pipeline off-main
/// in a detached `Task`), and writes the transcript markdown via
/// `appendProcessedMarkdown(origin: .transcript, technique: "apple-ttml")`.
///
/// Throws `PodcastTranscriptError.signatureUnavailable` when the helper
/// binary isn't present (mirroring the same throw at ingest pre-PR4 and
/// `SourceRefreshService.materializePodcast`'s shape). Throws
/// `SourceRefreshService.RefreshError.notRefreshable` when the source's
/// provenance isn't a podcast episode URL (a defensive guard — the
/// View-level predicate should prevent reaching this path on a non-
/// podcast source, but the model can't trust the predicate).
///
/// `appendProcessedMarkdown` always appends — the FIRST call creates the
/// HEAD; subsequent calls (re-transcribe) append coexisting alternatives
/// (no clobber). So the initial Transcribe and a later Re-transcribe
/// both flow through this method — provenance is differentiated by the
/// version id and (if needed) the technique column. Mirrors the HTML
/// `extractHtml(for:backend:)` lifecycle in PR2.
///
/// - Parameters:
///   - sourceID: the byteless podcast source to transcribe.
///   - fetcher: the `PodcastTranscriptFetching` to use; defaults to
///     `ApplePodcastTranscriptService.bundled()` (the bundled signing
///     helper). Tests inject a fake. `nil` on a build without the helper
///     → throws `.signatureUnavailable`.
/// - Returns: the new `SourceMarkdownVersion`, or nil on a store write
///   failure.
@discardableResult
public func transcribePodcast(
    sourceID: PageID,
    fetcher: (any PodcastTranscriptFetching)? = ApplePodcastTranscriptService.bundled()
) async throws -> SourceMarkdownVersion? {
    #if PODCAST_TRANSCRIPTS
    guard let origin = try store.sourceOrigin(sourceID: id) else {
        throw SourceRefreshService.RefreshError.notRefreshable("unknown")
    }
    guard origin.provider == .applePodcast else {
        throw SourceRefreshService.RefreshError.notRefreshable(origin.agentName)
    }
    guard let planURLString = origin.plan,
          let pageURL = URL(string: planURLString),
          let episode = PodcastEpisodeURL.parse(planURLString) else {
        throw SourceRefreshService.RefreshError.missingPlan
    }
    guard let svc = fetcher else {
        throw PodcastTranscriptError.signatureUnavailable(
            "Apple Podcasts transcripts need the signing helper, which isn't available in this build.")
    }
    // The materializer runs the transcript fetch (helper subprocess + two
    // HTTP round-trips + TTML parse) off-main in a detached Task; the
    // model never touches the store inside this `await`.
    let provider = ApplePodcastMaterializer(episode: episode, pageURL: pageURL, fetcher: svc)
    let transcript = try await provider.materialize()
    let markdown = String(data: transcript.data, encoding: .utf8) ?? ""
    do {
        return try store.appendProcessedMarkdown(
            sourceID: sourceID, content: markdown,
            origin: .transcript, note: nil, technique: "apple-ttml")
    } catch {
        // #475: never silently swallow — a transcription failure (after
        // network round-trips) must leave a Console.app trace.
        DebugLog.store("WikiStoreModel.transcribePodcast appendProcessedMarkdown failed (source=\(sourceID.rawValue)): \(error)")
        return nil
    }
    #else
    // Phase-out build: podcast support isn't compiled. The View-level
    // predicate hides the button in `#if !PODCAST_TRANSCRIPTS`, so this
    // path is unreachable in production; the throw keeps the model honest
    // for callers that bypass the predicate (tests, headless API).
    throw PodcastTranscriptError.signatureUnavailable(
        "Apple Podcasts transcripts are not compiled into this build (WIKIFS_APP_STORE=1).")
    #endif
}
```

The `id` parameter shadowing in the `#if PODCAST_TRANSCRIPTS` body
re-refers to the outer `sourceID`; corrected in the implementation commit.

### 3. `WikiStoreModel.podcastBackend` injection point

`Sources/WikiFSCore/Store/WikiStoreModel.swift` — beside `htmlBackend`:

```swift
/// The configured podcast transcription backend (issue #799 PR4). Set at
/// app wiring time from `ExtractionConfig.podcastBackend` so the Transcribe
/// button and the "Re-transcribe with" menu have a default to use when the
/// user taps Transcribe without picking a backend explicitly. `nil` = no
/// default chosen (a fresh install, or a config file written before this
/// field shipped); the View-level `runTranscription` falls back to
/// `.appleTranscript` directly. Mirrors the `htmlBackend` injection
/// pattern (the model is deliberately NOT config-aware; config is read by
/// `ExtractionCoordinator` in `WikiFSEngine`).
@ObservationIgnored public var podcastBackend: PodcastTranscriptionBackend?
```

`Sources/WikiFSEngine/SessionManager.swift` `:68` — beside
`htmlMarkdownExtractorFactory`:

```swift
public let podcastBackendResolver: @MainActor () -> PodcastTranscriptionBackend?
```

`Sources/WikiFSEngine/WikiSession.swift` `:158` (init param) + `:231`
(assignment):

```swift
podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend? = { nil },
// ...
model.podcastBackend = podcastBackendResolver()
```

`Sources/WikiFS/Window/WikiFSApp.swift` beside the `htmlBackendResolver`
construction (around `:218`): add a `podcastBackendResolver` closure that
reads `ExtractionConfig.load(from: directory).podcastBackend`. Pass through
to the session manager. Same plumbing as `htmlBackendResolver`.

### 4. `SourceDetailView` — Transcribe button, provenance chip, Re-transcribe menu

Four concrete edits (line numbers refer to `SourceDetailView.swift`):

#### 4a. `isPodcastEmbed` + `isTranscribable` + `needsTranscription` predicates

Below `isHTMLSource` (~`:149`):

```swift
/// `true` for byteless Apple Podcasts embed sources (`agentName ==
/// "apple-podcast"`). Detects via the loaded `origin`'s provider — the
/// byteless-source synthetic MIME (`audio/apple-podcast`) is also a
/// reliable tell, but `origin.provider` is the single source of truth
/// (matches how `isSourceRefreshable` gates the Refresh button). Returns
/// `false` until `origin` loads, so the predicate is re-evaluated when
/// `.task(id: file.id)` finishes loading origin — same shape as
/// `isRefreshable`.
private var isPodcastEmbed: Bool { origin?.provider == .applePodcast }

/// `true` when this podcast source can be transcribed right now — the
/// single source of truth for the Transcribe button's enable state.
/// Delegates to `store.isSourceRefreshable(for:)` so the runtime guard
/// (the bundled signing helper binary present + this build compiles
/// podcast support) is identical to the existing Refresh button's guard
/// for podcasts (issues #799 PR4 + parent plan §PR4 AC.16). The
/// predicate already returns `false` for non-podcast sources, so this is
/// a typed narrowing over it.
private var isTranscribable: Bool {
    isPodcastEmbed && store.isSourceRefreshable(for: file.id)
}

/// A transcribable podcast source with no transcript yet — the gate for
/// the prominent "Transcribe" call-to-action. Analog of `needsExtraction`
/// for PDF/HTML sources. Exclusivity guarded: a podcast source with no
/// transcript shows Transcribe (NOT Refresh — there's nothing to refresh
/// yet); once a transcript exists, the provenance chip + Re-transcribe
/// menu take over (and Refresh is offered when `isRefreshable && !needsExtraction`
/// — the existing gate).
private var needsTranscription: Bool { isTranscribable && !hasMarkdown }
```

#### 4b. Generalize `isExtractable` to include podcast

`needsExtraction` (~`:309`) stays as-is — it gates the Extract button
which is for PDF/HTML only (the bytes→markdown transform). Podcast
sources use the new `needsTranscription` gate. The provenance chip's gate
(original `isExtractable, hasMarkdown, let head = headVersion`) widens:

```swift
private var isExtractable: Bool { isPDF || isHTMLSource }
private var hasExtractionChip: Bool {
    (isExtractable || isTranscribable) && hasMarkdown
}
```

The new `hasExtractionChip` is used in `extractProvenanceChip`'s
`if hasExtractionChip, let head = headVersion` gate so podcast sources
with a transcript show the chip and the Re-transcribe menu.

#### 4c. Transcribe button + action dispatch

In the primary actions row (`~`:675``), alongside the Extract button
`if needsExtraction { … }`, add a sibling:

```swift
if needsTranscription {
    Button(isTranscribing ? "Transcribing…" : "Transcribe",
           systemImage: "waveform") {
        DebugLog.extraction("SourceDetailView: Transcribe tapped — id=\(file.id.rawValue)")
        Task { await runTranscription() }
    }
    .buttonStyle(.borderedProminent)
    .disabled(isTranscribing || isThisFileExtracting
              || tracker.isSlotBusyForOtherSource(file.id))
}
```

The new `@State private var isTranscribing = false` mirrors `isExtracting`.

Add the action methods beside `runHtmlExtraction` / `runHtmlReExtraction`:

```swift
/// Podcast transcription trigger (issue #799 PR4). Inline — does NOT
/// route through the queue engine (the queue is PDF-coupled via
/// `ExtractionResolution.pdfData` / `convert(pdfData:)` /
/// `seedPdfMarkdown`; podcast transcription is a NETWORK FETCH with a
/// different input shape). Mirrors `runHtmlExtraction` (PR2), but calls
/// `WikiStoreModel.transcribePodcast(sourceID:fetcher:)` (the new
/// direct-network trigger in PR4). Uses the configured `store.podcastBackend`
/// when set; otherwise falls back to `.appleTranscript` (only backend
/// today). On a build without `PODCAST_TRANSCRIPTS`, the predicate
/// `needsTranscription` is `false` (its underlying `isSourceRefreshable`
/// returns `false` for `.applePodcast` outside the flag), so the button
/// doesn't render; the `nil`-handle on the bundled signing helper is
/// surfaced as `PodcastTranscriptError.signatureUnavailable`, caught
/// here as `extractError`.
private func runTranscription() async {
    isTranscribing = true
    isExtracting = false  // mutual-exclusion: one affordance at a time
    extractError = nil
    defer { isTranscribing = false }
    do {
        if let head = try await store.transcribePodcast(sourceID: file.id) {
            headVersion = head
        }
    } catch PodcastTranscriptError.signatureUnavailable(let message) {
        extractError = message
    } catch SourceRefreshService.RefreshError.notRefreshable(let agent) {
        extractError = "Sources from \"\(agent)\" can't be transcribed."
    } catch {
        extractError = "Transcribe failed: \(error.localizedDescription)"
    }
}

/// Re-transcription trigger (issue #799 PR4). Mirrors `runHtmlReExtraction`
/// but calls the inline `transcribePodcast` path. The `backend` parameter
/// is currently a placeholder for future backends (Whisper / Rev.ai / etc.);
/// `.appleTranscript` is the only backend today, so every re-transcribe
/// routes through the same `transcribePodcast` path. The picker is the
/// scaffolding for extensibility.
private func runTranscription(with backend: PodcastTranscriptionBackend) async {
    isTranscribing = true
    extractError = nil
    defer { isTranscribing = false }
    do {
        if let head = try await store.transcribePodcast(sourceID: file.id) {
            headVersion = head
        }
    } catch {
        extractError = "Transcribe failed: \(error.localizedDescription)"
    }
}
```

#### 4d. Re-transcribe with menu (podcast branch)

In `extractionProvenanceChip`'s "Re-extract with" `Section`, add a third
mutually-exclusive branch alongside the existing HTML/PDF branches:

```swift
Section("Re-extract with") {
    if isHTMLSource {
        ForEach(HtmlExtractionBackend.allCases, id: \.self) { backend in
            Button(backend.displayName) { Task { await runHtmlReExtraction(with: backend) } }
            .disabled(isThisFileExtracting || tracker.isSlotBusyForOtherSource(file.id))
        }
    } else if isPodcastEmbed {
        ForEach(PodcastTranscriptionBackend.allCases, id: \.self) { backend in
            Button(backend.displayName) { Task { await runTranscription(with: backend) } }
            .disabled(isTranscribing || isThisFileExtracting
                      || tracker.isSlotBusyForOtherSource(file.id))
        }
    } else {
        ForEach(ExtractionBackend.allCases, id: \.self) { backend in
            Button(backend.displayName) { Task { await runReExtraction(with: backend) } }
            .disabled(isThisFileExtracting || tracker.isSlotBusyForOtherSource(file.id))
        }
    }
}
```

A podcast source is HTML-xor-PDF-xor-podcast — `isExtractable` excludes
podcast sources (so a podcast doesn't show Extract), `isPodcastEmbed`
excludes HTML/PDF sources (so a podcast DOES show Transcribe + the
podcast Re-transcribe menu). Three mutually-exclusive branch arms.

### 5. No schema migration + downstream impacts

Pre-PR4 podcast sources already have a transcript HEAD stamped with
`origin: .transcript` and `technique: nil` (the old `addBytelessSource` +
`appendProcessedMarkdown(technique: nil)` path). PR4 leaves those rows in
place — existing sources keep their pre-fetched transcript. Only NEW
ingests change. This matches the parent plan's "Out of scope" section.

After PR4 a fresh podcast source has no `source_markdown_versions` HEAD:

1. **Search (Tantivy / FTS5)**: indexes title-only (filename + display
   name); body unsearchable until transcribed. Not broken — degraded,
   matching the post-PR3 HTML trade-off.
2. **File Provider `.md` sibling**: no `.md` projected — the source
   appears as a `.html`-style pointer file (the byteless-source
   synthetic MIME) in Finder. The user clicks Transcribe (PR4) to
   surface the `.md` again.
3. **Reader view**: the source has an `embedTarget` (the player iframe);
   `SourceDetailView`'s `isBytelessEmbedWithPlayer` renders the player
   without a Reader row when `!hasMarkdown` (existing behavior — the
   no-transcript path pre-PR4 used the same `availableTabs` shift to
   `[.reader, .media]` with no `.split`). No crash, no broken state.
4. **Agent ingestion**: the agent gets no bytes (it's byteless) and
   no processed markdown (no transcript). `WikiStoreModel.canIngest`
   returns `false` for this source (the existing guard covers the
   no-processed-markdown + byteless case — the same edge YouTube
   sources hit when their caption fetch failed pre-#646). The Ingest
   button is disabled with the existing "No content to ingest yet"
   affordance; the user transcribes first.

Each is acceptable given the user's explicit "no automatic extraction"
directive (parent plan), and each is the same trade-off the post-PR3 HTML
sources already accept.

## Acceptance criteria

- **AC.14**: Ingesting a podcast URL stores the byteless embed source with NO
  transcript (`source_markdown_versions` for that source id is empty).
  The source's `origin` is `apple-podcast` with the pasted page URL as
  `plan` and the numeric episode ID as `externalIdentity`.
- **AC.15**: Tapping "Transcribe" on the un-transcribed podcast source
  triggers `PodcastTranscriptFetching.transcript(for:)` and creates a
  transcript processed-markdown version (HEAD, `.transcript` origin,
  `"apple-ttml"` technique). The provenance chip appears with the
  Re-transcribe menu.
- **AC.16**: The Transcribe button is disabled when the signing helper is
  unavailable (`ApplePodcastTranscriptService.bundled()` returns `nil` at
  runtime, OR `#if !PODCAST_TRANSCRIPTS` — neither the button nor the
  menu is visible in that config because every podcast symbol is gated).

## Tests

Three existing tests assert the pre-PR4 ingest contract (transcript lands
at ingest). They're rewritten to assert the new contract (byteless
embed-only + the new Transcribe trigger):

- **`Tests/WikiFSTests/PodcastIngestRoutingTests`** — major rewrite:

  - `episodeURLRoutesToTranscriptPipelineAndStoresMarkdown` →
    `episodeURLRoutesToBytelessEmbedWithoutTranscript`. Asserts
    `outcome.kind == .audioEmbed`, byteless `byteSize == 0`, the source's
    origin preserved (agentName, plan, externalIdentity); the source has
    NO `processedMarkdownHead` (the new invariant). The
    `podcast.requestedEpisodeID` assertion is DROPPED — the fetcher is
    not consulted at ingest anymore.
  - `pastingSameEpisodeTwiceDedupsAsByteless` — unchanged (byteless
    dedup happens at `addBytelessSource` regardless of transcript).
  - `missingHelperGivesAClearError` → `missingHelperAtTranscribeGivesClearError`.
    Rewritten to test the new contract: ingest now SUCCEEDS without a
    helper (it just creates a byteless source), but `transcribePodcast`
    throws `PodcastTranscriptError.signatureUnavailable` when invoked
    without a helper. Exercises AC.16.
  - `nonPodcastURLStillUsesHTMLFetcher` — unchanged.
  - `podcastURLStaysFirstInRoutingPrecedence` — outcome.kind assertion
    changes from `.podcastTranscript` to `.audioEmbed`; podcast
    fetcher is no longer consulted.
  - `episodeURLSetsDisplayTitleFromSlug`,
    `multiWordSlugResolvesTitleCasedDisplayName`,
    `sluglessEpisodeURLLeavesFilenameDisplayName` — unchanged (the
    display-title path is offline + unaffected by the ingest contract
    change). Filename assertions change from
    `<slug>-<id>-transcript.md` to `<slug>-<id>` (or `podcast-<id>` for
    slugless).

- **`Tests/WikiFSTests/SourceRefreshTests.podcastRefreshAppendsDerivedMarkdown`**
  — rewritten: v1 transcript is now seeded via `transcribePodcast(sourceID:)`,
  not via `addURL` (which no longer writes a transcript); then
  `refreshSource` appends v2. Two transcription calls instead of one
  ingest + one refresh.

- **`Tests/WikiFSTests/BytelessEmbedIntegrationTests`** — the
  `youtubeEmbedAndTranscriptOutcome`-shaped comment block about the
  podcast byteless-source convention stays; the actual
  `youtubeEmbedAndTranscript*` tests are unchanged (they're YouTube).
  The `bytelessMediaProvidersAreNotRefreshable` test, which lists
  providers NOT including apple-podcast, is unchanged (its impact is
  refreshed, but the predicate behavior is unchanged — apple-podcast stays
  refreshable, the other providers stay non-refreshable).

Four new tests cover the new PR4 invariants not exercised today:

- **`PodcastIngestRoutingTests.episodeURLStoresBytelessEmbedOnly`** (AC.14) — the
  new contract version of the existing routing test.
- **`PodcastIngestRoutingTests.transcribePodcastWritesTranscriptAlternative`** (AC.15)
  — ingests a podcast via `addURL`, asserts no transcript HEAD exists
  (the PR4 invariant), THEN calls `transcribePodcast(sourceID:)` with a
  fake fetcher, asserts the transcript version IS created (HEAD,
  `.transcript` origin, `"apple-ttml"` technique) — proves the Transcribe
  button works on the byteless source.
- **`PodcastIngestRoutingTests.transcribeNonPodcastSourceThrowsNotRefreshable`**
  — defensive guard: calling `transcribePodcast(sourceID:)` on a local-file
  source throws `RefreshError.notRefreshable`. The View-level predicate
  prevents this; the model stays honest.
- **`PodcastIngestRoutingTests.reTranscribeAppendsCoexistingAlternative`** —
  transcribe twice; asserts v1.id ≠ v2.id, both in the history, v2 is HEAD
  by the default-active rule. Mirrors the HTML
  `reExtractHtmlAppendsCoexistingAlternative` (PR2).

The existing `ApplePodcastTranscriptServiceTests`, `ApplePodcastLiveTests`,
`PodcastEpisodeURLTests`, and `TTMLTranscriptTests` are unchanged — they
test the lower-level service pipeline (token → AMP → TTML → parse) which
PR4 doesn't touch.

## Build & test

```bash
make version prompts && swift build
swift test                        # full suite — ~1.5 min (in-memory fixtures #658)
```

## Files touched

- **New:** `Tests/WikiFSTests/PodcastTranscribeTriggerTests.swift` (the
  dedicated Transcribe-trigger test suite, AC.14/15/16 + re-transcribe
  alternative), `plans/extraction-framework-pr4.md` (this plan doc).
- **Edit (code):**
  - `Sources/WikiFSCore/Store/WikiStoreModel.swift` (the `addURL`
    podcast branch is rewritten to byteless-only + the new
    `transcribePodcast(sourceID:fetcher:)` method + the
    `podcastBackend` injection point + the `podcastEmbedMIME` /
    `podcastEmbedFilename(for:)` private helpers).
  - `Sources/WikiFS/Sources/SourceDetailView.swift` (the
    `isPodcastEmbed` / `isTranscribable` / `needsTranscription`
    predicates; the Transcribe button + menu branch; the
    `runTranscription` / `runTranscription(with:)` action methods; the
    generalized `hasExtractionChip` gate; the new `@State isTranscribing`
    + `@State extractError`).
  - `Sources/WikiFSEngine/WikiSession.swift`
    (`podcastBackendResolver` param + assignment).
  - `Sources/WikiFSEngine/SessionManager.swift`
    (`podcastBackendResolver` factory + pass-through).
  - `Sources/WikiFS/Window/WikiFSApp.swift`
    (`podcastBackendResolver` from config).
- **Edit (tests):**
  - `Tests/WikiFSTests/PodcastIngestRoutingTests.swift` (rewrite five
    tests for the new ingest contract + add
    `episodeURLStoresBytelessEmbedOnly` (AC.14); rewrite
    `missingHelperGivesAClearError` → `missingHelperAtTranscribeGivesClearError`
    (AC.16)).
  - `Tests/WikiFSTests/SourceRefreshTests.swift` (rewrite
    `podcastRefreshAppendsDerivedMarkdown` — v1 transcript comes from
    `transcribePodcast`, not `addURL`).
- **Edit (docs):** `PLAN.md` (master index — mark PR4 landed + the
  podcast ingest-contract change), `PROGRESS.md` (entry for PR4), this file.

## Out of scope (covered by parent plan)

- **Queue engine generalization** — podcast transcription uses the inline
  path; the PDF-coupled queue stays PDF-only (deferred per parent plan).
- **New podcast backends** (Whisper, Rev.ai) — PR4 adds the framework +
  the Apple Podcasts backend. The `PodcastTranscriptionBackend` enum is
  extensible; the Re-transcribe with menu lists `allCases`, so new
  backends slot in by adding a case. Follow-ups are listed in the parent
  plan's "Out of scope" section.
- **Unifying the three extraction protocols** (`MarkdownExtractor` for
  PDF, `HtmlMarkdownExtractor` for HTML, `PodcastTranscriptFetching` for
  podcast) — they have fundamentally different input types
  (`Data`/`String`/network-fetch). Each keeps its own protocol; the
  View-level dispatch ties them together.
- **Migrating existing auto-transcribed podcast sources** — their
  transcript HEAD rows persist (`origin: .transcript`, `technique: nil`).
  Only NEW ingests change. Matches the parent plan's "Out of scope"
  section.
- **PathKeeper PR.5** — there is no PR5; this is the last of the four
  PRs in the staged plan.
