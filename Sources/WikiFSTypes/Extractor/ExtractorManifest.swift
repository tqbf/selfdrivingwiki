import Foundation

// pattern: Functional Core

/// Hard host policy limits for extractor manifest and operation revision 1.
public enum ExtractorHostLimits {
    public static let maximumManifestByteCount = 256 * 1_024
    public static let maximumPackageFileCount = 1_024
    public static let maximumPackageByteCount = 64 * 1_024 * 1_024
    public static let maximumFrameByteCount = 64 * 1_024
    public static let maximumStandardErrorByteCount = 64 * 1_024
    public static let maximumInputByteCount = 128 * 1_024 * 1_024
    public static let maximumMarkdownOutputByteCount = 128 * 1_024 * 1_024
    public static let maximumDurationMilliseconds = 30 * 60 * 1_000
    public static let maximumProgressEventCount = 10_000
    public static let maximumFixedArgumentCount = 64
    public static let maximumFixedArgumentByteCount = 8 * 1_024
}

extension ExtractorHostLimits {
    /// Sync config sidecar file name declared by a registration (UTF-8 bytes).
    public static let maximumSyncConfigFileNameByteCount = 128
    /// Sync source URL template declared by a registration (UTF-8 bytes).
    public static let maximumSyncTemplateByteCount = 512
    /// Declared sync fields per registration.
    public static let maximumSyncFieldCount = 8
    /// One declared sync field name (UTF-8 bytes).
    public static let maximumSyncFieldNameByteCount = 64
    /// One declared sync validation pattern — field or item (UTF-8 bytes).
    public static let maximumSyncPatternByteCount = 256
    /// One declared sync item alphabet (UTF-8 bytes).
    public static let maximumSyncAlphabetByteCount = 128
    /// One accepted sync item value — length bounds and values are capped
    /// here so a config sidecar cannot make the host loop or store
    /// unbounded strings (UTF-8 bytes).
    public static let maximumSyncItemLength = 256
    /// One accepted sync list length (items) at sidecar load.
    public static let maximumSyncItemCount = 4_096
}

/// Length bounds plus either a character alphabet or a bounded regex for the
/// item keys of a sync declaration's list field. The structured replacement
/// for the retired per-kind key alphabets (e.g. Zotero's 8-character
/// A–Z0–9 item keys): `alphabet` expresses "these characters, this length
/// range"; `pattern` is the general form. Exactly one of the two may be
/// declared; neither means length-only validation.
///
/// Lengths count UTF-8 bytes, matching every other host bound.
public struct ExtractorSyncItemValidation: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case minimumLength, maximumLength, alphabet, pattern
    }

    public let minimumLength: Int
    public let maximumLength: Int
    public let alphabet: String?
    public let pattern: String?

    public init(
        minimumLength: Int,
        maximumLength: Int,
        alphabet: String? = nil,
        pattern: String? = nil
    ) throws {
        guard minimumLength >= 1,
              minimumLength <= maximumLength,
              maximumLength <= ExtractorHostLimits.maximumSyncItemLength else {
            throw ExtractorValidationError.invalidManifest("sync item validation length bounds")
        }
        switch (alphabet, pattern) {
        case (.some(let alphabet), nil):
            guard alphabet.isEmpty == false,
                  Set(alphabet).count == alphabet.count,
                  alphabet.utf8.count <= ExtractorHostLimits.maximumSyncAlphabetByteCount,
                  alphabet.contains("{") == false,
                  alphabet.contains("}") == false,
                  alphabet.contains("\0") == false else {
                throw ExtractorValidationError.invalidManifest("sync item validation alphabet")
            }
        case (nil, .some(let pattern)):
            try ExtractorSyncPatternRules.validate(pattern, what: "sync item validation pattern")
        case (.some, .some):
            throw ExtractorValidationError.invalidManifest(
                "sync item validation declares both alphabet and pattern")
        case (nil, nil):
            break
        }
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.alphabet = alphabet
        self.pattern = pattern
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumLength: container.decode(Int.self, forKey: .minimumLength),
            maximumLength: container.decode(Int.self, forKey: .maximumLength),
            alphabet: container.decodeIfPresent(String.self, forKey: .alphabet),
            pattern: container.decodeIfPresent(String.self, forKey: .pattern))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minimumLength, forKey: .minimumLength)
        try container.encode(maximumLength, forKey: .maximumLength)
        if let alphabet { try container.encode(alphabet, forKey: .alphabet) }
        if let pattern { try container.encode(pattern, forKey: .pattern) }
    }
}

/// One declared config field of a sync declaration: the sidecar key the
/// host reads, whether it must be present, and how its value is bounded.
public struct ExtractorSyncFieldDeclaration: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, required, pattern, isList
    }

    /// The config sidecar key this field reads (e.g. `libraryID`).
    public let name: String
    public let isRequired: Bool
    /// Optional bounded regex the whole (trimmed) value must match.
    public let pattern: String?
    /// True for the one field that carries the item keys to sync.
    public let isList: Bool

    public init(
        name: String,
        required: Bool,
        pattern: String? = nil,
        isList: Bool = false
    ) throws {
        guard ExtractorIdentifierRules.isSyncFieldName(name) else {
            throw ExtractorValidationError.invalidManifest("sync field name \(name)")
        }
        // The placeholder name is reserved: a field named `itemKey` would be
        // demanded at load but silently ignored at interpolation.
        guard name != ExtractorSyncPlaceholder.itemKey else {
            throw ExtractorValidationError.invalidManifest(
                "sync field name \(name) is reserved")
        }
        if let pattern {
            try ExtractorSyncPatternRules.validate(pattern, what: "sync field pattern")
        }
        self.name = name
        self.isRequired = required
        self.pattern = pattern
        self.isList = isList
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            required: container.decode(Bool.self, forKey: .required),
            pattern: container.decodeIfPresent(String.self, forKey: .pattern),
            isList: container.decodeIfPresent(Bool.self, forKey: .isList) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(isRequired, forKey: .required)
        if let pattern { try container.encode(pattern, forKey: .pattern) }
        if isList { try container.encode(true, forKey: .isList) }
    }
}

/// Shared bounds for declared sync validation patterns: bounded, non-empty,
/// NUL-free, and it must compile as a regular expression at decode time so a
/// broken pattern fails manifest validation, never a later sync run.
enum ExtractorSyncPatternRules {
    static func validate(_ pattern: String, what: String) throws {
        guard pattern.isEmpty == false,
              pattern.utf8.count <= ExtractorHostLimits.maximumSyncPatternByteCount,
              pattern.contains("\0") == false else {
            throw ExtractorValidationError.invalidManifest("\(what) exceeds host policy")
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ExtractorValidationError.invalidManifest("\(what) does not compile")
        }
    }
}

/// The placeholder every sync URL template must carry exactly once: each
/// list item substitutes it, which is what makes one configured list become
/// many distinct source URLs.
public enum ExtractorSyncPlaceholder {
    public static let itemKey = "itemKey"
}

/// Manifest revision 3: one registration's acquisition-sync declaration.
///
/// A package that declares `sync` is syncable: `wikictl extractor sync
/// <short-name>` loads the declared config sidecar from the App Group
/// container, interpolates the URL template with the declared field values
/// and each item key, and enqueues one byteless source per item. The host
/// side of that flow is fully generic — every package-specific fact lives
/// here, in package data.
public struct ExtractorSyncDeclaration: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case configFileName, urlTemplate, fields, itemValidation, sourceMIMEType
    }

    /// The sidecar file name in the App Group container (e.g.
    /// `zotero-config.json`). No path separators: it names one file beside
    /// `wikis.json`, never a nested path.
    public let configFileName: String
    /// The byteless source URL template with named placeholders in braces.
    /// Placeholders must be declared field names plus `{itemKey}`, which must
    /// appear exactly once. Sample interpolation must form a valid absolute
    /// HTTPS URL.
    public let urlTemplate: String
    /// The config fields the sidecar may carry, in declaration order.
    public let fields: [ExtractorSyncFieldDeclaration]
    /// Validation for the list field's items (length bounds plus alphabet
    /// or pattern). Optional: an unvalidated list is accepted.
    public let itemValidation: ExtractorSyncItemValidation?
    /// The MIME type of the byteless sources the sync creates. Defaults to
    /// the registration's single declared MIME type when absent.
    public let sourceMIMEType: ExtractorMIMEType?

    public init(
        configFileName: String,
        urlTemplate: String,
        fields: [ExtractorSyncFieldDeclaration],
        itemValidation: ExtractorSyncItemValidation? = nil,
        sourceMIMEType: ExtractorMIMEType? = nil
    ) throws {
        guard configFileName.isEmpty == false,
              configFileName.utf8.count <= ExtractorHostLimits.maximumSyncConfigFileNameByteCount,
              configFileName.contains("/") == false,
              configFileName.contains("\\") == false,
              configFileName.contains("\0") == false,
              configFileName != ".",
              configFileName != ".." else {
            throw ExtractorValidationError.invalidManifest("sync config file name")
        }
        guard urlTemplate.utf8.count <= ExtractorHostLimits.maximumSyncTemplateByteCount,
              urlTemplate.isEmpty == false,
              urlTemplate.contains("\0") == false else {
            throw ExtractorValidationError.invalidManifest("sync URL template")
        }
        guard fields.isEmpty == false,
              fields.count <= ExtractorHostLimits.maximumSyncFieldCount else {
            throw ExtractorValidationError.invalidManifest("sync field count")
        }
        let fieldNames = fields.map(\.name)
        guard Set(fieldNames).count == fieldNames.count else {
            throw ExtractorValidationError.invalidManifest("sync declares duplicate field names")
        }
        let listFields = fields.filter(\.isList)
        guard listFields.count == 1 else {
            throw ExtractorValidationError.invalidManifest(
                "sync declaration must declare exactly one list field")
        }
        guard try Self.templatePlaceholders(urlTemplate)
            .allSatisfy({ $0 == ExtractorSyncPlaceholder.itemKey || fieldNames.contains($0) }) else {
            throw ExtractorValidationError.invalidManifest(
                "sync URL template uses an undeclared placeholder")
        }
        guard try Self.templatePlaceholders(urlTemplate)
            .filter({ $0 == ExtractorSyncPlaceholder.itemKey }).count == 1 else {
            throw ExtractorValidationError.invalidManifest(
                "sync URL template must reference {itemKey} exactly once")
        }
        try Self.validateTemplateFormsHTTPSURL(urlTemplate, fields: fields)
        self.configFileName = configFileName
        self.urlTemplate = urlTemplate
        self.fields = fields
        self.itemValidation = itemValidation
        self.sourceMIMEType = sourceMIMEType
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            configFileName: container.decode(String.self, forKey: .configFileName),
            urlTemplate: container.decode(String.self, forKey: .urlTemplate),
            fields: try container.decodeIfPresent(
                [ExtractorSyncFieldDeclaration].self, forKey: .fields) ?? [],
            itemValidation: container.decodeIfPresent(
                ExtractorSyncItemValidation.self, forKey: .itemValidation),
            sourceMIMEType: container.decodeIfPresent(
                ExtractorMIMEType.self, forKey: .sourceMIMEType))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configFileName, forKey: .configFileName)
        try container.encode(urlTemplate, forKey: .urlTemplate)
        try container.encode(fields, forKey: .fields)
        if let itemValidation { try container.encode(itemValidation, forKey: .itemValidation) }
        if let sourceMIMEType { try container.encode(sourceMIMEType, forKey: .sourceMIMEType) }
    }

    /// The field declaration carrying the item keys.
    public var listField: ExtractorSyncFieldDeclaration {
        guard let field = fields.first(where: \.isList) else {
            preconditionFailure("sync declaration without a list field cannot exist")
        }
        return field
    }

    /// The template's placeholder tokens in order. Throws on malformed
    /// braces (unbalanced, empty, or nested) — used at validation time so a
    /// broken template is a typed manifest failure, never a runtime nil.
    static func templatePlaceholders(_ template: String) throws -> [String] {
        var tokens: [String] = []
        var remainder = Substring(template)
        while let open = remainder.firstIndex(of: "{") {
            // A stray `}` before the next `{` is malformed braces, not a
            // literal — the template grammar reserves both characters.
            guard remainder[..<open].contains("}") == false else {
                throw ExtractorValidationError.invalidManifest(
                    "sync URL template has malformed braces")
            }
            guard let close = remainder[open...].firstIndex(of: "}"),
                  close > remainder.index(after: open),
                  remainder[remainder.index(after: open)..<close].contains("{") == false else {
                throw ExtractorValidationError.invalidManifest(
                    "sync URL template has malformed braces")
            }
            tokens.append(String(remainder[remainder.index(after: open)..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        guard remainder.contains("}") == false else {
            throw ExtractorValidationError.invalidManifest("sync URL template has malformed braces")
        }
        return tokens
    }

    /// Interpolates the template with a value per field plus one item key.
    /// Returns `nil` when the result does not form a valid URL — the
    /// caller-facing invalid-item gate.
    public func interpolatedURL(fieldValues: [String: String], itemKey: String) -> URL? {
        Self.interpolate(template: urlTemplate, fieldValues: fieldValues, itemKey: itemKey)
    }

    /// The template must form a valid absolute HTTPS URL once its
    /// placeholders are replaced with sample values — validated now so a
    /// broken template never reaches a sync run.
    private static func validateTemplateFormsHTTPSURL(
        _ template: String, fields: [ExtractorSyncFieldDeclaration]
    ) throws {
        let sample = "s"
        let fieldValues = Dictionary(
            uniqueKeysWithValues: fields.map { ($0.name, sample) })
        guard let url = Self.interpolate(
            template: template, fieldValues: fieldValues, itemKey: sample),
              url.scheme == "https",
              url.host?.isEmpty == false else {
            throw ExtractorValidationError.invalidManifest(
                "sync URL template does not form an absolute HTTPS URL")
        }
    }

    /// Placeholder substitution over the template. A token with no value
    /// (missing field) or a result `URL` cannot parse yields `nil`.
    private static func interpolate(
        template: String, fieldValues: [String: String], itemKey: String
    ) -> URL? {
        var result = ""
        var remainder = Substring(template)
        while let open = remainder.firstIndex(of: "{") {
            guard let close = remainder[open...].firstIndex(of: "}"), close > remainder.index(after: open) else {
                return nil
            }
            result += remainder[..<open]
            let token = String(remainder[remainder.index(after: open)..<close])
            let value = token == ExtractorSyncPlaceholder.itemKey
                ? itemKey
                : fieldValues[token]
            guard let value else { return nil }
            result += value
            remainder = remainder[remainder.index(after: close)...]
        }
        result += remainder
        return URL(string: result)
    }
}

public struct ExtractorOperationLimits: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case maximumInputByteCount
        case maximumMarkdownOutputByteCount
        case maximumDurationMilliseconds
        case maximumProgressEventCount
    }

    public let maximumInputByteCount: Int
    public let maximumMarkdownOutputByteCount: Int
    public let maximumDurationMilliseconds: Int
    public let maximumProgressEventCount: Int

    public init(
        maximumInputByteCount: Int,
        maximumMarkdownOutputByteCount: Int,
        maximumDurationMilliseconds: Int,
        maximumProgressEventCount: Int
    ) throws {
        guard maximumInputByteCount > 0,
              maximumInputByteCount <= ExtractorHostLimits.maximumInputByteCount else {
            throw ExtractorValidationError.limitExceedsHostPolicy("input bytes")
        }
        guard maximumMarkdownOutputByteCount > 0,
              maximumMarkdownOutputByteCount <= ExtractorHostLimits.maximumMarkdownOutputByteCount else {
            throw ExtractorValidationError.limitExceedsHostPolicy("markdown bytes")
        }
        guard maximumDurationMilliseconds > 0,
              maximumDurationMilliseconds <= ExtractorHostLimits.maximumDurationMilliseconds else {
            throw ExtractorValidationError.limitExceedsHostPolicy("duration")
        }
        guard maximumProgressEventCount > 0,
              maximumProgressEventCount <= ExtractorHostLimits.maximumProgressEventCount else {
            throw ExtractorValidationError.limitExceedsHostPolicy("progress events")
        }
        self.maximumInputByteCount = maximumInputByteCount
        self.maximumMarkdownOutputByteCount = maximumMarkdownOutputByteCount
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.maximumProgressEventCount = maximumProgressEventCount
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumInputByteCount: container.decode(Int.self, forKey: .maximumInputByteCount),
            maximumMarkdownOutputByteCount: container.decode(Int.self, forKey: .maximumMarkdownOutputByteCount),
            maximumDurationMilliseconds: container.decode(Int.self, forKey: .maximumDurationMilliseconds),
            maximumProgressEventCount: container.decode(Int.self, forKey: .maximumProgressEventCount))
    }
}

public enum ExtractorLaunch: Codable, Hashable, Sendable {
    case direct
    case runtime(command: ExtractorRuntimeName, arguments: [String])

    private enum CodingKeys: String, CodingKey, CaseIterable { case mode, command, arguments }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ExtractorLaunchMode.self, forKey: .mode) {
        case .direct:
            let arguments = try container.decodeIfPresent([String].self, forKey: .arguments)
            guard container.contains(.command) == false, arguments == nil else {
                throw ExtractorValidationError.invalidManifest("direct launch cannot declare a runtime")
            }
            self = .direct
        case .runtime:
            let command = try container.decode(ExtractorRuntimeName.self, forKey: .command)
            let arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            try Self.validate(arguments: arguments)
            self = .runtime(command: command, arguments: arguments)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct:
            try container.encode(ExtractorLaunchMode.direct, forKey: .mode)
        case .runtime(let command, let arguments):
            try Self.validate(arguments: arguments)
            try container.encode(ExtractorLaunchMode.runtime, forKey: .mode)
            try container.encode(command, forKey: .command)
            if arguments.isEmpty == false { try container.encode(arguments, forKey: .arguments) }
        }
    }

    private static func validate(arguments: [String]) throws {
        guard arguments.count <= ExtractorHostLimits.maximumFixedArgumentCount,
              arguments.allSatisfy({ $0.utf8.count <= ExtractorHostLimits.maximumFixedArgumentByteCount && $0.contains("\0") == false }) else {
            throw ExtractorValidationError.invalidManifest("runtime arguments exceed host policy")
        }
    }
}

public struct ExtractorRegistration: Codable, Hashable, Sendable, Comparable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, kinds, mimeTypes, filenameExtensions
    }

    /// Revision-2 keys: adds registration-scoped credential requirement
    /// declarations (issue #1159). Revision 1 decoding rejects this key
    /// (unknown-field policy), so a v1 manifest cannot carry credentials.
    enum V2CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, kinds, mimeTypes, filenameExtensions, credentialRequirements
    }

    /// Revision-3 keys: adds the registration-scoped acquisition-sync
    /// declaration (package-declared syncability). Revisions 1 and 2 reject
    /// this key (unknown-field policy), so only a v3 manifest can declare
    /// sync.
    enum V3CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, kinds, mimeTypes, filenameExtensions, credentialRequirements, sync
    }

    public let id: ExtractorRegistrationID
    public let displayName: String
    public let kinds: Set<ExtractorKind>
    public let mimeTypes: Set<ExtractorMIMEType>
    public let filenameExtensions: Set<ExtractorFileExtension>
    /// Non-secret credential DECLARATIONS (id/kind/optionality/label/purpose).
    /// Never a value, never a reference binding. Empty for every revision-1
    /// registration.
    public let credentialRequirements: [ExtractorCredentialRequirement]
    /// The registration's acquisition-sync declaration (revision 3). `nil`
    /// for every revision-1/2 registration and for revision-3 registrations
    /// that declare no sync surface.
    public let sync: ExtractorSyncDeclaration?

    public init(
        id: ExtractorRegistrationID,
        displayName: String,
        kinds: Set<ExtractorKind>,
        mimeTypes: Set<ExtractorMIMEType>,
        filenameExtensions: Set<ExtractorFileExtension> = [],
        credentialRequirements: [ExtractorCredentialRequirement] = [],
        sync: ExtractorSyncDeclaration? = nil
    ) throws {
        guard displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              displayName.utf8.count <= 128 else {
            throw ExtractorValidationError.invalidManifest("registration display name")
        }
        guard kinds.isEmpty == false else { throw ExtractorValidationError.invalidManifest("registration kind set is empty") }
        guard mimeTypes.isEmpty == false else { throw ExtractorValidationError.invalidManifest("registration MIME type set is empty") }
        guard credentialRequirements.count <= ExtractorHostLimits.maximumRequirementsPerRegistration else {
            throw ExtractorValidationError.invalidManifest("too many credential requirements")
        }
        guard Set(credentialRequirements.map(\.id)).count == credentialRequirements.count else {
            throw ExtractorValidationError.invalidManifest(
                "registration declares duplicate credential requirement IDs")
        }
        if let sync {
            // The sync's source MIME defaults to the registration's single
            // declared MIME type, so a multi-MIME registration must declare
            // one explicitly.
            if sync.sourceMIMEType == nil, mimeTypes.count != 1 {
                throw ExtractorValidationError.invalidManifest(
                    "sync declaration without a source MIME type requires exactly one registration MIME type")
            }
            // The sync credential gate operates on the registration's
            // required credential requirement; more than one required
            // requirement would make its subject ambiguous. Zero is allowed:
            // a package with no required credentials syncs without the gate.
            let requiredRequirements = credentialRequirements.filter { $0.isOptional == false }
            guard requiredRequirements.count <= 1 else {
                throw ExtractorValidationError.invalidManifest(
                    "sync declaration supports at most one required credential requirement")
            }
        }
        self.id = id
        self.displayName = displayName
        self.kinds = kinds
        self.mimeTypes = mimeTypes
        self.filenameExtensions = filenameExtensions
        self.credentialRequirements = credentialRequirements.sorted()
        self.sync = sync
    }

    /// The v1 decoder: strict, no credential key.
    public init(from decoder: any Decoder) throws {
        try self.init(
            from: decoder, manifestRevision: .v1)
    }

    /// Revision-aware decoding. Revision 1 rejects the
    /// `credentialRequirements` key outright (unknown-field policy);
    /// revision 2 accepts it and validates every declaration. Revision 3
    /// additionally accepts the `sync` key.
    public init(from decoder: any Decoder, manifestRevision: ExtractorManifestRevision) throws {
        if manifestRevision == .v3 {
            try rejectUnknownKeys(from: decoder, allowed: V3CodingKeys.self)
        } else if manifestRevision == .v2 {
            try rejectUnknownKeys(from: decoder, allowed: V2CodingKeys.self)
        } else {
            try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        }
        let container = try decoder.container(keyedBy: V3CodingKeys.self)
        try self.init(keyedContainer: container, manifestRevision: manifestRevision)
    }

    /// Shared decode body over an already-keyed container. The catalog
    /// record decoder uses this so a stored registration decodes under the
    /// record's own protocol revision — the plain `init(from:)` defaults to
    /// v1 semantics and would reject a v2 registration's credential key.
    init(keyedContainer: KeyedDecodingContainer<V3CodingKeys>, manifestRevision: ExtractorManifestRevision) throws {
        let known: Set<String> = Set(
            (manifestRevision == .v3
                ? V3CodingKeys.allCases.map(\.stringValue)
                : manifestRevision == .v2
                    ? V2CodingKeys.allCases.map(\.stringValue)
                    : CodingKeys.allCases.map(\.stringValue)))
        if let unknown = keyedContainer.allKeys.first(where: { known.contains($0.stringValue) == false }) {
            throw ExtractorValidationError.invalidManifest("unknown field \(unknown.stringValue)")
        }
        let kinds = try keyedContainer.decode([ExtractorKind].self, forKey: .kinds)
        let mimeTypes = try keyedContainer.decode([ExtractorMIMEType].self, forKey: .mimeTypes)
        let filenameExtensions = try keyedContainer.decodeIfPresent(
            [ExtractorFileExtension].self, forKey: .filenameExtensions) ?? []
        guard Set(kinds).count == kinds.count,
              Set(mimeTypes).count == mimeTypes.count,
              Set(filenameExtensions).count == filenameExtensions.count else {
            throw ExtractorValidationError.invalidManifest("registration contains duplicate values")
        }
        let requirements: [ExtractorCredentialRequirement]
        let sync: ExtractorSyncDeclaration?
        if manifestRevision == .v3 {
            requirements = try keyedContainer.decodeIfPresent(
                [ExtractorCredentialRequirement].self, forKey: .credentialRequirements) ?? []
            sync = try keyedContainer.decodeIfPresent(
                ExtractorSyncDeclaration.self, forKey: .sync)
        } else if manifestRevision == .v2 {
            requirements = try keyedContainer.decodeIfPresent(
                [ExtractorCredentialRequirement].self, forKey: .credentialRequirements) ?? []
            sync = nil
        } else {
            requirements = []
            sync = nil
        }
        try self.init(
            id: keyedContainer.decode(ExtractorRegistrationID.self, forKey: .id),
            displayName: keyedContainer.decode(String.self, forKey: .displayName),
            kinds: Set(kinds),
            mimeTypes: Set(mimeTypes),
            filenameExtensions: Set(filenameExtensions),
            credentialRequirements: requirements,
            sync: sync)
    }

    /// Decodes a registration array element-by-element under the given
    /// manifest revision. The catalog record decoder uses this: the record's
    /// `protocolRevision` governs how its stored registrations decode.
    static func decodeArray(
        from container: inout UnkeyedDecodingContainer,
        manifestRevision: ExtractorManifestRevision
    ) throws -> [ExtractorRegistration] {
        var registrations: [ExtractorRegistration] = []
        registrations.reserveCapacity(container.count ?? 0)
        while container.isAtEnd == false {
            let element = try container.superDecoder()
            registrations.append(
                try self.init(from: element, manifestRevision: manifestRevision))
        }
        return registrations
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: V3CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kinds.sorted { $0.rawValue < $1.rawValue }, forKey: .kinds)
        try container.encode(mimeTypes.sorted(), forKey: .mimeTypes)
        if filenameExtensions.isEmpty == false { try container.encode(filenameExtensions.sorted(), forKey: .filenameExtensions) }
        // Emitted only when non-empty, so revision-1 canonical bytes (always
        // empty here) are unchanged bit-for-bit.
        if credentialRequirements.isEmpty == false {
            try container.encode(credentialRequirements, forKey: .credentialRequirements)
        }
        // Emitted only when non-nil, so revision-1/2 canonical bytes are
        // unchanged bit-for-bit (the same rule the credential key follows).
        if let sync {
            try container.encode(sync, forKey: .sync)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}

public struct ExtractorPackageFile: Codable, Hashable, Sendable, Comparable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case path, digest }

    public let path: ExtractorRelativePath
    public let digest: ExtractorPackageDigest

    public init(path: ExtractorRelativePath, digest: ExtractorPackageDigest) {
        self.path = path
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(ExtractorRelativePath.self, forKey: .path),
            digest: try container.decode(ExtractorPackageDigest.self, forKey: .digest))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path ? lhs.digest < rhs.digest : lhs.path < rhs.path
    }
}

/// Normalized extractor package manifest revision 1.
public struct ExtractorManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case manifestRevision, packageID, version, displayName, protocolRevision
        case entryPoint, launch, registrations, capabilities, files, limits
    }

    public let manifestRevision: ExtractorManifestRevision
    public let packageID: ExtractorPackageID
    public let version: ExtractorPackageVersion
    public let displayName: String
    public let protocolRevision: ExtractorProtocolRevision
    public let entryPoint: ExtractorRelativePath
    public let launch: ExtractorLaunch
    public let registrations: [ExtractorRegistration]
    public let capabilities: Set<ExtractorCapability>
    public let files: [ExtractorPackageFile]
    public let limits: ExtractorOperationLimits

    public init(
        manifestRevision: ExtractorManifestRevision,
        packageID: ExtractorPackageID,
        version: ExtractorPackageVersion,
        displayName: String,
        protocolRevision: ExtractorProtocolRevision,
        entryPoint: ExtractorRelativePath,
        launch: ExtractorLaunch,
        registrations: [ExtractorRegistration],
        capabilities: Set<ExtractorCapability>,
        files: [ExtractorPackageFile],
        limits: ExtractorOperationLimits
    ) throws {
        guard manifestRevision == .v1 || manifestRevision == .v2 || manifestRevision == .v3 else {
            throw ExtractorValidationError.unsupportedManifestRevision(manifestRevision.rawValue)
        }
        guard displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              displayName.utf8.count <= 128 else {
            throw ExtractorValidationError.invalidManifest("package display name")
        }
        let registrations = registrations.sorted()
        guard registrations.isEmpty == false else { throw ExtractorValidationError.invalidManifest("manifest has no registrations") }
        if let duplicate = zip(registrations, registrations.dropFirst()).first(where: { $0.id == $1.id })?.0.id {
            throw ExtractorValidationError.duplicateRegistration(duplicate)
        }
        // Credential declarations are a revision-2 feature. Revision 1 must
        // reject them even in memory (a v1 manifest can never carry them in
        // JSON — the decoder rejects the key — this guards construction).
        if manifestRevision == .v1,
           registrations.contains(where: { $0.credentialRequirements.isEmpty == false }) {
            throw ExtractorValidationError.invalidManifest(
                "credential requirements require manifest revision 2")
        }
        // Sync declarations are a revision-3 feature, under the same
        // in-memory guard.
        if manifestRevision == .v1 || manifestRevision == .v2,
           registrations.contains(where: { $0.sync != nil }) {
            throw ExtractorValidationError.invalidManifest(
                "sync declarations require manifest revision 3")
        }
        // Manifest-wide uniqueness of requirement IDs makes package lineage +
        // requirement ID an unambiguous authorization identity (plan step 7).
        var seenRequirementIDs: Set<ExtractorCredentialRequirementID> = []
        for registration in registrations {
            for requirement in registration.credentialRequirements
            where seenRequirementIDs.insert(requirement.id).inserted == false {
                throw ExtractorValidationError.invalidManifest(
                    "duplicate credential requirement ID \(requirement.id.rawValue) across registrations")
            }
        }
        let files = files.sorted()
        guard files.isEmpty == false else { throw ExtractorValidationError.invalidManifest("manifest has no declared files") }
        if let duplicate = zip(files, files.dropFirst()).first(where: { $0.path == $1.path })?.0.path {
            throw ExtractorValidationError.duplicatePath(duplicate)
        }
        var collisionKeys: Set<String> = []
        for file in files where collisionKeys.insert(file.path.collisionKey).inserted == false {
            throw ExtractorValidationError.normalizedPathCollision(file.path)
        }
        guard files.contains(where: { $0.path == entryPoint }) else {
            throw ExtractorValidationError.invalidManifest("entry point is not declared")
        }
        if capabilities.contains(.modelDownload), capabilities.contains(.network) == false {
            throw ExtractorValidationError.capabilityRequiresNetwork(.modelDownload)
        }
        self.manifestRevision = manifestRevision
        self.packageID = packageID
        self.version = version
        self.displayName = displayName
        self.protocolRevision = protocolRevision
        self.entryPoint = entryPoint
        self.launch = launch
        self.registrations = registrations
        self.capabilities = capabilities
        self.files = files
        self.limits = limits
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the revision FIRST so registration elements are decoded
        // with the matching key policy (v1 rejects the credential key; v2
        // accepts it).
        let revision = try container.decode(
            ExtractorManifestRevision.self, forKey: .manifestRevision)
        var nested = try container.nestedUnkeyedContainer(forKey: .registrations)
        var registrations: [ExtractorRegistration] = []
        registrations.reserveCapacity(nested.count ?? 0)
        while nested.isAtEnd == false {
            registrations.append(try ExtractorRegistration(
                from: nested.superDecoder(), manifestRevision: revision))
        }
        let capabilities = try container.decode([ExtractorCapability].self, forKey: .capabilities)
        guard Set(capabilities).count == capabilities.count else {
            throw ExtractorValidationError.invalidManifest("manifest contains duplicate capabilities")
        }
        try self.init(
            manifestRevision: revision,
            packageID: container.decode(ExtractorPackageID.self, forKey: .packageID),
            version: container.decode(ExtractorPackageVersion.self, forKey: .version),
            displayName: container.decode(String.self, forKey: .displayName),
            protocolRevision: container.decode(ExtractorProtocolRevision.self, forKey: .protocolRevision),
            entryPoint: container.decode(ExtractorRelativePath.self, forKey: .entryPoint),
            launch: container.decode(ExtractorLaunch.self, forKey: .launch),
            registrations: registrations,
            capabilities: Set(capabilities),
            files: container.decode([ExtractorPackageFile].self, forKey: .files),
            limits: container.decode(ExtractorOperationLimits.self, forKey: .limits))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifestRevision, forKey: .manifestRevision)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(version, forKey: .version)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(protocolRevision, forKey: .protocolRevision)
        try container.encode(entryPoint, forKey: .entryPoint)
        try container.encode(launch, forKey: .launch)
        try container.encode(registrations, forKey: .registrations)
        try container.encode(capabilities.sorted { $0.rawValue < $1.rawValue }, forKey: .capabilities)
        try container.encode(files, forKey: .files)
        try container.encode(limits, forKey: .limits)
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CanonicalExtractorManifestV1(self))
    }

    /// Digest namespace revision 1. Modes and installation paths are not inputs.
    public func packageDigest() throws -> ExtractorPackageDigest {
        let manifestObject = try JSONSerialization.jsonObject(with: canonicalJSON(), options: [.fragmentsAllowed])
        let envelope: [String: Any] = [
            "format": "selfdrivingwiki.extractor-package-digest",
            "revision": manifestRevision.rawValue,
            "manifest": manifestObject,
            "files": files.map { ["path": $0.path.rawValue, "sha256": $0.digest.hex] },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes])
        return ExtractorSHA256.digest(data)
    }
}

private struct AnyExtractorCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

func rejectUnknownKeys<Key>(from decoder: any Decoder, allowed: Key.Type) throws
where Key: CodingKey & CaseIterable, Key.AllCases: Sequence {
    let known = Set(Key.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: AnyExtractorCodingKey.self)
    guard let unknown = container.allKeys.first(where: { known.contains($0.stringValue) == false }) else { return }
    throw ExtractorValidationError.invalidManifest("unknown field \(unknown.stringValue)")
}

private struct CanonicalExtractorManifestV1: Encodable {
    let manifestRevision: ExtractorManifestRevision
    let packageID: ExtractorPackageID
    let version: ExtractorPackageVersion
    let displayName: String
    let protocolRevision: ExtractorProtocolRevision
    let entryPoint: ExtractorRelativePath
    let launch: ExtractorLaunch
    let registrations: [ExtractorRegistration]
    let capabilities: [ExtractorCapability]
    let files: [ExtractorRelativePath]
    let limits: ExtractorOperationLimits

    init(_ manifest: ExtractorManifest) {
        manifestRevision = manifest.manifestRevision
        packageID = manifest.packageID
        version = manifest.version
        displayName = manifest.displayName
        protocolRevision = manifest.protocolRevision
        entryPoint = manifest.entryPoint
        launch = manifest.launch
        registrations = manifest.registrations
        capabilities = manifest.capabilities.sorted { $0.rawValue < $1.rawValue }
        files = manifest.files.map(\.path)
        limits = manifest.limits
    }
}
