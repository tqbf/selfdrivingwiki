import AppKit
import SwiftUI
import WebKit
import WikiFSCore

// MARK: - JSONRenderView

/// Renders a json-render form spec in a `WKWebView` via the vendored
/// `jsonrender-form.js` bundle. The form renderer takes a base64-encoded spec
/// and renders HTML form primitives; actions emitted by button clicks
/// round-trip to Swift via `WKScriptMessageHandler`.
///
/// Modeled on `WikiReaderView` — same resource resolution pattern
/// (`Bundle.main` → `Bundle.module` fallback), same `NSViewRepresentable`
/// wrapping approach. No scheme handler needed (the form renderer is
/// self-contained).
///
/// **Resource resolution:** the JS source is resolved via a `Bundle.main` →
/// `Bundle.module` fallback chain. In the built `.app` (build.sh copies the
/// JS to `Contents/Resources/`), `Bundle.main` hits. Under `swift test`
/// (SwiftPM resource via `resources: [.copy("jsonrender-form.js")]`),
/// `Bundle.module` hits. Unlike Mermaid (which degrades gracefully to code
/// blocks when unbundled), the form renderer IS the feature — it has no
/// fallback and MUST resolve.
struct JSONRenderView: View {
    /// The base64-encoded json-render form spec to render.
    let specBase64: String
    /// Called when a form action (e.g. "addSource") is emitted from the webview.
    var onAction: ((String, [String: Any]) -> Void)? = nil

    var body: some View {
        JSONRenderRep(specBase64: specBase64, onAction: onAction)
    }
}

// MARK: - NSViewRepresentable bridge

/// `NSViewRepresentable` that hosts the `WKWebView` for `JSONRenderView`.
struct JSONRenderRep: NSViewRepresentable {
    let specBase64: String
    var onAction: ((String, [String: Any]) -> Void)?

    func makeNSView(context: Context) -> JSONRenderWebView {
        let webView = JSONRenderWebView()
        webView.onAction = onAction
        webView.loadHarness()
        return webView
    }

    func updateNSView(_ webView: JSONRenderWebView, context: Context) {
        webView.onAction = onAction
        webView.applySpec(specBase64)
    }
}

// MARK: - WKWebView subclass

/// The `WKWebView` that hosts the form renderer. Registers message handlers
/// for `addAction` (form button clicks → Swift), `log`, and `error`.
@MainActor
final class JSONRenderWebView: WKWebView, WKNavigationDelegate {
    var onAction: ((String, [String: Any]) -> Void)?
    private var pendingSpec: String?
    private var pageLoaded = false

    init() {
        let config = WKWebViewConfiguration()
        let cc = WKUserContentController()
        let actionProxy = ActionMessageHandler(target: nil)
        cc.add(actionProxy, name: "addAction")
        cc.add(LogMessageHandler(name: "log"), name: "log")
        cc.add(LogMessageHandler(name: "error"), name: "error")
        config.userContentController = cc
        super.init(frame: .zero, configuration: config)
        self.navigationDelegate = self
        actionProxy.target = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Load the HTML harness that inlines the form renderer JS + CSS.
    func loadHarness() {
        loadHTMLString(Self.harnessHTML(), baseURL: URL(string: "about:blank"))
    }

    /// Inject the spec via `applyBase64`. Caches the spec and applies it once
    /// the harness finishes loading (handles the race between `makeNSView` and
    /// `updateNSView`). Skips re-application if the spec is unchanged — SwiftUI
    /// re-renders trigger `updateNSView`, and re-applying would reset the form
    /// state model (the JS `render()` reinitializes `state` from `spec.state`).
    private var lastAppliedSpec: String?

    func applySpec(_ b64: String) {
        pendingSpec = b64
        guard pageLoaded else { return }
        guard b64 != lastAppliedSpec else { return }
        lastAppliedSpec = b64
        evaluateJavaScript(JSONRenderPayloadEncoder.applyScript(b64)) { _, _ in }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let spec = pendingSpec {
            evaluateJavaScript(JSONRenderPayloadEncoder.applyScript(spec)) { _, _ in }
        }
    }

    // MARK: - Resource resolution + HTML harness

    /// The vendored form renderer JS source. Resolved via `Bundle.main` (built
    /// `.app`) → `Bundle.module` (`swift test`) fallback. Unlike Mermaid, this
    /// has no graceful degradation — the form renderer IS the feature.
    nonisolated static let formRendererJS: String? = {
        for bundle in [Bundle.main, Bundle.module] {
            guard let url = bundle.url(forResource: "jsonrender-form", withExtension: "js") else { continue }
            do {
                let src = try String(contentsOf: url, encoding: .utf8)
                if !src.isEmpty { return src }
            } catch {
                DebugLog.reader("formRendererJS: failed to read \(url.path): \(error)")
            }
        }
        return nil
    }()

    /// CSS for the form renderer — reuses the reader's CSS variables for
    /// dark/light theming (same convention as `WikiReaderView.documentHTML`).
    nonisolated static let formCSS = """
    :root {
      --text: #1c1c1e;
      --muted: rgba(60, 60, 67, 0.6);
      --bg: rgba(0, 0, 0, 0.06);
      --border: rgba(0, 0, 0, 0.12);
      --accent: #007aff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #e6e6e6;
        --muted: rgba(235, 235, 245, 0.6);
        --bg: rgba(255, 255, 255, 0.08);
        --border: rgba(255, 255, 255, 0.16);
      }
    }
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      font-size: 13px; line-height: 1.45;
      color: var(--text);
      padding: 20px; margin: 0;
      -webkit-font-smoothing: antialiased;
    }
    .wiki-render-stack { display: flex; flex-direction: column; gap: 12px; max-width: 480px; }
    .wiki-render-stack-h { flex-direction: row; align-items: center; flex-wrap: wrap; }
    .wiki-field { display: flex; flex-direction: column; gap: 4px; }
    .wiki-field > label { font-size: 12px; font-weight: 500; color: var(--muted); }
    .wiki-field > label > input[type="checkbox"] { margin-right: 4px; }
    .wiki-field input, .wiki-field select {
      padding: 6px 8px;
      border: 1px solid var(--border); border-radius: 6px;
      background: transparent; color: var(--text);
      font-size: 13px; font-family: inherit;
    }
    .wiki-field input:focus, .wiki-field select:focus {
      outline: none; border-color: var(--accent);
      box-shadow: 0 0 0 3px rgba(0, 122, 255, 0.2);
    }
    .wiki-daterange .wiki-daterange-inputs { display: flex; gap: 8px; }
    .wiki-daterange .wiki-daterange-inputs input { flex: 1; }
    .wiki-btn {
      padding: 6px 16px; border: none; border-radius: 6px;
      background: var(--accent); color: #fff;
      font-size: 13px; font-weight: 500; cursor: pointer;
      font-family: inherit;
    }
    .wiki-btn:hover { opacity: 0.9; }
    .wiki-btn:active { opacity: 0.8; }
    .wiki-text { margin: 0; color: var(--muted); }
    .wiki-unknown { color: #ff453a; font-style: italic; }
    """

    /// The HTML document: inlines the form renderer JS + CSS into a self-
    /// contained harness. No scheme handler needed (the form renderer is
    /// self-contained). Pure / callable off the main actor.
    nonisolated static func harnessHTML() -> String {
        let formJS = formRendererJS ?? ""
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>\(formCSS)</style>
        <script>\(formJS)</script>
        </head>
        <body><div id="root"></div></body></html>
        """
    }
}

// MARK: - Message handlers

/// Receives `addAction` messages from the form renderer (button clicks). Logs
/// a redacted copy via `DebugLog` before forwarding to the `onAction` callback.
@MainActor
private final class ActionMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: JSONRenderWebView?

    init(target: JSONRenderWebView?) { self.target = target }

    func userContentController(_ cc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]

        // Redact password/secret values before logging (R2: never reach Console.app).
        DebugLog.reader("addAction \(RedactionHelper.redactActionPayload(action: action, params: params))")

        target?.onAction?(action, params)
    }
}

/// Receives `log` / `error` messages from the webview and forwards to `DebugLog`.
@MainActor
private final class LogMessageHandler: NSObject, WKScriptMessageHandler {
    let name: String
    init(name: String) { self.name = name }

    func userContentController(_ cc: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = (message.body as? String) ?? String(describing: message.body)
        DebugLog.reader("jsonrender[\(name)]: \(text)")
    }
}
