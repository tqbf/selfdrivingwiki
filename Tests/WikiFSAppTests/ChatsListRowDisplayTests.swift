#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// The left-hand chat list row contract: the title line is the chat's stored
/// title (the user's question, or the model-generated title when the
/// summarizer stage is configured) with the known injected skills-budget
/// warning stripped, and the subtitle is the creation date. These tests pin
/// the seams
/// `ChatsCellView.rowTitle(for:)` and `ChatsCellView.rowSubtitle(for:)`.
@Suite struct ChatsListRowDisplayTests {

    private let warningTitle =
        AgentPresentationPreamble.knownWarningSentence

    private func makeChat(
        title: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: "01JCHAT000000000000000ROW1"),
            kind: .edit,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: 3)
    }

    // MARK: - Title

    // The cached response summary (chats.summary) was REMOVED (schema v53),
    // so it can no longer shadow the title — rowTitle reads only the stored
    // title, structurally.

    @Test("a stored warning title cleans to the New Chat fallback")
    func warningOnlyStoredTitleFallsBack() {
        let chat = makeChat(title: warningTitle)
        #expect(ChatsCellView.rowTitle(for: chat) == "New Chat")
    }

    @Test("an empty stored title falls back to New Chat")
    func emptyStoredTitleFallsBack() {
        #expect(ChatsCellView.rowTitle(for: makeChat(title: "")) == "New Chat")
    }

    // MARK: - Subtitle

    @Test("subtitle is the creation date, not the updated date")
    func subtitleIsCreatedDate() {
        let created = Date(timeIntervalSince1970: 1_760_000_000)
        let chat = makeChat(
            title: "q",
            createdAt: created,
            updatedAt: created.addingTimeInterval(86_400 * 365))

        #expect(
            ChatsCellView.rowSubtitle(for: chat)
                == created.formatted(date: .abbreviated, time: .shortened))
    }
}
#endif
