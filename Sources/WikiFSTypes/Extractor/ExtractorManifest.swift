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
    private enum V2CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, kinds, mimeTypes, filenameExtensions, credentialRequirements
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

    public init(
        id: ExtractorRegistrationID,
        displayName: String,
        kinds: Set<ExtractorKind>,
        mimeTypes: Set<ExtractorMIMEType>,
        filenameExtensions: Set<ExtractorFileExtension> = [],
        credentialRequirements: [ExtractorCredentialRequirement] = []
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
        self.id = id
        self.displayName = displayName
        self.kinds = kinds
        self.mimeTypes = mimeTypes
        self.filenameExtensions = filenameExtensions
        self.credentialRequirements = credentialRequirements.sorted()
    }

    /// The v1 decoder: strict, no credential key.
    public init(from decoder: any Decoder) throws {
        try self.init(
            from: decoder, manifestRevision: .v1)
    }

    /// Revision-aware decoding. Revision 1 rejects the
    /// `credentialRequirements` key outright (unknown-field policy);
    /// revision 2 accepts it and validates every declaration.
    public init(from decoder: any Decoder, manifestRevision: ExtractorManifestRevision) throws {
        if manifestRevision == .v2 {
            try rejectUnknownKeys(from: decoder, allowed: V2CodingKeys.self)
        } else {
            try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        }
        let container = try decoder.container(keyedBy: V2CodingKeys.self)
        let kinds = try container.decode([ExtractorKind].self, forKey: .kinds)
        let mimeTypes = try container.decode([ExtractorMIMEType].self, forKey: .mimeTypes)
        let filenameExtensions = try container.decodeIfPresent([ExtractorFileExtension].self, forKey: .filenameExtensions) ?? []
        guard Set(kinds).count == kinds.count,
              Set(mimeTypes).count == mimeTypes.count,
              Set(filenameExtensions).count == filenameExtensions.count else {
            throw ExtractorValidationError.invalidManifest("registration contains duplicate values")
        }
        let requirements: [ExtractorCredentialRequirement]
        if manifestRevision == .v2 {
            requirements = try container.decodeIfPresent(
                [ExtractorCredentialRequirement].self, forKey: .credentialRequirements) ?? []
        } else {
            requirements = []
        }
        try self.init(
            id: container.decode(ExtractorRegistrationID.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            kinds: Set(kinds),
            mimeTypes: Set(mimeTypes),
            filenameExtensions: Set(filenameExtensions),
            credentialRequirements: requirements)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: V2CodingKeys.self)
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
        guard manifestRevision == .v1 || manifestRevision == .v2 else {
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
