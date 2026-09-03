#if os(macOS)
import WebKit
import WikiFSCore

// pattern: Imperative Shell — serves the app-authored reader document shell.

/// Serves the reader parent document under the `wiki-reader:` scheme.
///
/// WebKit only honors a custom-scheme `loadHTMLString(baseURL:)` when the
/// scheme has a registered `WKURLSchemeHandler` (proven in hosted probes:
/// without a handler the document silently falls back to `about:blank`).
/// This handler exists to satisfy that requirement: the reader loads its
/// app-authored HTML via `loadHTMLString`, and the handler answers the
/// registration probe so WebKit treats `wiki-reader://reader/document.html`
/// as a real document origin.
///
/// The handler never serves untrusted bytes. Package content is isolated by
/// per-frame token origins through `ReaderRendererPackageRouter`; blob bytes
/// are served by `BlobSchemeHandler` from the exact-version store.
@MainActor
final class WikiReaderDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    /// A shared no-op instance: `loadHTMLString` supplies the document body,
    /// so any task WebKit starts is answered with an empty 200 to satisfy the
    /// registration probe without duplicating the HTML payload.
    static let shared = WikiReaderDocumentSchemeHandler()

    override private init() {
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        // `loadHTMLString` renders the body; the handler only validates the
        // scheme's registration. Answer with an empty HTML document for any
        // direct navigation (never reached in production reader flow).
        let body = Data("<!doctype html><html><body></body></html>".utf8)
        let response = URLResponse(
            url: urlSchemeTask.request.url ?? WikiReaderDocumentOrigin.url ?? URL(string: "about:blank")!,
            mimeType: "text/html",
            expectedContentLength: body.count,
            textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
