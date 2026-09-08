import Foundation
import Testing
@testable import WikiFSCore

/// Regression coverage for #1223 — creating a new chat must surface a row in
/// the Chats sidebar immediately, with a stable identity, and reconcile it
/// without duplication when the daemon commits the real `ChatSummary` on the
/// first send.
///
/// The optimistic row is model-only: `beginNewChat()` inserts a
/// `ChatSummary` into `store.chats` (never into the SQLite store), owned by
/// the draft tab via `EditorTab.optimisticChatID`. `reloadChats()` re-merges
/// the overlay on every refresh, and the draft→persisted morph
/// (`retargetActiveTabToChat`) drops it in favor of the real row.
@MainActor
struct NewChatSidebarProjectionTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("new-chat-sidebar-\(UUID().uuidString).sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        return (model, store)
    }

    @Test("beginNewChat projects a row immediately without persisting a chat")
    func beginNewChatProjectsOptimisticRow() throws {
        let (model, store) = try makeModel()

        model.beginNewChat()

        // The sidebar list carries exactly one row during the same flow.
        #expect(model.chats.count == 1)
        let row = try #require(model.chats.first)
        #expect(row.title.isEmpty, "empty title renders as \"New Chat\" in the cell")

        // The row's identity is the draft tab's stable optimisticChatID.
        guard case .newChat = model.selection else {
            Issue.record("expected .newChat selection")
            return
        }
        #expect(model.activeTab?.optimisticChatID == row.id)

        // Nothing was persisted — the daemon owns row creation on first send.
        #expect(try store.listChats().isEmpty)
        #expect(model.pendingDraftChats.map(\.id) == [row.id])
    }

    @Test("The optimistic row sorts above older persisted chats")
    func optimisticRowSortsFirst() throws {
        let (model, store) = try makeModel()

        // A persisted chat from "earlier" (the daemon commits with a fresh
        // updated_at; seed one and backdate the projection via a reload).
        _ = try store.createChat(kind: .edit, title: "Earlier chat")
        model.reloadChats()
        #expect(model.chats.count == 1)

        model.beginNewChat()

        #expect(model.chats.count == 2)
        #expect(model.chats.first?.title.isEmpty == true, "the fresh draft row leads")
        #expect(model.chats.last?.title == "Earlier chat")
    }

    @Test("First-send reconciliation replaces the draft row without duplication")
    func firstSendReconcilesWithoutDuplicate() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let draftRowID = try #require(model.chats.first?.id)

        // The daemon commits the chat on the first send and returns its ID.
        let committed = try store.createChat(kind: .edit, title: "Hello world")
        model.retargetActiveTabToChat(chatID: committed.id)

        // Exactly one row — the real one — and no leftover draft row.
        #expect(model.chats.map(\.id) == [committed.id])
        #expect(model.chats.allSatisfy { $0.title == "Hello world" })
        #expect(model.pendingDraftChats.isEmpty)
        #expect(draftRowID != committed.id)

        // The tab morphed to the committed chat, and the sidebar was asked
        // to reveal (select + scroll to) the committed row.
        #expect(model.selection == .chat(committed.id))
        #expect(model.pendingSidebarReveal == .chat(committed.id))

        // The store holds exactly the committed row — no ghost persisted.
        #expect(try store.listChats().map(\.id) == [committed.id])
    }

    @Test("Closing a draft tab drops its optimistic row and persists nothing")
    func closingDraftTabDropsRow() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        #expect(model.chats.count == 1)
        let tabID = try #require(model.activeTabID)

        model.closeTab(id: tabID)

        #expect(model.chats.isEmpty)
        #expect(model.pendingDraftChats.isEmpty)
        #expect(try store.listChats().isEmpty)
    }

    @Test("An external store refresh keeps the open draft's row visible")
    func externalRefreshKeepsDraftRow() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let draftRowID = try #require(model.activeTab?.optimisticChatID)

        // A wikictl/agent write lands; the change bridge fires reloadFromStore.
        _ = try store.createChat(kind: .edit, title: "Written externally")
        model.reloadFromStore()

        // Both the real row and the still-open draft row are projected.
        #expect(model.chats.count == 2)
        #expect(model.chats.contains { $0.id == draftRowID })
        #expect(model.chats.contains { $0.title == "Written externally" })
    }

    @Test("Multiple open drafts each get their own row, newest first")
    func multipleDraftsGetMultipleRows() throws {
        let (model, _) = try makeModel()

        model.beginNewChat()
        let firstRowID = try #require(model.activeTab?.optimisticChatID)
        // Guarantee distinct updatedAt timestamps for the ordering assertion.
        model.beginNewChat()
        let secondRowID = try #require(model.activeTab?.optimisticChatID)

        #expect(firstRowID != secondRowID)
        #expect(model.chats.count == 2)
        #expect(model.chats.first?.id == secondRowID, "the newest draft leads")
        #expect(Set(model.chats.map(\.id)) == [firstRowID, secondRowID])
    }

    @Test("A title derived from the first message replaces the draft title")
    func firstMessageTitleReplacesDraftTitle() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()

        // The daemon derives the title from the first message at commit time;
        // mirror that commit and reconcile exactly as the app does.
        let title = ChatSummary.title(fromFirstMessage: "What is a wiki link?\nSecond line")
        let committed = try store.createChat(kind: .edit, title: title)
        model.retargetActiveTabToChat(chatID: committed.id)

        #expect(model.chats.map(\.title) == [title])
        #expect(model.chats.count == 1)
    }
}
