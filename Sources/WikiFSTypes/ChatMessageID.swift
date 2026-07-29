import Foundation

/// Stable identifier for one transcript message item.
public struct ChatMessageID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ChatMessageID: Identifiable {
    public var id: String { rawValue }
}
