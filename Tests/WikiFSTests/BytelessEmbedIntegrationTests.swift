import Foundation
import Testing
@testable import WikiFSCore

/// Phase 4b integration tests: store-level behavior for byteless external-embed
/// media sources — changeToken advance (AC.6), dedup (AC.7), the batched
/// `embedDescriptors()` query, `addURL` routing (AC.1/AC.2), and refreshability
/// (AC.8). No network — routing uses pure recognizers + an exploding/HTML fetcher.
@MainActor
struct BytelessEmbedIntegrationTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Fails if reached for an HTML website fetch — a recognized media URL must
    /// NOT hit the website path. Serves a canned oEmbed JSON title for the
    /// oEmbed endpoints (YouTube/Vimeo/Spotify/SoundCloud), since the byteless
    /// embed flow now best-effort-fetches the provider display title via oEmbed
    /// (issue #572) — that is expected new behavior, not a website fetch.
    struct ExplodingFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            let absolute = url.absoluteString
            if absolute.contains("/oembed") || absolute.contains("api/oembed") {
                return URLFetchService.FetchResponse(
                    data: Data(#"{"title":"Exploding Fixture Title","author_name":"x"}"#.utf8),
                    contentType: "application/json", finalURL: url)
            }
            Issue.record("HTML fetcher must not run for a recognized media URL")
            throw URLFetchService.FetchError.empty
        }
    }

    struct HTMLFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            URLFetchService.FetchResponse(
                data: Data("<title>Hi</title><p>x</p>".utf8),
                contentType: "text/html", finalURL: url)
        }
    }

    // MARK: - AC.6: changeToken advances on byteless media add

    @Test func changeTokenAdvancesWhenBytelessMediaAdded() throws {
        let store = try tempStore()
        let before = try store.changeToken()
        _ = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)
        let after = try store.changeToken()
        #expect(before != after)
    }

    // MARK: - AC.7: duplicate external_identity rejected

    @Test func duplicateExternalIdentityRejected() throws {
        let store = try tempStore()
        _ = try store.addBytelessSource(
            filename: "spotify-track-abc",
            mimeType: "audio/spotify",
            provenance: SourceProvenance(
                agentName: "spotify", activityKind: "fetch",
                plan: "https://open.spotify.com/track/abc",
                externalRef: "https://open.spotify.com/track/abc",
                externalIdentity: "track/abc"),
            role: .primary)
        // Same external_identity → duplicate (byteless partial-index dedup).
        #expect(throws: WikiStoreError.self) {
            _ = try store.addBytelessSource(
                filename: "spotify-track-abc-2",
                mimeType: "audio/spotify",
                provenance: SourceProvenance(
                    agentName: "spotify", activityKind: "fetch",
                    plan: "https://open.spotify.com/track/abc",
                    externalRef: "https://open.spotify.com/track/abc",
                    externalIdentity: "track/abc"),
                role: .primary)
        }
        #expect(try store.listSources().count == 1)
    }

    // MARK: - embedDescriptors() query

    @Test func embedDescriptorsReturnsBytelessMediaOnly() throws {
        let store = try tempStore()
        // A byteful source (has bytes) — should NOT appear.
        _ = try store.addSource(
            filename: "pic.png", data: Data([0x89, 0x50, 0x4E, 0x47]),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: "image/png",
            provenance: nil)
        // A byteless YouTube source — SHOULD appear with the right fields.
        let yt = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)

        let descriptors = try store.embedDescriptors()
        #expect(descriptors.count == 1)  // byteful excluded
        let d = try #require(descriptors[yt.id])
        #expect(d.mimeType == "video/youtube")
        #expect(d.externalIdentity == "dQw4w9WgXcQ")
        #expect(d.agentName == "youtube")
        #expect(d.planURL == "https://youtu.be/dQw4w9WgXcQ")
        // The descriptor yields a YouTube iframe target.
        let target = try #require(ExternalEmbed.target(for: d))
        #expect(target.kind == .iframe)
        // Embed URL carries the reader origin (issue #206: no origin ⇒ error 153).
        #expect(target.url.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"))
        #expect(target.url.contains("origin="))
    }

    // MARK: - AC.1: provider URL routing (no network)

    @Test func youtubeURLRoutesToBytelessVideoEmbed() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // Pass nil as the YouTube transcript fetcher so only the byteless embed
        // is created (this test verifies the embed routing, not transcript
        // extraction — that's covered by youtubeURLWithTranscriptCreatesEmbedAndMarkdown).
        #if PODCAST_TRANSCRIPTS
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: ExplodingFetcher(),
            podcastFetcher: nil,
            youtubeFetcher: nil)
        #else
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: ExplodingFetcher(),
            youtubeFetcher: nil)
        #endif
        #expect(outcome.kind == .videoEmbed)
        let source = try #require(try store.listSources().first)
        #expect(source.byteSize == 0)  // byteless
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "youtube")
        #expect(origin.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func spotifyURLRoutesToBytelessAudioEmbed() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .audioEmbed)
        let source = try #require(try store.listSources().first)
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "spotify")
        #expect(origin.externalIdentity == "track/4uLU6hMCjMI75M1A2tKUQC")
    }

    // MARK: - AC.2: direct-remote media routing (no network)

    @Test func remoteMp3RoutesToBytelessRemoteMedia() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://radio.example.com/live.mp3", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .remoteMedia)
        let source = try #require(try store.listSources().first)
        #expect(source.byteSize == 0)
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "remote-media")
        #expect(origin.externalIdentity == "https://radio.example.com/live.mp3")
    }

    @Test func plainHTMLURLStillUsesWebsiteFetcher() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A non-media URL must NOT route to byteless media — it hits the fetcher.
        let outcome = try await model.addURL(
            "https://example.com/article", fetcher: HTMLFetcher())
        #expect(outcome.kind == .html)  // #599: HTML bytes preserved with markdown sidecar
    }

    // MARK: - #646: synthetic markdown for byteless sources

    /// Serves a rich Vimeo-shaped oEmbed payload so the synthesizer can render
    /// a readable page from real metadata (title + author + provider + duration
    /// + description).
    struct VimeoMetadataFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            // Only oEmbed URLs are expected; explode for anything else.
            let absolute = url.absoluteString
            guard absolute.contains("/oembed") || absolute.contains("api/oembed") else {
                throw URLFetchService.FetchError.network("not an oEmbed URL")
            }
            let body = """
            {"title":"Orientation","author_name":"Vimeo Staff",
             "author_url":"https://vimeo.com/staff","provider_name":"Vimeo",
             "thumbnail_url":"https://i.vimeocdn.com/x.jpg",
             "description":"A short orientation","duration":42}
            """
            return URLFetchService.FetchResponse(
                data: Data(body.utf8), contentType: "application/json", finalURL: url)
        }
    }

    /// Serves an empty 200 OK for oEmbed — simulates a reachable-but-empty
    /// provider response. The fetcher's `data.isEmpty` guard rejects this; the
    /// title-fetcher returns nil metadata, and the synthesizer falls back to
    /// a URL + filename-only page.
    struct EmptyOEmbedFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            URLFetchService.FetchResponse(
                data: Data(), contentType: "application/json", finalURL: url)
        }
    }

    @Test func vimeoURLWritesSyntheticMarkdownFromFullMetadata() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://vimeo.com/76979871", fetcher: VimeoMetadataFetcher())
        #expect(outcome.kind == .videoEmbed)
        let source = try #require(try store.listSources().first)
        // The display name is the oEmbed title (not the synthetic `vimeo-<id>`).
        #expect(source.effectiveName == "Orientation")
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(md.origin == .transcript)
        #expect(md.technique == "byteless-oembed-synthetic")
        #expect(md.content.hasPrefix("# Orientation\n"))
        #expect(md.content.contains("[https://vimeo.com/76979871](https://vimeo.com/76979871)"))
        #expect(md.content.contains("**Provider:** Vimeo"))
        #expect(md.content.contains("**Author:** [Vimeo Staff](https://vimeo.com/staff)"))
        #expect(md.content.contains("**Duration:** 0:42"))
        #expect(md.content.contains("A short orientation"))
        #expect(!md.content.contains("## Transcript"))
    }

    @Test func spotifyURLWritesSyntheticMarkdownEvenWithPartialMetadata() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        // ExplodingFetcher serves title + author only (Spotify-shape: no
        // description / duration).
        let outcome = try await model.addURL(
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
            fetcher: ExplodingFetcher())
        #expect(outcome.kind == .audioEmbed)
        let source = try #require(try store.listSources().first)
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(md.technique == "byteless-oembed-synthetic")
        // Title from oEmbed (ExplodingFetcher serves "Exploding Fixture Title")
        #expect(md.content.hasPrefix("# Exploding Fixture Title\n"))
        #expect(md.content.contains("[https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC]"))
        #expect(md.content.contains("**Author:** x"))
        // No description / duration block for Spotify-shape metadata.
        #expect(!md.content.contains("**Duration:**"))
        #expect(!md.content.contains("## Transcript"))
    }

    @Test func remoteMediaWritesMinimalSyntheticMarkdownWhenNoOEmbed() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        // remote-media has no oEmbed endpoint → MediaTitleFetcher.oembedURL
        // returns nil → fetchMediaMetadata returns nil → synthesizer renders
        // a title-from-filename + URL-only page.
        let outcome = try await model.addURL(
            "https://radio.example.com/live.mp3", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .remoteMedia)
        let source = try #require(try store.listSources().first)
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(md.technique == "byteless-oembed-synthetic")
        // Title falls back to the effective name (filename "live.mp3").
        #expect(md.content.hasPrefix("# live.mp3\n"))
        #expect(md.content.contains("[https://radio.example.com/live.mp3]"))
        // No metadata block (no oEmbed).
        #expect(!md.content.contains("**Provider:**"))
        #expect(!md.content.contains("**Author:**"))
        #expect(!md.content.contains("**Duration:**"))
    }

    @Test func bytelessSyntheticMarkdownIsEmptyOEmbedFallback() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        // An empty oEmbed body ⇒ metadata = nil (best-effort) ⇒ minimal page.
        let outcome = try await model.addURL(
            "https://vimeo.com/1", fetcher: EmptyOEmbedFetcher())
        #expect(outcome.kind == .videoEmbed)
        let source = try #require(try store.listSources().first)
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        // No title in metadata → fallback to the synthetic filename.
        #expect(md.content.hasPrefix("# vimeo-1\n"))
        #expect(md.content.contains("[https://vimeo.com/1](https://vimeo.com/1)"))
        #expect(!md.content.contains("**Provider:**"))
    }

    // MARK: - #564: YouTube transcript extraction

    /// A fake YouTube fetcher that serves canned watch-page HTML + caption XML.
    struct YouTubeFixtureFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            let absolute = url.absoluteString
            // Issue #572: the byteless embed flow best-effort-fetches the video
            // title via oEmbed alongside the transcript. Serve a canned title.
            if absolute.contains("/oembed") {
                return URLFetchService.FetchResponse(
                    data: Data(#"{"title":"Test Talk","author_name":"Test Author"}"#.utf8),
                    contentType: "application/json", finalURL: url)
            }
            if absolute.contains("/watch") {
                return URLFetchService.FetchResponse(
                    data: Data(Self.watchPageHTML.utf8), contentType: "text/html", finalURL: url)
            }
            if absolute.contains("timedtext") {
                return URLFetchService.FetchResponse(
                    data: Data(Self.captionXML.utf8), contentType: "text/xml", finalURL: url)
            }
            throw URLFetchService.FetchError.network("no canned response")
        }
        static let watchPageHTML = """
        <script>var ytInitialPlayerResponse = {
            "videoDetails": {"title": "Test Talk"},
            "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": [
                {"baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en",
                 "languageCode": "en", "name": {"simpleText": "English"}}
            ]}}
        };</script>
        """
        static let captionXML = """
        <transcript>
            <text start="0.5" dur="2.3">Hello world</text>
            <text start="2.8" dur="1.5">Second cue</text>
        </transcript>
        """
    }

    @Test func youtubeURLWithTranscriptCreatesEmbedAndMarkdown() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        #if PODCAST_TRANSCRIPTS
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: YouTubeFixtureFetcher(),
            podcastFetcher: nil,
            youtubeFetcher: nil)  // unused at ingest (PR5: byteless-only)
        #else
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: YouTubeFixtureFetcher())
        #endif
        // Issue #799 PR5: YouTube ingest is now byteless-only — no transcript
        // fetched at ingest (mirrors the podcast PR4 contract). The outcome
        // reports the byteless video embed (NOT `.videoTranscript` — the
        // pre-PR5 contract reported a transcript because the auto-fetch ran
        // at ingest; PR5 stopped that, so the outcome reflects just the embed).
        // The synthetic metadata page is still written so the reader has
        // readable content (issue #646) — but the synthetic page carries no
        // transcript cues; the user clicks Transcribe to fetch those.
        #expect(outcome.kind == .videoEmbed)
        #expect(outcome.filename == "youtube-dQw4w9WgXcQ")
        let sources = try store.listSources()
        #expect(sources.count == 1)  // one byteless source, transcript would be a derived version
        let source = try #require(sources.first)
        #expect(source.byteSize == 0)  // byteless embed
        // The synthetic metadata-only markdown page exists (the byteless-only
        // ingest writes it via `writeSyntheticBytelessMarkdown`), but it has
        // the `byteless-oembed-synthetic` technique (NOT `youtube-captions`),
        // and no transcript cues.
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(md.technique == "byteless-oembed-synthetic")
        #expect(!md.content.contains("Hello world"))
        #expect(!md.content.contains("Second cue"))
        // The oEmbed title is still surfaced (this fixture serves it).
        #expect(md.content.contains("Test Talk"))

        // The user clicks Transcribe — `transcribe(sourceID:)` dispatches to
        // the private `transcribeYouTube` helper, which fetches via
        // `YouTubeTranscriptFetching.transcript(forVideoID:)`.
        let head = try #require(try await model.transcribe(
            sourceID: source.id,
            youtubeFetcher: CannedYouTubeFetcher()))
        #expect(head.origin == .transcript)
        #expect(head.technique == "youtube-captions")
        #expect(head.content.contains("Hello world"))
        #expect(head.content.contains("Second cue"))
        #expect(head.content.contains("[Watch on YouTube]"))
        // Persisted to the store as the new HEAD (alternative appended —
        // the synthetic page is still in history, just no longer the head).
        let persisted = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(persisted.content == head.content)
        #expect(persisted.origin == .transcript)
        #expect(persisted.technique == "youtube-captions")
    }

    @Test func youtubeURLWithNoCaptionsFallsBackToSyntheticMarkdown() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        let emptyFetcher = YouTubeNoCaptionsFetcher()
        #if PODCAST_TRANSCRIPTS
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: emptyFetcher,
            podcastFetcher: nil,
            youtubeFetcher: nil)  // unused at ingest (PR5: byteless-only)
        #else
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: emptyFetcher)
        #endif
        // Issue #799 PR5: YouTube ingest is byteless-only — the fetcher is
        // NOT consulted at ingest (the param is a back-compat no-op now,
        // mirroring `podcastFetcher`). The outcome is always `.videoEmbed`
        // (no `.videoTranscript` arm anymore), and the synthetic metadata
        // page is written so the reader has something to show (issue #646).
        // The no-oEmbed path (this fixture doesn't serve the oEmbed endpoint)
        // means the synthesizer renders URL + filename only.
        #expect(outcome.kind == .videoEmbed)
        let sources = try store.listSources()
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.byteSize == 0)  // byteless embed
        // The synthetic markdown head exists and carries the URL — the
        // byteless-only ingest writes it the same way regardless of whether
        // a fetcher was injected.
        let md = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(md.origin == .transcript)
        #expect(md.technique == "byteless-oembed-synthetic")
        #expect(md.content.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        // No transcript cues present (captions weren't fetched at ingest).
        #expect(!md.content.contains("Hello world"))
        // The user clicks Transcribe — `transcribe(sourceID:)` now
        // attempts the caption fetch on-demand. With the no-captions
        // fixture, the fetch throws `YouTubeTranscriptError.noCaptions`.
        await #expect(throws: YouTubeTranscriptError.self) {
            _ = try await model.transcribe(
                sourceID: source.id,
                youtubeFetcher: ThrowingYouTubeFetcher())
        }
    }

    /// Serves a watch page that has no caption tracks → `.noCaptions`.
    struct YouTubeNoCaptionsFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            if url.absoluteString.contains("/watch") {
                let html = """
                <script>var ytInitialPlayerResponse = {
                    "videoDetails": {"title": "No Captions"},
                    "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": []}}
                };</script>
                """
                return URLFetchService.FetchResponse(
                    data: Data(html.utf8), contentType: "text/html", finalURL: url)
            }
            throw URLFetchService.FetchError.network("no canned response")
        }
    }

    // MARK: - AC.8: new providers are not refreshable

    @Test func bytelessMediaProvidersAreNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let service = SourceRefreshService(fetcher: HTMLFetcher())
        let agents = ["youtube", "vimeo", "spotify", "soundcloud", "remote-media"]
        for (i, agent) in agents.enumerated() {
            _ = try store.addBytelessSource(
                filename: "media-\(i)",
                mimeType: agent.contains("video") || agent == "vimeo" ? "video/\(agent)" : "audio/\(agent)",
                provenance: SourceProvenance(
                    agentName: agent, activityKind: "fetch",
                    plan: "https://example.com/\(agent)",
                    externalRef: nil, externalIdentity: "id-\(i)"),
                role: .primary)
        }
        for source in try store.listSources() {
            let origin = try #require(try store.sourceOrigin(sourceID: source.id))
            #expect(origin.agentName != "website")  // sanity
            await #expect(throws: SourceRefreshService.RefreshError.self) {
                _ = try await service.materialize(origin: origin)
            }
        }
        _ = model  // suppress unused warning
    }

    // MARK: - YouTube transcript fakes

    /// Returns a canned transcript for any video ID (for the Transcribe button
    /// test path — the real `YouTubeTranscriptService` now spawns a subprocess).
    struct CannedYouTubeFetcher: YouTubeTranscriptFetching {
        func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
            return YouTubeTranscript(
                videoID: videoID,
                title: "Test Talk",
                markdown: "# Test Talk\n\n[Watch on YouTube](https://www.youtube.com/watch?v=\(videoID))\n\nHello world. Second cue.",
                filename: "Test-Talk-\(videoID)-transcript.md")
        }
    }

    /// Always throws `.noCaptions` (for the no-captions Transcribe test path).
    struct ThrowingYouTubeFetcher: YouTubeTranscriptFetching {
        func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
            throw YouTubeTranscriptError.noCaptions
        }
    }
}
