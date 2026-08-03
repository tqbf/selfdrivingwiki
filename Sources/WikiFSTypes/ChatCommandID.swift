import Foundation

/// Stable identifier for a user or system command issued against a chat.
///
/// Commands are idempotency keys. Repeating the same raw value must identify
/// the same semantic command.
public struct ChatCommandID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ChatCommandID: Identifiable {
    public var id: String { rawValue }
}
