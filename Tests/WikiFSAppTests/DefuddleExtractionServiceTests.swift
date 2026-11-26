#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine
@testable import wikid

/// Reviewed Defuddle package selection and the tag-based floor, exercised
/// through the DAEMON format route (P4.3 workload migration): the queue's
/// `resolveFormatRoute` recognizes the registration claim, prepares the
/// typed adapter, and `QueueFormatRoute.persistHtml` writes the version.
@Suite("Reviewed Defuddle extractor", .serialized, .timeLimit(.minutes(2)))
struct DefuddleExtractionServiceTests {

    /// Extraction services whose HTML route resolves the tag-based floor
    /// (no Defuddle package installed in the fixture).
    private struct TagFloorServices: ExtractionServices {
        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareHTML(
            backendOverride: HtmlExtractionBackend?
        ) async throws -> any HtmlMarkdownExtractor {
            // No defuddle package in this fixture: the defuddle selection
            // fails closed — no substitution.
            if backendOverride == .defuddle {
                throw ExtractionServicesError.unavailable
            }
            return TagBasedHtmlExtractor()
        }

        func prepareDOCX() async throws -> any DocxMarkdownExtractor {
            throw ExtractionServicesError.unavailable
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            RegisteredExtractionInputs(claims: [.init(
                kind: .html,
                mimeTypes: ["text/html"],
                filenameExtensions: ["html", "htm"])])
        }
    }

    private func makeProvider(
        store: GRDBWikiStore,
        services: any ExtractionServices
    ) -> DaemonQueueExtractionProvider {
        DaemonQueueExtractionProvider(
            extractionServices: services,
            storeResolver: { _ in store })
    }

    private func makeStore(id: String) throws -> GRDBWikiStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("defuddle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: id))
        return store
    }

    private static let html = "<html><head><title>Fallback</title></head><body><article><p>Hello from the fallback.</p></article></body></html>"

    @Test("defuddle backend without an installed package adapter fails closed (package-only)")
    @MainActor
    func defuddleWithoutAdapterYieldsNothing() async throws {
        // Since #1167 each backend runs only through its injected package
        // adapter; there is no silent cross-backend fallback (the DOCX path's
        // package-only shape). A defuddle request with no installed adapter
        // now FAILS THE QUEUE ITEM loudly (the Activity window carries the
        // message) — a strictly stronger contract than the inline path's
        // silent nil.
        let store = try makeStore(id: "defuddle-noadapter")
        let html = Self.html
        let source = try store.addSource(filename: "fallback.html", data: Data(html.utf8))
        let provider = makeProvider(store: store, services: TagFloorServices())

        await #expect(throws: ExtractionServicesError.self) {
            try await provider.resolveFormatRoute(
                wikiID: WikiID(rawValue: "w"), sourceID: source.id,
                htmlBackendOverride: .defuddle)
        }
        // Nothing was written.
        let head = try store.processedMarkdownHead(sourceID: source.id)
        #expect(head == nil)
    }

    @Test("tag-based backend extracts through html-to-markdown")
    @MainActor
    func tagBasedBackendExtracts() async throws {
        // The explicit tag-based backend still runs the built-in extractor.
        let store = try makeStore(id: "defuddle-tagbased")
        let html = Self.html
        let source = try store.addSource(filename: "fallback.html", data: Data(html.utf8))
        let provider = makeProvider(store: store, services: TagFloorServices())

        let resolution = try #require(await provider.resolveFormatRoute(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            htmlBackendOverride: .tagBased))
        guard case .html(let htmlResolution) = resolution else {
            Issue.record("expected an HTML format-route resolution")
            return
        }
        let markdown = try await htmlResolution.extract()
        let reference = try QueueFormatRoute.persistHtml(
            store: store, sourceID: source.id, resolution: htmlResolution,
            markdown: markdown, nominateActive: false)
        let versionID = try #require(reference?.versionID)
        #expect(versionID.isEmpty == false)

        let head = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(head.technique == "html-to-markdown")
        #expect(head.content.contains("Hello from the fallback."))
    }
}
#endif
