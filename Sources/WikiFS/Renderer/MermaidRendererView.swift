#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import WikiFSCore

/// Cached access to the trusted Mermaid runtime bundled with the app.
enum MermaidRendererAssets {
    nonisolated static let library: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
              let source = DebugLog.trying(
                  "load mermaid.js",
                  operation: { try String(contentsOf: url, encoding: .utf8) }),
              source.isEmpty == false
        else { return nil }
        return source
    }()
}

/// Renders one Mermaid diagram as renderer content, without inline-reader card chrome.
struct MermaidRendererView: View {
    let source: String
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    var body: some View {
        MermaidRendererWebView(source: source, zoom: readerZoom)
            .zoomShortcuts($readerZoom)
            .zoomScroll($readerZoom)
    }
}

struct MermaidRendererWebView: NSViewRepresentable {
    let source: String
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoom
        context.coordinator.load(source: source, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        guard context.coordinator.loadedSource != source else { return }
        context.coordinator.load(source: source, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedSource: String?

        func load(source: String, into webView: WKWebView) {
            loadedSource = source
            webView.loadHTMLString(Self.documentHTML(source: source), baseURL: nil)
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

        nonisolated static func documentHTML(
            source: String,
            library: String? = MermaidRendererAssets.library
        ) -> String {
            let escapedSource = HTMLEntities.escapeHTML(source)
            guard let library else {
                return fallbackHTML(source: escapedSource)
            }
            return """
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
            <style>
              html, body { width: 100%; min-height: 100%; margin: 0; }
              body {
                display: flex; align-items: flex-start; justify-content: center;
                box-sizing: border-box; padding: 24px;
                color: CanvasText; background: Canvas;
                font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
              }
              #diagram { max-width: 100%; }
              #diagram svg { max-width: 100%; height: auto; }
              #error { max-width: 720px; white-space: pre-wrap; color: #ff453a; }
            </style></head><body>
            <div id="diagram" aria-label="Mermaid diagram"></div>
            <pre id="source" hidden>\(escapedSource)</pre>
            <pre id="error" role="alert" hidden></pre>
            <script>\(library)</script>
            <script>
            (function(){
              var diagram = document.getElementById('diagram');
              var source = document.getElementById('source').textContent;
              var error = document.getElementById('error');
              var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
              try {
                mermaid.initialize({ startOnLoad:false, securityLevel:'strict', theme:dark ? 'dark' : 'default' });
                diagram.textContent = source;
                mermaid.run({ nodes:[diagram] }).catch(function(reason){
                  diagram.hidden = true;
                  error.hidden = false;
                  error.textContent = 'The Mermaid diagram could not be rendered.\n\n' + String(reason);
                });
              } catch (reason) {
                diagram.hidden = true;
                error.hidden = false;
                error.textContent = 'The Mermaid diagram could not be rendered.\n\n' + String(reason);
              }
            })();
            </script></body></html>
            """
        }

        nonisolated private static func fallbackHTML(source: String) -> String {
            """
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <style>
              body { margin: 0; padding: 24px; color: CanvasText; background: Canvas; }
              pre { white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            </style></head><body><pre>\(source)</pre></body></html>
            """
        }
    }
}
#endif
