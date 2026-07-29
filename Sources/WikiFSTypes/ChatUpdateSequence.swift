import Foundation

/// Monotonic per-generation sequence number for chat session updates.
public struct ChatUpdateSequence: Hashable, Codable, RawRepresentable, Sendable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ChatUpdateSequence, rhs: ChatUpdateSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func next() -> ChatUpdateSequence {
        ChatUpdateSequence(rawValue: rawValue + 1)
    }
}
