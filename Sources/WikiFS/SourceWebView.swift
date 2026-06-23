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
                       scrollVersion: scrollVersion)
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
    /// Pure / callable off the main actor.
    nonisolated static func documentHTML(_ body: String) -> String {
        """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          body {
            font: -apple-system-body; font-size: 15px; line-height: 1.55;
            max-width: 720px; margin: 24px auto 64px; padding: 0 24px;
            -webkit-text-size-adjust: 100%;
          }
          pre {
            background: rgba(128,128,128,0.14); padding: 12px 14px;
            border-radius: 8px; overflow: auto; font-size: 13px;
          }
          code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          a { color: -webkit-link; }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
          h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h3 { font-size: 1.15em; }
          ul, ol { padding-left: 1.6em; }
          mark.sdwhl { background: rgba(255, 213, 79, 0.75); border-radius: 2px; }
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

private struct WebViewRep: NSViewRepresentable {
    let markdown: String
    let store: WikiStoreModel
    @Binding var isLoading: Bool
    let pendingScroll: PendingScroll?
    let scrollVersion: Int

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.store = store
        context.coordinator.pendingScroll = pendingScroll
        context.coordinator.pendingScrollVersion = scrollVersion
        context.coordinator.startLoad(markdown: markdown, isLoading: $isLoading)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
