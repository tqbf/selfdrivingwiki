#if os(macOS)
import WebKit
import WikiFSCore

// pattern: Imperative Shell — serves the app-authored reader document shell.

/// Staging errors surfaced by the reader document scheme handler.
enum WikiReaderDocumentError: Error {
    /// A scheme task started for a token with no staged document. The task is
    /// failed loudly (the navigation delegate then drives the reader's error
    /// state); fallback bytes are never served.
    case missingStagedDocument(URL)

    /// A descriptive `NSError` in an app domain, for `didFailWithError`.
    var nsError: NSError {
        switch self {
        case .missingStagedDocument(let url):
            return NSError(
                domain: "WikiReaderDocument",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No staged reader document for \(url.absoluteString)",
                    NSURLErrorKey: url,
                ])
        }
    }
}

/// Process-wide, token-keyed staging store for reader documents.
///
/// Every load mints a `UUID`; the coordinator stages the converted HTML under
/// that token and the document URL carries it
/// (`wiki-reader://reader/document.html?load=<uuid>`), so a navigation can only
/// ever consume **its own** document. This replaces a single process-wide
/// pending slot, where two overlapping loads cross-consumed each other's HTML
/// and the loser was served a silent empty document.
///
/// Retention contract (two-tier):
/// - An entry is **pending** from `stage` until its scheme task first starts,
///   then **served**. Pending entries are **never evicted** — a
///   not-yet-dispatched navigation cannot be starved — and are retired by
///   owner teardown (`forget`/`forgetAll`).
/// - Served entries are kept for idempotent re-issue (a re-issued task
///   re-serves the same bytes) and are bounded by an oldest-served LRU cap
///   (`servedCapacity`). Evicting one downgrades only a hypothetical re-issue
///   to a loud, logged miss.
/// - There is deliberately **no forget-on-restage**: retiring a prior token
///   when a newer load is staged can starve a superseded navigation whose
///   scheme task dispatches late (`webView.load` returning does not prove
///   WebKit has dispatched — or will never dispatch — the superseded
///   navigation's scheme task).
/// - A miss (`beginServing` returning `nil`) means the caller must fail the
///   scheme task with `WikiReaderDocumentError.missingStagedDocument`. No code
///   path serves fallback bytes.
@MainActor
enum ReaderDocumentStaging {
    /// Maximum number of *served* entries retained for idempotent re-issue.
    static let servedCapacity = 8

    private struct Entry {
        let bytes: Data
        var isServed = false
        var servedRecency = 0
    }

    private static var entries: [UUID: Entry] = [:]
    private static var recencyClock = 0

    /// Inserts a *pending* entry for `token`. Staging a newer load never
    /// touches existing entries (no forget-on-restage).
    static func stage(_ html: String, token: UUID) {
        entries[token] = Entry(bytes: Data(html.utf8))
    }

    /// The single operation the scheme handler calls on task start: on a hit,
    /// atomically transitions pending→served (refreshing LRU recency if the
    /// entry was already served), applies oldest-served eviction, and returns
    /// the bytes. On a miss, returns `nil` so the caller fails the task loudly.
    ///
    /// Re-issue is idempotent: a token already served re-serves the same bytes.
    static func beginServing(token: UUID) -> Data? {
        guard var entry = entries[token] else { return nil }
        if entry.isServed == false {
            entry.isServed = true
        }
        recencyClock += 1
        entry.servedRecency = recencyClock
        entries[token] = entry
        evictOldestServed(excluding: token)
        return entry.bytes
    }

    /// Removes one token (owner teardown, or nil-load-seam cleanup for a token
    /// that can never be dispatched).
    static func forget(token: UUID) {
        entries.removeValue(forKey: token)
    }

    /// Removes every token in `tokens` (coordinator teardown retires its own).
    static func forgetAll(_ tokens: some Sequence<UUID>) {
        for token in tokens {
            entries.removeValue(forKey: token)
        }
    }

    /// Clears all staged state. Test seam only — production relies on owner
    /// teardown; the LRU cap bounds growth.
    static func resetForTesting() {
        entries.removeAll()
        recencyClock = 0
    }

    /// Bounds *served* entries at `servedCapacity`, evicting the least
    /// recently served first. Pending entries are never touched. `protected`
    /// (the token just served) is excluded as an eviction candidate so the
    /// current serve always wins — but it still counts toward the cap.
    private static func evictOldestServed(excluding protected: UUID) {
        let servedCount = entries.values.filter(\.isServed).count
        guard servedCount > servedCapacity else { return }
        var evictable = entries.compactMap { token, entry -> (token: UUID, recency: Int)? in
            guard entry.isServed, token != protected else { return nil }
            return (token, entry.servedRecency)
        }
        evictable.sort { $0.recency < $1.recency }
        for candidate in evictable.prefix(servedCount - servedCapacity) {
            entries.removeValue(forKey: candidate.token)
        }
    }
}

/// Serves the reader parent document under the `wiki-reader:` scheme.
///
/// WebKit only honors a custom-scheme `loadHTMLString(baseURL:)` when the
/// scheme has a registered `WKURLSchemeHandler` (proven in hosted probes:
/// without a handler the document silently falls back to `about:blank`).
/// This handler exists to satisfy that requirement: the reader loads its
/// app-authored HTML via a real navigation to
/// `wiki-reader://reader/document.html?load=<uuid>`, and the handler answers
/// the navigation with the HTML staged under that token (see
/// `ReaderDocumentStaging` for the staging contract: token-keyed; two-tier
/// pending/served retention — no forget-on-restage, pending never evicted,
/// oldest-served LRU on served entries; retire-all on coordinator dismantle;
/// a staging miss **fails the task**).
///
/// The handler never serves untrusted bytes. Package content is isolated by
/// per-frame token origins through `ReaderRendererPackageRouter`; blob bytes
/// are served by `BlobSchemeHandler` from the exact-version store.
@MainActor
final class WikiReaderDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The scheme string this handler serves.
    static let scheme = "wiki-reader"

    /// A shared instance: every reader webview registers this handler and the
    /// token in the request URL selects the document.
    static let shared = WikiReaderDocumentSchemeHandler()

    override private init() {
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let token = url.flatMap(WikiReaderDocumentOrigin.loadToken(from:))
        guard let token,
              let body = ReaderDocumentStaging.beginServing(token: token) else {
            DebugLog.reader(
                "reader document staging MISS for token \(token?.uuidString ?? "nil") (url \(url?.absoluteString ?? "nil"))")
            urlSchemeTask.didFailWithError(
                WikiReaderDocumentError.missingStagedDocument(url ?? URL(string: "about:blank")!).nsError)
            return
        }
        let response = URLResponse(
            url: url ?? URL(string: "about:blank")!,
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
