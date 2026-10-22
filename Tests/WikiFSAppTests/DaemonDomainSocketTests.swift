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
