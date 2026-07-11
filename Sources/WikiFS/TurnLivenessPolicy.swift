import Foundation

/// Pure decision helper for ACP turn liveness. Determines whether an in-flight
/// `session/prompt` is healthy, stalled (no `session/update` notifications for
/// too long), or past a hard ceiling (total turn duration).
///
/// This is NOT a flat prompt timeout — a turn legitimately running 6+ minutes
/// of research work is healthy as long as notifications keep arriving. The
/// correct failure signal is **inactivity**: the agent is healthy iff
/// `session/update` notifications keep flowing.
///
/// PURE — no actor, no clock side-effects, no I/O. Unit-tested directly.
/// `ACPBackend.send` calls this from its watchdog task on every poll interval.
///
/// See `plans/acp-stall-recovery.md` §1a.
enum TurnLivenessPolicy {

    /// The watchdog's verdict for a single poll.
    enum Decision: Equatable {
        /// The turn is progressing — keep waiting.
        case healthy
        /// No notification has arrived for `idleSeconds`. The turn should be
        /// cancelled and surfaced as an error.
        case stalled(idleSeconds: TimeInterval)
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
    ///   - lastActivityAt: When the most recent `session/update` notification
    ///     arrived. At turn start this equals `turnStartedAt` (no notifications
    ///     yet).
    ///   - idleTimeout: How long without a notification before declaring a
    ///     stall (default 120s).
    ///   - ceilingTimeout: Hard maximum turn duration (default 1800s / 30 min).
    /// - Returns: The decision. Precedence: `promptDone` > `ceilingExceeded`
    ///   > `stalled` > `healthy`.
    static func evaluate(
        now: Date,
        promptDone: Bool,
        turnStartedAt: Date,
        lastActivityAt: Date,
        idleTimeout: TimeInterval,
        ceilingTimeout: TimeInterval
    ) -> Decision {
        // If the prompt already completed, the turn is over — nothing to do.
        if promptDone { return .healthy }

        let totalElapsed = now.timeIntervalSince(turnStartedAt)

        // Hard ceiling: even a chatty agent must finish eventually.
        if totalElapsed >= ceilingTimeout {
            return .ceilingExceeded(totalSeconds: totalElapsed)
        }

        let idle = now.timeIntervalSince(lastActivityAt)

        // Inactivity: the agent went silent.
        if idle >= idleTimeout {
            return .stalled(idleSeconds: idle)
        }

        return .healthy
    }

    // MARK: - Defaults

    /// Default idle timeout: 120 seconds. Generous because an agent may pause
    /// between tool calls or while thinking. The observed stall had zero
    /// notifications — this is the signal that distinguishes "thinking" from
    /// "dead."
    static let defaultIdleTimeout: TimeInterval = 120

    /// Default ceiling: 30 minutes. Backstop against an agent that streams
    /// heartbeat-ish updates forever without finishing.
    static let defaultCeilingTimeout: TimeInterval = 1800

    /// Watchdog poll interval: 15 seconds. Balances responsiveness (a stall is
    /// detected within 15s of the threshold) against actor pressure.
    static let defaultPollInterval: TimeInterval = 15
}
