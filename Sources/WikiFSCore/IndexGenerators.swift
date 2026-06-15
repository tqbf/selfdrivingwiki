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

    /// A single wiki link row, as read back from `page_links`.
    public struct LinkRow: Equatable, Sendable {
        public let from: String
        public let to: String
        public let linkText: String

        public init(from: String, to: String, linkText: String) {
            self.from = from
            self.to = to
            self.linkText = linkText
        }
    }

    // Relative paths advertised in the manifest. Shared with the README text.
    public static let pagesByIDPath = "pages/by-id"
    public static let pagesByTitlePath = "pages/by-title"
    public static let pageIndexPath = "indexes/pages.jsonl"
    public static let linkIndexPath = "indexes/links.jsonl"

    /// `manifest.json` — a machine-readable summary of the projection. `pages`
    /// is the page list (used for `page_count`); `generatedAt` is stamped into
    /// `generated_at` as ISO-8601 UTC. Hand-built with a fixed key order so the
    /// byte count is stable for a given (page_count, generatedAt).
    public static func manifest(pages: [WikiPage], generatedAt: Date) -> Data {
        let iso = iso8601(generatedAt)
        let json = """
        {
          "name": "WikiFS",
          "version": 1,
          "generated_at": "\(iso)",
          "page_count": \(pages.count),
          "paths": {
            "pages_by_id": "\(pagesByIDPath)",
            "pages_by_title": "\(pagesByTitlePath)",
            "page_index": "\(pageIndexPath)",
            "link_index": "\(linkIndexPath)"
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
    /// ordered as given (the caller passes links ordered by (from,to)). Keys in
    /// fixed order: from, to, link_text.
    public static func linksJSONL(links: [LinkRow]) -> Data {
        var out = ""
        for link in links {
            let from = jsonString(link.from)
            let to = jsonString(link.to)
            let text = jsonString(link.linkText)
            out += "{\"from\":\(from),\"to\":\(to),\"link_text\":\(text)}\n"
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
