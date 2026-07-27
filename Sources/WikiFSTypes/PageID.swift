import Foundation

/// Stable identifier for a wiki page. Backed by a ULID string (see `ULID`).
public struct PageID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PageID: Identifiable {
    public var id: String { rawValue }
}
