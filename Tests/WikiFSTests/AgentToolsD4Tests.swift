import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for Phase D4 — the Agent sidebar affordances.
///
/// Covers two gate points that are unit-testable without driving a real
/// `AgentLauncher` generation cycle:
///   (a) the **live-indicator predicate** (`AgentToolsView.isLiveRow`) — the
///       pure function the row reads; verified across the (activeChatID ×
///       isGenerating × chatID) matrix.
///   (b) the **rename round-trip** via `WikiStoreModel.renameChat(id:to:)` —
///       the store path the new context-menu item wires. Confirms the row's
///       title updates after rename and `reloadChats()` reflects it.
///
/// The full alert/text-field UI and the live `circle.fill` rendering are not
/// asserted here (alert presentation is not unit-testable in Swift Testing
/// without a host app); the wiring they call into is.
@MainActor
struct AgentToolsD4Tests {

    private func tempModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-d4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - (a) Live-indicator predicate

    @Test func liveIndicator_trueWhenActiveChatIDMatchesAndGenerating() {
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(AgentToolsView.isLiveRow(
            activeChatID: id.rawValue, isGenerating: true, chatID: id))
    }

    @Test func liveIndicator_falseWhenNotGenerating_evenIfChatMatches() {
        // An open-but-idle session: process alive, between turns. No badge.
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(!AgentToolsView.isLiveRow(
            activeChatID: id.rawValue, isGenerating: false, chatID: id))
    }

    @Test func liveIndicator_falseWhenChatIDDiffers_evenIfGenerating() {
        // The other chat is generating, not this one.
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        let other = "01J" + String(repeating: "B", count: 22)
        #expect(!AgentToolsView.isLiveRow(
            activeChatID: other, isGenerating: true, chatID: id))
    }

    @Test func liveIndicator_falseWhenActiveChatIDIsNil() {
        // No live session at all → persisted path, no badge.
        let id = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        #expect(!AgentToolsView.isLiveRow(
            activeChatID: nil, isGenerating: true, chatID: id))
    }

    // MARK: - (b) Rename round-trip via the model (the path the context menu wires)

    @Test func renameChat_updatesRowTitle() throws {
        let (model, store) = try tempModel()
        let chat = try store.createChat(kind: .edit, title: "Original Title")
        model.reloadChats()

        // The context menu's Rename action commits through this exact call.
        model.renameChat(id: chat.id, to: "Renamed Title")
        model.reloadChats()

        let row = model.chats.first { $0.id == chat.id }
        #expect(row?.title == "Renamed Title")
        // Also persists through the underlying store.
        let persisted = try store.listChats().first { $0.id == chat.id }
        #expect(persisted?.title == "Renamed Title")
    }

    @Test func renameChat_isIdempotentForSameTitle() throws {
        // Renaming to the current title should not error or drop the row.
        let (model, store) = try tempModel()
        let chat = try store.createChat(kind: .edit, title: "Keep Me")
        model.reloadChats()

        model.renameChat(id: chat.id, to: "Keep Me")
        model.reloadChats()

        let row = model.chats.first { $0.id == chat.id }
        #expect(row?.title == "Keep Me")
    }

    @Test func renameChat_preservesOtherChats() throws {
        // Behavior-preservation: renaming one chat must not disturb siblings.
        let (model, store) = try tempModel()
        let a = try store.createChat(kind: .edit, title: "A")
        let b = try store.createChat(kind: .edit, title: "B")
        model.reloadChats()

        model.renameChat(id: a.id, to: "A2")
        model.reloadChats()

        #expect(model.chats.first { $0.id == a.id }?.title == "A2")
        #expect(model.chats.first { $0.id == b.id }?.title == "B")
    }

    // MARK: - List order stays MRU

    @Test func chatsList_isMostRecentlyUpdatedFirst() throws {
        // The store query orders by updated_at DESC; the sidebar renders
        // store.chats as-is. Verify the model preserves that order so the most
        // recently touched chat is on top (no D4 reordering added).
        let (model, store) = try tempModel()
        let first = try store.createChat(kind: .edit, title: "First")
        // Bump `first`'s updated_at by appending a message, so it becomes the
        // most-recently-updated *after* `second` is created.
        _ = try store.appendChatMessages(chatID: first.id, events: [.userText("bump")])
        let second = try store.createChat(kind: .edit, title: "Second")
        model.reloadChats()

        // `second` was created last → newest updated_at → first in the list.
        #expect(model.chats.first?.id == second.id)
    }
}
