#if os(macOS)
import Foundation
import WikiFSCore

/// The reader document's dedicated custom-scheme origin.
///
/// The reader parent document must frame custom-scheme documents
/// (`renderer-package:` iframes, `wiki-blob:` PDF/HTML frames). WebKit's
/// custom-scheme CORS enforcement blocks framed custom-scheme loads from an
/// https parent (proven in Phase 1 hosted probes), so the reader loads via
/// `loadHTMLString(baseURL:)` under this dedicated scheme instead of the
/// retired synthetic https origin.
///
/// The host is a fixed sentinel (`reader`), not per-frame: the reader
/// document is app-authored, not untrusted. Untrusted package content is
/// isolated by the per-frame `RendererFrameOriginToken` origins.
///
/// This origin must never be stamped into any external URL: provider-hosted
/// media is not embedded inline in the reader (operator decision of
/// 2026-09-03), so no external player validates it.
enum WikiReaderDocumentOrigin {
    static let scheme = "wiki-reader"
    /// The fixed host for the reader parent document.
    static let host = "reader"
    /// The baseURL for `loadHTMLString`. Pathless so relative fragment links
    /// resolve against the document root.
    static var url: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/document.html"
        return components.url
    }

    /// Returns `true` for a fragment link within the reader document.
    ///
    /// `WKWebView` resolves `href="#target"` against the baseURL. The
    /// resulting URL must bypass relative source-link routing so WebKit can
    /// scroll to the target.
    static func isSameDocumentFragment(_ url: URL) -> Bool {
        guard url.scheme == scheme,
              url.host == host,
              url.fragment != nil,
              url.query == nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/document.html"
    }
}
#endif
