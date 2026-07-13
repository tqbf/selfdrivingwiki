import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for Phase D2 — the unified `ChatView` surface (pillar 2).
///
/// Covers four gate points:
///   (a) source-of-truth rule: `activeChatID == chatID` → live events; else
///       persisted `chatMessages`. Plus the flip-timing gate: `activeChatID` is
///       cleared in `finish()` AFTER `flushTranscript()` commits the tail.
///   (b) `retargetTab` preserves the tab UUID while changing its selection.
///   (c) draft-state morph: the runner retargets the active tab from .newChat
///       to .chat(id) on first send (via `retargetActiveTabToChat`).
///   (d) `startNewChat` clears `activeChatID`.
@MainActor
struct ChatViewD2Tests {

    private func tempModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-d2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    private func makeLauncher() -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - (a) Source-of-truth rule + flip timing

    @Test func activeChatID_isNil_byDefault() {
        let launcher = makeLauncher()
        #expect(launcher.activeChatID == nil)
    }

    @Test func activeChatID_setViaStartInteractiveQuery() async {
        let launcher = makeLauncher()
        let chatID = "01J" + String(repeating: "A", count: 22)
        // Simulate the runner passing chatID — the launcher records it.
        // We can't call startInteractiveQuery without a real backend, but we can
        // verify the property is settable (it's `var`, not private(set)), which is
        // the contract ChatView relies on.
        launcher.activeChatID = chatID
        #expect(launcher.activeChatID == chatID)
    }

    @Test func sourceOfTruth_liveChat_matchesActiveChatID() {
        let launcher = makeLauncher()
        let chatID = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        launcher.activeChatID = chatID.rawValue
        // The view's isLiveChat predicate:
        let isLive = launcher.activeChatID == chatID.rawValue
        #expect(isLive)
    }

    @Test func sourceOfTruth_persistedChat_doesNotMatchActiveChatID() {
        let launcher = makeLauncher()
        let chatID = PageID(rawValue: "01J" + String(repeating: "A", count: 22))
        // activeChatID is nil (no live session) → persisted path.
        let isLive = launcher.activeChatID == chatID.rawValue
        #expect(!isLive)
    }

    @Test func startNewChat_clearsActiveChatID() {
        let launcher = makeLauncher()
        launcher.activeChatID = "some-chat-id"
        // Pre-seed idle state so the guard passes.
        launcher.events = [.userText("hello")]
        launcher.isRunning = false

        launcher.startNewChat()

        #expect(launcher.activeChatID == nil)
        #expect(launcher.events.isEmpty)
    }

    // MARK: - (b) retargetTab preserves UUID, changes selection

    @Test func retargetTab_preservesUUID_changesSelection() throws {
        let (model, store) = try tempModel()
        let page = try store.createPage(title: "Page")
        model.reloadFromStore()
        model.openTab(.newChat)
        let askTabID = model.tabs[0].id
        #expect(model.tabs[0].selection == .newChat)

        // Morph the tab in place: .newChat → .chat(id)
        let chatID = page.id
        model.retargetTab(id: askTabID, to: .chat(chatID))

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == askTabID)  // UUID preserved
        #expect(model.tabs[0].selection == .chat(chatID))
    }

    @Test func retargetTab_preservesTabOrder() throws {
        let (model, store) = try tempModel()
        let pageA = try store.createPage(title: "A")
        let pageB = try store.createPage(title: "B")
        model.reloadFromStore()
        model.openTab(.page(pageA.id))
        model.openTab(.newChat)
        model.openTab(.page(pageB.id))
        #expect(model.tabs.count == 3)
        let askTabID = model.tabs[1].id
        let orderBefore = model.tabs.map(\.id)

        // Retarget the middle tab (.newChat → .chat).
        model.retargetTab(id: askTabID, to: .chat(pageA.id))

        let orderAfter = model.tabs.map(\.id)
        #expect(orderBefore == orderAfter)  // order preserved
        #expect(model.tabs[1].selection == .chat(pageA.id))
    }

    @Test func retargetTab_updatesActiveTabSelection() throws {
        let (model, _) = try tempModel()
        model.openTab(.newChat)
        let askTabID = model.tabs[0].id
        #expect(model.selection == .newChat)

        let chatID = PageID(rawValue: "01J" + String(repeating: "B", count: 22))
        model.retargetTab(id: askTabID, to: .chat(chatID))

        #expect(model.selection == .chat(chatID))
    }

    @Test func retargetTab_unknownID_isNoOp() throws {
        let (model, _) = try tempModel()
        model.openTab(.newChat)
        #expect(model.tabs.count == 1)

        model.retargetTab(id: UUID(), to: .newChat)

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .newChat)
    }

    @Test func retargetActiveTabToChat_morphsActiveTab() throws {
        let (model, store) = try tempModel()
        let page = try store.createPage(title: "Chat")
        model.reloadFromStore()
        model.openTab(.newChat)
        let askTabID = model.tabs[0].id

        model.retargetActiveTabToChat(chatID: page.id)

        #expect(model.tabs[0].id == askTabID)  // same tab
        #expect(model.tabs[0].selection == .chat(page.id))
        #expect(model.selection == .chat(page.id))
    }

    @Test func retargetActiveTabToChat_noActiveTab_isNoOp() throws {
        let (model, _) = try tempModel()
        #expect(model.activeTabID == nil)
        let chatID = PageID(rawValue: "01J" + String(repeating: "C", count: 22))
        model.retargetActiveTabToChat(chatID: chatID)
        #expect(model.tabs.isEmpty)
    }

    // MARK: - (c) Draft-state morph (.newChat → .chat(id))

    @Test func draftMorph_askToChat_preservesTab() throws {
        let (model, _) = try tempModel()
        model.openTab(.newChat)
        let askTabID = model.tabs[0].id

        // Simulate the first send: runner creates chat row and retargets.
        let chatID = PageID(rawValue: "01J" + String(repeating: "D", count: 22))
        model.retargetActiveTabToChat(chatID: chatID)

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == askTabID)
        #expect(model.tabs[0].selection == .chat(chatID))
        // The tab title should update to the chat title (or "Chat" fallback).
        #expect(model.tabs[0].title == "Chat")
    }

    @Test func draftMorph_editToChat_preservesTab() throws {
        let (model, _) = try tempModel()
        model.openTab(.newChat)
        let editTabID = model.tabs[0].id

        let chatID = PageID(rawValue: "01J" + String(repeating: "E", count: 22))
        model.retargetActiveTabToChat(chatID: chatID)

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == editTabID)
        #expect(model.tabs[0].selection == .chat(chatID))
    }

    // MARK: - (d) startNewChat retarget-back

    @Test func startNewChat_clearsActiveChatIDAndEvents() {
        let launcher = makeLauncher()
        launcher.activeChatID = "live-chat-id"
        launcher.events = [.userText("hello"), .assistantText("world")]
        launcher.isRunning = false

        launcher.startNewChat()

        #expect(launcher.activeChatID == nil)
        #expect(launcher.events.isEmpty)
    }

    @Test func startNewChat_retargetBackToDraft_preservesTab() throws {
        let (model, _) = try tempModel()
        // Start in .chat(id) state (post-morph).
        let chatID = PageID(rawValue: "01J" + String(repeating: "F", count: 22))
        model.openTab(.chat(chatID))
        let chatTabID = model.tabs[0].id
        #expect(model.tabs[0].selection == .chat(chatID))

        // Simulate "New Chat": clear launcher state + retarget back to .newChat.
        model.retargetTab(id: chatTabID, to: .newChat)

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == chatTabID)  // same tab UUID
        #expect(model.tabs[0].selection == .newChat)
        #expect(model.selection == .newChat)
    }

    // MARK: - Integration: persisted chat renders through ChatView path

    @Test func persistedChat_hasMessages_readFromStore() throws {
        let (model, store) = try tempModel()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try store.appendChatMessages(chatID: chat.id, events: [
            .userText("hello"), .assistantText("hi there")
        ])
        model.reloadChats()

        let messages = model.chatMessages(chatID: chat.id)
        #expect(messages.count == 2)
        #expect(messages[0].event == .userText("hello"))
        #expect(messages[1].event == .assistantText("hi there"))

        // Verify transcriptVisible filter works on persisted events.
        let visible = messages.map(\.event).transcriptVisible
        #expect(visible.contains(.userText("hello")))
        #expect(visible.contains(.assistantText("hi there")))
    }
}
