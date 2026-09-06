import Foundation

/// Package-owned source-format metadata for one renderer descriptor.
///
/// Routing remains owned by the descriptor's matchers. The manifest validates
/// that every value declared here has an equivalent routing matcher.
public struct RendererSourceTypeDeclaration: Codable, Hashable, Sendable {
    public let canonicalMIMEType: RendererMIMEType
    public let mimeAliases: Set<RendererMIMEType>
    public let filenameExtensions: Set<RendererFileExtension>

    public init(
        canonicalMIMEType: RendererMIMEType,
        mimeAliases: Set<RendererMIMEType> = [],
        filenameExtensions: Set<RendererFileExtension> = []
    ) throws {
        guard mimeAliases.contains(canonicalMIMEType) == false else {
            throw RendererValidationError.duplicateSourceTypeMIME(canonicalMIMEType.rawValue)
        }
        self.canonicalMIMEType = canonicalMIMEType
        self.mimeAliases = mimeAliases
        self.filenameExtensions = filenameExtensions
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalMIMEType
        case mimeAliases
        case filenameExtensions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonicalRaw = try container.decode(String.self, forKey: .canonicalMIMEType)
        let aliasRaw = try container.decodeIfPresent([String].self, forKey: .mimeAliases) ?? []
        let extensionRaw = try container.decodeIfPresent([String].self, forKey: .filenameExtensions) ?? []
        let canonical = try RendererMIMEType(validating: Self.normalizedMIME(canonicalRaw))
        let aliases = try Self.decodeUniqueMIMEs(aliasRaw, canonical: canonical)
        let extensions = try Self.decodeUniqueExtensions(extensionRaw)
        try self.init(
            canonicalMIMEType: canonical,
            mimeAliases: aliases,
            filenameExtensions: extensions)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalMIMEType, forKey: .canonicalMIMEType)
        try container.encode(mimeAliases.sorted(), forKey: .mimeAliases)
        try container.encode(filenameExtensions.sorted(), forKey: .filenameExtensions)
    }

    public var allMIMETypes: Set<RendererMIMEType> {
        mimeAliases.union([canonicalMIMEType])
    }

    private static func decodeUniqueMIMEs(
        _ rawValues: [String],
        canonical: RendererMIMEType
    ) throws -> Set<RendererMIMEType> {
        var values = Set<RendererMIMEType>()
        for rawValue in rawValues {
            let normalized = normalizedMIME(rawValue)
            let value = try RendererMIMEType(validating: normalized)
            guard value != canonical, values.insert(value).inserted else {
                throw RendererValidationError.duplicateSourceTypeMIME(normalized)
            }
        }
        return values
    }

    private static func decodeUniqueExtensions(_ rawValues: [String]) throws -> Set<RendererFileExtension> {
        var values = Set<RendererFileExtension>()
        for rawValue in rawValues {
            let normalized = normalizedExtension(rawValue)
            let value = try RendererFileExtension(validating: normalized)
            guard values.insert(value).inserted else {
                throw RendererValidationError.duplicateSourceTypeExtension(normalized)
            }
        }
        return values
    }

    private static func normalizedMIME(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedExtension(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") { normalized.removeFirst() }
        return normalized
    }
}
