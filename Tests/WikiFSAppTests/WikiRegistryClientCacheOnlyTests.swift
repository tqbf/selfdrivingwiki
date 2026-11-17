import Foundation
import Testing
import WikiDaemonContract
import WikiCtlCore
import WikiFSCore
import WikiFSTypes
@testable import wikid

// Phase 3 slice 2 (plans/daemon-only-access.md 3.2 + 3.3; AC.6): the registry
// client is a READ CACHE in remote mode. Every lifecycle op (create / rename /
// delete / first-run seed) routes to the daemon through the injected
// ``WikiRegistryDaemonInvoker``; the client writes NO `wikis.json` and creates
// NO DB files; the cache refreshes from daemon registry events (routed by
// ``DaemonRegistryEventFeed``) and from ``reloadFromDisk()``. One control test
// pins LOCAL mode still writing (the DEBUG local dev path is unchanged).
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// waiting is a non-blocking poll — no test blocks a cooperative pool thread.
@Suite(.serialized, .timeLimit(.minutes(8)))
@MainActor
struct WikiRegistryClientCacheOnlyTests {

    // MARK: - Fixtures

    private func tempContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-registry-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every file currently in the container. Remote-mode lifecycle ops must
    /// leave this EMPTY (no `wikis.json`, no `.sqlite`, no sidecars).
    private func containerContents(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .sorted() ?? []
    }

    /// A `WikiRegistryDaemonInvoker` double that records every mediated op and
    /// optionally simulates the daemon's own `wikis.json` write.
    private final class RecordingInvoker: WikiRegistryDaemonInvoker, @unchecked Sendable {
        // swiftlint:disable:next unchecked_sendable
        private let lock = NSLock()
        private var creates: [String] = []
        private var renames: [(WikiID, String)] = []
        private var deletes: [WikiID] = []
        /// When true, `createWiki` also writes the registry row to
        /// `wikis.json` — simulating the daemon's own write (the client must
        /// never be the writer; this double IS the daemon).
        var simulateDaemonCreateWrite = false

        func createWiki(name: String) async throws -> WikiDescriptor {
            lock.withLock { creates.append(name) }
            let descriptor = WikiDescriptor.make(displayName: name)
            if simulateDaemonCreateWrite {
                var registry = WikiRegistry()
                registry.add(descriptor)
                try registry.save(to: containerDirectory)
            }
            return descriptor
        }

        func renameWiki(id: WikiID, to name: String) async throws -> Bool {
            lock.withLock { renames.append((id, name)) }
            return true
        }

        func deleteWiki(id: WikiID) async throws -> Bool {
            lock.withLock { deletes.append(id) }
            return true
        }

        var containerDirectory: URL

        init(containerDirectory: URL) {
            self.containerDirectory = containerDirectory
        }

        var recordedCreates: [String] { lock.withLock { creates } }
        var recordedRenames: [(WikiID, String)] { lock.withLock { renames } }
        var recordedDeletes: [WikiID] { lock.withLock { deletes } }
    }

    /// The invoker that routes to the REAL fixture daemon's wiki family —
    /// the same ops the app's `DaemonWikiRegistryInvoker` reaches over XPC.
    private final class FixtureDaemonInvoker: WikiRegistryDaemonInvoker, @unchecked Sendable {
        // swiftlint:disable:next unchecked_sendable
        let daemon: WikiDaemon

        init(daemon: WikiDaemon) {
            self.daemon = daemon
        }

        enum InvocationError: Error {
            case createFailed
        }

        func createWiki(name: String) async throws -> WikiDescriptor {
            guard let data = daemon.testFixtureCreateWiki(name: name) else {
                throw InvocationError.createFailed
            }
            return try JSONDecoder().decode(WikiDescriptor.self, from: data)
        }

        func renameWiki(id: WikiID, to name: String) async throws -> Bool {
            daemon.renameWiki(id: id, name: name)
        }

        func deleteWiki(id: WikiID) async throws -> Bool {
            daemon.testFixtureDeleteWiki(id: id)
        }
    }

    /// A `WikiDaemonEventSink` double that records every `deliverEvent`
    /// payload (lock-guarded — deliveries arrive on arbitrary threads).
    private final class RecordingSink: NSObject, WikiDaemonEventSink, @unchecked Sendable {
        // swiftlint:disable:next unchecked_sendable
        private let lock = NSLock()
        private var payloads: [Data] = []

        func deliverEvent(_ payload: Data) {
            lock.lock()
            payloads.append(payload)
            lock.unlock()
        }

        func snapshot() -> [Data] {
            lock.withLock { payloads }
        }
    }

    /// Non-blocking completion poll (AGENTS.md #1051).
    private func waitFor(
        _ condition: @autoclosure () async -> Bool,
        timeout: Duration = .seconds(10), what: String
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("timed out waiting for: \(what)")
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Decode the REGISTRY-grammar payloads only. The firehose also carries
    /// store envelopes (the fixture daemon's seeded Home commit emits one) —
    /// the pairwise-disjoint grammars make the filter deterministic.
    private func decodedRegistryPayloads(_ payloads: [Data])
        -> [DaemonRegistryEventEnvelope] {
        payloads.compactMap { data -> DaemonRegistryEventEnvelope? in
            guard let envelope = try? JSONDecoder().decode(
                DaemonRegistryEventEnvelope.self, from: data),
                envelope.wire == DaemonRegistryEventWire.marker
            else { return nil }
            return envelope
        }
    }

    /// Non-throwing registry-payload count for the completion polls.
    private func registryEventCount(_ sink: RecordingSink) -> Int {
        decodedRegistryPayloads(sink.snapshot()).count
    }

    // MARK: - Mediated lifecycle ops (remote mode, stubbed daemon)

    /// AC.6 core: remote create routes to the daemon, writes NO `wikis.json`,
    /// creates NO DB files, and the cache reflects the daemon's reply.
    @Test func remoteCreateRoutesToDaemonAndWritesNothingLocally() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)

        let created = await client.createWiki(displayName: "Cache Only")

        #expect(created != nil)
        #expect(invoker.recordedCreates == ["Cache Only"])
        #expect(
            containerContents(dir).isEmpty,
            "remote create must write NO wikis.json and NO DB files")
        #expect(
            client.wikis.map(\.displayName) == ["Cache Only"],
            "the cache reflects the daemon's reply")
        #expect(client.activeWikiID == created?.id)
    }

    @Test func remoteRenameRoutesToDaemonAndUpdatesTheCache() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)
        let created = try #require(await client.createWiki(displayName: "Before"))

        await client.renameWiki(id: created.id, to: "After")

        #expect(invoker.recordedRenames.count == 1)
        #expect(invoker.recordedRenames.first?.0 == created.id)
        #expect(invoker.recordedRenames.first?.1 == "After")
        #expect(
            containerContents(dir).isEmpty,
            "remote rename must not write wikis.json")
        #expect(
            client.wikis.map(\.displayName) == ["After"],
            "the cache reflects the daemon's rename")
    }

    @Test func remoteDeleteRoutesToDaemonAndClearsTheCache() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)
        let created = try #require(await client.createWiki(displayName: "Doomed"))
        #expect(client.activeWikiID == created.id)

        await client.deleteWiki(id: created.id)

        #expect(invoker.recordedDeletes == [created.id])
        #expect(client.wikis.isEmpty, "the cache drops the daemon-deleted wiki")
        #expect(client.activeWikiID == nil)
        #expect(containerContents(dir).isEmpty)
    }

    /// Remote mode with NO invoker injected: the op site surfaces the typed
    /// error (logged) and NOTHING is written locally — never a silent local
    /// write, never a local fallback.
    @Test func remoteWithoutInvokerSurfacesTypedErrorAndWritesNothing() async throws {
        let dir = try tempContainer()
        let client = WikiRegistryClient(containerDirectory: dir, accessMode: .remote)

        let created = await client.createWiki(displayName: "Unmediated")
        #expect(created == nil)

        // rename/delete no-op against an empty cache; nothing may appear.
        let stranger = WikiDescriptor.make(displayName: "Stranger")
        await client.renameWiki(id: stranger.id, to: "Renamed")
        await client.deleteWiki(id: stranger.id)

        #expect(client.wikis.isEmpty)
        #expect(containerContents(dir).isEmpty)
    }

    /// Export/import touch the daemon's DB files client-side — unreachable in
    /// remote mode (the daemon gains these ops in a later slice).
    @Test func remoteRefusesExportAndImportAsDaemonOwnedSurface() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)
        let created = try #require(await client.createWiki(displayName: "Guarded"))

        let destination = dir.appendingPathComponent("backup.sqlite")
        #expect(throws: WikiRegistryError.daemonOwnedSurface("export")) {
            try client.exportWiki(id: created.id, to: destination)
        }
        do {
            _ = try await client.importWiki(
                from: destination, displayName: "Imported")
            Issue.record("importWiki must throw in remote mode")
        } catch let error as WikiRegistryError {
            #expect(error == .daemonOwnedSurface("import"))
        }
        #expect(containerContents(dir).isEmpty)
    }

    // MARK: - Registry events (the read cache's refresh path)

    /// A registry event routed through ``DaemonRegistryEventFeed`` refreshes
    /// the cache; non-registry payloads (store, queue grammars) miss the
    /// decode and leave the cache untouched — the two-way disjointness in
    /// action at the feed.
    @Test func registryEventRefreshesTheReadCacheAndNonRegistryPayloadsMiss() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)
        let created = try #require(await client.createWiki(displayName: "Event Source"))
        #expect(client.wikis.count == 1)

        // Simulate the daemon's async wikis.json write landing AFTER the
        // create reply: a second wiki joins the file.
        var onDisk = WikiRegistry()
        onDisk.add(created)
        let second = WikiDescriptor.make(displayName: "Event Added")
        onDisk.add(second)
        try onDisk.save(to: dir)

        // The daemon's `wikid.registry-event.v1` envelope for that second
        // wiki — exactly what the fixture daemon pushes on its create path.
        let envelope = DaemonRegistryEventEnvelope(event: DaemonRegistryEvent(
            kind: .created, wikiID: second.id.rawValue, displayName: second.displayName))
        let routed = DaemonRegistryEventFeed.route(
            try JSONEncoder().encode(envelope), into: client)

        #expect(routed?.kind == .created)
        #expect(routed?.wikiID == second.id.rawValue)
        #expect(
            client.wikis.map(\.displayName) == ["Event Added", "Event Source"],
            "the registry event must have triggered reloadFromDisk()")

        // A STORE-event payload fails the registry decode (no `kind` field on
        // the inner event) and is ignored, cache untouched.
        let storeEnvelope = DaemonStoreEventEnvelope(event: DaemonStoreEvent(
            epoch: 1, wikiID: created.id.rawValue, sequence: 1,
            changeToken: "1:2", batch: []))
        #expect(
            DaemonRegistryEventFeed.route(
                try JSONEncoder().encode(storeEnvelope), into: client) == nil)
        #expect(client.wikis.map(\.displayName) == ["Event Added", "Event Source"])

        // A queue-grammar payload fails too (no `wire` key).
        let queuePayload = Data(#"{"itemID":"x","kind":"enqueued","payload":{}}"#.utf8)
        #expect(DaemonRegistryEventFeed.route(queuePayload, into: client) == nil)
    }

    // MARK: - Local control (DEBUG local dev is unchanged)

    /// One control test: LOCAL mode (the default) writes exactly as before —
    /// `wikis.json` AND the wiki's DB file.
    @Test func localModeControlStillWritesRegistryAndDatabaseFiles() async throws {
        let dir = try tempContainer()
        let client = WikiRegistryClient(containerDirectory: dir)

        let created = await client.createWiki(displayName: "Local Control")

        #expect(created != nil)
        let contents = containerContents(dir)
        #expect(contents.contains(WikiRegistry.fileName))
        #expect(contents.contains { $0.hasSuffix(".sqlite") })
        #expect(client.wikis.map(\.displayName) == ["Local Control"])
        #expect(client.activeWikiID == created?.id)
    }

    // MARK: - Bootstrap (first-run seed + legacy branch)

    /// Remote first-run seed: the spawn routes through the daemon (the
    /// invoker records `create("My Wiki")`), the cache picks the reply up,
    /// and the client still wrote nothing itself.
    @Test func remoteBootstrapSeedsThroughTheDaemon() async throws {
        let dir = try tempContainer()
        let invoker = RecordingInvoker(containerDirectory: dir)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)

        client.bootstrap(activateNow: true)

        try await waitFor(
            !invoker.recordedCreates.isEmpty, what: "the daemon seed create")
        try await waitFor(
            !client.wikis.isEmpty, what: "the cache to reflect the seeded wiki")
        #expect(invoker.recordedCreates == ["My Wiki"])
        #expect(client.wikis.map(\.displayName) == ["My Wiki"])
        #expect(client.activeWikiID != nil)
        #expect(
            containerContents(dir).isEmpty,
            "the first-run seed must not write wikis.json or a DB file locally")
    }

    /// Remote bootstrap's legacy branch is a deliberate NO-OP: a legacy
    /// `WikiFS.sqlite` in the container is the DAEMON's import (P3.3); the
    /// client neither imports it nor writes a registry row.
    @Test func remoteBootstrapLegacyImportIsANoOp() async throws {
        let dir = try tempContainer()
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        try Data("legacy-db-bytes".utf8).write(to: legacy)

        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote)

        client.bootstrap(activateNow: true)

        #expect(client.wikis.isEmpty, "the client must not import the legacy DB in remote mode")
        #expect(client.activeWikiID == nil)
        #expect(
            FileManager.default.fileExists(atPath: legacy.path),
            "the legacy file stays untouched — the daemon owns the import")
        #expect(
            !containerContents(dir).contains(WikiRegistry.fileName),
            "no local wikis.json write")
    }

    // MARK: - P3.3: the daemon-owned legacy import

    /// Fresh container + legacy DB present → daemon start imports: the wiki
    /// row appears, the legacy file is renamed to its ULID-keyed name, the
    /// content is readable through the daemon's store, and a second daemon is
    /// a no-op (idempotent).
    @Test func daemonStartImportsLegacyV0DatabaseIdempotently() async throws {
        let dir = try tempContainer()
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        do {
            let store = try GRDBWikiStore(databaseURL: legacy)
            let page = try store.createPage(title: "Legacy Home")
            try store.updatePage(
                id: page.id, title: "Legacy Home", body: "VERIFY-V0-CONTENT")
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        let daemon = WikiDaemon(containerDirectory: dir)
        let wikis = try JSONDecoder().decode(
            [WikiDescriptor].self, from: daemon.listWikis())

        #expect(wikis.count == 1)
        let migrated = try #require(wikis.first)
        #expect(migrated.displayName == "Self Driving Wiki")
        #expect(
            !FileManager.default.fileExists(atPath: legacy.path),
            "the legacy file was renamed, not copied")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(migrated.id.rawValue).sqlite").path))

        // Content readable through the daemon's store.
        let store = try await daemon.domainCommandStore(wikiID: migrated.id)
        let titles = try await store.listPages(sortBy: .newestFirst).map(\.title)
        #expect(titles.contains("Legacy Home"))

        // Idempotent: a second daemon start is a no-op (registry non-empty,
        // legacy file gone).
        let second = WikiDaemon(containerDirectory: dir)
        let again = try JSONDecoder().decode(
            [WikiDescriptor].self, from: second.listWikis())
        #expect(again.map(\.id) == [migrated.id])
    }

    // MARK: - Lifecycle round trip over the fixture daemon

    /// The full mediated chain against the REAL fixture daemon: create → the
    /// client cache shows it (reply + registry event) → rename → delete, with
    /// one `wikid.registry-event.v1` envelope per mutation arriving on the
    /// sink and each event refreshing the cache through the feed.
    @Test func lifecycleRoundTripOverFixtureDaemonWithRegistryEvents() async throws {
        let dir = try tempContainer()
        let daemon = WikiDaemon(containerDirectory: dir)
        let invoker = FixtureDaemonInvoker(daemon: daemon)
        let client = WikiRegistryClient(
            containerDirectory: dir, accessMode: .remote, daemonInvoker: invoker)

        // Flip a sink LIVE (register + acknowledged handshake) so the
        // daemon's registry events flow.
        let sink = RecordingSink()
        let registrationID = daemon.registerEventSink(sink)
        let handshakeRequest = DaemonStoreRequest(
            wikiID: "", operation: DaemonStoreOperation.sinkHandshake.rawValue,
            stamp: nil, payload: try JSONEncoder().encode(DaemonSinkHandshakeRequest()))
        let handshakeDomain = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: DaemonStoreOperation.sinkHandshake.rawValue,
            payload: try DaemonStoreWire.encode(handshakeRequest))
        _ = await daemon.storeCommandExecutor()
            .handleStoreOperation(handshakeDomain, sinkRegistrationID: registrationID)

        // CREATE — through the client, executed by the daemon.
        let created = try #require(await client.createWiki(displayName: "Roundtrip"))
        #expect(client.wikis.map(\.displayName) == ["Roundtrip"])
        #expect(client.activeWikiID == created.id)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(WikiRegistry.fileName).path),
            "the DAEMON wrote the registry file (the mediated create landed)")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(created.id.rawValue).sqlite").path),
            "the DAEMON created the DB file")

        // The created registry event reached the sink; the feed routes it and
        // the reload is idempotent against the reply merge.
        try await waitFor(registryEventCount(sink) >= 1, what: "the created registry event")
        let registryPayloads = decodedRegistryPayloads(sink.snapshot())
        #expect(registryPayloads.count == 1)
        #expect(registryPayloads.first?.event.kind == .created)
        #expect(registryPayloads.first?.event.wikiID == created.id.rawValue)
        #expect(registryPayloads.first?.event.displayName == "Roundtrip")
        #expect(registryPayloads.first?.wire == DaemonRegistryEventWire.marker)
        #expect(
            DaemonRegistryEventFeed.route(try #require(sink.snapshot().first), into: client) != nil)
        #expect(client.wikis.map(\.displayName) == ["Roundtrip"])

        // RENAME — through the client, executed by the daemon.
        await client.renameWiki(id: created.id, to: "Renamed Roundtrip")
        try await waitFor(registryEventCount(sink) >= 2, what: "the renamed registry event")
        #expect(client.wikis.map(\.displayName) == ["Renamed Roundtrip"])

        // DELETE — through the client, executed by the daemon; both the
        // registry row and the DB file are gone daemon-side.
        await client.deleteWiki(id: created.id)
        try await waitFor(registryEventCount(sink) >= 3, what: "the deleted registry event")
        #expect(client.wikis.isEmpty)
        #expect(client.activeWikiID == nil)
        let onDisk = try WikiRegistry.loadStrictly(from: dir)
        #expect(onDisk.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(created.id.rawValue).sqlite").path))

        // Exactly the three lifecycle events, in order, all registry grammar.
        let all = decodedRegistryPayloads(sink.snapshot())
        #expect(all.map(\.event.kind) == [.created, .renamed, .deleted])
        #expect(all.map(\.event.wikiID) == [created.id.rawValue, created.id.rawValue, created.id.rawValue])
    }
}
