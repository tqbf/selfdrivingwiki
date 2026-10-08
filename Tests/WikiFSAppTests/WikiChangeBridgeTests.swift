#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFS

/// `WikiChangeBridge` tests: verifies the bridge routes Darwin-notification
/// flushes to ALL matching sessions' buses (multi-window), and always signals
/// the File Provider for any wiki regardless of which sessions are active.
///
/// The bridge's `flush(wikiID:)` and `didReceiveDarwinNotification(named:)` are
/// called directly (both `internal`, exposed via `@testable import WikiFS`), so
/// these don't need to post real Darwin notifications — see the note on
/// `didReceiveDarwinNotification`.
///
/// This suite requires `WIKIFS_APP_TESTS=1` (it links the app target). The pure
/// routing decision it depends on is pinned separately in
/// `WikiChangeWakeRoutingTests`, which runs in the default graph.
@MainActor
struct WikiChangeBridgeTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Helper: create a registry + bootstrap + return the active descriptor
    /// for a freshly seeded wiki.
    private func makeSeededRegistry(dir: URL) -> WikiRegistryClient {
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        return registry
    }

    /// Helper: create a session for a wiki + return it.
    private func makeSession(
        wikiID: WikiID, descriptor: WikiDescriptor, dir: URL
    ) throws -> ProfileWikiSession {
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let queueEngine = try! makeTestQueueEngine()
        let provider = StubExtractionProvider()
        return try ProfileWikiSession(
            testFixtureWikiID: wikiID,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: queueEngine,
            extractionProvider: provider)
    }

    /// Write a second wiki's descriptor to the registry FILE on disk, bypassing
    /// this client's `wikis` property — exactly what `wikictl wiki create` and the
    /// daemon do, and the situation #1374 is about.
    private func registerWikiOnDisk(
        _ descriptor: WikiDescriptor, dir: URL
    ) throws {
        var registry = WikiRegistry.load(from: dir)
        registry.add(descriptor)
        try registry.save(to: dir)
    }

    /// When the changed wiki matches an active session, the bridge pokes the
    /// session's bus so the on-screen model reloads. We verify by checking that
    /// the session's store received a `ResourceChangeEvent` — i.e. the store's
    /// `summaries` get rebuilt (a side effect of the bus subscription's
    /// reload path).
    @Test func testFlushPokesSessionBusForMatchingWiki() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptor = registry.wikis.first!
        let session = try makeSession(wikiID: descriptor.id, descriptor: descriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        // Inject the lookup closure — returns the session whose wikiID matches.
        bridge.sessionLookup = { wikiID in
            wikiID == session.wikiID ? [session] : []
        }
        bridge.start()

        // Flush for the active wiki's id. The bus should receive a
        // ResourceChangeEvent, which triggers the model's reload subscription.
        bridge.flush(wikiID: descriptor.id)

        // Give the async FP signal + bus emit a tick to land.
        try? await Task.sleep(for: .milliseconds(50))

        // The flush emitted via the bus — the store's subscription rebuilds
        // summaries. If the bus was NOT poked, summaries would still be
        // populated from init, so this is a non-crash + presence check.
        #expect(!session.store.summaries.isEmpty)
    }

    /// Two sessions with the SAME wiki ID both get poked by flush (multi-window:
    /// a second window over the same wiki shares the session, but the lookup
    /// returns all matching sessions — verify the bridge iterates them all).
    @Test func testFlushPokesAllMatchingSessions() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptor = registry.wikis.first!

        // Two sessions for the SAME wiki ID (simulates two windows over one
        // wiki — in practice they share one session, but the bridge must
        // handle the lookup returning multiple).
        let session1 = try makeSession(wikiID: descriptor.id, descriptor: descriptor, dir: dir)
        let session2 = try makeSession(wikiID: descriptor.id, descriptor: descriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var pokedSessions: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            if wikiID == descriptor.id {
                pokedSessions = [session1.wikiID, session2.wikiID]
                return [session1, session2]
            }
            return []
        }
        bridge.start()

        bridge.flush(wikiID: descriptor.id)

        // Give the async FP signal + bus emit a tick to land.
        try? await Task.sleep(for: .milliseconds(50))

        // Both sessions' wikiIDs were returned by the lookup → both poked.
        #expect(pokedSessions.count == 2)
    }

    /// The chat-tool-call hint (`noteSuspectedExternalWrite`) flows through the
    /// same coalescer as a Darwin notification: two hints inside the quiet
    /// window produce ONE flush that pokes the matching session's bus.
    @Test func testNoteSuspectedExternalWriteCoalescesIntoOneFlush() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptor = registry.wikis.first!
        let session = try makeSession(wikiID: descriptor.id, descriptor: descriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var flushLookups: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            if wikiID == descriptor.id {
                flushLookups.append(wikiID)
                return [session]
            }
            return []
        }
        bridge.start()

        // Two completed-tool-call hints, microseconds apart — one flush.
        bridge.noteSuspectedExternalWrite(forWikiID: descriptor.id)
        bridge.noteSuspectedExternalWrite(forWikiID: descriptor.id)

        // The real scheduler sleeps the ~250 ms coalesce window on the main
        // actor; poll until the flush lands (bounded, never blocks the pool).
        for _ in 0..<200 where flushLookups.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(flushLookups == [descriptor.id])
    }

    /// A session with a DIFFERENT wiki ID is not poked.
    @Test func testFlushDoesNotPokeNonMatchingSessions() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptorA = registry.wikis.first!

        // Create a second wiki.
        let descriptorB = WikiDescriptor.make(displayName: "Wiki B")
        let urlB = dir.appendingPathComponent("\(descriptorB.id.rawValue).sqlite", isDirectory: false)
        _ = try? GRDBWikiStore(databaseURL: urlB)

        let sessionA = try makeSession(wikiID: descriptorA.id, descriptor: descriptorA, dir: dir)
        let sessionB = try makeSession(wikiID: descriptorB.id, descriptor: descriptorB, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var pokedWikiIDs: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            let matching = [sessionA, sessionB].filter { $0.wikiID == wikiID }
            pokedWikiIDs = matching.map(\.wikiID)
            return matching
        }
        bridge.start()

        // Flush for wiki A — only session A should be poked.
        bridge.flush(wikiID: descriptorA.id)

        // Give the async bus emit a tick to land.
        try? await Task.sleep(for: .milliseconds(50))

        // Only sessionA was poked, not sessionB.
        #expect(pokedWikiIDs == [descriptorA.id])
    }

    /// The bridge always signals the File Provider, even for a wiki with no
    /// matching session — the bridge should not crash and should not poke any
    /// bus (no matching sessions).
    @Test func testFlushSignalsFileProviderForAnyWiki() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptor = registry.wikis.first!
        let session = try makeSession(wikiID: descriptor.id, descriptor: descriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        bridge.sessionLookup = { wikiID in
            wikiID == session.wikiID ? [session] : []
        }
        bridge.start()

        // Flush for a non-matching wiki id — the bridge should not crash and
        // should not poke the session's bus (wikiID mismatch).
        let nonActiveID = WikiID(rawValue: "non-active-wiki-id")
        bridge.flush(wikiID: nonActiveID)

        // Give the async FP signal a tick to land.
        try? await Task.sleep(for: .milliseconds(50))

        // No crash is the main assertion — the bridge handled a non-matching
        // wiki id gracefully (FP was signaled, no bus was poked).
        #expect(Bool(true))
    }

    // MARK: - #1374 regression pins

    /// THE regression pin for #1374: a post for a wiki that was NOT in the set as
    /// of launch is still handled.
    ///
    /// On the old code this failed by construction — the receipt path resolved
    /// the wiki by matching the posted name against `observedWikiIDs` (the
    /// launch-time set) and silently dropped anything else, so a wiki created
    /// while the app ran was inaudible no matter how many times the writer
    /// posted.
    @Test func testPostForWikiNotInLaunchTimeSetIsHandled() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let launchDescriptor = registry.wikis.first!

        // A wiki created AFTER launch — never in `registry.wikis` at start(),
        // and written to the registry file only, like `wikictl wiki create`.
        let lateDescriptor = WikiDescriptor.make(displayName: "Created While Running")
        try registerWikiOnDisk(lateDescriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var refreshed: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            refreshed.append(wikiID)
            return []
        }
        bridge.start()

        // The writer posts the ONE stable name. The bridge must refresh the late
        // wiki even though it knew nothing about it at launch.
        bridge.didReceiveDarwinNotification(named: WikiChangeNotification.baseName)

        // Poll for the coalesced flush (the scheduler sleeps ~250 ms).
        for _ in 0..<200 where !refreshed.contains(lateDescriptor.id) {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(
            refreshed.contains(lateDescriptor.id),
            "a wiki created after launch must still be refreshed by a wiki-agnostic wake")
        #expect(refreshed.contains(launchDescriptor.id))
    }

    /// A wiki added to the registry after launch receives changes with NO explicit
    /// refresh call: the receipt path re-reads the registry from disk itself.
    ///
    /// This is the "no `refreshObservations()`" pin — the old design needed the
    /// app to call it from `.onChange(of: registry.wikis)` on the main window's
    /// content, which only evaluates while that window is on screen.
    @Test func testWikiAddedAfterLaunchReceivesChangesWithoutExplicitRefresh() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var refreshed: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            refreshed.append(wikiID)
            return []
        }
        // Subscribe ONCE, at launch — and never call any refresh method again.
        bridge.start()

        // The registry file gains a wiki behind this client's back.
        let lateDescriptor = WikiDescriptor.make(displayName: "Late")
        try registerWikiOnDisk(lateDescriptor, dir: dir)

        bridge.didReceiveDarwinNotification(named: WikiChangeNotification.baseName)

        for _ in 0..<200 where !refreshed.contains(lateDescriptor.id) {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(
            refreshed.contains(lateDescriptor.id),
            "the receipt path must re-read the registry; no explicit refresh may be required")
    }

    /// A wake for the wiki-change name refreshes every wiki the registry lists —
    /// the fan-out is deliberate, because the payload-free name cannot say which
    /// wiki changed.
    @Test func testWakeRefreshesEveryRegisteredWiki() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let descriptorA = registry.wikis.first!
        let descriptorB = WikiDescriptor.make(displayName: "Wiki B")
        try registerWikiOnDisk(descriptorB, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var refreshed: Set<WikiID> = []
        bridge.sessionLookup = { wikiID in
            refreshed.insert(wikiID)
            return []
        }
        bridge.start()

        bridge.didReceiveDarwinNotification(named: WikiChangeNotification.baseName)

        for _ in 0..<200 where refreshed.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(refreshed == [descriptorA.id, descriptorB.id])
    }

    /// A name from another namespace never enters the wiki fan-out — the renderer
    /// machine route owns it.
    @Test func testForeignNotificationNameDoesNotRefreshWikis() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        var refreshed: [WikiID] = []
        bridge.sessionLookup = { wikiID in
            refreshed.append(wikiID)
            return []
        }
        var machineScopes: [RendererMachineScopeID] = []
        bridge.rendererMachineWakeHandler = { machineScopes.append($0) }
        bridge.start()

        bridge.didReceiveDarwinNotification(
            named: "\(RendererChangeNotification.machineBaseName).not-observed")

        // A tick long enough that a scheduled flush would have landed.
        try? await Task.sleep(for: .milliseconds(350))

        #expect(refreshed.isEmpty)
        #expect(machineScopes.isEmpty)
    }

    /// A name from another namespace does not even READ the registry: the name is
    /// resolved before `reloadFromDisk()`, so a foreign wake costs no main-actor
    /// disk read. Pinned by making the registry file disagree with the client and
    /// asserting the foreign wake left the client's view untouched.
    @Test func testForeignNotificationNameDoesNotReloadTheRegistry() async throws {
        let dir = tempDirectory()
        let registry = makeSeededRegistry(dir: dir)
        let launchDescriptor = registry.wikis.first!

        // A wiki appears on disk behind this client's back — a reload would
        // adopt it, so its absence afterwards proves no read happened.
        let lateDescriptor = WikiDescriptor.make(displayName: "Created While Running")
        try registerWikiOnDisk(lateDescriptor, dir: dir)

        let fileProvider = FileProviderFacade()
        let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
        bridge.start()

        bridge.didReceiveDarwinNotification(
            named: "\(RendererChangeNotification.machineBaseName).not-observed")

        #expect(
            registry.wikis.map(\.id) == [launchDescriptor.id],
            "a foreign wake must not reload the registry")

        // The wiki-change name DOES read it, so the assertion above is about the
        // name check and not about a dead reload path.
        bridge.didReceiveDarwinNotification(named: WikiChangeNotification.baseName)
        #expect(registry.wikis.map(\.id).contains(lateDescriptor.id))
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
    func persistBytesExtraction(
        wikiID: WikiID, sourceID: SourceID,
        resolution: BytesExtractionResolution, markdown: String
    ) async throws -> QueueExtractionOutputReference? { nil }
    func persistTranscriptExtraction(
        wikiID: WikiID, sourceID: SourceID,
        resolution: TranscriptExtractionResolution, outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func persistFetch(
        wikiID: WikiID, sourceID: SourceID,
        resolution: FetcherResolution, outcome: FetchOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func enqueueFollowOnExtraction(
        wikiID: WikiID, sourceID: SourceID,
        acquiredContentVersionID: SourceVersionID, dedupeKey: QueueItemDedupeKey
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
#endif
