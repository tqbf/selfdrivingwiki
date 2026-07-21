import Testing
import Foundation
import WikiFSCore

/// Pure-logic tests for `FreeTierModelNudge` (#612).
///
/// The helper powers the info-tone nudge caption shown in the Agents-settings
/// pickers when the selected model is a known free-tier model (e.g.
/// `opencode/big-pickle`). It never blocks selection — the caption is a gentle
/// steer toward a stronger model. PURE + STATIC so these tests call it
/// directly without a SwiftUI view tree.
@Suite("FreeTierModelNudge")
struct FreeTierModelNudgeTests {

    // MARK: - Returns nil for non-free-tier models

    @Test func returnsNilForNilModelId() {
        #expect(FreeTierModelNudge.message(for: nil) == nil)
    }

    @Test func returnsNilForEmptyModelId() {
        #expect(FreeTierModelNudge.message(for: "") == nil)
    }

    @Test func returnsNilForRegularModel() {
        #expect(FreeTierModelNudge.message(for: "sonnet") == nil)
        #expect(FreeTierModelNudge.message(for: "claude-sonnet-4.5") == nil)
        #expect(FreeTierModelNudge.message(for: "glm-4.7") == nil)
    }

    // MARK: - Returns nudge for free-tier models

    @Test func returnsNudgeForBigPickle() {
        let msg = FreeTierModelNudge.message(for: "opencode/big-pickle")
        #expect(msg != nil)
        #expect(msg?.contains("Free-tier models") == true)
        #expect(msg?.contains("stronger model") == true)
    }

    @Test func returnsNudgeForBigPickleUnderscoreVariant() {
        let msg = FreeTierModelNudge.message(for: "opencode/big_pickle")
        #expect(msg != nil)
    }

    @Test func returnsNudgeCaseInsensitive() {
        #expect(FreeTierModelNudge.message(for: "BIG-PICKLE") != nil)
        #expect(FreeTierModelNudge.message(for: "Big_Pickle") != nil)
    }

    @Test func returnsNudgeForModelIdContainingPattern() {
        // The pattern is a substring match, so a versioned or prefixed id
        // still fires.
        #expect(FreeTierModelNudge.message(for: "opencode/big-pickle-v2") != nil)
        #expect(FreeTierModelNudge.message(for: "free/big-pickle-mini") != nil)
    }

    @Test func returnsSameMessageForAllFreeTierModels() {
        // The message is a constant, not model-specific — pin it so the UI
        // caption is stable.
        let a = FreeTierModelNudge.message(for: "opencode/big-pickle")
        let b = FreeTierModelNudge.message(for: "other/big_pickle")
        #expect(a == b)
        #expect(a == FreeTierModelNudge.nudgeMessage)
    }
}
