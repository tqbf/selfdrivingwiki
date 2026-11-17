#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import wikid

// AC.10 (plans/daemon-only-access.md): the mutation OUTCOME semantics over
// the REAL domain-socket transport against a fixture daemon. Every scenario
// drives hand-stamped requests through the same executor path the client
// uses, so the exactly-once contract is observed on the wire, not in a
// ledger unit double:
//
// 1. Concurrent identical duplicates JOIN — one store commit (exactly one
//    created event, one page), both replies carry the same outcome + stamp.
// 2. A reused requestID with a DIFFERENT payload fingerprint is a typed
//    rejection (never a join, never a second execution).
// 3. An epoch mismatch is the typed contract case with BOTH epochs intact.
// 4. A committed retry (same ID, same fingerprint) returns the cached
//    outcome — byte-identical reply, no re-execution; `resolveOutcome`
//    resolves the same cached bytes without dispatching.
// 5. Past the bounded cache (64 per wiki), a resolve answers
//    `outcomeUnknown` and dispatches NOTHING — the mutation and event
//    counts stay unchanged — while a genuinely fresh ID still executes.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`,
// non-blocking completion polls only.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct RemoteStoreDedupeTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rsd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Dedupe Fixture"
    ) throws -> WikiID {
        let data = try #require(daemon.testFixtureCreateWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
    }

    private func makeSocketServer(
        _ container: URL, _ daemon: WikiDaemon
    ) throws -> DaemonSearchSocketServer {
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) {
            data in
            await dispatcher.handle(data)
        }
        try server.start()
        return server
    }

    private func socketTransport(
        _ container: URL, timeout: TimeInterval = 30
    ) throws -> DomainSocketStoreTransport {
        DomainSocketStoreTransport(client: try DaemonDomainSocketClient(
            containerDirectory: container, timeout: timeout))
    }

    /// Lock-guarded bus recorder (handlers run on the main actor).
    private final class BusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []

        func record(_ event: ResourceChangeEvent) {
            lock.withLock { events.append(event) }
        }

        func snapshot() -> [ResourceChangeEvent] {
            lock.withLock { events }
        }
    }

    /// A registered client-shaped sink: the store IS the connection's sink
    /// (the app wiring's shape), so commits replay onto the bus recorder.
    /// The sink's transport is the IN-PROCESS executor — the domain socket
    /// has no reverse-push channel, so the handshake's sink correlation
    /// (flipping the sink live) only works through the executor path
    /// (RemoteWikiStoreTests' established pattern).
    private struct ExecutorTransport: RemoteWikiStoreTransport {
        let daemon: WikiDaemon

        var connectionIdentifier: String? { nil }

        func send(
            _ request: DaemonDomainRequest,
            sinkRegistrationID: UUID?
        ) async throws -> DaemonDomainReply {
            await daemon.storeCommandExecutor().handleStoreOperation(
                request, sinkRegistrationID: sinkRegistrationID)
        }
    }

    private func makeSink(
        daemon: WikiDaemon, container: URL, wikiID: WikiID
    ) throws -> (remote: RemoteWikiStore, recorder: BusRecorder) {
        let remote = RemoteWikiStore(
            transport: ExecutorTransport(daemon: daemon), wikiID: wikiID)
        let recorder = BusRecorder()
        let bus = WikiEventBus(wikiID: wikiID)
        remote.eventBus = bus
        _ = bus.subscribe(nil) { [recorder] event in
            recorder.record(event)
        }
        let registrationID = daemon.registerEventSink(remote)
        remote.registerSink(registrationID: registrationID)
        return (remote, recorder)
    }

    /// Non-blocking completion poll (AGENTS.md #1051).
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        what: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The admission fingerprint: SHA-256 over the operation string then
    /// the payload bytes (the executor's own computation).
    private static func fingerprint(
        operation: DaemonStoreOperation, payload: Data?
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(operation.rawValue.utf8))
        hasher.update(data: payload ?? Data())
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One raw stamped store round trip over the real socket.
    private func sendStamped(
        _ transport: DomainSocketStoreTransport, wikiID: WikiID,
        operation: DaemonStoreOperation, payload: Data,
        stamp: DaemonMutationStamp
    ) async throws -> DaemonStoreReply {
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: operation.rawValue,
            stamp: stamp, payload: payload)
        return try await sendEnvelope(transport, storeRequest)
    }

    /// One raw unstamped store round trip over the real socket.
    private func sendPlain(
        _ transport: DomainSocketStoreTransport, wikiID: WikiID,
        operation: DaemonStoreOperation, payload: Data? = nil
    ) async throws -> DaemonStoreReply {
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: operation.rawValue,
            payload: payload)
        return try await sendEnvelope(transport, storeRequest)
    }

    private func sendEnvelope(
        _ transport: DomainSocketStoreTransport, _ storeRequest: DaemonStoreRequest
    ) async throws -> DaemonStoreReply {
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: storeRequest.operation,
            payload: try DaemonStoreWire.encode(storeRequest))
        let reply = try await transport.send(
            domainRequest, sinkRegistrationID: nil)
        if let domainError = reply.error {
            Issue.record(
                "domain rejection \(domainError.code.rawValue): \(domainError.message)")
        }
        guard let payloadData = reply.payload else {
            Issue.record("\(storeRequest.operation) carried no reply payload")
            throw CancellationError()
        }
        return try DaemonStoreWire.decodeReply(payloadData)
    }

    private func setMetadataPayload(
        key: String, value: String
    ) throws -> Data {
        try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: key, value: value))
    }

    // MARK: - 1. Concurrent identical duplicates JOIN

    @Test func concurrentIdenticalDuplicatesJoinOneStoreCommit()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let sink = try makeSink(
            daemon: daemon, container: container, wikiID: wikiID)
        try await sink.remote.warmSession()
        let epoch = try #require(sink.remote.sessionEpoch())
        // Settle the fixture's Home replay so the baseline is quiet.
        try await Task.sleep(for: .milliseconds(300))
        let baseline = sink.recorder.snapshot().count

        let transport = try socketTransport(container)
        // ONE body, staged ONCE; both duplicates reference the same
        // handle, the same title, and carry byte-identical payloads.
        let remote = sink.remote
        let handle = try await remote.stageUpload(Data("joined body".utf8))
        let payload = try JSONEncoder().encode(DaemonUpsertPageRequest(
            pageID: nil, title: "Joined Page", rawBody: handle,
            expectation: .expectedAbsence, author: "dedupe-tests",
            provenance: []))
        let stamp = DaemonMutationStamp(
            requestID: ULID.generate(), expectedEpoch: epoch)

        async let first: DaemonStoreReply = sendStamped(
            transport, wikiID: wikiID, operation: .upsertPage,
            payload: payload, stamp: stamp)
        async let second: DaemonStoreReply = sendStamped(
            transport, wikiID: wikiID, operation: .upsertPage,
            payload: payload, stamp: stamp)
        let (replyA, replyB) = try await (first, second)

        #expect(replyA.error == nil)
        #expect(replyB.error == nil)
        let bytesA = try #require(replyA.result)
        let bytesB = try #require(replyB.result)
        let outcomeA = try JSONDecoder().decode(
            DaemonUpsertPageReply.self, from: bytesA)
        let outcomeB = try JSONDecoder().decode(
            DaemonUpsertPageReply.self, from: bytesB)

        // Both replies: same outcome + stamp, same result (one execution's
        // bytes — exactly-once observable on the replies themselves).
        #expect(outcomeA.outcome.stamp.requestID == stamp.requestID)
        #expect(outcomeB.outcome.stamp.requestID == stamp.requestID)
        #expect(outcomeA.outcome.stamp.expectedEpoch == epoch)
        #expect(outcomeB.outcome.stamp.expectedEpoch == epoch)
        #expect(outcomeA.result.id == outcomeB.result.id)
        #expect(outcomeA.result.didCreate == true)
        #expect(outcomeA == outcomeB)

        // ONE store commit: exactly one created event beyond the baseline,
        // and exactly one page with the title.
        try await waitFor(
            { sink.recorder.snapshot().count > baseline },
            what: "the joined commit's event to reach the bus")
        try await Task.sleep(for: .milliseconds(300))
        let newEvents = sink.recorder.snapshot()[baseline...]
        #expect(newEvents.count == 1)
        #expect(newEvents.allSatisfy { $0.change == .created })
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let pages = try await store.listPages(sortBy: .titleAZ)
        #expect(pages.filter { $0.title == "Joined Page" }.count == 1)
    }

    // MARK: - 2. Reused requestID, different fingerprint → typed rejection

    @Test func reusedRequestIDWithDifferentPayloadIsRejectedTyped()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        try await remote.warmSession()
        let epoch = try #require(remote.sessionEpoch())
        let transport = try socketTransport(container)

        let original = try setMetadataPayload(key: "fingerprint", value: "one")
        let stamp = DaemonMutationStamp(
            requestID: ULID.generate(), expectedEpoch: epoch)
        let committed = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: original, stamp: stamp)
        #expect(committed.error == nil)

        // SAME ID, DIFFERENT content: the typed rejection, never a join.
        let mutated = try setMetadataPayload(key: "fingerprint", value: "two")
        let rejected = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: mutated, stamp: stamp)
        let wireError = try #require(rejected.error)
        guard case .unexpected(let message) = wireError else {
            Issue.record("expected the typed unexpected rejection, got \(wireError)")
            return
        }
        #expect(message.contains("already admitted with a different"))
        #expect(message.contains("fingerprint"))

        // The store kept the ORIGINAL value (the mutated write never ran).
        let read = try await sendPlain(
            transport, wikiID: wikiID, operation: .getMetadata,
            payload: try JSONEncoder().encode(DaemonGetMetadataRequest(key: "fingerprint")))
        let metadata = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(read.result))
        #expect(metadata.value == "one")
    }

    // MARK: - 3. Epoch mismatch → the typed contract case

    @Test func epochMismatchIsTypedWithBothEpochsIntact() async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        try await remote.warmSession()
        let epoch = try #require(remote.sessionEpoch())
        let transport = try socketTransport(container)

        let payload = try setMetadataPayload(key: "epoch", value: "v")
        let staleStamp = DaemonMutationStamp(
            requestID: ULID.generate(), expectedEpoch: epoch + 1)
        let reply = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: payload, stamp: staleStamp)
        let wireError = try #require(reply.error)
        guard case .epochMismatch(let expected, let actual) = wireError else {
            Issue.record("expected the typed epoch mismatch, got \(wireError)")
            return
        }
        #expect(expected == epoch + 1)
        #expect(actual == epoch)

        // The client-side reconstruction: BOTH epochs cross intact.
        let reconstructed = RemoteWikiStore.reconstructStoreError(wireError)
        guard case .epochMismatch(
            let expectedEpoch, let actualEpoch, _) = reconstructed
            as? RemoteStoreClientError else {
            Issue.record("expected the typed client reconstruction")
            return
        }
        #expect(expectedEpoch == epoch + 1)
        #expect(actualEpoch == epoch)
    }

    // MARK: - 4. Committed retry → the cached outcome

    @Test func committedRetryReturnsTheCachedOutcome() async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        try await remote.warmSession()
        let epoch = try #require(remote.sessionEpoch())
        let transport = try socketTransport(container)

        let payload = try setMetadataPayload(key: "cache", value: "kept")
        let stamp = DaemonMutationStamp(
            requestID: ULID.generate(), expectedEpoch: epoch)
        let first = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: payload, stamp: stamp)
        #expect(first.error == nil)
        let firstBytes = try #require(first.result)

        // RETRY: the SAME ID + the SAME fingerprint answers the cached
        // outcome — byte-identical reply DTO, no second execution.
        let retry = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: payload, stamp: stamp)
        #expect(retry.error == nil)
        #expect(retry.result == firstBytes)

        // RESOLVE-ONLY: the cached outcome resolves WITHOUT dispatching.
        let resolve = DaemonResolveOutcomeRequest(
            wikiID: wikiID.rawValue, stamp: stamp,
            operation: DaemonStoreOperation.setMetadata.rawValue,
            payloadFingerprintSHA256Hex: Self.fingerprint(
                operation: .setMetadata, payload: payload))
        let resolved = try await sendPlain(
            transport, wikiID: wikiID, operation: .resolveOutcome,
            payload: try JSONEncoder().encode(resolve))
        #expect(resolved.error == nil)
        let resolveReply = try JSONDecoder().decode(
            DaemonResolveOutcomeReply.self, from: #require(resolved.result))
        // The resolve reports the WINNING submission's outcome (committed
        // — this resolve reads the cache, it never dispatches).
        #expect(resolveReply.status == .committed)
        #expect(resolveReply.result == firstBytes)
    }

    // MARK: - 5. Post-eviction resolve → outcomeUnknown; fresh ID executes

    @Test func postEvictionResolveIsOutcomeUnknownAndDispatchesNothing()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let sink = try makeSink(
            daemon: daemon, container: container, wikiID: wikiID)
        try await sink.remote.warmSession()
        let epoch = try #require(sink.remote.sessionEpoch())
        try await Task.sleep(for: .milliseconds(300))
        let eventBaseline = sink.recorder.snapshot().count
        let transport = try socketTransport(container)

        // 65 distinct stamped mutations on ONE wiki: the bounded cache
        // (64 requestIDs) evicts the OLDEST.
        let capacity = DaemonStoreLimits.outcomeCacheCapacity
        var stamps: [(stamp: DaemonMutationStamp, payload: Data)] = []
        for index in 0..<(capacity + 1) {
            let payload = try setMetadataPayload(
                key: "evict-\(index)", value: "v\(index)")
            let stamp = DaemonMutationStamp(
                requestID: ULID.generate(), expectedEpoch: epoch)
            let reply = try await sendStamped(
                transport, wikiID: wikiID, operation: .setMetadata,
                payload: payload, stamp: stamp)
            #expect(reply.error == nil)
            stamps.append((stamp, payload))
        }
        let oldest = stamps[0]

        // RESOLVE the evicted ID: outcomeUnknown, and the resolve must
        // NEVER dispatch (the mutation + event counts stay unchanged).
        let resolve = DaemonResolveOutcomeRequest(
            wikiID: wikiID.rawValue, stamp: oldest.stamp,
            operation: DaemonStoreOperation.setMetadata.rawValue,
            payloadFingerprintSHA256Hex: Self.fingerprint(
                operation: .setMetadata, payload: oldest.payload))
        let resolved = try await sendPlain(
            transport, wikiID: wikiID, operation: .resolveOutcome,
            payload: try JSONEncoder().encode(resolve))
        #expect(resolved.error == nil)
        let resolveReply = try JSONDecoder().decode(
            DaemonResolveOutcomeReply.self, from: #require(resolved.result))
        #expect(resolveReply.status == .outcomeUnknown)
        #expect(resolveReply.result == nil)
        #expect(resolveReply.message != nil)

        // The re-cent read still holds the committed value — the resolve
        // re-executed nothing (the key's value is what submission #1 wrote).
        let read = try await sendPlain(
            transport, wikiID: wikiID, operation: .getMetadata,
            payload: try JSONEncoder().encode(
                DaemonGetMetadataRequest(key: "evict-0")))
        let metadata = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(read.result))
        #expect(metadata.value == "v0")
        #expect(
            sink.recorder.snapshot().count == eventBaseline,
            "the outcomeUnknown resolve must not emit — setMetadata is a no-emit mutator and the resolve dispatches nothing")

        // A genuinely FRESH ID still executes after the eviction.
        let freshPayload = try setMetadataPayload(key: "evict-fresh", value: "new")
        let fresh = try await sendStamped(
            transport, wikiID: wikiID, operation: .setMetadata,
            payload: freshPayload,
            stamp: DaemonMutationStamp(
                requestID: ULID.generate(), expectedEpoch: epoch))
        #expect(fresh.error == nil)
        let freshReply = try JSONDecoder().decode(
            DaemonSetMetadataReply.self, from: #require(fresh.result))
        #expect(freshReply.outcome.stamp.requestID != oldest.stamp.requestID)
        let freshRead = try await sendPlain(
            transport, wikiID: wikiID, operation: .getMetadata,
            payload: try JSONEncoder().encode(
                DaemonGetMetadataRequest(key: "evict-fresh")))
        let freshMetadata = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(freshRead.result))
        #expect(freshMetadata.value == "new")
    }
}
#endif
