#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests reviewed Defuddle package selection and the tag-based fallback.
@Suite("Reviewed Defuddle extractor", .serialized, .timeLimit(.minutes(2)))
struct DefuddleExtractionServiceTests {
    @Test("defuddle backend without an installed package adapter yields nothing (package-only)")
    @MainActor
    func defuddleWithoutAdapterYieldsNothing() async throws {
        // Since #1167 each backend runs only through its injected package
        // adapter; there is no silent cross-backend fallback (the DOCX path's
        // package-only shape). A defuddle request with no installed adapter
        // produces no version rather than degrading to the tag-based
        // extractor.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("defuddle-noadapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                DebugLog.store("Defuddle test cleanup failed: \(error)")
            }
        }

        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "defuddle-noadapter"))
        let model = WikiStoreModel(store: store)
        let html = "<html><head><title>Fallback</title></head><body><article><p>Hello from the fallback.</p></article></body></html>"
        let source = try store.addSource(filename: "fallback.html", data: Data(html.utf8))

        let version = await model.extractHtml(for: source.id, backend: .defuddle)
        #expect(version == nil)
    }

    @Test("tag-based backend extracts through html-to-markdown")
    @MainActor
    func tagBasedBackendExtracts() async throws {
        // The explicit tag-based backend still runs the built-in extractor.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("defuddle-tagbased-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                DebugLog.store("Defuddle test cleanup failed: \(error)")
            }
        }

        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "defuddle-tagbased"))
        let model = WikiStoreModel(store: store)
        let html = "<html><head><title>Fallback</title></head><body><article><p>Hello from the fallback.</p></article></body></html>"
        let source = try store.addSource(filename: "fallback.html", data: Data(html.utf8))

        let version = await model.extractHtml(for: source.id, backend: .tagBased)
        let head = try #require(version)
        #expect(head.technique == "html-to-markdown")
        #expect(head.content.contains("Hello from the fallback."))
    }
}
#endif
