import Foundation

/// Stable identity for one system-notice transcript item.
public struct ChatTranscriptNoticeID: Hashable, Codable, RawRepresentable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

/// Stable identity for one terminal-failure transcript item.
public struct ChatTranscriptFailureID: Hashable, Codable, RawRepresentable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

/// A leaf transcript item was encoded before durable non-message identities.
public enum ChatTranscriptItemDecodingError: Error, Hashable, Sendable {
    case missingNoticeIdentity
    case missingFailureIdentity
}
