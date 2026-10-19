#if os(macOS)
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import WikiFS
@testable import WikiFSCore

/// macOS 27 hides menu-item symbol images by default for apps linked
/// against the macOS 27 SDK (Apple: "By default, NSMenu hides all menu item
/// symbol images — non-symbol images remain visible"). That platform change
/// is why the sidebar row menus appeared icon-less. These suites pin the
/// sidebar menu contract: every action item carries an image forced to
/// `.visible`, the Open cluster is separated from the actions below it,
/// Delete sits after a separator, and no menu shows edge or adjacent
/// separators.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SidebarMenuIconHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private final class MenuActionProbe: NSObject {
        @objc func invoke(_ sender: NSMenuItem?) {}
    }

    // MARK: - Shared contract

    private func assertRenderableMenu(_ menu: NSMenu) {
        var previousWasSeparator = false
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                #expect(!previousWasSeparator, "adjacent separators at index \(index)")
                #expect(index > 0, "leading separator at index 0")
                #expect(index != menu.items.count - 1, "trailing separator at index \(index)")
                previousWasSeparator = true
                continue
            }
            previousWasSeparator = false
            #expect(item.image != nil, "missing image on “\(item.title)”")
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                #expect(item.preferredImageVisibility == .visible, "image not forced visible on “\(item.title)”")
            }
            #endif
            if let submenu = item.submenu {
                assertRenderableMenu(submenu)
            }
        }
    }

    private func assertSeparatedBefore(_ menu: NSMenu, title: String) throws {
        let index = try #require(menu.items.firstIndex { $0.title == title }, "missing “\(title)”")
        #expect(index > 0 && menu.items[index - 1].isSeparatorItem, "“\(title)” is not preceded by a separator")
    }

    // MARK: - Pages

    private func makePagesFixture() throws -> PagesListViewController {
        _ = Self.app
        let store = try GRDBWikiStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pages-menu-icons-\(UUID().uuidString).sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        for title in ["Alpha", "Beta", "Gamma"] {
            _ = try store.createPage(title: title)
        }
        model.reloadFromStore()

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
            onNewChat: { _ in })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = vc.view
        window.orderFront(nil)
        vc.reloadData(from: model.summaries)
        return vc
    }

    @Test("pages menu: every item renders a forced-visible image, Open cluster separated, Delete separated")
    func pagesMenuContract() throws {
        let vc = try makePagesFixture()
        vc.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        let menu = try #require(vc.menuForRow(0))
        assertRenderableMenu(menu)
        try assertSeparatedBefore(menu, title: "New Chat with Page")
        try assertSeparatedBefore(menu, title: "Delete")
    }

    @Test("pages menu: batch selection keeps the same contract")
    func pagesMenuBatchContract() throws {
        let vc = try makePagesFixture()
        vc.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let menu = try #require(vc.menuForRow(0))
        assertRenderableMenu(menu)
        try assertSeparatedBefore(menu, title: "Delete 2 Pages")
    }

    // MARK: - Sources

    private func makeSourcesFixture() throws -> SourcesListViewController {
        _ = Self.app
        let store = try GRDBWikiStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sources-menu-icons-\(UUID().uuidString).sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        for (name, byte) in [("alpha.pdf", "a"), ("beta.pdf", "b"), ("gamma.pdf", "g")] {
            _ = try store.addSource(filename: name, data: Data(byte.utf8))
        }
        model.reloadFromStore()

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
            onNewChat: { _ in })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = vc.view
        window.orderFront(nil)
        vc.reloadData(from: model.sources.filter(\.isPrimary))
        return vc
    }

    @Test("sources menu: every item renders a forced-visible image, Open cluster separated, Delete separated")
    func sourcesMenuContract() throws {
        let vc = try makeSourcesFixture()
        vc.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        let menu = try #require(vc.menuForRow(0))
        assertRenderableMenu(menu)
        try assertSeparatedBefore(menu, title: "New Chat with Source")
        try assertSeparatedBefore(menu, title: "Delete")
    }

    @Test("sources menu: batch selection keeps the same contract")
    func sourcesMenuBatchContract() throws {
        let vc = try makeSourcesFixture()
        vc.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let menu = try #require(vc.menuForRow(0))
        assertRenderableMenu(menu)
        try assertSeparatedBefore(menu, title: "Delete 2 Sources")
    }

    // MARK: - Open With submenu

    @Test("Open With submenu: app items and Other… carry forced-visible images")
    func openWithSubmenuContract() {
        let probe = MenuActionProbe()
        let submenu = OpenWithMenu.build(
            contentType: .plainText,
            target: probe,
            action: #selector(MenuActionProbe.invoke(_:)),
            payload: { _ in NSNull() })
        assertRenderableMenu(submenu)
    }
}
#endif
