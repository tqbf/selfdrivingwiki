import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `BlobSchemeHandler` — the `WKURLSchemeHandler` that serves source
/// blob bytes from SQLite to the WKWebView via `wiki-blob://source/<id>`
/// (Phase 4a, AC.5).
@MainActor
struct BlobSchemeHandlerTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-blob-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// A minimal `WKURLSchemeTask` mock that captures the response + data.
    private final class MockSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var receivedResponse: URLResponse?
        var receivedData = Data()
        var didFinishCalled = false

        init(url: URL) {
            self.request = URLRequest(url: url)
            super.init()
        }

        func didReceive(_ response: URLResponse) { receivedResponse = response }
        func didReceive(_ data: Data) { receivedData.append(data) }
        func didFinish() { didFinishCalled = true }
        func didFailWithError(_ error: any Error) { /* not expected in tests */ }
    }

    @Test func servesKnownSourceBytesAndMIME() throws {
        let store = try tempStore()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])  // PNG header bytes
        let source = try store.addSource(filename: "photo.png", data: imageData,
                                         mimeType: "image/png")
        let model = WikiStoreModel(store: store)

        let handler = BlobSchemeHandler(store: model)
        let url = URL(string: "wiki-blob://source/\(source.id.rawValue)")!
        let task = MockSchemeTask(url: url)

        handler.serve(task)

        #expect(task.didFinishCalled)
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(task.receivedData == imageData)
    }

    @Test func returns404ForUnknownId() throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let handler = BlobSchemeHandler(store: model)
        let url = URL(string: "wiki-blob://source/01HNOSUCHSOURCE00000000")!
        let task = MockSchemeTask(url: url)

        handler.serve(task)

        #expect(task.didFinishCalled)
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.statusCode == 404)
        #expect(task.receivedData.isEmpty)
    }

    @Test func servesBytelessSourceAsEmpty200() throws {
        let store = try tempStore()
        // Add a source with empty data (byteless) — the store allows this.
        let source = try store.addSource(filename: "empty.txt", data: Data(),
                                         mimeType: "text/plain")
        let model = WikiStoreModel(store: store)

        let handler = BlobSchemeHandler(store: model)
        let url = URL(string: "wiki-blob://source/\(source.id.rawValue)")!
        let task = MockSchemeTask(url: url)

        handler.serve(task)

        #expect(task.didFinishCalled)
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(task.receivedData.isEmpty)
    }

    @Test func returns404ForMalformedURL() throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        let handler = BlobSchemeHandler(store: model)
        // Missing host ("source") or empty path.
        let url = URL(string: "wiki-blob:///")!
        let task = MockSchemeTask(url: url)

        handler.serve(task)

        #expect(task.didFinishCalled)
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.statusCode == 404)
    }
}
