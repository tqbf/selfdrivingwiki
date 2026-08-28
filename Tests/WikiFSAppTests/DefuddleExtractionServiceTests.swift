#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests reviewed Defuddle package selection and the tag-based fallback.
@Suite("Reviewed Defuddle extractor", .serialized, .timeLimit(.minutes(2)))
struct DefuddleExtractionServiceTests {
    @Test("unavailable reviewed package falls back to tag-based extraction")
    @MainActor
    func unavailablePackageFallsBackToTagBasedExtraction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("defuddle-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                DebugLog.store("Defuddle test cleanup failed: \(error)")
            }
        }

        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "defuddle-fallback"))
        let model = WikiStoreModel(store: store)
        let html = "<html><head><title>Fallback</title></head><body><article><p>Hello from the fallback.</p></article></body></html>"
        let source = try store.addSource(filename: "fallback.html", data: Data(html.utf8))

        let version = await model.extractHtml(for: source.id, backend: .defuddle)
        let head = try #require(version)
        #expect(head.technique == "html-to-markdown")
        #expect(head.content.contains("Hello from the fallback."))
    }
}
#endif
