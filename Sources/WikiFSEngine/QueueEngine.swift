import Foundation
import WikiFSCore

// MARK: - QueueEngine

/// The single owner of queue scheduling. An `actor` so scheduling state is
/// race-free without manual locking. Every state change writes through to
/// ``QueueStore`` before it is observable — the in-memory state and the
/// database never diverge.
///
/// **Dispatch model:** event-driven (no polling). Any change that could
/// unblock work — `enqueue`, item finish, `resume`, `retryItem` — triggers
/// `dispatchScan()`, which walks each running queue in `orderingKey` order
/// and starts every satisfiable item.
///
/// **Capacity:**
/// - Extraction: local pdf2md serialized (limit 1); remote backends get a
///   configurable limit (default 2). Determined by `QueueEngineConfig`.
/// - Ingestion: per-provider `maxConcurrent` (default 1). Items on different
///   providers run simultaneously.
/// - Per-wiki invariant: at most one ingestion runs per wiki at a time.
///
/// **Pause** stops new dispatch; in-flight items complete. **Halt**
/// additionally cancels in-flight worker `Task`s — halted items return to
/// `.queued` at their old position (via `requeue`).
///
/// **Headless:** the engine imports only `Foundation` + `WikiFSCore`. It never
/// names `@MainActor` types (`SessionManager`, `WikiSession`,
/// `WikiStoreModel`) — the app injects `QueueWorkerFactory` at construction so
/// the engine sees only `Sendable` protocols. This keeps the engine hostable
/// outside the GUI process (XPC/service) without a rewrite.
public actor QueueEngine {

    // MARK: - Stored properties

    private let store: QueueStore
    private let config: QueueEngineConfig
    private let workerFactory: any QueueWorkerFactory

    /// In-memory mirror of per-provider active (running) counts, used for
    /// capacity checks during dispatch. Derived from `runningItems`.
    private var providerActiveCounts: [String: Int] = [:]

    /// Wikis with an active (`.running`) ingestion item. Enforces the
    /// per-wiki invariant: at most one ingestion per wiki at a time.
    private var activeIngestionWikis: Set<String> = []

    /// Bonne: the `Task` for each running item, so `halt` can cancel them.
    private var runningTasks: [QueueItem.ID: Task<Void, Never>] = [:]

    /// Whether the engine should stop dispatching. Set by `pause`; cleared by
    /// `resume`. Persisted via `QueueStore.setQueueRunState`.
    private var runStates: [QueueKind: QueueRunState] = [:]

    /// Fan-out for queue events. `AsyncStream` is single-consumer — with
    /// several `for await` loops on ONE stream, each event is delivered to
    /// exactly one of them (racily). The engine has multiple UI consumers
    /// (activity tracker, status item, activity window), so each access of
    /// ``events`` subscribes a fresh stream and the broadcaster yields every
    /// event to all live subscribers.
    private nonisolated let broadcaster = QueueEventBroadcaster()

    /// A fresh event-stream subscription. Every access returns a NEW stream
    /// that receives all events emitted from this point on — safe for any
    /// number of concurrent consumers. (Events emitted before subscription
    /// are not replayed; consumers needing current state should also call
    /// ``snapshot()``.)
    public nonisolated var events: AsyncStream<QueueEvent> {
        broadcaster.subscribe()
    }

    /// Whether the engine has been initialized (rehydration + initial dispatch).
    private var didStart = false

    /// Pending `waitForCompletion` waiters, keyed by item ID. Resumed by
    /// `handleWorkerFinished` when the item reaches a terminal state.
    private var completionWaiters: [QueueItem.ID: [CheckedContinuation<Result<Void, Error>, Never>]] = [:]

    // MARK: - Init

    /// Create the engine. Does NOT start dispatching — call ``start()``
    /// after construction to rehydrate from the store and begin the initial
    /// dispatch scan. This split lets tests construct the engine, inject
    /// expectations, then start.
    public init(
        store: QueueStore,
        config: QueueEngineConfig = QueueEngineConfig(),
        workerFactory: any QueueWorkerFactory
    ) {
        self.store = store
        self.config = config
        self.workerFactory = workerFactory
    }

    // MARK: - Start (rehydration + initial dispatch)

    /// Rehydrate in-memory state from the store: crash-recover running items,
    /// load run states, then dispatch. Safe to call once; subsequent calls are
    /// no-ops.
    public func start() async {
        guard !didStart else { return }
        didStart = true

        // Crash recovery: any items left `.running` from a previous session
        // are reset to `.queued` (attempt preserved).
        let resetCount = (try? store.resetRunningToQueued()) ?? 0
        if resetCount > 0 {
            DebugLog.store("QueueEngine.start: reset \(resetCount) running items to queued")
        }

        // Re-sync in-memory state after the reset. If items were dispatched
        // during `enqueue` before `start()` was called, `resetRunningToQueued`
        // may have reset those items from `.running` to `.queued` in the DB
        // without clearing the in-memory provider counts / wiki set. Without
        // this rebuild, `dispatchScan` would skip those items because the
        // stale counts make the provider look at-capacity.
        await rebuildInMemoryState()

        // Load run states.
        for queue in [QueueKind.extraction, QueueKind.ingestion] {
            runStates[queue] = (try? store.queueRunState(for: queue)) ?? .running
        }

        // Initial dispatch scan.
        await dispatchScan()
    }

    // MARK: - Enqueue

    /// Enqueue a new item. Writes through to the store immediately, emits an
    /// `.enqueued` event, and triggers a dispatch scan. Returns the item's ID.
    @discardableResult
    public func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        // Synchronous shape validation (AC4.2): reject empty wikiID before the
        // store write so doomed items never enter the queue.
        guard !request.wikiID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QueueStoreError.invalidRequest("wikiID must not be empty")
        }
        let item = try store.enqueue(request)
        emit(.enqueued(item))
        await dispatchScan()
        return item.id
    }

    // MARK: - Pause / Resume / Halt

    /// Pause a queue: stop dispatching new items. In-flight items complete
    /// normally. Pause state persists across relaunch (written to the store).
    public func pause(_ queue: QueueKind) async {
        runStates[queue] = .paused
        try? store.setQueueRunState(queue, .paused)
        emit(.runStateChanged(queue: queue, state: .paused))
    }

    /// Resume a queue: restart dispatch. Persists the run state.
    public func resume(_ queue: QueueKind) async {
        runStates[queue] = .running
        try? store.setQueueRunState(queue, .running)
        emit(.runStateChanged(queue: queue, state: .running))
        await dispatchScan()
    }

    /// Halt a queue: pause + cancel all in-flight items for this queue kind.
    /// Cancelled items return to `.queued` at their prior position (via
    /// `requeue`, which preserves `orderingKey`).
    public func halt(_ queue: QueueKind) async {
        runStates[queue] = .paused
        try? store.setQueueRunState(queue, .paused)
        emit(.runStateChanged(queue: queue, state: .paused))

        // Cancel all running tasks for this queue kind.
        let activeItems = (try? store.loadActive(for: queue)) ?? []
        for item in activeItems where item.state == .running {
            if let task = runningTasks.removeValue(forKey: item.id) {
                task.cancel()
            }
            // Requeue: running → queued, preserves orderingKey.
            // This may fail if the item is mid-transition; best-effort.
            do {
                try store.requeue(id: item.id)
                if let updated = try store.getItem(item.id) {
                    emit(.cancelled(updated))
                }
            } catch {
                DebugLog.store("QueueEngine.halt: failed to requeue \(item.id): \(error)")
            }
        }
        // Rebuild counts after halting.
        await rebuildInMemoryState()
    }

    // MARK: - Cancel / Retry

    /// Cancel a specific queued or running item. Running items have their
    /// worker `Task` cancelled, then transition to `.cancelled` (preserving
    /// `orderingKey`).
    public func cancelItem(_ id: QueueItem.ID) async {
        // Cancel the worker task if running.
        if let task = runningTasks.removeValue(forKey: id) {
            task.cancel()
        }

        // Transition to cancelled (valid from queued or running).
        do {
            try store.markCancelled(id: id)
            if let updated = try store.getItem(id) {
                emit(.cancelled(updated))
                decrementProviderCount(for: updated)
                activeIngestionWikis.remove(updated.wikiID)
            }
        } catch {
            // The item may be in a terminal state already, or the
            // transition is invalid. Best-effort + log.
            DebugLog.store("QueueEngine.cancelItem: failed for \(id): \(error)")
        }
        await dispatchScan()
    }

    /// Retry a failed item: `failed` → `queued`, `attempt + 1`, new
    /// `orderingKey` (back of queue). Triggers a dispatch scan.
    public func retryItem(_ id: QueueItem.ID) async throws {
        try store.retryItem(id: id)
        if let updated = try store.getItem(id) {
            emit(.enqueued(updated))
        }
        await dispatchScan()
    }

    // MARK: - Reorder

    /// Move a queued item to a new position in its queue. The item is placed
    /// **before** `beforeItemID` (i.e., it gets an ordering key lower than
    /// that item). If `beforeItemID` is `nil`, the item is moved to the end.
    ///
    /// Only `.queued` items can be reordered — `.running` items are actively
    /// being processed and must stay in place. Items in other queues are
    /// unaffected (ordering keys are per-queue-kind).
    ///
    /// The new key is computed as the midpoint between the neighbor keys.
    /// With the default 1000-gap scheme, there is always room. If the gap
    /// shrinks to zero (extremely unlikely), the item is placed at
    /// `max + 1000` as a fallback.
    public func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {
        guard let item = try? store.getItem(id), item.state == .queued else { return }

        var key: Int64
        if let beforeID = beforeItemID,
           let beforeItem = try? store.getItem(beforeID) {
            // Move before `beforeItem`: new key is between the predecessor
            // and `beforeItem`.
            let active = (try? store.loadActive(for: item.queue)) ?? []
            let beforeKey = beforeItem.orderingKey
            let predecessorKey = active
                .map(\.orderingKey)
                .filter { $0 < beforeKey }
                .max() ?? 0
            let midpoint = predecessorKey + (beforeKey - predecessorKey) / 2
            if midpoint > predecessorKey && midpoint < beforeKey {
                key = midpoint
            } else {
                // Gap too small — fall back to end of queue.
                let maxKey = (try? store.maxOrderingKey(for: item.queue)) ?? 0
                key = max(maxKey, beforeKey) + 1000
            }
        } else {
            // Move to end.
            key = ((try? store.maxOrderingKey(for: item.queue)) ?? 0) + 1000
        }

        _ = try? store.updateOrderingKey(id: id, key: key)
        if let updated = try? store.getItem(id) {
            emit(.reordered(updated))
        }
    }

    // MARK: - Has active work

    /// Whether the engine has any queued or running items for the given wiki.
    /// Used by `RootScene.onDisappear` to decide whether to retain a session
    /// (if work is pending) or release it.
    public func hasActiveWork(for wikiID: String) -> Bool {
        let active = (try? store.loadActive()) ?? []
        return active.contains { $0.wikiID == wikiID }
    }

    // MARK: - Snapshot

    /// A point-in-time view of the engine's full state, for UI bootstrap and
    /// test assertions.
    public func snapshot() -> QueueSnapshot {
        let activeItems = (try? store.loadActive()) ?? []
        let recentItems = (try? store.loadRecent(limit: config.recentLimit)) ?? []
        let qs: [QueueKind: QueueRunState] = [
            .extraction: runStates[.extraction] ?? .running,
            .ingestion: runStates[.ingestion] ?? .running,
        ]
        return QueueSnapshot(
            activeItems: activeItems,
            recentItems: recentItems,
            runStates: qs,
            providerCounts: providerActiveCounts,
            activeIngestionWikis: activeIngestionWikis
        )
    }

    // MARK: - Wait for completion

    /// Await the completion of a specific item. Returns `.success` on
    /// `.completed`, `.failure` on `.failed` or `.cancelled`.
    ///
    /// FIRST checks the current state via `store.getItem(id)` — if the item is
    /// already terminal (e.g. the worker finished fast before this call),
    /// returns the corresponding Result synchronously without registering a
    /// continuation (so fast-completing items don't leak a continuation).
    /// Otherwise registers a `CheckedContinuation` keyed by item ID;
    /// `handleWorkerFinished` resumes all waiters for the item and empties
    /// the waiters array.
    public func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> {
        // Check if already terminal.
        if let item = try? store.getItem(id), item.state == .completed {
            return .success(())
        }
        if let item = try? store.getItem(id), item.state == .failed {
            return .failure(QueueExtractionError.notReady(item.error ?? "unknown"))
        }
        if let item = try? store.getItem(id), item.state == .cancelled {
            return .failure(CancellationError())
        }

        // Register a waiter.
        return await withCheckedContinuation { c in
            completionWaiters[id, default: []].append(c)
        }
    }

    // MARK: - Emit progress (for worker factory)

    /// A `Sendable` closure the worker factory captures to yield `.progress`
    /// events onto the engine's broadcaster (bypassing `emit()` which is
    /// actor-isolated). The broadcaster is `Sendable`, so this is safe to
    /// call from the worker's detached `Task`.
    public func makeEmitProgress() -> @Sendable (QueueItem.ID, String) -> Void {
        return { [broadcaster] id, line in
            broadcaster.yield(.progress(id, line: line))
        }
    }

    /// A `Sendable` closure the worker factory captures to yield `.transcript`
    /// events onto the engine's broadcaster (bypassing `emit()` which is
    /// actor-isolated). The broadcaster is `Sendable`, so this is safe to
    /// call from the worker's detached `Task`.
    public func makeEmitTranscript() -> @Sendable (QueueItem.ID, AgentEvent) -> Void {
        return { [broadcaster, store] id, event in
            broadcaster.yield(.transcript(id, event))
            // Persist to SQLite for cross-session transcript survival —
            // final events only. Streaming deltas / turn boundaries are
            // display plumbing; the final `.assistantText` carries the full
            // text, so persisting every delta bloats rows AND rehydrates as
            // one row per word-fragment.
            guard event.isPersistable else { return }
            try? store.appendItemEvent(itemID: id, event: event)
        }
    }

    /// Load persisted agent events (transcript) for a queue item from the DB.
    /// Used by the Activity tracker to show transcripts for items rehydrated
    /// from a previous session. Deltas are folded into whole rows on the way
    /// out — rows persisted before deltas were filtered contain fragments.
    public func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] {
        AgentEvent.mergingStreamDeltas((try? store.loadItemEvents(itemID: itemID)) ?? [])
    }

    /// Delete persisted events for an item (e.g. on retry).
    public func clearTranscript(for itemID: QueueItem.ID) async {
        try? store.deleteItemEvents(itemID: itemID)
    }

    // MARK: - Dispatch (internal)

    /// Event-driven dispatch scan: walk each running queue in `orderingKey`
    /// order and start every satisfiable item. Called after `enqueue`,
    /// `resume`, `retryItem`, and item completion/cancellation.
    ///
    /// This is the heart of the scheduler. It uses an unstructured `Task`
    /// (non-detached) per worker so the worker's `await` points suspend the
    /// actor and let other messages proceed.
    ///
    /// **Reentrancy safety:** Swift actors are reentrant — when `dispatchScan`
    /// suspends at an `await`, the actor can process another message (e.g.
    /// `handleWorkerFinished` → `dispatchScan`). To prevent the per-wiki and
    /// per-provider invariants from being violated across this suspension, the
    /// capacity check + invariant check + `markRunning` + in-memory update are
    /// performed as a single synchronous block AFTER the one `await` that
    /// resolves the provider ID. No `await` separates the check from the set.
    private func dispatchScan() async {
        // For each queue kind that is `.running`, try to dispatch items.
        for queue in [QueueKind.extraction, QueueKind.ingestion] {
            guard runStates[queue] == .running else { continue }

            let active = (try? store.loadActive(for: queue)) ?? []
            for item in active where item.state == .queued {
                // The ONE await — resolve the provider up front.
                guard let providerID = await workerFactory.providerID(for: item) else {
                    continue  // No provider available; item stays queued.
                }

                // From here, NO await until the item is claimed and the
                // in-memory counts are updated. This keeps the check-and-claim
                // atomic within the actor's serialized execution — a reentrant
                // dispatchScan that runs during the await above sees the
                // pre-claim state; one that runs after this block sees the
                // post-claim state (counts updated, wiki inserted).
                let limit: Int
                switch item.queue {
                case .extraction:
                    limit = config.extractionLimit(for: providerID)
                case .ingestion:
                    limit = config.ingestionLimit(for: providerID)
                }

                // Per-provider capacity check.
                let currentCount = providerActiveCounts[providerID] ?? 0
                guard currentCount < limit else { continue }

                // Per-wiki ingestion invariant: at most one ingestion per wiki.
                if item.queue == .ingestion {
                    guard !activeIngestionWikis.contains(item.wikiID) else { continue }
                }

                // Claim the item: mark running (synchronous store call).
                do {
                    try store.markRunning(id: item.id, providerID: providerID)
                } catch {
                    DebugLog.store("QueueEngine.dispatchScan: claim failed for \(item.id): \(error)")
                    continue
                }

                // Read back the running item for the event (synchronous).
                guard let runningItem = try? store.getItem(item.id) else { continue }

                // Update in-memory counts — immediately after the successful
                // claim, with no suspension in between.
                incrementProviderCount(providerID)
                if item.queue == .ingestion {
                    activeIngestionWikis.insert(item.wikiID)
                }

                // Emit the started event.
                emit(.started(runningItem))

                // Spawn the worker task.
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runWorker(runningItem)
                }
                runningTasks[item.id] = task
            }
        }
    }

    // MARK: - Worker execution

    /// Run a worker for `item`. Called in a detached `Task` so the engine
    /// is not blocked. On completion, transitions the item to `.completed`
    /// (success) or `.failed` (throw). On cancellation (from `halt` or
    /// `cancelItem`), the item is requeued (halt) or marked cancelled
    /// (cancel). After the worker finishes, triggers a dispatch scan.
    private func runWorker(_ item: QueueItem) async {
        let worker: any QueueWorker
        do {
            worker = try await workerFactory.worker(for: item)
        } catch {
            // Factory failed to produce a worker — mark the item failed.
            await handleWorkerFinished(item, result: .failure(error))
            return
        }

        // Execute the worker. Cancellation propagates via `Task.checkCancellation()`
        // inside the worker's `await` points.
        let result: Result<Void, Error>
        do {
            try await worker.execute(item)
            result = .success(())
        } catch is CancellationError {
            result = .failure(CancellationError())
        } catch {
            result = .failure(error)
        }

        await handleWorkerFinished(item, result: result)
    }

    /// Handle the completion of a worker. Transitions the item to a terminal
    /// state, cleans up in-memory tracking, emits an event, and triggers a
    /// dispatch scan.
    ///
    /// **Slot ownership:** the provider count and wiki set are only decremented
    /// in the branches that own the transition (success / failure). For the
    /// cancellation path, `cancelItem` or `halt` has ALREADY freed the slot —
    /// so we skip the decrement to avoid double-freeing. The only exception is
    /// if the item is still `.running` (orphaned after cancellation), which we
    /// requeue + free.
    private func handleWorkerFinished(_ item: QueueItem, result: Result<Void, Error>) async {
        runningTasks.removeValue(forKey: item.id)

        switch result {
        case .success:
            do {
                try store.markCompleted(id: item.id)
                decrementProviderCount(for: item)
                if item.queue == .ingestion {
                    activeIngestionWikis.remove(item.wikiID)
                }
                if let updated = try store.getItem(item.id) {
                    emit(.completed(updated))
                }
            } catch {
                // markCompleted can fail if the item was requeued/cancelled
                // while the worker was finishing. The work is done — log and
                // free the slot defensively.
                DebugLog.store("QueueEngine: markCompleted failed for \(item.id): \(error)")
                decrementProviderCount(for: item)
                if item.queue == .ingestion {
                    activeIngestionWikis.remove(item.wikiID)
                }
            }

        case .failure(let error):
            if error is CancellationError {
                // Cancellation from halt: the item was already requeued by
                // `halt` (which calls `store.requeue` + `rebuildInMemoryState`).
                // Cancellation from `cancelItem`: the item was already marked
                // `.cancelled` and the slot was freed there.
                // Either way, the slot is already freed — DON'T double-decrement.
                // Only act if the item is orphaned (still .running).
                if let updated = try? store.getItem(item.id), updated.state == .running {
                    try? store.requeue(id: item.id)
                    decrementProviderCount(for: item)
                    if item.queue == .ingestion {
                        activeIngestionWikis.remove(item.wikiID)
                    }
                    if let requeued = try? store.getItem(item.id) {
                        emit(.cancelled(requeued))
                    }
                }
            } else {
                let errorMsg = String(describing: error)
                do {
                    try store.markFailed(id: item.id, error: errorMsg)
                    decrementProviderCount(for: item)
                    if item.queue == .ingestion {
                        activeIngestionWikis.remove(item.wikiID)
                    }
                    if let updated = try store.getItem(item.id) {
                        emit(.failed(updated, error: errorMsg))
                    }
                } catch {
                    DebugLog.store("QueueEngine: markFailed failed for \(item.id): \(error)")
                    decrementProviderCount(for: item)
                    if item.queue == .ingestion {
                        activeIngestionWikis.remove(item.wikiID)
                    }
                }
            }
        }

        // Resume any `waitForCompletion` waiters for this item.
        resumeWaiters(for: item.id, result: result)

        // Trigger dispatch for potentially unblocked items.
        await dispatchScan()
    }

    /// Resume all `waitForCompletion` waiters for an item with the given result
    /// and clear the waiters array.
    private func resumeWaiters(for id: QueueItem.ID, result: Result<Void, Error>) {
        guard let waiters = completionWaiters.removeValue(forKey: id) else { return }
        for w in waiters {
            w.resume(returning: result)
        }
    }

    // MARK: - In-memory state management

    /// Increment the active count for a provider.
    private func incrementProviderCount(_ providerID: String) {
        providerActiveCounts[providerID, default: 0] += 1
    }

    /// Decrement the active count for a provider (clamped at 0).
    private func decrementProviderCount(for item: QueueItem) {
        guard let providerID = item.providerID else { return }
        let current = providerActiveCounts[providerID, default: 0]
        if current <= 1 {
            providerActiveCounts.removeValue(forKey: providerID)
        } else {
            providerActiveCounts[providerID] = current - 1
        }
    }

    /// Rebuild in-memory state from the store. Called after `halt` to
    /// resync counts and wiki set.
    private func rebuildInMemoryState() async {
        providerActiveCounts.removeAll()
        activeIngestionWikis.removeAll()

        let active = (try? store.loadActive()) ?? []
        for item in active where item.state == .running {
            if let providerID = item.providerID {
                incrementProviderCount(providerID)
            }
            if item.queue == .ingestion {
                activeIngestionWikis.insert(item.wikiID)
            }
        }
    }

    // MARK: - Event emission

    /// Emit a `QueueEvent` to all subscribers.
    private func emit(_ event: QueueEvent) {
        broadcaster.yield(event)
    }
}

// MARK: - QueueEventBroadcaster

/// Thread-safe multicast of ``QueueEvent``s to any number of subscribers.
///
/// Each ``subscribe()`` returns an independent `AsyncStream`; ``yield(_:)``
/// delivers the event to every live subscriber (buffered 256 per subscriber
/// so a slow consumer doesn't block the engine or starve the others).
/// Terminated streams (consumer task cancelled / deallocated) unregister
/// themselves via `onTermination`.
final class QueueEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<QueueEvent>.Continuation] = [:]

    func subscribe() -> AsyncStream<QueueEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ event: QueueEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
