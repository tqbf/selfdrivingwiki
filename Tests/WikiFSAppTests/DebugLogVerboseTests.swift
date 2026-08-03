import Foundation
import Testing
import WikiFSCore

/// Tests for `DebugLog.verbose` / `DebugLog.verboseLogging` (#872).
///
/// The verbose flag gates high-frequency per-event daemon logs
/// (`pushQueueEvent` / `pushChatEnvelope`) so they don't flood Console.app
/// during active ingestion. The os_log sink can't be intercepted from a unit
/// test, so these tests assert the gating contract (no-crash in either state,
/// flag is mutable) rather than the emitted bytes.
///
/// `verboseLogging` is a shared mutable static, so the suite is `.serialized`
/// to keep the save/toggle/restore sequence free of cross-test races.
@Suite(.serialized)
struct DebugLogVerboseTests {

    /// Calling `verbose` with the flag off must be a cheap no-op (the default
    /// state in tests / fresh installs — `debugVerboseLogging` is absent from
    /// UserDefaults). Regression guard: this is the hot path hit once per
    /// daemon event; it must never crash or throw.
    @Test
    func verboseIsNoOpWhenFlagOff() {
        let saved = DebugLog.verboseLogging
        defer { DebugLog.verboseLogging = saved }
        DebugLog.verboseLogging = false

        DebugLog.verbose("wikid: pushQueueEvent kind=progress sinks=1")
        DebugLog.verbose("wikid: pushChatEnvelope kind=chatEvent sinks=2")
        // No crash / no throw => the guard short-circuits before `emit`.
    }

    /// The flag is a mutable runtime toggle (defaults menu / `defaults write`
    /// / direct assignment). Round-trip both states and confirm `verbose` is
    /// safe to call while the flag is on (it then reaches `emit` → os_log).
    @Test
    func verboseFlagCanBeToggled() {
        let saved = DebugLog.verboseLogging
        defer { DebugLog.verboseLogging = saved }

        DebugLog.verboseLogging = true
        #expect(DebugLog.verboseLogging == true)
        DebugLog.verbose("wikid: pushQueueEvent kind=progress sinks=1")

        DebugLog.verboseLogging = false
        #expect(DebugLog.verboseLogging == false)
        DebugLog.verbose("wikid: pushQueueEvent kind=progress sinks=1")
    }

    /// The `@autoclosure` argument must not be evaluated when the flag is off —
    /// otherwise an expensive `String` build (interpolating an `envelope.kind`
    /// or a `sinks.count`) would still be paid on every event even though the
    /// line is dropped, defeating the whole point of gating (#872).
    @Test
    func verboseDoesNotEvaluateArgumentWhenOff() {
        let saved = DebugLog.verboseLogging
        defer { DebugLog.verboseLogging = saved }
        DebugLog.verboseLogging = false

        var evaluated = false
        DebugLog.verbose({
            evaluated = true
            return "should not be built"
        }())
        #expect(evaluated == false)
    }
}
