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
/// bounded host operations listed by ``RendererDescriptor``.
public enum RendererCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case inputRead
    case externalLink
    case hostNavigation
    case assetRead
    case network
    case credentials
    case worker
    case contentWrite
}

/// The closed roles a Web package may request through the revision-5
/// `assetRead` capability. Each role describes where an extracted reference
/// appears in the package's own document model; the host stores no format
/// knowledge beyond the role name.
public enum RendererAssetRole: String, Codable, CaseIterable, Hashable, Sendable {
    case imageNode
    case groupBackground
}

/// Closed target namespaces that a Web package may request through the
/// user-activated host-navigation bridge.
public enum RendererHostNavigationTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case page
    case source
    case namedContent
}

/// Explicit, bounded authority paired with the `hostNavigation` capability.
public struct RendererHostNavigationDeclaration: Codable, Hashable, Sendable {
    public let allowedTargetKinds: Set<RendererHostNavigationTargetKind>

    public init(allowedTargetKinds: Set<RendererHostNavigationTargetKind>) throws {
        guard allowedTargetKinds.isEmpty == false else {
            throw RendererValidationError.emptyHostNavigationDeclaration
        }
        self.allowedTargetKinds = allowedTargetKinds
    }
}

/// Explicit, bounded authority paired with the `assetRead` capability
/// (manifest revision 5, Web packages only). It declares the closed roles and
/// approved image MIME types the package may read, the extractor contract
/// bounds, and the single hash-approved package-local reference-extractor
/// asset (`{role, reference}` records) that derives the allowed references
/// from the pinned primary input before any session exists.
public struct RendererAssetReadDeclaration: Codable, Hashable, Sendable {
    public let allowedRoles: Set<RendererAssetRole>
    public let allowedMIMETypes: Set<RendererMIMEType>
    public let maximumExtractedReferenceCount: Int
    public let maximumExtractorInputBytes: Int
    public let maximumExtractorOutputBytes: Int
    public let maximumExtractorExecutionSeconds: Int
    public let maximumBytesPerAsset: Int
    public let maximumAggregateSessionBytes: Int
    public let extractorAsset: RendererRelativePath
    public let extractorEntryFunction: String

    public init(
        allowedRoles: Set<RendererAssetRole>,
        allowedMIMETypes: Set<RendererMIMEType>,
        maximumExtractedReferenceCount: Int,
        maximumExtractorInputBytes: Int,
        maximumExtractorOutputBytes: Int,
        maximumExtractorExecutionSeconds: Int,
        maximumBytesPerAsset: Int,
        maximumAggregateSessionBytes: Int,
        extractorAsset: RendererRelativePath,
        extractorEntryFunction: String
    ) throws {
        guard allowedRoles.isEmpty == false else {
            throw RendererValidationError.emptyAssetReadDeclaration
        }
        guard allowedMIMETypes.isEmpty == false else {
            throw RendererValidationError.emptyAssetReadDeclaration
        }
        let supportedMIMEs: Set<RendererMIMEType> = [
            try .init(validating: "image/png"),
            try .init(validating: "image/jpeg"),
            try .init(validating: "image/gif"),
            try .init(validating: "image/svg+xml"),
            try .init(validating: "image/webp"),
        ]
        guard allowedMIMETypes.isSubset(of: supportedMIMEs) else {
            throw RendererValidationError.unsupportedAssetMIMEType
        }
        guard maximumExtractedReferenceCount > 0,
              maximumExtractedReferenceCount <= RendererAssetReadLimits.maximumExtractedReferenceCount else {
            throw RendererValidationError.invalidAssetReadLimit("maximumExtractedReferenceCount=\(maximumExtractedReferenceCount)")
        }
        guard maximumExtractorInputBytes > 0,
              maximumExtractorInputBytes <= RendererAssetReadLimits.maximumExtractorInputBytes else {
            throw RendererValidationError.invalidAssetReadLimit("maximumExtractorInputBytes=\(maximumExtractorInputBytes)")
        }
        guard maximumExtractorOutputBytes > 0,
              maximumExtractorOutputBytes <= RendererAssetReadLimits.maximumExtractorOutputBytes else {
            throw RendererValidationError.invalidAssetReadLimit("maximumExtractorOutputBytes=\(maximumExtractorOutputBytes)")
        }
        guard maximumExtractorExecutionSeconds > 0,
              maximumExtractorExecutionSeconds <= RendererAssetReadLimits.maximumExtractorExecutionSeconds else {
            throw RendererValidationError.invalidAssetReadLimit("maximumExtractorExecutionSeconds=\(maximumExtractorExecutionSeconds)")
        }
        guard maximumBytesPerAsset > 0,
              maximumBytesPerAsset <= RendererAssetReadLimits.maximumBytesPerAsset else {
            throw RendererValidationError.invalidAssetReadLimit("maximumBytesPerAsset=\(maximumBytesPerAsset)")
        }
        guard maximumAggregateSessionBytes > 0,
              maximumAggregateSessionBytes <= RendererAssetReadLimits.maximumAggregateSessionBytes else {
            throw RendererValidationError.invalidAssetReadLimit("maximumAggregateSessionBytes=\(maximumAggregateSessionBytes)")
        }
        guard rendererJavaScriptIdentifier(extractorEntryFunction) else {
            throw RendererValidationError.invalidAssetReadLimit("extractorEntryFunction=\(extractorEntryFunction)")
        }
        self.allowedRoles = allowedRoles
        self.allowedMIMETypes = allowedMIMETypes
        self.maximumExtractedReferenceCount = maximumExtractedReferenceCount
        self.maximumExtractorInputBytes = maximumExtractorInputBytes
        self.maximumExtractorOutputBytes = maximumExtractorOutputBytes
        self.maximumExtractorExecutionSeconds = maximumExtractorExecutionSeconds
        self.maximumBytesPerAsset = maximumBytesPerAsset
        self.maximumAggregateSessionBytes = maximumAggregateSessionBytes
        self.extractorAsset = extractorAsset
        self.extractorEntryFunction = extractorEntryFunction
    }
}

/// The named ceilings for renderer asset-read declarations. These clamp what a
/// package may request so a hostile or corrupt manifest cannot expand host
/// budget beyond a bounded, documentable cap.
public enum RendererAssetReadLimits {
    public static let maximumExtractedReferenceCount = 256
    public static let maximumExtractorInputBytes = 256 * 1_024
    public static let maximumExtractorOutputBytes = 256 * 1_024
    public static let maximumExtractorExecutionSeconds = 10
    public static let maximumBytesPerAsset = 16 * 1_024 * 1_024
    public static let maximumAggregateSessionBytes = 64 * 1_024 * 1_024
}

/// True when `value` is a valid JavaScript identifier (the extractor entry
/// function name and the fence-validation entry function share the same
/// identifier-safety requirement).
func rendererJavaScriptIdentifier(_ value: String) -> Bool {
    guard value.isEmpty == false,
          value.first == "_" || value.first?.isLetter == true,
          value.allSatisfy({ $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber })
    else { return false }
    // Reject reserved words so a package cannot alias a host intrinsic.
    let reserved: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export",
        "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "null", "return", "static",
        "super", "switch", "this", "throw", "true", "try", "typeof", "var",
        "void", "while", "with", "yield", "null", "undefined", "NaN", "Infinity",
    ]
    return reserved.contains(value) == false
}
