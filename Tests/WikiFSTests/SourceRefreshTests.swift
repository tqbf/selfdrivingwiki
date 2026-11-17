import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Phase 3b refresh semantics, now exercised through the DAEMON refresh arm
/// (P4.3 workload migration): the app's inline `refreshSource` pipeline is
/// gone — the daemon's `DaemonQueueExtractionProvider.resolveSourceRefresh`
/// re-materializes the source's provider and
/// `QueueFormatRoute.persistRefresh` appends the content version. Covers
/// website refresh (content version append) and non-refreshable rejection —
/// via the same injected fakes the inline tests used.
@MainActor
struct SourceRefreshTests {

    /// A controllable fake fetcher: returns different responses on successive
    /// calls (swap the `response` between refreshes to simulate content change).
    final class SwapFetcher: URLFetchService.URLResourceFetcher, @unchecked Sendable {
        var response: URLFetchService.FetchResponse
        init(_ response: URLFetchService.FetchResponse) { self.response = response }
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// The daemon refresh arm under test: the provider resolves the refresh
    /// from the stored origin and persists the fresh content version.
    private func makeRefreshProvider(
        store: GRDBWikiStore,
        fetcher: URLFetchService.URLResourceFetcher
    ) -> DaemonQueueExtractionProvider {
        DaemonQueueExtractionProvider(
            extractionServices: UnavailableExtractionServices(),
            storeResolver: { _ in store },
            refreshFetcher: fetcher)
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

        // Swap to v2 and refresh through the DAEMON arm.
        fetcher.response = htmlResponse(
            "<html><head><title>Test</title></head><body>v2 content</body></html>",
            url: "https://example.com/article")
        let provider = makeRefreshProvider(store: store, fetcher: fetcher)
        let resolution = try #require(await provider.resolveSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id))
        guard case .refresh(let refresh) = resolution else {
            Issue.record("expected a refresh resolution")
            return
        }
        let outcome = try await refresh.fetch { _ in }
        _ = try await provider.persistSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id, outcome: outcome)

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

    @Test func websiteRefreshPreservesDeclaredMIMEHints() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = SwapFetcher(URLFetchService.FetchResponse(
            data: Data([0x00, 0x01, 0x02]),
            contentType: "application/x-refresh-test; version=1",
            finalURL: URL(string: "https://example.com/download")!))

        _ = try await model.addURL("https://example.com/download", fetcher: fetcher)
        let source = try #require(try store.listSources().first)
        let provider = makeRefreshProvider(store: store, fetcher: fetcher)
        let resolution = try #require(await provider.resolveSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id))
        guard case .refresh(let refresh) = resolution else {
            Issue.record("expected a refresh resolution")
            return
        }
        let outcome = try await refresh.fetch { _ in }
        _ = try await provider.persistSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id, outcome: outcome)

        let refreshed = try #require(try store.listSources().first { $0.id == source.id })
        let activeVersion = try #require(try store.contentVersionHistory(sourceID: source.id).first)
        #expect(refreshed.mimeType == "application/x-refresh-test")
        #expect(activeVersion.mimeType == "application/x-refresh-test")
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
        // unchanged"). The DAEMON arm drives the write.
        let provider = makeRefreshProvider(store: store, fetcher: fetcher)
        let resolution = try #require(await provider.resolveSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id))
        guard case .refresh(let refresh) = resolution else {
            Issue.record("expected a refresh resolution")
            return
        }
        let outcome = try await refresh.fetch { _ in }
        _ = try await provider.persistSourceRefresh(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id, outcome: outcome)
        let history = try store.contentVersionHistory(sourceID: source.id)
        #expect(history.count == 2)
    }

    // MARK: - AC.6: Non-refreshable sources

    @Test func localFileSourceIsNotRefreshable() async throws {
        let store = try tempStore()
        // A local-file source has no URL to re-fetch.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            externalItemKey: nil, externalItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)

        let service = SourceRefreshService(fetcher: SwapFetcher(htmlResponse(
            "<html></html>", url: "https://example.com")))
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await service.materialize(origin: origin)
        }
    }

    // MARK: - AC.5: Podcast refresh routes through the queue

    /// The Apple TTML packaging: BOTH podcast refresh arms route through the
    /// extraction queue's package routes. The refresh arm on an Apple episode
    /// source throws `.transcriptQueueRequired` (the caller enqueues the
    /// transcript job), and the queue's installed-package adapter preserves
    /// the v1 lineage via the initial source-version link (asserted by the
    /// daemon queue provider tests). This test pins the service-level
    /// contract and the refreshability predicate, which derives from the
    /// package ROUTE — not from signing-helper presence (a missing helper
    /// keeps the route usable through the package's RSS fallback).
    @Test func applePodcastRefreshRequiresQueueEnqueueAndRouteAvailability() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest — byteless only, no transcript.
        let url = "https://podcasts.apple.com/us/podcast/test/id1?i=100"
        _ = try await model.addURL(
            url, fetcher: SwapFetcher(htmlResponse("", url: "https://x")))
        let source = try #require(try store.listSources().first)
        #expect(try store.processedMarkdownHead(sourceID: source.id) == nil)

        // Refresh MUST direct the caller to the extraction queue — and write
        // nothing itself. The DAEMON arm carries the same typed rejection.
        let service = SourceRefreshService(fetcher: SwapFetcher(htmlResponse("", url: "https://x")))
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        await #expect(throws: SourceRefreshService.RefreshError.transcriptQueueRequired) {
            _ = try await service.materialize(origin: origin)
        }
        #expect(try store.processedMarkdownHead(sourceID: source.id) == nil)

        // Availability comes from the route, not helper presence: an Apple
        // source is refreshable (transcribable) on every build.
        #expect(await model.isSourceRefreshable(for: source.id) == true)
    }

    // MARK: - Refreshability gate (#218): the detail view should only offer
    // Refresh when the refresh job would actually succeed.

    @Test func websiteSourceIsRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = SwapFetcher(htmlResponse(
            "<html><body>plain</body></html>", url: "https://example.com/a"))
        _ = try await model.addURL("https://example.com/a", fetcher: fetcher)
        let source = try #require(try store.listSources().first { $0.role == .primary })
        #expect(await model.isSourceRefreshable(for: source.id) == true)
    }

    @Test func localFileSourceIsNotRefreshableGate() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A local-file source has no URL to re-fetch.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            externalItemKey: nil, externalItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)
        #expect(await model.isSourceRefreshable(for: source.id) == false)
    }
}
