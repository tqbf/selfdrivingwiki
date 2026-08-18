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
/// The actor serializes client replacement and operation admission. The event
/// broadcaster is immutable and thread-safe, so consumers can subscribe without
/// entering the actor.
actor QueueEngineHotSwap: QueueEngineClient {

    private var activeClient: any QueueEngineClient
    private var clientGeneration: UInt64 = 0
    private var admissionCounts: [UInt64: Int] = [:]
    private var admissionWaiters: [UInt64: [AsyncStream<Void>.Continuation]] = [:]

    /// The unified event broadcaster — multicasts from whichever engine is active.
    nonisolated private let broadcaster = QueueEventBroadcaster()

    /// Background task forwarding events from the current inner engine into
    /// the broadcaster. Cancelled and awaited on every `swap`.
    private var forwardTask: Task<Void, Never>

    init(_ engine: any QueueEngineClient) {
        self.activeClient = engine
        let broadcaster = self.broadcaster
        let events = engine.events
        self.forwardTask = Task {
            for await event in events {
                broadcaster.yield(event)
            }
        }
    }

    deinit {
        forwardTask.cancel()
        broadcaster.finish()
    }

    /// The currently active inner client.
    var current: any QueueEngineClient { activeClient }

    /// Replace the inner client and start its event subscription before this
    /// method returns. The method cancels and awaits the retired forwarder, so
    /// the caller can safely dispose resources owned by the retired client.
    func swap(to engine: any QueueEngineClient) async {
        let retiredGeneration = clientGeneration
        let retiredTask = forwardTask
        let broadcaster = broadcaster
        let events = engine.events

        clientGeneration &+= 1
        let installedGeneration = clientGeneration
        activeClient = engine
        forwardTask = Task {
            for await event in events {
                broadcaster.yield(event)
            }
        }

        retiredTask.cancel()
        await retiredTask.value
        await waitForAdmissions(toDrain: retiredGeneration)
        guard clientGeneration == installedGeneration else { return }
        DebugLog.store("QueueEngineHotSwap: swapped to new engine (\(type(of: engine)))")
    }

    private func admit() -> (client: any QueueEngineClient, generation: UInt64) {
        let generation = clientGeneration
        admissionCounts[generation, default: 0] += 1
        return (activeClient, generation)
    }

    private func releaseAdmission(_ generation: UInt64) {
        guard let count = admissionCounts[generation] else { return }
        if count > 1 {
            admissionCounts[generation] = count - 1
            return
        }

        admissionCounts[generation] = nil
        let waiters = admissionWaiters.removeValue(forKey: generation) ?? []
        for waiter in waiters { waiter.finish() }
    }

    private func waitForAdmissions(toDrain generation: UInt64) async {
        guard admissionCounts[generation, default: 0] > 0 else { return }
        let pair = AsyncStream<Void>.makeStream()
        admissionWaiters[generation, default: []].append(pair.continuation)
        for await _ in pair.stream { break }
    }

    // MARK: - QueueEngineClient conformance

    nonisolated var events: AsyncStream<QueueEvent> { broadcaster.subscribe() }


    @discardableResult
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.enqueue(request)
    }

    func cancelItem(_ id: QueueItem.ID) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.cancelItem(id)
    }

    @discardableResult
    func cancelAllInFlight() async throws -> Int {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.cancelAllInFlight()
    }

    func retryItem(_ id: QueueItem.ID) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.retryItem(id)
    }

    func pause(_ queue: QueueKind) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.pause(queue)
    }

    func resume(_ queue: QueueKind) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.resume(queue)
    }

    func halt(_ queue: QueueKind) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.halt(queue)
    }

    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        try await admission.client.reorderItem(id: id, beforeItemID: beforeItemID)
    }

    func snapshot() async throws -> QueueSnapshot {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.snapshot()
    }

    func hasActiveWork(for wikiID: WikiID) async throws -> Bool {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.hasActiveWork(for: wikiID)
    }

    func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.waitForCompletion(of: id)
    }

    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.loadTranscript(for: itemID)
    }

    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
        let admission = admit()
        defer { releaseAdmission(admission.generation) }
        return try await admission.client.loadAllActivitySnapshots()
    }
}
#endif
