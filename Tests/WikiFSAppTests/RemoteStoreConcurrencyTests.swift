#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import wikid

// AC.10 (plans/daemon-only-access.md): the daemon integrity invariants
// over the REAL domain-socket transport against a fixture daemon:
//
// 1. Competing CAS upserts with the SAME expected head — exactly one
//    winner; the loser surfaces `PageConflictError` with both version IDs.
// 2. A failed expectation write inside `upsertPage` commits NOTHING and
//    emits NOTHING (the composed atomic op's rollback discipline).
// 3. Exactly ONE event batch per commit — N sequential commits produce N
//    envelopes with contiguous sequences (no dupes, no gaps).
// 4. Concurrent reads during writes return CONSISTENT snapshots — every
//    observed body is exactly one of the committed versions, never
//    partial or mixed.
// 5. Cancelling an in-flight mutation leaves no partial state — the page
//    is either absent or FULLY committed, never in between.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`,
// non-blocking completion polls only.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct RemoteStoreConcurrencyTests {

    init() {
        // The cancellation test force-closes a client connection mid-call;
        // the in-process socket server's reply write to the vanished peer
        // would otherwise raise SIGPIPE and kill the test process (the
        // #1422 mid-run-death signature). Ignoring SIGPIPE turns that
        // write into an EPIPE error the server can handle — the same
        // guard every long-lived socket process here installs.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Fixtures

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rsc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Concurrency Fixture"
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

    /// The sink's transport is the IN-PROCESS executor — the domain socket
    /// has no reverse-push channel, so the handshake's sink correlation
    /// (flipping the sink live) only works through the executor path
    /// (RemoteWikiStoreTests' established pattern).
    private struct SinkExecutorTransport: RemoteWikiStoreTransport {
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
            transport: SinkExecutorTransport(daemon: daemon), wikiID: wikiID)
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

    /// One CAS race write, resolved to a discriminated outcome (a nested
    /// do/catch around this call tripped the compiler's unreachable-catch
    /// analysis; a suite method context does not).
    private enum CASWriteResult {
        case won
        case conflict(PageConflictError)
        case failed(Error)
    }

    private func casWrite(
        _ writer: RemoteWikiStore, pageID: PageID,
        expectedHead: PageVersionID, body: String
    ) async -> CASWriteResult {
        do {
            let outcome = try await writer.upsertPage(
                id: pageID, title: "CAS Race", rawBody: body,
                expectation: .expectedHead(expectedHead), author: nil,
                provenance: [])
            _ = outcome
            return .won
        } catch {
            if let conflict = error as? PageConflictError {
                return .conflict(conflict)
            }
            return .failed(error)
        }
    }

    // MARK: - 1. Competing CAS upserts: exactly one winner

    @Test func competingCASUpsertsElectExactlyOneWinner() async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let created = try await remote.upsertPage(
            id: nil, title: "CAS Race", rawBody: "base",
            expectation: .expectedAbsence, author: nil, provenance: [])
        let head = try await remote.pageHeadVersionID(pageID: created.id)
        let expectedHead = try #require(head)

        // TWO writers, the SAME expected head, different bodies. Exactly
        // one wins; the loser surfaces PageConflictError with BOTH version
        // IDs intact (its stale expectation + the winner's new head).
        let writerA = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let writerB = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        async let resultA = casWrite(
            writerA, pageID: created.id, expectedHead: expectedHead,
            body: "winner-body-A")
        async let resultB = casWrite(
            writerB, pageID: created.id, expectedHead: expectedHead,
            body: "winner-body-B")
        let (a, b) = await (resultA, resultB)

        let winners = [a, b].enumerated().compactMap { pair -> String? in
            if case .won = pair.element { return ["A", "B"][pair.offset] }
            return nil
        }
        let conflicts = [a, b].compactMap { result -> PageConflictError? in
            if case .conflict(let error) = result { return error }
            return nil
        }
        #expect(winners.count == 1, "exactly one writer must win")
        #expect(conflicts.count == 1, "exactly one writer must lose")
        if let loser = conflicts.first {
            #expect(loser.expectedVersionID == expectedHead)
        }

        // The committed head is the WINNER's full body.
        let final = try await remote.getPage(id: created.id)
        #expect(
            final.bodyMarkdown == (winners == ["A"] ? "winner-body-A" : "winner-body-B"))
    }

    // MARK: - 2. Failed expectation write: commits nothing, emits nothing

    @Test func failedExpectationWriteCommitsAndEmitsNothing() async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let sink = try makeSink(
            daemon: daemon, container: container, wikiID: wikiID)
        let remote = sink.remote
        try await remote.warmSession()
        // Settle the fixture replay; the baseline must be quiet.
        try await Task.sleep(for: .milliseconds(300))
        let baseline = sink.recorder.snapshot().count

        let created = try await remote.upsertPage(
            id: nil, title: "Rollback Page", rawBody: "committed once",
            expectation: .expectedAbsence, author: nil, provenance: [])
        try await waitFor(
            { sink.recorder.snapshot().count == baseline + 1 },
            what: "the create's single event")
        let afterCreate = sink.recorder.snapshot().count

        // A create-only write onto the OCCUPIED title: the expectation
        // write inside upsertPage fails → full rollback → zero events.
        do {
            _ = try await remote.upsertPage(
                id: nil, title: "Rollback Page", rawBody: "must not land",
                expectation: .expectedAbsence, author: nil, provenance: [])
            Issue.record("expected the create-only conflict")
        } catch let error as PageCreateConflictError {
            #expect(error.title == "Rollback Page")
        }

        // A stale-head write against the SAME page: conflict, zero events.
        let stale = PageVersionID(rawValue: "01STALE0000000000000000YY")
        do {
            _ = try await remote.upsertPage(
                id: created.id, title: "Rollback Page",
                rawBody: "must not land either",
                expectation: .expectedHead(stale), author: nil,
                provenance: [])
            Issue.record("expected the stale-head conflict")
        } catch let error as PageConflictError {
            #expect(error.expectedVersionID == stale)
        }

        try await Task.sleep(for: .milliseconds(300))
        #expect(
            sink.recorder.snapshot().count == afterCreate,
            "failed expectation writes must emit NOTHING")
        // The committed state is unchanged: the original body stands.
        let page = try await remote.getPage(id: created.id)
        #expect(page.bodyMarkdown == "committed once")
    }

    // MARK: - 3. Exactly one event batch per commit, contiguous sequences

    @Test func oneEventBatchPerCommitWithContiguousSequences() async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let sink = try makeSink(
            daemon: daemon, container: container, wikiID: wikiID)
        let remote = sink.remote
        try await remote.warmSession()
        try await Task.sleep(for: .milliseconds(300))
        let baseline = sink.recorder.snapshot().count

        let commits = 5
        for index in 0..<commits {
            _ = try await remote.upsertPage(
                id: nil, title: "Batch Commit \(index)", rawBody: "b\(index)",
                expectation: .expectedAbsence, author: nil, provenance: [])
        }
        try await waitFor(
            { sink.recorder.snapshot().count >= baseline + commits },
            what: "every commit's event to reach the bus")
        // Settle: no further deliveries may arrive.
        try await Task.sleep(for: .milliseconds(400))

        let committed = sink.recorder.snapshot()[baseline...]
        #expect(committed.count == commits)
        #expect(
            committed.allSatisfy {
                $0.kind == .page && $0.change == .created
                    && $0.wikiID == wikiID
            })
        // Contiguous sequences, no dupes, no gaps.
        let sequences = committed.map(\.seq).sorted()
        #expect(sequences.count == commits)
        for (position, sequence) in sequences.enumerated()
        where position > 0 {
            #expect(
                sequence == sequences[position - 1] + 1,
                "sequences must advance by exactly one: \(sequences)")
        }
    }

    // MARK: - 4. Concurrent reads during writes: consistent snapshots

    @Test func concurrentReadsDuringWritesReturnConsistentSnapshots()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let created = try await remote.upsertPage(
            id: nil, title: "Snapshot Page", rawBody: Self.versionBody(0),
            expectation: .expectedAbsence, author: nil, provenance: [])

        // The known-committed body set: a consistent snapshot is EXACTLY
        // one of these — never a mix, never a truncation.
        let versions = (0...8).map { Self.versionBody($0) }
        let known = Set(versions)

        // 8 writers advance the head; 8 readers race them.
        let readerTransport = try socketTransport(container)
        let reader = RemoteWikiStore(
            transport: readerTransport, wikiID: wikiID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...8 {
                let writer = RemoteWikiStore(
                    transport: try socketTransport(container),
                    wikiID: wikiID)
                let pageID = created.id
                group.addTask {
                    _ = try await writer.upsertPage(
                        id: pageID, title: "Snapshot Page",
                        rawBody: Self.versionBody(index),
                        expectation: .unrestricted, author: nil,
                        provenance: [])
                }
                let body = try await reader.getPage(id: pageID).bodyMarkdown
                #expect(
                    known.contains(body),
                    "a concurrent read returned a body that is not exactly one of the committed versions (partial or mixed): \(body.prefix(80))…")
            }
            try await group.waitForAll()
        }
        // The final head is one of the written versions — the last writer's
        // or any interleaved winner's, but always a FULL body.
        let final = try await remote.getPage(id: created.id)
        #expect(known.contains(final.bodyMarkdown))
    }

    private static func versionBody(_ index: Int) -> String {
        "snapshot-body-v\(index)-"
            + String(repeating: "pad\(index)", count: 200)
            + "-END-v\(index)"
    }

    // MARK: - 5. Cancellation: no partial state

    @Test func cancellingAnInFlightMutationLeavesNoPartialState()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        try await remote.warmSession()

        // A multi-chunk body: the client stages it over several round
        // trips before the atomic upsert dispatches, so a mid-call cancel
        // lands somewhere in the staging/execution window.
        let body = String(repeating: "cancel-body-", count: 114_000)
        #expect(body.utf8.count > DaemonStoreLimits.maxChunkBytes)

        let task = Task {
            try await remote.upsertPage(
                id: nil, title: "Cancel Page", rawBody: body,
                expectation: .expectedAbsence, author: nil, provenance: [])
        }
        // Let the call get in flight, then cancel it mid-call.
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            // A winner that landed BEFORE the cancel is fine — but the
            // committed state must then be the FULL body.
        } catch is CancellationError {
            // The expected path when the cancel wins the race.
        } catch {
            // Transport-level deadline/connection failures are also
            // legitimate cancel symptoms; the state assertion below is
            // what this test owns.
        }

        // Settle: any daemon-side execution that survived the cancel
        // (the ledger joined or the store committed) gets time to land.
        try await Task.sleep(for: .milliseconds(600))

        // ONE-OR-THE-OTHER, never partial: the page is ABSENT, or present
        // with the EXACT full body (the store's own method-atomic entry
        // point cannot expose a half-written version).
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let resolved = try await store.resolveTitleToID("Cancel Page")
        if let pageID = resolved {
            let page = try await store.getPage(id: pageID)
            #expect(
                page.bodyMarkdown == body,
                "a cancelled in-flight mutation must never surface partial state — the body is truncated or mixed")
        }
        // Absent is equally acceptable: nothing asserts the mutation MUST
        // have committed, only that it never lands HALF.
    }
}
#endif
