import Testing
import Foundation
@testable import WikiFSCore

/// `ChatSummary.title(fromFirstMessage:)` derives a chat's display title from
/// the first user message: first line, trimmed, elided at 60 chars. Pure
/// function, so it's tested in isolation from the store.
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
        let title = ChatSummary.title(fromFirstMessage: message)
        #expect(title.count == 60)
        #expect(title.hasSuffix("…"))
        #expect(title == String(repeating: "a", count: 59) + "…")
    }

    @Test func whitespaceOnlyMessageFallsBackToNewChat() {
        #expect(ChatSummary.title(fromFirstMessage: "   \n\t  ") == "New Chat")
    }

    @Test func emptyMessageFallsBackToNewChat() {
        #expect(ChatSummary.title(fromFirstMessage: "") == "New Chat")
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

    @Test("a warning-only message derives to New Chat")
    func warningOnlyMessageFallsBackToNewChat() {
        #expect(ChatSummary.title(fromFirstMessage: Self.warning) == "New Chat")
        #expect(ChatSummary.title(fromFirstMessage: "\(Self.warning)\n\n") == "New Chat")
    }

    @Test("an unrelated Warning: line is preserved — only the known family is stripped")
    func unrelatedWarningLinesArePreserved() {
        let message = "Warning: the disk is nearly full\nplease check"
        #expect(ChatSummary.title(fromFirstMessage: message) == "Warning: the disk is nearly full")
    }
}
