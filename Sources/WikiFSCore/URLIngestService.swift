import Foundation

/// Fetches a URL and lands its content as an ingested file in the active wiki —
/// exactly like a drag-dropped file, so the existing "Ingest into wiki" `claude -p`
/// operation can summarize it afterward.
///
/// Design for testability: the network is behind an injected `URLResourceFetcher`,
/// and the store write is an injected closure (`store:`). So the whole
/// dispatch / filename / store pipeline is unit-tested with a FAKE fetcher and an
/// in-memory store — no real network, deterministic. The app wires the real
/// `URLSessionFetcher` + the active `WikiStoreModel.ingestFile`.
///
/// Dispatch by `Content-Type`:
/// - `text/html` / `application/xhtml+xml` → `HTMLToMarkdown` → store the **markdown**
///   as a `.md` file (named from the `<title>` when present).
/// - `application/pdf` → store the raw PDF bytes as `.pdf` (verbatim).
/// - other `text/*` (plain, markdown, csv…) → store the raw text as-is.
/// - anything else (images, binaries) → store raw bytes with an extension inferred
///   from the MIME type or the URL.
public struct URLIngestService {

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
    public struct IngestOutcome: Sendable, Equatable {
        public let filename: String
        public let byteSize: Int
        /// The detected kind, for a human-readable confirmation.
        public let kind: Kind

        public enum Kind: Sendable, Equatable {
            case htmlConverted   // HTML → Markdown
            case pdf             // verbatim PDF
            case text            // verbatim text
            case binary          // verbatim other bytes
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
    public enum IngestError: LocalizedError, Equatable {
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
    /// passes `WikiStoreModel.ingestFile`; tests pass an in-memory collector.
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
    /// active wiki. Returns what was stored. Throws `IngestError` on a bad URL,
    /// non-2xx status (the fetcher reports it), empty body, or a store failure.
    @discardableResult
    public func ingest(rawInput: String) async throws -> IngestOutcome {
        guard let url = Self.normalizeURL(rawInput) else {
            throw IngestError.invalidURL(rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        return try store(response: response)
    }

    /// The PURE dispatch + filename + store step (no network), so tests can drive it
    /// directly with a hand-built `FetchResponse`.
    @discardableResult
    public func store(response: FetchResponse) throws -> IngestOutcome {
        guard !response.data.isEmpty else { throw IngestError.empty }
        let plan = Self.plan(for: response)
        do {
            try store(plan.filename, plan.data)
        } catch {
            throw IngestError.network("Couldn't save the fetched file: \(error.localizedDescription)")
        }
        return IngestOutcome(filename: plan.filename, byteSize: plan.data.count, kind: plan.kind)
    }

    // MARK: - Dispatch plan (pure)

    /// The decision about what bytes to store under what filename — pure, so it is
    /// the unit-test target AND the seam a `@MainActor` caller can use to store
    /// directly (avoiding the `@Sendable` store closure across an actor boundary).
    public struct StorePlan: Equatable, Sendable {
        public let filename: String
        public let data: Data
        public let kind: IngestOutcome.Kind
    }

    public static func plan(for response: FetchResponse) -> StorePlan {
        let mime = normalizedMIME(response.contentType)

        // Content-sniff the bytes when the declared type is one a misconfigured /
        // interstitial-serving host commonly lies about: `text/html`, missing, or a
        // generic `application/octet-stream`. If the bytes carry a known binary magic
        // number (e.g. a Dropbox interstitial that slipped past the normalizer but
        // actually returned a `%PDF`), store them verbatim as the SNIFFED type instead
        // of running HTML→Markdown on binary garbage. We trust an explicit, specific
        // declared type (`application/pdf`, `image/png`, …) and only sniff the
        // ambiguous ones, so a server that knows what it's serving wins.
        if shouldSniff(mime), let sniffed = sniffContentType(response.data) {
            let ext = binaryExtension(forMIME: sniffed, url: response.finalURL)
            let stem = stemFromURL(response.finalURL, droppingExtension: ext)
            let filename = ext.isEmpty ? sanitizeStem(stem) : ensureExtension(sanitizeStem(stem), ext: ext)
            let kind: IngestOutcome.Kind = sniffed == "application/pdf" ? .pdf : .binary
            return StorePlan(filename: filename, data: response.data, kind: kind)
        }

        if mime == "text/html" || mime == "application/xhtml+xml" {
            let html = decodeText(response.data)
            let result = HTMLToMarkdown.convert(html)
            let stem = result.title.flatMap { nonEmpty($0) } ?? stemFromURL(response.finalURL)
            let filename = ensureExtension(sanitizeStem(stem), ext: "md")
            return StorePlan(filename: filename, data: Data(result.markdown.utf8), kind: .htmlConverted)
        }

        if mime == "application/pdf" {
            let stem = stemFromURL(response.finalURL, droppingExtension: "pdf")
            let filename = ensureExtension(sanitizeStem(stem), ext: "pdf")
            return StorePlan(filename: filename, data: response.data, kind: .pdf)
        }

        if let mime, mime.hasPrefix("text/") {
            let ext = textExtension(forMIME: mime, url: response.finalURL)
            let stem = stemFromURL(response.finalURL, droppingExtension: ext)
            let filename = ensureExtension(sanitizeStem(stem), ext: ext)
            return StorePlan(filename: filename, data: response.data, kind: .text)
        }

        // Anything else: keep bytes verbatim with a best-effort extension.
        let ext = binaryExtension(forMIME: mime, url: response.finalURL)
        let stem = stemFromURL(response.finalURL, droppingExtension: ext)
        let filename = ext.isEmpty ? sanitizeStem(stem) : ensureExtension(sanitizeStem(stem), ext: ext)
        return StorePlan(filename: filename, data: response.data, kind: .binary)
    }

    // MARK: - Content sniffing (pure)

    /// Whether a declared MIME is ambiguous enough to second-guess via the bytes:
    /// `text/html` (the interstitial case), a missing type, or the catch-all
    /// `application/octet-stream`. A specific declared type is trusted as-is.
    static func shouldSniff(_ mime: String?) -> Bool {
        switch mime {
        case nil, "text/html", "application/xhtml+xml", "application/octet-stream":
            return true
        default:
            return false
        }
    }

    /// Detect a known binary content type from leading magic-number bytes, else
    /// `nil` (so the caller falls back to the declared type). Cheap prefix checks;
    /// extend the table as needed.
    static func sniffContentType(_ data: Data) -> String? {
        // Examine a small prefix; `prefix` is a view, so this copies at most 8 bytes.
        let head = Array(data.prefix(8))
        func starts(with magic: [UInt8]) -> Bool {
            guard head.count >= magic.count else { return false }
            return Array(head.prefix(magic.count)) == magic
        }

        if starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }  // \x89PNG
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }  // PK\x03\x04
        return nil
    }

    // MARK: - Helpers (pure)

    /// Lowercased MIME with any `; charset=…` parameter and whitespace stripped.
    static func normalizedMIME(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decode response bytes as text — UTF-8 first, then Latin-1 (which never fails)
    /// so a mis-declared charset still produces *something* the HTML walker can chew.
    static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)  // lossy, never nil
    }

    /// The filename stem from a URL: the last path component without its extension,
    /// else the host. `droppingExtension` removes a trailing `.<ext>` if the path
    /// component already carries it (so we don't double it).
    static func stemFromURL(_ url: URL, droppingExtension ext: String = "") -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            let ns = last as NSString
            let stem = ns.deletingPathExtension
            if !stem.isEmpty { return stem }
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        return "download"
    }

    /// Sanitize a stem into a safe filename component. Reuses `FilenameEscaping`'s
    /// title rules (collapse whitespace, strip control chars, replace `/`/`:`,
    /// leading-dot guard, trim trailing dots/spaces, empty→untitled), then caps the
    /// length so a giant `<title>` can't make an unwieldy filename.
    static func sanitizeStem(_ stem: String) -> String {
        let escaped = FilenameEscaping.escapeTitle(stem)
        let capped = String(escaped.prefix(80)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "untitled" : capped
    }

    /// Append `.ext` unless the stem already ends in it (case-insensitive).
    static func ensureExtension(_ stem: String, ext: String) -> String {
        let lower = stem.lowercased()
        if lower.hasSuffix(".\(ext)") { return stem }
        return "\(stem).\(ext)"
    }

    /// Extension for a `text/*` response: map the common ones, else fall back to the
    /// URL's extension, else `txt`.
    static func textExtension(forMIME mime: String, url: URL) -> String {
        switch mime {
        case "text/markdown", "text/x-markdown": return "md"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "text/css": return "css"
        case "text/javascript": return "js"
        default:
            let urlExt = (url.lastPathComponent as NSString).pathExtension.lowercased()
            return urlExt.isEmpty ? "txt" : urlExt
        }
    }

    /// Extension for a non-text response: from the MIME subtype when recognizable,
    /// else the URL's extension, else empty (no extension).
    static func binaryExtension(forMIME mime: String?, url: URL) -> String {
        if let mime {
            switch mime {
            case "image/jpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            case "application/json": return "json"
            case "application/zip": return "zip"
            case "application/epub+zip": return "epub"
            default:
                // Use the subtype if it looks like a clean extension token.
                if let sub = mime.split(separator: "/").last,
                   sub.allSatisfy({ $0.isLetter || $0.isNumber }), !sub.isEmpty {
                    return String(sub)
                }
            }
        }
        return (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
