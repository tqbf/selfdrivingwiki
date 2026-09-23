#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// #925: the "Suggest…" / "Find Similar…" submenu used to be filled by a
/// `DispatchSemaphore` bridge that blocked the main thread (and pinned a
/// cooperative-pool thread) on every right-click. It is now a lazy
/// `NSMenuDelegate` that searches when the submenu opens.
///
/// These tests drive the real `NSMenu`/`NSMenuItem` objects through the
/// injected-search seam, so they cover construction, the open callback, the
/// ranked/empty completions, and stale completion after a close. Waiting is
/// condition-based (`Task.yield()` until the probe records a call) or a direct
/// `await` on the loader's task — never a sleep or a wall-clock assertion.
@MainActor
struct WikiLinkMenuNSItemsTests {

    // MARK: - Fixtures

    private static func page(_ title: String, id: String) -> WikiPageSummary {
        WikiPageSummary(id: PageID(rawValue: id), title: title, updatedAt: .now, createdAt: .now)
    }

    private func tempModel() throws -> (model: WikiStoreModel, store: GRDBWikiStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-link-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    private func perform(_ item: NSMenuItem) throws {
        let target = try #require(item.target)
        let action = try #require(item.action)
        _ = target.perform(action)
    }

    /// Records every search the loader starts and holds the result until the
    /// test releases it, so "is the placeholder still up?" is decidable without
    /// racing the scheduler.
    @MainActor
    private final class SearchProbe {
        private(set) var calls: [(query: String, limit: Int)] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var result: [WikiPageSummary] = []

        /// Matches `SimilarPagesMenuLoader.Search`.
        func search(_ query: String, _ limit: Int) async -> [WikiPageSummary] {
            calls.append((query: query, limit: limit))
            if !isOpen {
                await withCheckedContinuation { gate = $0 }
            }
            return result
        }

        /// Lets the pending (and every future) search return.
        func release() {
            isOpen = true
            gate?.resume()
            gate = nil
        }
    }

    /// A loader that is open (never gated) and answers with `results`.
    private func openItem(
        title: String = "Find Similar…",
        query: String = "Alpha",
        results: [WikiPageSummary] = [],
        navigate: @escaping SimilarPagesMenuLoader.Navigate = { _ in }
    ) -> (item: NSMenuItem, probe: SearchProbe) {
        let probe = SearchProbe()
        probe.result = results
        probe.release()
        let item = WikiLinkMenuNSItems.similarPagesItem(
            title: title, query: query,
            search: { q, l in await probe.search(q, l) },
            navigate: navigate)
        return (item, probe)
    }

    private func loader(of item: NSMenuItem) throws -> SimilarPagesMenuLoader {
        try #require(item.representedObject as? SimilarPagesMenuLoader)
    }

    /// Condition-based wait: yields the main actor until `condition` holds.
    /// Bounded so a genuine hang fails the test instead of spinning forever.
    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Construction (AC.7)

    // MARK: - #1315 source-link menus

    /// A legacy `?title=`-only link whose display name carries an apostrophe
    /// (issue #1315's chat transcript). The menu action must resolve the
    /// source by display name and open it.
    @Test("Legacy source menu resolves an apostrophe title", .bug(id: 1315))
    func legacySourceMenuResolvesApostropheTitle() throws {
        let (model, store) = try tempModel()
        let source = try store.addSource(
            filename: "Consciousness doesn't overflow cognition.pdf",
            data: Data("pdf".utf8))
        model.reloadFromStore()
        let url = try #require(URL(
            string: "wiki://source?title=Consciousness%20doesn%27t%20overflow%20cognition"))

        let item = try #require(WikiLinkMenuNSItems.items(
            for: url, actions: [.openInBackgroundTab], store: model, fileProvider: nil
        ).first)
        try perform(item)

        // Empty tab bar → `openTabInBackground` falls back to the focused
        // open, so the selection is the source itself.
        #expect(model.selection == .source(source.id))
    }

    /// A canonical `?id=` link whose display alias went stale (the source was
    /// renamed after the link was written). The id must win — no name lookup —
    /// so the menu action still opens the source.
    @Test("Canonical source menu ignores a stale display alias", .bug(id: 1315))
    func canonicalSourceMenuIgnoresStaleDisplayAlias() throws {
        let (model, store) = try tempModel()
        let active = try store.createPage(title: "Active")
        let source = try store.addSource(filename: "Current title.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        model.openTab(.page(active.id))
        let url = try #require(URL(
            string: "wiki://source?id=\(source.id.rawValue)&title=Former%20title"))

        let item = try #require(WikiLinkMenuNSItems.items(
            for: url, actions: [.openInBackgroundTab], store: model, fileProvider: nil
        ).first)
        try perform(item)

        // "Former title" matches nothing; the canonical id still resolves.
        // Background open: the focused selection is unchanged, and a tab for
        // the source appears at the end of the bar.
        #expect(model.selection == .page(active.id))
        #expect(model.tabs.contains { $0.selection == .source(source.id) })
    }

    /// Builds a link menu the way AppKit presents one for a right-click:
    /// WebKit's "Open Link" item is present, our items go right after it.
    private func linkMenu() -> NSMenu {
        let menu = NSMenu()
        let openLink = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLink.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLink)
        return menu
    }

    private func rightClickEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Right-clicking a resolved source link in a chat transcript inserts the
    /// reader's tab actions after WebKit's "Open Link", and each item hands
    /// the link's URL to its callback (issue #1315).
    @Test("Chat source link menu adds the native tab actions", .bug(id: 1315))
    func chatSourceLinkMenuAddsTabActions() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var newTabURLs: [URL] = []
        var backgroundURLs: [URL] = []
        webView.onOpenInNewTab = { newTabURLs.append($0) }
        webView.onOpenInBackgroundTab = { backgroundURLs.append($0) }
        webView.hoveredLinkHref = "wiki://source?id=01JZZZZZZZZZZZZZZZZZZZZZZZ&title=Publisher"
        let menu = linkMenu()

        webView.willOpenMenu(menu, with: try rightClickEvent())

        // The inserted items sit right after WebKit's "Open Link"; a trailing
        // separator groups them apart from WebKit's Reload/Inspect items.
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Open Link", "Open in New Tab", "Open in Background"])
        #expect(menu.items.last?.isSeparatorItem == true)

        try perform(try #require(menu.items.first { $0.title == "Open in New Tab" }))
        try perform(try #require(menu.items.first { $0.title == "Open in Background" }))
        let hovered = try #require(URL(
            string: "wiki://source?id=01JZZZZZZZZZZZZZZZZZZZZZZZ&title=Publisher"))
        #expect(newTabURLs == [hovered])
        #expect(backgroundURLs == [hovered])
    }

    /// External links and unresolved (`wiki://missing`) links keep WebKit's
    /// menu — no tab actions are inserted.
    @Test("Chat menu leaves non-wiki links to WebKit", .bug(id: 1315))
    func chatMenuLeavesNonWikiLinksToWebKit() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())

        for href in ["https://example.com/post", "wiki://missing?title=Ghost"] {
            webView.hoveredLinkHref = href
            let menu = linkMenu()
            webView.willOpenMenu(menu, with: try rightClickEvent())
            #expect(menu.items.map(\.title) == ["Open Link"], "href: \(href)")
        }
    }

    @Test func menuConstructionReturnsSearchingPlaceholder() throws {
        let (item, probe) = openItem(query: "Alpha")
        let submenu = try #require(item.submenu)

        #expect(item.title == "Find Similar…")
        #expect(submenu.items.count == 1)
        #expect(submenu.items.first?.title == "Searching…")
        #expect(submenu.items.first?.isEnabled == false)
        // The whole point of #925: building the context menu does no searching.
        #expect(probe.calls.isEmpty)
        #expect(submenu.delegate is SimilarPagesMenuLoader)
    }

    @Test func emptyQueryShowsNoSimilarPagesWithoutSearching() {
        let (item, probe) = openItem(query: "")
        #expect(item.submenu?.items.map(\.title) == ["No similar pages"])
        #expect(item.submenu?.items.first?.isEnabled == false)
        #expect(probe.calls.isEmpty)
        // No loader is attached at all — there is nothing to search.
        #expect(item.representedObject == nil)
        #expect(item.submenu?.delegate == nil)
    }

    // MARK: - Opening (AC.8)

    @Test func openingSubmenuStartsOneSearch() async throws {
        let (item, probe) = openItem(query: "Alpha", results: [Self.page("Beta", id: "01B")])
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        // AppKit can call `menuNeedsUpdate(_:)` more than once per display pass.
        loader.menuNeedsUpdate(submenu)
        loader.menuNeedsUpdate(submenu)
        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        #expect(probe.calls.count == 1)
        #expect(probe.calls.first?.query == "Alpha")
        #expect(probe.calls.first?.limit == 8)

        // Reopening an already-filled submenu does not search again either.
        loader.menuNeedsUpdate(submenu)
        #expect(probe.calls.count == 1)
    }

    @Test func rankedResultsReplacePlaceholderAndNavigate() async throws {
        let ranked = [
            Self.page("First", id: "01A"),
            Self.page("Second", id: "01B"),
            Self.page("Third", id: "01C"),
        ]
        let navigated = Navigated()
        let (item, _) = openItem(query: "Alpha", results: ranked, navigate: { navigated.ids.append($0.id) })
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        // Rank order is the search's, verbatim — no placeholder left behind.
        #expect(submenu.items.map(\.title) == ["First", "Second", "Third"])

        let second = try #require(submenu.items.dropFirst().first)
        let target = try #require(second.target)
        let action = try #require(second.action)
        _ = target.perform(action)
        #expect(navigated.ids == [PageID(rawValue: "01B")])
    }

    @Test func emptyResultsShowNoSimilarPages() async throws {
        let (item, _) = openItem(query: "Alpha", results: [])
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        #expect(submenu.items.map(\.title) == ["No similar pages"])
        #expect(submenu.items.first?.isEnabled == false)
    }

    @Test func cancelledOrClosedMenuIgnoresStaleCompletion() async throws {
        let probe = SearchProbe()
        probe.result = [Self.page("First", id: "01A")]
        let navigated = Navigated()
        let item = WikiLinkMenuNSItems.similarPagesItem(
            title: "Suggest…", query: "Alpha",
            search: { q, l in await probe.search(q, l) },
            navigate: { navigated.ids.append($0.id) })
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await yieldUntil { probe.calls.count == 1 }
        // Hold the handle the loader is about to drop, so the stale completion
        // is awaitable rather than merely "probably done by now".
        let stale = try #require(loader.inFlightSearch)

        loader.menuDidClose(submenu)
        #expect(stale.isCancelled)

        probe.release()
        await stale.value

        // The dismissed submenu was not mutated by the late result.
        #expect(submenu.items.map(\.title) == ["Searching…"])
        #expect(navigated.ids.isEmpty)

        // Reopening retries from the placeholder and completes normally — the
        // stale completion did not leave the loader wedged or double-complete.
        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value
        #expect(probe.calls.count == 2)
        #expect(submenu.items.map(\.title) == ["First"])
    }

    // MARK: - Source guard (AC.7)

    @Test func wikiStoreModelHasNoSynchronousTantivyBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = root.appending(path: "Sources/WikiFSCore/Store/WikiStoreModel.swift")
        let text = try String(contentsOf: model, encoding: .utf8)

        // Doc/comment lines are excluded so the #925 rationale can name the
        // removed symbols in prose without tripping its own guard.
        let banned = ["resolveTantivyLegSync", "TantivyLegBox", "DispatchSemaphore", "semaphore.wait"]
        var offenders: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            for symbol in banned where trimmed.contains(symbol) {
                offenders.append("WikiStoreModel.swift:\(i + 1): \(symbol)")
            }
        }
        #expect(offenders.isEmpty, "#925: synchronous Tantivy bridge reappeared — \(offenders)")
    }

    /// Main-actor recorder for the navigate closure. A plain `var` captured by
    /// an escaping `@MainActor` closure would need `inout`; a reference type is
    /// the straightforward way to observe the call.
    @MainActor
    private final class Navigated {
        var ids: [PageID] = []
    }
}
#endif
