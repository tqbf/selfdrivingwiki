import Testing
import Foundation
@testable import WikiFSCore

/// Phase 4 refresh guard tests (AC.8). A snapshot source with image siblings
/// throws `RefreshError.snapshotWithImages` and does NOT append a version; a
/// website source without image siblings refreshes as today.
@MainActor
struct SnapshotRefreshGuardTests {

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

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func pngResponse(url: String) -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(
            data: pngBytes, contentType: "image/png", finalURL: URL(string: url)!)
    }

    @Test func snapshotWithImagesCannotBeRefreshed() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest a snapshot page with an image.
        let html = """
        <html><head><title>Guarded</title></head><body><article>
        <p>v1 content</p>
        <img src="images/logo.png">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/g": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/g")!),
            "https://example.com/images/logo.png": pngResponse(url: "https://example.com/images/logo.png"),
        ])
        _ = try await model.addURL("https://example.com/g", fetcher: fetcher)

        let pageID = try store.listSources().first { $0.role == .primary }!.id
        let verBefore = try store.activeContentVersion(sourceID: pageID)
        let versionBefore = try #require(verBefore)

        // Refresh must throw snapshotWithImages — no version appended.
        let refreshFetcher = MultiURLFetcher(responses: [
            "https://example.com/g": URLFetchService.FetchResponse(
                data: Data("<title>Guarded</title><body>v2</body>".utf8),
                contentType: "text/html",
                finalURL: URL(string: "https://example.com/g")!),
        ])
        await #expect(throws: SourceRefreshService.RefreshError.snapshotWithImages) {
            _ = try await model.refreshSource(pageID, fetcher: refreshFetcher)
        }

        // The active version is unchanged (no new version appended).
        let verAfter = try store.activeContentVersion(sourceID: pageID)
        let versionAfter = try #require(verAfter)
        #expect(versionAfter.id == versionBefore.id)
    }

    @Test func imagelessWebsiteSourceRefreshesNormally() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest an image-less HTML page.
        let html = "<html><head><title>Plain</title></head><body><p>v1</p></body></html>"
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/p": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/p")!),
        ])
        _ = try await model.addURL("https://example.com/p", fetcher: fetcher)

        let pageID = try store.listSources().first { $0.role == .primary }!.id
        let verBefore = try store.activeContentVersion(sourceID: pageID)
        let versionBefore = try #require(verBefore)

        // Refresh succeeds — a new version is appended.
        let refreshFetcher = MultiURLFetcher(responses: [
            "https://example.com/p": URLFetchService.FetchResponse(
                data: Data("<title>Plain</title><body>v2 updated</body>".utf8),
                contentType: "text/html",
                finalURL: URL(string: "https://example.com/p")!),
        ])
        _ = try await model.refreshSource(pageID, fetcher: refreshFetcher)

        let verAfter = try store.activeContentVersion(sourceID: pageID)
        let versionAfter = try #require(verAfter)
        #expect(versionAfter.id != versionBefore.id)
    }

    // MARK: - Refreshability gate (#218): a snapshot with image siblings hides
    // Refresh entirely (the single-source refresh guard would orphan the images).

    @Test func snapshotWithImagesIsNotRefreshableGate() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let html = """
        <html><head><title>Guarded</title></head><body><article>
        <p>v1 content</p>
        <img src="images/logo.png">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/g": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/g")!),
            "https://example.com/images/logo.png": pngResponse(url: "https://example.com/images/logo.png"),
        ])
        _ = try await model.addURL("https://example.com/g", fetcher: fetcher)

        let pageID = try store.listSources().first { $0.role == .primary }!.id
        #expect(model.isSourceRefreshable(for: pageID) == false)
    }

    @Test func imagelessWebsiteSourceIsRefreshableGate() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let html = "<html><head><title>Plain</title></head><body><p>v1</p></body></html>"
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/p": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://example.com/p")!),
        ])
        _ = try await model.addURL("https://example.com/p", fetcher: fetcher)

        let pageID = try store.listSources().first { $0.role == .primary }!.id
        #expect(model.isSourceRefreshable(for: pageID) == true)
    }
}
