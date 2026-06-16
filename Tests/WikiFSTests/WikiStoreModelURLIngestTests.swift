import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.ingestURL` lands a fetched resource through the SAME
/// store path as drag-ingest, so it appears under `ingestedFiles` immediately and
/// is byte-correct. Uses a fake fetcher — no real network.
@MainActor
struct WikiStoreModelURLIngestTests {

    struct FakeFetcher: URLIngestService.URLResourceFetcher {
        let response: URLIngestService.FetchResponse
        func fetch(_ url: URL) async throws -> URLIngestService.FetchResponse { response }
    }

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-urlingest-\(UUID().uuidString)", isDirectory: true)
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

        let outcome = try await model.ingestURL("example.com/doc", fetcher: fetcher)

        #expect(outcome.kind == .htmlConverted)
        #expect(outcome.filename == "My Doc.md")
        #expect(model.ingestedFiles.count == 1)
        #expect(model.ingestedFiles.first?.filename == "My Doc.md")
        #expect(model.ingestedFiles.first?.ext == "md")
        #expect(didSignal)

        // Content is the converted markdown.
        let id = model.ingestedFiles.first!.id
        let bytes = try store.ingestedFileContent(id: id)
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

        let outcome = try await model.ingestURL("https://example.com/files/paper.pdf", fetcher: fetcher)
        #expect(outcome.kind == .pdf)
        #expect(model.ingestedFiles.first?.filename == "paper.pdf")
        let id = model.ingestedFiles.first!.id
        #expect(try store.ingestedFileContent(id: id) == pdf)  // byte-identical
    }

    @Test func errorLeavesListUnchanged() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data(), contentType: "text/html",
            finalURL: URL(string: "https://example.com")!))
        await #expect(throws: URLIngestService.IngestError.empty) {
            try await model.ingestURL("https://example.com", fetcher: fetcher)
        }
        #expect(model.ingestedFiles.isEmpty)
    }
}
