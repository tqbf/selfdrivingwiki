import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Pure unit tests for `TurnLivenessPolicy` — the turn ceiling watchdog
/// decision helper.
///
/// The idle/stall path was removed: ACP agents emit notifications for every
/// activity (thinking, tool calls, sub-agent lifecycle), so a live agent is
/// almost never truly idle. Only the hard ceiling remains.
///
/// No actor, no clock, no subprocess. Every test constructs explicit `Date`
/// values and asserts the decision.
@Suite struct TurnLivenessPolicyTests {

    // MARK: - Healthy

    @Test func healthyWhenPromptDone() {
        // Even if ceiling exceeded, promptDone wins.
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(9999)

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: true,
            turnStartedAt: start,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    @Test func healthyWithRecentActivity() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(60)     // 60s elapsed

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    // MARK: - Ceiling

    @Test func ceilingExceededAfterMaxDuration() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(1810)     // 1810s > 1800s ceiling

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800
        )
        #expect(decision == .ceilingExceeded(totalSeconds: 1810))
    }

    @Test func ceilingNotTriggeredWhileActive() {
        // Active agent under the ceiling — healthy.
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(1795)     // under 1800s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    // MARK: - Precedence

    @Test func promptDoneTakesPrecedenceOverCeiling() {
        // Even with ceiling exceeded, promptDone wins.
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(9999)

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: true,
            turnStartedAt: start,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }
}
