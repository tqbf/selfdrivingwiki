#if os(macOS)
import Foundation
import WikiFSCore

/// The reader document's dedicated custom-scheme origin.
///
/// The reader parent document must frame custom-scheme documents
/// (`renderer-package:` iframes, `wiki-blob:` PDF/HTML frames). WebKit's
/// custom-scheme CORS enforcement blocks framed custom-scheme loads from an
/// https parent (proven in Phase 1 hosted probes), so the reader loads via a
/// real navigation under this dedicated scheme instead of the retired
/// synthetic https origin.
///
/// The host is a fixed sentinel (`reader`), not per-frame: the reader
/// document is app-authored, not untrusted. Untrusted package content is
/// isolated by the per-frame `RendererFrameOriginToken` origins.
///
/// Each load's document URL carries a `?load=<uuid>` staging token so the
/// scheme handler serves that navigation **its own** staged document (see
/// `ReaderDocumentStaging`): overlapping loads cannot cross-consume each
/// other's HTML, and a staging miss fails the navigation loudly instead of
/// rendering a silent empty page. The origin (scheme + host + path) is
/// unchanged by the token; only the query varies per load.
///
/// This origin must never be stamped into any external URL: provider-hosted
/// media is not embedded inline in the reader (operator decision of
/// 2026-09-03), so no external player validates it.
enum WikiReaderDocumentOrigin {
    static let scheme = "wiki-reader"
    /// The fixed host for the reader parent document.
    static let host = "reader"
    /// Query item name carrying a load's staging token.
    static let loadTokenQueryItem = "load"
    /// The document path. Shared by every load; the token lives in the query.
    static let documentPath = "/document.html"

    /// The document URL for one staged load. Non-optional: every component is
    /// a constant, so construction cannot fail — the `precondition` pins that
    /// invariant instead of pretending an impossible optional.
    static func url(loadToken: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = documentPath
        components.queryItems = [
            URLQueryItem(name: loadTokenQueryItem, value: loadToken.uuidString)
        ]
        guard let url = components.url else {
            preconditionFailure("reader document URL construction failed with constant components")
        }
        return url
    }

    /// Extracts the staging token from a document URL, if the URL is a reader
    /// document URL carrying exactly one syntactically valid `load` query
    /// item. Anything else (no query, unrelated queries, malformed UUIDs,
    /// duplicate items) yields `nil` and the scheme task fails loudly.
    static func loadToken(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems,
            items.count == 1,
            let item = items.first,
            item.name == loadTokenQueryItem,
            let value = item.value,
            let token = UUID(uuidString: value)
        else { return nil }
        return token
    }

    /// Returns `true` for a fragment link within the reader document.
    ///
    /// `WKWebView` resolves `href="#target"` against the tokenized baseURL,
    /// and the resolved URL retains the base's `?load=<uuid>` query. The link
    /// is same-document exactly when its query is absent or is that one valid
    /// staging token; unrelated or malformed queries are rejected so they
    /// cannot masquerade as in-document anchors.
    static func isSameDocumentFragment(_ url: URL) -> Bool {
        guard url.scheme == scheme,
              url.host == host,
              url.fragment != nil,
              isOwnOrEmptyQuery(url),
              url.path.isEmpty || url.path == documentPath else {
            return false
        }
        return true
    }

    /// The query is either absent (a plain anchor) or exactly one
    /// syntactically valid `load` token — what a fragment link resolved
    /// against the current tokenized base carries.
    ///
    /// Foundation quirk (probed 2026-09-10): `URL(string: "#f", relativeTo:)`
    /// against a base with a query yields a URL that retains the query in
    /// `absoluteString`/`query`, but `URLComponents(url:resolvingAgainstBase
    /// URL:)` returns `nil` for it. Parsing the same absolute string succeeds,
    /// so fall back to that before treating the URL as query-less.
    private static func isOwnOrEmptyQuery(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            ?? URLComponents(string: url.absoluteString)
        guard let items = components?.queryItems, items.isEmpty == false else {
            return true
        }
        guard items.count == 1,
              let item = items.first,
              item.name == loadTokenQueryItem,
              let value = item.value,
              UUID(uuidString: value) != nil
        else { return false }
        return true
    }
}
#endif
