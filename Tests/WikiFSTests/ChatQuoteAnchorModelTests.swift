import Foundation
import Testing
@testable import WikiFSCore

/// Issue #281 — chat quote-anchor producer/consumer: `selectChat(anchor:)` →
/// `pendingScrollAnchor` (tagged `.chat(id)`) → `consumePendingScrollAnchor`.
/// Pure model state — no WKWebView needed. Mirrors `Phase6PinningModelTests`.
@MainActor
struct ChatQuoteAnchorModelTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-chat-quote-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, PageID) {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let chat = try store.createChat(kind: .edit, title: "Debugging the FP bug")
        model.reloadFromStore()
        return (model, chat.id)
    }

    @Test func selectChatByIDStashesAnchorTaggedToChat() throws {
        let (model, chatID) = try makeModel()
        let beforeVersion = model.pendingScrollAnchorVersion

        _ = model.selectChat(byID: chatID, anchor: #""the fix was in didDeleteItems""#)

        #expect(model.pendingScrollAnchor?.selection == .chat(chatID))
        #expect(model.pendingScrollAnchor?.fragment == #""the fix was in didDeleteItems""#)
        #expect(model.pendingScrollAnchorVersion == beforeVersion + 1)
    }

    @Test func selectChatByTitleStashesAnchor() throws {
        let (model, chatID) = try makeModel()

        _ = model.selectChat(byTitle: "Debugging the FP bug", anchor: #""the fix""#)

        #expect(model.pendingScrollAnchor?.selection == .chat(chatID))
        #expect(model.pendingScrollAnchor?.fragment == #""the fix""#)
    }

    @Test func consumeReturnsFragmentOnceForMatchingChat() throws {
        let (model, chatID) = try makeModel()
        _ = model.selectChat(byID: chatID, anchor: #""the fix""#)

        #expect(model.consumePendingScrollAnchor(for: .chat(chatID)) == #""the fix""#)
        // State cleared after one consume.
        #expect(model.pendingScrollAnchor == nil)
        #expect(model.consumePendingScrollAnchor(for: .chat(chatID)) == nil)
    }

    @Test func consumeReturnsNilForMismatchedSelection() throws {
        let (model, chatID) = try makeModel()
        _ = model.selectChat(byID: chatID, anchor: #""the fix""#)
        let otherID = PageID(rawValue: "01JAAAAAAAAAAAAAAAAAAAAAAA")

        // A non-chat (or different chat) selection doesn't consume.
        #expect(model.consumePendingScrollAnchor(for: .chat(otherID)) == nil)
        #expect(model.consumePendingScrollAnchor(for: .source(otherID)) == nil)
        // The chat's anchor survives.
        #expect(model.pendingScrollAnchor?.selection == .chat(chatID))
    }

    @Test func nilAnchorLeavesNoPendingAnchor() throws {
        let (model, chatID) = try makeModel()

        _ = model.selectChat(byID: chatID, anchor: nil)

        #expect(model.pendingScrollAnchor == nil)
        // Consume is a no-op (matches the page/source behavior: a plain link
        // click bumps the version but sets no fragment).
        #expect(model.consumePendingScrollAnchor(for: .chat(chatID)) == nil)
    }
}
