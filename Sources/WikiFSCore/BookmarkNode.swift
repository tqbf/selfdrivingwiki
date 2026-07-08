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
    /// When the node was first created (issue #242). Epoch default lets
    /// in-memory fixtures omit it; the store always stamps a real value.
    public var createdAt: Date
    /// When the node last changed in a way the user would consider an "update"
    /// (label rename or a move to a new parent). Pure same-parent reordering
    /// does NOT bump this — see `moveBookmarkNode`.
    public var updatedAt: Date

    public init(
        id: String,
        parentID: String?,
        position: Int,
        kind: BookmarkNodeKind,
        label: String?,
        targetID: PageID?,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.parentID = parentID
        self.position = position
        self.kind = kind
        self.label = label
        self.targetID = targetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Builds a slash-delimited display path for a folder by walking its
    /// `parentID` chain — e.g. `"Research / Papers"`. Used by the
    /// bookmark-target picker to disambiguate folders that share a label.
    /// Root folders (or unknown ids) return just their own label. The walk is
    /// capped so a corrupted parent cycle can't loop forever.
    ///
    /// - Parameters:
    ///   - id: The folder id to resolve.
    ///   - nodes: The full bookmark-node set to resolve parents against
    ///     (typically `store.bookmarkNodes`).
    /// - Returns: The joined path, or an empty string if the id isn't found or
    ///   has no label.
    public static func displayPath(id: String, in nodes: [BookmarkNode]) -> String {
        var byID: [String: BookmarkNode] = [:]
        byID.reserveCapacity(nodes.count)
        for node in nodes { byID[node.id] = node }

        var segments: [String] = []
        var current = byID[id]
        var depth = 0
        let maxDepth = 64
        while let node = current, depth < maxDepth {
            depth += 1
            if let label = node.label, !label.isEmpty {
                segments.insert(label, at: 0)
            }
            current = node.parentID.flatMap { byID[$0] }
        }
        return segments.joined(separator: " / ")
    }
}
