#if os(macOS)
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

    // MARK: - Per-context ceiling selection (#609)

    /// The queued-ingestion ceiling constant exists and is the value the issue
    /// prescribes (600s = 10 min). A pre-#609 installation had only
    /// `defaultCeilingTimeout` (1800s); a stall in `runACPIngestPlannerExecutors`
    /// burned 30 minutes per turn before the watchdog killed it (issue #609
    /// symptom on 2026-07-18: two ceiling kills = ~60 min lost).
    @Test func queuedIngestCeilingIs600Seconds() {
        #expect(TurnLivenessPolicy.queuedIngestCeiling == 600)
    }

    /// The interactive default stays at 1800s (30 min). The fix is split *who
    /// reads* the constant, NOT a change to the constant itself — interactive
    /// chat keeps the long chain backstop. Pinned so the split isn't lost.
    @Test func interactiveCeilingStays1800Seconds() {
        #expect(TurnLivenessPolicy.defaultCeilingTimeout == 1800)
    }

    /// `ceiling(for: .chat)` resolves to the 1800s interactive default — the
    /// value `startInteractiveQuery` MUST pass when constructing its backend.
    /// Long reasoning chains are legitimate in a user-attended chat, and the
    /// UI chip is the release valve.
    @Test func ceilingForChatIsInteractiveDefault() {
        #expect(TurnLivenessPolicy.ceiling(for: .chat) == TurnLivenessPolicy.defaultCeilingTimeout)
        #expect(TurnLivenessPolicy.ceiling(for: .chat) == 1800)
    }

    /// `ceiling(for: .ingest)` resolves to the 600s queued-ingestion ceiling.
    /// This is the value `runACPIngestPlannerExecutors` runs under — exactly the
    /// wiring #609 asserts: "ceiling used by `runACPIngestPlannerExecutors` is
    /// the queued-ingestion value (600s)". `runACPIngestPlannerExecutors`
    /// reuses the backend `run()` constructed (which selects the kind as
    /// `.ingest`), so this decision gates all planner/executor/finalizer phases.
    @Test func ceilingForIngestIsQueuedCeiling() {
        #expect(TurnLivenessPolicy.ceiling(for: .ingest) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.ceiling(for: .ingest) == 600)
    }

    /// `ceiling(for: .lint)` also uses the 600s ceiling — lint runs are the
    /// other unattended pipeline kind. Same rationale as `.ingest`: nobody is
    /// watching, the UI chip doesn't apply, so a stall must not burn 30 minutes.
    @Test func ceilingForLintIsQueuedCeiling() {
        #expect(TurnLivenessPolicy.ceiling(for: .lint) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.ceiling(for: .lint) == 600)
    }

    /// Regression guard: queued-ingestion and interactive ceilings MUST differ.
    /// If a future refactor merges them (deliberately or by typo), the whole
    /// point of #609 is silently lost — assert the contract directly.
    @Test func queuedCeilingIsLowerThanInteractive() {
        #expect(TurnLivenessPolicy.queuedIngestCeiling < TurnLivenessPolicy.defaultCeilingTimeout)
    }
}
#endif
