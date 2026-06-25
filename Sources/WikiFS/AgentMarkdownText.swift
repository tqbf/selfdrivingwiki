import AppKit
import SwiftUI
import WebKit

/// Leaf renderer for Claude-authored prose in the agent transcript. Claude often
/// emits Markdown (lists, headings, code fences, links).
///
/// Rendered through a `WKWebView` (markdown → HTML via `MarkdownHTMLRenderer`,
/// the same renderer the large-source reader uses) so the whole message is a
/// **single native text surface**: selection and copy span the entire message,
/// crossing paragraphs, lists, and code fences. (Textual `StructuredText` lays
/// each block out as a separate selectable `Text`, so selection stopped at block
/// boundaries.)
///
/// The web view measures its own content height via JS
/// (`document.body.scrollHeight` + a `ResizeObserver`) and reports it back so the
/// view sizes vertically to its content inside the parent scroll view.
struct AgentMarkdownText: View {
    let markdown: String
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        AgentMarkdownWebView(markdown: markdown, contentHeight: $contentHeight)
            // Frame to the measured content height so the non-scrolling web view
            // fits its content inside the parent ScrollView.
            .frame(height: max(contentHeight, 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Re-create on markdown change so stale height from a previous
            // message never lingers.
            .id(markdown)
    }
}

// MARK: - WKWebView bridge

private struct AgentMarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: Self.heightHandler)
        config.userContentController = userContent
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Transparent so it blends into the row; the document body also has no
        // background. (`underPageBackgroundColor` is the WKWebView seam for this.)
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView
        context.coordinator.load(markdown: markdown)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.markdown != markdown {
            context.coordinator.load(markdown: markdown)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.heightHandler)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private static let heightHandler = "sdwhlHeight"

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let parent: AgentMarkdownWebView
        weak var webView: WKWebView?
        var markdown: String?

        init(parent: AgentMarkdownWebView) { self.parent = parent }

        func load(markdown: String) {
            self.markdown = markdown
            let body = MarkdownHTMLRenderer.render(markdown)
            let html = Self.document(wrapping: body)
            webView?.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure()
        }

        /// Re-measure after the initial layout pass settles (images, late
        /// reflow) — a backstop for the JS ResizeObserver.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            measure()
        }

        private func measure() {
            webView?.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                self.applyHeight(result)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            applyHeight(message.body)
        }

        private func applyHeight(_ value: Any?) {
            guard let height = value as? Double, height > 0 else { return }
            let cg = CGFloat(height)
            DispatchQueue.main.async {
                // Avoid feedback loops from rounding noise.
                if abs(self.parent.contentHeight - cg) > 0.5 {
                    self.parent.contentHeight = cg
                }
            }
        }

        /// Open external links in the default browser instead of navigating the
        /// inline web view.
        @MainActor func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// Minimal inline document — tight margins (it lives inside a row), no
        /// fixed max-width, transparent background, light/dark via `color-scheme`.
        static func document(wrapping body: String) -> String {
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
              html, body { margin: 0; padding: 0; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                font-size: 13px; line-height: 1.5; color: var(--text);
                -webkit-font-smoothing: antialiased;
                -webkit-text-size-adjust: 100%;
              }
              p { margin: 0 0 0.6em; }
              p:last-child { margin-bottom: 0; }
              h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 0.7em 0 0.3em; }
              h1 { font-size: 1.25em; } h2 { font-size: 1.15em; }
              h3 { font-size: 1.05em; } h4, h5, h6 { font-size: 1em; }
              strong { font-weight: 600; }
              a { color: -webkit-link; }
              code {
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                font-size: 0.9em; background: var(--code-bg);
                padding: 0.1em 0.35em; border-radius: 4px;
              }
              pre {
                margin: 0 0 0.6em; padding: 8px 10px;
                background: var(--code-bg); border-radius: 6px; overflow: auto;
              }
              pre code { background: none; padding: 0; font-size: 0.9em; }
              ul, ol { padding-left: 1.4em; margin: 0 0 0.6em; }
              li { margin: 0.1em 0; }
              blockquote {
                margin: 0 0 0.6em; padding: 0 0 0 0.8em;
                border-left: 3px solid var(--border); color: var(--muted);
              }
            </style>
            </head><body>\(body)
            <script>
              (function () {
                var h = window.webkit.messageHandlers.sdwhlHeight;
                function report() {
                  var hgt = document.body.scrollHeight;
                  if (hgt > 0) { h.postMessage(hgt); }
                }
                window.addEventListener('load', report);
                // Re-measure when the body's box changes (e.g. sidebar resize
                // reflows the wrapped text).
                if (window.ResizeObserver) {
                  new ResizeObserver(report).observe(document.body);
                }
              })();
            </script>
            </body></html>
            """
        }
    }
}

#if DEBUG
#Preview {
    AgentMarkdownText(
        markdown: """
        ## Answer

        - **One** thing
        - `Another` thing

        ```sh
        wikictl page list
        ```

        A second paragraph with a [link](https://example.com).
        """
    )
    .padding()
    .frame(width: 360)
}
#endif
