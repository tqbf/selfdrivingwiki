import Foundation
import WikiFSCore

/// Display sort for the Bookmarks outline (issue #241). View-level only —
/// the persisted `position` column (manual drag-and-drop order) is never
/// rewritten by sorting; `.manual` is the default and renders it directly.
enum BookmarkSortOrder: String, CaseIterable, Sendable {
    /// Manual drag-and-drop order: `position` ascending (the persisted default).
    case manual
    /// Resolved display title, localized case-insensitive, A–Z.
    case nameAZ
    /// `createdAt` descending (newest first).
    case dateAdded
    /// `updatedAt` descending (newest first).
    case dateUpdated
}

/// Kind filter for the Bookmarks outline (issue #241), mirroring the
/// `SourceFilter` picker in `SourcesContainerView`.
enum BookmarkKindFilter: String, CaseIterable, Sendable {
    case all
    case folders
    case pages
    case sources
    case chats

    func matches(_ kind: BookmarkNodeKind) -> Bool {
        switch self {
        case .all: true
        case .folders: kind == .folder
        case .pages: kind == .pageRef
        case .sources: kind == .sourceRef
        case .chats: kind == .chatRef
        }
    }
}

extension BookmarkSortOrder {
    /// Sorts one sibling group (nodes sharing a parent). Pure: no store
    /// parameter, no writes — the caller supplies a title resolver. Every
    /// non-manual order breaks ties on `position` ascending so equal keys
    /// still yield a deterministic order. `.manual` is `position` ascending,
    /// exactly today's persisted-order rendering.
    nonisolated func sortedSiblings(
        _ siblings: [BookmarkNode],
        resolveTitle: (BookmarkNode) -> String
    ) -> [BookmarkNode] {
        switch self {
        case .manual:
            return siblings.sorted { $0.position < $1.position }
        case .nameAZ:
            return siblings.sorted { a, b in
                let order = resolveTitle(a).localizedCaseInsensitiveCompare(resolveTitle(b))
                if order == .orderedSame { return a.position < b.position }
                return order == .orderedAscending
            }
        case .dateAdded:
            return siblings.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.position < b.position
            }
        case .dateUpdated:
            return siblings.sorted { a, b in
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.position < b.position
            }
        }
    }
}
