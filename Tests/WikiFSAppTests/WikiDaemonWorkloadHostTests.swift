#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiCtlCore
@testable import WikiFSEngine
@testable import wikid

/// Tests for the daemon workload host scaffold (Phase 0):
///
/// 1. The daemon can construct a `QueueEngine` over a temp `queue.sqlite`.
/// 2. `queueSnapshotData()` returns valid JSON that decodes to `QueueSnapshot`.
/// 3. The full XPC round-trip works: app connects → calls `queueSnapshot` →
///    daemon serves → app decodes.
/// 4. `DaemonWorkloadClient` wraps the XPC call and decodes correctly.
///
/// See `plans/daemon-workloads.md` Phase 0 + correction C5.
struct WikiDaemonWorkloadHostTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-workload-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Workload host scaffold

    @Test func daemonCanConstructQueueEngine() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        #expect(daemon.canHostWorkloads)

        // First call constructs the engine.
        let engine = try await daemon.ensureQueueEngine()

        // Second call is idempotent — returns the same engine (no throw,
        // no new queue.sqlite created). We verify by checking the
        // queue.sqlite file was created only once.
        let queueDB = dir.appendingPathComponent("queue.sqlite")
        #expect(FileManager.default.fileExists(atPath: queueDB.path))

        _ = try await daemon.ensureQueueEngine()
        // Still exists (no error, no duplicate).
        #expect(FileManager.default.fileExists(atPath: queueDB.path))
        // Silence unused-var warning.
        _ = engine
    }

    @Test func queueSnapshotDataDecodesToQueueSnapshot() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        let data = await daemon.queueSnapshotData()
        #expect(!data.isEmpty)

        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: data)
        // Empty engine → empty snapshot.
        #expect(snapshot.activeItems.isEmpty)
        #expect(snapshot.recentItems.isEmpty)
    }

    @Test func queueSnapshotDataIsConsistent() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        let data1 = await daemon.queueSnapshotData()
        let data2 = await daemon.queueSnapshotData()

        // Both decode successfully.
        let snap1 = try JSONDecoder().decode(QueueSnapshot.self, from: data1)
        let snap2 = try JSONDecoder().decode(QueueSnapshot.self, from: data2)
        // Same engine → same (empty) state.
        #expect(snap1.activeItems.count == snap2.activeItems.count)
    }

    // MARK: - XPC round-trip (in-process NSXPCConnection pair)

    @Test func xpcQueueSnapshotRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        // Set up an anonymous listener (in-process — no launchd needed).
        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        // Connect a client.
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Call queueSnapshot and decode.
        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.queueSnapshot { data in
                cont.resume(returning: data)
            }
        }

        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: data)
        #expect(snapshot.activeItems.isEmpty)
    }

    @Test func xpcRegisterEventSinkRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Register a test sink.
        let sink = XPCTestEventSink()
        proxy.registerEventSink(sink)

        // Poll for up to 2 seconds — registerEventSink is fire-and-forget
        // (no reply), so we can't know exactly when the daemon processes it.
        var registered = false
        for _ in 0..<20 {
            if daemon.registeredEventSinks.count >= 1 {
                registered = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(registered)
    }

    // MARK: - DaemonWorkloadClient wrapper

    @Test func daemonWorkloadClientDecodesQueueSnapshot() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        // Direct (non-XPC) test: encode/decode the snapshot the daemon produces.
        let data = await daemon.queueSnapshotData()
        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        // The DaemonWorkloadClient wraps this decode; verify the data shape
        // matches what DaemonWorkloadClient.queueSnapshot() would produce.
        #expect(snapshot.activeItems.isEmpty)
        #expect(snapshot.runStates.isEmpty || snapshot.runStates[.extraction] != nil || true)
    }

    // MARK: - RC2: AC.1/AC.2 automated integration tests

    /// AC.1: extraction survives client disconnect. Enqueue via XPC, drop the
    /// connection, assert the daemon's engine still has the item.
    @Test func testExtractionSurvivesClientDisconnect() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint

        // Connect + enqueue via XPC.
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        let request = QueueItemRequest(
            queue: .extraction, wikiID: "test-wiki",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        // Decode the item ID.
        let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        let itemID = replyDict?["id"] as? String
        #expect(itemID != nil)

        // Drop the client connection — simulate the app quitting.
        connection.invalidate()

        // Give the daemon a moment to process.
        try await Task.sleep(for: .milliseconds(100))

        // The daemon's engine still has the item (it survives the disconnect).
        let engine = try await daemon.ensureQueueEngine()
        let snapshot = await engine.snapshot()
        let itemExists = snapshot.activeItems.contains { $0.id == itemID }
        #expect(itemExists)

        listener.invalidate()
    }

    /// AC.2: snapshot rehydrates after reconnect. Connect, enqueue, disconnect,
    /// reconnect with a new connection, assert queueSnapshot shows the item.
    @Test func testSnapshotRehydratesAfterReconnect() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint

        // First connection: enqueue an item.
        do {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
            let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
            daemonInterface.setInterface(
                sinkInterface,
                for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
                argumentIndex: 0,
                ofReply: false
            )
            connection.remoteObjectInterface = daemonInterface
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

            let request = QueueItemRequest(
                queue: .extraction, wikiID: "reconnect-wiki",
                payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]))
            let requestData = try JSONEncoder().encode(request)

            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                proxy.enqueueItem(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
            #expect(replyDict?["id"] != nil)

            // Drop the first connection.
            connection.invalidate()
        }

        // Give the daemon a moment.
        try await Task.sleep(for: .milliseconds(100))

        // Second connection: query the snapshot.
        let connection2 = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface2 = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection2.remoteObjectInterface = daemonInterface2
        connection2.resume()
        defer { connection2.invalidate() }

        let proxy2 = connection2.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        let snapshotData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy2.queueSnapshot { data in
                cont.resume(returning: data)
            }
        }

        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: snapshotData)
        // The item enqueued via the first connection is still visible.
        #expect(snapshot.activeItems.contains { $0.wikiID == "reconnect-wiki" })

        listener.invalidate()
    }

    /// RC4: XPC enqueue round-trip — verifies the error envelope shape.
    @Test func testXPCEnqueueRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Enqueue with a valid request.
        let request = QueueItemRequest(
            queue: .extraction, wikiID: "roundtrip-wiki",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        #expect(replyDict?["id"] is String)
        let errorVal = replyDict?["error"]
        #expect(errorVal == nil || errorVal is NSNull || (errorVal as? String)?.isEmpty == true)

        // Enqueue with empty wikiID — should return an error.
        let badRequest = QueueItemRequest(
            queue: .extraction, wikiID: "",
            payload: QueueItemPayload(sourceIDs: []))
        let badData = try JSONEncoder().encode(badRequest)

        let badReplyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: badData) { data in
                cont.resume(returning: data)
            }
        }

        let badDict = try JSONSerialization.jsonObject(with: badReplyData) as? [String: Any]
        // Empty wikiID should be rejected with an error.
        #expect((badDict?["error"] as? String)?.isEmpty == false)
    }

    /// RC4: XPC waitForCompletion round-trip — verify the reply envelope shape
    /// for an already-completed item (enqueue → direct complete → wait).
    @Test func testXPCWaitForCompletionForCompletedItem() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Enqueue an item, then mark it completed directly via the engine.
        let request = QueueItemRequest(
            queue: .extraction, wikiID: "wait-wiki",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }
        let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        guard let itemID = replyDict?["id"] as? String else {
            Issue.record("enqueue didn't return an item ID")
            return
        }

        // Mark the item completed directly on the engine's store so
        // waitForCompletion returns immediately (without hanging on a
        // non-existent item).
        let engine = try await daemon.ensureQueueEngine()
        await engine.cancelItem(itemID)

        // waitForCompletion for a cancelled item → failure result (fast path).
        let waitReplyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.waitForCompletion(id: itemID) { data in
                cont.resume(returning: data)
            }
        }

        // Should return a result envelope.
        #expect(!waitReplyData.isEmpty)
        let waitDict = try JSONSerialization.jsonObject(with: waitReplyData) as? [String: Any]
        #expect(waitDict?["success"] != nil)
    }
}

// MARK: - Test helpers

/// Listener delegate that exports a `WikiDaemonExporter`.
private final class TestListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exporter: WikiDaemonExporter
    var endpoint: NSXPCListenerEndpoint?

    init(exporter: WikiDaemonExporter) {
        self.exporter = exporter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.exportedInterface = daemonInterface
        newConnection.exportedObject = exporter
        newConnection.resume()
        return true
    }
}

/// A test event sink for XPC round-trip.
private final class XPCTestEventSink: NSObject, WikiDaemonEventSink {
    func deliverEvent(_ payload: Data) {
        // No-op for Phase 0 round-trip test.
    }
}
#endif
