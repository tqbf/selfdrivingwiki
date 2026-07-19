import Foundation

/// Pure decision helper for ACP turn liveness. Determines whether an in-flight
/// `session/prompt` is healthy or past a hard ceiling (total turn duration).
///
/// The idle/stall path was removed: ACP agents emit `session/update`
/// notifications for every activity — thinking, text deltas, tool calls,
/// sub-agent lifecycle — so a live, working agent almost always produces
/// notifications. The only remaining failure signal is the **hard ceiling**
/// (a turn that runs too long) and **process death** (detected separately via
/// `kill(pid, 0)` in the watchdog task). A legitimate long reasoning chain
/// during page creation should not be killed just because it went quiet.
///
/// PURE — no actor, no clock side-effects, no I/O. Unit-tested directly.
/// `ACPBackend.send` calls this from its watchdog task on every poll interval.
///
/// See `plans/acp-stall-recovery.md` §1a (idle path now removed).
enum TurnLivenessPolicy {

    /// The watchdog's verdict for a single poll.
    enum Decision: Equatable {
        /// The turn is progressing — keep waiting.
        case healthy
        /// Total turn duration exceeded the ceiling — even if notifications are
        /// flowing, the turn has run too long.
        case ceilingExceeded(totalSeconds: TimeInterval)
    }

    /// Evaluate turn liveness at a point in time.
    ///
    /// - Parameters:
    ///   - now: The current wall-clock time.
    ///   - promptDone: Whether `sendPrompt` has already returned (the turn is
    ///     over). When true, always `.healthy` — the watchdog should stop.
    ///   - turnStartedAt: When the turn began (the prompt was sent).
    ///   - ceilingTimeout: Hard maximum turn duration (default 1800s / 30 min).
    /// - Returns: The decision. Precedence: `promptDone` > `ceilingExceeded`
    ///   > `healthy`.
    static func evaluate(
        now: Date,
        promptDone: Bool,
        turnStartedAt: Date,
        ceilingTimeout: TimeInterval
    ) -> Decision {
        // If the prompt already completed, the turn is over — nothing to do.
        if promptDone { return .healthy }

        let totalElapsed = now.timeIntervalSince(turnStartedAt)

        // Hard ceiling: even a chatty agent must finish eventually.
        if totalElapsed >= ceilingTimeout {
            return .ceilingExceeded(totalSeconds: totalElapsed)
        }

        return .healthy
    }

    // MARK: - Defaults

    /// Default (interactive) ceiling: 30 minutes. Backstop against an agent
    /// that streams heartbeat-ish updates forever without finishing. Used by
    /// `startInteractiveQuery` (interactive chat — long reasoning chains are
    /// legitimate, and the UI chip is the user-facing release valve).
    static let defaultCeilingTimeout: TimeInterval = 1800

    /// Queued-ingestion ceiling: 10 minutes. Used by unattended pipelines
    /// (ingest — including `runACPIngestPlannerExecutors` — and lint runs).
    /// Lower than the interactive default so a single stalled ingestion turn
    /// burns 10 minutes, not 30 (issue #609: a 4-page ingest twice hit the
    /// 1800s ceiling on 2026-07-18, costing ~60 minutes of dead time). The
    /// companion #606 permission auto-reject budget (60s) is the primary
    /// backstop; this ceiling is a wider safety net for non-permission stalls.
    static let queuedIngestCeiling: TimeInterval = 600

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
    /// Single decision point the launcher consults at backend construction.
    /// Mirrors the `permissionBudget` split (`nil` for chat, `.seconds(60)`
    /// for ingest/lint) at the symmetric call site — same rationale:
    /// unattended pipelines need tighter backstops than interactive chat.
    static func ceiling(for kind: PermissionOperationKind) -> TimeInterval {
        switch kind {
        case .chat:                return defaultCeilingTimeout
        case .ingest, .lint:       return queuedIngestCeiling
        }
    }
}
