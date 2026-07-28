import Foundation

/// Stable identifier for a source markdown-version row
/// (`source_markdown_versions.id`).
///
/// The raw value and Codable representation match the legacy string-backed
/// markdown-version identifiers so persisted and external formats stay
/// unchanged.
public struct SourceMarkdownVersionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SourceMarkdownVersionID: Identifiable {
    public var id: String { rawValue }
}
