import Foundation
import Testing
@testable import WikiFSCore

/// Phase 3b tests: `SourceRefreshService` + `WikiStoreModel.refreshSource`.
/// Covers website refresh (content version append), podcast refresh (derived
/// markdown append), and non-refreshable rejection — all via injected fakes.
@MainActor
struct SourceRefreshTests {

    /// A controllable fake fetcher: returns different responses on successive
    /// calls (swap the `response` between refreshes to simulate content change).
    final class SwapFetcher: URLFetchService.URLResourceFetcher, @unchecked Sendable {
        var response: URLFetchService.FetchResponse
        init(_ response: URLFetchService.FetchResponse) { self.response = response }
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func htmlResponse(_ body: String, url: String) -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(
            data: Data(body.utf8), contentType: "text/html; charset=utf-8",
            finalURL: URL(string: url)!)
    }

    // MARK: - AC.3: Website refresh appends a content version

    @Test func websiteRefreshAppendsNewContentVersion() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = SwapFetcher(htmlResponse(
            "<html><head><title>Test</title></head><body>v1</body></html>",
            url: "https://example.com/article"))

        // Ingest v1.
        _ = try await model.addURL("https://example.com/article", fetcher: fetcher)
        let sources = try store.listSources()
        let source = try #require(sources.first)
        let historyBefore = try store.contentVersionHistory(sourceID: source.id)
        #expect(historyBefore.count == 1)

        // Swap to v2 and refresh.
        fetcher.response = htmlResponse(
            "<html><head><title>Test</title></head><body>v2 content</body></html>",
            url: "https://example.com/article")
        _ = try await model.refreshSource(source.id, fetcher: fetcher)

        // A new content version was appended.
        let historyAfter = try store.contentVersionHistory(sourceID: source.id)
        #expect(historyAfter.count == 2)
        // HEAD bytes match v2.
        let head = try store.sourceContent(id: source.id)
        #expect(String(data: head, encoding: .utf8)?.contains("v2 content") == true)
        // Origin URL preserved.
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "website")
        #expect(origin.plan == "https://example.com/article")
    }

    @Test func websiteRefreshUnchangedBytesStillAppendsVersion() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let response = htmlResponse(
            "<html><body>same content</body></html>", url: "https://example.com/page")
        let fetcher = SwapFetcher(response)

        _ = try await model.addURL("https://example.com/page", fetcher: fetcher)
        let source = try #require(try store.listSources().first)

        // Refresh with identical bytes — still appends a version ("checked,
        // unchanged").
        _ = try await model.refreshSource(source.id, fetcher: fetcher)
        let history = try store.contentVersionHistory(sourceID: source.id)
        #expect(history.count == 2)
    }

    // MARK: - AC.6: Non-refreshable sources

    @Test func localFileSourceIsNotRefreshable() async throws {
        let store = try tempStore()
        // A local-file source has no URL to re-fetch.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)

        let service = SourceRefreshService(fetcher: SwapFetcher(htmlResponse(
            "<html></html>", url: "https://example.com")))
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await service.materialize(origin: origin)
        }
    }

    // MARK: - AC.5: Podcast refresh (guarded)

    #if PODCAST_TRANSCRIPTS
    @Test func podcastRefreshAppendsDerivedMarkdown() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Seed a byteless podcast source via addURL.
        final class FakePodcast: PodcastTranscriptFetching, @unchecked Sendable {
            var markdown: String
            init(_ markdown: String) { self.markdown = markdown }
            func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript {
                PodcastTranscript(
                    episodeID: episode.id, markdown: markdown,
                    filename: "podcast-\(episode.id)-transcript.md")
            }
        }
        let podcast = FakePodcast("SPEAKER_1: v1 transcript.")
        let url = "https://podcasts.apple.com/us/podcast/test/id1?i=100"
        _ = try await model.addURL(url, fetcher: SwapFetcher(htmlResponse("", url: "https://x")), podcastFetcher: podcast)
        let source = try #require(try store.listSources().first)

        // v1 markdown head.
        let headBefore = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(headBefore.content == "SPEAKER_1: v1 transcript.")

        // Swap transcript and refresh (inject the fake podcast fetcher).
        podcast.markdown = "SPEAKER_1: v2 transcript."
        _ = try await model.refreshSource(source.id, fetcher: SwapFetcher(htmlResponse("", url: "https://x")), podcastFetcher: podcast)

        // A new derived markdown version was appended.
        let headAfter = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(headAfter.content == "SPEAKER_1: v2 transcript.")
    }
    #endif

    // MARK: - Refreshability gate (#218): the detail view should only offer
    // Refresh when `refreshSource(_:)` would actually succeed.

    @Test func websiteSourceIsRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = SwapFetcher(htmlResponse(
            "<html><body>plain</body></html>", url: "https://example.com/a"))
        _ = try await model.addURL("https://example.com/a", fetcher: fetcher)
        let source = try #require(try store.listSources().first { $0.role == .primary })
        #expect(model.isSourceRefreshable(for: source.id) == true)
    }

    @Test func localFileSourceIsNotRefreshableGate() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A local-file source has no URL to re-fetch.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)
        #expect(model.isSourceRefreshable(for: source.id) == false)
    }
}
