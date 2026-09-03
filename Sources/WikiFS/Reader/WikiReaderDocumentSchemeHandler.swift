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
    /// The scheme string this handler serves.
    static let scheme = "wiki-reader"

    /// The converted reader document body for the next navigation. The
    /// coordinator sets this right before `load(request:)`; the handler
    /// consumes it when WebKit starts the navigation task.
    private static var pendingHTML: String?

    static func setPendingHTML(_ html: String) {
        pendingHTML = html
    }

    /// A shared instance: the handler answers the navigation with the
    /// pending HTML set by the coordinator.
    static let shared = WikiReaderDocumentSchemeHandler()

    override private init() {
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let body = Self.consumePendingHTML()
            ?? Data("<!doctype html><html><body></body></html>".utf8)
        let response = URLResponse(
            url: urlSchemeTask.request.url ?? URL(string: "about:blank")!,
            mimeType: "text/html",
            expectedContentLength: body.count,
            textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    private static func consumePendingHTML() -> Data? {
        guard let html = pendingHTML else { return nil }
        pendingHTML = nil
        return Data(html.utf8)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
