import Foundation
import WikiFSTypes

// pattern: Functional Core

/// One validated relative content reference for a renderer package byte read
/// (`asset.read`, manifest revision 5). It is distinct from
/// `RendererNamedContentReference` (which is a *navigation* target): this
/// value names a byte source the host resolves to an exact pinned
/// `SourceVersionID` before session creation and returns only through the
/// authorized asset reader.
///
/// Rejections match the navigation-path validator's fail-closed posture:
/// empty or oversized values, absolute paths, schemes, credentials, queries,
/// fragments, percent escapes, backslashes, control characters, whitespace
/// padding, empty components, and `.`/`..` components are all invalid.
public struct RendererAssetReference: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererBridgeAuthorizationError.invalidAssetReference
        }
        self = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(validating: String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func isValid(_ value: String) -> Bool {
        guard value.isEmpty == false,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= WikiAppWebViewPolicy.maximumAssetReferenceByteCount,
              value.hasPrefix("/") == false,
              value.hasPrefix("~") == false,
              value.contains("\\") == false,
              value.contains(":") == false,
              value.contains("@") == false,
              value.contains("?") == false,
              value.contains("#") == false,
              value.contains("%") == false,
              value.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
        else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { $0.isEmpty == false && $0 != "." && $0 != ".." }
    }
}
