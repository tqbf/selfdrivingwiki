#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

// Real end-to-end tests for the versioned domain envelope over the CLI ⇄
// daemon socket (Phase 1 of plans/cli-domain-commands.md): actual AF_UNIX
// connections between `DaemonDomainSocketClient` and a real
// `DaemonDomainSocketDispatcher` (the daemon boot's payload handler) running
// over a fixture `WikiDaemon` in this process. No transport is mocked; the
// envelope codec, version gate, family dispatch, and queue verbs are the real
// code paths the daemon serves.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// every scenario is bounded by a short injected timeout — never the 30 s
// production default.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DaemonDomainSocketTests {

    // MARK: Fixtures

    /// Unique throwaway container directory per test (socket + fixture
    /// registry + fixture queue store), so guard flocks never overlap. Left
    /// in place on purpose — same reasoning as `DaemonSearchSocketTests`.
    private func makeContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ddm-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// A fixture daemon + the real dispatcher, served on a real socket.
    private func startDaemonSocket(
        container: URL
    ) throws -> (server: DaemonSearchSocketServer, daemon: WikiDaemon) {
        let daemon = WikiDaemon(containerDirectory: container)
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) { request in
            await dispatcher.handle(request)
        }
        try server.start()
        return (server, daemon)
    }

    private func makeClient(container: URL) throws -> DaemonDomainSocketClient {
        try DaemonDomainSocketClient(containerDirectory: container, timeout: 10)
    }

    // MARK: hello / capabilities

    @Test func helloRoundTripReportsProtocolVersionAndFamilies() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let client = try makeClient(container: container)
        let hello = try await client.hello()
        #expect(hello.protocolVersion == DaemonDomainVersion.current)
        #expect(hello.families.contains("hello"))
        #expect(hello.families.contains("search"))
        #expect(hello.families.contains("queue"))
        #expect(hello.families == hello.families.sorted())
        #expect(hello.version == DaemonHelloPayload.currentVersion)
    }

    // MARK: Version gate + unknown family/operation

    @Test func versionMismatchIsTypedUnsupportedVersion() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let client = try makeClient(container: container)
        // Send raw envelope bytes carrying a version the daemon does not
        // serve (a newer CLI against an older daemon is the live scenario).
        let stale = DaemonDomainRequest(
            version: UInt16(DaemonDomainVersion.current + 1),
            requestID: "stale-version",
            family: .search,
            operation: DaemonDomainOperation.Search.search,
            payload: nil)
        let replyBytes = try await DaemonSocketRoundTrip.perform(
            socketPath: client.socketPath,
            requestBytes: try DaemonDomainWire.encode(stale),
            timeout: 10)
        let reply = try DaemonDomainWire.decodeReply(replyBytes)
        #expect(reply.requestID == "stale-version")
        #expect(reply.error?.code == .unsupportedVersion)
        #expect(reply.error?.message.contains("protocol") == true)
    }

    @Test func unknownFamilyStringIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let client = try makeClient(container: container)
        // An unknown family cannot be typed client-side — send raw envelope
        // JSON the way a future family's pre-daemon client would.
        let raw: [String: Any] = [
            "version": 1,
            "requestID": "unknown-family",
            "family": "teleport",
            "operation": "go",
        ]
        let bytes = try JSONSerialization.data(withJSONObject: raw)
        let replyBytes = try await DaemonSocketRoundTrip.perform(
            socketPath: client.socketPath, requestBytes: bytes, timeout: 10)
        let reply = try DaemonDomainWire.decodeReply(replyBytes)
        #expect(reply.error?.code == .invalidRequest)
    }

    @Test func unknownQueueOperationIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let client = try makeClient(container: container)
        do {
            _ = try await client.send(family: .queue, operation: "teleportQueue")
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("teleportQueue"))
        }
    }

    @Test func malformedEnvelopeBytesAnswerInvalidRequestReply() async throws {
        let container = makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)

        // Direct handler call: no socket needed to pin the typed rejection.
        let replyBytes = await dispatcher.handle(Data("not json".utf8))
        let reply = try DaemonDomainWire.decodeReply(replyBytes)
        #expect(reply.error?.code == .invalidRequest)
    }

    // MARK: Queue verbs over the real socket

    @Test func queueSnapshotRoundTripsOverRealSocket() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        let snapshot = try await workload.queueSnapshot()
        // A fresh fixture daemon owns an empty queue; the shape is the
        // contract (the envelope decoded, the payload parsed).
        #expect(snapshot.activeItems.isEmpty)
    }

    @Test func laneControlsRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        // pause → resume → halt on the extraction lane: each must come back
        // as a typed void success (the failure envelope would throw).
        try await workload.pause(.extraction)
        try await workload.resume(.extraction)
        try await workload.halt(.extraction)
    }

    /// The queue error taxonomy survives the socket: an enqueue the daemon's
    /// queue host cannot admit arrives as a `QueueRPCError` (from the failure
    /// envelope inside the domain payload), not as a transport fault.
    @Test func enqueueFailureSurfacesTypedQueueError() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "0200000000000000000000000A")]))
        do {
            _ = try await workload.enqueue(request)
            Issue.record("expected the enqueue to fail for an unknown wiki")
        } catch let error as QueueRPCError {
            // The daemon refused through its own typed taxonomy — exactly the
            // failure shape the XPC transport delivers to the app.
            #expect(error.code == .unavailable || error.code == .operationFailed)
        }
    }

    // MARK: queueItemState (transcribe completion wait, Phase 5)

    /// The poll operation behind `wikictl transcribe --wait`: one short
    /// item-state snapshot per round trip over the real socket. The test walks
    /// an item through its lifecycle in the daemon's durable queue store and
    /// pins the snapshot at each leg — the shape the CLI's polling loop keys on.
    @Test func queueItemStateSnapshotsItemLifecycleOverRealSocket() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        // A durable extraction item written the way the engine writes it (the
        // daemon owns queue.sqlite; the test seeds one row to poll).
        let sourceID = SourceID(rawValue: "0200000000000000000000000A")
        let queueStore = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        let item = try queueStore.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            payload: QueueItemPayload(sourceIDs: [sourceID])))
        queueStore.close()

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        let queued = try await workload.queueItemState(of: item.id)
        #expect(queued.state == QueueItemState.queued.rawValue)
        #expect(queued.error == nil)

        // Walk the lifecycle through a writer handle — the daemon's snapshot
        // opens read-only beside it, the same WAL pattern production uses.
        let writer = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        try writer.markRunning(id: item.id, providerID: ProviderID(rawValue: "test-provider"))
        try writer.markCompleted(id: item.id)
        writer.close()
        let completed = try await workload.queueItemState(of: item.id)
        #expect(completed.state == QueueItemState.completed.rawValue)
        #expect(completed.error == nil)
    }

    /// A failed item's snapshot carries the recorded error text — the value
    /// the CLI prints as the transcribe outcome's failure message.
    @Test func queueItemStateCarriesFailureTextOverRealSocket() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let queueStore = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        let item = try queueStore.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "0200000000000000000000000A")])))
        queueStore.close()

        let writer = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        try writer.markRunning(id: item.id, providerID: ProviderID(rawValue: "test-provider"))
        try writer.markFailed(id: item.id, error: "speech floor unavailable")
        writer.close()

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        let failed = try await workload.queueItemState(of: item.id)
        #expect(failed.state == QueueItemState.failed.rawValue)
        #expect(failed.error == "speech floor unavailable")
    }

    /// An unknown item is a typed `notFound`, never a transport fault — and a
    /// container with NO queue database answers the same typed rejection (the
    /// durable terminal history is never deleted, so a missing row mid-wait is
    /// a genuine anomaly the CLI surfaces instead of polling forever).
    @Test func queueItemStateUnknownItemIsTypedNotFound() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        do {
            _ = try await workload.queueItemState(
                of: QueueItemID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
            Issue.record("expected notFound for an unknown item")
        } catch let error as DaemonDomainError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("no queue item matching") == true)
        }

        // Same typed shape with a queue database present but no matching row.
        let queueStore = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        let item = try queueStore.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "0200000000000000000000000A")])))
        queueStore.close()
        do {
            _ = try await workload.queueItemState(
                of: QueueItemID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
            Issue.record("expected notFound for a row that does not exist")
        } catch let error as DaemonDomainError {
            #expect(error.code == .notFound)
        }
        _ = item // seeded to prove the DB-present leg reads the real store
    }

    /// A malformed payload for the new operation stays inside the envelope
    /// contract: typed `invalidRequest`, never a transport fault.
    @Test func queueItemStateMalformedPayloadIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }

        let client = try makeClient(container: container)
        do {
            _ = try await client.send(
                family: .queue,
                operation: DaemonDomainOperation.Queue.queueItemState,
                payload: Data("not json".utf8))
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
        }
    }

    // MARK: transcribePreflight (speech enqueue preflight, Phase 5)

    /// The preflight behind `wikictl transcribe on-device`: the YouTube-scope
    /// check reads the daemon's prepared store, so the CLI never opens the
    /// wiki database. Pins the true leg (YouTube-provenance source), the false
    /// legs (present non-YouTube source, unknown source), and the unknown-wiki
    /// typed notFound — the exact answer shape the CLI's typed failure keys on.
    @Test func transcribePreflightYouTubeScopeOverRealSocket() async throws {
        let container = makeContainer()
        let (server, daemon) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let registry = try DaemonWikiRegistryClient(containerDirectory: container, timeout: 10)
        let fixture = try await registry.createWiki(name: "Preflight Fixture Wiki")

        // One YouTube-provenance source (the in-scope shape) and one plain
        // source, seeded through the daemon's own admission seam.
        let youtubeSourceID: SourceID = try await {
            let store = try await daemon.domainCommandStore(wikiID: fixture.id)
            let summary = try store.addSource(
                filename: "youtube-dQw4w9WgXcQ.mp4",
                data: Data("video".utf8),
                detectionHints: ContentTypeDetectionHints(filenameExtension: "mp4"),
                ingestMetadata: nil,
                provenance: SourceProvenance(
                    agentName: SourceProvider.youtube.rawValue,
                    activityKind: "import",
                    externalIdentity: "dQw4w9WgXcQ"),
                role: .media,
                originalPath: nil,
                activityID: nil,
                resolvedDisplayName: nil)
            return summary.id
        }()
        let plainSourceID: SourceID = try await {
            let store = try await daemon.domainCommandStore(wikiID: fixture.id)
            return try store.addSource(filename: "notes.md", data: Data("text".utf8)).id
        }()

        let workload = try DaemonWorkloadClient(
            socketContainerDirectory: container, timeout: 10)
        let youtube = try await workload.transcribePreflight(
            wikiID: fixture.id, sourceID: youtubeSourceID)
        #expect(youtube == true)
        let plain = try await workload.transcribePreflight(
            wikiID: fixture.id, sourceID: plainSourceID)
        #expect(plain == false)
        let unknown = try await workload.transcribePreflight(
            wikiID: fixture.id,
            sourceID: SourceID(rawValue: "02AAAAAAAAAAAAAAAAAAAAAAAA"))
        #expect(unknown == false)

        do {
            _ = try await workload.transcribePreflight(
                wikiID: WikiID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA"),
                sourceID: youtubeSourceID)
            Issue.record("expected notFound for an unknown wiki")
        } catch let error as DaemonDomainError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("no wiki matching") == true)
        }
    }

    // MARK: Absent daemon

    @Test func absentDaemonSurfacesExplicitNotRunningError() async throws {
        let container = makeContainer()
        let client = try makeClient(container: container)
        do {
            _ = try await client.send(
                family: .hello, operation: DaemonDomainOperation.Hello.capabilities)
            Issue.record("expected daemonNotRunning")
        } catch let error as SearchSocketError {
            #expect(error.isDaemonNotRunning)
            // The CLI's generic catch renders the localized description, so
            // the message must name the cause explicitly.
            #expect(
                error.localizedDescription
                    == "the wikid daemon is not running — launch the app")
        }
    }
}
#endif
