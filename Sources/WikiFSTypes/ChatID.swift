import Foundation

/// Stable identifier for a persisted chat entity.
///
/// The raw value and Codable representation match the legacy chat-valued
/// `PageID` representation so persisted and external formats stay unchanged.
public struct ChatID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ChatID: Identifiable {
    public var id: String { rawValue }
}
