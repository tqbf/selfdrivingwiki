import Foundation

/// One version in the append-only, git-lite version chain for a file's
/// processed markdown. Each version is a FULL-TEXT snapshot (never a delta).
/// ULID-sorted: MAX(id) is always the HEAD. The original source bytes in
/// `ingested_files.content` are immutable — this chain holds the editable
/// processed markdown.
///
/// `parentID` is nil for v1 (the seeding/extraction baseline) and points to
/// the previous version for every subsequent edit/revert.
public struct FileMarkdownVersion: Identifiable, Hashable, Sendable {
    /// ULID — sorts chronologically, so MAX(id) for a given file is the head.
    public let id: PageID
    /// The ingested file this version belongs to.
    public let fileID: PageID
    /// Previous version's id; nil for v1 (the lineage root).
    public let parentID: PageID?
    /// Full markdown text of this version.
    public let content: String
    /// Who/what created this version: "extraction", "user", or "revert".
    public let origin: String
    /// Optional edit summary (unused by UI for now).
    public let note: String?
    /// When this version was created.
    public let createdAt: Date

    public init(
        id: PageID,
        fileID: PageID,
        parentID: PageID?,
        content: String,
        origin: String,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.fileID = fileID
        self.parentID = parentID
        self.content = content
        self.origin = origin
        self.note = note
        self.createdAt = createdAt
    }
}
