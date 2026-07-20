import AppKit
import SwiftUI
import WebKit
import WikiFSCore

/// Renders the original HTML bytes of a source in a WKWebView — the "HTML" tab
/// of `SourceDetailView` for HTML sources (issue #599). Mirrors how PDF sources
/// show the original PDF in a `PDFView`: the user gets a faithful rendering of
/// the original document alongside the Reader (extracted markdown) tab.
///
/// Security posture: JavaScript is disabled on the page (`allowsContentJavaScript
/// = false`), so `<script>` blocks, inline event handlers, and `javascript:`
/// URLs all no-op. External CSS / images / iframes still load through the
/// network so the rendering stays faithful (a script-less page reads as a
/// script-less page would in any browser). The same `reader.zoom` keyboard
/// shortcuts (`⌘+`, `⌘−`, `⌘0`, `⌘-scroll`) and wheel-zoom as the markdown
/// reader apply via `WKWebView.pageZoom`.
///
/// `baseURL: nil`: relative URLs in the HTML (e.g. `<img src="/foo.png">`) won't
/// resolve without the original page URL. Absolute URLs (`https://…`) load via
/// the network. Snapshot sources — whose image siblings are stored as separate
/// sources — keep that resolved-image path through the Reader tab (the
/// extracted markdown sidecar has image srcs rewritten to point at stored
/// blobs); the HTML tab shows the ORIGINAL HTML verbatim.
struct HTMLSourceWebView: View {
    let html: String
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    var body: some View {
        HTMLSourceWebViewRep(html: html, zoom: readerZoom)
            .zoomShortcuts($readerZoom)
            .zoomScroll($readerZoom)
    }
}

/// The `NSViewRepresentable` wrapping a plain `WKWebView`. Kept minimal — no
/// blob scheme, no wiki-link routing, no find bar; the HTML tab is a faithful
/// rendering of the source's original HTML with scripts disabled.
private struct HTMLSourceWebViewRep: NSViewRepresentable {
    let html: String
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Security: disable JavaScript entirely in the rendered HTML so the
        // wiki never executes untrusted script from an ingested page. Scripts,
        // inline event handlers, and `javascript:` URLs all no-op. CSS and
        // external resources (images, iframes) still load so the rendering
        // stays faithful.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadHTML(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadHTML(html, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The HTML string currently loaded (or loading). Used by `updateNSView`
        /// to avoid reloading the same document on every SwiftUI re-evaluation.
        var loadedHTML: String?

        func loadHTML(_ html: String, into webView: WKWebView) {
            loadedHTML = html
            // `baseURL: nil`: relative URLs in the original HTML won't resolve,
            // but absolute (`https://…`) URLs still load via the network. The
            // HTML tab shows the page verbatim — the Reader tab carries the
            // extracted markdown with image src rewriting for offline images.
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}
