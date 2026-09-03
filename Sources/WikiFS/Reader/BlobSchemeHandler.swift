import Foundation
import WebKit
import WikiFSCore

/// Serves source blob bytes from SQLite to the WKWebView via two routes:
///
/// - `wiki-blob://source/<SourceID>` — compatibility route, resolves the
///   source's current active version (current HEAD).
/// - `wiki-blob://source-version/<SourceVersionID>` — exact immutable
///   version route used by renderer admission. Resolves the version row
///   directly through `WikiStore.sourceVersion(id:)` +
///   `sourceContent(versionID:)` and returns the stored MIME; never
///   substitutes HEAD.
///
/// Registered on the `WKWebViewConfiguration` in `WikiReaderWebView.init()`.
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

    /// Host for the compatibility current-HEAD route.
    static let sourceHost = WikiLinkMarkdown.sourceHost
    /// Host for the exact-version route (renderer admission).
    static let sourceVersionHost = "source-version"

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
              url.scheme == Self.scheme else {
            respond404(task, url: task.request.url)
            return
        }
        switch url.host {
        case Self.sourceHost:
            serveCurrentHEAD(id: url, task: task)
        case Self.sourceVersionHost:
            serveExactVersion(url: url, task: task)
        default:
            respond404(task, url: url)
        }
    }

    /// Compatibility route: `wiki-blob://source/<SourceID>` resolves HEAD.
    @MainActor private func serveCurrentHEAD(id url: URL, task: WKURLSchemeTask) {
        // Path is "/<ULID>" — strip the leading slash.
        let idStr = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !idStr.isEmpty else {
            respond404(task, url: url)
            return
        }
        let id = SourceID(rawValue: idStr)

        guard let store, let (data, mimeType) = store.sourceContentAndMIME(id: id) else {
            respond404(task, url: url)
            return
        }
        respond200(task, url: url, data: data, mimeType: mimeType)
    }

    /// Exact-version route: `wiki-blob://source-version/<SourceVersionID>`.
    /// Reads the immutable version row; a HEAD edit never changes the bytes
    /// served here. Returns the version's stored MIME, never a guess.
    @MainActor private func serveExactVersion(url: URL, task: WKURLSchemeTask) {
        // Path is "/<ULID>" — strip the leading slash.
        let idStr = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard let store, idStr.isEmpty == false else {
            respond404(task, url: url)
            return
        }
        let versionID = SourceVersionID(rawValue: idStr)
        let version = DebugLog.trying(
            "sourceVersion(id:)",
            operation: { try store.internalStore.sourceVersion(id: versionID) })
        guard let version else {
            respond404(task, url: url)
            return
        }
        let data = DebugLog.trying(
            "sourceContent(versionID:)",
            operation: { try store.internalStore.sourceContent(versionID: versionID) }) ?? Data()
        respond200(task, url: url, data: data, mimeType: version.mimeType)
    }

    @MainActor private func respond200(
        _ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String?
    ) {
        let headers = [
            "Content-Type": mimeType ?? MimeType.octetStream,
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
