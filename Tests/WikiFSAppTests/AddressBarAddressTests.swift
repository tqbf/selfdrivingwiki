#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Pure logic behind `AddressBarView.hasContentLoaded`. The bar autofocuses
/// its search field whenever the address text goes empty (launch, last tab
/// closed) — so an open chat MUST always resolve to a non-empty address. The
/// previous `title.isEmpty ? "" : …` return made every UNTITLED chat (i.e.
/// every brand-new chat) look like "no content", and the omnibox's
/// `focusIfEmpty()` stole keyboard focus from the new chat's composer before
/// the composer's own autofocus could claim it.
@Suite struct AddressBarAddressTests {

    private func makeChat(title: String) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: "01JCHAT000000000000000TEST"),
            kind: .edit,
            title: title,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messageCount: 0)
    }

    @Test("a titled chat renders its title in the pseudo-wikilink")
    func titledChat() {
        let chat = makeChat(title: "What is a tide pool?")
        #expect(AddressBarView.chatAddress(in: [chat], chatID: chat.id) == "[[chat:What is a tide pool?]]")
    }

    @Test("an untitled chat falls back to New Chat — never an empty address")
    func untitledChatUsesNewChatFallback() {
        let chat = makeChat(title: "")
        let address = AddressBarView.chatAddress(in: [chat], chatID: chat.id)
        #expect(address == "[[chat:New Chat]]")
        // The load-bearing assertion: non-empty, so `hasContentLoaded` stays
        // true and the omnibox does not autofocus over the chat composer.
        #expect(!address.isEmpty)
    }

    @Test("a whitespace-only title counts as untitled")
    func whitespaceTitleCountsAsUntitled() {
        let chat = makeChat(title: "   ")
        #expect(AddressBarView.chatAddress(in: [chat], chatID: chat.id) == "[[chat:New Chat]]")
    }

    @Test("a chat missing from the projection still resolves a non-empty address")
    func missingChatRowStillResolves() {
        let address = AddressBarView.chatAddress(in: [], chatID: ChatID(rawValue: "01JMISSING"))
        #expect(address == "[[chat:New Chat]]")
    }
}
#endif
