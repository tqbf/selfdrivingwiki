#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid

// Phase 2c (plans/daemon-only-access.md): the daemon-side store EVENT
// CONTRACT — handshake watermarks for prepared wikis, per-(epoch, wiki)
// sequence stamping, pre-handshake bounded replay, live fanout, late wiki
// preparation, daemon-restart epoch change, and the deliverEvent envelope
// round trip (including its two-way grammar disjointness against
// `QueueEventEnvelope`).
//
// Every test drives REAL store commits through a fixture daemon's wired
// event bus (the mandatory-bus choke point in `WikiDaemon.wireEventBus`) and
// observes what a `WikiDaemonEventSink` actually receives.
//
// Note on the fixture's seeded Home page: `testFixtureCreateWiki` seeds a
// Home page, so each fixture wiki emits one `page` event before a test's own
// commits. Sequences therefore start at 1 (the Home event) and ascend per
// commit.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// waiting is a non-blocking poll — no test blocks a cooperative pool thread.
@Suite(.serialized, .timeLimit(.minutes(8)))
struct DaemonStoreEventTests {

    // MARK: - Fixtures (same shape as DaemonStoreCommandExecutorTests)

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dse-events-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func makeDaemon() throws -> WikiDaemon {
        WikiDaemon(containerDirectory: try makeContainer())
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Store Events Fixture"
    ) throws -> WikiID {
        let data = try #require(daemon.testFixtureCreateWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
    }

    /// Real store commit through the daemon's prepared-store seam — the
    /// same admitted path the executor serves, so every commit emits one
    /// `ResourceChangeEvent` onto the wired bus.
    private func commitPage(
        _ daemon: WikiDaemon, wikiID: WikiID, title: String
    ) async throws {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        _ = try await store.createPage(
            title: title, body: "event fixture body",
            createdBy: nil, provenance: [])
    }

    /// Encode one store-family request and run it through the executor.
    private func executeDomain(
        _ daemon: WikiDaemon, _ operation: DaemonStoreOperation,
        wikiID: WikiID, payload: Data? = nil,
        sinkRegistrationID: UUID? = nil
    ) async throws -> DaemonDomainReply {
        // The handshake is daemon-scoped: the wikiID rides only for
        // transport-envelope self-consistency (the client passes the wiki it
        // is opening first; the daemon ignores it).
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: operation.rawValue,
            stamp: nil, payload: payload)
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: operation.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))
        return await daemon.storeCommandExecutor()
            .handleStoreOperation(
                domainRequest, sinkRegistrationID: sinkRegistrationID)
    }

    private func storeReply(
        _ domainReply: DaemonDomainReply
    ) throws -> DaemonStoreReply {
        let payload = try #require(
            domainReply.payload, "expected a success envelope payload")
        return try DaemonStoreWire.decodeReply(payload)
    }

    /// Register a sink and complete its acknowledged handshake through the
    /// executor's `sinkHandshake` operation, exactly as the XPC exporter
    /// threads the connection's registration id.
    @discardableResult
    private func registerAndHandshake(
        _ daemon: WikiDaemon, wikiID: WikiID
    ) async throws -> (sink: RecordingSink, registrationID: UUID, reply: DaemonSinkHandshakeReply) {
        let sink = RecordingSink()
        let registrationID = daemon.registerEventSink(sink)
        let payload = try JSONEncoder().encode(DaemonSinkHandshakeRequest())
        let domainReply = try await executeDomain(
            daemon, .sinkHandshake, wikiID: wikiID, payload: payload,
            sinkRegistrationID: registrationID)
        let reply = try storeReply(domainReply)
        #expect(reply.error == nil)
        let handshake = try JSONDecoder().decode(
            DaemonSinkHandshakeReply.self, from: #require(reply.result))
        return (sink, registrationID, handshake)
    }

    /// Non-blocking completion poll (AGENTS.md #1051): waits until the sink
    /// holds at least `count` STORE-grammar payloads, with a diagnosed
    /// timeout. Phase 3 slice 2: the firehose also carries registry-event
    /// envelopes, so the count is over the store grammar (what every caller
    /// of this helper asserts on), not the raw payload array.
    private func waitForDeliveries(
        _ sink: RecordingSink, count: Int, timeout: Duration = .seconds(10)
    ) async throws -> [Data] {
        let deadline = ContinuousClock.now + timeout
        while (try? decodedEnvelopes(sink.snapshot()))?.count ?? 0 < count {
            if ContinuousClock.now >= deadline {
                let have = sink.snapshot().count
                Issue.record(
                    "timed out waiting for \(count) deliveries; have \(have) raw")
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return sink.snapshot()
    }

    private func decodedEnvelopes(_ payloads: [Data]) throws
        -> [DaemonStoreEventEnvelope] {
        // Phase 3 slice 2: the firehose now also carries
        // `wikid.registry-event.v1` envelopes (one per fixture-daemon create).
        // The store decoder dispatches by grammar — a payload that decodes as
        // a store envelope with the store marker is a store event; everything
        // else belongs to another grammar's consumer. (The filter is
        // non-throwing; the `throws` signature is kept for the callers.)
        payloads.compactMap { data -> DaemonStoreEventEnvelope? in
            guard let envelope = try? JSONDecoder().decode(
                DaemonStoreEventEnvelope.self, from: data),
                envelope.wire == DaemonStoreEventWire.marker
            else { return nil }
            return envelope
        }
    }

    // MARK: - Handshake watermarks

    @Test func handshakeCoversPreparedWikisOnlyWithEpochAndWatermarks()
        async throws {
        let daemon = try makeDaemon()
        let wikiA = try fixtureWiki(daemon, name: "Events Prepared A")
        let wikiB = try fixtureWiki(daemon, name: "Events Prepared B")
        // Close B: the fixture daemon holds no profile services, so the
        // close removes the held store — B stays REGISTERED but is no
        // longer PREPARED, exactly the boundary the handshake reports.
        await daemon.closeStore(wikiID: wikiB)

        let (_, _, handshake) = try await registerAndHandshake(daemon, wikiID: wikiA)

        #expect(handshake.daemonEpoch == daemon.daemonEpoch)
        #expect(handshake.perWiki.map(\.wikiID) == [wikiA.rawValue])
        let watermark = try #require(handshake.perWiki.first)
        // No live sink existed when A's seeded Home event stamped, so
        // nothing was delivered yet: the delivery watermark is 0.
        #expect(watermark.lastSequence == 0)
        // A real token (colon-joined folds), never the sentinel or empty.
        #expect(!watermark.changeToken.isEmpty)
        #expect(watermark.changeToken != WikiDaemon.errorTokenSentinel)
        #expect(watermark.changeToken.contains(":"))
    }

    // MARK: - Sequence stamping + batch completeness

    @Test func eventsCarryEpochAndMonotonicPerWikiSequencesWithCompleteBatches()
        async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let (sink, _, _) = try await registerAndHandshake(daemon, wikiID: wikiID)

        try await commitPage(daemon, wikiID: wikiID, title: "Seq One")
        try await commitPage(daemon, wikiID: wikiID, title: "Seq Two")
        let envelopes = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 3))

        for envelope in envelopes {
            #expect(envelope.event.epoch == daemon.daemonEpoch)
            #expect(envelope.event.wikiID == wikiID.rawValue)
            #expect(envelope.wire == DaemonStoreEventWire.marker)
            // One commit = one complete batch (one event today).
            #expect(envelope.event.batch.count == 1)
            let mirror = try #require(envelope.event.batch.first)
            #expect(mirror.kind == "page")
            #expect(mirror.change == "created")
            #expect(!mirror.id.isEmpty)
        }
        // Home event first, then the two commits: strictly increasing.
        let sequences = envelopes.map(\.event.sequence)
        #expect(sequences == [1, 2, 3])
    }

    // MARK: - Pre-handshake buffering + exactly-once replay

    @Test func preHandshakeCommitsReplayExactlyOnceInSequenceOrderThenLive()
        async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        // Register WITHOUT the handshake: commits now buffer for this sink.
        let sink = RecordingSink()
        let registrationID = daemon.registerEventSink(sink)

        try await commitPage(daemon, wikiID: wikiID, title: "Buffered One")
        try await commitPage(daemon, wikiID: wikiID, title: "Buffered Two")
        // Nothing delivered to an unhandshaken sink.
        #expect(sink.snapshot().isEmpty)

        let payload = try JSONEncoder().encode(DaemonSinkHandshakeRequest())
        let domainReply = try await executeDomain(
            daemon, .sinkHandshake, wikiID: wikiID, payload: payload,
            sinkRegistrationID: registrationID)
        #expect(try storeReply(domainReply).error == nil)

        // Replay: Home (1) + the two buffered commits (2, 3) — the delivery
        // watermark was 0, so the whole ring replays in sequence order.
        let replayed = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 3))
        #expect(replayed.map(\.event.sequence) == [1, 2, 3])

        // Then live: one more commit delivers exactly once.
        try await commitPage(daemon, wikiID: wikiID, title: "Live After")
        let settled = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 4))
        try await Task.sleep(for: .milliseconds(200))
        #expect(settled.count == 4)
        #expect(settled.map(\.event.sequence) == [1, 2, 3, 4])
    }

    // MARK: - Bounded ring

    @Test func ringOverflowDropsOldestAndHandshakeStillDeliversSurvivors()
        async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let sink = RecordingSink()
        let registrationID = daemon.registerEventSink(sink)

        // 260 commits on top of the seeded Home event (261 stamps total);
        // the 256-entry ring retains the newest entries (sequences
        // 6...261) and drops the oldest 5 — each drop is logged through
        // DebugLog.store (behavior pinned by the surviving first sequence).
        for index in 0..<260 {
            try await commitPage(
                daemon, wikiID: wikiID, title: "Ring Fill \(index)")
        }
        // Ingest rides the bus's async handler tasks — a commit returning
        // does not mean its stamp landed in the ring. Wait for the full
        // count (261 = seeded Home + 260 commits) before handshaking, or
        // the handshake races trailing ingests and stragglers arrive as
        // live deliveries with post-handshake sequences.
        let ingestDeadline = ContinuousClock.now + .seconds(10)
        while daemon.storeEvents.ingestedSequenceCount(
            wikiID: wikiID.rawValue) < 261 {
            if ContinuousClock.now >= ingestDeadline {
                let have = daemon.storeEvents.ingestedSequenceCount(
                    wikiID: wikiID.rawValue)
                Issue.record(
                    "timed out waiting for event ingest; have \(have) of 261")
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sink.snapshot().isEmpty)

        let payload = try JSONEncoder().encode(DaemonSinkHandshakeRequest())
        let domainReply = try await executeDomain(
            daemon, .sinkHandshake, wikiID: wikiID, payload: payload,
            sinkRegistrationID: registrationID)
        let handshake = try JSONDecoder().decode(
            DaemonSinkHandshakeReply.self, from: #require(
                try storeReply(domainReply).result))
        #expect(handshake.daemonEpoch == daemon.daemonEpoch)

        // Replay delivers exactly the survivors, oldest-dropped semantics
        // visible as a first sequence of 6 (= 261 stamps - 256 capacity).
        let replayed = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 256))
        #expect(replayed.count == 256)
        #expect(replayed.first?.event.sequence == 6)
        let sequences = replayed.map(\.event.sequence)
        #expect(sequences == Array(6...261))

        // Live flow continues above the replay with no gap.
        try await commitPage(daemon, wikiID: wikiID, title: "Ring Live")
        let settled = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 257))
        #expect(settled.count == 257)
        #expect(settled.last?.event.sequence == 262)
    }

    // MARK: - Live fanout

    @Test func twoLiveSinksEachReceiveEveryEventAfterTheirHandshake()
        async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let (sinkA, _, _) = try await registerAndHandshake(daemon, wikiID: wikiID)
        let (sinkB, _, _) = try await registerAndHandshake(daemon, wikiID: wikiID)

        try await commitPage(daemon, wikiID: wikiID, title: "Fanout One")
        try await commitPage(daemon, wikiID: wikiID, title: "Fanout Two")

        let envelopesA = try decodedEnvelopes(
            await waitForDeliveries(sinkA, count: 3))
        let envelopesB = try decodedEnvelopes(
            await waitForDeliveries(sinkB, count: 2))

        // A handshook first (delivery watermark 0), so its replay includes
        // the seeded Home event; B handshook after A was live — the Home
        // commit was already DELIVERED (watermark 1), so B's replay is
        // empty by design and B catches it through the handshake token.
        #expect(envelopesA.map(\.event.sequence) == [1, 2, 3])
        #expect(envelopesB.map(\.event.sequence) == [2, 3])
        // Every event emitted while both were live reached BOTH sinks.
        #expect(
            envelopesB.map(\.event.batch.first?.id)
                == envelopesA.suffix(2).map(\.event.batch.first?.id))
    }

    // MARK: - Late wiki preparation

    @Test func wikiPreparedAfterSinkRegistrationFlowsOncePrepared()
        async throws {
        let daemon = try makeDaemon()
        // No wiki exists yet. The handshake is daemon-scoped: the request's
        // wikiID is transport consistency only.
        let sink = RecordingSink()
        let registrationID = daemon.registerEventSink(sink)
        let payload = try JSONEncoder().encode(DaemonSinkHandshakeRequest())
        let domainReply = try await executeDomain(
            daemon, .sinkHandshake,
            wikiID: WikiID(rawValue: "01JWIKI0000000000000000AB"),
            payload: payload, sinkRegistrationID: registrationID)
        let handshake = try JSONDecoder().decode(
            DaemonSinkHandshakeReply.self, from: #require(
                try storeReply(domainReply).result))
        #expect(handshake.daemonEpoch == daemon.daemonEpoch)
        #expect(handshake.perWiki.isEmpty)

        // NOW a wiki prepares (creation wires + caches the store — the
        // same choke point the production prepare path uses).
        let wikiID = try fixtureWiki(daemon)
        try await commitPage(daemon, wikiID: wikiID, title: "Late Prepared")

        let envelopes = try decodedEnvelopes(
            await waitForDeliveries(sink, count: 2))
        // The live sink receives the late-prepared wiki's events: the
        // seeded Home event (1) then the commit (2), both for the new wiki.
        #expect(envelopes.map(\.event.sequence) == [1, 2])
        for envelope in envelopes {
            #expect(envelope.event.wikiID == wikiID.rawValue)
            #expect(envelope.event.epoch == daemon.daemonEpoch)
        }
    }

    // MARK: - Daemon restart epoch change

    @Test func freshDaemonCarriesNewEpochAndSequenceRestartsLow()
        async throws {
        let daemonA = try makeDaemon()
        let wikiA = try fixtureWiki(daemonA, name: "Epoch A")
        let (sinkA, _, _) = try await registerAndHandshake(daemonA, wikiID: wikiA)
        try await commitPage(daemonA, wikiID: wikiA, title: "Epoch One")
        try await commitPage(daemonA, wikiID: wikiA, title: "Epoch Two")
        let envelopesA = try decodedEnvelopes(
            await waitForDeliveries(sinkA, count: 3))
        let lastSequenceA = try #require(envelopesA.last?.event.sequence)
        #expect(lastSequenceA == 3)

        // "Restart": a fresh daemon instance claims the next global epoch.
        let daemonB = try makeDaemon()
        #expect(daemonB.daemonEpoch != daemonA.daemonEpoch)

        let wikiB = try fixtureWiki(daemonB, name: "Epoch B")
        let (sinkB, _, handshakeB) = try await registerAndHandshake(
            daemonB, wikiID: wikiB)
        try await commitPage(daemonB, wikiID: wikiB, title: "Epoch Fresh")
        let envelopesB = try decodedEnvelopes(
            await waitForDeliveries(sinkB, count: 2))

        // The fresh daemon's envelopes carry ITS epoch and its sequences
        // start low again — a client holding epoch A's watermark treats
        // these as a new epoch (epoch-keyed watermarks), never as stale
        // duplicates of A's higher sequence.
        for envelope in envelopesB {
            #expect(envelope.event.epoch == daemonB.daemonEpoch)
            #expect(envelope.event.epoch != daemonA.daemonEpoch)
        }
        #expect(envelopesB.map(\.event.sequence) == [1, 2])
        #expect(handshakeB.daemonEpoch == daemonB.daemonEpoch)
        #expect(lastSequenceA > envelopesB.map(\.event.sequence).last ?? 0)
    }

    // MARK: - Envelope round trip (contract)

    @Test func storeEventEnvelopeRoundTripsAndStaysDisjointFromQueueEnvelope()
        throws {
        let event = DaemonStoreEvent(
            epoch: 7,
            wikiID: "01JWIKI0000000000000000AB",
            sequence: 42,
            changeToken: "1:2:3:4:5:6:7:8:9:10:11:12:13:14:15:16:17",
            batch: [
                DaemonResourceChangeEvent(
                    kind: "page", id: "01PAGE0000000000000000AA",
                    change: "created", seq: 1),
                DaemonResourceChangeEvent(
                    kind: "source", id: "01SRCE0000000000000000AA",
                    change: "updated", seq: 2),
            ])
        let envelope = DaemonStoreEventEnvelope(event: event)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            DaemonStoreEventEnvelope.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.wire == DaemonStoreEventWire.marker)
        #expect(decoded.event.batch.count == 2)
        #expect(decoded.event.batch.map(\.change) == ["created", "updated"])
        #expect(decoded.event.batch.map(\.seq) == [1, 2])

        // Grammar disjointness (both directions): a store envelope is NOT a
        // queue envelope (no `kind` key) and a queue envelope is NOT a
        // store envelope (no `wire`/`event`) — the app's decoder dispatches
        // deterministically either by try order or by the marker.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        }
        let queueJSON = try JSONEncoder().encode(
            QueueEventEnvelope(kind: .enqueued))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonStoreEventEnvelope.self, from: queueJSON)
        }

        // Phase 3 slice 2: the registry grammar joins the firehose — the
        // store envelope must also NOT be a registry envelope (its inner
        // event has no `kind` field), and the queue envelope still misses it.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonRegistryEventEnvelope.self, from: data)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonRegistryEventEnvelope.self, from: queueJSON)
        }
    }

    /// The `wikid.registry-event.v1` envelope round-trips and stays pairwise
    /// two-way disjoint against BOTH other firehose grammars: a registry
    /// payload fails the queue decode (no top-level `kind`) AND the store
    /// decode (the inner event lacks `epoch`/`sequence`/`changeToken`/
    /// `batch`); queue and store payloads fail the registry decode. Three
    /// deterministically dispatchable grammars on one channel.
    @Test func registryEventEnvelopeRoundTripsAndStaysDisjointFromQueueAndStore()
        throws {
        let event = DaemonRegistryEvent(
            kind: .renamed, wikiID: "01JWIKI0000000000000000CD",
            displayName: "Renamed Wiki")
        let envelope = DaemonRegistryEventEnvelope(event: event)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            DaemonRegistryEventEnvelope.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.wire == DaemonRegistryEventWire.marker)
        #expect(decoded.event.kind == .renamed)
        #expect(decoded.event.wikiID == "01JWIKI0000000000000000CD")
        #expect(decoded.event.displayName == "Renamed Wiki")

        // vs queue: no top-level `kind` on the registry envelope; the queue
        // envelope has no `wire`.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        }
        let queueJSON = try JSONEncoder().encode(
            QueueEventEnvelope(kind: .enqueued))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonRegistryEventEnvelope.self, from: queueJSON)
        }

        // vs store: `DaemonStoreEvent` requires `epoch` (missing on a
        // registry event); `DaemonRegistryEvent` requires `kind` (missing on
        // a store event). The markers differ too.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonStoreEventEnvelope.self, from: data)
        }
        let storeJSON = try JSONEncoder().encode(DaemonStoreEventEnvelope(event: DaemonStoreEvent(
            epoch: 7, wikiID: "01JWIKI0000000000000000CD", sequence: 1,
            changeToken: "1:2:3", batch: [])))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DaemonRegistryEventEnvelope.self, from: storeJSON)
        }
    }
}

// MARK: - Sink double

/// A `WikiDaemonEventSink` double that records every `deliverEvent` payload.
/// Deliveries arrive from the bus's main-actor handlers and the
/// coordinator's handshake path; the array is lock-guarded.
private final class RecordingSink: NSObject, WikiDaemonEventSink,
    @unchecked Sendable {
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
#endif
