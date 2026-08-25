#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import WikiFSCore

/// Cached access to the trusted Mermaid runtime bundled with the app.
enum MermaidRendererAssets {
    nonisolated static let sharedCSS = """
    .mermaid { text-align:center; margin:0 0 1em; overflow:auto; }
    .mermaid svg { max-width:100%; height:auto; }
    """

    nonisolated static let library = library(in: .main)

    nonisolated static func library(in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "mermaid", withExtension: "js"),
              let source = DebugLog.trying(
                  "load mermaid.js",
                  operation: { try String(contentsOf: url, encoding: .utf8) }),
              source.isEmpty == false
        else { return nil }
        return source
    }
}

enum MermaidRendererTheme: String, Sendable {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }

    nonisolated var mermaidName: String {
        switch self {
        case .light: "default"
        case .dark: "dark"
        }
    }
}

/// Renders one Mermaid diagram as renderer content, without inline-reader card chrome.
struct MermaidRendererView: View {
    @Environment(\.colorScheme) private var colorScheme

    let source: String
    var library: String? = MermaidRendererAssets.library
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    var body: some View {
        MermaidRendererWebView(
            source: source,
            library: library,
            theme: MermaidRendererTheme(colorScheme: colorScheme),
            zoom: readerZoom)
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

struct MermaidRendererWebView: NSViewRepresentable {
    let source: String
    let library: String?
    let theme: MermaidRendererTheme
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
        context.coordinator.load(source: source, library: library, theme: theme, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        let contentIdentity = Coordinator.contentIdentity(source: source, library: library, theme: theme)
        guard context.coordinator.loadedContentIdentity != contentIdentity else { return }
        context.coordinator.load(source: source, library: library, theme: theme, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedContentIdentity: Int?

        func load(
            source: String,
            library: String?,
            theme: MermaidRendererTheme,
            into webView: WKWebView
        ) {
            loadedContentIdentity = Self.contentIdentity(source: source, library: library, theme: theme)
            webView.loadHTMLString(
                Self.documentHTML(source: source, library: library, theme: theme),
                baseURL: nil)
        }

        nonisolated static func contentIdentity(
            source: String,
            library: String?,
            theme: MermaidRendererTheme
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(source)
            hasher.combine(library)
            hasher.combine(theme.rawValue)
            return hasher.finalize()
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
            library: String? = MermaidRendererAssets.library,
            theme: MermaidRendererTheme
        ) -> String {
            let escapedSource = HTMLEntities.escapeHTML(source)
            guard let library else {
                return fallbackHTML(source: escapedSource)
            }
            let width = Int(PageEditorMetrics.readableContentWidth)
            let mermaidTheme = theme.mermaidName
            return """
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
            <style>
              html, body { width: 100%; min-height: 100%; margin: 0; }
              body {
                display: flex; align-items: flex-start; justify-content: center;
                box-sizing: border-box; padding: 24px 12px 72px;
                color: CanvasText; background: Canvas;
                font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                font-size: 15px; line-height: 1.55;
              }
              #diagram { box-sizing: border-box; width: \(width)px; max-width: 100%; }
              \(MermaidRendererAssets.sharedCSS)
              #error { width: \(width)px; max-width: 100%; white-space: pre-wrap; color: #ff453a; }
            </style></head><body>
            <div id="diagram" class="mermaid" aria-label="Mermaid diagram" data-mermaid-theme="\(mermaidTheme)">\(escapedSource)</div>
            <pre id="error" role="alert" hidden></pre>
            <script>\(library)</script>
            <script>
            (function(){
              var diagram = document.getElementById('diagram');
              var error = document.getElementById('error');
              try {
                mermaid.initialize({ startOnLoad:false, securityLevel:'strict', theme:'\(mermaidTheme)' });
                mermaid.run({ nodes:[diagram] }).catch(function(reason){
                  diagram.hidden = true;
                  error.hidden = false;
                  error.textContent = 'The Mermaid diagram could not be rendered.\\n\\n' + String(reason);
                });
              } catch (reason) {
                diagram.hidden = true;
                error.hidden = false;
                error.textContent = 'The Mermaid diagram could not be rendered.\\n\\n' + String(reason);
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
