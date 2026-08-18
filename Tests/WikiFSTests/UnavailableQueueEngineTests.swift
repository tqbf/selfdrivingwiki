#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// `UnavailableQueueEngine` tests (issue #881): when the local `queue.sqlite`
/// cannot be opened, the app wires this engine in instead of silently falling
/// back to an in-memory store. Every operation surfaces a clear error, while
/// the event stream finishes immediately.
@Suite(.timeLimit(.minutes(2)))
struct UnavailableQueueEngineTests {

    private let reason = "queue.sqlite is missing (test)"

    @Test func enqueueThrowsUnavailableError() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [])
        )
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.enqueue(request)
        }
    }

    @Test func retryItemThrowsUnavailableError() async {
        let engine = UnavailableQueueEngine(reason: reason)
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.retryItem(QueueItem.ID(rawValue: "some-item"))
        }
    }

    @Test func unavailableOperationsNeverReturnNormalDefaults() async {
        let engine = UnavailableQueueEngine(reason: reason)
        let itemID = QueueItem.ID(rawValue: "item")

        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.cancelItem(itemID)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.cancelAllInFlight()
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.pause(.extraction)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.resume(.extraction)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.halt(.extraction)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            try await engine.reorderItem(id: itemID, beforeItemID: nil)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.snapshot()
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.hasActiveWork(for: WikiID(rawValue: "wiki"))
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.waitForCompletion(of: itemID)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.loadTranscript(for: itemID)
        }
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await engine.loadAllActivitySnapshots()
        }
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
