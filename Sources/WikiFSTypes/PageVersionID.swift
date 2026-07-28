import Foundation

/// Stable identifier for a page-content version row (`page_versions.id`).
///
/// The raw value and Codable representation preserve the existing SQLite and
/// external string contracts.
public struct PageVersionID: Hashable, Codable, RawRepresentable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PageVersionID: Identifiable {
    public var id: String { rawValue }
}

extension PageVersionID {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
