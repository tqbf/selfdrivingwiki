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

    /// Default ceiling: 30 minutes. Backstop against an agent that streams
    /// heartbeat-ish updates forever without finishing.
    static let defaultCeilingTimeout: TimeInterval = 1800

    /// Watchdog poll interval: 15 seconds. Balances responsiveness (a ceiling
    /// breach is detected within 15s of the threshold) against actor pressure.
    static let defaultPollInterval: TimeInterval = 15
}
