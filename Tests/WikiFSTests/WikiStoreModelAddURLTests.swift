import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.addURL` lands a fetched resource through the SAME
/// store path as `addFiles`, so it appears under `sources` immediately and
/// is byte-correct. Uses a fake fetcher — no real network.
@MainActor
struct WikiStoreModelAddURLTests {

    struct FakeFetcher: URLIngestService.URLResourceFetcher {
        let response: URLIngestService.FetchResponse
        func fetch(_ url: URL) async throws -> URLIngestService.FetchResponse { response }
    }

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-addurl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    @Test func htmlURLLandsAsMarkdownFileInList() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var didSignal = false
        model.onPageDidChange = { didSignal = true }

        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data("<title>My Doc</title><body><h1>Heading</h1><p>Body.</p></body>".utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/doc")!))

        let outcome = try await model.addURL("example.com/doc", fetcher: fetcher)

        #expect(outcome.kind == .htmlConverted)
        #expect(outcome.filename == "My Doc.md")
        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "My Doc.md")
        #expect(model.sources.first?.ext == "md")
        #expect(didSignal)

        // Content is the converted markdown.
        let id = model.sources.first!.id
        let bytes = try store.sourceContent(id: id)
        #expect(String(data: bytes, encoding: .utf8) == "# Heading\n\nBody.")
    }

    @Test func pdfURLLandsVerbatim() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var pdf = Data("%PDF-1.7".utf8)
        pdf.append(contentsOf: [0x00, 0xFF, 0x10])
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: pdf, contentType: "application/pdf",
            finalURL: URL(string: "https://example.com/files/paper.pdf")!))

        let outcome = try await model.addURL("https://example.com/files/paper.pdf", fetcher: fetcher)
        #expect(outcome.kind == .pdf)
        #expect(model.sources.first?.filename == "paper.pdf")
        let id = model.sources.first!.id
        #expect(try store.sourceContent(id: id) == pdf)  // byte-identical
    }

    @Test func errorLeavesListUnchanged() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data(), contentType: "text/html",
            finalURL: URL(string: "https://example.com")!))
        await #expect(throws: URLIngestService.IngestError.empty) {
            try await model.addURL("https://example.com", fetcher: fetcher)
        }
        #expect(model.sources.isEmpty)
    }
}
