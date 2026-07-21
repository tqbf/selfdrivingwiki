#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import WikiFSEngine
import Testing

/// Tests for the chat-summary feature (issue #411).
///
/// Three layers:
///   - **Pure extract** — `ChatSummary.summaryExtract(from:maxLength:)` is a
///     pure function; these tests run in the fast tier.
///   - **Static event-selection** — `AgentLauncher.firstSummaryText(from:)`
///     iterates `[AgentEvent]` without a live launcher; fast tier.
///   - **Store round-trip** — `updateChatSummary` + `listChats()` on a real
///     SQLite DB; tagged `.integration` (opens a real store).
@Suite(.timeLimit(.minutes(5)))
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

    // MARK: - Static event selection: AgentLauncher.firstSummaryText

    @Test func firstSummaryText_assistantText_extractsFirstSentence() {
        let events: [AgentEvent] = [
            .userText("question"),
            .assistantText("First sentence here. Second sentence omitted."),
        ]
        let result = AgentLauncher.firstSummaryText(from: events)
        #expect(result == "First sentence here.")
    }

    @Test func firstSummaryText_resultEvent_extractsFromResultText() {
        let events: [AgentEvent] = [
            .toolUse(name: "Bash", inputSummary: "ls"),
            .result(isError: false, text: "The answer is 42. More details follow."),
        ]
        let result = AgentLauncher.firstSummaryText(from: events)
        #expect(result == "The answer is 42.")
    }

    @Test func firstSummaryText_onlyToolEvents_returnsNil() {
        let events: [AgentEvent] = [
            .userText("question"),
            .toolUse(name: "Bash", inputSummary: "ls"),
            .toolResult(isError: false, summary: "file.txt"),
        ]
        #expect(AgentLauncher.firstSummaryText(from: events) == nil)
    }

    @Test func firstSummaryText_emptyEvents_returnsNil() {
        #expect(AgentLauncher.firstSummaryText(from: []) == nil)
    }

    @Test func firstSummaryText_emptyAssistantText_returnsNil() {
        let events: [AgentEvent] = [
            .assistantText("   "),
        ]
        #expect(AgentLauncher.firstSummaryText(from: events) == nil)
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
