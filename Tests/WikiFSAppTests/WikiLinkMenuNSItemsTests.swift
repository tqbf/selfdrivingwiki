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
            for: url, actions: [.openInBackgroundTab],
            capabilities: .full(store: model, fileProvider: nil)
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
            for: url, actions: [.openInBackgroundTab],
            capabilities: .full(store: model, fileProvider: nil)
        ).first)
        try perform(item)

        // "Former title" matches nothing; the canonical id still resolves.
        // Background open: the focused selection is unchanged, and a tab for
        // the source appears at the end of the bar.
        #expect(model.selection == .page(active.id))
        #expect(model.tabs.contains { $0.selection == .source(source.id) })
    }

    /// AC.6: menu actions RE-RESOLVE at click time. A target deleted between
    /// right-click and click no-ops — no dead tab, no selection change.
    @Test("Menu action on a target deleted after build no-ops", .bug(id: 1315))
    func deletedTargetNoOpsAtClickTime() throws {
        let (model, store) = try tempModel()
        let active = try store.createPage(title: "Active")
        let source = try store.addSource(filename: "Ephemeral.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        model.openTab(.page(active.id))
        let url = try #require(URL(
            string: "wiki://source?id=\(source.id.rawValue)&title=Ephemeral"))

        let item = try #require(WikiLinkMenuNSItems.items(
            for: url, actions: [.openInBackgroundTab],
            capabilities: .full(store: model, fileProvider: nil)
        ).first)

        // The target vanishes after the menu is built.
        try store.deleteSource(id: source.id)
        model.reloadFromStore()

        try perform(item)

        // No dead tab opened; the focused selection is untouched.
        #expect(model.selection == .page(active.id))
        #expect(model.tabs.contains { $0.selection == .page(active.id) })
        #expect(model.tabs.count == 1)
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

    /// Right-clicking a resolved wiki link in a chat transcript with full
    /// capabilities shows the reader's parity menu: Add Bookmark… prepended,
    /// the URL-only tab actions after WebKit's "Open Link", then the bottom
    /// group Share… / Find Similar… (issue #1315).
    @Test("Chat resolved link with full capabilities gains the reader menu", .bug(id: 1315))
    func resolvedLinkGainsReaderParityMenu() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var newTabURLs: [URL] = []
        var backgroundURLs: [URL] = []
        webView.onOpenInNewTab = { newTabURLs.append($0) }
        webView.onOpenInBackgroundTab = { backgroundURLs.append($0) }
        let recorder = CapabilityRecorder()
        webView.linkMenuCapabilities = recorder.capabilities
        webView.hoveredLinkHref = "wiki://page?title=Alpha"
        let menu = linkMenu()

        webView.willOpenMenu(menu, with: try rightClickEvent())

        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Add Bookmark…", "Open Link", "Open in New Tab", "Open in Background",
            "Share…", "Find Similar…",
        ])
        // Separators: after the prepended group, after the tab group, and
        // between Share… and Find Similar… (the reader's bottom grouping).
        #expect(menu.items.filter(\.isSeparatorItem).count == 3)

        // Built items route through the host's closures.
        try perform(try #require(menu.items.first { $0.title == "Add Bookmark…" }))
        #expect(recorder.addedBookmarks.count == 1)
        try perform(try #require(menu.items.first { $0.title == "Share…" }))
        let share = try #require(recorder.shareCalls.first)
        #expect(share.url.absoluteString == "wiki://page?title=Alpha")
        #expect(share.view === webView)
    }

    /// The three link kinds the composed chat menu serves, with full
    /// capabilities: resolved links get the whole menu, unresolved links get
    /// Suggest…, external http(s) links get Add as Source.
    @Test("Chat menu parity per link kind", .bug(id: 1315))
    func chatMenuParityPerLinkKind() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.linkMenuCapabilities = CapabilityRecorder().capabilities

        webView.hoveredLinkHref = "wiki://missing?title=Ghost"
        let missingMenu = linkMenu()
        webView.willOpenMenu(missingMenu, with: try rightClickEvent())
        #expect(missingMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Suggest…", "Open Link"])

        webView.hoveredLinkHref = "https://example.com/post"
        let externalMenu = linkMenu()
        webView.willOpenMenu(externalMenu, with: try rightClickEvent())
        #expect(externalMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Add as Source", "Open Link"])

        webView.hoveredLinkHref = "wiki://page?title=Alpha"
        let resolvedMenu = linkMenu()
        webView.willOpenMenu(resolvedMenu, with: try rightClickEvent())
        #expect(resolvedMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Add Bookmark…", "Open Link", "Open in New Tab", "Open in Background",
                "Share…", "Find Similar…"])
    }

    /// AC.5: the web view reads capabilities at menu-build time, so a host
    /// that swaps the value (as `updateNSView` does on every update — e.g. an
    /// Activity row's wiki window opening or closing) retargets the menu
    /// without rebuilding the web view.
    @Test("Capabilities swap between builds retargets the menu", .bug(id: 1315))
    func capabilitySwapRetargetsMenu() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.hoveredLinkHref = "wiki://page?title=Alpha"
        webView.linkMenuCapabilities = CapabilityRecorder().capabilities
        let full = linkMenu()
        webView.willOpenMenu(full, with: try rightClickEvent())
        #expect(full.items.contains { $0.title == "Add Bookmark…" })

        // The update path (updateNSView) re-assigns this property; the next
        // right-click must reflect the new value, not a makeNSView snapshot.
        webView.linkMenuCapabilities = .none
        let none = linkMenu()
        webView.willOpenMenu(none, with: try rightClickEvent())
        #expect(none.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Open Link", "Open in New Tab", "Open in Background"])
    }

    /// Degraded host (`.none`): only the URL-only tab actions on resolved
    /// links; missing and external links keep WebKit's plain menu.
    @Test("Chat menu degrades to URL-only actions with no capabilities", .bug(id: 1315))
    func chatMenuDegradesToURLOnlyActions() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())

        webView.hoveredLinkHref = "wiki://page?title=Alpha"
        let resolvedMenu = linkMenu()
        webView.willOpenMenu(resolvedMenu, with: try rightClickEvent())
        #expect(resolvedMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Open Link", "Open in New Tab", "Open in Background"])

        for href in ["wiki://missing?title=Ghost", "https://example.com/post"] {
            webView.hoveredLinkHref = href
            let menu = linkMenu()
            webView.willOpenMenu(menu, with: try rightClickEvent())
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Open Link"],
                    "href: \(href)")
        }
    }

    /// Non-link hrefs — same-page anchors and non-http external schemes —
    /// keep WebKit's menu; no chat items are inserted.
    @Test("Chat menu leaves non-link hrefs to WebKit", .bug(id: 1315))
    func chatMenuLeavesNonLinkHrefsToWebKit() throws {
        let webView = ChatTranscriptWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.linkMenuCapabilities = CapabilityRecorder().capabilities

        for href in ["wiki://anchor#section", "mailto:someone@example.com"] {
            webView.hoveredLinkHref = href
            let menu = linkMenu()
            webView.willOpenMenu(menu, with: try rightClickEvent())
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Open Link"],
                    "href: \(href)")
        }
    }

    // MARK: - Capability seam (menu construction without a store)

    /// Records every capability-closure call. The `capabilities` value built
    /// from it contains no store anywhere — menu construction is driven by
    /// opaque closures alone.
    @MainActor
    private final class CapabilityRecorder {
        var resolvedSelections: [URL] = []
        var openedInBackground: [WikiSelection] = []
        var searchedQueries: [String] = []
        var addedURLs: [String] = []
        var addedBookmarks: [BookmarkTargetPickerContext] = []
        var shareCalls: [(url: URL, view: NSView, rect: NSRect)] = []

        private static let stubPageID = PageID(rawValue: "01JZZZZZZZZZZZZZZZZZZZZZZA")

        var capabilities: WikiLinkMenuCapabilities {
            WikiLinkMenuCapabilities(
                selection: { [weak self] url in
                    self?.resolvedSelections.append(url)
                    return .page(Self.stubPageID)
                },
                openInBackground: { [weak self] in self?.openedInBackground.append($0) },
                similarPages: { [weak self] query, _ in
                    self?.searchedQueries.append(query)
                    return []
                },
                navigateToPage: { _ in },
                sharePresent: { [weak self] url, view, rect in
                    self?.shareCalls.append((url, view, rect))
                },
                addURL: { [weak self] in self?.addedURLs.append($0) },
                addBookmark: { [weak self] in self?.addedBookmarks.append($0) })
        }
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// AC.2 golden: with every capability present, the builder's default
    /// (top-actions) output per URL kind is exactly the reader's historical
    /// menu — titles and order unchanged by the capabilities conversion.
    @Test("Golden titles per URL kind with every capability present", .bug(id: 1315))
    func goldenTitlesPerURLKind() throws {
        let recorder = CapabilityRecorder()
        let kinds: [(String, URL, [String])] = [
            ("resolved page", try url("wiki://page?title=Alpha"), ["Add Bookmark…"]),
            ("resolved source", try url("wiki://source?title=Paper"), ["Add Bookmark…"]),
            ("resolved chat", try url("wiki://chat?title=Assistant"), ["Add Bookmark…"]),
            ("missing", try url("wiki://missing?title=Ghost"), ["Suggest…"]),
            ("external", try url("https://example.com/post"), ["Add as Source"]),
            ("anchor", try url("wiki://anchor#section"), []),
        ]
        for (name, kindURL, expected) in kinds {
            #expect(
                WikiLinkMenuNSItems.items(for: kindURL, capabilities: recorder.capabilities)
                    .map(\.title) == expected,
                "\(name)")
        }
    }

    /// AC.4 omission matrix: a missing capability omits its item (never shows
    /// it inert); a capability that cannot resolve THIS link omits it too;
    /// `.none` omits everything.
    @Test("Omission matrix: absent capability omits its action", .bug(id: 1315))
    func omissionMatrix() throws {
        let resolvedPage = try url("wiki://page?title=Alpha")
        let missing = try url("wiki://missing?title=Ghost")
        let external = try url("https://example.com/post")

        func stub() -> WikiLinkMenuCapabilities { CapabilityRecorder().capabilities }

        // `.none` — nothing capability-driven survives.
        #expect(WikiLinkMenuNSItems.items(for: resolvedPage, capabilities: .none).isEmpty)
        #expect(WikiLinkMenuNSItems.items(for: missing, capabilities: .none).isEmpty)
        #expect(WikiLinkMenuNSItems.items(for: external, capabilities: .none).isEmpty)

        // No addBookmark → Add Bookmark… omitted.
        var caps = stub()
        caps.addBookmark = nil
        #expect(WikiLinkMenuNSItems.items(for: resolvedPage, capabilities: caps).isEmpty)

        // No addURL → Add as Source omitted.
        caps = stub()
        caps.addURL = nil
        #expect(WikiLinkMenuNSItems.items(for: external, capabilities: caps).isEmpty)

        // No similar search (or no navigate) → Suggest… / Find Similar… omitted.
        caps = stub()
        caps.similarPages = nil
        #expect(WikiLinkMenuNSItems.items(for: missing, capabilities: caps).isEmpty)
        caps = stub()
        caps.navigateToPage = nil
        #expect(WikiLinkMenuNSItems.items(
            for: resolvedPage, actions: [.findSimilar], capabilities: caps).isEmpty)

        // No selection → Add Bookmark… and Open in Background omitted.
        caps = stub()
        caps.selection = nil
        #expect(WikiLinkMenuNSItems.items(for: resolvedPage, capabilities: caps).isEmpty)
        #expect(WikiLinkMenuNSItems.items(
            for: resolvedPage, actions: [.openInBackgroundTab], capabilities: caps).isEmpty)

        // No openInBackground → Open in Background omitted even though the
        // link resolves.
        caps = stub()
        caps.openInBackground = nil
        #expect(WikiLinkMenuNSItems.items(
            for: resolvedPage, actions: [.openInBackgroundTab], capabilities: caps).isEmpty)

        // Capability present but THIS link is dead → omitted, not inert.
        caps = stub()
        caps.selection = { _ in nil }
        #expect(WikiLinkMenuNSItems.items(for: resolvedPage, capabilities: caps).isEmpty)
        #expect(WikiLinkMenuNSItems.items(
            for: resolvedPage, actions: [.openInBackgroundTab], capabilities: caps).isEmpty)
    }

    /// Invoking built items hands the right payloads to the injected closures.
    @Test("Capability closures receive the link's payloads", .bug(id: 1315))
    func capabilityClosuresReceivePayloads() throws {
        let recorder = CapabilityRecorder()

        let external = try url("https://example.com/post")
        let addSource = try #require(WikiLinkMenuNSItems.items(
            for: external, capabilities: recorder.capabilities).first)
        try perform(addSource)
        #expect(recorder.addedURLs == ["https://example.com/post"])

        let resolved = try url("wiki://page?title=Alpha")
        let bookmark = try #require(WikiLinkMenuNSItems.items(
            for: resolved, capabilities: recorder.capabilities).first)
        try perform(bookmark)
        let added = try #require(recorder.addedBookmarks.first)
        if case .pages(let ids) = added.targets {
            #expect(ids == [PageID(rawValue: "01JZZZZZZZZZZZZZZZZZZZZZZA")])
        } else {
            Issue.record("Add Bookmark… resolved a non-page target: \(added.targets)")
        }
        #expect(recorder.resolvedSelections.map(\.absoluteString) == [resolved.absoluteString])
    }

    /// Share… heads the bottom group, separated from the actions under it,
    /// and does NO work at menu-build time — the File Provider resolution
    /// runs only when the item is clicked (the #925 rule, Share branch).
    @Test("Share… builds from the capability with click-time-only work", .bug(id: 1315))
    func shareItemBuildsWithClickTimeWork() throws {
        let recorder = CapabilityRecorder()
        let resolved = try url("wiki://source?title=Paper")
        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let anchorRect = NSRect(x: 3, y: 4, width: 1, height: 1)

        let items = WikiLinkMenuNSItems.items(
            for: resolved, actions: WikiLinkMenuBuilder.bottomActions(for: resolved),
            capabilities: recorder.capabilities,
            anchorView: anchorView, anchorRect: anchorRect)

        let titles = items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["Share…", "—", "Find Similar…"])

        // Building the menu performs no share-presenter work.
        #expect(recorder.shareCalls.isEmpty)

        try perform(try #require(items.first))
        let call = try #require(recorder.shareCalls.first)
        #expect(call.url == resolved)
        #expect(call.view === anchorView)
        #expect(call.rect == anchorRect)
    }

    /// Without a presenter, or without anchor facts, Share… is omitted rather
    /// than shown inert; unresolved links never offer it at all.
    @Test("Share… omitted without presenter or anchor facts", .bug(id: 1315))
    func shareItemOmission() throws {
        let resolved = try url("wiki://source?title=Paper")
        let recorder = CapabilityRecorder()

        // No presenter → only Find Similar… survives, with no orphaned divider.
        var caps = recorder.capabilities
        caps.sharePresent = nil
        let noPresenter = WikiLinkMenuNSItems.items(
            for: resolved, actions: [.share, .findSimilar], capabilities: caps,
            anchorView: NSView())
        #expect(noPresenter.map { $0.isSeparatorItem ? "—" : $0.title } == ["Find Similar…"])

        // Presenter but no anchor view → the picker has nowhere to anchor.
        #expect(WikiLinkMenuNSItems.items(
            for: resolved, actions: [.share], capabilities: recorder.capabilities
        ).isEmpty)

        // Unresolved links: bottomActions carries no .share, so the dead
        // Share… item the reader once built on wiki://missing is gone.
        let missing = try url("wiki://missing?title=Ghost")
        #expect(WikiLinkMenuNSItems.items(
            for: missing, actions: WikiLinkMenuBuilder.bottomActions(for: missing),
            capabilities: recorder.capabilities, anchorView: NSView()
        ).isEmpty)
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
