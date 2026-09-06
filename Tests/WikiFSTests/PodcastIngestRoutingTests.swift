import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.addURL` ROUTES an Apple Podcasts episode link to
/// the byteless-embed pipeline (not the HTML fetcher) and stores the source
/// WITHOUT a transcript (issue #799 PR4 invariant, unchanged by the Apple
/// TTML packaging). Both podcast transcribe paths now enqueue through the
/// extraction queue — the reviewed apple-podcast-transcript and
/// podcast-transcript package routes — so the model-level `transcribe`
/// throws `.podcastQueueRequired` for podcast sources and writes nothing.
///
/// Uses an exploding HTML fetcher so we can assert which path ran — no
/// network, no private frameworks.
@MainActor
struct PodcastIngestRoutingTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-podcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Fails if the HTML fetch path is taken — a podcast URL must NOT reach it.
    struct ExplodingFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            Issue.record("HTML fetcher must not run for an Apple Podcasts episode URL")
            throw URLFetchService.FetchError.empty
        }
    }

    private static let chinaTalkURL =
        "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"

    // MARK: - AC.14: Ingest stores byteless embed WITHOUT a transcript

    /// Issue #799 PR4 AC.14 — ingesting an Apple Podcasts episode URL stores
    /// a byteless embed source with NO transcript. Transcription is a
    /// separate, user-triggered queue job through the package route.
    @Test func episodeURLStoresBytelessEmbedWithoutTranscript() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher())

        // Outcome reports the byteless audio-embed (matching Spotify/SoundCloud),
        // NOT `.podcastTranscript` (which implied a transcript was fetched).
        #expect(outcome.kind == .audioEmbed)
        #expect(outcome.byteSize == 0)
        // Filename is `<slug>-<id>` (mirrors YouTube's `youtube-<id>`); the
        // `-transcript.md` suffix is reserved for the transcript version row's
        // filename written by the queue's package persistence.
        #expect(outcome.filename == "chinatalk-1000774368453")

        // §11 byteless model: the source is byteless (no content bytes).
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.byteSize == 0)
        // sourceContent returns empty Data for a byteless source.
        #expect(try store.sourceContent(id: stored.id).isEmpty)
        // No processed-markdown version was written — the source's
        // `source_markdown_versions` is empty until the user transcribes.
        #expect(try store.processedMarkdownHead(sourceID: stored.id) == nil)
        // Origin provenance: apple-podcast agent + pasted episode URL + numeric ID.
        let origin = try #require(try store.sourceOrigin(sourceID: stored.id))
        #expect(origin.agentName == "apple-podcast")
        #expect(origin.plan == Self.chinaTalkURL)
        #expect(origin.externalIdentity == "1000774368453")
    }

    @Test func pastingSameEpisodeTwiceDedupsAsByteless() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        _ = try await model.addURL(Self.chinaTalkURL, fetcher: ExplodingFetcher())

        // Second paste of the same episode URL → duplicate (byteless dedup on
        // external_identity).
        await #expect(throws: WikiStoreError.self) {
            try await model.addURL(Self.chinaTalkURL, fetcher: ExplodingFetcher())
        }
        // Only one source was created.
        let sources = try store.listSources()
        #expect(sources.count == 1)
    }

    // MARK: - Transcribe routes through the queue

    /// The Apple TTML packaging: the model has no direct podcast fetch path.
    /// `transcribe(sourceID:)` on an Apple episode source throws
    /// `.podcastQueueRequired` — callers enqueue the durable job, which the
    /// queue resolves through the reviewed apple-podcast-transcript package
    /// (installed-package provenance; RSS fallback when no helper is staged,
    /// proven by the queue/provider tests).
    @Test func applePodcastTranscribeRequiresQueueEnqueue() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest SUCCEEDS without any fetch infrastructure (byteless only).
        let outcome = try await model.addURL(Self.chinaTalkURL, fetcher: ExplodingFetcher())
        #expect(outcome.kind == .audioEmbed)

        // Transcribe MUST direct the caller to the extraction queue — and
        // write nothing itself.
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        await #expect(throws: SourceRefreshService.RefreshError.podcastQueueRequired) {
            _ = try await model.transcribe(sourceID: stored.id)
        }
        #expect(try store.processedMarkdownHead(sourceID: stored.id) == nil)
    }

    /// The generic RSS podcast arm behaves identically: `.podcastQueueRequired`,
    /// nothing written. (Preserved from the RSS packaging; now pinned beside
    /// the Apple arm so both podcast source classes keep the same shape.)
    @Test func rssPodcastTranscribeRequiresQueueEnqueue() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let summary = try store.addBytelessSource(
            filename: "feed-1",
            mimeType: "audio/podcast",
            provenance: SourceProvenance(
                agentName: SourceProvider.podcast.rawValue,
                activityKind: "fetch",
                plan: "https://example.com/feed.rss",
                externalRef: "https://example.com/feed.rss",
                externalIdentity: nil),
            role: .primary)

        await #expect(throws: SourceRefreshService.RefreshError.podcastQueueRequired) {
            _ = try await model.transcribe(sourceID: summary.id)
        }
        #expect(try store.processedMarkdownHead(sourceID: summary.id) == nil)
    }

    @Test func nonPodcastURLStillUsesHTMLFetcher() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // A normal URL must NOT touch the podcast path; a fetcher returning HTML
        // proves the ordinary route still runs.
        struct HTMLFetcher: URLFetchService.URLResourceFetcher {
            func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
                URLFetchService.FetchResponse(
                    data: Data("<title>Hi</title><p>x</p>".utf8),
                    contentType: "text/html", finalURL: url)
            }
        }
        let outcome = try await model.addURL(
            "https://example.com/article", fetcher: HTMLFetcher())
        #expect(outcome.kind == .html)  // #599: HTML now preserved, outcome kind .html
    }

    /// Phase 4b routing-precedence: an Apple Podcasts episode URL must still
    /// route to `.audioEmbed` (apple-podcast stays FIRST) even though the new
    /// media recognizers are now wired in `addURL`. A `podcasts.apple.com`
    /// URL is not a recognized media-provider URL, but the order is pinned so a
    /// future recognizer can't accidentally shadow it.
    @Test func podcastURLStaysFirstInRoutingPrecedence() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let outcome = try await model.addURL(Self.chinaTalkURL, fetcher: ExplodingFetcher())
        #expect(outcome.kind == .audioEmbed)
    }

    /// Issue #621: the source's display name must be the un-slugified episode
    /// title (written via `setSourceDisplayName`, mirroring the oEmbed title
    /// step for YouTube/Vimeo/Spotify/SoundCloud) — NOT the slugified filename
    /// `chinatalk-1000774368453`.
    @Test func episodeURLSetsDisplayTitleFromSlug() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let outcome = try await model.addURL(Self.chinaTalkURL, fetcher: ExplodingFetcher())

        // Re-fetch (the in-memory `summary` came back BEFORE the
        // setSourceDisplayName write). `effectiveName` reads displayName first
        // and falls back to filename only when unset — so the title shows up as
        // the source's effective name everywhere in the UI.
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName == "Chinatalk")
        #expect(stored.effectiveName == "Chinatalk")
    }

    /// Issue #621: an episode URL with a multi-word slug resolves a real
    /// title-cased display name (small words kept lowercase) instead of the
    /// slug filename.
    @Test func multiWordSlugResolvesTitleCasedDisplayName() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // The issue's driving example episode URL — the slug is the entire
        // episode title as Apple generates it for an episode link.
        let url = "https://podcasts.apple.com/us/podcast/"
            + "if-you-care-about-food-you-have-to-care-about-land/"
            + "id1728932037?i=1000714478537"
        let outcome = try await model.addURL(url, fetcher: ExplodingFetcher())

        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName
                == "If You Care About Food You Have to Care About Land")
        #expect(stored.effectiveName
                == "If You Care About Food You Have to Care About Land")
    }

    /// Issue #621 edge case: an episode URL with no `/podcast/<slug>/` path
    /// (an unusual but parseable episode URL) leaves the display name unset —
    /// the slug → title helper returns nil and the synthetic filename display
    /// name stays in place, mirroring the oEmbed-nil discipline.
    @Test func sluglessEpisodeURLLeavesFilenameDisplayName() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let url = "https://podcasts.apple.com/us?i=1000774368453"
        let outcome = try await model.addURL(url, fetcher: ExplodingFetcher())

        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName == nil)
        // `effectiveName` falls through to the synthetic filename.
        #expect(stored.effectiveName == stored.filename)
    }

    // MARK: - Defensive guard: non-podcast source

    /// A defensive guard: calling `transcribe(sourceID:)` on a non-podcast
    /// source (e.g. a local-file source) throws
    /// `SourceRefreshService.RefreshError.notRefreshable`. The View-level
    /// predicate `isSourceRefreshable(for:)` (and the
    /// `isTranscribable` predicate that delegates to
    /// `provider.supportsTranscription`) already returns `false` for
    /// non-`.applePodcast` / non-`.youtube` sources, so the button doesn't
    /// render — this test pins the model-level guard that backstops a caller
    /// bypassing the predicate (a headless API, a future wikictl verb).
    @Test func transcribeNonPodcastSourceThrowsNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A local-file source has no apple-podcast provenance.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)

        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await model.transcribe(sourceID: source.id)
        }
    }
}
