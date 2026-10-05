import Foundation

/// Pure decision helper for ACP turn liveness. Determines whether an in-flight
/// `session/prompt` is healthy, past a hard ceiling (total turn duration), or
/// idle-stalled (no notification activity for the idle bound — queued lanes
/// only).
///
/// ACP agents emit `session/update` notifications for every activity —
/// thinking, text deltas, tool calls, sub-agent lifecycle — so a live, working
/// agent almost always produces notifications. Interactive chat therefore has
/// NO idle bound (`idleTimeout` nil): long silent reasoning is legitimate when
/// a user is attending, and the UI chip is the release valve. The remaining
/// failure signals are the **hard ceiling** (a turn that runs too long) and,
/// for the unattended queued lanes (ingest/lint), the **idle stall** — a phase
/// whose notification stream has been silent for minutes is dead or wedged
/// (issue #1364). Process death is detected separately via `kill(pid, 0)` in
/// the watchdog task.
///
/// PURE — no actor, no clock side-effects, no I/O. Unit-tested directly.
/// `ACPBackend.send` calls this from its watchdog task on every poll interval.
///
/// See `plans/acp-stall-recovery.md` §1a (the interactive idle path was
/// removed; #1364 restored an idle bound for the queued lanes only).
public enum TurnLivenessPolicy {

    /// The watchdog's verdict for a single poll.
    enum Decision: Equatable {
        /// The turn is progressing — keep waiting.
        case healthy
        /// Total turn duration exceeded the ceiling — even if notifications are
        /// flowing, the turn has run too long.
        case ceilingExceeded(totalSeconds: TimeInterval)
        /// No notification activity for `idleSeconds` (queued lanes only —
        /// interactive chat passes `idleTimeout: nil`). The turn was cancelled.
        case idleStallExceeded(idleSeconds: TimeInterval)
    }

    /// Evaluate turn liveness at a point in time.
    ///
    /// - Parameters:
    ///   - now: The current wall-clock time.
    ///   - promptDone: Whether `sendPrompt` has already returned (the turn is
    ///     over). When true, always `.healthy` — the watchdog should stop.
    ///   - turnStartedAt: When the turn began (the prompt was sent).
    ///   - ceilingTimeout: Hard maximum turn duration (default 1800s / 30 min).
    ///   - idleTimeout: Maximum notification silence before the turn is
    ///     considered stalled. nil (default) disables idle monitoring — the
    ///     interactive-chat configuration, where long silent reasoning is
    ///     legitimate while a user is attending. The queued lanes (ingest/lint)
    ///     pass `idleStallTimeout(for:)` so a wedged phase cannot sit frozen
    ///     for a full ceiling (issue #1364).
    ///   - lastActivityAt: The fanout's current activity timestamp at poll
    ///     time (the wall-clock time of the most recent `session/update`).
    ///     Only read when `idleTimeout` is non-nil.
    /// - Returns: The decision. Precedence: `promptDone` > `ceilingExceeded`
    ///   > `idleStallExceeded` > `healthy`.
    static func evaluate(
        now: Date,
        promptDone: Bool,
        turnStartedAt: Date,
        ceilingTimeout: TimeInterval,
        idleTimeout: TimeInterval? = nil,
        lastActivityAt: Date = Date()
    ) -> Decision {
        // If the prompt already completed, the turn is over — nothing to do.
        if promptDone { return .healthy }

        let totalElapsed = now.timeIntervalSince(turnStartedAt)

        // Hard ceiling: even a chatty agent must finish eventually.
        if totalElapsed >= ceilingTimeout {
            return .ceilingExceeded(totalSeconds: totalElapsed)
        }

        // Idle stall (queued lanes only — `idleTimeout` is nil for interactive
        // chat). Computed against the fanout's activity timestamp, NOT the
        // turn start: a notification that arrived 10 minutes into the turn
        // proves the agent was alive then.
        if let idleTimeout {
            let idleSeconds = now.timeIntervalSince(lastActivityAt)
            if idleSeconds >= idleTimeout {
                return .idleStallExceeded(idleSeconds: idleSeconds)
            }
        }

        return .healthy
    }

    // MARK: - Defaults

    /// Default (interactive) ceiling: 30 minutes. Backstop against an agent
    /// that streams heartbeat-ish updates forever without finishing. Used by
    /// `startInteractiveQuery` (interactive chat — long reasoning chains are
    /// legitimate, and the UI chip is the user-facing release valve).
    public static let defaultCeilingTimeout: TimeInterval = 1800

    /// Queued-ingestion ceiling: 10 minutes. Used by unattended pipelines
    /// (ingest — including `runACPIngestPlannerExecutors` — and lint runs).
    /// Lower than the interactive default so a single stalled ingestion turn
    /// burns 10 minutes, not 30 (issue #609: a 4-page ingest twice hit the
    /// 1800s ceiling on 2026-07-18, costing ~60 minutes of dead time). The
    /// companion #606 permission auto-reject budget (60s) is the primary
    /// backstop; this ceiling is a wider safety net for non-permission stalls.
    static let queuedIngestCeiling: TimeInterval = 600

    /// Queued-lane idle-stall timeout: 5 minutes. A queued ingest phase that
    /// produces no ACP notifications for 5 minutes is dead or wedged (issue
    /// #1364: a fresh-start executor froze at events=32 for minutes under a
    /// 600s turn ceiling); 300s sits above legitimate long tool executions
    /// but well below the 600s flat ceiling, bounding a stall to one
    /// ceiling-worth of dead time.
    static let queuedIdleStallTimeout: TimeInterval = 300

    /// Watchdog poll interval: 15 seconds. Balances responsiveness (a ceiling
    /// breach is detected within 15s of the threshold) against actor pressure.
    static let defaultPollInterval: TimeInterval = 15

    // MARK: - Per-context ceiling selection

    /// Resolve the ceiling a turn should use given the operation kind:
    /// - `.chat` — the interactive 1800s default (long reasoning chains are
    ///   legitimate in a user-attended chat).
    /// - `.ingest` / `.lint` — the queued-ingestion 600s ceiling (unattended
    ///   batch pipelines that must not burn 30 minutes on a stall).
    ///
    // MARK: - Batch-aware queued ceiling

    /// Work units covered by the flat ``queuedIngestCeiling`` before per-unit
    /// scaling begins. Batches at or below this size keep the 600s stall
    /// bound exactly as #609 set it (its scenario was a 4-source ingest).
    static let queuedCeilingBaseWorkUnits = 10

    /// Ceiling seconds added per work unit beyond
    /// ``queuedCeilingBaseWorkUnits``. Calibrated against the 2026-10-04
    /// 61-source ingestion (job 01M44Q63RG…): the planner staged ~72 chapter
    /// files in 603s ≈ 10s per source, so 20s per source leaves headroom for
    /// slower sources without unbounding a stall.
    static let queuedCeilingSecondsPerWorkUnit: TimeInterval = 20

    /// Hard cap on the scaled ceiling so even a very large batch keeps a
    /// bounded stall backstop — one hour.
    static let queuedCeilingCap: TimeInterval = 3600

    /// The queued-lane ceiling for a batch of `workUnits` sources: the flat
    /// 600s up to ``queuedCeilingBaseWorkUnits``, then
    /// ``queuedCeilingSecondsPerWorkUnit`` per additional unit, capped at
    /// ``queuedCeilingCap``. A 61-source batch resolves to 1620s (27 min) —
    /// enough for the observed staging pace instead of a mid-work kill at
    /// 603s.
    static func queuedCeiling(workUnits: Int) -> TimeInterval {
        guard workUnits > queuedCeilingBaseWorkUnits else { return queuedIngestCeiling }
        let scaled = queuedIngestCeiling
            + TimeInterval(workUnits - queuedCeilingBaseWorkUnits) * queuedCeilingSecondsPerWorkUnit
        return min(scaled, queuedCeilingCap)
    }

    /// Single decision point the launcher consults at backend construction.
    /// Mirrors the `permissionBudget` split (`nil` for chat, `.seconds(60)`
    /// for ingest/lint) at the symmetric call site — same rationale:
    /// unattended pipelines need tighter backstops than interactive chat.
    ///
    /// `workUnits` makes the queued lane batch-aware: a large ingest batch
    /// legitimately needs more than one flat 600s turn of work, so the
    /// ceiling scales (see ``queuedCeiling(workUnits:)``). `nil` keeps the
    /// flat ceiling; `.chat` ignores it (interactive runs have no batch).
    static func ceiling(for kind: PermissionOperationKind, workUnits: Int? = nil) -> TimeInterval {
        switch kind {
        case .chat:                return defaultCeilingTimeout
        case .ingest, .lint:       return workUnits.map { queuedCeiling(workUnits: $0) } ?? queuedIngestCeiling
        }
    }

    /// Resolve the idle-stall timeout a turn should use given the operation
    /// kind — the idle companion to `ceiling(for:workUnits:)`, mirroring the
    /// `permissionBudget` split at the same call sites:
    /// - `.chat` — nil. Idle monitoring is disabled: long silent reasoning is
    ///   legitimate while a user is attending the session, and the UI chip is
    ///   the user-facing release valve. The hard ceiling still applies.
    /// - `.ingest` / `.lint` — `queuedIdleStallTimeout` (300s). Unattended
    ///   pipelines must not sit with a frozen event count for a full ceiling.
    static func idleStallTimeout(for kind: PermissionOperationKind) -> TimeInterval? {
        switch kind {
        case .chat:                return nil
        case .ingest, .lint:       return queuedIdleStallTimeout
        }
    }
}
