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
    /// A reference to a chat conversation (leaf).
    case chatRef = "chat_ref"
}

/// One row in the `bookmark_nodes` table — the persistent organizational tree for
/// the Bookmarks sidebar section. Folders hold children; refs point at a page,
/// source, or chat.
public struct BookmarkNode: Identifiable, Hashable, Sendable {
    /// The authoritative content of a bookmark node.
    ///
    /// This tagged representation prevents a reference kind from being paired
    /// with an identifier from another namespace. `kind`, `label`, and
    /// `targetRawValue` below are persistence projections for the existing
    /// `bookmark_nodes` columns.
    public enum Content: Hashable, Sendable {
        case folder(label: String)
        case page(PageID)
        case source(SourceID)
        case chat(ChatID)

        public var kind: BookmarkNodeKind {
            switch self {
            case .folder: .folder
            case .page: .pageRef
            case .source: .sourceRef
            case .chat: .chatRef
            }
        }

        public var label: String? {
            guard case .folder(let label) = self else { return nil }
            return label
        }

        public var targetRawValue: String? {
            switch self {
            case .folder: nil
            case .page(let id): id.rawValue
            case .source(let id): id.rawValue
            case .chat(let id): id.rawValue
            }
        }
    }

    public let id: String
    public var parentID: String?
    public var position: Int
    public var content: Content
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
        content: Content,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.parentID = parentID
        self.position = position
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The existing `bookmark_nodes.kind` persistence projection.
    public var kind: BookmarkNodeKind { content.kind }

    /// The existing `bookmark_nodes.label` persistence projection.
    public var label: String? { content.label }

    /// The existing `bookmark_nodes.target_id` persistence projection.
    public var targetRawValue: String? { content.targetRawValue }

    /// Reconstruct the tagged content from one complete persisted row tuple.
    /// This is internal because callers must create typed `Content` directly.
    internal static func content(
        bookmarkID: String,
        kindRawValue: String,
        label: String?,
        targetRawValue: String?
    ) throws -> Content {
        guard let kind = BookmarkNodeKind(rawValue: kindRawValue) else {
            throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "unknown kind '\(kindRawValue)'")
        }
        switch kind {
        case .folder:
            guard targetRawValue == nil else {
                throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "folder has target_id")
            }
            guard let label, !label.isEmpty else {
                throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "folder requires a non-empty label")
            }
            return .folder(label: label)
        case .pageRef:
            guard label == nil else {
                throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "page reference has label")
            }
            let targetRawValue = try requiredTargetRawValue(
                bookmarkID: bookmarkID,
                targetRawValue: targetRawValue,
                referenceName: "page reference"
            )
            return .page(PageID(rawValue: targetRawValue))
        case .sourceRef:
            guard label == nil else {
                throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "source reference has label")
            }
            let targetRawValue = try requiredTargetRawValue(
                bookmarkID: bookmarkID,
                targetRawValue: targetRawValue,
                referenceName: "source reference"
            )
            return .source(SourceID(rawValue: targetRawValue))
        case .chatRef:
            guard label == nil else {
                throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "chat reference has label")
            }
            let targetRawValue = try requiredTargetRawValue(
                bookmarkID: bookmarkID,
                targetRawValue: targetRawValue,
                referenceName: "chat reference"
            )
            return .chat(ChatID(rawValue: targetRawValue))
        }
    }

    private static func requiredTargetRawValue(
        bookmarkID: String,
        targetRawValue: String?,
        referenceName: String
    ) throws -> String {
        guard let targetRawValue else {
            throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "\(referenceName) requires target_id")
        }
        guard targetRawValue.isEmpty == false else {
            throw WikiStoreError.invalidBookmarkRow(id: bookmarkID, reason: "\(referenceName) requires a non-empty target_id")
        }
        return targetRawValue
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
