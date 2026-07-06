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

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-podcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
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
}
#endif
