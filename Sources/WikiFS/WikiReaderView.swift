import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import WikiFSCore

// MARK: - WikiReaderView

/// Renders markdown in a `WKWebView` via `MarkdownHTMLRenderer` — the single
/// reader for every markdown surface in the app (pages, sources, system prompt,
/// changelog). It replaces the vendored Textual reader (`MarkdownPreview`): the
/// browser's windowed layout sidesteps the whole-document layout freeze on large
/// docs, and WKWebView ships whole-link selection + a native context menu for
/// free (the fork Textual carried solely to get those).
///
/// Loads **asynchronously**: the page chrome appears immediately with a spinner,
/// and the footnote/link pre-pass + swift-markdown render run off the main actor.
/// Ghost-link resolution needs the store, which is `@MainActor`, so existence
/// sets are computed on the main actor before the convert task and passed in —
/// letting a missing `[[Ghost]]` render red via a single CSS rule.
///
/// **Anchors + quote highlight:** a `[[source:Name#Section]]` /
/// `[[Page#"quote"]]` link (set via `selectPage(anchor:)` /
/// `selectSource(anchor:)`) is consumed from the store's pending-anchor path,
/// resolved with the shared `AnchorBlock.parse` + `resolveAnchor`, then applied
/// after the page paints — scroll to the heading's slug `id` for a section
/// anchor, or `window.find` + `<mark>` for a quote highlight (with a
/// whitespace-tolerant TreeWalker fallback).
struct WikiReaderView: View {
    let markdown: String
    var currentSelection: WikiSelection? = nil
    let store: WikiStoreModel
    /// The File Provider spike, for "Copy File Path" on wiki links. Only page
    /// readers (which own a spike) pass it; `nil` elsewhere omits that item.
    var fileProvider: FileProviderSpike? = nil
    /// Opens the "Add from URL" sheet pre-filled with a URL — injected via the
    /// `\.addURLHandler` environment value, feeding the http(s) "Add as Source"
    /// context-menu item through `WikiLinkMenuNSItems`.
    @Environment(\.addURLHandler) private var addURLHandler
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @State private var isLoading = true

    /// Find bar: when set, the matched text is passed to the web view for
    /// `window.find()` highlighting and scrolling.
    var findText: String? = nil
    var findVersion: Int = 0
    /// 1-based index of the current match (`FindModel.currentMatchIndex`).
    /// `applyFind` advances `window.find()` this many times so next/previous
    /// navigation lands on distinct matches instead of always the first.
    var findOccurrence: Int = 1

    var body: some View {
        ZStack {
            WikiReaderRep(markdown: markdown,
                          store: store,
                          fileProvider: fileProvider,
                          readerZoom: readerZoom,
                          currentSelection: currentSelection,
                          anchorVersion: store.pendingScrollAnchorVersion,
                          isLoading: $isLoading,
                          addURLHandler: addURLHandler,
                          findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    /// Resolve a consumed anchor fragment to a scroll target: a section anchor
    /// scrolls to the heading's slug id; anything else (a `[[…#"quote"]]` or an
    /// unresolved fragment) becomes a quote highlight. Mirrors the reader's
    /// heading-vs-quote split. Pure — unit-tested.
    ///
    /// `nonisolated`: it touches no actor state, but `WikiReaderView` is a `View`
    /// (its members inherit main-actor isolation). Without this the unit tests
    /// — which run off the main actor — trip a `dispatch_assert_queue_fail`.
    nonisolated static func resolveScrollTarget(_ fragment: String, blocks: [AnchorBlock]) -> PendingScroll? {
        if let id = resolveAnchor(fragment, in: blocks),
           blocks.contains(where: { $0.id == id && $0.kind == .heading }) {
            return .heading(slug: id)
        }
        let quote = fragment.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return quote.isEmpty ? nil : .quote(quote)
    }

    /// Classify a clicked `wiki://` (or same-page anchor) URL into a routing
    /// action, using the proven query-based helpers from `WikiLinkMarkdown`
    /// (`target`/`fragment`/`resolvedKind`/`isSamePageAnchor`). Pure — unit-tested.
    ///
    /// This replaces the old `comps.path` extraction, which read `""` for the
    /// query-encoded `wiki://page?title=…` URLs `WikiLinkMarkdown` emits (no path
    /// component), silently no-op'ing every wiki-link click.
    nonisolated static func linkRoute(for url: URL) -> WikiLinkRoute {
        if WikiLinkMarkdown.isSamePageAnchor(url) {
            return .samePageAnchor(fragment: WikiLinkMarkdown.fragment(from: url))
        }
        guard let title = WikiLinkMarkdown.target(from: url) else { return .inert }
        let frag = WikiLinkMarkdown.fragment(from: url)
        switch WikiLinkMarkdown.resolvedKind(from: url) {
        case .page:   return .page(title: title, fragment: frag)
        case .source: return .source(title: title, fragment: frag)
        case nil:     return .inert
        }
    }

    /// Build an `onWikiLink` closure that routes a clicked `wiki://` link to the
    /// store — navigate to the page/source, carrying any `#fragment`. Same-page
    /// anchors are inert here: this powers the agent transcript (a chat feed,
    /// not a single document), so `[[#anchor]]` has no document to scroll within.
    ///
    /// Built where the store lives (and the navigation detail column is wired)
    /// and forwarded unchanged down through the intermediate views to
    /// `AgentTranscriptWebView`. Pass `nil` where navigation is impossible.
    @MainActor
    static func onWikiLinkHandler(for store: WikiStoreModel) -> (URL) -> Void {
        { url in
            switch WikiReaderView.linkRoute(for: url) {
            case .page(let title, let frag):   store.selectPage(byTitle: title, anchor: frag)
            case .source(let title, let frag): store.selectSource(byDisplayName: title, anchor: frag)
            case .samePageAnchor, .inert:      break
            }
        }
    }

    /// One-shot loader for the vendored Mermaid library. Reads the bundled
    /// `mermaid.js` once and caches it; `nil` when unbundled (e.g. `swift test`,
    /// `swift run` without `./build.sh`), so diagram pages degrade gracefully to
    /// ordinary code blocks. `nonisolated` so it's safe off the main actor where
    /// the convert task reads it.
    nonisolated private static let mermaidLib: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8),
              !src.isEmpty else { return nil }
        return src
    }()

    /// Bootstrap that initializes Mermaid (matching the system appearance via
    /// `prefers-color-scheme`), converts each
    /// `<pre><code class="language-mermaid">` into a `<div class="mermaid">`
    /// using `textContent` (which un-escapes the renderer's `&lt;`/`&gt;`/`&amp;`),
    /// then renders. Wrapped in try/catch so a bad diagram logs but never breaks
    /// the page.
    nonisolated static let mermaidBootstrapJS = """
    (function(){
      try {
        var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        mermaid.initialize({ startOnLoad:false, securityLevel:'strict', theme: dark ? 'dark' : 'default' });
        var codes = document.querySelectorAll('code.language-mermaid');
        codes.forEach(function(code){
          var pre = code.parentElement;
          if(!pre || pre.tagName !== 'PRE') return;
          var div = document.createElement('div');
          div.className = 'mermaid';
          div.textContent = code.textContent;
          pre.parentNode.replaceChild(div, pre);
        });
        mermaid.run({ querySelector: '.mermaid' }).catch(function(e){
          console.error('mermaid run failed', e);
        });
      } catch(e) {
        console.error('mermaid init failed', e);
      }
    })();
    """

    /// Full HTML document string built around `body` (the converted markdown).
    /// Pure / callable off the main actor. The theme mirrors the native reader's
    /// geometry (760pt column, 12pt inset from `PageEditorMetrics`) and uses CSS
    /// variables + `color-scheme` so light/dark match the app appearance. A CSS
    /// rule colors unresolved `wiki://missing` links red (ghost links). When the
    /// body contains a mermaid block and the library is bundled, the Mermaid lib
    /// + bootstrap are appended at the end of `<body>` so they run after the DOM
    /// exists without blocking first paint.
    nonisolated static func documentHTML(_ body: String) -> String {
        let width = Int(PageEditorMetrics.readableContentWidth)
        let inset = Int(PageEditorMetrics.contentInset)
        // Embed the vendored Mermaid library + bootstrap only when the page
        // actually contains a mermaid code block (the exact class visitCodeBlock
        // emits) and the library is bundled. Otherwise the block stays a normal
        // <pre><code> — graceful degradation for swift test / dev runs with no
        // bundle, and no ~3 MB parse cost for diagram-free pages.
        var mermaidScripts = ""
        if body.contains("class=\"language-mermaid\""), let lib = mermaidLib {
            mermaidScripts = "<script>\(lib)</script>\n<script>\(mermaidBootstrapJS)</script>"
        }
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          :root {
            --text: #1c1c1e;
            --muted: rgba(60, 60, 67, 0.6);
            --code-bg: rgba(0, 0, 0, 0.06);
            --border: rgba(0, 0, 0, 0.12);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --text: #e6e6e6;
              --muted: rgba(235, 235, 245, 0.6);
              --code-bg: rgba(255, 255, 255, 0.08);
              --border: rgba(255, 255, 255, 0.16);
            }
          }
          /* color-scheme above drives the page canvas (light/dark background). */
          body {
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            font-size: 15px; line-height: 1.55;
            color: var(--text);
            max-width: \(width)px; margin: 24px 0 72px; padding: 0 \(inset)px;
            -webkit-text-size-adjust: 100%;
            -webkit-font-smoothing: antialiased;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 1.4em 0 0.5em; }
          h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h3 { font-size: 1.15em; } h4 { font-size: 1em; }
          p { margin: 0 0 1em; }
          strong { font-weight: 600; }
          a { color: -webkit-link; }
          /* Ghost links: a wiki link whose target doesn't resolve is emitted as
             wiki://missing?… by the linkifier — color it red so dangling
             references are obvious at a glance. */
          a[href^="wiki://missing"] { color: #ff453a; }
          ul, ol { padding-left: 1.6em; margin: 0 0 1em; }
          li { margin: 0.15em 0; }
          blockquote {
            margin: 0 0 1em; padding: 0.1em 0 0.1em 1em;
            border-left: 3px solid var(--border); color: var(--muted);
          }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em; background: var(--code-bg);
            padding: 0.1em 0.35em; border-radius: 4px;
          }
          pre {
            margin: 0 0 1em; padding: 12px 14px;
            background: var(--code-bg); border-radius: 8px; overflow: auto;
            font-size: 13px; line-height: 1.45;
          }
          pre code { background: none; padding: 0; font-size: inherit; }
          hr { border: none; border-top: 1px solid var(--border); margin: 1.5em 0; }
          table { border-collapse: collapse; margin: 0 0 1em; }
          th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; vertical-align: top; }
          th { font-weight: 600; }
          img { max-width: 100%; height: auto; }
          mark.sdwhl { background: rgba(255, 213, 79, 0.8); border-radius: 2px; }
          .mermaid { text-align:center; margin:0 0 1em; overflow:auto; }
          .mermaid svg { max-width:100%; height:auto; }
        </style></head>
        <body><article>\(body)</article>\(mermaidScripts)</body></html>
        """
    }
}

/// What a clicked `wiki://` link should do. The pure classifier
/// `WikiReaderView.linkRoute(for:)` returns one of these; the Coordinator and
/// the agent transcript's `onWikiLink` closure map each case onto a store call.
enum WikiLinkRoute: Equatable, Sendable {
    /// Same-page `[[#Section]]` — scroll within the current document.
    case samePageAnchor(fragment: String?)
    /// Resolved page link — navigate + carry the optional `#fragment`.
    case page(title: String, fragment: String?)
    /// Resolved source link — navigate + carry the optional `#fragment`.
    case source(title: String, fragment: String?)
    /// Unresolved (`wiki://missing`) or un-classifiable — inert.
    case inert
}

/// A resolved pending anchor to apply once the page has painted.
enum PendingScroll: Equatable {
    case heading(slug: String)
    case quote(String)
}

// MARK: - WKWebView bridge

/// A `WKWebView` subclass that augments the macOS context menu with the custom
/// wiki-link items (Suggest / Find Similar / Copy as Wiki Link / Copy File Path
/// for wiki links, Add as Source for http(s)) on top of WKWebView's native
/// Copy / Copy Link / Look Up / Share.
///
/// WKWebView has **no** public macOS API for customizing its context menu (the
/// `WKUIDelegate` `contextMenuConfigurationForElement:` family is iOS/
/// visionOS-only), so we override `NSView.willOpenMenu(_:with:)`. WebKit's menu
/// items don't carry the link URL, and there's no synchronous way to query the
/// DOM, so the hovered `<a>` href is tracked continuously via a `mouseover`
/// listener that posts to a `WKScriptMessageHandler`; by the time the user
/// right-clicks, the hovered href is current. `willOpenMenu` then builds the
/// items for that href via `WikiLinkMenuNSItems` and prepends them (plus a
/// separator) to WebKit's defaults.
@MainActor
final class WikiReaderWebView: WKWebView {
    /// Existence/navigation state for the custom menu items, set by
    /// `WikiReaderRep` from the view's store / fileProvider / addURLHandler.
    var store: WikiStoreModel?
    var fileProvider: FileProviderSpike?
    var currentSelection: WikiSelection?
    var addURLHandler: ((String) -> Void)?
    /// The href under the cursor, kept current by the injected `mouseover`
    /// listener. Read synchronously in `willOpenMenu`. `fileprivate(set)` so the
    /// in-file message-handler proxy can write it without exposing a public setter.
    fileprivate(set) var hoveredLinkHref: String?

    init() {
        let config = WKWebViewConfiguration()
        let cc = WKUserContentController()
        // The content controller retains the handler; the handler weakly
        // references this view, so there's no retain cycle. The proxy is created
        // with a nil target and wired to `self` after super.init (the view
        // doesn't exist until then).
        let proxy = LinkHoverMessageHandler(target: nil)
        cc.add(proxy, name: Self.linkHoverName)
        cc.addUserScript(WKUserScript(
            source: Self.hoverListenerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        config.userContentController = cc
        super.init(frame: .zero, configuration: config)
        proxy.target = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Handle sidebar drag-and-drop directly on the WKWebView. SwiftUI's
    /// `.dropDestination` overlay covers the SwiftUI chrome (header, banners) and
    /// the welcome screen, but it does NOT cover the AppKit WKWebView's own frame
    /// — so drops on the rendered markdown body never reach the SwiftUI target
    /// (#133). The WKWebView subclass is the drop target for its own body:
    /// register ONLY the sidebar-item type, and AppKit routes a sidebar drag over
    /// the body here (WebKit's internal subviews still register their own broad
    /// types for web-content drag/drop, but a sidebar payload doesn't conform to
    /// those, so they don't match and the drag bubbles up to this view).
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarPayloads(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarPayloads(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let payloads = sidebarPayloads(from: sender.draggingPasteboard)
        guard !payloads.isEmpty else { return false }
        for payload in payloads {
            DebugLog.tabs("[drop] wikiReader body action fired: kind=\(payload.kind) id=\(payload.id)")
            store?.openTab(payload.selection)
        }
        return true
    }

    /// Reads every dragged pasteboard item (not just the first — a multi-row
    /// selection or a bookmark folder both put more than one item on the
    /// pasteboard) and flattens each item's resolved target list.
    private func sidebarPayloads(from pb: NSPasteboard) -> [SidebarDragPayload] {
        let type = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item -> SidebarDragPayloadList? in
            guard let data = item.data(forType: type) else { return nil }
            return try? JSONDecoder().decode(SidebarDragPayloadList.self, from: data)
        }.flatMap(\.items)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Dump WebKit's menu items so we can see what identifiers / titles WKWebView
        // actually ships on this macOS version — useful diagnostic until the menu is
        // shipping reliably across macOS releases.  Logged public so Console shows it.
        let itemDescs = menu.items.map { "id=\($0.identifier?.rawValue ?? "nil") title=\"\($0.title)\"" }.joined(separator: ", ")
        DebugLog.reader("willOpenMenu \(menu.items.count) items: [\(itemDescs)]")

        // Remove WebKit built-ins that don't work for this app: opening in a new
        // window is unsupported (we use tabs), and "Download Linked File" no-ops
        // for our custom schemes. Remove them before building custom items so the
        // menu stays clean regardless of which URL type triggered it.
        let removeIDs: Set<String> = [
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile",
            "WKMenuItemIdentifierCopyLink",
        ]
        menu.items.removeAll { removeIDs.contains($0.identifier?.rawValue ?? "") }
        // Collapse any double separators or leading/trailing separators left
        // behind by the removal above.
        collapseMenuSeparators(menu)

        // We removed Copy Link; Open Link is the only remaining WebKit link
        // item we rely on to prove we're on a link.  Also accept a wiki://
        // hoveredLinkHref for custom-scheme links.
        let hasLinkItem = menu.items.contains {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
        }
        let hasWikiHref = hoveredLinkHref?.hasPrefix("wiki://") ?? false

        guard let store else {
            DebugLog.reader("willOpenMenu: store is nil → bailing")
            return
        }

        // Non-link right-click: add a Share item below "Reload" so the user
        // can share the current page/source document directly.
        guard hasLinkItem || hasWikiHref else {
            if let sel = currentSelection {
                addInlineShareItem(to: menu, for: sel, store: store, event: event)
            }
            DebugLog.reader("willOpenMenu: no link → added inline Share, bailing")
            return
        }

        guard let href = hoveredLinkHref, !href.isEmpty else {
            DebugLog.reader("willOpenMenu: hoveredLinkHref is nil/empty → bailing. href=\(hoveredLinkHref ?? "nil")")
            return
        }

        guard let url = URL(string: href) else {
            DebugLog.reader("willOpenMenu: URL(string:) failed for href=\"\(href)\" → bailing")
            return
        }

        DebugLog.reader("willOpenMenu: building custom items for url=\(url.absoluteString)")

        let custom = WikiLinkMenuNSItems.items(for: url, store: store, fileProvider: fileProvider, addURL: addURLHandler)

        // Insert "Open in Background" right after WebKit's "Open Link"
        // for resolved wiki links, so it's the second item in the menu.
        if let openLinkIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }),
           WikiLinkMarkdown.resolvedKind(from: url) != nil {
            let target = WikiLinkMarkdown.target(from: url) ?? ""
            let bgItem = NSMenuItem.wikiItem("Open in Background") {
                switch WikiLinkMarkdown.resolvedKind(from: url) {
                case .page:
                    if let id = store.pageID(forTitle: target) { store.openTabInBackground(.page(id)) }
                case .source:
                    if let id = store.sourceID(forDisplayName: target) { store.openTabInBackground(.source(id)) }
                case nil: break
                }
            }
            bgItem.image = NSImage(systemSymbolName: "dock.arrow.down.rectangle",
                                   accessibilityDescription: "Open in Background")
            menu.insertItem(bgItem, at: openLinkIdx + 1)
            menu.insertItem(NSMenuItem.separator(), at: openLinkIdx + 2)
        }

        // Prepend remaining custom items (addAsSource, openInBrowser,
        // suggest for missing links) at the top.
        if !custom.isEmpty {
            DebugLog.reader("willOpenMenu: prepending \(custom.count) custom items")
            menu.insertItem(NSMenuItem.separator(), at: 0)
            for item in custom.reversed() { menu.insertItem(item, at: 0) }
        }

        // Find the insertion point for Share + bottom items: right after
        // "Open in Background" if present, otherwise after "Open Link".
        let bgIdx = menu.items.firstIndex(where: { $0.title == "Open in Background" })
        let openLinkIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" })
        let insertIdx = bgIdx.map { $0 + 1 } ?? openLinkIdx.map { $0 + 1 } ?? menu.items.count

        // Remove WebKit's Share (we replace it with our own) if present.
        let shareID = "WKMenuItemIdentifierShareMenu"
        if let webKitShareIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == shareID }) {
            menu.removeItem(at: webKitShareIdx)
        }

        // Build Share + bottom items for wiki links.
        if url.scheme == WikiLinkMarkdown.scheme, let fp = fileProvider {
            let shareWebView = self
            let viewPoint = convert(event.locationInWindow, from: nil)

            let shareURLTask: Task<URL?, Never>?
            switch WikiLinkMarkdown.resolvedKind(from: url) {
            case .page?:
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                if let id = store.pageID(forTitle: target) {
                    shareURLTask = Task { await fp.resolvePageByTitleURL(id: id) }
                } else { shareURLTask = nil }
            case .source?:
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                if let id = store.sourceID(forDisplayName: target) {
                    shareURLTask = Task { await fp.resolveSourceByNameURL(id: id) }
                } else { shareURLTask = nil }
            case nil:
                shareURLTask = nil
            }

            let customShare = NSMenuItem.wikiItem("Share…") {
                Task { @MainActor in
                    guard let fileURL = await shareURLTask?.value as? URL else { return }
                    let picker = NSSharingServicePicker(items: [fileURL])
                    let rect = NSRect(x: viewPoint.x, y: viewPoint.y, width: 1, height: 1)
                    picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
                }
            }
            customShare.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                        accessibilityDescription: "Share")

            let bottomActions = WikiLinkMenuBuilder.bottomActions(for: url)
            let bottomItems = WikiLinkMenuNSItems.items(
                for: url, actions: bottomActions, store: store, fileProvider: fileProvider)

            // Insert at insertIdx in reverse so they appear in order.
            for item in bottomItems.reversed() { menu.insertItem(item, at: insertIdx) }
            if !bottomItems.isEmpty { menu.insertItem(NSMenuItem.separator(), at: insertIdx) }
            menu.insertItem(customShare, at: insertIdx)
            collapseMenuSeparators(menu)
        } else {
            // External link: Share the URL directly.
            let shareWebView = self
            let extViewPoint = convert(event.locationInWindow, from: nil)
            let customShare = NSMenuItem.wikiItem("Share…") {
                let picker = NSSharingServicePicker(items: [url])
                let rect = NSRect(x: extViewPoint.x, y: extViewPoint.y, width: 1, height: 1)
                picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
            }
            customShare.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                        accessibilityDescription: "Share")
            menu.insertItem(customShare, at: insertIdx)
            collapseMenuSeparators(menu)
        }
    }

    // MARK: - Menu cleanup helpers

    /// Remove leading, trailing, and consecutive separators from `menu` so that
    /// removing individual items never leaves an orphaned divider.
    private func collapseMenuSeparators(_ menu: NSMenu) {
        var lastWasSeparator = true // treat start-of-menu as "after separator"
        var i = 0
        while i < menu.items.count {
            let item = menu.items[i]
            if item.isSeparatorItem {
                if lastWasSeparator {
                    menu.removeItem(at: i)
                    continue
                }
                lastWasSeparator = true
            } else {
                lastWasSeparator = false
            }
            i += 1
        }
        // Remove trailing separator if any.
        if menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    /// Insert a Share item after WebKit's "Reload" (or at the end) for
    /// right-clicks on non-link text.  Resolves the canonical URL from the
    /// daemon so the share sheet gets a human-readable filename.
    private func addInlineShareItem(
        to menu: NSMenu,
        for selection: WikiSelection,
        store: WikiStoreModel,
        event: NSEvent
    ) {
        let shareWebView = self
        let viewPoint = convert(event.locationInWindow, from: nil)

        let shareTask: Task<URL?, Never>?
        switch selection {
        case .page(let id):
            shareTask = Task { [weak fileProvider] in
                await fileProvider?.resolvePageByTitleURL(id: id)
            }
        case .source(let id):
            shareTask = Task { [weak fileProvider] in
                await fileProvider?.resolveSourceByNameURL(id: id)
            }
        default:
            return
        }

        let item = NSMenuItem.wikiItem("Share…") {
            Task { @MainActor in
                guard let fileURL = await shareTask?.value as? URL else { return }
                let picker = NSSharingServicePicker(items: [fileURL])
                let rect = NSRect(x: viewPoint.x, y: viewPoint.y, width: 1, height: 1)
                picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
            }
        }
        item.image = NSImage(systemSymbolName: "square.and.arrow.up",
                             accessibilityDescription: "Share")

        // Insert after "Reload" if present.
        if let reloadIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }) {
            menu.insertItem(NSMenuItem.separator(), at: reloadIdx + 1)
            menu.insertItem(item, at: reloadIdx + 2)
        } else {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item)
        }
        collapseMenuSeparators(menu)
    }

    // MARK: - Pure, testable hit-test helpers

    /// Flip an AppKit (bottom-left origin) view point to the CSS (top-left
    /// origin) viewport coordinates `document.elementFromPoint` expects, clamped
    /// to the bounds. Pure — unit-tested.
    nonisolated static func cssHitTestPoint(_ point: NSPoint, in bounds: CGRect) -> (x: CGFloat, y: CGFloat) {
        let x = min(max(0, point.x), bounds.width)
        let y = min(max(0, bounds.height - point.y), bounds.height)
        return (x, y)
    }

    /// JS that returns the `href` of the anchor under `(x, y)`, or `""` if there
    /// is none / it isn't http(s). Coordinates are embedded as POSIX-formatted
    /// numbers (no locale-dependent separators). Pure — unit-tested.
    nonisolated static func linkHrefAtJS(x: CGFloat, y: CGFloat) -> String {
        """
        (function(x,y){
          var el=document.elementFromPoint(x,y);
          while(el && el.tagName!=="A"){ el=el.parentElement; }
          if(!el){ return ""; }
          return (el.protocol==="http:"||el.protocol==="https:") ? el.href : "";
        })(\(posix(x)),\(posix(y)))
        """
    }

    /// Format a coordinate with a POSIX decimal point so it's valid JS anywhere.
    nonisolated private static func posix(_ v: CGFloat) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(v))
    }

    // MARK: - Hover tracking (injected script + message handler)

    nonisolated static let linkHoverName = "linkHover"

    /// Tracks the `<a>` href under the cursor by listening for `mouseover` on the
    /// document (capture phase) AND per-link `mouseenter`/`mouseleave`.  Both paths
    /// post to the same `linkHover` message handler.  A `lastHref` guard suppresses
    /// duplicate posts so we don't flood WebKit's IPC queue (which can throttle or
    /// drop messages when the mouse moves rapidly over dense inline content).
    ///
    /// `mouseenter` fires only when the pointer enters an `<a>` element (far fewer
    /// events than `mouseover`), so it acts as a reliable fallback even when the
    /// capture-phase path is noisy.
    nonisolated static let hoverListenerJS = """
    (function(){
      var lastHref="";
      function post(href){
        if(href!==lastHref){
          lastHref=href;
          try{window.webkit.messageHandlers.\(linkHoverName).postMessage(href);}catch(e){}
        }
      }
      // capture-phase mouseover — catches every element entered
      document.addEventListener('mouseover',function(e){
        var el=e.target;
        while(el&&el.tagName!=="A"){el=el.parentElement;}
        post(el&&el.tagName==="A"?el.href:"");
      },true);
      // per-link mouseenter/leave — reliable for links, tiny event count
      function bindLinks(){
        var links=document.querySelectorAll("a:not([data-sdw-hover])");
        for(var i=0;i<links.length;i++){(function(a){
          a.setAttribute("data-sdw-hover","1");
          a.addEventListener("mouseenter",function(){post(a.href);});
          a.addEventListener("mouseleave",function(){post("");});
        })(links[i]);}
      }
      // bind once the DOM is settled; re-bind on DOM mutation as a safety net
      bindLinks();
      new MutationObserver(bindLinks).observe(document.body||document.documentElement,{childList:true,subtree:true});
    })();
    """
}

/// Forwards the `mouseover`-posted href to the owning web view. Retained by the
/// `WKUserContentController`; holds a weak reference to the view so there's no
/// cycle.
@MainActor
private final class LinkHoverMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WikiReaderWebView?
    init(target: WikiReaderWebView?) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.hoveredLinkHref = message.body as? String
    }
}

internal struct WikiReaderRep: NSViewRepresentable {
    let markdown: String
    let store: WikiStoreModel
    let fileProvider: FileProviderSpike?
    let readerZoom: Double
    /// The selection this reader renders — used to match a pending scroll anchor.
    let currentSelection: WikiSelection?
    /// Mirrors `store.pendingScrollAnchorVersion`; passed in so a bump causes an
    /// `updateNSView` (the Coordinator consumes + applies it once the page loads).
    let anchorVersion: Int
    @Binding var isLoading: Bool
    let addURLHandler: ((String) -> Void)?
    let findText: String?
    let findVersion: Int
    let findOccurrence: Int

    func makeNSView(context: Context) -> WikiReaderWebView {
        let webView = WikiReaderWebView()
        webView.pageZoom = readerZoom
        webView.store = store
        webView.fileProvider = fileProvider
        webView.currentSelection = currentSelection
        webView.addURLHandler = addURLHandler
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.store = store
        context.coordinator.currentSelection = currentSelection
        context.coordinator.startLoad(markdown: markdown, isLoading: $isLoading)
        return webView
    }

    func updateNSView(_ webView: WikiReaderWebView, context: Context) {
        webView.pageZoom = readerZoom
        webView.store = store
        webView.fileProvider = fileProvider
        webView.currentSelection = currentSelection
        webView.addURLHandler = addURLHandler
        context.coordinator.store = store
        context.coordinator.currentSelection = currentSelection
        if context.coordinator.loadedMarkdown != markdown {
            context.coordinator.startLoad(markdown: markdown, isLoading: $isLoading)
        }
        // Consume + apply any pending scroll anchor (handles re-clicks on an
        // already-loaded doc; a fresh load is handled in `didFinish`). Reads the
        // store's version directly so it's robust to the view being re-created
        // mid-navigation (the store outlives the view's @State).
        context.coordinator.consumeAndApplyPendingAnchor(in: webView)
        // Find: apply to the loaded page.
        if context.coordinator.appliedFindVersion != findVersion {
            context.coordinator.appliedFindVersion = findVersion
            if let text = findText, !text.isEmpty {
                context.coordinator.applyFind(text, occurrence: findOccurrence, in: webView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var store: WikiStoreModel?
        var currentSelection: WikiSelection?
        var loadedMarkdown: String?
        var pageLoaded = false
        /// The last `store.pendingScrollAnchorVersion` this coordinator applied.
        /// Drives `consumeAndApplyPendingAnchor` off the STORE's version (which
        /// outlives view re-creation) rather than the view's @State.
        var appliedAnchorVersion = 0
        var appliedFindVersion = 0
        private var convertTask: Task<Void, Never>?
        private var loadStart: DispatchTime?
        /// Timestamp captured right before `loadHTMLString`, to split
        /// `appear-to-painted` into the async hop (startLoad→loadHTMLString) vs.
        /// the pure WKWebView parse/layout (loadHTMLString→didFinish).
        private var htmlLoadStart: DispatchTime?
        private var isLoadingBinding: Binding<Bool>?

        func startLoad(markdown: String, isLoading: Binding<Bool>) {
            convertTask?.cancel()  // drop any in-flight conversion for stale markdown
            loadedMarkdown = markdown
            pageLoaded = false
            isLoadingBinding = isLoading
            isLoading.wrappedValue = true
            loadStart = DispatchTime.now()
            // Measure the synchronous click→startLoad window: openTab →
            // loadDrafts (getPage + stripped) → SwiftUI re-render → this
            // updateNSView→startLoad dispatch. This is the gap NOT covered by
            // "webview.convert" / "webview.appear-to-painted".
            if let click = store?.clickStartedAt {
                ReaderTiming.point("click.to-startLoad", ms: Self.elapsedMs(since: click))
            }

            // Build existence sets on the main actor (the store is @MainActor)
            // so the off-main convert can resolve links without crossing actor
            // boundaries — giving real ghost-link coloring. Sources match by
            // either display name or filename (lowercased, case-insensitive),
            // AND each name with its path extension stripped — mirroring
            // resolveSourceByName's fallback, so a `[[source:Paper]]` link also
            // resolves against a source whose filename is "Paper.pdf".
            let pageTitles = Set((store?.summaries ?? []).map { $0.title.lowercased() })
            let sourceNames = Set((store?.sources ?? [])
                .flatMap { source -> [String] in
                    let names = [source.displayName, source.filename].compactMap { $0 }
                    let stripped = names.map { ($0 as NSString).deletingPathExtension }
                    return (names + stripped).map { $0.lowercased() }
                })
            // Lenient tier, mirroring resolveSourceByName's pass 3 so ghost
            // styling agrees with navigation: loose keys (extension + trailing
            // "(…)" stripped) that are UNIQUE across sources.
            var looseKeyCounts: [String: Int] = [:]
            for source in store?.sources ?? [] {
                let effective = source.displayName ?? source.filename
                looseKeyCounts[WikiNameRules.looseMatchKey(effective), default: 0] += 1
            }
            let uniqueLooseKeys = Set(looseKeyCounts.filter { $0.value == 1 }.keys)

            let loadStartVal = loadStart
            convertTask = Task.detached(priority: .userInitiated) { [weak self] in
                let t0 = DispatchTime.now()
                // How long did Task.detached take to start after startLoad?
                if let ls = loadStartVal {
                    ReaderTiming.point("webview.task-start", ms: Self.elapsedMs(since: ls))
                }
                // Shared pre-pass (footnotes + wiki links) + swift-markdown HTML
                // render, both off the main actor. isResolved resolves against
                // the precomputed existence sets so missing links style as ghosts.
                let prepared = ReaderMarkdown.prepared(markdown) { name, kind in
                    kind == .source
                        ? sourceNames.contains(name.lowercased())
                            || uniqueLooseKeys.contains(WikiNameRules.looseMatchKey(name))
                        : pageTitles.contains(name.lowercased())
                }
                let body = MarkdownHTMLRenderer.render(prepared)
                let html = WikiReaderView.documentHTML(body)
                let convertMs = Self.elapsedMs(since: t0)
                let convertDone = DispatchTime.now()
                await MainActor.run { [weak self] in
                    guard let self, let webView = self.webView,
                          self.loadedMarkdown == markdown else { return }
                    // How long did MainActor.run wait to get back on the main
                    // actor? Large value ⇒ main thread is busy (SwiftUI layout).
                    ReaderTiming.point("webview.main-hop", ms: Self.elapsedMs(since: convertDone))
                    ReaderTiming.point("webview.convert", ms: convertMs)
                    self.htmlLoadStart = DispatchTime.now()
                    webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
                }
            }
        }

        // MARK: - Pending-anchor / quote-highlight flow
        //
        // How a clicked `[[source:Name#"quote"]]` (or `[[Page#Section]]`) link
        // reaches a highlight/scroll in this reader:
        //
        //   1. The link is rendered as `<a href="wiki://source?title=…#%22quote%22">`.
        //   2. A click fires the WKWebView navigation delegate → `route(_:)` →
        //      `linkRoute(for:)` classifies it → `store.selectSource(byDisplayName:
        //      anchor:)` (or `selectPage`).
        //   3. `selectSource` stashes the fragment in `store.pendingScrollAnchor`
        //      (tagged with the destination selection) and bumps
        //      `store.pendingScrollAnchorVersion`, then opens the tab.
        //   4. This reader's `Coordinator` — here — consumes that anchor once the
        //      page has painted and applies it (`apply(_:)` → scroll to a heading
        //      slug, or `highlightJS` for a quote).
        //
        // WHY the Coordinator consumes (not the view's `.task` + `@State`): the
        // reader can be re-created mid-navigation (e.g. its container swaps
        // `headVersion`), and a `.task` that consumed the anchor into `@State` was
        // discarded before `updateNSView` could propagate it — so nothing applied.
        // By reading the STORE's version directly and tracking our own
        // `appliedAnchorVersion`, the coordinator that actually reaches a painted
        // page always gets to consume + apply, regardless of how many times the
        // view above is torn down and rebuilt. The store outlives the view.
        //
        // The version gate also makes a re-click to an already-open doc re-fire
        // (a new `selectSource` bumps the version past `appliedAnchorVersion`),
        // and `consumePendingScrollAnchor` clearing the anchor only here (after
        // `pageLoaded`) means a discarded-before-paint view never steals it.

        /// Consume + apply the pending scroll anchor for `currentSelection` once
        /// the page has painted and the store has a newer anchor version than we
        /// last applied. Called from `updateNSView` (re-click on a loaded doc) and
        /// `didFinish` (fresh load). See the flow note above.
        func consumeAndApplyPendingAnchor(in webView: WKWebView) {
            guard let store, pageLoaded,
                  store.pendingScrollAnchorVersion != appliedAnchorVersion else { return }
            appliedAnchorVersion = store.pendingScrollAnchorVersion
            guard let fragment = store.consumePendingScrollAnchor(for: currentSelection) else { return }
            
            // First, try scrolling assuming fragment is an exact element ID (like a heading slug).
            // This guarantees that outline clicks work even if AnchorBlock.parse fails or slugs mismatch slightly.
            let s = WikiReaderRep.jsString(fragment)
            webView.evaluateJavaScript(
                #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}"#
            ) { [weak self] _, _ in
                // We don't check for success here because we still want to apply quotes if it wasn't a heading ID.
                guard let md = self?.loadedMarkdown,
                      let target = WikiReaderView.resolveScrollTarget(fragment, blocks: AnchorBlock.parse(md))
                else { return }
                
                // If it resolved to a quote, apply it. If it resolved to a heading, applying it again is harmless.
                if case .quote = target {
                    WikiReaderRep.apply(target, in: webView)
                }
            }
        }

        /// Highlight and scroll to the find match using `window.find()`.
        /// `occurrence` is 1-based: the selection is reset to the document start
        /// and `window.find()` is advanced that many times, so repeated next/prev
        /// clicks step through distinct matches instead of re-finding the first.
        func applyFind(_ text: String, occurrence: Int, in webView: WKWebView) {
            guard pageLoaded else { return }
            let q = WikiReaderRep.jsString(text)
            let n = max(1, occurrence)
            webView.evaluateJavaScript("""
            (function(q, n){
              // Clear any previous highlight, collapsing the selection.
              document.querySelectorAll("mark.sdwhl").forEach(function(m){
                var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
                p.removeChild(m); p.normalize();
              });
              // Reset the selection to the start of the body so window.find()
              // walks matches in order from the top — making occurrence N
              // deterministic instead of resuming from the previous highlight.
              var sel=window.getSelection();
              sel.removeAllRanges();
              var body=document.body;
              if(body){
                 var r0=document.createRange();
                 r0.setStart(body,0);
                 r0.collapse(true);
                 sel.addRange(r0);
              }
              // Advance forward N times to land on the requested occurrence.
              for(var i=0;i<n;i++){ window.find(q,false,false,false,false); }
              if(sel.rangeCount>0 && !sel.isCollapsed){
                 var r=sel.getRangeAt(0); var mark=document.createElement("mark");
                 mark.className="sdwhl";
                 try{ r.surroundContents(mark); }catch(e){
                   // surroundContents fails across element boundaries; fall back
                   // to a plain node at the selection start and scroll to it.
                   mark.appendChild(document.createTextNode(q));
                   r.insertNode(mark);
                 }
                 var mk=document.querySelector("mark.sdwhl");
                 if(mk){ mk.scrollIntoView({block:"center"}); }
              }
            })("\(q)", \(n));
            """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let start = loadStart {
                ReaderTiming.point("webview.appear-to-painted", ms: Self.elapsedMs(since: start))
            }
            // Split the WKWebView cost: async hop (startLoad→loadHTMLString) vs.
            // pure WKWebView parse/layout (loadHTMLString→didFinish). Tells us
            // whether a navigation-free innerHTML swap would actually help.
            if let html = htmlLoadStart {
                ReaderTiming.point("webview.html-load", ms: Self.elapsedMs(since: html))
            }
            // Full click→painted latency (user perception): click → convert →
            // WKWebView parse/layout → didFinish. Splits vs. the startLoad window
            // above ("click.to-startLoad") so we know if the stall is in the
            // synchronous SwiftUI path or in the WKWebView load itself.
            if let click = store?.clickStartedAt {
                ReaderTiming.point("click.to-painted", ms: Self.elapsedMs(since: click))
            }
            pageLoaded = true
            isLoadingBinding?.wrappedValue = false
            consumeAndApplyPendingAnchor(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if url.scheme == "wiki" {
                    route(url)
                    decisionHandler(.cancel)
                    return
                }
                // External links open in the system browser, not in the reader.
                // Footnote references are same-page fragment links (`#wiki-fn-…`),
                // so they fall through to `.allow` and WKWebView scrolls natively.
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        /// Dispatch a clicked `wiki://` link to navigation/scroll. Step 2 of the
        /// pending-anchor flow (see `consumeAndApplyPendingAnchor`): the resulting
        /// `selectPage`/`selectSource` stash the `#fragment` as a pending anchor
        /// that the *destination* reader's Coordinator later consumes + applies.
        private func route(_ url: URL) {
            switch WikiReaderView.linkRoute(for: url) {
            case .samePageAnchor(let frag):
                if let webView, let frag {
                    let s = WikiReaderRep.jsString(frag)
                    webView.evaluateJavaScript(
                        #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}""#)
                }
            case .page(let title, let frag):
                store?.selectPage(byTitle: title, anchor: frag)
            case .source(let title, let frag):
                store?.selectSource(byDisplayName: title, anchor: frag)
            case .inert:
                break
            }
        }

        nonisolated private static func elapsedMs(since start: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }
    }

    // MARK: Apply (JS)

    /// Apply a resolved scroll/highlight target to the loaded web view.
    @MainActor
    static func apply(_ target: PendingScroll, in webView: WKWebView) {
        switch target {
        case .heading(let slug):
            let s = jsString(slug)
            webView.evaluateJavaScript(
                #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}""#)
        case .quote(let quote):
            webView.evaluateJavaScript(Self.highlightJS(quote: quote))
        }
    }

    /// Highlight + scroll to a quoted passage. Emits a pure JS string —
    /// `nonisolated` so unit tests can assert against it off the main actor
    /// (this replaces the retired `quoteRange` logic).
    ///
    /// Walks **every** text node under the body, building a whitespace-collapsed,
    /// lowercased view with an index map back to `(node, charOffset)`. The quote
    /// is searched in that whole-document view, then the matched range is wrapped
    /// one text segment at a time — so a quote that spans an inline element (a
    /// link, bold) is found and highlighted even though it lives in several text
    /// nodes. (The previous single-node search + `window.find` missed these, and
    /// `window.find` is deprecated/unreliable in WKWebView.)
    nonisolated static func highlightJS(quote: String) -> String {
        let q = jsString(quote)
        return """
        (function(q){
          document.querySelectorAll("mark.sdwhl").forEach(function(m){
            var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
            p.removeChild(m); p.normalize();
          });
          var nq=q.replace(/\\s+/g," ").trim().toLowerCase();
          if(!nq){ return; }
          var chars=[], map=[];
          var tw=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while(tw.nextNode()){
            var v=tw.currentNode.nodeValue;
            for(var i=0;i<v.length;i++){
              var c=v[i];
              if(/\\s/.test(c)){
                if(chars.length===0||chars[chars.length-1]!==" "){ chars.push(" "); map.push({n:tw.currentNode,o:i}); }
              } else { chars.push(c.toLowerCase()); map.push({n:tw.currentNode,o:i}); }
            }
          }
          var lo=0, hi=chars.length;
          while(lo<hi&&chars[lo]===" "){ lo++; }
          while(hi>lo&&chars[hi-1]===" "){ hi--; }
          var hay=chars.slice(lo,hi).join("");
          var at=hay.indexOf(nq), mlen=nq.length;
          if(at<0){
            // The quote may not appear contiguously: PDF extraction can splice
            // a footer/marginal block (or a hard-hyphenated word) into the
            // middle of a sentence. Fall back to the LONGEST contiguous run of
            // >=4 quote-words that IS present, so we still highlight + scroll to
            // the passage instead of giving up.
            var words=nq.split(" ");
            for(var L=words.length-1; L>=4 && at<0; L--){
              for(var st=0; st+L<=words.length; st++){
                var cand=words.slice(st,st+L).join(" ");
                var p=hay.indexOf(cand);
                if(p>=0){ at=p; mlen=cand.length; break; }
              }
            }
            if(at<0){ return; }
          }
          var s=lo+at, e=lo+at+mlen-1;
          var range=document.createRange();
          range.setStart(map[s].n, map[s].o);
          range.setEnd(map[e].n, map[e].o+1);
          // Wrap each text segment intersecting the range, preserving inline
          // elements (e.g. the link inside the quote). Reverse so splitText
          // offsets of earlier nodes stay valid.
          var segs=[];
          var root=range.commonAncestorContainer;
          var rw=document.createTreeWalker(root.nodeType===3?root.parentNode:root, NodeFilter.SHOW_TEXT);
          while(rw.nextNode()){
            var nd=rw.currentNode;
            if(range.intersectsNode(nd)){
              var ss=(nd===range.startContainer)?range.startOffset:0;
              var ee=(nd===range.endContainer)?range.endOffset:nd.nodeValue.length;
              if(ss<ee){ segs.push({n:nd,s:ss,e:ee}); }
            }
          }
          for(var i=segs.length-1;i>=0;i--){
            var g=segs[i];
            var tail=g.n.splitText(g.s);
            if(g.e-g.s<tail.nodeValue.length){ tail.splitText(g.e-g.s); }
            var mark=document.createElement("mark"); mark.className="sdwhl";
            tail.parentNode.insertBefore(mark,tail); mark.appendChild(tail);
          }
          var mk=document.querySelector("mark.sdwhl");
          if(mk){ mk.scrollIntoView({block:"center"}); }
        })("\(q)");
        """
    }

    /// Escape a string for a JS double-quoted literal.
    nonisolated static func jsString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}
