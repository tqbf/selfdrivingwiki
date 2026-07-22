import Foundation
import Testing
@testable import WikiFSCore

/// Verifies the window-wide drop routing (#163): an `http(s)` URL dragged from
/// a browser, and a `.webloc` shortcut that resolves to one, flow through the
/// "Add from URL" fetch path (`addURL` → HTML bytes preserved as the source
/// blob, issue #599; the markdown sidecar is NO LONGER written at ingest as
/// of issue #799 PR3 — the user triggers extraction via the Extract button),
/// while genuine local files still ingest as raw bytes (`addFiles`).
/// Uses a fake fetcher — no real network.
@MainActor
struct WikiStoreModelDropRoutingTests {

    struct FakeFetcher: URLFetchService.URLResourceFetcher {
        let response: URLFetchService.FetchResponse
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-droproute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Write a real `.webloc` plist (XML) wrapping `urlString` and return its URL.
    private func writeWebloc(in dir: URL, named: String, urlString: String) throws -> URL {
        let fileURL = dir.appendingPathComponent("\(named).webloc")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": urlString], format: .xml, options: 0)
        try data.write(to: fileURL)
        return fileURL
    }

    /// Write a plain local file and return its URL.
    private func writeLocalFile(in dir: URL, named: String, contents: String) throws -> URL {
        let fileURL = dir.appendingPathComponent(named)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    @Test func weblocRoutesThroughURLIngestAsRawHTML() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-droproute-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webloc = try writeWebloc(
            in: dir, named: "Link",
            urlString: "https://example.com/article")

        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<title>Article</title><body><p>Body.</p></body>".utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/article")!))

        await model.addDroppedURLs([webloc], fetcher: fetcher)
        model.reloadFromStore()

        // Issue #599 + #799 PR3: routed through `addURL` → HTML bytes preserved
        // as the source blob (filename `Article.html`). The extracted-markdown
        // sidecar is NO LONGER written at ingest (PR3 removed the auto-extraction;
        // the user triggers extraction via the Extract button from PR2).
        // NOT the raw plist bytes of the `.webloc`.
        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "Article.html")
        let id = model.sources.first!.id
        let bytes = try store.sourceContent(id: id)
        // The source blob IS the original HTML (not the markdown "Body.",
        // and not the raw `.webloc` plist bytes).
        #expect(String(data: bytes, encoding: .utf8) == "<title>Article</title><body><p>Body.</p></body>")
        // PR3 AC.9: no markdown sidecar — `source_markdown_versions` for this
        // source is empty until the user clicks Extract.
        #expect(try store.processedMarkdownHead(sourceID: id) == nil,
               "PR3: dropped-URL HTML ingest must NOT auto-extract markdown")
    }

    @Test func remoteHTTPURLRoutesThroughURLIngest() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<title>Page</title><body><h1>Hi</h1></body>".utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/page")!))

        await model.addDroppedURLs(
            [URL(string: "https://example.com/page")!],
            fetcher: fetcher)
        model.reloadFromStore()

        #expect(model.sources.count == 1)
        // Issue #599: HTML bytes preserved, filename ends in `.html` (not `.md`).
        #expect(model.sources.first?.filename == "Page.html")
    }

    @Test func localFileStillIngestsAsRawBytes() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-droproute-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try writeLocalFile(in: dir, named: "notes.txt", contents: "plain text body")

        await model.addDroppedURLs([file], fetcher: FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: nil, finalURL: URL(string: "https://unused.example")!)))
        model.reloadFromStore()

        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "notes.txt")
        let id = model.sources.first!.id
        #expect(String(data: try store.sourceContent(id: id), encoding: .utf8) == "plain text body")
    }

    @Test func mixedBatchRoutesEachURLCorrectly() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-droproute-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webloc = try writeWebloc(
            in: dir, named: "Web",
            urlString: "https://example.com/web")
        let txt = try writeLocalFile(in: dir, named: "doc.txt", contents: "file bytes")

        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<title>Web</title><body><p>Web body.</p></body>".utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/web")!))

        await model.addDroppedURLs([webloc, txt], fetcher: fetcher)
        model.reloadFromStore()

        let names = model.sources.map(\.filename).sorted()
        // Issue #599 + #799 PR3: HTML routed through `addURL` → filename ends
        // in `.html` (the original HTML bytes are preserved as the source blob;
        // no extracted-markdown sidecar is written at ingest post-PR3).
        #expect(names == ["Web.html", "doc.txt"])
    }

    @Test func unresolvableWeblocIsSkippedNotIngestedAsBytes() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-droproute-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A .webloc whose plist has no URL key — must NOT be ingested as raw bytes.
        let badWebloc = dir.appendingPathComponent("Broken.webloc")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Foo": "bar"], format: .xml, options: 0)
        try data.write(to: badWebloc)

        await model.addDroppedURLs([badWebloc], fetcher: FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: nil, finalURL: URL(string: "https://unused.example")!)))

        #expect(model.sources.isEmpty)
    }
}
