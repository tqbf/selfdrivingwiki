import SwiftUI
import WebKit
import WikiFSCore

// MARK: - SourceWebView

/// Renders a source's markdown in a `WKWebView` instead of the native
/// `MarkdownPreview` (Textual). The native reader beachballs on 500 KB+ sources
/// because it lays out the whole document synchronously; the browser's windowed
/// layout sidesteps that (confirmed by A/B).
///
/// Loads **asynchronously**: the page chrome appears immediately with a spinner,
/// and the footnote/link pre-pass + swift-markdown render run off the main actor
/// (~180 ms on 500 KB). No selection-overlay geometry constraint exists on this
/// path (that's specific to the native reader), so deferring the load is safe.
///
/// **Anchors + quote highlight** mirror the native reader: a
/// `[[source:Name#Section]]` link (set via `selectSource(anchor:)`) is consumed
/// from the store's pending-anchor path, resolved with the shared
/// `AnchorBlock.parse` + `resolveAnchor`, then applied after the page paints —
/// scroll to the heading's slug `id` for a section anchor, or `window.find` +
/// `<mark>` for a `[[source:Name#"quote"]]` highlight (with a whitespace-tolerant
/// TreeWalker fallback so the scroll lands even if `surroundContents` can't wrap
/// the range).
///
/// Gated behind `@AppStorage("debug.webReader")` in `SourceDetailView` as an A/B
/// toggle. Phase timings are logged under `com.selfdrivingwiki.debug`/render.
struct SourceWebView: View {
    let markdown: String
    var currentSelection: WikiSelection? = nil
    let store: WikiStoreModel
    /// Opens the "Add from URL" sheet pre-filled with a URL — the same value
    /// the Textual reader uses, so right-click "Add as Source" works here too.
    @Environment(\.addURLHandler) private var addURLHandler
    @State private var isLoading = true
    /// Resolved from a consumed pending anchor; applied once the page paints.
    @State private var pendingScroll: PendingScroll?
    /// Bumped when `pendingScroll` is set, so the Coordinator re-applies it
    /// (covers re-clicking the same `[[…#"quote"]]` on an already-open source).
    @State private var scrollVersion = 0

    var body: some View {
        ZStack {
            WebViewRep(markdown: markdown,
                       store: store,
                       isLoading: $isLoading,
                       pendingScroll: pendingScroll,
                       scrollVersion: scrollVersion,
                       addURLHandler: addURLHandler)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
        // Re-run on markdown change OR a new pending anchor (the same RenderKey
        // scheme the native MarkdownPreview uses). Consume, resolve heading vs
        // quote, then bump scrollVersion so the Coordinator applies it once the
        // page has painted.
        .task(id: RenderKey(markdown: markdown, anchorVersion: store.pendingScrollAnchorVersion)) {
            guard let fragment = store.consumePendingScrollAnchor(for: currentSelection) else { return }
            let target = SourceWebView.resolveScrollTarget(fragment, blocks: AnchorBlock.parse(markdown))
            pendingScroll = target
            if target != nil { scrollVersion += 1 }
        }
    }

    /// Resolve a consumed anchor fragment to a scroll target: a section anchor
    /// scrolls to the heading's slug id; anything else (a `[[…#"quote"]]` or an
    /// unresolved fragment) becomes a quote highlight. Mirrors the native
    /// reader's `resolveAnchor` heading-vs-quote split. Pure — unit-tested.
    ///
    /// `nonisolated`: it touches no actor state, but `SourceWebView` is a `View`
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

    /// Full HTML document string built around `body` (the converted markdown).
    /// Pure / callable off the main actor. The theme mirrors the native reader's
    /// geometry (760pt column, 12pt inset from `PageEditorMetrics`) and uses CSS
    /// variables + `color-scheme` so light/dark match the app appearance.
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

/// A resolved pending anchor to apply once the page has painted.
enum PendingScroll: Equatable {
    case heading(slug: String)
    case quote(String)
}

/// Keys the consume `.task` so it re-fires on a repeat anchor click to the
/// already-open source (same markdown, bumped anchor version).
private struct RenderKey: Equatable {
    let markdown: String
    let anchorVersion: Int
}

// MARK: - WKWebView bridge

/// A `WKWebView` subclass that augments the macOS context menu with **Add as
/// Source** when you right-click an external http(s) link — the WKWebView
/// counterpart to the Textual reader's menu (`plans/url-context-menu-add.md`).
///
/// WKWebView has **no** public macOS API for customizing its context menu (the
/// `WKUIDelegate` `contextMenuConfigurationForElement:` family is iOS/
/// visionOS-only — confirmed in WebKit's `WKUIDelegate.h`), so we override
/// `NSView.willOpenMenu(_:with:)`. WebKit's menu items don't carry the link's
/// URL, so on selection we hit-test the captured right-click point in the DOM
/// (`document.elementFromPoint` → walk up to the `<a>`) and keep only http(s)
/// `href`s — matching `WikiLinkMenuBuilder`'s `.addAsSource` gate. The URL is
/// handed to `addURLHandler`, the same `\.addURLHandler` environment value the
/// Textual reader uses, so both readers open the identical pre-filled sheet.
@MainActor
final class SourceDetailWebView: WKWebView {
    /// Opens the "Add from URL" sheet pre-filled with a URL — injected from
    /// `SourceWebView`'s `\.addURLHandler` environment value.
    var addURLHandler: ((String) -> Void)?
    /// The right-click location (view coords) captured in `willOpenMenu`, used
    /// to hit-test the DOM when the item is chosen.
    private var contextMenuPoint: NSPoint?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        contextMenuPoint = convert(event.locationInWindow, from: nil)

        // WebKit only adds a "Copy Link" item when the right-click is on a link;
        // gate on that so the item never appears for plain text / images.
        let isLink = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }
        guard isLink, addURLHandler != nil else { return }

        let item = NSMenuItem(title: "Add as Source", action: #selector(addSourceFromLink), keyEquivalent: "")
        item.target = self
        // Lead with the headline action, separated from WebKit's default items.
        menu.insertItem(NSMenuItem.separator(), at: 0)
        menu.insertItem(item, at: 0)
    }

    @objc private func addSourceFromLink() {
        guard let point = contextMenuPoint, let handler = addURLHandler else { return }
        let css = Self.cssHitTestPoint(point, in: bounds)
        evaluateJavaScript(Self.linkHrefAtJS(x: css.x, y: css.y)) { result, _ in
            guard let href = result as? String, !href.isEmpty else { return }
            handler(href)
        }
    }

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
}

private struct WebViewRep: NSViewRepresentable {
    let markdown: String
    let store: WikiStoreModel
    @Binding var isLoading: Bool
    let pendingScroll: PendingScroll?
    let scrollVersion: Int
    let addURLHandler: ((String) -> Void)?

    func makeNSView(context: Context) -> SourceDetailWebView {
        let webView = SourceDetailWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.addURLHandler = addURLHandler
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.store = store
        context.coordinator.pendingScroll = pendingScroll
        context.coordinator.pendingScrollVersion = scrollVersion
        context.coordinator.startLoad(markdown: markdown, isLoading: $isLoading)
        return webView
    }

    func updateNSView(_ webView: SourceDetailWebView, context: Context) {
        webView.addURLHandler = addURLHandler
        context.coordinator.store = store
        context.coordinator.pendingScroll = pendingScroll
        context.coordinator.pendingScrollVersion = scrollVersion
        if context.coordinator.loadedMarkdown != markdown {
            context.coordinator.startLoad(markdown: markdown, isLoading: $isLoading)
        } else {
            context.coordinator.applyPendingScrollIfNeeded(in: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var store: WikiStoreModel?
        var loadedMarkdown: String?
        var pageLoaded = false
        var pendingScroll: PendingScroll?
        var pendingScrollVersion = 0
        var appliedScrollVersion = 0
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

            convertTask = Task.detached(priority: .userInitiated) { [weak self] in
                let t0 = DispatchTime.now()
                // Shared pre-pass (footnotes + wiki links) + swift-markdown HTML
                // render, both off the main actor. isResolved is constant here —
                // the web reader can't call the @MainActor store from this task,
                // so ghost-link coloring is a follow-up.
                let prepared = ReaderMarkdown.prepared(markdown) { _, _ in true }
                let body = MarkdownHTMLRenderer.render(prepared)
                let html = SourceWebView.documentHTML(body)
                let convertMs = Self.elapsedMs(since: t0)
                await MainActor.run { [weak self] in
                    guard let self, let webView = self.webView,
                          self.loadedMarkdown == markdown else { return }
                    ReaderTiming.point("webview.convert", ms: convertMs)
                    webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
                }
            }
        }

        /// Apply the pending scroll exactly once per version, once the page has
        /// painted. Called from both `updateNSView` (anchor set while loaded)
        /// and `didFinish` (load finished after an anchor was set).
        func applyPendingScrollIfNeeded(in webView: WKWebView) {
            guard pageLoaded, let target = pendingScroll,
                  appliedScrollVersion != pendingScrollVersion else { return }
            appliedScrollVersion = pendingScrollVersion
            WebViewRep.apply(target, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let start = loadStart {
                ReaderTiming.point("webview.appear-to-painted", ms: Self.elapsedMs(since: start))
            }
            pageLoaded = true
            isLoadingBinding?.wrappedValue = false
            applyPendingScrollIfNeeded(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, url.scheme == "wiki" {
                route(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func route(_ url: URL) {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            let kind = comps.host ?? ""
            var target = comps.path
            if target.hasPrefix("/") { target.removeFirst() }
            target = target.removingPercentEncoding ?? target
            let frag = comps.fragment
            switch kind {
            case "page":   store?.selectPage(byTitle: target, anchor: frag)
            case "source": store?.selectSource(byDisplayName: target, anchor: frag)
            default: break
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
                #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}""#
            )
        case .quote(let quote):
            webView.evaluateJavaScript(Self.highlightJS(quote: quote))
        }
    }

    /// Highlight + scroll to a quoted passage. Tries `window.find` (WebKit) for a
    /// precise `<mark>` wrap; falls back to a whitespace-tolerant text-node walk
    /// that scrolls to the containing element if the range can't be wrapped.
    static func highlightJS(quote: String) -> String {
        let q = jsString(quote)
        return """
        (function(q){
          document.querySelectorAll("mark.sdwhl").forEach(function(m){
            var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
            p.removeChild(m); p.normalize();
          });
          function norm(s){ return s.replace(/\\s+/g," ").toLowerCase(); }
          var nq=norm(q);
          var found=false; try { found=window.find(q,false,false,true); } catch(e){}
          var sel=window.getSelection();
          if(found && sel.rangeCount>0 && !sel.isCollapsed){
            var r=sel.getRangeAt(0); var mark=document.createElement("mark");
            mark.className="sdwhl";
            try{ r.surroundContents(mark); }catch(e){}
            sel.removeAllRanges();
            var mk=document.querySelector("mark.sdwhl");
            if(mk){ mk.scrollIntoView({block:"center"}); return; }
          }
          sel.removeAllRanges();
          var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);
          while(w.nextNode()){
            if(norm(w.currentNode.nodeValue).indexOf(nq)>=0){
              var el=w.currentNode.parentElement;
              if(el) el.scrollIntoView({block:"center"});
              return;
            }
          }
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
