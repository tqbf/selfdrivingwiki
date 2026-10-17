#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Operator-visible menu contract for the "New Chat with …" selection actions
/// (create-chat-with-attachments, AC.1/AC.2/AC.6): exact titles, icon, enabled
/// state, placement, inside/outside-selection semantics, and the window
/// behavior (active tab of the host window, never a new window).
///
/// The menus are built by the real `menuForRow(_:)` of the real AppKit view
/// controllers against a real temp-file store, and the actions are invoked
/// through AppKit's own target/action plumbing — the same path a right-click
/// takes — with the container's production callback wiring.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct PagesNewChatMenuHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func makeFixture() throws -> (model: WikiStoreModel, vc: PagesListViewController, window: NSWindow, ids: [PageID], storeURL: URL) {
        _ = Self.app
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pages-menu-\(UUID().uuidString).sqlite")
        let store = try GRDBWikiStore(databaseURL: storeURL)
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        for title in ["Alpha", "Beta", "Gamma"] {
            _ = try store.createPage(title: title)
        }
        model.reloadFromStore()
        let ids = model.summaries.map(\.id)

        let vc = PagesListViewController()
        vc.store = model
        vc.callbacks = PagesListCallbacks(
            onOpen: { _ in },
            onOpenExternal: { _, _ in },
            onOpenBackground: { _ in },
            onShare: { _ in },
            onReveal: { _ in },
            onLint: { _ in },
            onRename: { _ in },
            onDelete: { _ in },
            onSetHomePage: { _ in },
            onAddToBookmarks: { _ in },
            onNewChat: { ids in
                model.beginNewChat(attachments: ChatAttachmentTarget.pages(ids))
            })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = vc.view
        window.orderFront(nil)
        vc.reloadData(from: model.summaries)
        return (model, vc, window, ids, storeURL)
    }

    private func select(_ vc: PagesListViewController, _ rows: [Int]) {
        vc.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    private func newChatItem(in menu: NSMenu, titled expected: String) throws -> NSMenuItem {
        let item = try #require(menu.items.first { $0.title == expected }, "missing item \(expected)")
        return item
    }

    private func activeChatID(_ model: WikiStoreModel) -> ChatID? {
        guard case .chat(let id) = model.activeTab?.selection else { return nil }
        return id
    }

    @Test("single selection offers the exact item: title, icon, enabled, placement")
    func pagesMenuOffersSingularItem() throws {
        let (model, vc, _, _, _) = try makeFixture()
        select(vc, [0])

        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with Page")
        #expect(item.accessibilityIdentifier() == "plus.bubble")
        #expect(item.isEnabled)

        let bookmarksIndex = try #require(menu.items.firstIndex { $0.title == "Add to Bookmarks…" })
        let chatIndex = try #require(menu.items.firstIndex { $0 === item })
        #expect(chatIndex == bookmarksIndex - 1, "the item joins the open cluster")
        _ = model
    }

    @Test("batch selection offers the count-prefixed title")
    func pagesMenuOffersBatchTitle() throws {
        let (_, vc, _, _, _) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(0))
        _ = try newChatItem(in: menu, titled: "New Chat with 2 Pages")
    }

    @Test("right-click inside the selection acts on the whole selection in row order")
    func pagesMenuActsOnWholeSelectionWhenClickedInside() throws {
        let (model, vc, _, ids, storeURL) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with 2 Pages")

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        // The composed write persisted the ordered rows; a fresh model over
        // the same DB restores them (restart half of the proof).
        #expect(model.chatAttachments(chatID: chatID) == [.page(ids[0]), .page(ids[1])])
        let freshStore = try GRDBWikiStore(databaseURL: storeURL)
        freshStore.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        #expect(try freshStore.chatAttachments(chatID: chatID) == [.page(ids[0]), .page(ids[1])])
    }

    @Test("right-click outside the selection acts on the clicked row only")
    func pagesMenuActsOnClickedRowOnlyWhenClickedOutside() throws {
        let (model, vc, _, ids, _) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(2))
        let item = try newChatItem(in: menu, titled: "New Chat with Page")

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        #expect(model.chatAttachments(chatID: chatID) == [.page(ids[2])])
    }

    @Test("the action keeps the host window and opens the chat as its active tab")
    func newChatStaysInHostWindow() throws {
        let (model, vc, window, ids, _) = try makeFixture()
        select(vc, [0])
        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with Page")

        let windowsBefore = NSApp.windows
        #expect(windowsBefore.contains { $0 === window })

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        let windowsAfter = NSApp.windows
        #expect(windowsAfter.contains { $0 === window }, "host window identity unchanged")
        #expect(windowsAfter.count == windowsBefore.count, "no additional product window")
        #expect(model.activeTab?.selection == .chat(chatID), "the new chat is the active tab")
        _ = ids
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SourcesNewChatMenuHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func makeFixture() throws -> (model: WikiStoreModel, vc: SourcesListViewController, window: NSWindow, ids: [SourceID]) {
        _ = Self.app
        let store = try GRDBWikiStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sources-menu-\(UUID().uuidString).sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        for (name, byte) in [("alpha.pdf", "a"), ("beta.pdf", "b"), ("gamma.pdf", "g")] {
            _ = try store.addSource(filename: name, data: Data(byte.utf8))
        }
        model.reloadFromStore()
        let ids = model.sources.filter(\.isPrimary).map(\.id)

        let vc = SourcesListViewController()
        vc.store = model
        vc.callbacks = SourcesListCallbacks(
            onOpen: { _ in },
            onOpenExternal: { _, _ in },
            onOpenBackground: { _ in },
            onShare: { _ in },
            onReveal: { _ in },
            onIngest: { _ in },
            onIngestNeedsConfirmation: { _, _ in },
            onExtract: { _ in },
            onShowRunningJob: { _, _ in },
            onRename: { _ in },
            onDelete: { _ in },
            onAddToBookmarks: { _ in },
            onNewChat: { ids in
                model.beginNewChat(attachments: ChatAttachmentTarget.sources(ids))
            })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = vc.view
        window.orderFront(nil)
        vc.reloadData(from: model.sources.filter(\.isPrimary))
        return (model, vc, window, ids)
    }

    private func select(_ vc: SourcesListViewController, _ rows: [Int]) {
        vc.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    private func newChatItem(in menu: NSMenu, titled expected: String) throws -> NSMenuItem {
        let item = try #require(menu.items.first { $0.title == expected }, "missing item \(expected)")
        return item
    }

    private func activeChatID(_ model: WikiStoreModel) -> ChatID? {
        guard case .chat(let id) = model.activeTab?.selection else { return nil }
        return id
    }

    @Test("single selection offers the exact item: title, icon, enabled, placement")
    func sourcesMenuOffersSingularItem() throws {
        let (model, vc, _, _) = try makeFixture()
        select(vc, [0])

        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with Source")
        #expect(item.accessibilityIdentifier() == "plus.bubble")
        #expect(item.isEnabled)

        let bookmarksIndex = try #require(menu.items.firstIndex { $0.title == "Add to Bookmarks…" })
        let chatIndex = try #require(menu.items.firstIndex { $0 === item })
        #expect(chatIndex == bookmarksIndex - 1, "the item joins the open cluster")
        _ = model
    }

    @Test("batch selection offers the count-prefixed title")
    func sourcesMenuOffersBatchTitle() throws {
        let (_, vc, _, _) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(0))
        _ = try newChatItem(in: menu, titled: "New Chat with 2 Sources")
    }

    @Test("right-click inside the selection acts on the whole selection in row order")
    func sourcesMenuActsOnWholeSelectionWhenClickedInside() throws {
        let (model, vc, _, ids) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with 2 Sources")

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        #expect(model.chatAttachments(chatID: chatID) == [.source(ids[0]), .source(ids[1])])
    }

    @Test("right-click outside the selection acts on the clicked row only")
    func sourcesMenuActsOnClickedRowOnlyWhenClickedOutside() throws {
        let (model, vc, _, ids) = try makeFixture()
        select(vc, [0, 1])
        let menu = try #require(vc.menuForRow(2))
        let item = try newChatItem(in: menu, titled: "New Chat with Source")

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        #expect(model.chatAttachments(chatID: chatID) == [.source(ids[2])])
    }

    @Test("the action keeps the host window and opens the chat as its active tab")
    func newChatStaysInHostWindow() throws {
        let (model, vc, window, _) = try makeFixture()
        select(vc, [0])
        let menu = try #require(vc.menuForRow(0))
        let item = try newChatItem(in: menu, titled: "New Chat with Source")

        let windowsBefore = NSApp.windows
        #expect(windowsBefore.contains { $0 === window })

        _ = item.target?.perform(item.action, with: item)

        let chatID = try #require(activeChatID(model))
        let windowsAfter = NSApp.windows
        #expect(windowsAfter.contains { $0 === window }, "host window identity unchanged")
        #expect(windowsAfter.count == windowsBefore.count, "no additional product window")
        #expect(model.activeTab?.selection == .chat(chatID), "the new chat is the active tab")
    }
}
#endif
