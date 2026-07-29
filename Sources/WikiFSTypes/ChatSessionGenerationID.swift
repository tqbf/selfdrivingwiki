import Foundation

/// Stable identifier for one daemon-owned chat session generation.
public struct ChatSessionGenerationID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ChatSessionGenerationID: Identifiable {
    public var id: String { rawValue }
}
