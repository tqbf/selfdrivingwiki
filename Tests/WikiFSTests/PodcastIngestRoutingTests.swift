#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.addURL` ROUTES an Apple Podcasts episode link to
/// the transcript pipeline (not the HTML fetcher) and stores the markdown as a
/// source. Uses a fake `PodcastTranscriptFetching` + a fake HTML fetcher so we can
/// assert which path ran — no network, no private frameworks.
@MainActor
struct PodcastIngestRoutingTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-podcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Records whether it was asked for a transcript, and returns a canned one.
    final class FakePodcastFetcher: PodcastTranscriptFetching, @unchecked Sendable {
        private(set) var requestedEpisodeID: String?
        func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript {
            requestedEpisodeID = episode.id
            return PodcastTranscript(
                episodeID: episode.id,
                markdown: "SPEAKER_1: Hello from the episode.",
                filename: "\(episode.slug ?? "podcast")-\(episode.id)-transcript.md")
        }
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

    @Test func episodeURLRoutesToTranscriptPipelineAndStoresMarkdown() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        #expect(podcast.requestedEpisodeID == "1000774368453")
        #expect(outcome.kind == .podcastTranscript)
        #expect(outcome.filename == "chinatalk-1000774368453-transcript.md")

        // §11 byteless model: the source is byteless (no content bytes); the
        // transcript lives as the processed-markdown derived alternative.
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.byteSize == 0)
        // sourceContent returns empty Data for a byteless source.
        #expect(try store.sourceContent(id: stored.id).isEmpty)
        // The transcript is the processed-markdown head.
        let head = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(head.content == "SPEAKER_1: Hello from the episode.")
        // Origin provenance: apple-podcast agent + the pasted episode URL.
        let origin = try #require(try store.sourceOrigin(sourceID: stored.id))
        #expect(origin.agentName == "apple-podcast")
        #expect(origin.plan == Self.chinaTalkURL)
        #expect(origin.externalIdentity == "1000774368453")
    }

    @Test func pastingSameEpisodeTwiceDedupsAsByteless() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        _ = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        // Second paste of the same episode URL → duplicate (byteless dedup on
        // external_identity).
        await #expect(throws: WikiStoreError.self) {
            try await model.addURL(
                Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        }
        // Only one source was created.
        let sources = try store.listSources()
        #expect(sources.count == 1)
    }

    @Test func missingHelperGivesAClearError() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // No podcast fetcher available (a build without the signing helper).
        await #expect(throws: PodcastTranscriptError.self) {
            try await model.addURL(
                Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: nil)
        }
    }

    @Test func nonPodcastURLStillUsesHTMLFetcher() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // A normal URL must NOT touch the podcast path; a fetcher returning HTML
        // proves the ordinary route still runs (and the exploding podcast fetcher
        // is never consulted).
        struct HTMLFetcher: URLFetchService.URLResourceFetcher {
            func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
                URLFetchService.FetchResponse(
                    data: Data("<title>Hi</title><p>x</p>".utf8),
                    contentType: "text/html", finalURL: url)
            }
        }
        let outcome = try await model.addURL(
            "https://example.com/article", fetcher: HTMLFetcher(), podcastFetcher: nil)
        #expect(outcome.kind == .htmlConverted)
    }

    /// Phase 4b routing-precedence: an Apple Podcasts episode URL must still
    /// route to `.podcastTranscript` (apple-podcast stays FIRST) even though the
    /// new media recognizers are now wired in `addURL`. A `podcasts.apple.com`
    /// URL is not a recognized media-provider URL, but the order is pinned so a
    /// future recognizer can't accidentally shadow it.
    @Test func podcastURLStaysFirstInRoutingPrecedence() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        #expect(outcome.kind == .podcastTranscript)
        #expect(podcast.requestedEpisodeID == "1000774368453")
    }

    /// Issue #621: the source's display name must be the un-slugified episode
    /// title (written via `setSourceDisplayName`, mirroring the oEmbed title
    /// step for YouTube/Vimeo/Spotify/SoundCloud) — NOT the slugified filename
    /// `chinatalk-1000774368453-transcript.md`.
    @Test func episodeURLSetsDisplayTitleFromSlug() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

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
    /// `-transcript.md` slug filename.
    @Test func multiWordSlugResolvesTitleCasedDisplayName() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        // The issue's driving example episode URL — the slug is the entire
        // episode title as Apple generates it for an episode link.
        let url = "https://podcasts.apple.com/us/podcast/"
            + "if-you-care-about-food-you-have-to-care-about-land/"
            + "id1728932037?i=1000714478537"
        let outcome = try await model.addURL(
            url, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

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
        let podcast = FakePodcastFetcher()

        let url = "https://podcasts.apple.com/us?i=1000774368453"
        let outcome = try await model.addURL(
            url, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName == nil)
        // `effectiveName` falls through to the synthetic filename.
        #expect(stored.effectiveName == stored.filename)
    }
}
#endif
