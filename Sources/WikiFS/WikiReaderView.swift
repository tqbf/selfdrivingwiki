import AppKit
import SwiftUI
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

    /// Full HTML document string built around `body` (the converted markdown).
    /// Pure / callable off the main actor. The theme mirrors the native reader's
    /// geometry (760pt column, 12pt inset from `PageEditorMetrics`) and uses CSS
    /// variables + `color-scheme` so light/dark match the app appearance. A CSS
    /// rule colors unresolved `wiki://missing` links red (ghost links).
    nonisolated static func documentHTML(_ body: String) -> String {
        let width = Int(PageEditorMetrics.readableContentWidth)
        let inset = Int(PageEditorMetrics.contentInset)
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
        </style></head>
        <body><article>\(body)</article></body></html>
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

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Dump WebKit's menu items so we can see what identifiers / titles WKWebView
        // actually ships on this macOS version — useful diagnostic until the menu is
        // shipping reliably across macOS releases.  Logged public so Console shows it.
        let itemDescs = menu.items.map { "id=\($0.identifier?.rawValue ?? "nil") title=\"\($0.title)\"" }.joined(separator: ", ")
        DebugLog.reader("willOpenMenu \(menu.items.count) items: [\(itemDescs)]")

        // WebKit adds "Copy Link" / "Open Link" when the right-click lands on an <a>
        // IMPORTANT: WebKit may NOT add link items for custom URL schemes (wiki://),
        // so also accept a wiki:// hoveredLinkHref as proof we're on a link.
        let hasCopyLink = menu.items.contains {
            $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink"
        }
        let hasLinkItem = hasCopyLink || menu.items.contains {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
        }
        let hasWikiHref = hoveredLinkHref?.hasPrefix("wiki://") ?? false
        guard hasLinkItem || hasWikiHref else {
            DebugLog.reader("willOpenMenu: no link item (hasCopyLink=\(hasCopyLink)) and no wiki href → bailing")
            return
        }

        guard let store else {
            DebugLog.reader("willOpenMenu: store is nil → bailing")
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
        guard !custom.isEmpty else {
            DebugLog.reader("willOpenMenu: WikiLinkMenuNSItems returned empty for url=\(url.absoluteString) → bailing")
            return
        }
        DebugLog.reader("willOpenMenu: prepending \(custom.count) custom items")
        menu.insertItem(NSMenuItem.separator(), at: 0)
        for item in custom.reversed() { menu.insertItem(item, at: 0) }
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
        private var isLoadingBinding: Binding<Bool>?

        func startLoad(markdown: String, isLoading: Binding<Bool>) {
            convertTask?.cancel()  // drop any in-flight conversion for stale markdown
            loadedMarkdown = markdown
            pageLoaded = false
            isLoadingBinding = isLoading
            isLoading.wrappedValue = true
            loadStart = DispatchTime.now()

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

            convertTask = Task.detached(priority: .userInitiated) { [weak self] in
                let t0 = DispatchTime.now()
                // Shared pre-pass (footnotes + wiki links) + swift-markdown HTML
                // render, both off the main actor. isResolved resolves against
                // the precomputed existence sets so missing links style as ghosts.
                let prepared = ReaderMarkdown.prepared(markdown) { name, kind in
                    kind == .source ? sourceNames.contains(name.lowercased())
                                    : pageTitles.contains(name.lowercased())
                }
                let body = MarkdownHTMLRenderer.render(prepared)
                let html = WikiReaderView.documentHTML(body)
                let convertMs = Self.elapsedMs(since: t0)
                await MainActor.run { [weak self] in
                    guard let self, let webView = self.webView,
                          self.loadedMarkdown == markdown else { return }
                    ReaderTiming.point("webview.convert", ms: convertMs)
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
            guard let fragment = store.consumePendingScrollAnchor(for: currentSelection),
                  let md = loadedMarkdown,
                  let target = WikiReaderView.resolveScrollTarget(fragment, blocks: AnchorBlock.parse(md))
            else { return }
            WikiReaderRep.apply(target, in: webView)
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
          var at=chars.slice(lo,hi).join("").indexOf(nq);
          if(at<0){ return; }
          var s=lo+at, e=lo+at+nq.length-1;
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
