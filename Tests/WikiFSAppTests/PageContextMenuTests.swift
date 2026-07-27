#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSCore

/// Issue #933: right-clicking the rendered page offers Back / Forward /
/// Print Page….
///
/// These tests drive the **real** menu path — the same `NSMenu` objects AppKit
/// hands to `WikiReaderWebView.willOpenMenu(_:with:)`, seeded with WebKit's own
/// item identifiers — rather than a parallel description of it. Enabled state is
/// asserted after `NSMenu.update()`, the automatic-validation pass AppKit itself
/// runs immediately before a menu is displayed: that is what calls the items'
/// `NSMenuItemValidation` target, so it is the state the user actually sees, not
/// merely the value the builder happened to assign.
///
/// Printing is exercised through the injected `printRenderedPage` seam, so no
/// print panel is ever presented by a unit test. What the seam proves is the
/// part that can actually regress: the item is wired, fires once, and is handed
/// *this* reader's web view — i.e. the document currently on screen.
@MainActor
struct PageContextMenuTests {

    // MARK: - Fixtures

    private func tempModel() throws -> (model: WikiStoreModel, store: GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-context-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    /// A menu shaped like the one WebKit builds for a right-click on page
    /// content that isn't a link: a "Reload" item carrying WebKit's identifier,
    /// then the services group.
    private func webKitPageMenu() -> NSMenu {
        let menu = NSMenu()
        let reload = NSMenuItem(title: "Reload", action: nil, keyEquivalent: "")
        reload.identifier = NSUserInterfaceItemIdentifier(PageContextMenuNSItems.reloadIdentifier)
        menu.addItem(reload)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Look Up", action: nil, keyEquivalent: ""))
        return menu
    }

    private func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func perform(_ item: NSMenuItem) throws {
        let target = try #require(item.target)
        let action = try #require(item.action)
        _ = target.perform(action)
    }

    private func item(_ menu: NSMenu, titled title: String) throws -> NSMenuItem {
        try #require(menu.items.first { $0.title == title })
    }

    /// Records every print request and the view it was made against.
    @MainActor
    private final class PrintProbe {
        private(set) var printed: [WKWebView] = []
        var count: Int { printed.count }
        func record(_ webView: WKWebView) { printed.append(webView) }
    }

    /// Counts bare print invocations where no web view is involved.
    @MainActor
    private final class CallCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    // MARK: - Labels and order

    @Test func pageGroupIsBackForwardPrintInMenuOrder() throws {
        let (model, _) = try tempModel()
        let items = PageContextMenuNSItems.items(store: model, printPage: {})

        #expect(items.map(\.title) == ["Back", "Forward", "Print Page…"])
        // Safari's page menu shows no shortcuts on these; the app's ⌘[ / ⌘] live
        // on the toolbar chevrons, and a context menu is not where macOS
        // advertises key equivalents.
        #expect(items.allSatisfy { $0.keyEquivalent.isEmpty })
        // Every item carries its glyph, and VoiceOver has a description for it.
        #expect(items.allSatisfy { $0.image != nil })
    }

    @Test(arguments: PageContextMenuAction.allCases)
    func everyActionHasALabelAndSymbol(action: PageContextMenuAction) {
        #expect(!action.title.isEmpty)
        #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title) != nil)
    }

    @Test func insertPutsNavigationAboveReloadAndPrintInTheGroupBelow() throws {
        let (model, _) = try tempModel()
        let menu = webKitPageMenu()

        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})

        #expect(menu.items.map(\.title) == ["Back", "Forward", "Reload", "", "Print Page…", "", "Look Up"])
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[5].isSeparatorItem)
        // Back / Forward / Reload read as one navigation group — no divider
        // between the inserted items and WebKit's Reload.
        #expect(!menu.items[2].isSeparatorItem)
    }

    @Test func insertWithoutWebKitReloadStillSeparatesPrintFromNavigation() throws {
        let (model, _) = try tempModel()
        let menu = NSMenu()

        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})

        #expect(menu.items.map(\.title) == ["Back", "Forward", "", "Print Page…"])
        #expect(menu.items[2].isSeparatorItem)
    }

    // MARK: - Enabled state

    @Test func backAndForwardAreDisabledWithNoHistory() throws {
        let (model, _) = try tempModel()
        let menu = webKitPageMenu()
        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})

        // The state AppKit will show: automatic validation is on, so run it.
        #expect(menu.autoenablesItems)
        menu.update()

        #expect(try item(menu, titled: "Back").isEnabled == false)
        #expect(try item(menu, titled: "Forward").isEnabled == false)
        // Print never depends on history — there is always a rendered document.
        #expect(try item(menu, titled: "Print Page…").isEnabled)
    }

    @Test func historyEnablesBackThenForward() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()
        model.select(.page(a.id))
        model.select(.page(b.id))

        let menu = webKitPageMenu()
        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})
        menu.update()

        #expect(try item(menu, titled: "Back").isEnabled)
        #expect(try item(menu, titled: "Forward").isEnabled == false)

        model.navigateBack()
        // Re-validated on the next display pass — the same items now flip.
        menu.update()
        #expect(try item(menu, titled: "Back").isEnabled == false)
        #expect(try item(menu, titled: "Forward").isEnabled)
    }

    // MARK: - Actions

    @Test func backNavigatesExactlyOneStep() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()
        model.select(.page(a.id))
        model.select(.page(b.id))
        model.select(.page(c.id))

        let menu = webKitPageMenu()
        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})
        try perform(item(menu, titled: "Back"))

        #expect(model.selection == .page(b.id))
        #expect(model.canNavigateForward)
    }

    @Test func forwardNavigatesExactlyOneStep() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()
        model.select(.page(a.id))
        model.select(.page(b.id))
        model.navigateBack()

        let menu = webKitPageMenu()
        PageContextMenuNSItems.insert(into: menu, store: model, printPage: {})
        try perform(item(menu, titled: "Forward"))

        #expect(model.selection == .page(b.id))
        #expect(!model.canNavigateForward)
    }

    @Test func printInvokesTheInjectedActionOnce() throws {
        let (model, _) = try tempModel()
        let counter = CallCounter()
        let menu = webKitPageMenu()
        PageContextMenuNSItems.insert(into: menu, store: model, printPage: { counter.bump() })

        try perform(item(menu, titled: "Print Page…"))

        #expect(counter.count == 1)
    }

    // MARK: - The reader's own menu

    @Test func readerPageMenuMatchesSafariOrderAndKeepsShare() throws {
        let (model, store) = try tempModel()
        let page = try store.createPage(title: "A")
        model.reloadFromStore()
        let webView = WikiReaderWebView()
        webView.store = model
        webView.currentSelection = .page(page.id)

        let menu = webKitPageMenu()
        webView.addPageItems(to: menu, store: model, event: try rightClick())

        #expect(menu.items.map(\.title)
            == ["Back", "Forward", "Reload", "", "Print Page…", "Share…", "", "Look Up"])
    }

    @Test func readerPageMenuOmitsShareWithNoShareableSelection() throws {
        let (model, _) = try tempModel()
        let webView = WikiReaderWebView()
        webView.store = model
        webView.currentSelection = nil

        let menu = webKitPageMenu()
        webView.addPageItems(to: menu, store: model, event: try rightClick())

        #expect(menu.items.map(\.title) == ["Back", "Forward", "Reload", "", "Print Page…", "", "Look Up"])
    }

    @Test func printTargetsTheReaderThatWasRightClicked() throws {
        let (model, _) = try tempModel()
        let probe = PrintProbe()
        let webView = WikiReaderWebView()
        webView.store = model
        webView.printRenderedPage = { probe.record($0) }
        // A second reader (another window's) must not be the one that prints.
        let other = WikiReaderWebView()
        other.store = model
        other.printRenderedPage = { probe.record($0) }

        let menu = webKitPageMenu()
        webView.addPageItems(to: menu, store: model, event: try rightClick())
        try perform(item(menu, titled: "Print Page…"))

        #expect(probe.count == 1)
        #expect(probe.printed.first === webView)
        #expect(probe.printed.first !== other)
    }

    /// The real entry point — `willOpenMenu` — on a right-click that is not over
    /// a link. This also covers the WebKit-builtin removal and separator
    /// collapsing that run before the page group is inserted.
    @Test func willOpenMenuAddsThePageGroupOnANonLinkClick() throws {
        let (model, _) = try tempModel()
        let webView = WikiReaderWebView()
        webView.store = model

        let menu = webKitPageMenu()
        // WebKit ships these on some menus; the reader strips them.
        let download = NSMenuItem(title: "Download Linked File", action: nil, keyEquivalent: "")
        download.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadLinkedFile")
        menu.addItem(download)

        webView.willOpenMenu(menu, with: try rightClick())

        #expect(menu.items.map(\.title) == ["Back", "Forward", "Reload", "", "Print Page…", "", "Look Up"])
    }

    /// A right-click on a link is Safari's *link* menu: no Back / Forward /
    /// Print. The link items themselves are unchanged — including #925's lazy
    /// "Suggest…" submenu, which must still do no work at build time.
    @Test func linkMenuKeepsItsOwnItemsAndGainsNoPageItems() throws {
        let (model, _) = try tempModel()
        let webView = WikiReaderWebView()
        webView.store = model

        let menu = NSMenu()
        let openLink = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLink.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLink)

        webView.willOpenMenu(menu, with: try rightClick())

        let pageTitles = Set(PageContextMenuAction.allCases.map(\.title))
        #expect(menu.items.allSatisfy { !pageTitles.contains($0.title) })

        // #925: the unresolved-link menu still offers a lazy "Suggest…" submenu
        // that has not searched anything yet.
        let url = try #require(URL(string: "wiki://missing?title=Ghost"))
        let linkItems = WikiLinkMenuNSItems.items(for: url, store: model, fileProvider: nil)
        #expect(linkItems.map(\.title) == ["Suggest…"])
        let suggest = try #require(linkItems.first)
        #expect(suggest.submenu?.items.map(\.title) == ["Searching…"])
        #expect(suggest.representedObject is SimilarPagesMenuLoader)
    }
}
#endif
