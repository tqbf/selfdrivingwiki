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

/// The daemon-only open-seam harness (plans/daemon-only-access.md Phase 0).
///
/// Attribution is BY INJECTION: the harness boots the production app
/// composition with recording open factories (`AppPluginCatalogFactories
/// .storeOpenFactories`, the recording Tantivy runtime factory, recording
/// queue-store factories). Daemon-side fixture opens keep their plain
/// factories and never reach `WikiOpenSeamRecorder.shared`, so a recorded
/// open is by construction a CLIENT-side local storage open.
///
/// Assertions match the plan's permitted-access column: the LOCAL-mode cases
/// (positive control, P0 column, DEBUG-override path) prove the seams are
/// CONNECTED — a disconnected seam cannot fake a zero — and the REMOTE-mode
/// case pins the P3 column: the store seam records ZERO client opens while
/// the daemon serves every read and write. Later phases tighten the waived
/// seams; Phase 7 flips everything to zero with the daemon up and down.
@Suite("Client local open boundary", .serialized, .timeLimit(.minutes(8)))
struct ClientLocalOpenBoundaryTests {
    // MARK: - Harness

    /// Boots the production app process composition + one real per-wiki
    /// session through `AppProcessProfileOwner.bootWikiSession` — the same
    /// async session loader `WikiFSApp` wires — with every storage seam
    /// recording into `WikiOpenSeamRecorder.shared`. Pass `catalog:` for a
    /// mode-specific catalog (the P3 remote case injects the daemon-backed
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
            extractionProvider: ProfileBootFixture.extractionProvider(),
            searchServices: UnavailableSearchServices())
        return (session, owner)
    }

    /// The app catalog with every storage seam recording.
    private static func recordingAppCatalog() throws -> PluginCatalog {
        let recordingIndexer:
            @Sendable (SearchRuntimeIdentity, any TantivyContentSource) throws -> TantivyIndexer
            = { identity, contentSource in
                try WikiOpenSeamRecorder.shared.recording(
                    seam: .tantivyIndexerWriter,
                    label: identity.indexDirectory.path) {
                    try TantivyIndexer(
                        indexDirectory: identity.indexDirectory,
                        contentSource: contentSource)
                }
            }
        let recordingRuntime: SearchRuntimeFactory.Factory = { identity, contentSource, changeStreamFactory in
            SearchRuntimeCompositionFactory.runtimeFactory(
                identity: identity,
                contentSource: contentSource,
                changeStreamFactory: changeStreamFactory,
                makeIndexer: recordingIndexer)
        }
        let recordingMakeStore: @Sendable (StorePlugin.StoreOpenContext) throws -> any WikiStore = { context in
            try WikiOpenSeamRecorder.shared.recording(
                seam: .wikiStore, label: context.databaseURL.path) {
                try StoreBackend.current.makeStore(databaseURL: context.databaseURL)
            }
        }
        let recordingReadOnlyStore: @Sendable (URL) throws -> GRDBWikiStore = { url in
            try WikiOpenSeamRecorder.shared.recording(seam: .wikiReadOnlyStore, label: url.path) {
                try GRDBWikiStore(readOnlyURL: url)
            }
        }
        return try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
            base: BasePluginCatalogFactories(
                agentProviderServices: UnavailableAgentProviderServices()),
            makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() },
            makeTantivyRuntime: recordingRuntime,
            storeOpenFactories: StorePlugin.StoreOpenFactories(
                makeStore: recordingMakeStore,
                makeReadOnlyStore: recordingReadOnlyStore)))
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

    @Test("positive control: the local path records every storage seam")
    @MainActor
    func positiveControlRecordsEverySeam() async throws {
        let recorder = WikiOpenSeamRecorder.shared
        recorder.reset()
        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }

        let wikiID = WikiID(rawValue: "open-boundary-control")
        let (session, owner) = try await bootRecordingSession(
            container: container,
            wikiID: wikiID,
            displayName: "Open Boundary Control")
        defer { Task { await owner.shutdown() } }

        let databasePath = container.appendingPathComponent("\(wikiID.rawValue).sqlite").path

        // Wiki store: opened exactly once for this wiki during session boot.
        #expect(recorder.count(.wikiStore) == 1)
        #expect(recorder.labels(.wikiStore) == [databasePath])

        // Read-only pool: driving one read through the session's read service
        // checks out a fresh read-only connection (nothing idle yet).
        let readService = try #require(session.store.readService)
        _ = try await readService.asyncRead { access in
            try access.listSources()
        }
        #expect(recorder.count(.wikiReadOnlyStore) == 1)
        #expect(recorder.labels(.wikiReadOnlyStore) == [databasePath])

        // Queue store: the local runtime factory opens the queue database
        // through the seam when the harness assembles one with a recording
        // factory (the app's P4 removal target).
        let queueURL = container.appendingPathComponent("queue.sqlite")
        let queueFactory = QueueRuntimeFactory(
            databaseURL: queueURL,
            extractionProvider: ProfileBootFixture.extractionProvider(),
            makeIngestionProvider: { _ in HarnessIngestionProvider() },
            makeQueueStore: { url in
                try WikiOpenSeamRecorder.shared.recording(
                    seam: .queueStore,
                    label: url.path) {
                    try QueueStore(databaseURL: url)
                }
            })
        let queueHandle = try await queueFactory.assemble()
        #expect(recorder.labels(.queueStore).contains(queueURL.path))

        // Tantivy writer: the app's P0 local index assembly is a DEAD PATH at
        // session boot (sessions consume the daemon search facade), so the
        // positive control exercises the search runtime factory directly to
        // prove the seam stays connected.
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

        _ = try await queueHandle.dispose()
    }

    // MARK: - P0 column: real entry points across multiple sessions/wikis

    /// The app's local storage opens happen exactly where the P0 waiver
    /// column permits them: one wiki-store open per booted session, per-wiki
    /// labels, and no opens for wikis that were never opened. This runs with
    /// NO daemon — the daemon-down half of the P0 harness (with the local
    /// path active, daemon availability cannot change client opens; from P3
    /// the daemon-up/down pair asserts the tightening columns).
    @Test("P0 column: session boot and entry points open only the waived local seams")
    @MainActor
    func entryPointsOpenOnlyWaivedSeams() async throws {
        let recorder = WikiOpenSeamRecorder.shared
        recorder.reset()
        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }

        let first = WikiID(rawValue: "open-boundary-alpha")
        let second = WikiID(rawValue: "open-boundary-beta")
        let (alpha, owner) = try await bootRecordingSession(
            container: container, wikiID: first, displayName: "Alpha")
        defer { Task { await owner.shutdown() } }

        let alphaDatabase = container.appendingPathComponent("\(first.rawValue).sqlite").path

        // Navigation + source import through the session model (real entry
        // points) — the wiki store seam stays at its single boot open: page
        // reads and source writes reuse the composition's store, never a new
        // local open.
        #expect(alpha.store.selectPage(byTitle: "Home"))
        _ = await alpha.store.addSource(filename: "boundary-notes.txt", data: Data("boundary".utf8))
        alpha.store.reloadFromStore()
        _ = await alpha.store.searchSimilar(query: "boundary")
        _ = await alpha.store.searchSimilarResolvingTantivy(query: "boundary")
        await alpha.upgradeSearchIndex()
        #expect(recorder.count(.wikiStore) == 1)
        #expect(recorder.labels(.wikiStore) == [alphaDatabase])

        // A second session/wiki records its own open; labels never mix.
        _ = try await bootRecordingSession(
            container: container, wikiID: second, displayName: "Beta")
        let betaDatabase = container.appendingPathComponent("\(second.rawValue).sqlite").path
        #expect(recorder.count(.wikiStore) == 2)
        #expect(Set(recorder.labels(.wikiStore)) == Set([alphaDatabase, betaDatabase]))

        // Unopened wikis record nothing: the labels list IS the open set.
        #expect(!recorder.labels(.wikiStore).contains(
            container.appendingPathComponent("open-boundary-gamma.sqlite").path))
    }

    // MARK: - P3 column: remote default records ZERO client store opens

    /// The P3 tightening (plans/daemon-only-access.md, permitted-access
    /// table, "App: wiki DB" row): with the resolved mode REMOTE, the
    /// session's store is the daemon-backed client, the store seam records
    /// ZERO client opens, and the app container never even gains the wiki
    /// database file — while the daemon serves every read and write (the
    /// fixture daemon's own prepared store observes the committed write).
    /// The waived seams (read-only pool, queue, Tantivy writer) stay
    /// connected and still record: the harness drives them directly,
    /// exactly like the positive control.
    ///
    /// Fixture mechanics reuse the `DaemonStoreCommandExecutorTests`
    /// harness: a REAL in-process daemon serves the store family through
    /// the same `WikiDaemonExporter.storeOperation` selector an XPC
    /// connection vends (`XPCStoreTransport`'s invoker seam) — no local
    /// socket, no subprocess.
    @Test("P3 column: remote mode records zero client store opens; the daemon serves reads and writes")
    @MainActor
    func remoteModeRecordsZeroClientStoreOpens() async throws {
        let recorder = WikiOpenSeamRecorder.shared
        recorder.reset()

        // The fixture daemon over its own container; its fixture wiki id
        // IS the session wiki id, so the injected factory's context wiki id
        // scopes the wire operations correctly (in production app and
        // daemon share one registry).
        let daemonContainer = try Self.makeContainer()
        defer { Self.removeContainer(daemonContainer) }
        let daemon = WikiDaemon(containerDirectory: daemonContainer)
        let fixtureData = try #require(
            daemon.testFixtureCreateWiki(name: "Remote Boundary Fixture"))
        let wikiID = try JSONDecoder()
            .decode(WikiDescriptor.self, from: fixtureData).id
        let exporter = WikiDaemonExporter(daemon: daemon)
        let transport = XPCStoreTransport(
            invoker: { wikiID, request, reply in
                exporter.storeOperation(wikiID, request: request, reply: reply)
            },
            timeout: 20)

        // The remote-mode catalog: the store factory constructs the
        // daemon-backed client and records NOTHING — no local open exists
        // on this path. The read-only pool keeps its recording factory
        // (the P3 waiver row: the semantic-search leg still reads locally).
        let remoteCatalog = try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
            base: BasePluginCatalogFactories(
                agentProviderServices: UnavailableAgentProviderServices()),
            makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() },
            storeOpenFactories: StorePlugin.StoreOpenFactories(
                makeStore: { context in
                    RemoteWikiStore(
                        transport: transport,
                        wikiID: WikiID(rawValue: context.wikiID))
                },
                makeReadOnlyStore: { url in
                    try WikiOpenSeamRecorder.shared.recording(
                        seam: .wikiReadOnlyStore, label: url.path) {
                        try GRDBWikiStore(readOnlyURL: url)
                    }
                }),
            storeAccessMode: .remote))

        let container = try Self.makeContainer()
        defer { Self.removeContainer(container) }
        let (session, owner) = try await bootRecordingSession(
            container: container,
            wikiID: wikiID,
            displayName: "Remote Boundary",
            catalog: remoteCatalog)
        defer { Task { await owner.shutdown() } }

        let databasePath = container
            .appendingPathComponent("\(wikiID.rawValue).sqlite").path

        // Session boot (bootstrap + Home seeding + format-job recovery)
        // already exercised daemon-served reads/writes — recording nothing.
        #expect(recorder.count(.wikiStore) == 0)
        #expect(!FileManager.default.fileExists(atPath: databasePath))
        // The read-only pool opens lazily: nothing drove it during boot.
        #expect(recorder.count(.wikiReadOnlyStore) == 0)

        // Warm the session exactly the way the app's asyncSessionLoader
        // does (handshake + bootstrap composition).
        try await RemoteStoreSessionComposition.composeIfRemote(session)
        #expect(recorder.count(.wikiStore) == 0)

        // Real entry points through the session's store: daemon-served
        // reads and writes, still zero client opens.
        let remoteStore = session.store.internalStore
        let homeID = try await remoteStore.resolveTitleToID("Home")
        #expect(homeID != nil)
        try await remoteStore.setMetadata("boundary-remote", value: "daemon-served")
        #expect(
            try await remoteStore.getMetadata("boundary-remote")
                == "daemon-served")
        #expect(recorder.count(.wikiStore) == 0)

        // The write landed on the DAEMON's side: the fixture daemon's own
        // prepared store reads it back — the client never owned a file.
        let daemonStore = try await daemon.domainCommandStore(wikiID: wikiID)
        #expect(
            try await daemonStore.getMetadata("boundary-remote")
                == "daemon-served")
        #expect(!FileManager.default.fileExists(atPath: databasePath))

        // P4 tightening (plans/daemon-only-access.md, "App: local
        // QueueEngine + queue.sqlite" row, slice 1): the app profile never
        // assembles a local queue engine. The queue-store seam stays SILENT
        // through session boot and every entry point above (the direct drive
        // below proves the seam itself is still connected), and the
        // provider-invocation seam records ZERO worker entries — the app
        // providers' only caller (the local engine) is gone.
        #expect(recorder.count(.queueStore) == 0)
        #expect(recorder.count(.queueProviderInvocation) == 0)

        // Waived seams stay connected and record (P3 column):
        //
        // Read-only pool: the semantic-search leg still reads locally.
        // The wiki DB it reads is seeded HERE because the daemon owns the
        // real file and this container never had one (fixture setup — a
        // direct constructor call, not a seam open).
        _ = try GRDBWikiStore(databaseURL: URL(fileURLWithPath: databasePath))
        let readService = try #require(session.store.readService)
        _ = try await readService.asyncRead { access in
            try access.listSources()
        }
        #expect(recorder.count(.wikiReadOnlyStore) == 1)
        #expect(recorder.labels(.wikiReadOnlyStore) == [databasePath])

        // Queue store: the app no longer assembles the local queue runtime
        // (P4 slice 1), so this direct drive is only the seam-connectivity
        // positive control — the same shape as the P0 control — kept until
        // the factory itself retires with the P4.3 workload migration.
        let queueURL = container.appendingPathComponent("queue.sqlite")
        let queueFactory = QueueRuntimeFactory(
            databaseURL: queueURL,
            extractionProvider: ProfileBootFixture.extractionProvider(),
            makeIngestionProvider: { _ in HarnessIngestionProvider() },
            makeQueueStore: { url in
                try WikiOpenSeamRecorder.shared.recording(
                    seam: .queueStore,
                    label: url.path) {
                    try QueueStore(databaseURL: url)
                }
            })
        let queueHandle = try await queueFactory.assemble()
        #expect(recorder.labels(.queueStore).contains(queueURL.path))

        // Tantivy writer: still waived at P3 (the local index assembly
        // leaves at P5) — same direct drive as the positive control.
        let searchContainer = try Self.makeContainer()
        defer { Self.removeContainer(searchContainer) }
        let identity = SearchRuntimeIdentity(
            wikiID: wikiID,
            containerDirectory: searchContainer)
        let fixtureStore = try GRDBWikiStore(
            databaseURL: URL(fileURLWithPath: ":memory:"))
        let runtime = SearchRuntimeCompositionFactory.runtimeFactory(
            identity: identity,
            contentSource: StoreBackedTantivyContentSource(store: fixtureStore),
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
        #expect(recorder.labels(.tantivyIndexerWriter)
            .contains(identity.indexDirectory.path))
        await lease.dispose()
        _ = try await queueHandle.dispose()

        // The headline column, restated: nothing on the remote path ever
        // recorded a client-side wiki-store open.
        #expect(recorder.count(.wikiStore) == 0)
    }

    // MARK: - Failing seam (future phases)

    /// The harness's failing-seam contract, kept connected from day one: a
    /// seam factory that THROWS surfaces the open failure instead of
    /// silently proceeding. Later phases swap the recording bodies for
    /// failing ones to prove the client path never opens local storage.
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
                extractionProvider: ProfileBootFixture.extractionProvider(),
                searchServices: UnavailableSearchServices())
            Issue.record("session boot must surface the seamed store-open failure")
        } catch {
            // Expected: the seam failure propagates out of the session loader
            // — no silent local revival and no half-booted session.
        }
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

/// Minimal ingestion provider for harness queue assemblies (nothing routes
/// through it — the assembly only needs a provider value to construct).
/// Same shape as `QueueRuntimeFactoryTests`'s private double.
private struct HarnessIngestionProvider: QueueIngestionProvider {
    func runIngestion(
        wikiID: WikiID,
        sourceIDs: [SourceID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?,
        onReport: (@Sendable (QueueReportMutation) -> Void)?
    ) async throws {}

    func runLint(
        wikiID: WikiID,
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?,
        onReport: (@Sendable (QueueReportMutation) -> Void)?
    ) async throws {}

    func runLintPages(
        wikiID: WikiID,
        pageIDs: [PageID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?,
        onReport: (@Sendable (QueueReportMutation) -> Void)?
    ) async throws {}

    func readiness() async -> String? { nil }
}
#endif
