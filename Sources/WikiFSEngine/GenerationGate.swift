import Foundation

/// A lane-aware generation gate that serializes generation by **lane**: ingest
/// runs serialize among themselves, while interactive (chat/query) turns run on a
/// separate, higher-capacity lane. This prevents a long ingest from blocking
/// chat responsiveness, while still serializing concurrent ingest runs.
///
/// "Active generation" means:
/// - A one-shot agent run (ingest / lint) holds the **ingest** lane for
///   the entire run (spawn to finish).
/// - An interactive session (Ask / Edit / query) holds the **interactive** lane
///   only for the duration of ONE TURN — from when the user's message is
///   written to stdin until the agent emits `messageStop` or `result`. The
///   interactive process itself stays alive between turns without holding the
///   lane, so a second interactive session can hold its own process
///   simultaneously; only one GENERATES at a time (per lane).
///
/// The API mirrors the original single-FIFO gate: `acquire(_:)` /
/// `release(_:)` / `waiterCount`. The same cancellation-safe
/// `CheckedContinuation` + `withTaskCancellationHandler` shape is preserved —
/// a cancelled waiter must never be handed the slot.
///
/// Phase 2 (`#multi-writer-hardening`): converted from single-FIFO to
/// per-lane queues, preserving the exact cancellation-safety invariants.
@MainActor
public final class GenerationGate {

    // MARK: - Lane

    /// Which lane a generation runs on. Ingest-class runs (ingest, lint,
    /// lintPage) serialize on `.ingest`; query/chat turns run on
    /// `.interactive`. Lane limits are constructor-configurable.
    public enum GenerationLane: Hashable, Sendable {
        case ingest
        case interactive
    }

    // MARK: - Waiter

    /// One queued generation request. A class so the cancellation handler can
    /// identify its waiter by reference and self-remove it from its lane's
    /// `waiters` — a cancelled waiter must never be handed the slot.
    /// `@unchecked Sendable` because it is only ever touched on the main actor
    /// (registration in `acquire`'s continuation; removal in the cancel
    /// handler's `@MainActor` hop).
    fileprivate final class GenerationWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var didReceiveSlot = false
        var didCancel = false
    }

    // MARK: - State

    /// Per-lane throttling state. Each lane has its own limit, active count,
    /// and FIFO waiter queue — lanes are fully independent (acquiring one
    /// never blocks the other).
    private struct LaneState {
        var limit: Int
        var activeCount = 0
        var waiters: [GenerationWaiter] = []
    }

    private var lanes: [GenerationLane: LaneState]

    /// Convenience constructor for a single-lane gate (backwards-compatible
    /// with tests that don't need lane separation). Uses one lane with the
    /// given limit; callers must specify which lane via `acquire(_:)`.
    public init(laneLimits: [GenerationLane: Int]) {
        var l: [GenerationLane: LaneState] = [:]
        for (lane, limit) in laneLimits {
            l[lane] = LaneState(limit: max(1, limit))
        }
        self.lanes = l
    }

    /// Single-lane convenience (for simpler tests). Uses the given limit for
    /// the `.interactive` lane — production code uses the dictionary init.
    public convenience init(maxConcurrent: Int = 1) {
        self.init(laneLimits: [.interactive: maxConcurrent])
    }

    // MARK: - Interface

    /// The number of waiters currently queued across ALL lanes (test seam).
    var waiterCount: Int {
        lanes.values.reduce(0) { $0 + $1.waiters.count }
    }

    /// The number of waiters queued on a specific lane (test seam).
    func waiterCount(for lane: GenerationLane) -> Int {
        lanes[lane]?.waiters.count ?? 0
    }

    /// The active (in-flight) count for a specific lane (test seam).
    func activeCount(for lane: GenerationLane) -> Int {
        lanes[lane]?.activeCount ?? 0
    }

    /// Acquire a slot on the given lane. Fast path: if the lane is below its
    /// concurrency cap and nobody is queued, takes it immediately without
    /// suspending (zero overhead for the common single-run case). Otherwise
    /// enqueues a cancellation-safe waiter on that lane and suspends until a
    /// slot is handed over.
    ///
    /// Returns `true` if this caller acquired the slot. Returns `false` if the
    /// wait was cancelled before the slot was handed over — the caller owns
    /// nothing and must simply return (no `release(_:)` call needed).
    func acquire(_ lane: GenerationLane) async -> Bool {
        // Ensure the lane exists (defensive — the init seeds it).
        if lanes[lane] == nil {
            lanes[lane] = LaneState(limit: 1)
        }
        let state = lanes[lane]!

        // Fast path: below the concurrency cap and nobody is queued — acquire
        // atomically. There is no suspension point, so no other main-actor task
        // can interleave between the check and the set.
        if state.activeCount < state.limit && state.waiters.isEmpty {
            lanes[lane]!.activeCount += 1
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
                lanes[lane]!.waiters.append(waiter)
            }
        } onCancel: {
            // Hop to the main actor (the gate is @MainActor) to self-remove. A
            // cancelled waiter must not be handed the slot; if it already was
            // (race with `release`), do nothing — the woken caller will see
            // `Task.isCancelled` and bail, releasing the slot it was handed.
            Task { @MainActor [weak self] in
                guard let self else { return }
                waiter.didCancel = true
                if var state = self.lanes[lane],
                   let idx = state.waiters.firstIndex(where: { $0 === waiter }),
                   let c = waiter.continuation {
                    state.waiters.remove(at: idx)
                    self.lanes[lane] = state
                    c.resume()
                }
            }
        }
        return waiter.didReceiveSlot
    }

    /// Release a slot on the given lane, handing it to the next live waiter
    /// (FIFO) or freeing a capacity slot.
    ///
    /// Atomic transfer: on a handoff the waiter is resumed and the active
    /// count stays the same (one caller leaves, one arrives). Only when no
    /// live waiters remain does `activeCount` decrement.
    func release(_ lane: GenerationLane) {
        guard var state = lanes[lane] else { return }

        // Pop the next non-cancelled waiter and hand off the slot. On a
        // handoff, activeCount stays the same — one caller leaves, one arrives.
        while let head = state.waiters.first {
            state.waiters.removeFirst()
            if head.didCancel {
                // Already resumed by its cancel handler; don't hand the slot to
                // a dead task.
                continue
            }
            head.didReceiveSlot = true
            head.continuation?.resume()
            lanes[lane] = state
            return
        }
        // No live waiters: decrement activeCount (free a capacity slot).
        state.activeCount -= 1
        lanes[lane] = state
    }
}
