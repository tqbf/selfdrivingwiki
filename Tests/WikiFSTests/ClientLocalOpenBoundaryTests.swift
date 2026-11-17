#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
import WikiFSSearch
@testable import WikiCtlCore
@testable import WikiFSEngine
@testable import wikid

/// The daemon-only open-seam harness (plans/daemon-only-access.md Phase 0,
/// tightened to the P5 column).
///
/// Attribution is BY INJECTION: the harness boots the production app
/// composition with recording open factories (`AppPluginCatalogFactories
/// .storeOpenFactories`, recording queue-store factories). Daemon-side
/// fixture opens keep their plain factories and never reach
/// `WikiOpenSeamRecorder.shared`, so a recorded open is by construction a
/// CLIENT-side local storage open.
///
/// The P5 column (plans/daemon-only-access.md, permitted-access table):
/// store, read-pool, queue, and index-build rows are ALL `none` — the
/// session-level harness asserts ZERO client-side opens/builds across real
/// entry-point runs with the daemon UP and with it DOWN. The positive
/// control proves each seam is CONNECTED by driving its recording closure
/// directly (a disconnected seam cannot fake a recorded label); the app
/// composition itself no longer contains any of the five opens (the
/// read-pool leg and the local Tantivy assembly are deleted; the
/// `allowLocalStore` override is gone).
@Suite("Client local open boundary", .serialized, .timeLimit(.minutes(8)))
struct ClientLocalOpenBoundaryTests {
    // MARK: - Harness

    /// Boots the production app process composition + one real per-wiki
    /// session through `AppProcessProfileOwner.bootWikiSession` — the same
    /// async session loader `WikiFSApp` wires — with the store seam
    /// recording into `WikiOpenSeamRecorder.shared`. Pass `catalog:` for a
    /// mode-specific catalog (the P5 remote case injects the daemon-backed
    /// store factory).
    @MainActor
    private func bootRecordingSession(
        container: URL,
        wikiID: WikiID,
        displayName: String,
        catalog: PluginCatalog? = nil
    ) async throws -> (ProfileWikiSession, AppProcessProfileOwner) {
        let processDisposals = ProfileProcessDisposalRecorder()
        let owner = AppProcessProfileOwner {
            try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(
                    includeAppServices: true,
                    recorder: processDisposals),
                layers: [PatchFile(
                    entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        }
        owner.start()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let descriptor = WikiDescriptor(
            id: wikiID,
            displayName: displayName,
            createdAt: timestamp,
            lastUsedAt: timestamp)
        let session = try await owner.bootWikiSession(
            wikiID: wikiID,
            descriptor: descriptor,
            containerDirectory: container,
            catalog: catalog ?? Self.recordingAppCatalog(),
            searchServices: UnavailableSearchServices())
        return (session, owner)
    }

    /// The app catalog with the store seam recording. P5: the read-pool and
    /// Tantivy-runtime legs no longer exist in app composition (deleted
    /// with the pool and the local assembly); the only injectable storage
    /// open left is the store itself.
    private static func recordingAppCatalog() throws -> PluginCatalog {
        let recordingMakeStore: @Sendable (StorePlugin.StoreOpenContext) throws -> any WikiStore = { context in
            try WikiOpenSeamRecorder.shared.recording(
                seam: .wikiStore, label: context.databaseURL.path) {
                try StoreBackend.current.makeStore(databaseURL: context.databaseURL)
            }
        }
        return try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
            base: BasePluginCatalogFactories(
                agentProviderServices: UnavailableAgentProviderServices()),
            makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() },
            storeOpenFactories: StorePlugin.StoreOpenFactories(
                makeStore: recordingMakeStore)))
    }

    /// The remote-mode catalog: the store factory constructs the
    /// daemon-backed client and records NOTHING — no local open exists on
    /// this path. Every entry point below must keep all five seams at zero.
    /// `gate` flips the daemon down: while down, the invoker never replies
    /// and the transport's timeout backstop answers typed (the
    /// `RemoteWikiStoreTests` daemon-down shape).
    private static func remoteCatalog(
        wikiID: WikiID,
        exporter: WikiDaemonExporter,
        gate: DaemonAvailabilityGate
    ) throws -> PluginCatalog {
        try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
            base: BasePluginCatalogFactories(
                agentProviderServices: UnavailableAgentProviderServices()),
            makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() },
            storeOpenFactories: StorePlugin.StoreOpenFactories
                .remoteStore { context in
                    RemoteWikiStore(
                        transport: XPCStoreTransport(
                            invoker: { requestedWikiID, request, reply in
                                gate.invoke(requestedWikiID, request, reply) {
                                    exporter.storeOperation($0, request: $1, reply: $2)
                                }
                            },
                            timeout: gate.timeout),
                        wikiID: WikiID(rawValue: context.wikiID))
                },
            storeAccessMode: .remote))
    }

    private static func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func removeContainer(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Positive control (seams connected)

    /// Each recording seam is CONNECTED: driving its recording closure
    /// directly records a label. A disconnected seam cannot fake a zero, so
    /// this control is what makes the P5 zero assertions meaningful. (The
    /// app composition no longer contains any of these opens — the local
    /// session boot is gone; these are direct seam drives.)
    @Test("positive control: every storage seam's recording closure is connected")
    @MainActor
    func positiveControlRecordsEverySeam() async throws {
        let recorder = WikiOpenSeamRecorder.shared
        recorder.reset()
        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }
        let wikiID = WikiID(rawValue: "open-boundary-control")

        // Wiki store seam: the recording closure records the open it wraps.
        let databasePath = container.appendingPathComponent("\(wikiID.rawValue).sqlite").path
        let recordedStore = try WikiOpenSeamRecorder.shared.recording(
            seam: .wikiStore,
            label: databasePath) {
            try StoreBackend.current.makeStore(databaseURL: URL(fileURLWithPath: databasePath))
        }
        _ = recordedStore
        #expect(recorder.labels(.wikiStore) == [databasePath])

        // Read-only pool seam: the pool left app composition (P5), but the
        // recorder's seam stays defined for the P6 File Provider cutover —
        // the recording closure still wraps the read-only constructor.
        let recordedReadOnly = try WikiOpenSeamRecorder.shared.recording(
            seam: .wikiReadOnlyStore,
            label: databasePath) {
            try GRDBWikiStore(readOnlyURL: URL(fileURLWithPath: databasePath))
        }
        _ = recordedReadOnly
        #expect(recorder.labels(.wikiReadOnlyStore) == [databasePath])

        // Queue store seam: the app never opens queue.sqlite (P4); the
        // recording closure still wraps the queue store constructor.
        let queueURL = container.appendingPathComponent("queue.sqlite")
        let recordedQueueStore = try WikiOpenSeamRecorder.shared.recording(
            seam: .queueStore,
            label: queueURL.path) {
            try QueueStore(databaseURL: queueURL)
        }
        #expect(recorder.labels(.queueStore).contains(queueURL.path))
        recordedQueueStore.close()

        // Tantivy writer seam: the app's local index assembly is REMOVED
        // (P5). The CLI/fixture-owned factory is still the seam — drive it
        // directly to prove the recording closure stays connected.
        let searchContainer = try Self.makeContainer()
        defer { Self.removeContainer(searchContainer) }
        let identity = SearchRuntimeIdentity(
            wikiID: wikiID,
            containerDirectory: searchContainer)
        let store = try GRDBWikiStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let runtime = SearchRuntimeCompositionFactory.runtimeFactory(
            identity: identity,
            contentSource: StoreBackedTantivyContentSource(store: store),
            changeStreamFactory: BusSearchChangeStreamFactory(
                bus: WikiEventBus(wikiID: wikiID)),
            makeIndexer: { recordedIdentity, recordedSource in
                try WikiOpenSeamRecorder.shared.recording(
                    seam: .tantivyIndexerWriter,
                    label: recordedIdentity.indexDirectory.path) {
                    try TantivyIndexer(
                        indexDirectory: recordedIdentity.indexDirectory,
                        contentSource: recordedSource)
                }
            })
        let registry = SearchRuntimeRegistry()
        let lease = try await registry.assemble(runtime)
        #expect(recorder.labels(.tantivyIndexerWriter).contains(identity.indexDirectory.path))
        await lease.dispose()
    }

    // MARK: - P5 column: ZERO client opens across session-level runs (up + down)

    /// The P5 headline (plans/daemon-only-access.md gate): a REAL per-wiki
    /// session boots over the fixture daemon's store transport and drives
    /// every real entry point — navigation, source import, page/source/chat
    /// search, the search-upgrade trigger, registry-mediated reads — with
    /// the daemon UP; then the daemon goes DOWN mid-session and the same
    /// entry points fail TYPED. Across both phases, every client-side seam
    /// records ZERO opens: no wiki store, no read-only pool, no queue
    /// store, no provider invocation, no Tantivy writer — and the app
    /// container never even gains the wiki database file. There is no
    /// read-only local mode.
    @Test("P5 column: zero client-side store, read-pool, queue, and index opens with the daemon up and down")
    @MainActor
    func remoteSessionsRecordZeroLocalOpensDaemonUpAndDown() async throws {
        let recorder = WikiOpenSeamRecorder.shared
        recorder.reset()

        // The fixture daemon over its own container; its fixture wiki id
        // IS the session wiki id, so the injected factory's context wiki id
        // scopes the wire operations correctly (in production app and
        // daemon share one registry).
        let daemonContainer = try Self.makeContainer()
        defer { Self.removeContainer(daemonContainer) }
        let gate = DaemonAvailabilityGate()
        let daemon = WikiDaemon(containerDirectory: daemonContainer)
        let fixtureData = try #require(
            daemon.testFixtureCreateWiki(name: "Remote Boundary Fixture"))
        let wikiID = try JSONDecoder()
            .decode(WikiDescriptor.self, from: fixtureData).id
        let exporter = WikiDaemonExporter(daemon: daemon)

        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }
        let (session, owner) = try await bootRecordingSession(
            container: container,
            wikiID: wikiID,
            displayName: "Remote Boundary",
            catalog: Self.remoteCatalog(wikiID: wikiID, exporter: exporter, gate: gate))
        defer { Task { await owner.shutdown() } }

        let databasePath = container
            .appendingPathComponent("\(wikiID.rawValue).sqlite").path

        // Session boot (bootstrap + Home seeding + format-job recovery)
        // already exercised daemon-served reads/writes — recording nothing.
        #expect(recorder.count(.wikiStore) == 0)
        #expect(!FileManager.default.fileExists(atPath: databasePath))
        #expect(recorder.count(.wikiReadOnlyStore) == 0)
        #expect(recorder.count(.queueStore) == 0)
        #expect(recorder.count(.queueProviderInvocation) == 0)
        #expect(recorder.count(.tantivyIndexerWriter) == 0)

        // Warm the session exactly the way the app's asyncSessionLoader
        // does (handshake + bootstrap composition + the P5 search-upgrade
        // progress wiring).
        try await RemoteStoreSessionComposition.composeIfRemote(session)
        #expect(recorder.count(.wikiStore) == 0)

        // Real entry points, daemon UP — every read/write is daemon-served.
        let remoteStore = session.store.internalStore
        let homeID = try await remoteStore.resolveTitleToID("Home")
        #expect(homeID != nil)
        #expect(session.store.selectPage(byTitle: "Home"))
        _ = await session.store.addSource(filename: "boundary-notes.txt", data: Data("boundary".utf8))
        session.store.searchQuery = "boundary"
        try await Task.sleep(for: .milliseconds(500))
        session.store.sourceSearchQuery = "boundary"
        try await Task.sleep(for: .milliseconds(500))
        session.store.chatSearchQuery = "boundary"
        try await Task.sleep(for: .milliseconds(500))
        await session.store.upgradeSearchIndex()
        try await remoteStore.setMetadata("boundary-remote", value: "daemon-served")
        #expect(
            try await remoteStore.getMetadata("boundary-remote")
                == "daemon-served")

        // The write landed on the DAEMON's side: the fixture daemon's own
        // prepared store reads it back — the client never owned a file.
        let daemonStore = try await daemon.domainCommandStore(wikiID: wikiID)
        #expect(
            try await daemonStore.getMetadata("boundary-remote")
                == "daemon-served")
        #expect(!FileManager.default.fileExists(atPath: databasePath))

        // THE P5 COLUMN, daemon up: zero across all five seams.
        #expect(recorder.count(.wikiStore) == 0)
        #expect(recorder.count(.wikiReadOnlyStore) == 0)
        #expect(recorder.count(.queueStore) == 0)
        #expect(recorder.count(.queueProviderInvocation) == 0)
        #expect(recorder.count(.tantivyIndexerWriter) == 0)

        // Daemon DOWN: the same entry points fail TYPED (the transport
        // never replies; the timeout backstop answers). No local revival —
        // every seam still records zero, and nothing creates the file.
        gate.takeDaemonDown()
        await #expect(throws: RemoteStoreClientError.self) {
            try await remoteStore.resolveTitleToID("Home")
        }
        session.store.searchQuery = "down-query"
        try await Task.sleep(for: .milliseconds(gate.downSettleMilliseconds))
        await session.store.upgradeSearchIndex()
        do {
            try await remoteStore.setMetadata("boundary-down", value: "must-fail")
            Issue.record("the daemon-down write must fail typed")
        } catch {
            // Expected: explicit degradation, no silent fallback.
        }

        // Still zero, daemon down. No read-only local mode exists.
        #expect(recorder.count(.wikiStore) == 0)
        #expect(recorder.count(.wikiReadOnlyStore) == 0)
        #expect(recorder.count(.queueStore) == 0)
        #expect(recorder.count(.queueProviderInvocation) == 0)
        #expect(recorder.count(.tantivyIndexerWriter) == 0)
        #expect(!FileManager.default.fileExists(atPath: databasePath))
    }

    // MARK: - Failing seam (future phases)

    /// The harness's failing-seam contract, kept connected from day one: a
    /// seam factory that THROWS surfaces the open failure instead of
    /// silently proceeding — the session boot fails explicitly, never a
    /// silent local revival and no half-booted session.
    @Test("a failing store seam surfaces the open failure from session boot")
    @MainActor
    func failingStoreSeamSurfacesError() async throws {
        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }
        let wikiID = WikiID(rawValue: "open-boundary-failing")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let processDisposals = ProfileProcessDisposalRecorder()
        let owner = AppProcessProfileOwner {
            try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(
                    includeAppServices: true,
                    recorder: processDisposals),
                layers: [PatchFile(
                    entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        }
        owner.start()
        defer { Task { await owner.shutdown() } }

        let failingCatalog = try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
            base: BasePluginCatalogFactories(
                agentProviderServices: UnavailableAgentProviderServices()),
            makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() },
            storeOpenFactories: StorePlugin.StoreOpenFactories(
                makeStore: failingStoreFactory)))

        do {
            _ = try await owner.bootWikiSession(
                wikiID: wikiID,
                descriptor: WikiDescriptor(
                    id: wikiID,
                    displayName: "Failing",
                    createdAt: timestamp,
                    lastUsedAt: timestamp),
                containerDirectory: container,
                catalog: failingCatalog,
                searchServices: UnavailableSearchServices())
            Issue.record("session boot must surface the seamed store-open failure")
        } catch {
            // Expected: the seam failure propagates out of the session loader
            // — no silent local revival and no half-booted session.
        }
    }
}

/// The daemon availability gate for the P5 harness: UP routes every store
/// call into the exporter; DOWN never replies, so the transport's timeout
/// backstop answers typed — the same shape a dead daemon produces, without
/// waiting on a real process.
final class DaemonAvailabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var up = true

    /// The UP-phase transport timeout. The in-process exporter answers
    /// synchronously; 5s is generous headroom for a loaded CI sandbox.
    /// The DOWN-phase settle window matches it (every down-phase call must
    /// fail typed within one timeout, plus scheduler slack).
    let timeout: TimeInterval = 5
    var downSettleMilliseconds: UInt64 { UInt64((timeout + 1) * 1000) }

    func invoke(
        _ wikiID: String, _ request: Data, _ reply: @escaping (Data) -> Void,
        route: (String, Data, @escaping (Data) -> Void) -> Void
    ) {
        let isUp: Bool = lock.withLock { up }
        guard isUp else { return } // never replies → typed deadlineExceeded
        route(wikiID, request, reply)
    }

    func takeDaemonDown() {
        lock.withLock { up = false }
    }
}

/// The failing store seam used by the seamed-open-failure scenario. A top
/// level function: Swift does not parse error type declarations inside
/// closures.
private struct SeamedOpenFailure: Error {}

/// The fixture-daemon boundary for the REMOTE-mode harness case (mirrors
/// WikiFSAppTests' `WikiDaemonTestSupport` convenience init; that target is
/// opt-in and invisible here).
extension WikiDaemon {
    fileprivate convenience init(containerDirectory: URL) {
        self.init(
            containerDirectory: containerDirectory,
            testFixtureMakeStore: { try GRDBWikiStore(databaseURL: $0) })
    }
}

private let failingStoreFactory: @Sendable (StorePlugin.StoreOpenContext) throws -> any WikiStore = { _ in
    throw SeamedOpenFailure()
}
#endif
