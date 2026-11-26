#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
import WikiFSSearch
@testable import WikiFSEngine

/// The daemon-only open-seam harness (plans/daemon-only-access.md Phase 0).
///
/// Attribution is BY INJECTION: the harness boots the production app
/// composition with recording open factories (`AppPluginCatalogFactories
/// .storeOpenFactories`, the recording Tantivy runtime factory, recording
/// queue-store factories). Daemon-side fixture opens keep their plain
/// factories and never reach `WikiOpenSeamRecorder.shared`, so a recorded
/// open is by construction a CLIENT-side local storage open.
///
/// P0 assertions match the plan's permitted-access column: the local path is
/// still permitted for every seam, so the harness's job is to prove the
/// seams are CONNECTED — a disconnected seam cannot fake a zero. Later
/// phases tighten the expected counts to the table's columns; Phase 7 flips
/// to zero with the daemon up and down.
@Suite("Client local open boundary", .serialized, .timeLimit(.minutes(5)))
struct ClientLocalOpenBoundaryTests {
    // MARK: - Harness

    /// Boots the production app process composition + one real per-wiki
    /// session through `AppProcessProfileOwner.bootWikiSession` — the same
    /// async session loader `WikiFSApp` wires — with every storage seam
    /// recording into `WikiOpenSeamRecorder.shared`.
    @MainActor
    private func bootRecordingSession(
        container: URL,
        wikiID: WikiID,
        displayName: String
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
            catalog: try Self.recordingAppCatalog(),
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
        let recordingMakeStore: @Sendable (URL) throws -> any WikiStore = { url in
            try WikiOpenSeamRecorder.shared.recording(seam: .wikiStore, label: url.path) {
                try StoreBackend.current.makeStore(databaseURL: url)
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
        alpha.store.addSource(filename: "boundary-notes.txt", data: Data("boundary".utf8))
        alpha.store.reloadFromStore()
        _ = alpha.store.searchSimilar(query: "boundary")
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

private let failingStoreFactory: @Sendable (URL) throws -> any WikiStore = { _ in
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
