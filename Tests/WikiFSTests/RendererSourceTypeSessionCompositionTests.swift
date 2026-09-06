import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFSEngine

/// AC.3 (session leg): the child-session boot seam fans the validated
/// catalog out to every live session through `SessionManager`, matching the
/// `registeredExtractionInputs` refresh shape.
@Suite("Renderer source-type session composition", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct RendererSourceTypeSessionCompositionTests {
    @Test func sessionFanOutReceivesCatalog() throws {
        // The fan-out seam child-session boot uses: the plugin assigns the
        // validated preparation catalog to the model at boot, and
        // SessionManager fans it out to every live session. The
        // SessionsPlugin boot path itself is covered by app-composition
        // tests; this test pins the fan-out contract.
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let first = try #require(registry.wikis.first)
        let second = WikiDescriptor.make(displayName: "Second Wiki")
        _ = try StoreBackend.current.makeStore(
            databaseURL: dir.appendingPathComponent("\(second.id.rawValue).sqlite"))

        let firstSession = try manager.session(for: first.id, descriptor: first)
        let secondSession = try manager.session(for: second.id, descriptor: second)
        #expect(manager.sessions.count == 2)

        let catalog = MermaidSessionFixtures.catalog
        manager.refreshRegisteredRendererSourceTypesForLiveSessions(catalog)

        #expect(firstSession.store.registeredRendererSourceTypes == catalog)
        #expect(secondSession.store.registeredRendererSourceTypes == catalog)
    }

    // MARK: - Fixtures (mirrors SessionManagerTests)

    private func tempDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("source-type-sessions-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSeededRegistry(dir: URL) -> WikiRegistryClient {
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        return registry
    }

    private func makeSessionManager(dir: URL) -> SessionManager {
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let queueEngine = try! makeTestQueueEngine()
        let provider = StubExtractionProvider()
        return SessionManager(
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: queueEngine,
            extractionProvider: provider,
            pdf2mdScriptPathResolver: { nil },
            testSessionFactory: { wikiID, descriptor in
                try ProfileWikiSession(
                    testFixtureWikiID: wikiID,
                    descriptor: descriptor,
                    containerDirectory: dir,
                    extractionCoordinator: coordinator,
                    queueEngine: queueEngine,
                    extractionProvider: provider)
            })
    }
}

/// A minimal stub `MarkdownExtractor` for tests — returns empty content.
@MainActor
private final class StubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

/// A no-op `QueueExtractionProvider` for tests — returns nil (no extraction).
private struct StubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(
        wikiID: WikiID, sourceID: SourceID, backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? { nil }
    func persistExtraction(
        wikiID: WikiID, sourceID: SourceID, markdown: String,
        backend: ExtractionBackend, modelVersion: String?,
        technique: String?
    ) async throws {}
}

/// Creates a `QueueEngine` backed by an in-memory store + stub provider.
private func makeTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = StubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(
        provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}

enum MermaidSessionFixtures {
    static let catalog: RegisteredRendererSourceTypes = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try! JSONDecoder().decode(
            RendererManifest.self,
            from: try! Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        return RegisteredRendererSourceTypes(descriptors: manifest.descriptors)
    }()
}
