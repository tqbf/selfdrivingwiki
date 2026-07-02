import Foundation

// MARK: - Tree item types

/// One node in the rendered Bookmarks tree. Folders have `children` (possibly
/// empty — always expandable); page/source refs are leaves (`children = nil`).
public struct BookmarkTreeItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let node: BookmarkNode
    /// Child items. `nil` = leaf (no disclosure triangle). `[]` = expandable
    /// but empty (shows an empty-state placeholder). Non-empty = rendered with
    /// disclosure triangles.
    public var children: [BookmarkTreeItem]?

    /// The `WikiSelection` for all tree items. ALL bookmark items use
    /// `.bookmark(nodeID)` — selecting a bookmark highlights it but does NOT
    /// open a tab. Double-click or context-menu "Open" navigates instead.
    /// This keeps bookmarks and tabs fully independent.
    public var selection: WikiSelection? {
        .bookmark(node.id)
    }

    /// The `WikiSelection` to open when the user double-clicks or uses "Open".
    /// Returns the target page/source for refs; nil for folders.
    public var openSelection: WikiSelection? {
        switch node.kind {
        case .pageRef: return node.targetID.map { WikiSelection.page($0) }
        case .sourceRef: return node.targetID.map { WikiSelection.source($0) }
        case .folder: return nil
        }
    }

    public init(id: String, node: BookmarkNode, children: [BookmarkTreeItem]?) {
        self.id = id
        self.node = node
        self.children = children
    }
}

// MARK: - Tree builder

/// Build the tree from flat `BookmarkNode`s.
///
/// Folder nodes always get `children` as an array (possibly empty), so they are
/// always expandable. Page/source refs are leaves (`children = nil`).
public func buildBookmarkTree(nodes: [BookmarkNode]) -> [BookmarkTreeItem] {
    // Group nodes by parentID (nil = root).
    var childrenByParent: [String?: [BookmarkNode]] = [:]
    for node in nodes {
        childrenByParent[node.parentID, default: []].append(node)
    }

    func buildChildren(of parentID: String?) -> [BookmarkTreeItem] {
        let siblings = (childrenByParent[parentID] ?? []).sorted { $0.position < $1.position }
        return siblings.map { buildItem(from: $0) }
    }

    func buildItem(from node: BookmarkNode) -> BookmarkTreeItem {
        switch node.kind {
        case .folder:
            // Always expandable — empty array when no children.
            let children = buildChildren(of: node.id)
            return BookmarkTreeItem(id: node.id, node: node, children: children)
        case .pageRef, .sourceRef:
            // Leaf — no disclosure triangle.
            return BookmarkTreeItem(id: node.id, node: node, children: nil)
        }
    }

    return buildChildren(of: nil)
}
