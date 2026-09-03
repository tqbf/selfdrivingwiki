#if os(macOS)
import AppKit

// pattern: Imperative Shell — owns AppKit child layout and teardown.
//
// DOM era: the reader container hosts only the webview. Renderer embeds live
// inside the reader document's DOM (iframes and media elements injected via
// `sdwInjectRendererEmbed`), so there is no sibling overlay, no native child
// dictionary, no custom hit testing, and no attachment frame bookkeeping.
// Scroll, resize, and reader `pageZoom` move/scale embedded content with the
// page because it IS the page.

/// The native reader host. The WebView remains the document-layout and
/// scrolling authority and is the container's only child.
@MainActor
final class WikiReaderContainerView: NSView {
    let webView: WikiReaderWebView

    init(webView: WikiReaderWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The webview is the only child: every hit lands in the document.
        webView
    }

    func teardown() {
        webView.removeFromSuperview()
    }
}
#endif
