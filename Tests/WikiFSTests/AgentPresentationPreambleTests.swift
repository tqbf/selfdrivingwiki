import Foundation
import Testing
import WikiFSCore

/// The known-warning filter's two policies, at the Core seam every consumer
/// shares: streaming suppression hides proper prefixes; complete-only
/// removal preserves them. Unrelated warnings always survive.
@Suite struct AgentPresentationPreambleTests {
    private static let sentence =
        "Warning: Skill descriptions were shortened to fit the 2% skills context budget."

    /// Every incremental proper prefix — including mid-word cut points — plus
    /// the complete warning itself is hidden under the streaming policy.
    @Test(arguments: [
        "W",
        "Warning:",
        "Warning: Skill",
        "Warning: Skill descriptions",
        "Warning: Skill descriptions were shortened to fit",
        "Warning: Skill descriptions were shortened to fit the 2% skills context budget",
    ])
    func streamingPrefixesAreHiddenOnlyWithStreamingPolicy(_ prefix: String) {
        #expect(AgentPresentationPreamble.visibleText(prefix, policy: .streamingPrefixAware) == nil)
        // The same text as a FINAL value is content: complete-only preserves it.
        #expect(AgentPresentationPreamble.visibleText(prefix, policy: .completeOnly) == prefix)
    }

    @Test func streamingPolicyHidesTheCompleteWarningAndNothingElse() {
        #expect(AgentPresentationPreamble.visibleText(Self.sentence, policy: .streamingPrefixAware) == nil)
        #expect(AgentPresentationPreamble.visibleText(
            Self.sentence + "\n\nAnswer follows.",
            policy: .streamingPrefixAware) == "Answer follows.")
    }

    /// `completeOnly` keeps an incomplete final prefix, a warning-only value
    /// cleans to nil, warning-plus-answer keeps the answer, leading blank
    /// lines after the warning go, and unrelated warnings stay.
    @Test(arguments: [
        // (input, expected)
        ("Warning: Skill descriptions were shortened", "Warning: Skill descriptions were shortened"),
        ("Warning: Provider timeout after 30s", "Warning: Provider timeout after 30s"),
        ("Warning: Skill descriptions were shortened to fit a different budget",
         "Warning: Skill descriptions were shortened to fit a different budget"),
    ])
    func completeOnlyPreservesIncompleteAndUnrelatedWarnings(_ input: String, expected: String) {
        #expect(AgentPresentationPreamble.visibleText(input, policy: .completeOnly) == expected)
    }

    @Test func completeOnlyRemovesCompleteWarningFamilies() {
        // Warning-only: no visible text (with and without trailing blank).
        #expect(AgentPresentationPreamble.visibleText(Self.sentence, policy: .completeOnly) == nil)
        #expect(AgentPresentationPreamble.visibleText(Self.sentence + " \n", policy: .completeOnly) == nil)

        // Warning plus answer: leading blank lines after the warning go.
        #expect(AgentPresentationPreamble.visibleText(
            Self.sentence + "\n\n\nTidal pools form twice daily.",
            policy: .completeOnly) == "Tidal pools form twice daily.")

        // A provider suffix on the same line is part of the known family.
        #expect(AgentPresentationPreamble.visibleText(
            Self.sentence + " (12 tools)",
            policy: .completeOnly) == nil)
    }

    @Test func whitespaceOnlyTextHasNoVisibleTextUnderEitherPolicy() {
        #expect(AgentPresentationPreamble.visibleText("", policy: .streamingPrefixAware) == nil)
        #expect(AgentPresentationPreamble.visibleText("  \n \n", policy: .completeOnly) == nil)
    }
}
