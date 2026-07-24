#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine

/// A `QueueEngineClient` that forwards every call to a mutable inner engine.
/// Enables the daemon-health flow (#878) to swap from an XPC proxy to a local
/// `QueueEngine` mid-session when the daemon dies — without changing any
/// consumer's captured reference.
///
/// **Event stream unification:** consumers (`QueueActivityTracker`,
/// `MenuBarItemController`, `OperationNotifier`) subscribe to `events` once.
/// This router owns a single `AsyncStream` continuation and republishes events
/// from whichever inner engine is active. When `swap(to:)` is called, the old
/// forwarding task is cancelled and a new one starts for the new engine —
/// consumers see a continuous stream across the swap.
///
/// Thread-safe: the `_current` engine is protected by an `NSLock`; the event
/// continuation is inherently safe (`AsyncStream.Continuation.yield` is
/// thread-safe).
final class QueueEngineHotSwap: QueueEngineClient, @unchecked Sendable {

    private let lock = NSLock()
    private var _current: any QueueEngineClient

    /// The unified event stream — republishes from whichever engine is active.
    private let continuation: AsyncStream<QueueEvent>.Continuation
    private let stream: AsyncStream<QueueEvent>

    /// Background task forwarding events from the current inner engine into
    /// `continuation`. Cancelled + restarted on every `swap`.
    private var forwardTask: Task<Void, Never>?

    init(_ engine: any QueueEngineClient) {
        self._current = engine
        let (s, c) = AsyncStream.makeStream(of: QueueEvent.self, bufferingPolicy: .bufferingOldest(256))
        self.stream = s
        self.continuation = c
        startForwarding(from: engine)
    }

    deinit {
        forwardTask?.cancel()
        continuation.finish()
    }

    /// The currently-active inner engine.
    var current: any QueueEngineClient {
        lock.withLock { _current }
    }

    /// Replace the inner engine. Cancels the old event-forwarding task and
    /// starts a new one for `engine`. Existing event-stream subscribers see a
    /// continuous stream (the same `AsyncStream` is fed by both the old and
    /// new engines in sequence).
    func swap(to engine: any QueueEngineClient) {
        forwardTask?.cancel()
        lock.withLock { _current = engine }
        startForwarding(from: engine)
        DebugLog.store("QueueEngineHotSwap: swapped to new engine (\(type(of: engine)))")
    }

    private func startForwarding(from engine: any QueueEngineClient) {
        let cont = continuation
        forwardTask = Task { [weak self] in
            for await event in engine.events {
                cont.yield(event)
            }
            // If `self` is deallocated the task is cancelled on deinit; the
            // loop exit here just means the engine's event stream ended.
            _ = self
        }
    }

    // MARK: - QueueEngineClient conformance

    var events: AsyncStream<QueueEvent> { stream }

    @discardableResult
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        try await current.enqueue(request)
    }

    func cancelItem(_ id: QueueItem.ID) async {
        await current.cancelItem(id)
    }

    @discardableResult
    func cancelAllInFlight() async -> Int {
        await current.cancelAllInFlight()
    }

    func retryItem(_ id: QueueItem.ID) async throws {
        try await current.retryItem(id)
    }

    func pause(_ queue: QueueKind) async {
        await current.pause(queue)
    }

    func resume(_ queue: QueueKind) async {
        await current.resume(queue)
    }

    func halt(_ queue: QueueKind) async {
        await current.halt(queue)
    }

    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {
        await current.reorderItem(id: id, beforeItemID: beforeItemID)
    }

    func snapshot() async -> QueueSnapshot {
        await current.snapshot()
    }

    func hasActiveWork(for wikiID: String) async -> Bool {
        await current.hasActiveWork(for: wikiID)
    }

    func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> {
        await current.waitForCompletion(of: id)
    }

    func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] {
        await current.loadTranscript(for: itemID)
    }

    func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
        await current.loadAllActivitySnapshots()
    }
}
#endif
