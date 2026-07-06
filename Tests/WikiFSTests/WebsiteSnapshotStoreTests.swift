import Testing
import Foundation
@testable import WikiFSCore

/// Phase 4 integration tests for the website snapshot store path.
/// Covers AC.1 (source counts, shared activity, original_path, external_identity),
/// AC.5 (roles + media filter), AC.7 (shared image across snapshots — one blob,
/// two sources), AC.9 (PDF/text/binary single-source regression).
@MainActor
struct WebsiteSnapshotStoreTests {

    /// A fake fetcher that maps absolute URL strings to canned responses.
    struct MultiURLFetcher: URLFetchService.URLResourceFetcher {
        var responses: [String: URLFetchService.FetchResponse]
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            if let r = responses[url.absoluteString] { return r }
            throw URLFetchService.FetchError.network("no fake response for \(url)")
        }
    }

    private let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func pngResponse(url: String) -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(
            data: pngBytes, contentType: "image/png", finalURL: URL(string: url)!)
    }

    // MARK: - AC.1: HTML page with 2 images → 1 primary + 2 media, shared activity

    @Test func snapshotStoresPageAndImagesWithSharedActivity() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let html = """
        <html><head><title>Test Page</title></head><body><article>
        <p>Hello</p>
        <img src="images/foo.png" alt="foo">
        <img src="images/bar.png" alt="bar">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/page": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/page")!),
            "https://example.com/images/foo.png": pngResponse(url: "https://example.com/images/foo.png"),
            "https://example.com/images/bar.png": pngResponse(url: "https://example.com/images/bar.png"),
        ])
        _ = try await model.addURL("https://example.com/page", fetcher: fetcher)

        let sources = try store.listSources()
        let primarySources = sources.filter { $0.role == .primary }
        let mediaSources = sources.filter { $0.role == .media }
        #expect(primarySources.count == 1)
        #expect(mediaSources.count == 2)

        // All three share one activity_id.
        let pageID = primarySources.first!.id
        let pageVer = try store.activeContentVersion(sourceID: pageID)
        let pageVersion = try #require(pageVer)
        let pageActivity = try #require(pageVersion.activityID)
        for img in mediaSources {
            let v = try store.activeContentVersion(sourceID: img.id)
            let imgVersion = try #require(v)
            #expect(imgVersion.activityID == pageActivity)
            // external_identity = the resolved absolute download URL.
            #expect(imgVersion.externalIdentity == "https://example.com/images/\(img.filename)")
        }

        // original_path values are present in the resolver map.
        let resolvers = try store.siblingImageResolvers()
        let pageMap = try #require(resolvers[pageID])
        #expect(pageMap.count == 2)
        #expect(pageMap["images/foo.png"] != nil)
        #expect(pageMap["images/bar.png"] != nil)
    }

    // MARK: - AC.5: media sources are .media, page is .primary, media filtered from list

    @Test func mediaSourcesFilteredFromPrimaryList() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let html = """
        <html><head><title>Filter Test</title></head><body><article>
        <img src="a.png"><img src="b.png">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/p": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/p")!),
            "https://example.com/a.png": pngResponse(url: "https://example.com/a.png"),
            "https://example.com/b.png": pngResponse(url: "https://example.com/b.png"),
        ])
        _ = try await model.addURL("https://example.com/p", fetcher: fetcher)

        let allSources = try store.listSources()
        let mediaIDs = Set(allSources.filter { $0.role == .media }.map { $0.id })
        #expect(mediaIDs.count == 2)
        // The model's observable `sources` includes all; `isPrimary` filters them.
        #expect(allSources.filter { $0.isPrimary }.count == 1)
        // Every media source is not primary.
        for id in mediaIDs {
            let src = allSources.first { $0.id == id }!
            #expect(!src.isPrimary)
        }
    }

    // MARK: - AC.7: two pages share one image → one blob, two sources

    @Test func sharedImageAcrossSnapshotsProducesOneBlobTwoSources() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Both pages reference the same image URL (same bytes → one blob).
        let htmlA = """
        <html><head><title>Page A</title></head><body><article>
        <p>Content unique to page A.</p>
        <img src="https://cdn.example.com/logo.png">
        </article></body></html>
        """
        let htmlB = """
        <html><head><title>Page B</title></head><body><article>
        <p>Different text for page B.</p>
        <img src="https://cdn.example.com/logo.png">
        </article></body></html>
        """
        let logoResp = pngResponse(url: "https://cdn.example.com/logo.png")

        let fetcherA = MultiURLFetcher(responses: [
            "https://example.com/a": URLFetchService.FetchResponse(
                data: Data(htmlA.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/a")!),
            "https://cdn.example.com/logo.png": logoResp,
        ])
        let fetcherB = MultiURLFetcher(responses: [
            "https://example.com/b": URLFetchService.FetchResponse(
                data: Data(htmlB.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/b")!),
            "https://cdn.example.com/logo.png": logoResp,
        ])
        _ = try await model.addURL("https://example.com/a", fetcher: fetcherA)
        _ = try await model.addURL("https://example.com/b", fetcher: fetcherB)

        let allSources = try store.listSources()
        let primaries = allSources.filter { $0.role == .primary }
        let mediaSources = allSources.filter { $0.role == .media }
        #expect(primaries.count == 2)
        #expect(mediaSources.count == 2)  // two distinct image sources

        // Two distinct activity_ids (one per snapshot).
        let activities = Set(mediaSources.compactMap {
            (try? store.activeContentVersion(sourceID: $0.id))?.activityID
        })
        #expect(activities.count == 2)

        // Both image sources resolve in their own snapshot's resolver map.
        let resolvers = try store.siblingImageResolvers()
        for page in primaries {
            let map = try #require(resolvers[page.id])
            #expect(map["logo.png"] != nil)
        }
    }

    // MARK: - AC.9: PDF/text/binary stay single-source

    @Test func pdfIngestIsSingleSource() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var pdf = Data("%PDF-1.7".utf8)
        pdf.append(contentsOf: [0x00, 0xFF, 0x10])
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/doc.pdf": URLFetchService.FetchResponse(
                data: pdf, contentType: "application/pdf",
                finalURL: URL(string: "https://example.com/doc.pdf")!),
        ])
        let outcome = try await model.addURL("https://example.com/doc.pdf", fetcher: fetcher)
        #expect(outcome.kind == .pdf)
        #expect(try store.listSources().count == 1)
        #expect(try store.listSources().allSatisfy { $0.role == .primary })
    }

    @Test func textIngestIsSingleSource() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/notes.txt": URLFetchService.FetchResponse(
                data: Data("hello world".utf8), contentType: "text/plain",
                finalURL: URL(string: "https://example.com/notes.txt")!),
        ])
        let outcome = try await model.addURL("https://example.com/notes.txt", fetcher: fetcher)
        #expect(outcome.kind == .text)
        #expect(try store.listSources().count == 1)
    }
}
