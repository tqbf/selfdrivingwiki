import Foundation

/// A shared, FIFO-serialized generation gate that enforces "at most one active
/// generation across any number of `AgentLauncher` instances."
///
/// "Active generation" means:
/// - A one-shot `claude -p` run (ingest / lint / query) holds the gate for the
///   entire run (spawn to finish).
/// - An interactive session (Ask / Edit) holds the gate only for the duration of
///   ONE TURN — from when the user's message is written to stdin until the agent
///   emits `messageStop` or `result`. The interactive process itself stays alive
///   between turns without holding the gate, so a second interactive session can
///   hold its own process simultaneously; only one GENERATES at a time.
///
/// This is a significant semantic shift from the old "spawn gate" model: holding
/// the gate does NOT mean "a process is alive" — it means "a process is actively
/// producing output." Use `AgentLauncher.isRunning` to test whether a process is
/// alive; use `AgentLauncher.isGenerating` to test whether a turn is in flight.
///
/// The API is intentionally minimal: `acquire()` / `release()` / `waiterCount`.
/// The same cancellation-safe `CheckedContinuation` + `withTaskCancellationHandler`
/// shape as the original per-instance slot is preserved — a cancelled waiter must
/// never be handed the slot.
@MainActor
final class GenerationGate {

    // MARK: - Waiter

    /// One queued generation request. A class so the cancellation handler can
    /// identify its waiter by reference and self-remove it from `waiters` — a
    /// cancelled waiter must never be handed the slot. `@unchecked Sendable`
    /// because it is only ever touched on the main actor (registration in
    /// `acquire`'s continuation; removal in the cancel handler's `@MainActor` hop).
    fileprivate final class GenerationWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var didReceiveSlot = false
        var didCancel = false
    }

    // MARK: - State

    /// Maximum number of concurrent generations. Default 1 (backward-
    /// compatible). When N > 1, up to N generations run simultaneously — a
    /// resource-management concern, not a correctness concern (workspaces
    /// handle correctness). W4 (PR #312).
    private let maxConcurrent: Int
    /// Number of callers currently holding a slot.
    private var activeCount = 0
    /// FIFO queue of callers awaiting the slot.
    private var waiters: [GenerationWaiter] = []

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: - Interface

    /// The number of waiters currently queued (test seam).
    var waiterCount: Int { waiters.count }

    /// Acquire the generation slot. Fast path: if the slot is free and nobody is
    /// queued, takes it immediately without suspending (zero overhead for the
    /// common single-run case). Otherwise enqueues a cancellation-safe waiter
    /// and suspends until the slot is handed over.
    ///
    /// Returns `true` if this caller acquired the slot. Returns `false` if the
    /// wait was cancelled before the slot was handed over — the caller owns
    /// nothing and must simply return (no `release()` call needed).
    func acquire() async -> Bool {
        // Fast path: below the concurrency cap and nobody is queued — acquire
        // atomically. There is no suspension point, so no other main-actor task
        // can interleave between the check and the set.
        if activeCount < maxConcurrent && waiters.isEmpty {
            activeCount += 1
            return true
        }
        let waiter = GenerationWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if waiter.didCancel {
                    // Cancelled before we could register — resume immediately,
                    // don't enqueue. The caller will see `didReceiveSlot == false`.
                    c.resume()
                    return
                }
                waiter.continuation = c
                waiters.append(waiter)
            }
        } onCancel: {
            // Hop to the main actor (the gate is @MainActor) to self-remove. A
            // cancelled waiter must not be handed the slot; if it already was
            // (race with `release`), do nothing — the woken caller will see
            // `Task.isCancelled` and bail, releasing the slot it was handed.
            Task { @MainActor [weak self] in
                guard let self else { return }
                waiter.didCancel = true
                if let idx = self.waiters.firstIndex(where: { $0 === waiter }),
                   let c = waiter.continuation {
                    self.waiters.remove(at: idx)
                    c.resume()
                }
            }
        }
        return waiter.didReceiveSlot
    }

    /// Release the generation slot, handing it to the next live waiter (FIFO) or
    /// freeing a capacity slot.
    ///
    /// Atomic transfer: on a handoff the waiter is resumed and the active
    /// count stays the same (one caller leaves, one arrives). Only when no
    /// live waiters remain does `activeCount` decrement. This is the N-throttle
    /// generalization of the original atomic-transfer guarantee (W4, PR #312).
    func release() {
        // Pop the next non-cancelled waiter and hand off the slot. On a
        // handoff, activeCount stays the same — one caller leaves, one arrives.
        while let head = waiters.first {
            waiters.removeFirst()
            if head.didCancel {
                // Already resumed by its cancel handler; don't hand the slot to
                // a dead task.
                continue
            }
            head.didReceiveSlot = true
            head.continuation?.resume()
            return
        }
        // No live waiters: decrement activeCount (free a capacity slot).
        activeCount -= 1
    }
}
