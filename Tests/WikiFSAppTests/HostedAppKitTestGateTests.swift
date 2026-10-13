#if os(macOS)
import Testing
@testable import WikiFS

/// Contract tests for the hosted-test gate's bounded, cancellation-aware
/// acquire (see `AutocompleteHostedTestGate.swift` for the rationale). The
/// former bare `withCheckedContinuation` wait could leak a queued waiter when
/// a suite `.timeLimit` cancelled its task; these tests pin the replacement:
/// grant, queued grant, timeout, and cancellation all leave the gate usable
/// with no lost slot and no suspended continuation.
///
/// Every await here is bounded by construction: each path (grant, timeout,
/// cancel) resumes its continuation exactly once, which is what these tests
/// prove. The suite is serialized and time-limited like every window-hosting
/// suite.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct HostedAppKitTestGateTests {

    @Test func grantsImmediatelyWhenUncontended() async throws {
        let gate = HostedAppKitTestGate()
        let lease = try await gate.acquire(timeout: .seconds(2))
        lease.release()
    }

    @Test func handsTheLeaseToAQueuedWaiterAfterRelease() async throws {
        let gate = HostedAppKitTestGate()
        let first = try await gate.acquire(timeout: .seconds(2))

        let second = Task { try await gate.acquire(timeout: .seconds(5)) }
        // Give the waiter a bounded moment to enqueue behind the holder.
        try await Task.sleep(for: .milliseconds(100))

        first.release()
        // The queued waiter is granted deterministically by release().
        let secondLease = try await second.value
        secondLease.release()
    }

    @Test func contendedAcquireTimesOutAndGateStaysUsable() async throws {
        let gate = HostedAppKitTestGate()
        let holder = try await gate.acquire(timeout: .seconds(2))

        do {
            _ = try await gate.acquire(timeout: .milliseconds(150))
            Issue.record("contended acquire must time out, not grant")
        } catch is HostedAppKitTestGate.GateTimeoutError {
            // Expected: the deadline resumes the waiter with a typed error.
        }
        // The gate must stay usable — the timed-out waiter took no slot.
        holder.release()
        let next = try await gate.acquire(timeout: .seconds(2))
        next.release()
    }

    @Test func cancelledWaiterIsRemovedAndGateStaysUsable() async throws {
        let gate = HostedAppKitTestGate()
        let holder = try await gate.acquire(timeout: .seconds(2))

        let waiter = Task { try await gate.acquire(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()

        do {
            _ = try await waiter.value
            Issue.record("cancelled waiter must throw, not grant")
        } catch is CancellationError {
            // Expected: cancellation resumes the waiter, no leaked continuation.
        }
        // The cancelled waiter took no slot: release hands the gate back to
        // the free state (not to the dead waiter).
        holder.release()
        let next = try await gate.acquire(timeout: .seconds(2))
        next.release()
    }

    @Test func alreadyCancelledTaskThrowsImmediately() async throws {
        let gate = HostedAppKitTestGate()
        let holder = try await gate.acquire(timeout: .seconds(2))

        let waiter = Task { () throws -> HostedAppKitTestGate.Lease in
            try Task.checkCancellation()
            return try await gate.acquire(timeout: .seconds(5))
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            Issue.record("pre-cancelled waiter must throw, not grant")
        } catch is CancellationError {
            // Expected.
        }
        holder.release()
    }
}
#endif
