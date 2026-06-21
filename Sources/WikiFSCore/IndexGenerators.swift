import Foundation

/// Pure byte generators for the agent-facing generated index files
/// (INITIAL §5 / §8): `manifest.json`, `indexes/pages.jsonl`,
/// `indexes/links.jsonl`.
///
/// These live in `WikiFSCore` (not the extension) so they are unit-testable
/// without the File Provider runtime and the extension stays a thin shell. Each
/// function takes already-fetched rows (`[WikiPage]` / link tuples) and returns
/// `Data` — they never touch SQLite themselves.
///
/// **Determinism matters.** The File Provider reports `documentSize` for a file
/// before serving its bytes; if the size and the byte count disagree, `cat`
/// truncates. So these emit a controlled, fixed key order and avoid any
/// dictionary-iteration nondeterminism (no `JSONSerialization` of a `[String:
/// Any]`, whose key order is unspecified). For a fixed input the bytes are
/// byte-for-byte stable, which lets the extension cache size==content by token.
public enum IndexGenerators {

    /// A single wiki link row, as read back from `page_links` or `source_links`.
    public struct LinkRow: Equatable, Sendable {
        public let from: String
        public let to: String
        public let linkText: String
        /// `"page"` or `"source"` — so the unified `links.jsonl` spans both kinds.
        public let type: String

        public init(from: String, to: String, linkText: String, type: String = "page") {
            self.from = from
            self.to = to
            self.linkText = linkText
            self.type = type
        }
    }

    /// A single source row (no content), as read for `sources.jsonl` and for
    /// the projection's `sources/` enumeration. Carries the stable
    /// version/timestamps too so the File Provider can derive stable item
    /// versions during enumeration (only `id/name/path/size/mime/has_markdown`
    /// reach the JSONL — the rest are projection-only).
    public struct SourceIndexRow: Equatable, Sendable {
        public let id: String
        public let filename: String
        public let ext: String
        public let mime: String?
        public let byteSize: Int
        public let createdAt: Date
        public let updatedAt: Date
        public let version: Int
        public let displayName: String?
        public let hasMarkdown: Bool

        public init(
            id: String,
            filename: String,
            ext: String,
            mime: String?,
            byteSize: Int,
            createdAt: Date = Date(timeIntervalSince1970: 0),
            updatedAt: Date = Date(timeIntervalSince1970: 0),
            version: Int = 1,
            displayName: String? = nil,
            hasMarkdown: Bool = false
        ) {
            self.id = id
            self.filename = filename
            self.ext = ext
            self.mime = mime
            self.byteSize = byteSize
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.version = version
            self.displayName = displayName
            self.hasMarkdown = hasMarkdown
        }
    }

    // Relative paths advertised in the manifest. Shared with the README text.
    public static let pagesByIDPath = "pages/by-id"
    public static let pagesByTitlePath = "pages/by-title"
    public static let pageIndexPath = "indexes/pages.jsonl"
    public static let linkIndexPath = "indexes/links.jsonl"
    public static let sourcesByIDPath = "sources/by-id"
    public static let sourceIndexPath = "indexes/sources.jsonl"

    /// `manifest.json` — a machine-readable summary of the projection. `pages`
    /// is the page list (used for `page_count`); `sourceCount` is the source
    /// count; `generatedAt` is stamped into `generated_at` as ISO-8601 UTC.
    /// Hand-built with a fixed key order so the byte count is stable for a given
    /// (page_count, source_count, generatedAt).
    public static func manifest(pages: [WikiPage], sourceCount: Int, generatedAt: Date) -> Data {
        let iso = iso8601(generatedAt)
        let json = """
        {
          "name": "Self Driving Wiki",
          "version": 1,
          "generated_at": "\(iso)",
          "page_count": \(pages.count),
          "file_count": \(sourceCount),
          "paths": {
            "pages_by_id": "\(pagesByIDPath)",
            "pages_by_title": "\(pagesByTitlePath)",
            "page_index": "\(pageIndexPath)",
            "link_index": "\(linkIndexPath)",
            "sources_by_id": "\(sourcesByIDPath)",
            "source_index": "\(sourceIndexPath)"
          }
        }

        """
        return Data(json.utf8)
    }

    /// `indexes/pages.jsonl` — one JSON object per line, one line per page,
    /// ordered as given (the caller passes pages ordered by id). Trailing
    /// newline. Keys in fixed order: id, title, path, updated_at.
    public static func pagesJSONL(pages: [WikiPage]) -> Data {
        var out = ""
        for page in pages {
            let id = jsonString(page.id.rawValue)
            let title = jsonString(page.title)
            let path = jsonString("\(pagesByIDPath)/\(page.id.rawValue).md")
            let updatedAt = jsonNumber(page.updatedAt.timeIntervalSince1970)
            out += "{\"id\":\(id),\"title\":\(title),\"path\":\(path),\"updated_at\":\(updatedAt)}\n"
        }
        return Data(out.utf8)
    }

    /// `indexes/links.jsonl` — one JSON object per line, one line per link,
    /// ordered as given (page rows first, then source rows, each sorted by
    /// (from,to)). Keys in fixed order: from, to, link_text, type.
    public static func linksJSONL(links: [LinkRow]) -> Data {
        var out = ""
        for link in links {
            let from = jsonString(link.from)
            let to = jsonString(link.to)
            let text = jsonString(link.linkText)
            let type = jsonString(link.type)
            out += "{\"from\":\(from),\"to\":\(to),\"link_text\":\(text),\"type\":\(type)}\n"
        }
        return Data(out.utf8)
    }

    /// `indexes/sources.jsonl` — one JSON object per line, one line per source,
    /// ordered as given (the caller passes sources ordered by id == ingest
    /// order). Keys in fixed order: id, name, path, size, mime, has_markdown.
    /// `path` points at the canonical `sources/by-id/<id>.<ext>` location (no
    /// dot when extension-less); `mime` is JSON `null` when unknown;
    /// `has_markdown` is `true` when at least one processed-markdown version
    /// exists (from `source_markdown_versions`).
    public static func sourcesJSONL(sources: [SourceIndexRow]) -> Data {
        var out = ""
        for source in sources {
            let id = jsonString(source.id)
            let name = jsonString(source.filename)
            let relPath = source.ext.isEmpty
                ? "\(sourcesByIDPath)/\(source.id)"
                : "\(sourcesByIDPath)/\(source.id).\(source.ext)"
            let path = jsonString(relPath)
            let size = String(source.byteSize)
            let mime = source.mime.map { jsonString($0) } ?? "null"
            let hasMarkdown = source.hasMarkdown ? "true" : "false"
            out += "{\"id\":\(id),\"name\":\(name),\"path\":\(path),\"size\":\(size),\"mime\":\(mime),\"has_markdown\":\(hasMarkdown)}\n"
        }
        return Data(out.utf8)
    }

    // MARK: - JSON value helpers

    /// ISO-8601 in UTC with a trailing `Z` (e.g. `2026-06-15T00:00:00Z`),
    /// locale-independent so the bytes are stable on any machine.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Encode a Swift string as a JSON string literal (with surrounding quotes),
    /// escaping the characters JSON requires. Uses `JSONEncoder` on a single
    /// `String`, which is deterministic (no dictionary key ordering involved).
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let s = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return s
    }

    /// A `TimeInterval` rendered as a JSON number. `timeIntervalSince1970`
    /// fractional seconds are preserved; integer-valued intervals print without
    /// a decimal point. Stable for a given Double.
    private static func jsonNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
