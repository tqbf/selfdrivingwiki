#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSCore

/// Issue #933, live-UI half: the Back / Forward / Print Page… group appears on
/// the reader SwiftUI actually mounts, not just on a `WikiReaderWebView` a unit
/// test constructed by hand.
///
/// The gap this closes is the wiring, not the menu logic: `WikiReaderRep` is what
/// injects the window's store and the current selection into the web view
/// (`makeNSView` / `updateNSView`), and a menu built before that injection would
/// bail with "store is nil". So the test mounts the real `WikiReaderView` in an
/// `NSWindow`, finds the web view SwiftUI created, and runs the genuine
/// `willOpenMenu(_:with:)` entry point against it.
///
/// See `docs/skills/reproducing-live-ui-bugs` for the hosted-view pattern, and
/// `PageContextMenuTests` for the menu's own behavior.
@MainActor
struct PageContextMenuHostedTests {

    /// An `NSHostingController` in a `swift test` CLI has no host app, so give
    /// AppKit one to lay out into (same pattern as `PageDetailViewHostedTests`).
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func tempModel() throws -> (model: WikiStoreModel, store: GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-menu-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    private func readerWebView(in view: NSView) -> WikiReaderWebView? {
        if let reader = view as? WikiReaderWebView { return reader }
        for subview in view.subviews {
            if let reader = readerWebView(in: subview) { return reader }
        }
        return nil
    }

    @Test func mountedReaderOffersBackForwardAndPrint() async throws {
        // This mounts a live NSWindow + WKWebView in the single `swift test`
        // host process, same as every sibling hosted suite — without this
        // lease it can overlap with another window-owning suite (e.g. the
        // Editor/Composer autocomplete or QuoteHighlight suites) and wedge
        // the shared AppKit/WebKit environment (see AutocompleteHostedTestGate.swift).
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()
        model.select(.page(a.id))
        model.select(.page(b.id))

        let hosting = NSHostingController(
            rootView: WikiReaderView(markdown: "# B\n\nBody text.",
                                     currentSelection: .page(b.id),
                                     store: model))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // The web view mounts asynchronously after the first SwiftUI render.
        // Condition-based wait, bounded so a genuine hang fails rather than spins.
        var reader: WikiReaderWebView?
        for _ in 0..<200 {
            if let found = readerWebView(in: hosting.view), found.store != nil {
                reader = found
                break
            }
            await Task.yield()
        }
        let webView = try #require(reader, "WikiReaderView never mounted a WikiReaderWebView")

        let printed = PrintRecorder()
        webView.printRenderedPage = { printed.record($0) }

        // WebKit's non-link page menu, and the real entry point AppKit calls.
        let menu = NSMenu()
        let reload = NSMenuItem(title: "Reload", action: nil, keyEquivalent: "")
        reload.identifier = NSUserInterfaceItemIdentifier(PageContextMenuNSItems.reloadIdentifier)
        menu.addItem(reload)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        webView.willOpenMenu(menu, with: event)

        #expect(menu.items.map(\.title).prefix(3) == ["Back", "Forward", "Reload"])
        #expect(menu.items.contains { $0.title == "Print Page…" })

        // Two pages deep in this window's history: Back is live, Forward is not.
        menu.update()
        let back = try #require(menu.items.first { $0.title == "Back" })
        let forward = try #require(menu.items.first { $0.title == "Forward" })
        #expect(back.isEnabled)
        #expect(forward.isEnabled == false)

        // Print goes to the reader that was right-clicked — the one SwiftUI
        // mounted for this window — rather than any other web view in process.
        let printItem = try #require(menu.items.first { $0.title == "Print Page…" })
        let target = try #require(printItem.target)
        let action = try #require(printItem.action)
        _ = target.perform(action)
        #expect(printed.views.count == 1)
        #expect(printed.views.first === webView)

        // And Back moves this window's store exactly one step.
        let backTarget = try #require(back.target)
        let backAction = try #require(back.action)
        _ = backTarget.perform(backAction)
        #expect(model.selection == .page(a.id))
    }

    /// Records the web views handed to the print seam. A reference type so the
    /// escaping `@MainActor` closure can report back without `inout` capture.
    @MainActor
    private final class PrintRecorder {
        private(set) var views: [WKWebView] = []
        func record(_ webView: WKWebView) { views.append(webView) }
    }
}
#endif
