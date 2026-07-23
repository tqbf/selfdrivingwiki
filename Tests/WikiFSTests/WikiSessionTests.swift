#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// `WikiSession` tests: per-session store lifecycle, vacuum state, search
/// upgrade, and per-session launcher/gate isolation. Each session opens its own
/// DB over an injected temp dir, so these run hermetically with no App Group
/// access.
@MainActor
struct WikiSessionTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Helper: create a registry + bootstrap + return the active descriptor for
    /// a freshly seeded wiki.
    private func makeSeededRegistry(dir: URL) -> WikiRegistryClient {
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        return registry
    }

    // MARK: - Store lifecycle

    @Test func testSessionOpensStoreWithEventBus() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptor = registry.wikis.first!
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })

        let session = WikiSession(
            wikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        #expect(session.wikiID == descriptor.id)
        #expect(session.store.eventBus != nil)
        #expect(session.store.eventBus?.wikiID == descriptor.id)
    }

    // MARK: - Per-session launcher isolation

    @Test func testSessionCreatesPerSessionLaunchers() {
        let dirA = tempDirectory()
        let dirB = tempDirectory()
        let registryA = makeSeededRegistry(dir: dirA)
        let registryB = makeSeededRegistry(dir: dirB)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dirA,
            localExtractorFactory: { StubExtractor() })

        let sessionA = WikiSession(
            wikiID: registryA.wikis.first!.id,
            descriptor: registryA.wikis.first!,
            containerDirectory: dirA,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())
        let sessionB = WikiSession(
            wikiID: registryB.wikis.first!.id,
            descriptor: registryB.wikis.first!,
            containerDirectory: dirB,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        // Two sessions have distinct AgentLauncher instances.
        #expect(sessionA.agentLauncher !== sessionB.agentLauncher)
        // (Chat is daemon-hosted after Phase C4 — no per-session chat launcher.)
        // Two sessions have distinct GenerationGate instances.
        #expect(sessionA.generationGate !== sessionB.generationGate)
    }

    // MARK: - Per-session gate independence (structural — AC5)

    /// Two sessions have separate gates. A held gate on session A does not
    /// block session B (structural — verifies distinct gate instances; a full
    /// async concurrency test is deferred to the multi-window phase).
    @Test func testPerSessionGateIsIndependent() async {
        let dirA = tempDirectory()
        let dirB = tempDirectory()
        let registryA = makeSeededRegistry(dir: dirA)
        let registryB = makeSeededRegistry(dir: dirB)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dirA,
            localExtractorFactory: { StubExtractor() })

        let sessionA = WikiSession(
            wikiID: registryA.wikis.first!.id,
            descriptor: registryA.wikis.first!,
            containerDirectory: dirA,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())
        let sessionB = WikiSession(
            wikiID: registryB.wikis.first!.id,
            descriptor: registryB.wikis.first!,
            containerDirectory: dirB,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        // Acquire a slot on session A's gate.
        let acquiredA = await sessionA.generationGate.acquire(.ingest)
        #expect(acquiredA)
        // Session B's gate is a separate instance — it must still have zero
        // active count for the ingest lane.
        #expect(sessionB.generationGate.activeCount(for: .ingest) == 0)
        // (Not asserting acquire on B here since it would require releasing A
        // after; the structural point is that B's gate is untouched by A.)
        if acquiredA { sessionA.generationGate.release(.ingest) }
    }

    // MARK: - Vacuum state

    @Test func testVacuumPreviewSetsReportAndApplyClearsIt() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let session = WikiSession(
            wikiID: registry.wikis.first!.id,
            descriptor: registry.wikis.first!,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        session.previewVacuumAll()
        let report = session.pendingVacuumAll
        #expect(report != nil)
        #expect(report?.blobs.orphanCount == 0)
        #expect(report?.activities.orphanCount == 0)
        #expect(report?.isEmpty == true)

        session.applyVacuumAll()
        #expect(session.pendingVacuumAll == nil)
    }

    @Test func testBlobVacuumPreviewSetsReportAndApplyClearsIt() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let session = WikiSession(
            wikiID: registry.wikis.first!.id,
            descriptor: registry.wikis.first!,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        session.previewBlobVacuum()
        let report = session.pendingBlobVacuum
        #expect(report != nil)
        #expect(report?.orphanCount == 0)
        #expect(report?.bytesReclaimed == 0)
        #expect(report?.applied == false)

        session.applyBlobVacuum()
        #expect(session.pendingBlobVacuum == nil)
    }

    // MARK: - Search index upgrade (safe no-op without embedder)

    @Test func testUpgradeSearchIndexIsSafeNoOp() async {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let session = WikiSession(
            wikiID: registry.wikis.first!.id,
            descriptor: registry.wikis.first!,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try! makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())

        // No app bundle → no MiniLM model → upgradeSearchIndex is a safe no-op.
        await session.upgradeSearchIndex()
        // The store still works — no crash, no hang.
        #expect(session.store.eventBus != nil)
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
        wikiID: String, sourceID: PageID, backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? { nil }
    func persistExtraction(
        wikiID: String, sourceID: PageID, markdown: String,
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
#endif // os(macOS)
