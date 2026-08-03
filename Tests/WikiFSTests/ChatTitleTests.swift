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
}
