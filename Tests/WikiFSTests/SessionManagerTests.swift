#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// `SessionManager` tests: verifies the `[wikiID: WikiSession]` cache semantics
/// — create-or-get deduplication, release-removes-from-cache, flush-all, and
/// per-session gate isolation (structural — distinct `GenerationGate`
/// instances across different wiki IDs).
///
/// Each test opens real SQLite DBs over a temp dir (no App Group access), so
/// they run hermetically.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct SessionManagerTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-sm-tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Helper: create a SessionManager over a temp dir with a stub extractor.
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
            pdf2mdScriptPathResolver: { nil })
    }

    // MARK: - session(for:descriptor:)

    @Test func testSessionForCreatesSessionWithStore() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        let session = manager.session(for: descriptor.id, descriptor: descriptor)

        #expect(session.wikiID == descriptor.id)
        #expect(session.store.eventBus != nil)
        #expect(session.store.eventBus?.wikiID == descriptor.id)
        #expect(manager.sessions.count == 1)
    }

    @Test func testSameWikiIDReturnsSameSession() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        let session1 = manager.session(for: descriptor.id, descriptor: descriptor)
        let session2 = manager.session(for: descriptor.id, descriptor: descriptor)

        // Two calls with the same wiki ID return the IDENTICAL instance.
        #expect(session1 === session2)
        #expect(manager.sessions.count == 1)
    }

    @Test func testDifferentWikiIDsReturnDistinctSessions() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor1 = registry.wikis.first!

        // Create a second wiki so we have two distinct IDs.
        let descriptor2 = WikiDescriptor.make(displayName: "Second Wiki")
        // Seed the DB file for descriptor2.
        let url2 = dir.appendingPathComponent("\(descriptor2.id).sqlite", isDirectory: false)
        _ = try? StoreBackend.current.makeStore(databaseURL: url2)

        let session1 = manager.session(for: descriptor1.id, descriptor: descriptor1)
        let session2 = manager.session(for: descriptor2.id, descriptor: descriptor2)

        // Different wiki IDs get distinct sessions.
        #expect(session1 !== session2)
        // Distinct gates (structural isolation).
        #expect(session1.generationGate !== session2.generationGate)
        #expect(manager.sessions.count == 2)
    }

    // MARK: - releaseSession(for:)

    @Test func testReleaseSessionRemovesFromCache() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        _ = manager.session(for: descriptor.id, descriptor: descriptor)
        #expect(manager.sessions[descriptor.id] != nil)

        manager.releaseSession(for: descriptor.id)

        #expect(manager.sessions[descriptor.id] == nil)
        #expect(manager.sessions.isEmpty)
    }

    @Test func testReleaseSessionFlushesPendingSaves() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        let session = manager.session(for: descriptor.id, descriptor: descriptor)
        // releaseSession should call flushPendingSaves on the store before
        // removing — we can't easily observe the flush (no public dirty flag),
        // but we verify the session is gone and no crash occurs.
        #expect(manager.sessions[descriptor.id] != nil)

        manager.releaseSession(for: descriptor.id)

        // After release, the session is gone from the cache.
        #expect(manager.sessions[descriptor.id] == nil)
        #expect(session.store.eventBus != nil) // session still alive (test holds ref)
    }

    // MARK: - flushAllSessions()

    @Test func testFlushAllSessionsFlushesAllActive() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor1 = registry.wikis.first!

        // Create a second wiki.
        let descriptor2 = WikiDescriptor.make(displayName: "Second Wiki")
        let url2 = dir.appendingPathComponent("\(descriptor2.id).sqlite", isDirectory: false)
        _ = try? StoreBackend.current.makeStore(databaseURL: url2)

        _ = manager.session(for: descriptor1.id, descriptor: descriptor1)
        _ = manager.session(for: descriptor2.id, descriptor: descriptor2)

        // flushAllSessions should flush both sessions' pending saves without
        // removing them from the cache — no crash, sessions still present.
        // (No public dirty flag to assert pre/post; the structural point is
        // both are flushed and both survive.)
        manager.flushAllSessions()

        // Both sessions are still in the cache (flush doesn't remove).
        #expect(manager.sessions.count == 2)
        #expect(manager.sessions[descriptor1.id] != nil)
        #expect(manager.sessions[descriptor2.id] != nil)
    }

    // MARK: - Per-window gate isolation (AC7)

    @Test func testPerWindowGateIsolation() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor1 = registry.wikis.first!

        // Create a second wiki.
        let descriptor2 = WikiDescriptor.make(displayName: "Second Wiki")
        let url2 = dir.appendingPathComponent("\(descriptor2.id).sqlite", isDirectory: false)
        _ = try? StoreBackend.current.makeStore(databaseURL: url2)

        let session1 = manager.session(for: descriptor1.id, descriptor: descriptor1)
        let session2 = manager.session(for: descriptor2.id, descriptor: descriptor2)

        // Two sessions have distinct GenerationGate instances.
        #expect(session1.generationGate !== session2.generationGate)
        // Active wiki IDs set reflects both sessions.
        #expect(manager.activeWikiIDs == Set([descriptor1.id, descriptor2.id]))
        // allSessions returns both.
        #expect(manager.allSessions.count == 2)
    }

    // MARK: - frontmostSession

    @Test func testFrontmostSessionResolvesFromFrontmostWikiID() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        let session = manager.session(for: descriptor.id, descriptor: descriptor)

        // No frontmost ID set yet → nil.
        #expect(manager.frontmostSession == nil)

        manager.frontmostWikiID = descriptor.id

        #expect(manager.frontmostSession === session)
    }

    // MARK: - Cross-window wiki-link navigation

    @Test func testStashPendingWikiLinkStoresAndConsumes() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!
        let url = URL(string: "wiki://page?title=Home")!

        manager.stashPendingWikiLink(descriptor.id, url: url, openInNewTab: false)

        // Stash stores the request by wiki ID.
        #expect(manager.pendingWikiLinks[descriptor.id]?.url == url)
        #expect(manager.pendingWikiLinks[descriptor.id]?.openInNewTab == false)

        // Consume retrieves and clears (one-shot).
        let consumed = manager.consumePendingWikiLink(for: descriptor.id)
        #expect(consumed?.url == url)
        #expect(consumed?.openInNewTab == false)
        #expect(manager.pendingWikiLinks[descriptor.id] == nil)
    }

    @Test func testConsumePendingWikiLinkReturnsNilWhenNothingStashed() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        // No stash → nil, no crash.
        #expect(manager.consumePendingWikiLink(for: descriptor.id) == nil)
    }

    @Test func testSessionCreationTransfersPendingWikiLinkOntoSession() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!
        let url = URL(string: "wiki://source?title=Paper")!

        // Stash a deferred link BEFORE the session exists (wiki window closed).
        manager.stashPendingWikiLink(descriptor.id, url: url, openInNewTab: true)
        #expect(manager.pendingWikiLinks[descriptor.id] != nil)

        // Creating the session transfers the stash onto it.
        let session = manager.session(for: descriptor.id, descriptor: descriptor)

        #expect(session.pendingWikiLink?.url == url)
        #expect(session.pendingWikiLink?.openInNewTab == true)
        // The stash is consumed from the manager.
        #expect(manager.pendingWikiLinks[descriptor.id] == nil)
    }

    @Test func testSessionCreationWithoutStashLeavesPendingWikiLinkNil() {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let manager = makeSessionManager(dir: dir)
        let descriptor = registry.wikis.first!

        // No stash → the new session's pendingWikiLink is nil.
        let session = manager.session(for: descriptor.id, descriptor: descriptor)

        #expect(session.pendingWikiLink == nil)
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
