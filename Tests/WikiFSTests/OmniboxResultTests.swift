import Testing
import Foundation
@testable import WikiFSCore

/// Tests for `OmniboxResult` — the unified omnibox result type that wraps pages,
/// sources, chats, bookmarks, and an "Ask" action (#288).
@Suite struct OmniboxResultTests {

    private let page = WikiPageSummary(
        id: PageID(rawValue: "01PAGE"),
        title: "Mars Terraforming",
        updatedAt: Date(timeIntervalSince1970: 1000),
        createdAt: Date(timeIntervalSince1970: 500)
    )

    private let chat = ChatSummary(
        id: PageID(rawValue: "01CHAT"),
        kind: .edit,
        title: "Mars Discussion",
        createdAt: Date(timeIntervalSince1970: 2000),
        updatedAt: Date(timeIntervalSince1970: 3000),
        messageCount: 3
    )

    // MARK: - Identifiable

    @Test func pageResultIDHasPagePrefix() {
        #expect(OmniboxResult.page(page).id == "page:01PAGE")
    }

    @Test func askResultIDIsStable() {
        #expect(OmniboxResult.ask(question: "hello").id == "ask")
    }

    // MARK: - Display

    @Test func pageDisplayTitleIsPageTitle() {
        #expect(OmniboxResult.page(page).displayTitle == "Mars Terraforming")
    }

    @Test func askDisplayTitleIncludesQuestion() {
        #expect(OmniboxResult.ask(question: "How cold is Mars?").displayTitle == "Ask: How cold is Mars?")
    }

    @Test func pageSystemImageIsDocText() {
        #expect(OmniboxResult.page(page).systemImageName == "doc.text")
    }

    @Test func chatSystemImageIsBubbles() {
        #expect(OmniboxResult.chat(chat).systemImageName == "bubble.left.and.bubble.right")
    }

    @Test func askSystemImageIsSparkles() {
        #expect(OmniboxResult.ask(question: "test").systemImageName == "sparkles")
    }

    // MARK: - Subtitle

    @Test func pageSubtitleIsPage() {
        #expect(OmniboxResult.page(page).subtitle == "Page")
    }

    @Test func chatSubtitleIncludesMessageCount() {
        #expect(OmniboxResult.chat(chat).subtitle == "3 messages")
    }

    @Test func chatSubtitleSingularMessage() {
        let single = ChatSummary(
            id: PageID(rawValue: "01CHAT2"),
            kind: .edit, title: "Test",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messageCount: 1
        )
        #expect(OmniboxResult.chat(single).subtitle == "1 message")
    }

    @Test func askSubtitleIsSendToChat() {
        #expect(OmniboxResult.ask(question: "test").subtitle == "Send to chat")
    }

    // MARK: - Selection

    @Test func pageSelectionIsPageCase() {
        #expect(OmniboxResult.page(page).selection == .page(PageID(rawValue: "01PAGE")))
    }

    @Test func askSelectionIsNewChat() {
        #expect(OmniboxResult.ask(question: "test").selection == .newChat)
    }

    // MARK: - isAction

    @Test func askIsAction() {
        #expect(OmniboxResult.ask(question: "test").isAction == true)
    }

    @Test func pageIsNotAction() {
        #expect(OmniboxResult.page(page).isAction == false)
    }
}
