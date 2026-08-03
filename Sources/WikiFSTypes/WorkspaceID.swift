import Foundation

/// Stable identifier for a workspace. The raw value is a ULID string.
///
/// A workspace is a speculative branch within a wiki. Its identifier belongs to
/// a separate namespace from page, source, chat, and wiki identifiers.
public struct WorkspaceID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension WorkspaceID: Identifiable {
    public var id: String { rawValue }
}
