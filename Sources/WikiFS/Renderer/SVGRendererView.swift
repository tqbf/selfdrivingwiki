#if os(macOS)
import Foundation
import SwiftUI
import WebKit
import WikiFSCore

/// Displays exact SVG source bytes as an inert image. The SVG document is loaded
/// through an image element, while JavaScript and navigation stay disabled.
struct SVGRendererView: View {
    let bytes: Data
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    var body: some View {
        SVGRendererWebView(bytes: bytes, zoom: readerZoom)
            .zoomShortcuts($readerZoom)
            .diagramScrollZoom { steps in
                var next = readerZoom
                if steps > 0 {
                    for _ in 0..<steps { next = ZoomScale.zoomedIn(next) }
                } else {
                    for _ in 0..<(-steps) { next = ZoomScale.zoomedOut(next) }
                }
                readerZoom = next
            }
    }
}

struct SVGRendererWebView: NSViewRepresentable {
    let bytes: Data
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoom
        context.coordinator.load(bytes: bytes, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        let identity = bytes.hashValue
        guard context.coordinator.loadedContentIdentity != identity else { return }
        context.coordinator.load(bytes: bytes, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedContentIdentity: Int?

        func load(bytes: Data, into webView: WKWebView) {
            loadedContentIdentity = bytes.hashValue
            webView.loadHTMLString(Self.documentHTML(bytes: bytes), baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let isInitialDocument = navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }

        nonisolated static func documentHTML(bytes: Data) -> String {
            let encoded = bytes.base64EncodedString()
            return """
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <style>
              html, body { width:100%; min-height:100%; margin:0; }
              body {
                display:flex; align-items:flex-start; justify-content:center;
                box-sizing:border-box; padding:24px 12px 72px;
                background:Canvas; color:CanvasText;
              }
              img { display:block; max-width:none; height:auto; }
            </style></head><body>
            <img src="data:image/svg+xml;base64,\(encoded)" alt="SVG diagram">
            </body></html>
            """
        }
    }
}
#endif
