import Foundation

/// Metadata for one source — the verbatim bytes ingested into the app and
/// stored in the `sources` table (NOT a wiki page). The raw `content`
/// BLOB is deliberately NOT part of this summary: it is fetched on demand via
/// `SQLiteWikiStore.sourceContent(id:)` so the list and the projection's
/// `getattr`/enumeration never hold large blobs in memory.
///
/// `id` reuses `PageID` (a ULID-string wrapper) since the source id is also a
/// ULID — sortable, so the raw value orders by ingest time. Identifiable +
/// Hashable so it drives a SwiftUI `List`/`ForEach` directly.
public struct SourceSummary: Identifiable, Hashable, Sendable {
    public let id: PageID
    public let filename: String
    /// Lowercased extension with no leading dot (`""` when the name has none).
    public let ext: String
    /// Best-effort UTI→MIME; nil when the extension maps to no known type.
    public let mimeType: String?
    public let byteSize: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int

    /// The Zotero library item this source was ingested from — set ONLY via the
    /// Zotero ingest seam (`ingestFromZotero`). `nil` for drag-drop, URL, and
    /// Markdown-folder imports (no Zotero provenance). `key` is the item key
    /// needed to build a "View in Zotero" link; `title` is the item's display
    /// title captured at ingest time (the item could be renamed/deleted later).
    public let zoteroItemKey: String?
    public let zoteroItemTitle: String?

    /// User-editable display name for this source. Defaults to the original
    /// filename at ingest time. Used for `[[source:display-name]]` link
    /// resolution and sidebar/file-provider presentation.
    public let displayName: String?

    /// Best human-readable name: `displayName` when set and non-empty, otherwise `filename`.
    /// Use this everywhere a label is needed instead of branching on `displayName` at the call site.
    public var effectiveName: String {
        if let name = displayName, !name.isEmpty { return name }
        return filename
    }

    public init(
        id: PageID,
        filename: String,
        ext: String,
        mimeType: String?,
        byteSize: Int,
        createdAt: Date,
        updatedAt: Date,
        version: Int,
        zoteroItemKey: String? = nil,
        zoteroItemTitle: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.ext = ext
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.zoteroItemKey = zoteroItemKey
        self.zoteroItemTitle = zoteroItemTitle
        self.displayName = displayName
    }
}
