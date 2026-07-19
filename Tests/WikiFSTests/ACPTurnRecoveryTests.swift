import Testing
import Foundation
import ACPModel
import WikiFSCore
@testable import WikiFSEngine

/// #615 — ACPBackend turn-completion recovery regression suite.
///
/// Issue #615 repro: when the `claude-agent-acp` subprocess exits / closes the
/// transport AFTER streaming a complete response but BEFORE the
/// `session/prompt` `result` arrives, the SDK's `sendPrompt` neither returns nor
/// throws — so `promptTask` hung forever, the launcher's
/// `for await event in stream` blocked, `setGenerating(false)` never fired, no
/// `turn-N-response.json` was written (the bug was invisible in `debug/`), and
/// the run was abandoned (no `summary.json`). The fix introduces
/// `TurnRecoveryGrace`, armed ONLY inside the per-turn drain task's
/// post-`for-await` exit path gated by `!Task.isCancelled` (so a normal >3s
/// streaming turn never arms the timer — the CRITICAL wiring guard). See
/// `plans/615-turn-completion-hang.md`.
///
/// **Test infrastructure gap (documented in §7 of the plan):** the SDK `Client`
/// is a concrete `public actor`, NOT a protocol — so there is no fake `Client`
/// to drive the real `ACPBackend.send` with a never-returning `sendPrompt` +
/// finished fanout. These Tier 1 tests exercise the **pure seam**
/// (`TurnRecoveryGrace` + the `RecoveryTimerRef` holder + `ACPBackendError` +
/// `ACPBackend.turnEndEvents`) directly. The integration of the seam into
/// `send` (the fanout-finish-detection wiring, the `Task.isCancelled`
/// disambiguation, the `recoveryRef.cancel()` placement) is validated manually
/// (§7c in the plan: MV-1 normal >3s turn + MV-2 #615 repro + MV-3 stopAgent).
/// Flagged as Risks R1/R2 in the plan.
@Suite struct ACPTurnRecoveryTests {

    // MARK: - Test (a): grace timeout fires → recovery path

    /// The #615 failure case — `sendPrompt` never returns and no other path
    /// marks the turn done. `TurnRecoveryGrace.arm()` sleeps the grace timeout,
    /// then (because no winner ran) synthesizes the recovery: `markDone` +
    /// `markDied` + log + yield `turnEndEvents(.processDiedBeforeResult)` +
    /// `continuation.finish()`. Asserts the recovery actually fires (the
    /// consumer's `for-await` exits because `finish()` ran) + the events +
    /// health/flag state are correct.
    @Test func drainEndGraceTimeoutFiresRecovery() async throws {
        // Given: a TurnRecoveryGrace with completionFlag fresh, a real
        // AsyncStream.Continuation, and a short drainGraceTimeout.
        let flag = TurnCompletionFlag()
        let health = ProcessHealthFlag()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentEvent.self, bufferingPolicy: .unbounded)
        // Consumer returns the collected events to avoid a Swift 6 data-race
        // warning on capturing a `var seen` across task boundaries.
        let consumer = Task<[AgentEvent], Never> {
            var events: [AgentEvent] = []
            for await e in stream { events.append(e) }
            return events
        }

        // When: arm recovery; do NOT mark done from any other path (simulates
        // sendPrompt never returning — the #615 failure case).
        let recovery = TurnRecoveryGrace(
            completionFlag: flag,
            continuation: continuation,
            processHealth: health,
            drainGraceTimeout: .milliseconds(150),
            debugLogger: nil,
            debugTurn: nil)
        await recovery.arm()    // sleeps 150ms, then recovers (no one beat it)

        // Then: stream finished (consumer's for-await exited) + recovery events.
        // `await consumer.value` would hang indefinitely if `continuation.finish()`
        // never ran — so it IS the assertion that the recovery finished the stream.
        let seen = await consumer.value
        #expect(seen.count == 2)   // [.turnFailed(.agentError(msg)), .messageStop]
        #expect(seen.last == .messageStop)
        #expect(seen.contains { AgentEvent.endsGeneration($0) })
        if case .turnFailed(let reason) = seen.first {
            if case .agentError(let msg) = reason {
                #expect(msg.contains("connection dropped") || msg.contains("answer was shown"))
            } else {
                Issue.record("expected .agentError reason inside .turnFailed, got \(reason)")
            }
        } else {
            Issue.record("expected .turnFailed as the first event, got \(String(describing: seen.first))")
        }
        #expect(health.died == true)   // markDied() ran
        #expect(flag.isDone == true)    // markDone() ran
    }

    // MARK: - Test (a2): recovery writes `turn-N-response.json` error variant

    /// When debug logging is enabled, the recovery path must write the error
    /// variant of `turn-N-response.json` (so the bug is visible in `debug/`,
    /// not invisible — the original #615 symptom). Mirrors the catch path's
    /// `logPromptError` call (ACPBackend.swift's catch branch at the
    /// `debugLogger?.logPromptError(error, turn: debugTurn)` line).
    @Test func recoveryWritesErrorResponseJson() async throws {
        // Point a real DebugRunLogger at a temp dir; arm recovery with a
        // debugTurn; assert the error variant turn-N-response.json exists +
        // contains the error message.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = try #require(DebugRunLogger(folderURL: tmp))
        let turnIdx = logger.nextTurn()
        let flag = TurnCompletionFlag()
        let health = ProcessHealthFlag()
        let (_, cont) = AsyncStream.makeStream(of: AgentEvent.self)
        let recovery = TurnRecoveryGrace(
            completionFlag: flag,
            continuation: cont,
            processHealth: health,
            drainGraceTimeout: .milliseconds(100),
            debugLogger: logger,
            debugTurn: turnIdx)
        await recovery.arm()

        // The file lives at `<folderURL>/turns/turn-<n>-response.json`.
        let resp = tmp
            .appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent("turn-\(turnIdx)-response.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: resp.path))
        let body = try String(contentsOf: resp, encoding: .utf8)
        #expect(body.contains("error"))
    }

    // MARK: - Test (b): legitimate completion wins → grace timer no-op'd

    /// The race-safety regression guard. When `sendPrompt` returns successfully
    /// BEFORE the grace timer fires, the success path's `completionFlag.markDone()
    /// + recoveryRef.cancel()` wins. The grace timer's `Task.sleep` is
    /// cancelled (CancellationError) → `arm()` returns early WITHOUT reaching
    /// `markDone`/`markDied`. Asserts:
    /// - exactly the success events (`.messageStop`), NO spurious `.turnFailed`.
    /// - `health.died == false` (the timer no-op'd — `markDied` did NOT run).
    /// - `flag.isDone == true` (success is the only winner).
    ///
    /// **Test-tier limitation (per plan §7 Test b doc comment + R4):** this
    /// asserts the grace timer did not reach `markDone()`/`markDied()`
    /// (observable via `health.died == false` + `seen` cleanliness). It does
    /// NOT assert `continuation.finish()` was called exactly once —
    /// `AsyncStream.Continuation` tolerates a double `finish()` (unlike
    /// `CheckedContinuation`), so a double-finish wouldn't crash and can't be
    /// directly observed at this tier. The `completionFlag` guard makes a
    /// double-finish structurally impossible (only the first `markDone()`
    /// winner proceeds to finish), but that invariant is enforced by code
    /// review of `plans/615-turn-completion-hang.md` §3, not by this test.
    @Test func promptSuccessBeatsGraceTimeout() async throws {
        let flag = TurnCompletionFlag()
        let health = ProcessHealthFlag()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentEvent.self, bufferingPolicy: .unbounded)
        // Consumer returns the collected events to avoid a Swift 6 data-race
        // warning on capturing a `var seen` across task boundaries.
        let consumer = Task<[AgentEvent], Never> {
            var events: [AgentEvent] = []
            for await e in stream { events.append(e) }
            return events
        }

        // Arm the timer (long budget) via the holder, but BEFORE it fires,
        // the success path wins: markDone + cancel the timer. Mirrors the
        // success path's `completionFlag.markDone()` + `recoveryRef.cancel()`.
        let ref = RecoveryTimerRef()
        let recovery = TurnRecoveryGrace(
            completionFlag: flag,
            continuation: continuation,
            processHealth: health,
            drainGraceTimeout: .milliseconds(500),
            debugLogger: nil,
            debugTurn: nil)
        let t = Task { await recovery.arm() }
        ref.set(t)
        try await Task.sleep(nanoseconds: 50_000_000)  // let it register the sleep

        // Simulate sendPrompt returning successfully FIRST:
        flag.markDone()                                 // success wins
        ref.cancel()                                    // explicit cancel at win site
        for e in ACPBackend.turnEndEvents(error: nil) { continuation.yield(e) }
        continuation.finish()                           // mirror the real success path

        // Wait PAST the 500ms budget so the timer would have fired + done its
        // guard had the cancel not won the race.
        try await Task.sleep(nanoseconds: 600_000_000)
        _ = await t.value   // safety: ensure the cancelled timer task fully exited

        // Then: exactly the success events (.messageStop), NO spurious .turnFailed.
        let seen = await consumer.value
        #expect(seen == [.messageStop])
        #expect(health.died == false)    // markDied() did NOT run — recovery no-op'd
        #expect(flag.isDone == true)     // success is the (only) winner
    }

    // MARK: - Test (c): recovery events include `.messageStop` (contract pin)

    /// Contract pin: the recovery events MUST include `.messageStop` so the
    /// downstream launcher's `AgentEvent.endsGeneration(_:)` branch fires →
    /// `setGenerating(false)` (AgentLauncher.swift, inside the `endsGeneration`
    /// branch). Without `.messageStop`, ChatView stays stuck "generating" —
    /// the second half of the #615 symptom. This is a contract pin (the
    /// `turnEndEvents` synthesis), NOT a behavioral test that
    /// `setGenerating(false)` fires in `AgentLauncher` — that is launcher-tier
    /// behavior with no engine-tier harness; see plan §7c manual validation
    /// (MV-1/MV-2) + R3.
    @Test func recoveryEventsEndGeneration() {
        let events = ACPBackend.turnEndEvents(error: ACPBackendError.processDiedBeforeResult)
        #expect(events.contains { AgentEvent.endsGeneration($0) })
        #expect(events.last == .messageStop)
    }

    // MARK: - Test (d): `ACPBackendError.processDiedBeforeResult` message

    /// The new error case must surface a user-visible, actionable message
    /// (distinct from `.processDied`, which blames subprocess death + resume).
    /// Wording per the issue: "Claude finished but the connection dropped
    /// before the result arrived — your answer was shown; you can send the
    /// next message."
    @Test func processDiedBeforeResultMessageIsActionable() {
        let msg = ACPBackendError.processDiedBeforeResult.localizedDescription
        #expect(msg.contains("answer was shown") || msg.contains("send the next message"))
        // Distinct from .processDied (which blames subprocess death + resume).
        let diedMsg = ACPBackendError.processDied.errorDescription ?? ""
        #expect(msg != diedMsg)
    }

    // MARK: - Test (e): normal path does NOT yield `.processDiedBeforeResult`

    /// Minimum normal-path regression guard at the engine tier. Asserts the
    /// event synthesis for a normal (non-hung) turn yields NO
    /// `.processDiedBeforeResult` events — exactly `[.messageStop]`. This
    /// guards the event-contract layer.
    ///
    /// **What this guards (and what it can't):** it asserts the *event
    /// synthesis* for a successful turn is clean. It does NOT exercise the
    /// real `send` path (no fake `Client`) — i.e. it CANNOT catch the
    /// CRITICAL wiring bug where the timer is armed at turn start (which would
    /// kill every >3s turn with a spurious `.processDiedBeforeResult`). The
    /// arm-only-on-fanout-finish wiring is validated manually (plan §7c MV-1).
    @Test func normalTurnEndDoesNotProduceProcessDiedBeforeResult() {
        let events = ACPBackend.turnEndEvents(error: nil)
        #expect(events == [.messageStop])
        #expect(!events.contains { event in
            if case .turnFailed(let reason) = event {
                if case .agentError(let msg) = reason {
                    return msg.contains("connection dropped") || msg.contains("before the result")
                }
                return false
            }
            return false
        })
    }
}
