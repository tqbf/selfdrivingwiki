import Foundation
import Synchronization
import WikiFSCore

internal struct QueueWorkerOutputDrainSnapshot: Sendable {
    let streams: [AsyncStream<Void>]
    let itemIDs: Set<QueueItem.ID>
}

private final class QueueWorkerLeaseRegistry: Sendable {
    private struct LeaseState: Sendable {
        var acceptsNewScopes = true
        var active: [QueueItem.ID: WorkerLeaseID] = [:]
        var itemByLease: [WorkerLeaseID: QueueItem.ID] = [:]
        var inFlight: [WorkerLeaseID: Int] = [:]
        var drainWaiters: [WorkerLeaseID: [AsyncStream<Void>.Continuation]] = [:]
    }

    struct Admission: Sendable {
        let leaseID: WorkerLeaseID
        private let finishAction: @Sendable () -> Void

        fileprivate init(leaseID: WorkerLeaseID, finish: @escaping @Sendable () -> Void) {
            self.leaseID = leaseID
            self.finishAction = finish
        }

        func finish() { finishAction() }
    }

    private let state = Mutex(LeaseState())

    func activate(attemptID: QueueAttemptID, leaseID: WorkerLeaseID) -> Bool {
        state.withLock { state in
            guard state.acceptsNewScopes else { return false }
            if let previousLease = state.active[attemptID.itemID],
               previousLease != leaseID,
               state.inFlight[previousLease, default: 0] == 0 {
                state.itemByLease.removeValue(forKey: previousLease)
            }
            state.active[attemptID.itemID] = leaseID
            state.itemByLease[leaseID] = attemptID.itemID
            return true
        }
    }

    func admit(_ scope: QueueWorkerOutputScope) -> Admission? {
        let accepted = state.withLock { state -> Bool in
            guard state.active[scope.attemptID.itemID] == scope.leaseID else { return false }
            state.inFlight[scope.leaseID, default: 0] += 1
            return true
        }
        guard accepted else { return nil }
        return Admission(leaseID: scope.leaseID) { [self] in finish(scope.leaseID) }
    }

    func invalidate(_ scope: QueueWorkerOutputScope) -> AsyncStream<Void> {
        let stream = AsyncStream<Void>.makeStream()
        let finishNow = state.withLock { state -> Bool in
            guard state.active[scope.attemptID.itemID] == scope.leaseID else { return true }
            state.active.removeValue(forKey: scope.attemptID.itemID)
            guard state.inFlight[scope.leaseID, default: 0] > 0 else {
                state.itemByLease.removeValue(forKey: scope.leaseID)
                return true
            }
            state.drainWaiters[scope.leaseID, default: []].append(stream.continuation)
            return false
        }
        if finishNow { stream.continuation.finish() }
        return stream.stream
    }

    func closeAndInvalidateAll() -> QueueWorkerOutputDrainSnapshot {
        var finishNow: [AsyncStream<Void>.Continuation] = []
        let snapshot = state.withLock { state -> QueueWorkerOutputDrainSnapshot in
            state.acceptsNewScopes = false
            let activeLeases = Set(state.active.values)
            let inFlightLeases = Set(state.inFlight.keys)
            let leasesToDrain = activeLeases.union(inFlightLeases)
            let itemIDs = Set(leasesToDrain.compactMap { state.itemByLease[$0] })
            state.active.removeAll()
            let streams = leasesToDrain.map { leaseID in
                let pair = AsyncStream<Void>.makeStream()
                if state.inFlight[leaseID, default: 0] > 0 {
                    state.drainWaiters[leaseID, default: []].append(pair.continuation)
                } else {
                    state.itemByLease.removeValue(forKey: leaseID)
                    finishNow.append(pair.continuation)
                }
                return pair.stream
            }
            return QueueWorkerOutputDrainSnapshot(streams: streams, itemIDs: itemIDs)
        }
        for continuation in finishNow { continuation.finish() }
        return snapshot
    }

    private func finish(_ leaseID: WorkerLeaseID) {
        let waiters = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            let count = state.inFlight[leaseID, default: 0]
            if count > 1 {
                state.inFlight[leaseID] = count - 1
                return []
            }
            state.inFlight.removeValue(forKey: leaseID)
            state.itemByLease.removeValue(forKey: leaseID)
            return state.drainWaiters.removeValue(forKey: leaseID) ?? []
        }
        for waiter in waiters { waiter.finish() }
    }
}

/// A ready-at-construction worker output boundary shared by factories and the
/// queue engine. Each output preserves its established publication contract.
public struct QueueWorkerOutputChannel: Sendable {
    private let broadcaster: QueueEventBroadcaster
    private let transcriptState: QueueTranscriptStateStore
    private let leases = QueueWorkerLeaseRegistry()
    private let appendProgress: @Sendable (QueueItem.ID, String) throws -> Void
    private let persistTranscript: @Sendable (QueueTranscriptUpdate) throws -> Void
    private let persistUsage: @Sendable (QueueItem.ID, String?) throws -> Void
    private let persistRunPaths: @Sendable (QueueItem.ID, String?, String?) throws -> Void
    /// Internal observation runs after multicast publication and before the
    /// output-specific persistence step. Production uses a no-op observer.
    private let observePublication: @Sendable (QueueEvent) -> Void

    public init(
        store: QueueStore,
        broadcaster: QueueEventBroadcaster = QueueEventBroadcaster()
    ) {
        self.init(
            broadcaster: broadcaster,
            transcriptState: QueueTranscriptStateStore(),
            appendProgress: { id, line in
                try store.appendItemProgress(itemID: id, line: line)
            },
            persistTranscript: { update in
                try store.upsertTranscriptItems(
                    attemptID: update.attemptID,
                    items: update.changedItems)
            },
            persistUsage: { id, json in
                try store.upsertItemActivity(
                    itemID: id,
                    usageJSON: json,
                    logURL: nil,
                    debugURL: nil)
            },
            persistRunPaths: { id, logURL, debugURL in
                try store.upsertItemActivity(
                    itemID: id,
                    usageJSON: nil,
                    logURL: logURL,
                    debugURL: debugURL)
            },
            observePublication: { _ in })
    }

    internal init(
        broadcaster: QueueEventBroadcaster = QueueEventBroadcaster(),
        transcriptState: QueueTranscriptStateStore = QueueTranscriptStateStore(),
        appendProgress: @escaping @Sendable (QueueItem.ID, String) throws -> Void,
        persistTranscript: @escaping @Sendable (QueueTranscriptUpdate) throws -> Void,
        persistUsage: @escaping @Sendable (QueueItem.ID, String?) throws -> Void,
        persistRunPaths: @escaping @Sendable (QueueItem.ID, String?, String?) throws -> Void,
        observePublication: @escaping @Sendable (QueueEvent) -> Void = { _ in }
    ) {
        self.broadcaster = broadcaster
        self.transcriptState = transcriptState
        self.appendProgress = appendProgress
        self.persistTranscript = persistTranscript
        self.persistUsage = persistUsage
        self.persistRunPaths = persistRunPaths
        self.observePublication = observePublication
    }

    /// A fresh non-replaying event subscription.
    public var events: AsyncStream<QueueEvent> {
        broadcaster.subscribe()
    }

    public func events(
        onSubscribed: @escaping @Sendable () -> Void
    ) -> AsyncStream<QueueEvent> {
        broadcaster.subscribe(onSubscribed: onSubscribed)
    }

    /// Publish a scheduler-owned event through the same multicast boundary.
    internal func publish(_ event: QueueEvent) {
        broadcaster.yield(event)
        observePublication(event)
    }

    /// Create and activate a per-dispatch output capability.
    public func makeScope(attemptID: QueueAttemptID) -> QueueWorkerOutputScope {
        let scope = QueueWorkerOutputScope(attemptID: attemptID, leaseID: WorkerLeaseID(), channel: self)
        if leases.activate(attemptID: attemptID, leaseID: scope.leaseID) {
            transcriptState.begin(.scoped(attemptID, scope.leaseID))
        }
        return scope
    }

    /// Register the currently active transcript attempt before legacy output.
    public func beginTranscript(_ attemptID: QueueAttemptID) {
        transcriptState.begin(.legacy(attemptID))
    }

    /// Reject later output for one exact worker dispatch. A stale dispatch cannot
    /// invalidate the replacement dispatch for the same durable queue item.
    public func invalidate(_ scope: QueueWorkerOutputScope) -> AsyncStream<Void> {
        let drain = leases.invalidate(scope)
        transcriptState.invalidate(.scoped(scope.attemptID, scope.leaseID))
        return drain
    }

    /// Reject all current worker capabilities before shutdown/cancellation.
    internal func closeScopeAdmission() -> QueueWorkerOutputDrainSnapshot {
        let snapshot = leases.closeAndInvalidateAll()
        transcriptState.invalidateAll()
        return snapshot
    }

    public func invalidateAllScopes() -> [AsyncStream<Void>] {
        closeScopeAdmission().streams
    }

    /// Close one transcript attempt after all accepted batches drain.
    public func finishTranscript(_ attemptID: QueueAttemptID) {
        transcriptState.finish(.legacy(attemptID))
    }

    public func finish(_ scope: QueueWorkerOutputScope) {
        transcriptState.finish(.scoped(scope.attemptID, scope.leaseID))
    }

    /// Progress publishes before persistence. Persistence failure does not
    /// retract the event.
    public func emitProgress(itemID: QueueItem.ID, line: String) {
        publish(.progress(itemID, line: line))
        do {
            try appendProgress(itemID, line)
        } catch {
            DebugLog.store("Queue output: persist progress failed for item=\(itemID): \(error)")
        }
    }

    /// Lease-scoped progress. Stale workers cannot publish or persist.
    public func emitProgress(itemID: QueueItem.ID, line: String, scope: QueueWorkerOutputScope) {
        guard scope.attemptID.itemID == itemID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        emitProgress(itemID: itemID, line: line)
    }

    /// Transcript reduction is serialized per attempt. Each changed batch is
    /// persisted before it is published.
    public func emitTranscript(attemptID: QueueAttemptID, event: AgentEvent) {
        transcriptState.accept(
            event: event,
            for: .legacy(attemptID),
            persist: persistTranscript,
            broadcast: { update in
                publish(.transcript(update))
            })
    }

    /// Lease-scoped transcript output. The lease is checked before translation.
    public func emitTranscript(attemptID: QueueAttemptID, event: AgentEvent, scope: QueueWorkerOutputScope) {
        guard scope.attemptID == attemptID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        transcriptState.accept(
            event: event,
            for: .scoped(attemptID, scope.leaseID),
            persist: persistTranscript,
            broadcast: { update in
                publish(.transcript(update))
            })
    }

    /// Final usage publishes before persistence. Encoding or persistence
    /// failure does not retract the event.
    public func emitUsage(itemID: QueueItem.ID, usage: SessionUsage) {
        publish(.usage(itemID, usage))
        do {
            let data = try JSONEncoder().encode(usage)
            try persistUsage(itemID, String(data: data, encoding: .utf8))
        } catch {
            DebugLog.store("Queue output: persist usage failed for item=\(itemID): \(error)")
        }
    }

    public func emitUsage(itemID: QueueItem.ID, usage: SessionUsage, scope: QueueWorkerOutputScope) {
        guard scope.attemptID.itemID == itemID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        emitUsage(itemID: itemID, usage: usage)
    }

    /// Live usage is runtime-only.
    public func emitLiveUsage(itemID: QueueItem.ID, usage: SessionUsage) {
        publish(.liveUsage(itemID, usage))
    }

    public func emitLiveUsage(itemID: QueueItem.ID, usage: SessionUsage, scope: QueueWorkerOutputScope) {
        guard scope.attemptID.itemID == itemID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        emitLiveUsage(itemID: itemID, usage: usage)
    }

    /// Run paths publish before persistence. Persistence failure does not
    /// retract the event.
    public func emitRunPaths(itemID: QueueItem.ID, logURL: URL?, debugURL: URL?) {
        publish(.runPaths(itemID, logURL: logURL, debugURL: debugURL))
        do {
            try persistRunPaths(itemID, logURL?.absoluteString, debugURL?.absoluteString)
        } catch {
            DebugLog.store("Queue output: persist run paths failed for item=\(itemID): \(error)")
        }
    }

    public func emitRunPaths(itemID: QueueItem.ID, logURL: URL?, debugURL: URL?, scope: QueueWorkerOutputScope) {
        guard scope.attemptID.itemID == itemID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        emitRunPaths(itemID: itemID, logURL: logURL, debugURL: debugURL)
    }

    /// Pending permission is runtime-only.
    public func emitPendingPermission(itemID: QueueItem.ID, permission: PendingPermission?) {
        publish(.pendingPermission(itemID, permission))
    }

    public func emitPendingPermission(itemID: QueueItem.ID, permission: PendingPermission?, scope: QueueWorkerOutputScope) {
        guard scope.attemptID.itemID == itemID, let admission = leases.admit(scope) else { return }
        defer { admission.finish() }
        emitPendingPermission(itemID: itemID, permission: permission)
    }

    /// Finish every event subscription. Repeated calls are safe.
    public func finish() {
        broadcaster.finish()
    }
}
