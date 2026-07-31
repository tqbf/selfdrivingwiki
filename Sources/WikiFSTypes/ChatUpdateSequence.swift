import Foundation

/// Monotonic per-generation sequence number for chat session updates.
public struct ChatUpdateSequence: Hashable, Codable, RawRepresentable, Sendable, Comparable {
    public enum Error: Swift.Error, Equatable {
        case overflow(ChatUpdateSequence)
    }

    public let rawValue: Int64

    public static let initial = ChatUpdateSequence(rawValue: 0)

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ChatUpdateSequence, rhs: ChatUpdateSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func next() throws -> ChatUpdateSequence {
        guard rawValue < Int64.max else {
            throw Error.overflow(self)
        }
        return ChatUpdateSequence(rawValue: rawValue + 1)
    }
}
