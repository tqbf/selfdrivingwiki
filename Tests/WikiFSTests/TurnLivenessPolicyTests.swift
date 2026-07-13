import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Pure unit tests for `TurnLivenessPolicy` — the turn inactivity watchdog
/// decision helper (`plans/acp-stall-recovery.md` §1a).
///
/// No actor, no clock, no subprocess. Every test constructs explicit `Date`
/// values and asserts the decision.
@Suite struct TurnLivenessPolicyTests {

    // MARK: - Healthy

    @Test func healthyWhenPromptDone() {
        // Even if idle and ceiling exceeded, promptDone wins.
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(9999)

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: true,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    @Test func healthyWithRecentActivity() {
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 50) // active 50s ago
        let now = start.addingTimeInterval(60)     // 60s elapsed, idle 10s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    // MARK: - Stalled

    @Test func stalledAfterIdleTimeout() {
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 30)  // last activity at 30s
        let now = start.addingTimeInterval(200)       // 200s total, idle 170s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .stalled(idleSeconds: 170))
    }

    @Test func stalledWhenNeverActiveAndThresholdPassed() {
        // lastActivityAt == turnStartedAt (no notifications yet).
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(130) // 130s with zero activity

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: start,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .stalled(idleSeconds: 130))
    }

    @Test func stalledReportsExactIdleSeconds() {
        let start = Date(timeIntervalSince1970: 1000)
        let last = Date(timeIntervalSince1970: 1050)
        let now = Date(timeIntervalSince1970: 1200) // idle = 150s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        if case .stalled(let idle) = decision {
            #expect(idle == 150)
        } else {
            Issue.record("expected .stalled, got \(decision)")
        }
    }

    // MARK: - Ceiling

    @Test func ceilingExceededAfterMaxDuration() {
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 1790) // still active recently
        let now = start.addingTimeInterval(1810)     // 1810s > 1800s ceiling

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .ceilingExceeded(totalSeconds: 1810))
    }

    @Test func ceilingNotTriggeredWhileActive() {
        // Active agent under the ceiling — healthy.
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 1790) // very recent
        let now = start.addingTimeInterval(1795)     // under 1800s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    // MARK: - Precedence

    @Test func ceilingTakesPrecedenceOverIdle() {
        // Both idle AND ceiling exceeded — ceiling wins.
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 0) // never active
        let now = start.addingTimeInterval(2000)  // 2000s total

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .ceilingExceeded(totalSeconds: 2000))
    }

    @Test func promptDoneTakesPrecedenceOverAll() {
        // Even with ceiling exceeded AND idle, promptDone wins.
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(9999)

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: true,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }

    // MARK: - Boundary

    @Test func stalledAtExactlyIdleTimeout() {
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(120) // exactly at threshold

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .stalled(idleSeconds: 120))
    }

    @Test func healthyJustBelowIdleTimeout() {
        let start = Date(timeIntervalSince1970: 0)
        let last = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(119.9) // just under threshold

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            lastActivityAt: last,
            idleTimeout: 120,
            ceilingTimeout: 1800
        )
        #expect(decision == .healthy)
    }
}
