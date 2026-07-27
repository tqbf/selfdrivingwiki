import Foundation

/// Stable identifier for a source content-version row (`source_versions.id`).
///
/// The raw value and Codable representation match the legacy string-backed
/// source-version identifiers so persisted and external formats stay unchanged.
public struct SourceVersionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SourceVersionID: Identifiable {
    public var id: String { rawValue }
}
