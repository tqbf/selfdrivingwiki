import Foundation

/// A full wiki page, mirroring the `pages` row in SQLite (INITIAL.md §3).
public struct WikiPage: Identifiable, Hashable, Sendable {
    public let id: PageID
    public var title: String
    public var slug: String
    public var bodyMarkdown: String
    public let createdAt: Date
    public var updatedAt: Date
    public var version: Int
    /// Which agent/model created this page (e.g. "claude-sonnet-4-5-20250929",
    /// "user"). `nil` for pages created before provenance tracking (#131).
    public var createdBy: String?
    /// Which agent/model last edited this page. `nil` if unknown or unchanged
    /// since creation (#131).
    public var lastEditedBy: String?

    public init(
        id: PageID,
        title: String,
        slug: String,
        bodyMarkdown: String,
        createdAt: Date,
        updatedAt: Date,
        version: Int,
        createdBy: String? = nil,
        lastEditedBy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.createdBy = createdBy
        self.lastEditedBy = lastEditedBy
    }
}
