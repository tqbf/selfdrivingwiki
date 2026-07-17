import Foundation

/// The origin of a `SourceMarkdownVersion` — what created it. Persisted as the
/// `source_markdown_versions.origin` column. Typed (not a raw string) so a typo
/// like `"User"` is a compile error rather than a silent mis-guard (issue #501).
public enum SourceMarkdownOrigin: String, Sendable, CaseIterable {
    /// Backend extraction (pdf2md, anthropic, gemini, docling, …).
    case extraction
    /// Manual user edit.
    case user
    /// Revert to an older version (appends a new row reusing the target's blob).
    case revert
    /// Native markdown file seeded from its raw bytes (lazy seeding).
    case source
    /// Media (audio/video) transcription.
    case transcript
}

/// One version in the append-only, git-lite version chain for a source's
/// processed markdown. Each version is a FULL-TEXT snapshot (never a delta).
/// ULID-sorted: MAX(id) is always the HEAD. The original source bytes in
/// `sources.content` are immutable — this chain holds the editable
/// processed markdown.
///
/// `parentID` is nil for v1 (the seeding/extraction baseline) and points to
/// the previous version for every subsequent edit/revert.
public struct SourceMarkdownVersion: Identifiable, Hashable, Sendable {
    /// ULID — sorts chronologically, so MAX(id) for a given source is the head
    /// (absent a `source-derived` ref; see the default-active rule).
    public let id: PageID
    /// The source this version belongs to.
    public let sourceID: PageID
    /// Previous version's id; nil for v1 (the lineage root).
    public let parentID: PageID?
    /// Full markdown text of this version — ALWAYS the fully-resolved body. For
    /// CAS'd rows (v21+) this is the blob-decoded text; callers must never read
    /// `blobHash` to obtain body text. The empty string only appears transiently
    /// in the DB column, never on this property.
    public let content: String
    /// Who/what created this version (extraction / user / revert / source / transcript).
    public let origin: SourceMarkdownOrigin
    /// Optional edit summary (unused by UI for now).
    public let note: String?
    /// When this version was created.
    public let createdAt: Date
    /// The PROV activity that produced this extraction (§4.7). nil for rows
    /// without provenance (pre-v21 legacy rows that failed to backfill).
    public let activityID: String?
    /// The `source_versions.id` this extraction was derived from. nil when the
    /// extraction predates the content chain or the source has no versions.
    public let sourceVersionID: String?
    /// Content-addressed hash of the markdown body (CAS, §4.5). Rows sharing a
    /// blob hash store the bytes exactly once.
    public let blobHash: String?
    /// MIME type of the body (`text/markdown`).
    public let mimeType: String
    /// Which extraction backend/technique produced this version (e.g.
    /// "pdf2md", "anthropic", "gemini", "docling"). `nil` for pre-#131 rows
    /// and for user edits/reverts (#131).
    public let technique: String?

    public init(
        id: PageID,
        sourceID: PageID,
        parentID: PageID?,
        content: String,
        origin: SourceMarkdownOrigin,
        note: String?,
        createdAt: Date,
        activityID: String? = nil,
        sourceVersionID: String? = nil,
        blobHash: String? = nil,
        mimeType: String = MimeType.markdown,
        technique: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.parentID = parentID
        self.content = content
        self.origin = origin
        self.note = note
        self.createdAt = createdAt
        self.activityID = activityID
        self.sourceVersionID = sourceVersionID
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.technique = technique
    }
}
