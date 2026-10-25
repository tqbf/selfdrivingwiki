#if os(macOS)
import Dispatch
import Foundation
import Testing
@testable import wikid

/// The lint-eval host's main-frame wait (``LintEvalDriverHost/runAndWait``).
///
/// The host must wait for its detached task WITHOUT starving the main
/// actor: the host path hops to the main actor along its boot path (the
/// profile boot's service resolution, store-model and launcher
/// construction), and those hops only run while the waiting frame drains
/// the main run loop. The original `DispatchSemaphore` wait blocked the
/// main thread without draining it — the first hop never ran, the socket
/// handlers never settled, and every 2026-10-25 gate trial starved its
/// client deadline ("socket recv exceeded its deadline").
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// gate runs on the main thread from a detached task (never a cooperative
/// thread) and every wait races a timeout.
@Suite("LintEvalDriverHostWait", .serialized, .timeLimit(.minutes(2)))
struct LintEvalDriverHostWaitTests {

    /// The run-loop gate services a main-actor hop submitted while it holds
    /// the main thread — the exact shape the semaphore wait deadlocked.
    /// With a semaphore-shaped regression the hop never runs, the settle
    /// never fires, and the gate's budget expires: a fast diagnosed
    /// failure instead of a hang.
    @Test func gateServicesMainActorHopFromTheDetachedHostTask() async throws {
        // Lock-backed flags (written by the detached task and by the
        // main-actor hop, read by this frame).
        // swiftlint:disable:next unchecked_sendable
        final class Flags: @unchecked Sendable {
            private let lock = NSLock()
            private var _hopRan = false
            private var _settled = false
            var hopRan: Bool { lock.withLock { _hopRan } }
            var settled: Bool { lock.withLock { _settled } }
            func ranHop() { lock.withLock { _hopRan = true } }
            func settle() { lock.withLock { _settled = true } }
        }
        let flags = Flags()

        // The host-task shape: off-main work whose completion needs ONE
        // main-actor hop (what the profile boot's service resolution does).
        let hostTask = Task.detached(priority: .userInitiated) {
            await MainActor.run { flags.ranHop() }
            flags.settle()
        }
        defer { hostTask.cancel() }

        // The gate runs ON the main thread, as the host's main frame does:
        // dispatched onto the main queue from a detached task, raced
        // against the group's outer timeout.
        let serviced = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<Bool, Error>) in
                    DispatchQueue.main.async {
                        let ok = LintEvalDriverHost.drainCurrentRunLoopUntil(
                            { flags.settled }, budget: 10)
                        cont.resume(returning: ok)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                return false
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        // Deliberately NOT awaiting `hostTask` here: on a regressed
        // (semaphore-shaped) gate it never settles, and the flags below
        // already name the failure.
        #expect(serviced, "the gate never observed the settle — the main-actor hop was starved")
        #expect(flags.hopRan, "the main-actor hop never ran while the gate held the main thread")
        #expect(flags.settled)
    }

    /// The gate's budget converts a starved wait into a `false` return, not
    /// an infinite drain (the tests' fail-safe; the host passes nil).
    @Test func gateBudgetExpiresInsteadOfHanging() {
        let expired = LintEvalDriverHost.drainCurrentRunLoopUntil(
            { false }, tick: 0.05, budget: 0.3)
        #expect(!expired)
    }
}
#endif
