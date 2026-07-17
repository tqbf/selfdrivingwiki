import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Zotero Web API (`api.zotero.org`) to search a user's library and
/// list an item's child attachments — metadata only. Attachment BYTES are read
/// straight off disk via `ZoteroLocalStorage`, not downloaded through this client
/// (see that file for why `~/Zotero/storage/<key>/<filename>` is safe to read
/// directly). This keeps the picker's search-as-you-type loop to one cheap JSON
/// round trip per keystroke, with no file transfer in the hot path.
///
/// Design for testability, mirroring `URLFetchService`: the network is behind an
/// injected `RequestFetcher`, and every decode/request-building step is a pure
/// static function — the actual unit-test target.
public struct ZoteroClient: Sendable {

    /// Abstracts the network call. Unlike `URLFetchService.URLResourceFetcher`
    /// (which takes a bare `URL`), this takes a fully-formed `URLRequest` because
    /// every Zotero call needs `Zotero-API-Key` / `Zotero-API-Version` headers
    /// attached by THIS client, not by the fetcher — the fetcher stays
    /// auth-agnostic and trivially fakeable with canned `(Data, Int)` pairs.
    public protocol RequestFetcher: Sendable {
        func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int)
    }

    public struct Config: Sendable {
        public let libraryID: String
        public let apiKey: String

        public init(libraryID: String, apiKey: String) {
            self.libraryID = libraryID
            self.apiKey = apiKey
        }
    }

    /// Errors surfaced to the UI with user-readable messages.
    public enum ZoteroError: LocalizedError, Equatable {
        /// Reserved for the app-composition layer: thrown by callers that need a
        /// `ZoteroClient` but find no library ID / API key configured yet — the
        /// client itself is always constructed with a `Config`, so it never
        /// throws this on its own.
        case notConfigured
        case unauthorized
        case notFound
        case httpStatus(Int)
        case decoding(String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Zotero isn't configured yet. Add your API key in Settings."
            case .unauthorized: return "Zotero rejected that API key. Check it in Settings and try again."
            case .notFound: return "That Zotero item or library couldn't be found."
            case .httpStatus(let code): return "Zotero returned HTTP \(code)."
            case .decoding(let msg): return "Couldn't read Zotero's response: \(msg)"
            case .network(let msg): return msg
            }
        }
    }

    private let fetcher: any RequestFetcher
    private let config: Config
    private let baseURL: URL

    public init(config: Config, fetcher: any RequestFetcher, baseURL: URL = URL(string: "https://api.zotero.org")!) {
        self.config = config
        self.fetcher = fetcher
        self.baseURL = baseURL
    }

    // MARK: - Calls

    /// Quick-search the user's top-level library items (papers, books — not their
    /// attachments/notes), matching Zotero's own quick-search UX
    /// (`qmode=titleCreatorYear`) so results feel familiar. `itemType=-attachment`
    /// excludes attachments from this list — they're a drill-down via
    /// `childAttachments(ofItemKey:)` once an item is picked. An empty `query`
    /// returns the library's most recent items (also used by `verifyConnection`).
    public func searchItems(query: String, limit: Int = 100) async throws -> [ZoteroItem] {
        let request = Self.buildSearchRequest(baseURL: baseURL, config: config, query: query, limit: limit)
        let (data, status) = try await performFetch(request)
        try Self.checkStatus(status)
        return try Self.decodeItems(data)
    }

    /// An item's child attachments (PDFs, converted Markdown, etc.) — child notes
    /// are decoded but filtered out by `decodeAttachments`.
    public func childAttachments(ofItemKey itemKey: String) async throws -> [ZoteroAttachment] {
        let request = Self.buildChildrenRequest(baseURL: baseURL, config: config, itemKey: itemKey)
        let (data, status) = try await performFetch(request)
        try Self.checkStatus(status)
        return try Self.decodeAttachments(data)
    }

    /// Settings' "Test Connection": a cheap, side-effect-free call that succeeds
    /// only with a valid library ID + API key.
    public func verifyConnection() async throws {
        _ = try await searchItems(query: "", limit: 1)
    }

    private func performFetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        do {
            return try await fetcher.fetch(request)
        } catch let error as ZoteroError {
            throw error
        } catch {
            throw ZoteroError.network(error.localizedDescription)
        }
    }

    // MARK: - Pure (unit-test targets — no network)

    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 403: throw ZoteroError.unauthorized
        case 404: throw ZoteroError.notFound
        default: throw ZoteroError.httpStatus(status)
        }
    }

    static func buildSearchRequest(baseURL: URL, config: Config, query: String, limit: Int) -> URLRequest {
        var queryItems = [
            URLQueryItem(name: "itemType", value: "-attachment"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmed))
            queryItems.append(URLQueryItem(name: "qmode", value: "titleCreatorYear"))
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/\(config.libraryID)/items"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return authorizedRequest(url: components.url!, config: config)
    }

    static func buildChildrenRequest(baseURL: URL, config: Config, itemKey: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("users/\(config.libraryID)/items/\(itemKey)/children")
        return authorizedRequest(url: url, config: config)
    }

    private static func authorizedRequest(url: URL, config: Config) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.apiKey, forHTTPHeaderField: "Zotero-API-Key")
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        return request
    }

    static func decodeItems(_ data: Data) throws -> [ZoteroItem] {
        let envelopes: [Envelope]
        do {
            envelopes = try JSONDecoder().decode([Envelope].self, from: data)
        } catch {
            throw ZoteroError.decoding(error.localizedDescription)
        }
        return envelopes.map { envelope in
            ZoteroItem(
                key: envelope.key,
                version: envelope.version,
                itemType: envelope.data.itemType,
                title: envelope.data.title,
                creatorSummary: creatorSummary(envelope.data.creators),
                date: envelope.data.date
            )
        }
    }

    /// Decodes only entries whose `data.itemType == "attachment"` — a `children`
    /// response also includes child notes, which carry no `linkMode`/`filename`
    /// and aren't ingestable.
    static func decodeAttachments(_ data: Data) throws -> [ZoteroAttachment] {
        let envelopes: [Envelope]
        do {
            envelopes = try JSONDecoder().decode([Envelope].self, from: data)
        } catch {
            throw ZoteroError.decoding(error.localizedDescription)
        }
        return envelopes
            .filter { $0.data.itemType == "attachment" }
            .map { envelope in
                ZoteroAttachment(
                    key: envelope.key,
                    parentItem: envelope.data.parentItem,
                    linkMode: envelope.data.linkMode ?? "",
                    filename: envelope.data.filename,
                    contentType: envelope.data.contentType,
                    title: envelope.data.title
                )
            }
    }

    /// "Last, F.; Last2, F2." for display — falls back to a single-field `name`
    /// (orgs/institutions) when first/last aren't both present. `nil` if there are
    /// no creators at all.
    private static func creatorSummary(_ creators: [Envelope.Creator]?) -> String? {
        guard let creators, !creators.isEmpty else { return nil }
        let names = creators.compactMap { creator -> String? in
            if let last = creator.lastName, !last.isEmpty {
                if let first = creator.firstName, !first.isEmpty {
                    return "\(last), \(String(first.prefix(1)))."
                }
                return last
            }
            return creator.name
        }
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }

    /// The Zotero API's `{key, version, data: {...}}` envelope — only the fields
    /// this client actually uses are declared; everything else is ignored by
    /// `JSONDecoder` automatically.
    private struct Envelope: Decodable {
        let key: String
        let version: Int
        let data: ItemData

        struct ItemData: Decodable {
            let itemType: String
            let title: String?
            let date: String?
            let creators: [Creator]?
            let parentItem: String?
            let linkMode: String?
            let filename: String?
            let contentType: String?
        }

        struct Creator: Decodable {
            let firstName: String?
            let lastName: String?
            let name: String?
        }
    }
}

/// A top-level Zotero library item (paper, book, etc. — not an attachment).
public struct ZoteroItem: Identifiable, Hashable, Sendable {
    public let key: String
    public let version: Int
    public let itemType: String
    public let title: String?
    public let creatorSummary: String?
    public let date: String?
    public var id: String { key }

    /// "Ito, K. · 2016" for display in search results — nil when both fields are
    /// absent or empty. Extracted as a pure value-type property so the picker UI
    /// stays thin and the formatting is trivially unit-testable.
    public var subtitle: String? {
        let parts = [creatorSummary, date].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A Zotero attachment (PDF, converted Markdown, web snapshot, …) attached to a
/// parent item.
public struct ZoteroAttachment: Identifiable, Hashable, Sendable {
    public let key: String
    public let parentItem: String?
    /// `"imported_file"` | `"imported_url"` | `"linked_file"` | `"linked_url"`.
    public let linkMode: String
    public let filename: String?
    public let contentType: String?
    public let title: String?
    public var id: String { key }

    /// Only these two modes have a reliable local copy under
    /// `~/Zotero/storage/<key>/<filename>` — confirmed against Zotero's own sync
    /// client source (see `ZoteroLocalStorage`). `linked_file`/`linked_url` point
    /// elsewhere or nowhere on disk.
    public var hasLocalCopy: Bool { linkMode == "imported_file" || linkMode == "imported_url" }

    /// Whether this attachment can be ingested by Self Driving Wiki. Prefers the
    /// Zotero API `contentType` (e.g. `application/pdf`) when present; falls back
    /// to the filename extension. Extracted as a pure value-type property so the
    /// picker UI stays thin and the decision is trivially unit-testable.
    public var isIngestable: Bool {
        // Prefer the API-declared content type when available.
        if let ct = contentType?.lowercased() {
            if MimeType.isPDF(ct) { return true }
            if MimeType.isText(ct) { return true }  // text/markdown, text/plain, etc.
        }
        // Filename-based heuristic as fallback.
        guard let filename = filename?.lowercased() else { return false }
        return filename.hasSuffix(".pdf") || filename.hasSuffix(".md")
    }
}

/// The production `ZoteroClient.RequestFetcher` — a thin `URLSession` wrapper,
/// mirroring `URLSessionFetcher`. The app is un-sandboxed, so no entitlement is
/// needed for outbound network access.
public struct URLSessionZoteroFetcher: ZoteroClient.RequestFetcher {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return (data, 200)
        }
        return (data, http.statusCode)
    }
}
