#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Tests for `QueueEngineHotSwap` — the hot-swappable queue engine proxy
/// that enables mid-session daemon disconnect/reconnect fallback (#878).
struct QueueEngineHotSwapTests {

    // MARK: - Controllable fake engine

    /// A fake engine whose `events` stream can be fed from outside, so tests
    /// can verify the hot-swap republishes events from the active engine.
    final class ControllableFakeEngine: QueueEngineClient, @unchecked Sendable {
        let id: String
        let continuation: AsyncStream<QueueEvent>.Continuation
        let stream: AsyncStream<QueueEvent>
        private let subscription = AsyncStream<Void>.makeStream()
        private let snapshotStarted = AsyncStream<Void>.makeStream()
        private let snapshotRelease = AsyncStream<Void>.makeStream()
        let blocksSnapshot: Bool
        private(set) var snapshotCallCount = 0

        init(id: String, blocksSnapshot: Bool = false) {
            self.id = id
            self.blocksSnapshot = blocksSnapshot
            let (s, c) = AsyncStream.makeStream(of: QueueEvent.self)
            self.stream = s
            self.continuation = c
        }

        var events: AsyncStream<QueueEvent> {
            subscription.continuation.yield(())
            return stream
        }

        func awaitSubscription() async {
            for await _ in subscription.stream { return }
        }
        @discardableResult
        func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { QueueItemID(rawValue: id) }
        func cancelItem(_ id: QueueItem.ID) async {}
        @discardableResult
        func cancelAllInFlight() async -> Int { 0 }
        func retryItem(_ id: QueueItem.ID) async throws {}
        func pause(_ queue: QueueKind) async {}
        func resume(_ queue: QueueKind) async {}
        func halt(_ queue: QueueKind) async {}
        func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {}
        func snapshot() async -> QueueSnapshot {
            snapshotCallCount += 1
            guard blocksSnapshot else { return QueueSnapshot() }
            snapshotStarted.continuation.yield(())
            snapshotStarted.continuation.finish()
            for await _ in snapshotRelease.stream { break }
            return QueueSnapshot()
        }

        func awaitSnapshotStarted() async {
            for await _ in snapshotStarted.stream { break }
        }

        func releaseSnapshot() {
            snapshotRelease.continuation.yield(())
            snapshotRelease.continuation.finish()
        }
        func hasActiveWork(for wikiID: WikiID) async -> Bool { false }
        func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> { .success(()) }
        func loadTranscript(for itemID: QueueItem.ID) async -> [ChatTranscriptItem] { [] }
        func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
    }

    // MARK: - Tests

    @Test func forwardsToCurrentEngine() async throws {
        let engine = ControllableFakeEngine(id: "engine-A")
        let router = QueueEngineHotSwap(engine)

        // snapshot() should forward to the current engine.
        _ = try await router.snapshot()
        #expect(engine.snapshotCallCount == 1)
    }

    @Test func swapSwitchesForwardingToNewEngine() async throws {
        let engineA = ControllableFakeEngine(id: "A")
        let engineB = ControllableFakeEngine(id: "B")
        let router = QueueEngineHotSwap(engineA)

        // Before swap: forwards to A.
        _ = try await router.snapshot()
        #expect(engineA.snapshotCallCount == 1)
        #expect(engineB.snapshotCallCount == 0)

        // Swap to B.
        await router.swap(to: engineB)

        // After swap: forwards to B, not A.
        _ = try await router.snapshot()
        #expect(engineA.snapshotCallCount == 1)  // unchanged
        #expect(engineB.snapshotCallCount == 1)  // new
    }

    @Test func currentReturnsActiveEngine() async {
        let engineA = ControllableFakeEngine(id: "A")
        let router = QueueEngineHotSwap(engineA)

        // Before swap.
        #expect((await router.current as? ControllableFakeEngine)?.id == "A")

        // After swap.
        let engineB = ControllableFakeEngine(id: "B")
        await router.swap(to: engineB)
        #expect((await router.current as? ControllableFakeEngine)?.id == "B")
    }

    @Test func eventsRepublishedAcrossSwap() async {
        let engineA = ControllableFakeEngine(id: "A")
        let engineB = ControllableFakeEngine(id: "B")
        let router = QueueEngineHotSwap(engineA)

        // Subscribe to the router's unified stream.
        let received: Task<[String], Never> = Task {
            var ids: [String] = []
            for await event in router.events {
                switch event {
                case .enqueued(let item):
                    ids.append(item.id.rawValue)
                    if ids.count >= 2 { return ids }
                default: break
                }
            }
            return ids
        }

        await engineA.awaitSubscription()

        // Emit from engine A.
        engineA.continuation.yield(.enqueued(makeItem(id: "item-A")))

        // Swap to engine B and wait until its forwarder is installed.
        await router.swap(to: engineB)
        await engineB.awaitSubscription()

        // Emit from engine B — should flow through the SAME router stream.
        engineB.continuation.yield(.enqueued(makeItem(id: "item-B")))

        let ids = await received.value
        #expect(ids == ["item-A", "item-B"])
    }

    @Test func acknowledgedSwapDrainsRetiredAdmissions() async throws {
        let engineA = ControllableFakeEngine(id: "A", blocksSnapshot: true)
        let engineB = ControllableFakeEngine(id: "B")
        let router = QueueEngineHotSwap(engineA)
        await engineA.awaitSubscription()

        let retiredOperation = Task { try await router.snapshot() }
        await engineA.awaitSnapshotStarted()

        let swapFinished = AsyncStream<Void>.makeStream()
        let swapTask = Task {
            await router.swap(to: engineB)
            swapFinished.continuation.yield(())
            swapFinished.continuation.finish()
        }
        await engineB.awaitSubscription()

        _ = try await router.snapshot()
        #expect(engineB.snapshotCallCount == 1)

        engineA.releaseSnapshot()
        _ = try await retiredOperation.value
        for await _ in swapFinished.stream { break }
        await swapTask.value
    }

    @Test func oldForwarderCannotEmitAfterAcknowledgedSwap() async throws {
        let engineA = ControllableFakeEngine(id: "A")
        let engineB = ControllableFakeEngine(id: "B")
        let router = QueueEngineHotSwap(engineA)
        await engineA.awaitSubscription()

        var iterator = router.events.makeAsyncIterator()
        await router.swap(to: engineB)
        await engineB.awaitSubscription()

        engineA.continuation.yield(.enqueued(makeItem(id: "retired")))
        engineB.continuation.yield(.enqueued(makeItem(id: "replacement")))

        let event = try #require(await iterator.next())
        guard case .enqueued(let item) = event else {
            Issue.record("Expected one enqueued event after swap")
            return
        }
        #expect(item.id == QueueItemID(rawValue: "replacement"))
    }

    @Test func enqueueForwardsToCurrentEngine() async throws {
        let engine = ControllableFakeEngine(id: "engine-X")
        let router = QueueEngineHotSwap(engine)

        let id = try await router.enqueue(QueueItemRequest(
            queue: .extraction, wikiID: WikiID(rawValue: "wiki"), payload: QueueItemPayload(sourceIDs: [])))
        #expect(id == QueueItemID(rawValue: "engine-X"))
    }

    // MARK: - Helpers

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: QueueItemID(rawValue: id), queue: .extraction, wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: []),
            state: .queued, orderingKey: 0, attempt: 0,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
#endif
