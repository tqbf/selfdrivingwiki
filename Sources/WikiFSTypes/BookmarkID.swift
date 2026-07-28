import Foundation

/// Stable identifier for a `BookmarkNode` in the bookmarks tree. The raw value
/// is a ULID string.
///
/// A bookmark node's identifier belongs to a separate namespace from page,
/// source, chat, workspace, and wiki identifiers.
public struct BookmarkID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension BookmarkID: Identifiable {
    public var id: String { rawValue }
}
