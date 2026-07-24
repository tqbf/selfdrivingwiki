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
        private(set) var snapshotCallCount = 0

        init(id: String) {
            self.id = id
            let (s, c) = AsyncStream.makeStream(of: QueueEvent.self)
            self.stream = s
            self.continuation = c
        }

        var events: AsyncStream<QueueEvent> { stream }
        @discardableResult
        func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { id }
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
            return QueueSnapshot()
        }
        func hasActiveWork(for wikiID: String) async -> Bool { false }
        func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> { .success(()) }
        func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] { [] }
        func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
    }

    // MARK: - Tests

    @Test func forwardsToCurrentEngine() async {
        let engine = ControllableFakeEngine(id: "engine-A")
        let router = QueueEngineHotSwap(engine)

        // snapshot() should forward to the current engine.
        _ = await router.snapshot()
        #expect(engine.snapshotCallCount == 1)
    }

    @Test func swapSwitchesForwardingToNewEngine() async {
        let engineA = ControllableFakeEngine(id: "A")
        let engineB = ControllableFakeEngine(id: "B")
        let router = QueueEngineHotSwap(engineA)

        // Before swap: forwards to A.
        _ = await router.snapshot()
        #expect(engineA.snapshotCallCount == 1)
        #expect(engineB.snapshotCallCount == 0)

        // Swap to B.
        router.swap(to: engineB)

        // After swap: forwards to B, not A.
        _ = await router.snapshot()
        #expect(engineA.snapshotCallCount == 1)  // unchanged
        #expect(engineB.snapshotCallCount == 1)  // new
    }

    @Test func currentReturnsActiveEngine() {
        let engineA = ControllableFakeEngine(id: "A")
        let router = QueueEngineHotSwap(engineA)

        // Before swap.
        #expect((router.current as? ControllableFakeEngine)?.id == "A")

        // After swap.
        let engineB = ControllableFakeEngine(id: "B")
        router.swap(to: engineB)
        #expect((router.current as? ControllableFakeEngine)?.id == "B")
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
                    ids.append(item.id)
                    if ids.count >= 2 { return ids }
                default: break
                }
            }
            return ids
        }

        // Emit from engine A.
        engineA.continuation.yield(.enqueued(makeItem(id: "item-A")))

        // Swap to engine B.
        try? await Task.sleep(for: .milliseconds(50))
        router.swap(to: engineB)
        try? await Task.sleep(for: .milliseconds(50))

        // Emit from engine B — should flow through the SAME router stream.
        engineB.continuation.yield(.enqueued(makeItem(id: "item-B")))

        let ids = await received.value
        #expect(ids == ["item-A", "item-B"])
    }

    @Test func enqueueForwardsToCurrentEngine() async throws {
        let engine = ControllableFakeEngine(id: "engine-X")
        let router = QueueEngineHotSwap(engine)

        let id = try await router.enqueue(QueueItemRequest(
            queue: .extraction, wikiID: "wiki", payload: QueueItemPayload(sourceIDs: [])))
        #expect(id == "engine-X")
    }

    // MARK: - Helpers

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id, queue: .extraction, wikiID: "wiki",
            payload: QueueItemPayload(sourceIDs: []),
            state: .queued, orderingKey: 0, attempt: 0,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
#endif
