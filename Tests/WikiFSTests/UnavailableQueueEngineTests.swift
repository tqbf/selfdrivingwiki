#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// `UnavailableQueueEngine` tests (issue #881): when the local `queue.sqlite`
/// cannot be opened, the app wires this engine in instead of silently falling
/// back to an in-memory store. Enqueue/retry surface a clear error; reads
/// return empty; the event stream finishes immediately.
@Suite(.timeLimit(.minutes(2)))
struct UnavailableQueueEngineTests {

    private let reason = "queue.sqlite is missing (test)"

    @Test func enqueueThrowsUnavailableError() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: "wiki",
            payload: QueueItemPayload(sourceIDs: [])
        )
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.enqueue(request)
        }
    }

    @Test func retryItemThrowsUnavailableError() async {
        let engine = UnavailableQueueEngine(reason: reason)
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.retryItem("some-item")
        }
    }

    @Test func waitForCompletionReturnsFailure() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let result = await engine.waitForCompletion(of: "some-item")
        if case .failure(let error) = result {
            #expect(error is UnavailableQueueEngine.Error)
        } else {
            Issue.record("expected .failure")
        }
    }

    @Test func snapshotIsEmpty() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let snapshot = await engine.snapshot()
        #expect(snapshot.activeItems.isEmpty)
        #expect(snapshot.recentItems.isEmpty)
        #expect(snapshot.activeIngestionWikis.isEmpty)
    }

    @Test func hasActiveWorkIsFalse() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let hasWork = await engine.hasActiveWork(for: "wiki")
        #expect(hasWork == false)
    }

    @Test func cancelAndReorderAreNoOps() async {
        let engine = UnavailableQueueEngine(reason: reason)
        // These must not throw — they're idempotent no-ops.
        await engine.cancelItem("item")
        let n = await engine.cancelAllInFlight()
        #expect(n == 0)
        await engine.pause(.extraction)
        await engine.resume(.extraction)
        await engine.halt(.extraction)
        await engine.reorderItem(id: "item", beforeItemID: nil)
    }

    @Test func readsReturnEmpty() async {
        let engine = UnavailableQueueEngine(reason: reason)
        #expect(await engine.loadTranscript(for: "item").isEmpty)
        #expect(await engine.loadAllActivitySnapshots().isEmpty)
    }

    @Test func reasonIsExposedForUserVisibleError() {
        let engine = UnavailableQueueEngine(reason: reason)
        #expect(engine.reason == reason)
    }

    @Test func eventsStreamFinishesImmediately() async {
        let engine = UnavailableQueueEngine(reason: reason)
        // The stream should finish right away (no events produced).
        let count = await taskCount(engine)
        #expect(count == 0)
    }

    private func taskCount(_ engine: UnavailableQueueEngine) async -> Int {
        var n = 0
        for await _ in engine.events { n += 1 }
        return n
    }

    @Test func conformsToQueueEngineClient() {
        // Compile-time proof: UnavailableQueueEngine can be assigned to the
        // existential protocol (mirrors QueueEngineClientConformanceTests).
        let engine = UnavailableQueueEngine(reason: reason)
        let client: any QueueEngineClient = engine
        #expect(client is UnavailableQueueEngine)
    }

    @Test func errorDescriptionIncludesReason() {
        let error = UnavailableQueueEngine.Error.unavailable(reason: reason)
        #expect(String(describing: error).contains(reason))
    }
}
#endif
