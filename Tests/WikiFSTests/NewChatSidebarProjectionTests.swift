import Foundation
import Testing
@testable import WikiFSCore

/// Durable new-chat identity: `beginNewChat()` persists an empty chat row
/// BEFORE its tab opens, so the tab, the Chats-sidebar row, the first send,
/// and later navigation all share one stored `ChatID`. The tab never morphs,
/// there is no optimistic draft overlay, and empty chats are durable rows
/// that survive tab closure until the user deletes them.
///
/// The former #1223 optimistic-row contract (a model-only `ChatSummary` keyed
/// by `EditorTab.optimisticChatID`, reconciled by `retargetActiveTabToChat`)
/// is gone; these tests pin the persisted-from-creation replacement.
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

    /// A read-only store over a fully migrated DB: every write (including
    /// `createChat`) throws, which is exactly the failure `beginNewChat()`'
    /// catch path must survive. Read-only reopen mirrors the File Provider's
    /// handle (`GRDBWikiStore.init(readOnlyURL:)`).
    private func makeReadOnlyModel() throws -> (WikiStoreModel, GRDBWikiStore, URL) {
        let url = tempURL()
        _ = try GRDBWikiStore(databaseURL: url)
        let readOnly = try GRDBWikiStore(readOnlyURL: url)
        let model = WikiStoreModel(store: readOnly)
        return (model, readOnly, url)
    }

    private func activeChatID(_ model: WikiStoreModel) -> ChatID? {
        guard case .chat(let id) = model.activeTab?.selection else { return nil }
        return id
    }

    // MARK: - AC.1 Persist before opening the tab

    @Test("beginNewChat persists exactly one empty chat before opening its tab")
    func beginNewChatPersistsRowBeforeOpeningTab() throws {
        let (model, store) = try makeModel()

        model.beginNewChat()

        // The tab is a `.chat` route keyed by the STORED id — no draft state.
        let tabChatID = try #require(activeChatID(model))
        #expect(model.selection == .chat(tabChatID))

        // The sidebar carries the same row immediately (synchronous cache), and
        // the store holds exactly that row.
        #expect(model.chats.map(\.id) == [tabChatID])
        #expect(model.chats.first?.title.isEmpty == true,
                "empty title renders as \"New Chat\" in the cell")
        #expect(try store.listChats().map(\.id) == [tabChatID])

        // The persisted row becomes visible and selected in the sidebar.
        #expect(model.pendingSidebarReveal == .chat(tabChatID))

        // A fresh tab for a fresh chat: isEditing is off, title falls back.
        #expect(model.activeTab?.title == "Chat")
    }

    @Test("beginNewChat failure shows the store error and opens no tab")
    func beginNewChatFailureShowsStoreErrorAndOpensNoTab() throws {
        let (model, readOnly, _) = try makeReadOnlyModel()

        // The double's own failure detail, captured from the same store.
        let doubleDetail: String = {
            do {
                _ = try readOnly.createChat(kind: .edit, title: "must fail")
                return "createChat unexpectedly succeeded"
            } catch {
                return error.localizedDescription
            }
        }()

        // A failed creation must not leak an omnibox prefill question into a
        // later, unrelated chat.
        model.beginNewChat(prefill: "stale question")

        let storeError = try #require(model.storeError, "the failure must surface the store error alert")
        #expect(storeError.title == "Could Not Create Chat")
        #expect(storeError.message.contains(doubleDetail),
                "the alert message must carry the store failure detail")

        // No phantom tab, no sidebar row, no reveal, no selection, no prefill.
        #expect(model.tabs.isEmpty)
        #expect(model.chats.isEmpty)
        #expect(model.pendingSidebarReveal == nil)
        #expect(model.selection == nil)
        #expect(model.pendingChatQuestion == nil)
    }

    @Test("beginNewChat installs the prefill only after the store write succeeds")
    func beginNewChatPrefillInstallsAfterPersistence() throws {
        let (model, store) = try makeModel()

        model.beginNewChat(prefill: "Explain the venturi effect")

        let chatID = try #require(activeChatID(model))
        #expect(model.pendingChatQuestion == "Explain the venturi effect")
        #expect(try store.listChats().map(\.id) == [chatID])
    }

    // MARK: - AC.2 Resolve the durable row after navigation

    @Test("new chat resolves from the store after switching to a page and back")
    func newChatResolvesAfterSwitchingToPageAndBack() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))
        let page = try store.createPage(title: "A Page")
        model.reloadFromStore()

        // Switch to the page tab, then back to the chat.
        model.openTab(.page(page.id))
        #expect(model.selection == .page(page.id))
        model.openTab(.chat(chatID))

        // The same stored identity resolves authoritatively from SQLite —
        // never a "Chat Deleted" state for a live row.
        #expect(model.selection == .chat(chatID))
        #expect(model.resolveChat(id: chatID) == .available(try store.getChat(id: chatID)))
        #expect(model.chats.contains { $0.id == chatID })
    }

    // MARK: - AC.7 Empty chats are durable resources

    @Test("closing an empty chat tab keeps the persisted row")
    func closingEmptyChatTabKeepsPersistedRow() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))
        let tabID = try #require(model.activeTabID)

        model.closeTab(id: tabID)

        #expect(model.tabs.isEmpty)
        // The row stays: closing a tab never deletes the chat.
        #expect(try store.listChats().map(\.id) == [chatID])
        #expect(model.chats.map(\.id) == [chatID])
    }

    @Test("reopening an empty chat from the sidebar uses the same stored ID")
    func reopeningEmptyChatUsesSameID() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))
        // Consume the creation-time reveal so the reopen assertions observe
        // only NEW reveal requests.
        model.consumePendingSidebarReveal()
        model.closeTab(id: try #require(model.activeTabID))

        model.openTab(.chat(chatID))

        #expect(model.selection == .chat(chatID))
        #expect(activeChatID(model) == chatID)
        #expect(model.resolveChat(id: chatID) != .notFound)
        #expect(model.pendingSidebarReveal == nil,
                "plain tab opens do not request a Show-In-List reveal")
        _ = store
    }

    // MARK: - AC.8 Repeated commands create distinct durable chats

    @Test("multiple new chats create distinct persisted rows and tabs")
    func multipleNewChatsCreateDistinctPersistedRowsAndTabs() throws {
        let (model, store) = try makeModel()

        model.beginNewChat()
        let firstID = try #require(activeChatID(model))
        let firstTabID = try #require(model.activeTabID)
        // Guarantee distinct updatedAt timestamps for the ordering assertion.
        model.beginNewChat()
        let secondID = try #require(activeChatID(model))
        let secondTabID = try #require(model.activeTabID)

        #expect(firstID != secondID)
        #expect(firstTabID != secondTabID)
        #expect(model.tabs.map(\.selection) == [.chat(firstID), .chat(secondID)])
        // Two store rows, newest first, matching the tabs.
        #expect(try store.listChats().map(\.id) == [secondID, firstID])
        #expect(model.chats.map(\.id) == [secondID, firstID])
    }

    // MARK: - Sidebar projection after external writes

    @Test("an external store refresh keeps every persisted chat row visible")
    func externalRefreshKeepsPersistedRows() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))

        // A wikictl/agent write lands; the change bridge fires reloadFromStore.
        let external = try store.createChat(kind: .edit, title: "Written externally")
        model.reloadFromStore()

        #expect(model.chats.map(\.id) == [external.id, chatID],
                "most-recent-first, no overlay merging, no duplicates")
        #expect(try store.listChats().count == 2)
    }

    @Test("the first send titles the untouched empty chat without re-creating a row")
    func firstSendTitlesTheUntouchedEmptyChat() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))

        // The daemon's first-send title write (one conditional UPDATE).
        let titled = try store.setChatTitleIfEmpty(
            chatID: chatID,
            title: ChatSummary.title(fromFirstMessage: "What is a wiki link?\nSecond line"))
        #expect(titled)
        model.reloadFromStore()

        // Same identity, same single row, new title.
        #expect(activeChatID(model) == chatID)
        #expect(try store.listChats().map(\.id) == [chatID])
        #expect(model.chats.first?.title == "What is a wiki link?")
        #expect(model.chats.count == 1)
    }

    @Test("a manual rename before the first send is never overwritten by the title write")
    func manualRenameBeforeFirstSendIsPreserved() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))

        model.renameChat(id: chatID, to: "My rename")
        let titled = try store.setChatTitleIfEmpty(
            chatID: chatID,
            title: ChatSummary.title(fromFirstMessage: "first message"))
        #expect(titled == false, "the conditional update matches no row")

        #expect(try store.getChat(id: chatID).title == "My rename")
    }

    // MARK: - AC.9 Pre-send selections survive back-to-back picks

    /// The composer selectors derive each write from the model's `chats`
    /// projection. A provider pick followed immediately by a thinking pick
    /// (no await between them) must not clobber the first choice through a
    /// stale projection — `updateChatModelAndThinkingSelection` refreshes the
    /// cache synchronously after the store write.
    @Test("back-to-back provider and thinking picks both survive")
    func backToBackSelectionsDoNotClobber() throws {
        let (model, store) = try makeModel()
        model.beginNewChat()
        let chatID = try #require(activeChatID(model))
        let configured = ChatConfigurationValueID(rawValue: "high")

        // Pick 1: the provider (ProviderSelector.selectRow's durable path).
        model.updateChatModelAndThinkingSelection(
            chatID: chatID,
            providerID: ProviderID(rawValue: "acme"),
            modelID: ModelID(rawValue: "acme-1"),
            configuredThinkingID: nil,
            effectiveThinkingID: nil)
        // The projection reflects the write NOW (no await).
        let afterProvider = try #require(model.chats.first { $0.id == chatID })
        #expect(afterProvider.modelProviderId == ProviderID(rawValue: "acme"))

        // Pick 2: the thinking selector derives provider/model from the
        // projection, exactly as ThinkingEffortSelector.select does.
        let summary = try #require(model.chats.first { $0.id == chatID })
        model.updateChatModelAndThinkingSelection(
            chatID: chatID,
            providerID: summary.modelProviderId,
            modelID: summary.modelId,
            configuredThinkingID: configured,
            effectiveThinkingID: configured)

        // Both choices survive in the STORE row the daemon's first turn reads.
        let row = try store.getChat(id: chatID)
        #expect(row.modelProviderId == ProviderID(rawValue: "acme"))
        #expect(row.modelId == ModelID(rawValue: "acme-1"))
        #expect(row.configuredThinkingOptionID == configured)
        #expect(row.effectiveThinkingOptionID == configured)
    }
}
