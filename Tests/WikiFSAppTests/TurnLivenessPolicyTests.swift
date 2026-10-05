#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Pure unit tests for `TurnLivenessPolicy` — the turn watchdog decision
/// helper.
///
/// The INTERACTIVE idle/stall path was removed: ACP agents emit notifications
/// for every activity, so a live agent is almost never truly idle. #1364
/// restored an idle bound for the QUEUED lanes only (ingest/lint): an
/// unattended phase silent for 5 minutes is dead or wedged.
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

    // MARK: - Idle stall (queued lanes, #1364)

    /// Idle under the timeout with idle monitoring enabled → healthy.
    @Test func healthyWhileUnderIdleTimeout() {
        let start = Date(timeIntervalSince1970: 0)
        let lastActivity = start.addingTimeInterval(50)   // activity mid-turn
        let now = lastActivity.addingTimeInterval(299)    // 299s idle < 300s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: 300,
            lastActivityAt: lastActivity
        )
        #expect(decision == .healthy)
    }

    /// Idle over the timeout → idleStallExceeded, carrying the observed idle
    /// seconds (verified value, not just the case).
    @Test func idleStallExceededAfterSilence() {
        let start = Date(timeIntervalSince1970: 0)
        let lastActivity = start.addingTimeInterval(10)
        let now = lastActivity.addingTimeInterval(301)    // 301s idle > 300s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: 300,
            lastActivityAt: lastActivity
        )
        #expect(decision == .idleStallExceeded(idleSeconds: 301))
    }

    /// `idleTimeout: nil` (interactive chat) NEVER returns the idle case —
    /// even after hours of silence. Long silent reasoning is legitimate when
    /// a user is attending.
    @Test func nilIdleTimeoutDisablesIdleStall() {
        let start = Date(timeIntervalSince1970: 0)
        let lastActivity = start.addingTimeInterval(5)
        let now = lastActivity.addingTimeInterval(999_999)   // effectively forever

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: nil,
            lastActivityAt: lastActivity
        )
        // The ceiling still fires (it remains the interactive backstop) — but
        // only through the ceiling path, never the idle path.
        #expect(decision == .ceilingExceeded(totalSeconds: now.timeIntervalSince(start)))
    }

    /// promptDone wins over an idle stall — the turn is over; the watchdog
    /// must stop.
    @Test func promptDoneTakesPrecedenceOverIdleStall() {
        let start = Date(timeIntervalSince1970: 0)
        let lastActivity = start.addingTimeInterval(5)
        let now = lastActivity.addingTimeInterval(500)   // 500s idle > 300s

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: true,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: 300,
            lastActivityAt: lastActivity
        )
        #expect(decision == .healthy)
    }

    /// The ceiling wins over an idle stall when both are exceeded — the
    /// total-duration bound is the stronger statement about the turn.
    @Test func ceilingTakesPrecedenceOverIdleStall() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(1810)          // ceiling exceeded
        let lastActivity = start.addingTimeInterval(1800) // only 10s idle

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: 300,
            lastActivityAt: lastActivity
        )
        #expect(decision == .ceilingExceeded(totalSeconds: 1810))
    }

    /// Idle and ceiling both exceeded → the ceiling is reported (precedence).
    @Test func bothExceededReportsCeiling() {
        let start = Date(timeIntervalSince1970: 0)
        let lastActivity = start                          // silent whole turn
        let now = start.addingTimeInterval(2000)          // idle AND ceiling

        let decision = TurnLivenessPolicy.evaluate(
            now: now,
            promptDone: false,
            turnStartedAt: start,
            ceilingTimeout: 1800,
            idleTimeout: 300,
            lastActivityAt: lastActivity
        )
        #expect(decision == .ceilingExceeded(totalSeconds: 2000))
    }

    // MARK: - Per-context idle-stall selection (#1364)

    /// `idleStallTimeout(for: .chat)` is nil — interactive chat keeps idle
    /// monitoring disabled (the UI chip is the release valve; the ceiling
    /// still applies).
    @Test func idleStallTimeoutForChatIsDisabled() {
        #expect(TurnLivenessPolicy.idleStallTimeout(for: .chat) == nil)
    }

    /// `idleStallTimeout(for: .ingest)` / `.lint` resolve to the queued
    /// idle-stall constant (300s) — the unattended lanes bound a silent phase
    /// to five minutes, well under the 600s flat ceiling.
    @Test func idleStallTimeoutForQueuedLanesIs300Seconds() {
        #expect(TurnLivenessPolicy.idleStallTimeout(for: .ingest)
                == TurnLivenessPolicy.queuedIdleStallTimeout)
        #expect(TurnLivenessPolicy.idleStallTimeout(for: .lint)
                == TurnLivenessPolicy.queuedIdleStallTimeout)
        #expect(TurnLivenessPolicy.queuedIdleStallTimeout == 300)
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

    // MARK: - Batch-aware queued ceiling (2026-10-04, job 01M44Q63RG…)

    /// Batches at or below the base keep the flat #609 ceiling exactly.
    @Test func queuedCeilingFlatUpToBaseWorkUnits() {
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: 0) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: 1) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: TurnLivenessPolicy.queuedCeilingBaseWorkUnits)
                == TurnLivenessPolicy.queuedIngestCeiling)
    }

    /// Above the base the ceiling grows linearly by the per-unit allowance.
    @Test func queuedCeilingScalesPerWorkUnit() {
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: TurnLivenessPolicy.queuedCeilingBaseWorkUnits + 1)
                == TurnLivenessPolicy.queuedIngestCeiling + TurnLivenessPolicy.queuedCeilingSecondsPerWorkUnit)
        // The diagnosed 61-source batch: 600 + 51×20 = 1620s (27 min).
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: 61) == 1620)
    }

    /// Very large batches stay bounded by the cap — the stall backstop must
    /// never disappear, only stretch.
    @Test func queuedCeilingIsCapped() {
        #expect(TurnLivenessPolicy.queuedCeiling(workUnits: 10_000) == TurnLivenessPolicy.queuedCeilingCap)
        #expect(TurnLivenessPolicy.queuedCeilingCap >= TurnLivenessPolicy.defaultCeilingTimeout)
    }

    /// The ceiling(for:) decision point threads work units through: nil keeps
    /// the flat ceiling, .chat ignores the batch, and the queued lanes scale.
    @Test func ceilingForKindRespectsWorkUnits() {
        #expect(TurnLivenessPolicy.ceiling(for: .ingest) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.ceiling(for: .ingest, workUnits: nil) == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(TurnLivenessPolicy.ceiling(for: .ingest, workUnits: 61) == 1620)
        #expect(TurnLivenessPolicy.ceiling(for: .lint, workUnits: 61) == 1620)
        #expect(TurnLivenessPolicy.ceiling(for: .chat, workUnits: 61)
                == TurnLivenessPolicy.defaultCeilingTimeout)
    }
}
#endif
