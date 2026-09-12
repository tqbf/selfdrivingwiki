#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import WikiFSEngine
import Testing

/// Tests for the pure summary-extract logic that survives the chat-summary
/// feature's chat-level removal: `ChatSummary.summaryExtract(from:maxLength:)`
/// still shapes the per-message Default-mode summaries (which feed the
/// outline's response text). The chat-level `chats.summary` column and its
/// mirror were removed (schema v53); per-message summaries live in
/// `chat_messages.summary` and are covered by `MessageSummaryTests`.
@Suite
struct ChatSummaryTests {

    // MARK: - Pure extract: ChatSummary.summaryExtract

    @Test func summaryExtract_multiSentence_extractsFirstSentence() {
        let input = "The page covers tire selection. It also talks about pressures."
        let result = ChatSummary.summaryExtract(from: input)
        #expect(result == "The page covers tire selection.")
    }

    @Test func summaryExtract_longInput_elidesWithEllipsis() {
        let input = "This is a very long sentence that definitely exceeds the max length limit imposed by the caller."
        let result = ChatSummary.summaryExtract(from: input, maxLength: 20)
        #expect(result.count == 20)
        #expect(result.hasSuffix("…"))
    }

    @Test func summaryExtract_emptyInput_returnsEmptyString() {
        #expect(ChatSummary.summaryExtract(from: "") == "")
        #expect(ChatSummary.summaryExtract(from: "   ") == "")
    }

    @Test func summaryExtract_noSentenceBoundary_usesFullTextElided() {
        // No sentence boundary → full text is used, then elided.
        let input = "a very long line with no punctuation at all that goes past the limit"
        let result = ChatSummary.summaryExtract(from: input, maxLength: 20)
        #expect(result.count == 20)
        #expect(result.hasSuffix("…"))
    }

    @Test func summaryExtract_shortInput_returnsAsIs() {
        let input = "Short text."
        let result = ChatSummary.summaryExtract(from: input)
        #expect(result == "Short text.")
    }
}
#endif // os(macOS)
