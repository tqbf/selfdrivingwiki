import Foundation

/// Cross-suite throttle for subprocess-heavy tests.
///
/// Swift Testing runs suites concurrently inside one test-target process;
/// `.serialized` only serializes tests *within* a suite. On the 3-vCPU CI
/// runners every suite that spawns or probes real processes was running
/// simultaneously, stacking process startup and inflating per-operation
/// timeouts until probes blew their bounds (#1412) and the process-global
/// `OwnedProcessGroupRegistry` count behind #1402 stopped holding.
///
/// Hold a slot around the spawn window of each subprocess-spawning test:
///
///     @Test func probesAFakeRuntime() async throws {
///         let subprocessGate = try await SubprocessGate.shared.acquire()
///         defer { subprocessGate.release() }
///         // spawn / probe real processes here
///     }
///
/// At most `SubprocessGate.defaultCapacity` gated tests run concurrently per
/// test process; further waiters keep FIFO order. Waiting parks only the
/// awaiting task (actor + continuation) and never blocks a cooperative-pool
/// thread — the #1051 rule. Cancellation (`.timeLimit`) fails the wait fast
/// with `CancellationError` instead of queueing behind a timeout. New
/// subprocess-spawning suites must adopt this pattern; see AGENTS.md and
/// #1412 for the failure family.
public actor SubprocessGate {

    /// Two concurrent subprocess-heavy suites leave one core of a 3-vCPU
    /// runner for everything else.
    public static let defaultCapacity = 2

    /// Process-wide gate. With `swift test --parallel --num-workers 1` (the
    /// `make test` shape) test targets run one process at a time, so one
    /// instance per process is exactly the cross-suite scope that is needed.
    public static let shared = SubprocessGate()

    private var availableSlots: Int
    private var waiters: [Waiter] = []

    public init(capacity: Int = SubprocessGate.defaultCapacity) {
        self.availableSlots = max(1, capacity)
    }

    /// Waits for and holds one gate slot. Throws `CancellationError` if the
    /// awaiting task is cancelled before a slot is granted. Call
    /// `Slot.release()` exactly once per successful acquire.
    public func acquire() async throws -> Slot {
        if availableSlots > 0 {
            availableSlots -= 1
            return Slot(gate: self)
        }
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Runs synchronously on the actor before suspension, so the
                // enqueue and the continuation installation are one atomic
                // step: a cancellation that races a grant can find the waiter
                // either queued (cancel wins, throws) or already dequeued
                // (grant wins, cancel becomes a no-op) — never both.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter.continuation = continuation
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter) }
        }
        return Slot(gate: self)
    }

    /// Hands a slot back, granting it straight to the oldest waiter if any.
    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation?.resume()
        } else {
            availableSlots += 1
        }
    }

    /// Cancels a queued waiter. A granted waiter is no longer in the queue,
    /// so the lookup misses and this is a no-op — exactly one resume.
    private func cancelWaiter(_ waiter: Waiter) {
        guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return }
        waiters.remove(at: index)
        waiter.continuation?.resume(throwing: CancellationError())
    }

    /// Queue entry; both fields are touched only while the actor is held.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, any Error>?
    }

    /// Proof that a gate slot is held; releasing hands it back.
    public struct Slot: Sendable {
        private let gate: SubprocessGate

        fileprivate init(gate: SubprocessGate) {
            self.gate = gate
        }

        /// Hands the slot back. Non-blocking: posts the handback to the gate
        /// actor as its own task; it never parks the calling thread. Call
        /// exactly once per acquired slot (the `defer` in the pattern above).
        public func release() {
            Task { await self.gate.release() }
        }
    }
}
