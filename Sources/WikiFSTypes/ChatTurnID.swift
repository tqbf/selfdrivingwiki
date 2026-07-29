import Foundation

/// Stable identifier for one submitted chat turn.
public struct ChatTurnID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ChatTurnID: Identifiable {
    public var id: String { rawValue }
}
