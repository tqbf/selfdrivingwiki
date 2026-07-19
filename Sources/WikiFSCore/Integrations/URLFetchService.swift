import Foundation

/// Fetches a URL and lands its content as a source file in the active wiki —
/// exactly like a drag-dropped file, so the existing "Ingest into wiki" agent
/// operation can summarize it afterward.
///
/// Named `URLFetchService` (not `URLIngestService`) because it only fetches and
/// stores bytes — it does NOT run the agent "Ingest into wiki" phase. Issue #178.
///
/// Design for testability: the network is behind an injected `URLResourceFetcher`,
/// and the store write is an injected closure (`store:`). So the whole
/// dispatch / filename / store pipeline is unit-tested with a FAKE fetcher and an
/// in-memory store — no real network, deterministic. The app wires the real
/// `URLSessionFetcher` + the active `WikiStoreModel.addSource`.
///
/// Dispatch by `Content-Type`:
/// - `text/html` / `application/xhtml+xml` → store the **original HTML bytes**
///   as `.html`; the extracted markdown rides as a sidecar and is written as a
///   processed-markdown version (issue #599 — mirrors PDF → pdf2md extraction).
///   File named from the `<title>` when present.
/// - `application/pdf` → store the raw PDF bytes as `.pdf` (verbatim).
/// - other `text/*` (plain, markdown, csv…) → store the raw text as-is.
/// - anything else (images, binaries) → store raw bytes with an extension inferred
///   from the MIME type or the URL.
public struct URLFetchService {

    /// The bytes + metadata returned by a fetch. `finalURL` reflects redirects, so
    /// the filename derives from where we ended up, not where we asked.
    public struct FetchResponse: Sendable {
        public let data: Data
        public let contentType: String?
        public let finalURL: URL

        public init(data: Data, contentType: String?, finalURL: URL) {
            self.data = data
            self.contentType = contentType
            self.finalURL = finalURL
        }
    }

    /// What was stored, surfaced to the UI for the success message.
    public struct FetchOutcome: Sendable, Equatable {
        public let filename: String
        public let byteSize: Int
        /// The detected kind, for a human-readable confirmation.
        public let kind: Kind

        public enum Kind: Sendable, Equatable {
            case html           // verbatim HTML (extracted markdown stored as a processed version)
            case pdf             // verbatim PDF
            case text            // verbatim text
            case binary          // verbatim other bytes
            case podcastTranscript  // Apple Podcasts episode TTML → Markdown
            case videoEmbed      // byteless provider video embed (YouTube/Vimeo)
            case audioEmbed      // byteless provider audio embed (Spotify/SoundCloud)
            case remoteMedia     // byteless direct-remote media (mp3 stream / remote video)
            case videoTranscript // YouTube embed + extracted caption transcript → markdown
        }

        public init(filename: String, byteSize: Int, kind: Kind) {
            self.filename = filename
            self.byteSize = byteSize
            self.kind = kind
        }
    }

    /// Abstracts `URLSession.data(for:)` so tests inject canned responses.
    public protocol URLResourceFetcher: Sendable {
        func fetch(_ url: URL) async throws -> FetchResponse
    }

    /// Errors surfaced to the UI with user-readable messages.
    public enum FetchError: LocalizedError, Equatable {
        case invalidURL(String)
        case httpStatus(Int)
        case empty
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let s): return "That doesn't look like a valid URL: “\(s)”."
            case .httpStatus(let code): return "The server returned HTTP \(code)."
            case .empty: return "The URL returned no content."
            case .network(let msg): return msg
            }
        }
    }

    private let fetcher: any URLResourceFetcher
    /// Stores `(filename, data)` into the active wiki and returns nothing. The app
    /// passes `WikiStoreModel.addSource`; tests pass an in-memory collector.
    private let store: @Sendable (_ filename: String, _ data: Data) throws -> Void

    public init(
        fetcher: any URLResourceFetcher,
        store: @escaping @Sendable (_ filename: String, _ data: Data) throws -> Void
    ) {
        self.fetcher = fetcher
        self.store = store
    }

    /// Normalize raw user input into a fetchable URL: trim whitespace, and prepend
    /// `https://` when no scheme is present (paste-friendly). Returns `nil` for
    /// blank / unparseable input.
    public static func normalizeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if trimmed.hasPrefix("//") {
            withScheme = "https:" + trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        guard let url = URL(string: withScheme),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Fetch `rawInput`, dispatch by content type, and store the result in the
    /// active wiki. Returns what was stored. Throws `FetchError` on a bad URL,
    /// non-2xx status (the fetcher reports it), empty body, or a store failure.
    @discardableResult
    public func fetch(_ rawInput: String) async throws -> FetchOutcome {
        guard let url = Self.normalizeURL(rawInput) else {
            throw FetchError.invalidURL(rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        return try store(response: response)
    }

    /// The PURE dispatch + filename + store step (no network), so tests can drive it
    /// directly with a hand-built `FetchResponse`.
    @discardableResult
    public func store(response: FetchResponse) throws -> FetchOutcome {
        guard !response.data.isEmpty else { throw FetchError.empty }
        let plan = Self.plan(for: response)
        do {
            try store(plan.filename, plan.data)
        } catch {
            throw FetchError.network("Couldn't save the fetched file: \(error.localizedDescription)")
        }
        return FetchOutcome(filename: plan.filename, byteSize: plan.data.count, kind: plan.kind)
    }

    // MARK: - Dispatch plan (pure)

    /// The decision about what bytes to store under what filename — pure, so it is
    /// the unit-test target AND the seam a `@MainActor` caller can use to store
    /// directly (avoiding the `@Sendable` store closure across an actor boundary).
    public struct StorePlan: Equatable, Sendable {
        public let filename: String
        public let data: Data
        public let kind: FetchOutcome.Kind
    }

    /// The single source of truth for URL→(stem, extension) extraction. Returns
    /// the pre-computed filename stem (extension already deleted) and the
    /// lowercased extension hint (or `nil`). For root URLs the host is returned
    /// as-is (e.g. `"example.com"` — NOT with `.com` stripped).
    static func nameHint(for url: URL) -> (stem: String, ext: String?) {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            let ns = last as NSString
            let stem = ns.deletingPathExtension
            if !stem.isEmpty {
                let ext = ns.pathExtension.lowercased()
                return (stem, ext.isEmpty ? nil : ext)
            }
        }
        // Root URL: host as-is (no extension deletion — preserves "example.com").
        if let host = url.host, !host.isEmpty { return (host, nil) }
        return ("download", nil)
    }

    /// Map the format-layer `SourceFormat` to the UI-facing `FetchOutcome.Kind`.
    static func mapFormat(_ format: SourceFormat) -> FetchOutcome.Kind {
        switch format {
        case .html: return .html
        case .pdf: return .pdf
        case .text: return .text
        case .binary: return .binary
        }
    }

    /// The decision about what bytes to store under what filename — now a thin
    /// wrapper that delegates to the URL-independent `FormatMaterializer.dispatch`.
    /// The URL-specific `nameHint(for:)` extracts `(stem, extensionHint)` from
    /// `response.finalURL`; the format layer does the rest.
    public static func plan(for response: FetchResponse) -> StorePlan {
        let (stem, extHint) = nameHint(for: response.finalURL)
        let fp = FormatMaterializer.dispatch(
            data: response.data, contentType: response.contentType,
            stem: stem, extensionHint: extHint)
        return StorePlan(filename: fp.filename, data: fp.data, kind: mapFormat(fp.format))
    }

    // MARK: - Helpers (thin forwarders to FormatMaterializer)

    static func normalizedMIME(_ raw: String?) -> String? {
        FormatMaterializer.normalizedMIME(raw)
    }

    static func decodeText(_ data: Data) -> String {
        FormatMaterializer.decodeText(data)
    }

    static func binaryExtension(forMIME mime: String?, url: URL) -> String {
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        return FormatMaterializer.binaryExtension(forMIME: mime, extensionHint: ext.isEmpty ? nil : ext)
    }
}
