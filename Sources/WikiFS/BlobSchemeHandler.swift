import Foundation
import WebKit
import WikiFSCore

/// Serves source blob bytes from SQLite to the WKWebView via the custom
/// `wiki-blob://source/<id>` scheme. Registered on the `WKWebViewConfiguration`
/// in `WikiReaderWebView.init()`. Resolves the source id → `(bytes, mimeType)`
/// through `WikiStoreModel.sourceContentAndMIME(id:)`.
///
/// Thread safety: Apple's documentation states that `WKURLSchemeHandler` methods
/// are always called on the main thread. The handler holds a weak reference to
/// the `@MainActor` `WikiStoreModel`. `MainActor.assumeIsolated` bridges the
/// non-isolated protocol method to the `@MainActor` store access.
final class BlobSchemeHandler: NSObject, WKURLSchemeHandler {

    weak var store: WikiStoreModel?

    /// Matches `WikiLinkMarkdown.blobScheme` — declared separately so the handler
    /// doesn't need to import it from `WikiFSCore` at the use site.
    static let scheme = WikiLinkMarkdown.blobScheme

    init(store: WikiStoreModel?) {
        self.store = store
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        // WKURLSchemeHandler methods are called on the main thread (Apple docs).
        MainActor.assumeIsolated {
            serve(urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // All work is synchronous in start(); nothing to cancel.
    }

    // MARK: - Private

    /// Internal (not private) so tests can call it directly without creating a
    /// real WKWebView. The `webView` parameter in the protocol method is unused.
    @MainActor func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme == Self.scheme,
              url.host == "source" else {
            respond404(task, url: task.request.url)
            return
        }

        // Path is "/<ULID>" — strip the leading slash.
        let idStr = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !idStr.isEmpty else {
            respond404(task, url: url)
            return
        }
        let id = PageID(rawValue: idStr)

        guard let store, let (data, mimeType) = store.sourceContentAndMIME(id: id) else {
            respond404(task, url: url)
            return
        }

        let headers = [
            "Content-Type": mimeType ?? "application/octet-stream",
            "Content-Length": "\(data.count)"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func respond404(_ task: WKURLSchemeTask, url: URL?) {
        let response = HTTPURLResponse(url: url ?? URL(string: "about:blank")!,
                                       statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        task.didReceive(response)
        task.didFinish()
    }
}
