import Foundation

/// Stable identifier for a source entity.
///
/// The raw value and Codable representation match the legacy source-valued
/// `PageID` representation so persisted and external formats stay unchanged.
public struct SourceID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SourceID: Identifiable {
    public var id: String { rawValue }
}
