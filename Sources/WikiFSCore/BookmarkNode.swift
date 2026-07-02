import Foundation

/// The kind of a `BookmarkNode` — determines how it renders in the Bookmarks tree and
/// what data it carries.
public enum BookmarkNodeKind: String, Sendable, Codable {
    /// A user-named container that holds child nodes.
    case folder
    /// A reference to a wiki page (leaf).
    case pageRef = "page_ref"
    /// A reference to a source (leaf).
    case sourceRef = "source_ref"
}

/// One row in the `bookmark_nodes` table — the persistent organizational tree for
/// the Bookmarks sidebar section. Folders hold children; refs point at a page or
/// source.
public struct BookmarkNode: Identifiable, Hashable, Sendable {
    public let id: String
    public var parentID: String?
    public var position: Int
    public var kind: BookmarkNodeKind
    /// Folder name; `nil` for refs.
    public var label: String?
    /// Page/source id for refs; `nil` otherwise.
    public var targetID: PageID?

    public init(
        id: String,
        parentID: String?,
        position: Int,
        kind: BookmarkNodeKind,
        label: String?,
        targetID: PageID?
    ) {
        self.id = id
        self.parentID = parentID
        self.position = position
        self.kind = kind
        self.label = label
        self.targetID = targetID
    }
}
