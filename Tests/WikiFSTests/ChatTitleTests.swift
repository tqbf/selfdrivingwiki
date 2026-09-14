import Testing
import Foundation
@testable import WikiFSCore

/// `ChatSummary.title(fromFirstMessage:)` derives a chat's display title from
/// the first user message: first line, trimmed, elided at 60 chars; `nil`
/// when nothing usable remains (#1265 — writers skip the title write, leaving
/// the row genuinely untitled). Pure function, so it's tested in isolation
/// from the store.
@Suite struct ChatTitleTests {

    @Test func plainShortMessagePassesThrough() {
        #expect(ChatSummary.title(fromFirstMessage: "What does this page say?")
                == "What does this page say?")
    }

    @Test func multiLineMessageTakesFirstLine() {
        let message = "Summarize the wiki\nand also check for broken links."
        #expect(ChatSummary.title(fromFirstMessage: message) == "Summarize the wiki")
    }

    @Test func longMessageElidesAtSixtyCharsWithTrailingEllipsis() {
        let message = String(repeating: "a", count: 100)
        #expect(ChatSummary.title(fromFirstMessage: message)
                == String(repeating: "a", count: 59) + "…")
    }

    @Test("a whitespace-only message derives nothing usable")
    func whitespaceOnlyMessageDerivesNil() {
        #expect(ChatSummary.title(fromFirstMessage: "   \n\t  ") == nil)
    }

    @Test("an empty message derives nothing usable")
    func emptyMessageDerivesNil() {
        #expect(ChatSummary.title(fromFirstMessage: "") == nil)
    }

    // MARK: - Injected skills-budget preamble

    private static let warning =
        AgentPresentationPreamble.knownWarningSentence

    @Test("warning-prefixed message derives the title from the real question")
    func warningPrefixStrippedFromTitle() {
        let message = "\(Self.warning)\n\nWhat is a tide pool?"
        #expect(ChatSummary.title(fromFirstMessage: message)
                == "What is a tide pool?")
    }

    @Test("a warning-only message derives nothing usable")
    func warningOnlyMessageDerivesNil() {
        #expect(ChatSummary.title(fromFirstMessage: Self.warning) == nil)
        #expect(ChatSummary.title(fromFirstMessage: "\(Self.warning)\n\n") == nil)
    }

    @Test("an unrelated Warning: line is preserved — only the known family is stripped")
    func unrelatedWarningLinesArePreserved() {
        let message = "Warning: the disk is nearly full\nplease check"
        #expect(ChatSummary.title(fromFirstMessage: message) == "Warning: the disk is nearly full")
    }
}
