#if os(macOS)
import Foundation
import Synchronization
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
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

    private func decodeQueuePayload<Payload: Codable & Sendable>(
        _ type: Payload.Type,
        from data: Data
    ) throws -> Payload {
        let envelope = try QueueRPCWire.decode(type, from: data)
        return try envelope.requirePayload()
    }

    // MARK: - Workload host scaffold

    @Test func daemonCanConstructQueueEngine() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        #expect(daemon.canHostWorkloads)

        // The first admitted operation constructs the engine.
        let first = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        #expect(first.hostState == .serving)

        // A second admission uses the same live resources.
        let queueDB = dir.appendingPathComponent("queue.sqlite")
        #expect(FileManager.default.fileExists(atPath: queueDB.path))
        let second = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        #expect(second.epoch == first.epoch)
        #expect(FileManager.default.fileExists(atPath: queueDB.path))
    }

    @Test func admittedSnapshotStartsEmpty() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        let result = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        #expect(result.value.activeItems.isEmpty)
        #expect(result.value.recentItems.isEmpty)
    }

    @Test func queueSnapshotDataDecodesLegacyTranscriptionRowsAsExtraction() async throws {
        let dir = makeTempDir()
        let queueURL = dir.appendingPathComponent("queue.sqlite")
        let store = try QueueStore(databaseURL: queueURL)
        let item = try store.enqueue(
            QueueItemRequest(
                queue: .extraction,
                wikiID: WikiID(rawValue: "legacy-wiki"),
                payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "legacy-src")])
            )
        )
        store.close()

        var db: OpaquePointer?
        #expect(sqlite3_open(queueURL.path, &db) == SQLITE_OK)
        let updateSQL = "UPDATE queue_items SET queue = 'transcription' WHERE id = '\(item.id.rawValue)';"
        #expect(sqlite3_exec(db, updateSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let daemon = WikiDaemon(containerDirectory: dir)
        let result = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }

        let restored = result.value.activeItems.first { $0.id == item.id }
        #expect(restored != nil)
        #expect(restored?.queue == .extraction)
    }

    @Test func admittedSnapshotsAreConsistent() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        let first = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        let second = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }

        #expect(first.value.activeItems.count == second.value.activeItems.count)
        #expect(first.epoch == second.epoch)
    }

    @Test func daemonForwardingIsSubscribedBeforeEnginePublication() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink = RecordingQueueEventSink()
        _ = daemon.registerEventSink(sink)
        let itemID = QueueItem.ID(rawValue: "daemon-forwarding-ready")

        _ = try await daemon.daemonQueueHost.perform { engine in
            engine.outputChannel.emitProgress(itemID: itemID, line: "ready")
        }

        let envelope = try await nextQueueEvent(
            from: sink.deliveries,
            timeout: .seconds(1))
        #expect(sink.decodeFailure == nil)
        #expect(envelope.kind == .progress)
        #expect(envelope.itemID == itemID)
        #expect(envelope.line == "ready")
    }

    @Test func ownershipStatusDoesNotConstructQueueResources() async throws {
        let directory = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: directory)
        let exporter = WikiDaemonExporter(daemon: daemon)
        let reply = AsyncStream<Data>.makeStream()

        exporter.queueOwnershipStatus {
            reply.continuation.yield($0)
            reply.continuation.finish()
        }
        var data: Data?
        for await value in reply.stream {
            data = value
            break
        }
        let responseData = try #require(data)
        let envelope = try QueueRPCWire.decode(
            QueueOwnershipStatusPayload.self,
            from: responseData)
        let status = try envelope.requirePayload()

        #expect(status.epoch == envelope.ownershipEpoch)
        #expect(status.hostState == envelope.hostState)
        #expect(status.hostState == .serving)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("queue.sqlite").path))
    }

    @Test func relinquishmentRejectsMismatchedRequestEnvelopeEpoch() async throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let exporter = WikiDaemonExporter(daemon: daemon)
        let requestEpoch = QueueOwnershipEpoch(rawValue: 1)
        let request = try QueueRPCWire.encode(
            QueueRPCEnvelope<QueueRelinquishmentRequest>.success(
                QueueRelinquishmentRequest(expectedEpoch: requestEpoch),
                epoch: QueueOwnershipEpoch(rawValue: 2),
                hostState: .serving))

        let reply = AsyncStream<Data>.makeStream()
        exporter.relinquishQueue(request: request) {
            reply.continuation.yield($0)
            reply.continuation.finish()
        }
        let data = try #require(await reply.stream.first(where: { _ in true }))
        let response = try QueueRPCWire.decode(
            QueueRelinquishmentSuccess.self,
            from: data)

        #expect(response.payload == nil)
        #expect(response.error?.code == .invalidEnvelope)
        #expect(response.hostState == .serving)
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

        let payload = try decodeQueuePayload(QueueDataPayload.self, from: data)
        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: payload.data)
        #expect(snapshot.activeItems.isEmpty)
    }

    @Test func typedQueueTranscriptRoundTripsThroughXPC() async throws {
        let dir = makeTempDir()
        let queueURL = dir.appendingPathComponent("queue.sqlite")
        let store = try QueueStore(databaseURL: queueURL)
        let item = try store.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "typed-xpc-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "typed-xpc-source")])
        ))
        let expected = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "typed-xpc-message"),
            turnID: QueueAttemptID(itemID: item.id, attempt: item.attempt).chatTurnID,
            role: .assistant,
            text: "typed transcript through XPC",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try store.upsertTranscriptItems(
            attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
            items: [expected]
        )
        store.close()

        let daemon = WikiDaemon(containerDirectory: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)
        let listener = NSXPCListener.anonymous()
        let delegate = TestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            proxy.loadTranscript(itemID: item.id.rawValue) { continuation.resume(returning: $0) }
        }

        let payload = try decodeQueuePayload(QueueDataPayload.self, from: data)
        #expect(try JSONDecoder().decode([ChatTranscriptItem].self, from: payload.data) == [expected])
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

    @Test func daemonWorkloadClientSnapshotShapeStartsEmpty() async throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        let result = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }

        #expect(result.value.activeItems.isEmpty)
        #expect(result.value.recentItems.isEmpty)
        #expect(result.hostState == .serving)
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
            queue: .extraction, wikiID: WikiID(rawValue: "test-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        let itemID = try decodeQueuePayload(QueueItemIDPayload.self, from: replyData).itemID
        #expect(!itemID.isEmpty)

        // Drop the client connection — simulate the app quitting.
        connection.invalidate()

        // Give the daemon a moment to process.
        try await Task.sleep(for: .milliseconds(100))

        // The daemon host still has the item after the client disconnects.
        let admitted = try await daemon.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        let itemExists = admitted.value.activeItems.contains { $0.id.rawValue == itemID }
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
                queue: .extraction, wikiID: WikiID(rawValue: "reconnect-wiki"),
                payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "src1")]))
            let requestData = try JSONEncoder().encode(request)

            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                proxy.enqueueItem(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            let payload = try decodeQueuePayload(QueueItemIDPayload.self, from: replyData)
            #expect(!payload.itemID.isEmpty)

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

        let snapshotPayload = try decodeQueuePayload(QueueDataPayload.self, from: snapshotData)
        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: snapshotPayload.data)
        // The item enqueued via the first connection is still visible.
        #expect(snapshot.activeItems.contains { $0.wikiID == WikiID(rawValue: "reconnect-wiki") })

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
            queue: .extraction, wikiID: WikiID(rawValue: "roundtrip-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        let payload = try decodeQueuePayload(QueueItemIDPayload.self, from: replyData)
        #expect(!payload.itemID.isEmpty)

        // Enqueue with empty wikiID — should return an error.
        let badRequest = QueueItemRequest(
            queue: .extraction, wikiID: WikiID(rawValue: ""),
            payload: QueueItemPayload(sourceIDs: []))
        let badData = try JSONEncoder().encode(badRequest)

        let badReplyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: badData) { data in
                cont.resume(returning: data)
            }
        }

        let failure = try QueueRPCWire.decode(QueueItemIDPayload.self, from: badReplyData)
        #expect(failure.payload == nil)
        #expect(failure.error != nil)
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
            queue: .extraction, wikiID: WikiID(rawValue: "wait-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "src1")]))
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.enqueueItem(request: requestData) { data in
                cont.resume(returning: data)
            }
        }
        let itemID = try decodeQueuePayload(QueueItemIDPayload.self, from: replyData).itemID

        // Cancel the item through the daemon admission boundary so
        // waitForCompletion returns immediately.
        _ = try await daemon.daemonQueueHost.perform { engine in
            await engine.cancelItem(QueueItemID(rawValue: itemID))
        }

        // A cancelled item is a queue-domain failure, not a transport failure.
        // The typed workload client returns the failure payload without throwing.
        let workloadClient = DaemonWorkloadClient(proxy: proxy)
        let completion = try await workloadClient.waitForCompletion(
            of: QueueItemID(rawValue: itemID))
        #expect(!completion.completed)
        #expect(completion.errorMessage != nil)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DaemonQueueHostTests {
    @Test func concurrentAdmissionsShareOneResourceBuild() async throws {
        let directory = makeHostTempDirectory()
        let buildStarted = HostTestSignal()
        let releaseBuild = HostTestSignal()
        let buildCount = HostTestCounter()
        let admissions = HostTestCountGate(target: 2)
        let host = DaemonQueueHost(onAdmission: {
            admissions.record()
        }) {
            buildCount.increment()
            buildStarted.signal()
            await releaseBuild.wait()
            return try await makeIdleHostResources(
                databaseURL: directory.appendingPathComponent("queue.sqlite"))
        }

        let first = Task { try await host.perform { _ in 1 } }
        await buildStarted.wait()
        let second = Task { try await host.perform { _ in 2 } }
        await admissions.wait()

        #expect(buildCount.value == 1)
        releaseBuild.signal()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(Set([firstResult.value, secondResult.value]) == [1, 2])
        #expect(firstResult.epoch == secondResult.epoch)

        let success = try await host.relinquish(expectedEpoch: firstResult.epoch)
        #expect(success.isComplete)
    }

    @Test func relinquishmentDrainsAdmissionsAndPermanentlyRejectsNewWork() async throws {
        let directory = makeHostTempDirectory()
        let operationStarted = HostTestSignal()
        let releaseOperation = HostTestSignal()
        let relinquishing = HostTestSignal()
        let relinquishmentFinished = HostTestSignal()
        let buildCount = HostTestCounter()
        let order = HostTestOrder()
        let epoch = QueueOwnershipEpoch(rawValue: 41)
        let host = DaemonQueueHost(
            initialEpoch: epoch,
            onStateChange: { state in
                if state == .relinquishing { relinquishing.signal() }
            }
        ) {
            buildCount.increment()
            return try await makeIdleHostResources(
                databaseURL: directory.appendingPathComponent("queue.sqlite"))
        }

        let operation = Task {
            try await host.perform { _ in
                operationStarted.signal()
                await releaseOperation.wait()
                order.append("operation")
                return 7
            }
        }
        await operationStarted.wait()

        let relinquishment = Task {
            let result = try await host.relinquish(expectedEpoch: epoch)
            order.append("relinquishment")
            relinquishmentFinished.signal()
            return result
        }
        await relinquishing.wait()
        #expect(!relinquishmentFinished.isSignaled)

        try await expectOwnershipError(
            { try await host.perform { _ in () } },
            epoch: epoch,
            state: .relinquishing)
        try await expectRelinquishmentError(
            { try await host.relinquish(
                expectedEpoch: QueueOwnershipEpoch(rawValue: 40)) },
            epoch: epoch,
            state: .relinquishing)

        releaseOperation.signal()
        #expect(try await operation.value.value == 7)
        let success = try await relinquishment.value
        #expect(success.isComplete)
        #expect(order.values == ["operation", "relinquishment"])

        try await expectOwnershipError(
            { try await host.perform { _ in () } },
            epoch: epoch,
            state: .relinquished)
        #expect(buildCount.value == 1)
    }

    @Test func blockedShutdownRetainsResourcesUntilExplicitRetry() async throws {
        let directory = makeHostTempDirectory()
        let control = HostUncooperativeWorkerControl()
        let deadline = HostManualDeadlineSource()
        let buildCount = HostTestCounter()
        let itemID = HostTestValue<QueueItem.ID?>(nil)
        let epoch = QueueOwnershipEpoch(rawValue: 73)
        let host = DaemonQueueHost(initialEpoch: epoch) {
            buildCount.increment()
            let store = try QueueStore(
                databaseURL: directory.appendingPathComponent("queue.sqlite"))
            let factory = HostClosureWorkerFactory(
                providerID: ProviderID(rawValue: "blocked-provider"),
                body: { item in await control.execute(item) })
            let engine = QueueEngine(
                store: store,
                workerFactory: factory,
                shutdownPolicy: QueueEngineShutdownPolicy(
                    workerSettlementDeadline: .seconds(1)),
                deadlineSource: deadline)
            let queuedID = try await engine.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: WikiID(rawValue: "blocked-host-wiki"),
                payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "blocked-source")])) )
            itemID.value = queuedID
            await engine.start()
            await control.awaitStarted()
            let forwardingTask = Task {
                for await _ in engine.events {}
            }
            return DaemonQueueResources(
                engine: engine,
                store: store,
                forwardingTask: forwardingTask)
        }

        _ = try await host.perform { _ in () }
        let expectedItemID = try #require(itemID.value)
        let firstRelinquishment = Task {
            try await host.relinquish(expectedEpoch: epoch)
        }
        await control.awaitCancellationObserved()
        await deadline.awaitWaiting()
        deadline.fire()

        try await expectRelinquishmentError(
            { try await firstRelinquishment.value },
            epoch: epoch,
            state: .shutdownBlocked,
            activeItemIDs: [expectedItemID.rawValue])
        let status = await host.status()
        #expect(status.epoch == epoch)
        #expect(status.hostState == .shutdownBlocked)
        try await expectOwnershipError(
            { try await host.perform { _ in () } },
            epoch: epoch,
            state: .shutdownBlocked,
            activeItemIDs: [expectedItemID.rawValue])
        #expect(buildCount.value == 1)

        control.release()
        await control.awaitFinished()
        let success = try await host.relinquish(expectedEpoch: epoch)
        #expect(success.isComplete)
        #expect(buildCount.value == 1)
    }

    private func expectOwnershipError<Value: Sendable>(
        _ operation: @Sendable () async throws -> DaemonQueueOperationResult<Value>,
        epoch: QueueOwnershipEpoch,
        state: QueueDaemonHostState,
        activeItemIDs: [String] = []
    ) async throws {
        do {
            _ = try await operation()
            Issue.record("Expected a queue ownership transition error")
        } catch {
            let queueError = try #require(error as? QueueRPCError)
            #expect(queueError.code == .ownershipTransition)
            #expect(queueError.ownership?.epoch == epoch)
            #expect(queueError.ownership?.hostState == state)
            #expect(queueError.ownership?.activeItemIDs == activeItemIDs)
        }
    }

    private func expectRelinquishmentError(
        _ operation: @Sendable () async throws -> QueueRelinquishmentSuccess,
        epoch: QueueOwnershipEpoch,
        state: QueueDaemonHostState,
        activeItemIDs: [String] = []
    ) async throws {
        do {
            _ = try await operation()
            Issue.record("Expected a queue relinquishment error")
        } catch {
            let queueError = try #require(error as? QueueRPCError)
            #expect(queueError.code == .ownershipTransition)
            #expect(queueError.ownership?.epoch == epoch)
            #expect(queueError.ownership?.hostState == state)
            #expect(queueError.ownership?.activeItemIDs == activeItemIDs)
        }
    }
}

// MARK: - Test helpers

private func makeHostTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("daemon-queue-host-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory
}

private func makeIdleHostResources(databaseURL: URL) async throws -> DaemonQueueResources {
    let store = try QueueStore(databaseURL: databaseURL)
    let engine = QueueEngine(store: store, workerFactory: HostNoopWorkerFactory())
    await engine.start()
    let forwardingTask = Task {
        for await _ in engine.events {}
    }
    return DaemonQueueResources(
        engine: engine,
        store: store,
        forwardingTask: forwardingTask)
}

private final class HostTestSignal: Sendable {
    private struct State: Sendable {
        var isSignaled = false
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let state = Mutex(State())

    var isSignaled: Bool {
        state.withLock { $0.isSignaled }
    }

    func signal() {
        let continuation = state.withLock { state -> AsyncStream<Void>.Continuation? in
            guard !state.isSignaled else { return nil }
            state.isSignaled = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.yield(())
        continuation?.finish()
    }

    func wait() async {
        let pair = AsyncStream<Void>.makeStream()
        let completeNow = state.withLock { state -> Bool in
            if state.isSignaled { return true }
            state.continuation = pair.continuation
            return false
        }
        if completeNow {
            pair.continuation.finish()
        }
        for await _ in pair.stream { break }
    }
}

private final class HostTestCountGate: Sendable {
    private struct State: Sendable {
        var count = 0
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let target: Int
    private let state = Mutex(State())

    init(target: Int) {
        self.target = target
    }

    func record() {
        let continuation = state.withLock { state -> AsyncStream<Void>.Continuation? in
            state.count += 1
            guard state.count >= target else { return nil }
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.yield(())
        continuation?.finish()
    }

    func wait() async {
        let pair = AsyncStream<Void>.makeStream()
        let completeNow = state.withLock { state -> Bool in
            if state.count >= target { return true }
            state.continuation = pair.continuation
            return false
        }
        if completeNow {
            pair.continuation.finish()
        }
        for await _ in pair.stream { break }
    }
}

private final class HostTestCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

private final class HostTestOrder: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] { storage.withLock { $0 } }

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }
}

private final class HostTestValue<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private struct HostNoopWorkerFactory: QueueWorkerFactory {
    func providerID(for item: QueueItem) async -> ProviderID? { nil }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        throw QueueIngestionError.noSources
    }
}

private struct HostClosureWorkerFactory: QueueWorkerFactory {
    let providerIDValue: ProviderID
    let body: @Sendable (QueueItem) async throws -> Void

    init(
        providerID: ProviderID,
        body: @escaping @Sendable (QueueItem) async throws -> Void
    ) {
        self.providerIDValue = providerID
        self.body = body
    }

    func providerID(for item: QueueItem) async -> ProviderID? {
        providerIDValue
    }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        HostClosureWorker(body: body)
    }
}

private struct HostClosureWorker: QueueWorker {
    let body: @Sendable (QueueItem) async throws -> Void

    func execute(_ item: QueueItem) async throws {
        try await body(item)
    }
}

private final class HostUncooperativeWorkerControl: Sendable {
    private let started = HostTestSignal()
    private let cancellation = HostTestSignal()
    private let releaseGate = HostTestSignal()
    private let finished = HostTestSignal()

    func execute(_ item: QueueItem) async {
        started.signal()
        let releaseTask = Task { await releaseGate.wait() }
        await withTaskCancellationHandler {
            await releaseTask.value
        } onCancel: {
            cancellation.signal()
        }
        finished.signal()
    }

    func awaitStarted() async { await started.wait() }
    func awaitCancellationObserved() async { await cancellation.wait() }
    func release() { releaseGate.signal() }
    func awaitFinished() async { await finished.wait() }
}

private final class HostManualDeadlineSource: QueueEngineDeadlineSource, Sendable {
    private struct State: Sendable {
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let waiting = HostTestSignal()

    func stream(after duration: Duration) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream()
        let id = UUID()
        pair.continuation.onTermination = { [self] _ in
            state.withLock { _ = $0.waiters.removeValue(forKey: id) }
        }
        state.withLock { $0.waiters[id] = pair.continuation }
        waiting.signal()
        return pair.stream
    }

    func awaitWaiting() async { await waiting.wait() }

    func fire() {
        let waiters = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.finish() }
    }
}

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

private enum QueueEventTimeoutError: Error {
    case timedOut
}

private func nextQueueEvent(
    from stream: AsyncStream<QueueEventEnvelope>,
    timeout: Duration
) async throws -> QueueEventEnvelope {
    try await withThrowingTaskGroup(of: QueueEventEnvelope.self) { group in
        group.addTask {
            for await envelope in stream { return envelope }
            throw QueueEventTimeoutError.timedOut
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw QueueEventTimeoutError.timedOut
        }
        guard let envelope = try await group.next() else {
            throw QueueEventTimeoutError.timedOut
        }
        group.cancelAll()
        return envelope
    }
}

private final class RecordingQueueEventSink: NSObject, WikiDaemonEventSink {
    private struct State: Sendable {
        var decodeFailure: String?
    }

    private let storage = Mutex(State())
    private let deliveryPair = AsyncStream<QueueEventEnvelope>.makeStream()

    var deliveries: AsyncStream<QueueEventEnvelope> { deliveryPair.stream }

    var decodeFailure: String? {
        storage.withLock { $0.decodeFailure }
    }

    func deliverEvent(_ payload: Data) {
        do {
            let envelope = try JSONDecoder().decode(QueueEventEnvelope.self, from: payload)
            deliveryPair.continuation.yield(envelope)
        } catch {
            storage.withLock { $0.decodeFailure = String(describing: error) }
            deliveryPair.continuation.finish()
        }
    }
}

/// A test event sink for XPC round-trip.
private final class XPCTestEventSink: NSObject, WikiDaemonEventSink {
    func deliverEvent(_ payload: Data) {
        // No-op for Phase 0 round-trip test.
    }
}
#endif
