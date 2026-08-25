import Foundation

// pattern: Functional Core

public struct RendererRelativePath: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let segments = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard rawValue.isEmpty == false,
              rawValue.hasPrefix("/") == false,
              rawValue.contains("\\") == false,
              segments.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." && $0.contains("\0") == false })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw RendererValidationError.invalidRelativePath(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RendererMIMEType: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == rawValue.lowercased(),
              rawValue.range(of: "^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$", options: .regularExpression) != nil
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw RendererValidationError.invalidMIMEType(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RendererFileExtension: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == rawValue.lowercased(), rawValue.hasPrefix(".") == false,
              rawValue.isEmpty == false, rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw RendererValidationError.invalidExtension(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RendererArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case markdown
    case image
    case binary
}

/// The named upper bound for all in-memory source sniffing in renderer matching.
public enum RendererMatchingLimits {
    public static let maximumSniffByteCount = 4_096
}

public struct RendererSizeLimits: Codable, Hashable, Sendable {
    public let maximumInputByteCount: Int
    public let maximumDecodedByteCount: Int

    public init(maximumInputByteCount: Int, maximumDecodedByteCount: Int) throws {
        guard maximumInputByteCount > 0, maximumDecodedByteCount > 0,
              maximumDecodedByteCount >= maximumInputByteCount else {
            throw RendererValidationError.invalidSizeLimit("input=\(maximumInputByteCount), decoded=\(maximumDecodedByteCount)")
        }
        self.maximumInputByteCount = maximumInputByteCount
        self.maximumDecodedByteCount = maximumDecodedByteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumInputByteCount: container.decode(Int.self, forKey: .maximumInputByteCount), maximumDecodedByteCount: container.decode(Int.self, forKey: .maximumDecodedByteCount))
    }
}

public struct RendererCompatibility: Codable, Hashable, Sendable {
    public let minimumProtocolRevision: Int
    public let maximumProtocolRevision: Int

    public init(minimumProtocolRevision: Int, maximumProtocolRevision: Int) throws {
        guard minimumProtocolRevision > 0, maximumProtocolRevision >= minimumProtocolRevision else {
            throw RendererValidationError.invalidCompatibilityRange
        }
        self.minimumProtocolRevision = minimumProtocolRevision
        self.maximumProtocolRevision = maximumProtocolRevision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(minimumProtocolRevision: container.decode(Int.self, forKey: .minimumProtocolRevision), maximumProtocolRevision: container.decode(Int.self, forKey: .maximumProtocolRevision))
    }

    public func supports(hostProtocolRevision: Int) -> Bool {
        hostProtocolRevision >= minimumProtocolRevision && hostProtocolRevision <= maximumProtocolRevision
    }
}

public enum RendererPresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case native
    case web
}

/// The document-owned presentation role a renderer is allowed to fill.
/// Syntax selects this role before renderer matching; a renderer cannot promote
/// inline content into disclosure chrome or remove disclosure from a rich fence.
public enum RendererEmbeddingRole: String, Codable, CaseIterable, Hashable, Sendable {
    case inlineContent
    case disclosureRow
}

public enum RendererLinkPolicy: String, Codable, Hashable, Sendable {
    case none
    case userActivatedExternal
}

public struct RendererAccessibility: Codable, Hashable, Sendable {
    public let supportsVoiceOver: Bool
    public let supportsKeyboardNavigation: Bool

    public init(supportsVoiceOver: Bool, supportsKeyboardNavigation: Bool) {
        self.supportsVoiceOver = supportsVoiceOver
        self.supportsKeyboardNavigation = supportsKeyboardNavigation
    }
}

/// Capability names parsed from package metadata. Validation admits only the
/// two read-only host operations in this phase.
public enum RendererCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case inputRead
    case externalLink
    case network
    case credentials
    case worker
    case contentWrite
}
