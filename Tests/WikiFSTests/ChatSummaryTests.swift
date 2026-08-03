#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import WikiFSEngine
import Testing

/// Tests for the chat-summary feature (issue #411).
///
/// `chats.summary` is the chats-list row subtitle — the gist of the OPENING
/// answer, not a summary of the whole conversation. It is no longer computed
/// separately: it MIRRORS the first summarizable message's `chat_messages.summary`,
/// so it inherits that summarizer's mode (Default ⇒ truncated extract, Model ⇒
/// the model's sentence verbatim). Before the unification the launcher wrote its
/// own always-truncated version, which abbreviated the subtitle even in Model mode.
///
/// Three layers:
///   - **Pure extract** — `ChatSummary.summaryExtract(from:maxLength:)` is a
///     pure function; these tests run in the fast tier.
///   - **Source selection** — `MessageSummarizer.chatSummaryMessageID(in:)`
///     picks which message feeds the chat row; pure, fast tier.
///   - **Store round-trip** — `updateChatSummary` + `listChats()` on a real
///     SQLite DB; tagged `.integration` (opens a real store).
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

    // MARK: - Chat-summary source selection: MessageSummarizer.chatSummaryMessageID

    /// Build a `ChatMessage` list from events with deterministic ids ("m0", "m1", …).
    private func messages(_ events: [AgentEvent]) -> [ChatMessage] {
        events.enumerated().map { idx, event in
            ChatMessage(
                id: PageID(rawValue: "m\(idx)"), chatID: ChatID(rawValue: "chat"),
                seq: idx, event: event, createdAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func chatSummaryMessageID_picksFirstAssistantMessage() {
        // The chat subtitle mirrors the FIRST assistant response's summary —
        // later assistant turns never overwrite it.
        let msgs = messages([
            .userText("question"),
            .assistantText("First answer."),
            .assistantText("Second answer."),
        ])
        #expect(MessageSummarizer.chatSummaryMessageID(in: msgs) == PageID(rawValue: "m1"))
    }

    @Test func chatSummaryMessageID_acceptsResultEvent() {
        // Agents that emit everything in .result still seed the chat summary.
        let msgs = messages([
            .toolUse(name: "Bash", inputSummary: "ls"),
            .result(isError: false, text: "The answer is 42."),
        ])
        #expect(MessageSummarizer.chatSummaryMessageID(in: msgs) == PageID(rawValue: "m1"))
    }

    @Test func chatSummaryMessageID_skipsWhitespaceOnlyText() {
        // A blank assistant message is not a summary source — the next one is.
        let msgs = messages([
            .assistantText("   "),
            .assistantText("Real answer."),
        ])
        #expect(MessageSummarizer.chatSummaryMessageID(in: msgs) == PageID(rawValue: "m1"))
    }

    @Test func chatSummaryMessageID_onlyNonAssistantEvents_returnsNil() {
        let msgs = messages([
            .userText("question"),
            .toolUse(name: "Bash", inputSummary: "ls"),
            .toolResult(isError: false, summary: "file.txt"),
        ])
        #expect(MessageSummarizer.chatSummaryMessageID(in: msgs) == nil)
    }

    @Test func chatSummaryMessageID_emptyMessages_returnsNil() {
        #expect(MessageSummarizer.chatSummaryMessageID(in: []) == nil)
    }

    // MARK: - Store round-trip (integration)

    @Test
    func summaryRoundTrip_updateAndReadBack() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")

        // Before: no summary.
        let before = try store.listChats().first { $0.id == chat.id }
        #expect(before?.summary == nil)
        #expect(before?.summaryAt == nil)

        // After: summary is populated.
        try store.updateChatSummary(chatID: chat.id, summary: "A concise summary.")
        let after = try store.listChats().first { $0.id == chat.id }
        #expect(after?.summary == "A concise summary.")
        #expect(after?.summaryAt != nil)
    }

    @Test
    func summaryNullForExistingChats_afterMigration() throws {
        // A fresh DB is already at v36; createChat inserts a row with NULL
        // summary/summary_at. listChats() must return nil for both.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "No Summary Chat")

        let row = try store.listChats().first { $0.id == chat.id }
        #expect(row != nil)
        #expect(row?.summary == nil)
        #expect(row?.summaryAt == nil)
    }

    @Test
    func summaryBumpsUpdatedAt() async throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Timestamp Chat")
        let before = try store.listChats().first { $0.id == chat.id }
        let originalUpdatedAt = before?.updatedAt

        // Small delay to ensure timestamps differ.
        // Use Task.sleep to avoid blocking the cooperative thread pool (#732).
        try await Task.sleep(for: .milliseconds(10))
        try store.updateChatSummary(chatID: chat.id, summary: "Updated.")

        let after = try store.listChats().first { $0.id == chat.id }
        #expect(after?.updatedAt != originalUpdatedAt)
        #expect(after?.updatedAt ?? Date.distantPast > originalUpdatedAt ?? Date.distantPast)
    }
}
#endif // os(macOS)
