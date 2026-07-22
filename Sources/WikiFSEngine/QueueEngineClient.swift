import Foundation
import WikiFSCore

// MARK: - QueueEngineClient

/// The queue-engine surface the app consumes. The concrete ``QueueEngine``
/// actor conforms; a future `XPCQueueEngineProxy` (Phase A) will conform
/// too, letting the source flip from in-process to daemon-hosted without
/// rewriting call sites.
///
/// `AnyObject`-bound so consumers can hold `weak` references (the engine
/// outlives individual view-models — `QueueActivityTracker`,
/// `QueueViewModel`).
///
/// **`events` resolution (C4):** the protocol declares `events` as
/// `AsyncStream<QueueEvent>`. The concrete ``QueueEngine`` returns a
/// broadcaster-backed stream. The future `XPCQueueEngineProxy` will return
/// a stream fed by `WikiDaemonEventSink.deliverEvent` — so consumers
/// (`QueueActivityTracker`, `OperationNotifier`, `MenuBarItemController`)
/// keep the same `for await event in engine.events { … }` loop unchanged.
///
/// See `plans/daemon-workloads.md` Phase 0 §4.
public protocol QueueEngineClient: AnyObject, Sendable {

    /// A fresh event-stream subscription. Every access returns a NEW stream
    /// that receives all events emitted from this point on. The concrete
    /// ``QueueEngine`` yields from a thread-safe broadcaster; the future
    /// XPC proxy yields from a stream fed by `deliverEvent` callbacks.
    var events: AsyncStream<QueueEvent> { get }

    // MARK: - Enqueue / Cancel / Retry

    /// Enqueue a new item. Returns the item's ID.
    @discardableResult
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID

    /// Cancel a specific queued or running item.
    func cancelItem(_ id: QueueItem.ID) async

    /// Cancel ALL in-flight (`.running`) items across every queue kind.
    /// Used by the app's quit path.
    @discardableResult
    func cancelAllInFlight() async -> Int

    /// Retry a failed item: `failed` → `queued`, `attempt + 1`.
    func retryItem(_ id: QueueItem.ID) async throws

    // MARK: - Pause / Resume / Halt / Reorder

    /// Pause a queue: stop dispatching new items. In-flight items complete.
    func pause(_ queue: QueueKind) async

    /// Resume a queue: restart dispatch.
    func resume(_ queue: QueueKind) async

    /// Halt a queue: pause + cancel all in-flight items for this queue kind.
    func halt(_ queue: QueueKind) async

    /// Move a queued item to a new position (before `beforeItemID`, or end).
    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async

    // MARK: - Snapshot / Status

    /// A point-in-time view of the engine's full state.
    func snapshot() async -> QueueSnapshot

    /// Whether the engine has any queued or running items for the given wiki.
    func hasActiveWork(for wikiID: String) async -> Bool

    // MARK: - Await / Transcript / Activity

    /// Await the completion of a specific item.
    func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error>

    /// Load persisted agent events (transcript) for a queue item.
    func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent]

    /// Load persisted activity metadata for all items with recorded activity.
    func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot]
}

// MARK: - QueueEngine conformance

/// The concrete ``QueueEngine`` actor conforms to ``QueueEngineClient``.
/// Every method on the protocol is already implemented on the actor — the
/// conformance is implicit but declared explicitly for documentation and
/// to catch missing methods at compile time if the protocol evolves.
extension QueueEngine: QueueEngineClient {}
