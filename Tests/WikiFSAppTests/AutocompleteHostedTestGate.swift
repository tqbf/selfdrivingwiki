#if os(macOS)
import Foundation

/// Shared lifecycle harness for tests that mount live AppKit or WebKit views
/// inside the single `swift test` host process. These suites are correct in
/// production under user-driven interaction, but the CLI host's single
/// AppKit/WebKit environment can wedge when multiple window-owning suites
/// overlap under Swift Testing's default suite-level parallelism.
///
/// Keep this gate in `Tests/` so the serialization policy is explicit test
/// infrastructure rather than production behavior.
///
/// ## Bounded, cancellation-aware acquisition
///
/// `acquire(timeout:)` replaces the former bare `withCheckedContinuation`
/// wait. A suite `.timeLimit` cancels the test task but cannot resume an
/// abandoned continuation, so the old design could leak a queued waiter and
/// wedge the gate for the rest of the process. Now:
///
/// - a waiter whose task is cancelled is removed from the queue and resumed
///   by throwing `CancellationError` — no abandoned continuation stays
///   queued, and no resumed-but-dead task takes the lease slot;
/// - a waiter that waits past `timeout` is resumed by throwing
///   ``GateTimeoutError`` — a starved or wedged holder produces a fast,
///   diagnosed failure instead of an infinite hang;
/// - resume is exactly-once per waiter (the waiter leaves the queue before
///   its continuation is resumed, and `cancelledIDs` covers the window where
///   cancellation lands between id creation and enqueue).
actor HostedAppKitTestGate {
    static let shared = HostedAppKitTestGate()

    /// Thrown when a contended acquire waits past its deadline.
    struct GateTimeoutError: Error, CustomStringConvertible {
        var description: String { "HostedAppKitTestGate acquire timed out" }
    }

    private var held = false
    private var waiters: [Waiter] = []
    /// Ids whose cancellation arrived before the waiter was enqueued (or
    /// after it was granted and removed). The pre-enqueue case must resume
    /// the continuation immediately on enqueue; the post-grant case just
    /// leaves a stale id, which is harmless (one UUID, test-only lifetime).
    private var cancelledIDs: Set<UUID> = []

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Acquire the gate, waiting at most `timeout` when contended.
    ///
    /// Throws `CancellationError` when the awaiting task is cancelled, and
    /// ``GateTimeoutError`` when the deadline passes before a lease is
    /// granted. Every caller migrates to this bounded API; there is no
    /// unbounded entry point.
    func acquire(timeout: Duration = .seconds(30)) async throws -> Lease {
        if !held {
            held = true
            return Lease { [weak self] in
                await self?.release()
            }
        }
        let id = UUID()
        // Deadline watchdog: an actor-independent task that fires once. A
        // granted or cancelled waiter makes this task a no-op (its id is no
        // longer queued), and the deferred cancel reaps it immediately.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeoutWaiter(id: id)
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Runs synchronously in actor context before suspension.
                    enqueueWaiter(id: id, continuation: continuation)
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelWaiter(id: id)
                }
            }
            // Granted: the release() handoff already set `held` for us.
            return Lease { [weak self] in
                await self?.release()
            }
        } catch {
            throw error
        }
    }

    /// Enqueue a waiter — or resume it immediately with `CancellationError`
    /// when its cancellation landed before the enqueue (an already-cancelled
    /// task fires `onCancel` before the continuation body runs).
    private func enqueueWaiter(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if cancelledIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
    }

    /// Remove and resume-throw a queued waiter. Exactly-once: the waiter
    /// leaves the queue before its continuation is touched.
    private func removeWaiter(id: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Not queued (yet or anymore). Record pre-enqueue cancellations
            // so the enqueue resumes them instead of parking forever.
            cancelledIDs.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: error)
    }

    private func timeoutWaiter(id: UUID) {
        removeWaiter(id: id, error: GateTimeoutError())
    }

    private func cancelWaiter(id: UUID) {
        removeWaiter(id: id, error: CancellationError())
    }

    /// Hand the lease to the next waiter, or free the gate.
    private func release() {
        if waiters.isEmpty {
            held = false
            return
        }
        let waiter = waiters.removeFirst()
        // Stays held — ownership transfers to the granted waiter.
        held = true
        waiter.continuation.resume()
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var isReleased = false
        private let onRelease: @Sendable () async -> Void

        init(onRelease: @escaping @Sendable () async -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            lock.lock()
            guard !isReleased else {
                lock.unlock()
                return
            }
            isReleased = true
            lock.unlock()
            Task.detached { [onRelease = self.onRelease] in
                await onRelease()
            }
        }

        deinit {
            release()
        }
    }
}

typealias AutocompleteHostedTestGate = HostedAppKitTestGate
#endif
