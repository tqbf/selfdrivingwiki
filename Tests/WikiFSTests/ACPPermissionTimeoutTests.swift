#if os(macOS)
import Testing
import Foundation
import ACPModel
@testable import WikiFSEngine

/// #606 regression suite: a deferred permission request (alwaysAsk, or
/// acceptEdits on a non-edit tool) must auto-reject after the configured
/// `budget` elapses WITHOUT a user resolution — instead of suspending
/// indefinitely on `withCheckedContinuation` until the 1800s ceiling kills
/// the turn. Mirrors the existing `ACPBackendTests` always-ask family's
/// harness (suspend on a `Task` + await with a short timeout).
///
/// The race-safety invariant (exactly one `resume` per `CheckedContinuation`)
/// is the load-bearing correctness property — covered by tests #2, #3, #6
/// (`plans/acp-permissions.md` §4.1 note #1, §8.2).
///
/// `.serialized` AND `.timeLimit(.minutes(5))` (issue #664): this suite uses
/// real `Task`s, `Task.sleep`, and `CheckedContinuation` to exercise
/// race-safety timing windows. `.serialized` removes intra-suite concurrency
/// so its carefully-tuned `budget` windows don't slip when multiple tests
/// in the suite compete for the cooperative thread pool; `.timeLimit` is the
/// per-test safety net against a hung continuation. Historically this suite
/// was the identified cause of a 6-hour CI hang when run in parallel with the
/// heavy SQLite integration suites — see #664 / #448 (`QueueEngineTests`
/// shares the same flakiness shape).
@Suite(
    .timeLimit(.minutes(5)),
    .serialized
)
struct ACPPermissionTimeoutTests {

    /// A two-option request the always-ask path defers (matches the existing
    /// `ACPBackendTests.alwaysAskDefersUntilResolved` shape).
    private func makeRequest(toolCallId: String, title: String = "Write file") -> RequestPermissionRequest {
        RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_always", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: toolCallId, title: title, kind: .edit)
        )
    }

    /// #1 — #606 repro-becomes-test: a deferred permission request that is
    /// never resolved returns `cancelled` within `budget + ε`. The 1800s
    /// ceiling backstop is no longer the only release.
    @Test func deferPermissionAutoRejectsAfterBudget() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk, budget: .milliseconds(200))
        let request = makeRequest(toolCallId: "tc-timeout")

        let response = try await delegate.handlePermissionRequest(request: request)

        // The agent treats `cancelled` as denied and adapts — same as a denied
        // tool. This is the #606 auto-reject outcome.
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        // Pending map is empty after the timeout drain (removeValue under the lock).
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// #2 — A user resolution that lands BEFORE the budget elapses wins the
    /// race. The timer is cancelled by `resolve`; the response is the ALLOW
    /// outcome, not `cancelled`.
    @Test func deferPermissionUserResolveBeatsBudget() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk, budget: .milliseconds(500))
        let request = makeRequest(toolCallId: "tc-race-user")

        let requestTask = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: request)
        }

        // Give the suspended continuation + armed timer a moment to register,
        // then resolve ALLOW BEFORE the 500ms budget elapses.
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(delegate.pendingSnapshot().count == 1)
        let resolved = delegate.resolve(optionId: "opt-allow")
        #expect(resolved == true)

        let response = try await requestTask.value
        #expect(response.outcome.outcome == "selected")
        #expect(response.outcome.optionId == "opt-allow")
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// #3 — Continuation-safety regression guard: after the user resolves
    /// first AND the timer would have fired (waited past the budget), no
    /// second resume / no crash. This is the §4.1 note #1 invariant.
    @Test func deferPermissionUserResolveThenBudgetDoesNotDoubleFire() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk, budget: .milliseconds(150))
        let request = makeRequest(toolCallId: "tc-no-double")

        let requestTask = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: request)
        }

        // Resolve BEFORE the 150ms budget elapses, then sleep WELL past it so
        // the timer task wakes + tries to fire. If the single-resume invariant
        // is correct, the timer task's `timeOut` finds the entry gone and no-ops.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.resolve(optionId: "opt-allow") == true)
        let response = try await requestTask.value
        #expect(response.outcome.optionId == "opt-allow")

        // Wait past the budget + a generous margin so the detached timer task
        // has had time to wake + execute its `timeOut` (which must no-op).
        try await Task.sleep(nanoseconds: 400_000_000)

        // Still empty — no double-resume, no trap. The fact that this test
        // doesn't crash the process IS the assertion.
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// #4 — Interactive chat path: `budget: nil` = unbounded. Preserves the
    /// prior behavior so the UI chip stays the release valve. Verifies the
    /// request suspends (does NOT auto-reject) for an appreciable window.
    @Test func budgetNilMeansUnboundedInteractiveBehaviorPreserved() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk, budget: nil)
        let request = makeRequest(toolCallId: "tc-unbounded")

        let requestTask = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: request)
        }

        // Give a "budget" long enough that a 200ms-equivalent budget (test #1)
        // would have fired by now. With nil budget, no timer is armed → the
        // request must still be pending (the only release is an explicit resolve
        // or cancelAllPending).
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(delegate.pendingSnapshot().count == 1)
        #expect(requestTask.isCancelled == false)

        // Clean up so the suspended continuation doesn't leak (a leaked
        // CheckedContinuation warns/traps at task end).
        _ = delegate.cancelAllPending()
        _ = await requestTask.result
    }

    /// #5 — `acceptEdits` on a non-edit tool defers (the second deferring
    /// callsite). A short budget auto-rejects it the same way `alwaysAsk` does.
    @Test func acceptEditsNonEditToolAlsoAutoRejects() async throws {
        let delegate = ACPPermissionDelegate(policy: .acceptEdits, budget: .milliseconds(150))
        // `.execute` (Bash) is NOT an edit tool per `isEditTool` — it defers.
        let request = RequestPermissionRequest(
            options: [
                PermissionOption(kind: "allow_always", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject"),
            ],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc-ae-timeout", title: "Run bash command", kind: .execute)
        )

        let response = try await delegate.handlePermissionRequest(request: request)

        #expect(response.outcome.outcome == "cancelled")
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// #6 — After one request times out, `cancelAllPending()` drains the
    /// SURVIVOR without double-resuming the already-timed-out entry. The race
    /// between `timeOut` and `cancelAllPending` is safe.
    @Test func cancelAllPendingStillDrainsAfterTimeout() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk, budget: .milliseconds(150))

        // Request #1 — will time out.
        let r1 = makeRequest(toolCallId: "tc-timeout-1")
        let t1 = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: r1)
        }
        // Request #2 — still pending when #1 times out; the survivor.
        let r2 = makeRequest(toolCallId: "tc-survivor")
        let t2 = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: r2)
        }

        // Wait long enough for #1's budget to elapse (auto-reject) but not #2's.
        // The 150ms budget is shared (both pass the same delegate budget), so
        // they will time out within nanoseconds of each other. To exercise the
        // race deterministically, resolve #2 via cancelAllPending IMMEDIATELY
        // after #1 times out — before #2's timer would have fired.
        let r1Response = try await t1.value
        #expect(r1Response.outcome.outcome == "cancelled")

        // At this moment #2 may either still be pending (its timer hasn't fired
        // yet) OR already auto-rejected (its timer fired in the same window).
        // Either way, `cancelAllPending` must drain without double-resuming #1
        // (drained count is 0 for empty / 1 for one survivor — never 2).
        let drained = delegate.cancelAllPending()
        #expect(drained <= 1)
        // Drain #2's task — either the auto-reject OR the cancelAllPending resume
        // surfaced there; either way the continuation was resumed exactly once.
        _ = await t2.result
        #expect(delegate.pendingSnapshot().isEmpty)
    }
}
#endif // os(macOS)
