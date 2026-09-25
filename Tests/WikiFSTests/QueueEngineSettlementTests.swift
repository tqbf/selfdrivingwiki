import Foundation
import os
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// Settlement-owned bookkeeping tests: provider counts, the per-wiki
/// ingestion slot, and `waitForCompletion` waiters resolve exactly once per
/// dispatch, at settlement (`handleWorkerFinished`) — never on the
/// cancel/halt paths.
///
/// Reuses the fake worker infrastructure from `QueueEngineTests` — do not
/// duplicate those seams here.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct QueueEngineSettlementTests {

    // MARK: - Test helpers

    /// A fresh on-disk `queue.sqlite` URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-settlement-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    /// A trivial payload for tests that don't care about payload specifics.
    private func makePayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [SourceID(rawValue: "SETTLESRC01")])
    }

    // MARK: - Cancel-during-run settlement race (AC.4)

    @Test func cancelHoldsSlotUntilSettlementAndReleasesExactlyOnce() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let control = SettlementWorkerControl(honorsCancellation: true)
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in
                recorder.record(item.id)
                try await control.execute(item)
            })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 2]),
            workerFactory: factory)
        await engine.start()

        // Two items on provider p1, different wikis: both run (limit 2). The
        // second item is the counterweight that makes "exactly one decrement"
        // observable as 2 → 1 rather than a clamp to zero.
        let cancelledID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        let survivorID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w2"), payload: makePayload()))
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        // Register the waiter BEFORE the cancel so its resumption can only
        // come from settlement.
        let waiterTask = Task { await engine.waitForCompletion(of: cancelledID) }
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.cancelItem(cancelledID)
        // The worker observed the cancel but is parked before unwinding:
        // settlement has NOT run yet.
        await control.awaitCancellationObserved()

        // The slot is still held — settlement-owned capacity means the slot
        // is not freed by the cancel path itself. BOTH dispatches are
        // counted: the cancelled one has not settled.
        let preSettlement = await engine.snapshot()
        #expect(preSettlement.providerCounts[ProviderID(rawValue: "p1")] == 2)
        #expect(preSettlement.activeIngestionWikis == [WikiID(rawValue: "w1"), WikiID(rawValue: "w2")])
        let storeState = try #require(try store.getItem(cancelledID))
        #expect(storeState.state == .cancelled)

        // Let the worker settle. Capacity release and the waiter resume
        // happen now, exactly once.
        control.releaseFinish(cancelledID)
        let waiterResult = await waiterTask.value
        guard case .failure = waiterResult else {
            Issue.record("cancelled item's waiter should fail, got success")
            return
        }

        let postSettlement = await engine.snapshot()
        #expect(postSettlement.providerCounts[ProviderID(rawValue: "p1")] == 1)
        #expect(postSettlement.activeIngestionWikis == [WikiID(rawValue: "w2")])

        // Unwind the survivor cleanly (never cancelled: no finish park).
        control.releaseHold(survivorID)
        try await recorder.waitForCount(2, timeoutSeconds: 5)
        let survivorResult = await engine.waitForCompletion(of: survivorID)
        if case .failure(let error) = survivorResult {
            Issue.record("survivor should complete, got \(error)")
        }
        let final = await engine.snapshot()
        #expect(final.providerCounts.isEmpty)

        _ = await engine.shutdownForHandoff()
        store.close()
    }

    /// Regression: a `waitForCompletion` waiter registered on an item that is
    /// then cancelled by the user IS resumed (previously the cancel path
    /// removed the dispatch entry before settlement, so the lease guard
    /// skipped `resumeWaiters` and the waiter hung forever).
    @Test func waiterOnUserCancelledItemIsResumed() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let control = SettlementWorkerControl(honorsCancellation: true)
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in
                recorder.record(item.id)
                try await control.execute(item)
            })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        try await recorder.waitForCount(1, timeoutSeconds: 5)

        let waiterTask = Task { await engine.waitForCompletion(of: itemID) }
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.cancelItem(itemID)
        control.releaseFinish(itemID)
        let result = await waiterTask.value
        guard case .failure(let error) = result else {
            Issue.record("waiter should be resumed with a failure, got success")
            return
        }
        #expect(error is CancellationError)

        _ = await engine.shutdownForHandoff()
        store.close()
    }

    // MARK: - Halt settlement

    @Test func haltRequeuesItemAndSettlesAfterWorkerReturns() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let control = SettlementWorkerControl(honorsCancellation: true)
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in
                recorder.record(item.id)
                try await control.execute(item)
            })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        try await recorder.waitForCount(1, timeoutSeconds: 5)

        let waiterTask = Task { await engine.waitForCompletion(of: itemID) }
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.halt(.ingestion)

        // The item is back to `.queued` while the worker is still unwinding.
        let halted = try #require(try store.getItem(itemID))
        #expect(halted.state == .queued)

        // Settlement only after the worker returns: resume it.
        control.releaseFinish(itemID)
        let result = await waiterTask.value
        guard case .failure(let error) = result else {
            Issue.record("halted item's waiter should fail, got success")
            return
        }
        #expect(error is CancellationError)

        // The requeue stands — settlement must not clobber it to .running,
        // and the counts stay consistent (clamped, lane paused).
        let settled = try #require(try store.getItem(itemID))
        #expect(settled.state == .queued)
        let snapshot = await engine.snapshot()
        #expect(snapshot.providerCounts.isEmpty)
        #expect(snapshot.activeIngestionWikis.isEmpty)

        _ = await engine.shutdownForHandoff()
        store.close()
    }

    // MARK: - Double-settlement idempotency (AC.4)

    @Test func cancelThenWorkerFinishSettlesCountsExactlyOnce() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        // A worker that IGNORES cancellation and finishes normally — the
        // interleaving where the cancel transition won the store race but the
        // worker's success result arrives afterwards.
        let control = SettlementWorkerControl(honorsCancellation: false)
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in
                recorder.record(item.id)
                try await control.execute(item)
            })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        try await recorder.waitForCount(1, timeoutSeconds: 5)

        let waiterTask = Task { await engine.waitForCompletion(of: itemID) }
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.cancelItem(itemID)
        await control.awaitCancellationObserved()
        // Slot still held while the ignoring worker has not returned.
        let preSettlement = await engine.snapshot()
        #expect(preSettlement.providerCounts[ProviderID(rawValue: "p1")] == 1)

        control.releaseFinish(itemID)
        let result = await waiterTask.value
        // The store race was won by the cancel: waiters learn that terminal
        // truth, not the worker's success.
        guard case .failure(let error) = result else {
            Issue.record("waiter should see the cancelled terminal state, got success")
            return
        }
        #expect(error is CancellationError)

        // Counts moved exactly once (no double release at settlement), and
        // the cancel transition stands.
        let post = await engine.snapshot()
        #expect(post.providerCounts.isEmpty)
        #expect(post.activeIngestionWikis.isEmpty)
        let final = try #require(try store.getItem(itemID))
        #expect(final.state == .cancelled)

        _ = await engine.shutdownForHandoff()
        store.close()
    }
}

/// Worker control for settlement races: signals start, holds mid-execute on
/// a PER-ITEM gate, and — only when the worker's task is actually cancelled —
/// parks a second time on a per-item finish gate before unwinding. That
/// second park lets tests inspect and assert the pre-settlement state
/// deterministically. When `honorsCancellation` is false the worker ignores
/// cancellation and returns normally after release, producing the
/// cancel-then-finish interleaving.
///
/// Gates are per-item `AsyncStream`s: a shared stream is single-consumer, so
/// two workers iterating one stream would split values and terminate each
/// other's parks. The post-cancel park awaits an unstructured inner task via
/// `withTaskCancellationHandler` (the `UncooperativeWorkerControl` pattern):
/// a cancelled context's plain `for await` on an AsyncStream would return
/// immediately instead of waiting for the release.
private final class SettlementWorkerControl: @unchecked Sendable {
    private struct Gate {
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation
    }

    private struct State {
        var startedCount = 0
        var startedWaiters: [CheckedContinuation<Void, Never>] = []
        var holdGates: [QueueItem.ID: Gate] = [:]
        var finishGates: [QueueItem.ID: Gate] = [:]
        var cancelledItemIDs: Set<QueueItem.ID> = []
        var anyCancellationObserved = false
        var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let honorsCancellation: Bool

    init(honorsCancellation: Bool) {
        self.honorsCancellation = honorsCancellation
    }

    func execute(_ item: QueueItem) async throws {
        lock.withLock { state in
            state.startedCount += 1
            let waiters = state.startedWaiters
            state.startedWaiters.removeAll()
            for w in waiters { w.resume() }
        }

        // Materialize BOTH gates up front: a `releaseHold`/`releaseFinish`
        // that lands before the worker reaches the corresponding park must
        // still finish the right gate (a lazily created gate would miss the
        // release and park forever). Finishing an AsyncStream before its
        // iteration starts just ends the iteration immediately.
        let hold = holdGate(for: item.id)
        let finish = finishGate(for: item.id)

        // Hold mid-execute. Per-item stream; iteration honors task
        // cancellation, so a real cancel unwinds the worker from the hold.
        for await _ in hold.stream { break }

        // Signal cancellation observation (fires immediately when the task is
        // already cancelled; otherwise never).
        await withTaskCancellationHandler {
            // Empty body — the park below happens after the handler
            // registration returns, so `wasCancelled` is settled by then.
        } onCancel: {
            self.markCancellationObserved(item.id)
        }

        // Only a CANCELLED worker parks pre-settlement (and only such a
        // worker's test calls `releaseFinish`): the park lets the test
        // inspect pre-settlement state deterministically. The gate itself was
        // materialized at entry, so an early release cannot be missed.
        if wasCancelled(item.id) {
            await Task { for await _ in finish.stream { break } }.value
        }

        guard honorsCancellation else { return }
        try Task.checkCancellation()
    }

    /// Wait until at least one worker entered `execute`.
    func awaitStarted() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { state in
                if state.startedCount > 0 {
                    c.resume()
                } else {
                    state.startedWaiters.append(c)
                }
            }
        }
    }

    /// Open the hold gate for one item (unblocks a never-cancelled worker).
    func releaseHold(_ id: QueueItem.ID) {
        let gate = lock.withLock { state -> Gate? in
            state.holdGates.removeValue(forKey: id)
        }
        gate?.continuation.finish()
    }

    /// Wait until any worker's task observed cancellation.
    func awaitCancellationObserved() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { state in
                if state.anyCancellationObserved {
                    c.resume()
                } else {
                    state.cancellationWaiters.append(c)
                }
            }
        }
    }

    /// Open the finish gate for one item (lets a cancelled worker unwind and
    /// settle).
    func releaseFinish(_ id: QueueItem.ID) {
        let gate = lock.withLock { state -> Gate? in
            state.finishGates.removeValue(forKey: id)
        }
        gate?.continuation.finish()
    }

    // MARK: - Internals

    private func holdGate(for id: QueueItem.ID) -> Gate {
        lock.withLock { state -> Gate in
            if let gate = state.holdGates[id] { return gate }
            let pair = AsyncStream<Void>.makeStream()
            let gate = Gate(stream: pair.stream, continuation: pair.continuation)
            state.holdGates[id] = gate
            return gate
        }
    }

    private func finishGate(for id: QueueItem.ID) -> Gate {
        lock.withLock { state -> Gate in
            if let gate = state.finishGates[id] { return gate }
            let pair = AsyncStream<Void>.makeStream()
            let gate = Gate(stream: pair.stream, continuation: pair.continuation)
            state.finishGates[id] = gate
            return gate
        }
    }

    private func wasCancelled(_ id: QueueItem.ID) -> Bool {
        lock.withLock { $0.cancelledItemIDs.contains(id) }
    }

    private func markCancellationObserved(_ id: QueueItem.ID) {
        lock.withLock { state in
            state.cancelledItemIDs.insert(id)
            state.anyCancellationObserved = true
            let waiters = state.cancellationWaiters
            state.cancellationWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
