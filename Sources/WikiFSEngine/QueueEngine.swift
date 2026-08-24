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
    private let workerExecutor: any QueueWorkerExecutor
    private let shutdownPolicy: QueueEngineShutdownPolicy
    private let deadlineSource: any QueueEngineDeadlineSource

    /// In-memory mirror of per-provider active (running) counts, used for
    /// capacity checks during dispatch. Derived from `runningItems`.
    private var providerActiveCounts: [ProviderID: Int] = [:]

    /// Wikis with an active (`.running`) ingestion item. Enforces the
    /// per-wiki invariant: at most one ingestion per wiki at a time.
    private var activeIngestionWikis: Set<WikiID> = []

    private struct RunningDispatch {
        let leaseID: WorkerLeaseID
        let task: Task<Void, Never>
    }

    /// The exact dispatch identity and task for each running item.
    private var runningTasks: [QueueItem.ID: RunningDispatch] = [:]

    /// Whether the engine should stop dispatching. Set by `pause`; cleared by
    /// `resume`. Persisted via `QueueStore.setQueueRunState`.
    private var runStates: [QueueKind: QueueRunState] = [:]

    /// Ready-at-construction output boundary shared with worker factories.
    /// It owns event multicast, transcript reduction, and output persistence.
    public nonisolated let outputChannel: QueueWorkerOutputChannel

    /// A fresh event-stream subscription. Every access returns a NEW stream
    /// that receives all events emitted from this point on — safe for any
    /// number of concurrent consumers. (Events emitted before subscription
    /// are not replayed; consumers needing current state should also call
    /// ``snapshot()``.)
    public nonisolated var events: AsyncStream<QueueEvent> {
        outputChannel.events
    }

    /// The finite engine lifecycle. It is the sole dispatch admission state.
    public private(set) var lifecycle: QueueEngineLifecycle = .created
    private var shutdownTask: Task<QueueEngineShutdownResult, Never>?
    private var shutdownSettlementTask: Task<Void, Never>?
    private var shutdownSettlementSignal: QueueShutdownSettlementSignal?
    private var shutdownTrackedItemIDs: Set<QueueItem.ID> = []

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
        workerFactory: any QueueWorkerFactory,
        workerExecutor: any QueueWorkerExecutor = DirectQueueWorkerExecutor(),
        outputChannel: QueueWorkerOutputChannel? = nil,
        shutdownPolicy: QueueEngineShutdownPolicy = QueueEngineShutdownPolicy(),
        deadlineSource: any QueueEngineDeadlineSource = ContinuousQueueEngineDeadlineSource()
    ) {
        self.store = store
        self.config = config
        self.workerFactory = workerFactory
        self.workerExecutor = workerExecutor
        self.outputChannel = outputChannel ?? QueueWorkerOutputChannel(store: store)
        self.shutdownPolicy = shutdownPolicy
        self.deadlineSource = deadlineSource
    }

    deinit {
        shutdownTask?.cancel()
        shutdownSettlementTask?.cancel()
        for dispatch in runningTasks.values {
            dispatch.task.cancel()
        }
        for waiters in completionWaiters.values {
            for waiter in waiters {
                waiter.resume(returning: .failure(CancellationError()))
            }
        }
    }

    // MARK: - Start (rehydration + initial dispatch)

    /// Rehydrate in-memory state from the store: crash-recover running items,
    /// load run states, then dispatch. Safe to call once; subsequent calls are
    /// no-ops.
    public func start() async {
        guard lifecycle == .created else { return }
        lifecycle = .starting

        // Crash recovery: any items left `.running` from a previous session
        // are reset to `.queued` (attempt preserved).
        var resetCount = 0
        do {
            resetCount = try store.resetRunningToQueued()
        } catch {
            DebugLog.store("QueueEngine: failed to reset running items at launch: \(error)")
        }
        if resetCount > 0 {
            DebugLog.store("QueueEngine.start: reset \(resetCount) running items to queued")
        }

        // Re-sync in-memory state after the reset. `resetRunningToQueued` flips
        // leftover `.running` items back to `.queued` in the database, but the
        // in-memory `providerActiveCounts` / `activeIngestionWikis` still
        // reflect them as running. Without this rebuild, `dispatchScan` would
        // skip those items because the stale counts make their providers look
        // at-capacity — the item is stuck in `.queued` with no trigger to
        // re-dispatch it.
        await rebuildInMemoryState()

        // Load run states.
        for queue in [QueueKind.extraction, QueueKind.ingestion] {
            do {
                runStates[queue] = try store.queueRunState(for: queue)
            } catch {
                DebugLog.store("QueueEngine: failed to load run state for \(queue): \(error)")
                runStates[queue] = .running
            }
        }

        guard lifecycle == .starting else { return }
        lifecycle = .running
        // Initial dispatch scan.
        await dispatchScan()
    }

    public func shutdownForHandoff() async -> QueueEngineShutdownResult {
        if lifecycle == .shutDown { return .shutDown }
        if let shutdownTask { return await shutdownTask.value }

        if shutdownSettlementTask == nil {
            beginShutdownSettlement()
        } else {
            lifecycle = .shuttingDown
        }

        let task = Task<QueueEngineShutdownResult, Never> { [self] in
            await runShutdownRace()
        }
        shutdownTask = task
        return await task.value
    }

    private func beginShutdownSettlement() {
        lifecycle = .shuttingDown
        let outputDrainSnapshot = outputChannel.closeScopeAdmission()
        let outputDrains = outputDrainSnapshot.streams
        let activeItems: [QueueItem]
        do {
            activeItems = try store.loadActive().filter { $0.state == .running }
        } catch {
            DebugLog.store("QueueEngine.shutdown: failed to load running items: \(error)")
            activeItems = []
        }
        let workerTasks = runningTasks.values.map(\.task)
        shutdownTrackedItemIDs = Set(runningTasks.keys)
            .union(activeItems.map(\.id))
            .union(outputDrainSnapshot.itemIDs)
        for task in workerTasks { task.cancel() }
        for item in activeItems {
            do {
                try store.requeue(id: item.id)
            } catch {
                DebugLog.store("QueueEngine.shutdown: failed to requeue \(item.id.rawValue): \(error)")
            }
        }
        providerActiveCounts.removeAll()
        activeIngestionWikis.removeAll()
        resumeAllWaitersForShutdown()

        let signal = QueueShutdownSettlementSignal()
        shutdownSettlementSignal = signal
        shutdownSettlementTask = Task {
            for task in workerTasks { await task.value }
            for drain in outputDrains {
                for await _ in drain {}
            }
            signal.complete()
        }
    }

    private func runShutdownRace() async -> QueueEngineShutdownResult {
        guard let signal = shutdownSettlementSignal else {
            lifecycle = .shutDown
            outputChannel.finish()
            shutdownTask = nil
            return .shutDown
        }
        let settlement = signal.stream()
        let deadline = deadlineSource.stream(after: shutdownPolicy.workerSettlementDeadline)
        let outcome = await withTaskGroup(of: QueueShutdownRaceOutcome.self) { group in
            group.addTask {
                for await _ in settlement {}
                return .drained
            }
            group.addTask {
                for await _ in deadline { return .deadline }
                return .deadline
            }
            let first = await group.next() ?? .deadline
            group.cancelAll()
            return first
        }

        switch outcome {
        case .drained:
            if let settlementTask = shutdownSettlementTask { await settlementTask.value }
            shutdownSettlementTask = nil
            shutdownSettlementSignal = nil
            shutdownTrackedItemIDs.removeAll()
            outputChannel.finish()
            lifecycle = .shutDown
            shutdownTask = nil
            return .shutDown
        case .deadline:
            let activeItemIDs = shutdownTrackedItemIDs.union(runningTasks.keys)
            lifecycle = .shutdownBlocked(activeItemIDs: activeItemIDs)
            shutdownTask = nil
            return .shutdownBlocked(activeItemIDs: activeItemIDs)
        }
    }

    private func resumeAllWaitersForShutdown() {
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for itemWaiters in waiters.values {
            for waiter in itemWaiters {
                waiter.resume(returning: .failure(QueueEngineLifecycleError.shuttingDown))
            }
        }
    }

    private func requireEnqueueAllowed() throws {
        switch lifecycle {
        case .created, .starting, .running:
            return
        case .shuttingDown:
            throw QueueEngineLifecycleError.shuttingDown
        case .shutdownBlocked(let activeItemIDs):
            throw QueueEngineLifecycleError.shutdownBlocked(activeItemIDs: activeItemIDs)
        case .shutDown:
            throw QueueEngineLifecycleError.shutDown
        }
    }

    private func requireRunning() throws {
        switch lifecycle {
        case .running:
            return
        case .created, .starting:
            throw QueueEngineLifecycleError.notStarted
        case .shuttingDown:
            throw QueueEngineLifecycleError.shuttingDown
        case .shutdownBlocked(let activeItemIDs):
            throw QueueEngineLifecycleError.shutdownBlocked(activeItemIDs: activeItemIDs)
        case .shutDown:
            throw QueueEngineLifecycleError.shutDown
        }
    }

    // MARK: - Enqueue

    /// Enqueue a new item. Writes through to the store immediately, emits an
    /// `.enqueued` event, and triggers a dispatch scan. Returns the item's ID.
    @discardableResult
    public func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        try requireEnqueueAllowed()
        // Synchronous shape validation (AC4.2): reject empty wikiID before the
        // store write so doomed items never enter the queue.
        guard !request.wikiID.rawValue.trimmingCharacters(in: .whitespaces).isEmpty else {
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
        do {
            try store.setQueueRunState(queue, .paused)
        } catch {
            DebugLog.store("QueueEngine: failed to persist pause state for \(queue): \(error)")
        }
        emit(.runStateChanged(queue: queue, state: .paused))
    }

    /// Resume a queue: restart dispatch. Persists the run state.
    public func resume(_ queue: QueueKind) async throws {
        try requireRunning()
        runStates[queue] = .running
        do {
            try store.setQueueRunState(queue, .running)
        } catch {
            DebugLog.store("QueueEngine: failed to persist resume state for \(queue): \(error)")
        }
        emit(.runStateChanged(queue: queue, state: .running))
        await dispatchScan()
    }

    /// Halt a queue: pause + cancel all in-flight items for this queue kind.
    /// Cancelled items return to `.queued` at their prior position (via
    /// `requeue`, which preserves `orderingKey`).
    public func halt(_ queue: QueueKind) async {
        runStates[queue] = .paused
        do {
            try store.setQueueRunState(queue, .paused)
        } catch {
            DebugLog.store("QueueEngine: failed to persist halt state for \(queue): \(error)")
        }
        emit(.runStateChanged(queue: queue, state: .paused))

        // Cancel all running tasks for this queue kind.
        let activeItems: [QueueItem]
        do {
            activeItems = try store.loadActive(for: queue)
        } catch {
            DebugLog.store("QueueEngine: failed to load active items for halt: \(error)")
            activeItems = []
        }
        for item in activeItems where item.state == .running {
            if let dispatch = runningTasks.removeValue(forKey: item.id) {
                dispatch.task.cancel()
            }
            // Requeue: running → queued, preserves orderingKey.
            // This may fail if the item is mid-transition; best-effort.
            do {
                try store.requeue(id: item.id)
                if let updated = try store.getItem(item.id) {
                    emit(.cancelled(updated))
                }
            } catch {
                DebugLog.store("QueueEngine.halt: failed to requeue \(item.id.rawValue): \(error)")
            }
        }
        // Rebuild counts after halting.
        await rebuildInMemoryState()
    }

    // MARK: - Cancel / Retry

    /// Cancel ALL in-flight (`.running`) items across every queue kind. Used
    /// by the quit path to ensure running items are marked `.cancelled` in the
    /// store BEFORE the app terminates — so crash recovery on restart skips
    /// them (``resetRunningToQueued`` only touches `.running` items; a
    /// `.cancelled` item stays cancelled). Genuine crashes (no clean cancel)
    /// leave items `.running` and are still re-queued — this is correct.
    ///
    /// Returns the count of items cancelled. Safe to call when nothing is
    /// running (returns 0). Calling `cancelItem` per-item ensures worker
    /// `Task`s are cancelled AND the DB state is `.cancelled` in one
    /// atomic actor operation.
    @discardableResult
    public func cancelAllInFlight() async -> Int {
        var count = 0
        for queue in [QueueKind.extraction, QueueKind.ingestion] {
            let active: [QueueItem]
            do {
                active = try store.loadActive(for: queue)
            } catch {
                DebugLog.store("QueueEngine: failed to load active items for cancelAll: \(error)")
                continue
            }
            for item in active where item.state == .running {
                await cancelItem(item.id)
                count += 1
            }
        }
        if count > 0 {
            DebugLog.store("QueueEngine.cancelAllInFlight: cancelled \(count) running item(s) for quit")
        }
        return count
    }

    /// Cancel a specific queued or running item. Running items have their
    /// worker `Task` cancelled, then transition to `.cancelled` (preserving
    /// `orderingKey`).
    public func cancelItem(_ id: QueueItem.ID) async {
        // Cancel the worker task if running.
        if let dispatch = runningTasks.removeValue(forKey: id) {
            dispatch.task.cancel()
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
            DebugLog.store("QueueEngine.cancelItem: failed for \(id.rawValue): \(error)")
        }
        await dispatchScan()
    }

    /// Retry a failed item: `failed` → `queued`, `attempt + 1`, new
    /// `orderingKey` (back of queue). Triggers a dispatch scan.
    public func retryItem(_ id: QueueItem.ID) async throws {
        try requireRunning()
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
        let item: QueueItem
        do {
            guard let fetched = try store.getItem(id), fetched.state == .queued else { return }
            item = fetched
        } catch {
            DebugLog.store("QueueEngine.reorderItem: failed to fetch item \(id): \(error)")
            return
        }

        var key: Int64
        do {
            if let beforeID = beforeItemID,
               let beforeItem = try store.getItem(beforeID) {
                // Move before `beforeItem`: new key is between the predecessor
                // and `beforeItem`.
                let active = try store.loadActive(for: item.queue)
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
                    let maxKey = try store.maxOrderingKey(for: item.queue)
                    key = max(maxKey, beforeKey) + 1000
                }
            } else {
                // Move to end.
                let maxKey = try store.maxOrderingKey(for: item.queue)
                key = maxKey + 1000
            }
        } catch {
            DebugLog.store("QueueEngine.reorderItem: failed to calculate key: \(error)")
            return
        }

        do {
            _ = try store.updateOrderingKey(id: id, key: key)
            if let updated = try store.getItem(id) {
                emit(.reordered(updated))
            }
        } catch {
            DebugLog.store("QueueEngine.reorderItem: failed to persist reorder for \(id.rawValue): \(error)")
        }
    }

    // MARK: - Has active work

    /// Whether the engine has any queued or running items for the given wiki.
    /// Used by `RootScene.onDisappear` to decide whether to retain a session
    /// (if work is pending) or release it.
    public func hasActiveWork(for wikiID: WikiID) -> Bool {
        let active: [QueueItem]
        do {
            active = try store.loadActive()
        } catch {
            DebugLog.store("QueueEngine.hasActiveWork: failed to load active items: \(error)")
            active = []
        }
        return active.contains { $0.wikiID == wikiID }
    }

    // MARK: - Snapshot

    /// A point-in-time view of the engine's full state, for UI bootstrap and
    /// test assertions.
    public func snapshot() -> QueueSnapshot {
        let activeItems: [QueueItem]
        do {
            activeItems = try store.loadActive()
        } catch {
            DebugLog.store("QueueEngine.snapshot: failed to load active items: \(error)")
            activeItems = []
        }
        let recentItems: [QueueItem]
        do {
            recentItems = try store.loadRecent(limit: config.recentLimit)
        } catch {
            DebugLog.store("QueueEngine.snapshot: failed to load recent items: \(error)")
            recentItems = []
        }
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
        switch lifecycle {
        case .shuttingDown:
            return .failure(QueueEngineLifecycleError.shuttingDown)
        case .shutdownBlocked(let activeItemIDs):
            return .failure(QueueEngineLifecycleError.shutdownBlocked(activeItemIDs: activeItemIDs))
        case .shutDown:
            return .failure(QueueEngineLifecycleError.shutDown)
        case .created, .starting, .running:
            break
        }
        // Check if already terminal.
        do {
            if let item = try store.getItem(id) {
                if item.state == .completed {
                    return .success(())
                }
                if item.state == .failed {
                    return .failure(QueueExtractionError.notReady(item.error ?? "unknown"))
                }
                if item.state == .cancelled {
                    return .failure(CancellationError())
                }
            }
        } catch {
            DebugLog.store("QueueEngine.waitForCompletion: failed to fetch item \(id): \(error)")
        }

        // Register a waiter.
        return await withCheckedContinuation { c in
            completionWaiters[id, default: []].append(c)
        }
    }

    /// Load durable typed transcript items for a queue item.
    public func loadTranscript(for itemID: QueueItem.ID) async -> [ChatTranscriptItem] {
        let items: [ChatTranscriptItem]
        do {
            items = try store.loadTranscriptItems(itemID: itemID)
        } catch {
            DebugLog.store("QueueEngine.loadTranscript: failed to load items for \(itemID.rawValue): \(error)")
            items = []
        }
        return items
    }

    /// Delete persisted typed items for an item.
    public func clearTranscript(for itemID: QueueItem.ID) async {
        do {
            try store.deleteTranscriptItems(itemID: itemID)
        } catch {
            DebugLog.store("QueueEngine.clearTranscript: failed to delete items for \(itemID.rawValue): \(error)")
        }
    }

    /// Decoded per-item activity metadata for rehydration. The engine layer
    /// decodes the opaque `usageJSON` blob that `QueueStore` persists (the
    /// store lives in `WikiFSCore` and cannot reference `SessionUsage`).
    public struct ActivitySnapshot: Sendable {
        public let usage: SessionUsage?
        public let logURL: URL?
        public let debugURL: URL?
        public let progressLog: String

        public init(usage: SessionUsage?, logURL: URL?, debugURL: URL?, progressLog: String) {
            self.usage = usage
            self.logURL = logURL
            self.debugURL = debugURL
            self.progressLog = progressLog
        }
    }

    /// Codable XPC-boundary mirror of ``ActivitySnapshot``. The concrete
    /// snapshot is only `Sendable`; this wrapper adds `Codable` so snapshots
    /// can be JSON-encoded for transport over XPC.
    public struct ActivitySnapshotData: Codable, Sendable {
        public let usage: SessionUsage?
        public let logURL: URL?
        public let debugURL: URL?
        public let progressLog: String

        public init(from snapshot: ActivitySnapshot) {
            self.usage = snapshot.usage
            self.logURL = snapshot.logURL
            self.debugURL = snapshot.debugURL
            self.progressLog = snapshot.progressLog
        }
    }

    /// Load persisted activity metadata for all items with recorded activity,
    /// decoded into typed values. Used by the Activity tracker to rehydrate
    /// `itemUsage` / `itemLogURLs` / `itemDebugURLs` / `progressLogs` after an
    /// app restart so the Activity window shows completed/failed/cancelled runs
    /// (usage summary, "Reveal Log"/"Reveal Debug Folder", progress). Bounded
    /// by `pruneHistory` (rows cascade-delete with their item). A decode
    /// failure for one row leaves that field `nil` rather than aborting the
    /// whole rehydration.
    public func loadAllActivitySnapshots() async -> [QueueItem.ID: ActivitySnapshot] {
        let raw: [QueueItem.ID: QueueStore.QueueItemActivity]
        do {
            raw = try store.loadAllActivity()
        } catch {
            DebugLog.store("QueueEngine.loadAllActivitySnapshots: failed to load from store: \(error)")
            raw = [:]
        }
        var result: [QueueItem.ID: ActivitySnapshot] = [:]
        result.reserveCapacity(raw.count)
        for (id, activity) in raw {
            let usage: SessionUsage?
            if let json = activity.usageJSON,
               let data = json.data(using: .utf8) {
                do {
                    usage = try JSONDecoder().decode(SessionUsage.self, from: data)
                } catch {
                    DebugLog.store("QueueEngine.loadAllActivitySnapshots: usage decode failed for item=\(id): \(error)")
                    usage = nil
                }
            } else {
                usage = nil
            }
            result[id] = ActivitySnapshot(
                usage: usage,
                logURL: activity.logURL.flatMap { URL(string: $0) },
                debugURL: activity.debugURL.flatMap { URL(string: $0) },
                progressLog: activity.progressLog ?? "")
        }
        return result
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
        guard lifecycle == .running else { return }
        // For each queue kind that is `.running`, try to dispatch items.
        for queue in [QueueKind.extraction, QueueKind.ingestion] {
            guard runStates[queue] == .running else { continue }

            let active: [QueueItem]
            do {
                active = try store.loadActive(for: queue)
            } catch {
                DebugLog.store("QueueEngine.dispatchScan: failed to load active items for \(queue): \(error)")
                continue
            }
            for item in active where item.state == .queued {
                // The ONE await — resolve the provider up front.
                guard let providerID = await workerFactory.providerID(for: item) else {
                    continue  // No provider available; item stays queued.
                }
                guard lifecycle == .running else { return }

                // From here, NO await until the item is claimed and the
                // in-memory counts are updated. This keeps the check-and-claim
                // atomic within the actor's serialized execution — a reentrant
                // dispatchScan that runs during the await above sees the
                // pre-claim state; one that runs after this block sees the
                // post-claim state (counts updated, wiki inserted).
                let limit: Int
                switch item.queue {
                case .extraction, .transcription:
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
                    DebugLog.store("QueueEngine.dispatchScan: claim failed for \(item.id.rawValue): \(error)")
                    continue
                }

                // Read back the running item for the event (synchronous).
                let runningItem: QueueItem
                do {
                    guard let updated = try store.getItem(item.id) else { continue }
                    runningItem = updated
                } catch {
                    DebugLog.store("QueueEngine.dispatchScan: failed to load updated item \(item.id.rawValue): \(error)")
                    continue
                }

                // Update in-memory counts — immediately after the successful
                // claim, with no suspension in between.
                incrementProviderCount(providerID)
                if item.queue == .ingestion {
                    activeIngestionWikis.insert(item.wikiID)
                }

                // Emit the started event.
                emit(.started(runningItem))

                // Create the output capability before the task so the engine can
                // retain the exact dispatch identity across cancellation and retry.
                let attemptID = QueueAttemptID(
                    itemID: runningItem.id,
                    attempt: runningItem.attempt)
                let outputScope = outputChannel.makeScope(attemptID: attemptID)
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runWorker(runningItem, outputScope: outputScope)
                }
                runningTasks[item.id] = RunningDispatch(
                    leaseID: outputScope.leaseID,
                    task: task)
            }
        }
    }

    // MARK: - Worker execution

    /// Run a worker for `item`. Called in a detached `Task` so the engine
    /// is not blocked. On completion, transitions the item to `.completed`
    /// (success) or `.failed` (throw). On cancellation (from `halt` or
    /// `cancelItem`), the item is requeued (halt) or marked cancelled
    /// (cancel). After the worker finishes, triggers a dispatch scan.
    private func runWorker(
        _ item: QueueItem,
        outputScope: QueueWorkerOutputScope
    ) async {
        let worker: any QueueWorker
        do {
            worker = try await workerFactory.worker(for: item, output: outputScope)
        } catch {
            // Factory failed to produce a worker — revoke output, then fail.
            let outputDrain = outputChannel.invalidate(outputScope)
            for await _ in outputDrain {}
            await handleWorkerFinished(
                item,
                leaseID: outputScope.leaseID,
                result: .failure(error))
            outputChannel.finish(outputScope)
            return
        }

        // Execute the worker. Cancellation propagates via `Task.checkCancellation()`
        // inside the worker's `await` points.
        let result: Result<Void, Error>
        do {
            try await workerExecutor.execute(worker: worker, item: item)
            result = .success(())
        } catch is CancellationError {
            result = .failure(CancellationError())
        } catch {
            result = .failure(error)
        }

        let outputDrain = outputChannel.invalidate(outputScope)
        for await _ in outputDrain {}
        await handleWorkerFinished(
            item,
            leaseID: outputScope.leaseID,
            result: result)
        outputChannel.finish(outputScope)
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
    private func handleWorkerFinished(
        _ item: QueueItem,
        leaseID: WorkerLeaseID,
        result: Result<Void, Error>
    ) async {
        guard runningTasks[item.id]?.leaseID == leaseID else { return }
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
                DebugLog.store("QueueEngine: markCompleted failed for \(item.id.rawValue): \(error)")
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
                do {
                    if let updated = try store.getItem(item.id), updated.state == .running {
                        try store.requeue(id: item.id)
                        decrementProviderCount(for: item)
                        if item.queue == .ingestion {
                            activeIngestionWikis.remove(item.wikiID)
                        }
                        if let requeued = try store.getItem(item.id) {
                            emit(.cancelled(requeued))
                        }
                    }
                } catch {
                    DebugLog.store("QueueEngine.handleWorkerFinished: failed to handle cancellation for \(item.id.rawValue): \(error)")
                }
            } else {
                // #440: prefer `localizedDescription` (respects
                // `LocalizedError.errorDescription`) so the user sees a clean
                // message like "bun was not found on your PATH…" instead of the
                // raw `notReady("…")` enum case from `String(describing:)`.
                // Falls back to `String(describing:)` for non-Localized errors.
                let errorMsg = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
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
                    DebugLog.store("QueueEngine: markFailed failed for \(item.id.rawValue): \(error)")
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

        // Maintain the terminal history bound (default 200 per queue).
        do {
            try store.pruneHistory(maxPerQueue: config.recentLimit)
        } catch {
            DebugLog.store("QueueEngine.handleWorkerFinished: pruneHistory failed: \(error)")
        }
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
    private func incrementProviderCount(_ providerID: ProviderID) {
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
        let active: [QueueItem]
        do {
            active = try store.loadActive()
        } catch {
            DebugLog.store("QueueEngine.rebuildInMemoryState: failed to load active items: \(error)")
            return // Don't wipe state on transient read failure
        }

        providerActiveCounts.removeAll()
        activeIngestionWikis.removeAll()

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
        outputChannel.publish(event)
    }
}

// MARK: - Queue transcript callback state

/// Serializes synchronous provider callbacks per queue attempt. This class is
/// `@unchecked Sendable` only because every mutable member is protected by its
/// private lock, and no mutable reference escapes the critical section.
/// The synchronous callback-side state machine. It is `internal` so the
/// concurrency suite can exercise its lock/SQLite boundary directly; clients
/// enter it only through `QueueWorkerOutputChannel.emitTranscript`.
internal enum QueueTranscriptOwner: Hashable, Sendable {
    case legacy(QueueAttemptID)
    case scoped(QueueAttemptID, WorkerLeaseID)

    var attemptID: QueueAttemptID {
        switch self {
        case .legacy(let attemptID), .scoped(let attemptID, _): attemptID
        }
    }
}

// swiftlint:disable:next unchecked_sendable
final class QueueTranscriptStateStore: @unchecked Sendable {
    private struct AttemptState {
        var translator = AgentEventTranscriptTranslator()
        var items: [ChatTranscriptItem] = []
        var nextBatchNumber = 0
        var pending: [QueueTranscriptUpdate] = []
        var isDraining = false
        /// Terminal completion has started. Existing accepted batches may
        /// drain, but no callback may translate or enqueue another batch.
        var isClosing = false
    }

    private let lock = NSLock()
    private var currentOwnerByItem: [QueueItem.ID: QueueTranscriptOwner] = [:]
    private var states: [QueueTranscriptOwner: AttemptState] = [:]

    func begin(_ attemptID: QueueAttemptID) {
        begin(.legacy(attemptID))
    }

    func begin(_ owner: QueueTranscriptOwner) {
        lock.withLock {
            if let previousOwner = currentOwnerByItem[owner.attemptID.itemID],
               previousOwner != owner {
                states.removeValue(forKey: previousOwner)
            } else if currentOwnerByItem[owner.attemptID.itemID] == owner {
                return
            }
            currentOwnerByItem[owner.attemptID.itemID] = owner
            states[owner] = AttemptState()
        }
    }

    func invalidate(_ attemptID: QueueAttemptID) {
        invalidate(.legacy(attemptID))
    }

    func invalidate(_ owner: QueueTranscriptOwner) {
        lock.withLock {
            guard currentOwnerByItem[owner.attemptID.itemID] == owner else { return }
            currentOwnerByItem.removeValue(forKey: owner.attemptID.itemID)
            states.removeValue(forKey: owner)
        }
    }

    func invalidateAll() {
        lock.withLock {
            currentOwnerByItem.removeAll()
            states.removeAll()
        }
    }

    func finish(_ attemptID: QueueAttemptID) {
        finish(.legacy(attemptID))
    }

    func finish(_ owner: QueueTranscriptOwner) {
        lock.withLock {
            guard currentOwnerByItem[owner.attemptID.itemID] == owner,
                  var state = states[owner]
            else { return }
            state.isClosing = true
            guard state.pending.isEmpty, state.isDraining == false else {
                states[owner] = state
                return
            }
            currentOwnerByItem.removeValue(forKey: owner.attemptID.itemID)
            states.removeValue(forKey: owner)
        }
    }

    func accept(
        event: AgentEvent,
        for attemptID: QueueAttemptID,
        persist: @Sendable (QueueTranscriptUpdate) throws -> Void,
        broadcast: @Sendable (QueueTranscriptUpdate) -> Void
    ) {
        accept(
            event: event,
            for: .legacy(attemptID),
            persist: persist,
            broadcast: broadcast)
    }

    func accept(
        event: AgentEvent,
        for owner: QueueTranscriptOwner,
        persist: @Sendable (QueueTranscriptUpdate) throws -> Void,
        broadcast: @Sendable (QueueTranscriptUpdate) -> Void
    ) {
        let attemptID = owner.attemptID
        let shouldDrain = lock.withLock { () -> Bool in
            guard currentOwnerByItem[attemptID.itemID] == owner,
                  var state = states[owner],
                  state.isClosing == false
            else { return false }

            let previousItems = state.items
            let deltas = state.translator.translate([event], turnID: attemptID.chatTurnID)
            let reduced = ChatTranscriptReducer.reducing(items: previousItems, with: deltas)
            state.items = reduced

            var previousByIdentity: [QueueTranscriptItemIdentity: ChatTranscriptItem] = [:]
            for item in previousItems {
                previousByIdentity[QueueTranscriptItemIdentity(item)] = item
            }
            let changed = reduced.filter { previousByIdentity[QueueTranscriptItemIdentity($0)] != $0 }
            guard changed.isEmpty == false else {
                states[owner] = state
                return false
            }

            let update = QueueTranscriptUpdate(
                attemptID: attemptID,
                batchNumber: state.nextBatchNumber,
                changedItems: changed)
            state.nextBatchNumber += 1
            state.pending.append(update)
            let electDrainer = state.isDraining == false
            state.isDraining = true
            states[owner] = state
            return electDrainer
        }

        guard shouldDrain else { return }
        drain(owner: owner, persist: persist, broadcast: broadcast)
    }

    private func drain(
        owner: QueueTranscriptOwner,
        persist: @Sendable (QueueTranscriptUpdate) throws -> Void,
        broadcast: @Sendable (QueueTranscriptUpdate) -> Void
    ) {
        let attemptID = owner.attemptID
        while true {
            let next = lock.withLock { () -> QueueTranscriptUpdate? in
                guard currentOwnerByItem[attemptID.itemID] == owner,
                      var state = states[owner]
                else { return nil }
                guard state.pending.isEmpty == false else {
                    state.isDraining = false
                    if state.isClosing {
                        currentOwnerByItem.removeValue(forKey: attemptID.itemID)
                        states.removeValue(forKey: owner)
                    } else {
                        states[owner] = state
                    }
                    return nil
                }
                let update = state.pending.removeFirst()
                states[owner] = state
                return update
            }
            guard let next else { return }
            do {
                try persist(next)
                broadcast(next)
            } catch {
                DebugLog.store("QueueEngine: typed transcript persistence failed for \(attemptID.itemID.rawValue): \(error)")
            }
        }
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
public final class QueueEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<QueueEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<QueueEvent> {
        subscribe(onSubscribed: {})
    }

    /// Test seam that acknowledges registration after the continuation enters
    /// the multicast set. Production subscribers use ``subscribe()``.
    func subscribe(
        onSubscribed: @escaping @Sendable () -> Void
    ) -> AsyncStream<QueueEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
            onSubscribed()
        }
    }

    public func yield(_ event: QueueEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Signal stream termination to all subscribers. Subscribers' `for await`
    /// loops exit cleanly. Called when the owning object is deallocated.
    public func finish() {
        let targets = lock.withLock {
            let vals = Array(continuations.values)
            continuations.removeAll()
            return vals
        }
        for continuation in targets {
            continuation.finish()
        }
    }
}
