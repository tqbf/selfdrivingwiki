import Foundation

// pattern: Functional Core

public enum RendererManifestRevision {
    public static let legacy = 1
    /// Revision 2 added package-declared Markdown fence claims.
    public static let fenceClaims = 2
    /// Revision 3 added per-claim fence-syntax validation declarations.
    public static let fenceValidation = 3
    /// Revision 4 added explicit, typed host-navigation authority.
    public static let hostNavigation = 4
    /// Revision 5 added a closed, Web-package-only `assetRead` capability and
    /// declaration: byte reads of exact session-pinned wiki source versions
    /// through the renderer-neutral authorized asset reader.
    public static let assetRead = 5
    public static let current = assetRead
    public static let supported: ClosedRange<Int> = legacy ... current
}

/// The normalized package document. It contains metadata only and no package
/// installation or filesystem behavior.
public struct RendererManifest: Codable, Hashable, Sendable {
    public let revision: Int
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion
    public let descriptors: [RendererDescriptor]
    public let assets: [RendererAsset]

    public init(revision: Int, packageID: RendererPackageID, version: RendererPackageVersion, descriptors: [RendererDescriptor], assets: [RendererAsset]) throws {
        guard RendererManifestRevision.supported.contains(revision) else {
            throw RendererValidationError.unsupportedManifestRevision(revision)
        }
        let sortedDescriptors = descriptors.sorted { $0.reference.registrationID < $1.reference.registrationID }
        guard sortedDescriptors.isEmpty == false else {
            throw RendererValidationError.emptyManifest
        }
        guard Set(sortedDescriptors.map(\.reference.registrationID)).count == sortedDescriptors.count else {
            guard let duplicate = zip(sortedDescriptors, sortedDescriptors.dropFirst()).first(where: {
                $0.reference.registrationID == $1.reference.registrationID
            })?.0.reference.registrationID else { throw RendererValidationError.manifestIdentityMismatch }
            throw RendererValidationError.duplicateRegistration(duplicate)
        }
        let sortedAssets = assets.sorted()
        guard Set(sortedAssets.map(\.path)).count == sortedAssets.count else {
            guard let duplicate = zip(sortedAssets, sortedAssets.dropFirst()).first(where: { $0.path == $1.path })?.0.path else {
                throw RendererValidationError.manifestIdentityMismatch
            }
            throw RendererValidationError.duplicatePath(duplicate)
        }
        for descriptor in sortedDescriptors {
            if revision >= RendererManifestRevision.fenceClaims,
               descriptor.hasExplicitEmbeddingRoles == false {
                throw RendererValidationError.missingEmbeddingRoles
            }
            // Fence-syntax validation declarations are revision-3-only: the
            // same fail-closed posture, evaluated before the claims gate so a
            // pre-revision-3 manifest cannot smuggle a validation contract in
            // via its claims.
            if revision < RendererManifestRevision.fenceValidation, descriptor.hasFenceValidation {
                throw RendererValidationError.fenceValidationRequiresCurrentRevision
            }
            if revision < RendererManifestRevision.hostNavigation,
               descriptor.capabilities.contains(.hostNavigation) || descriptor.hasHostNavigationDeclaration {
                throw RendererValidationError.hostNavigationRequiresRevision4
            }
            // Asset-read authority is revision-5-and-later only: a
            // pre-revision-5 manifest that declares the capability or its
            // declaration fails closed, matching the navigation gate posture.
            if revision < RendererManifestRevision.assetRead,
               descriptor.capabilities.contains(.assetRead) || descriptor.hasAssetReadDeclaration {
                throw RendererValidationError.assetReadRequiresRevision5
            }
            // Fence authority is revision-2-and-later only: a revision-1
            // manifest that declares claims fails closed rather than silently
            // dropping them (same posture as the embedding-roles requirement).
            if revision < RendererManifestRevision.fenceClaims, descriptor.hasFenceClaims {
                throw RendererValidationError.fenceClaimsRequireCurrentRevision
            }
            guard descriptor.reference.packageID == packageID, descriptor.reference.version == version else {
                throw RendererValidationError.manifestIdentityMismatch
            }
            if case let .builtIn(identifier) = descriptor.implementation {
                throw RendererValidationError.packageManifestContainsBuiltIn(identifier)
            }
            let packageAssets = Set(sortedAssets)
            for asset in descriptor.approvedAssets where packageAssets.contains(asset) == false {
                throw RendererValidationError.manifestAssetNotApproved(asset.path)
            }
        }
        // One alias, one claimant, per manifest: two descriptors in the same
        // package cannot both answer the same fence.
        var claimedAliases = Set<RendererFenceAlias>()
        for descriptor in sortedDescriptors {
            for claim in descriptor.fenceClaims {
                guard claimedAliases.insert(claim.alias).inserted else {
                    throw RendererValidationError.duplicateFenceClaim(claim.alias)
                }
            }
        }
        self.revision = revision
        self.packageID = packageID
        self.version = version
        self.descriptors = sortedDescriptors
        self.assets = sortedAssets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(Int.self, forKey: .revision),
            packageID: container.decode(RendererPackageID.self, forKey: .packageID),
            version: container.decode(RendererPackageVersion.self, forKey: .version),
            descriptors: container.decode([RendererDescriptor].self, forKey: .descriptors),
            assets: container.decode([RendererAsset].self, forKey: .assets)
        )
    }

    /// JSON with Foundation's sorted-key encoder. This uses an explicit
    /// canonical DTO because synthesized Codable does not impose an order on
    /// `Set` members nested inside a descriptor.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch revision {
        case RendererManifestRevision.legacy:
            return try encoder.encode(CanonicalManifestV1(self))
        case RendererManifestRevision.fenceClaims:
            // Byte-for-byte the revision-2 path: reviewed revision-2 package
            // hashes are stability contracts and must not move.
            return try encoder.encode(CanonicalManifestV2(self))
        case RendererManifestRevision.fenceValidation:
            // Byte-for-byte the revision-3 path: reviewed revision-3 package
            // hashes are stability contracts and must not move.
            return try encoder.encode(CanonicalManifestV3(self))
        case RendererManifestRevision.hostNavigation:
            return try encoder.encode(CanonicalManifestV4(self))
        case RendererManifestRevision.assetRead:
            return try encoder.encode(CanonicalManifestV5(self))
        default:
            throw RendererValidationError.unsupportedManifestRevision(revision)
        }
    }

    /// SHA-256 of a versioned envelope that embeds normalized manifest JSON and
    /// every asset's canonical lowercase digest. The format label prevents a
    /// future envelope revision from sharing this hash namespace.
    public func packageHash() throws -> RendererSHA256Digest {
        let manifestObject = try JSONSerialization.jsonObject(with: canonicalJSON(), options: [.fragmentsAllowed])
        let envelope: [String: Any] = [
            "format": "selfdrivingwiki.renderer-package-hash",
            "revision": revision,
            "manifest": manifestObject,
            "assets": assets.map { ["path": $0.path.rawValue, "sha256": $0.digest.hex] },
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return RendererSHA256.digest(data)
    }
}

private struct CanonicalManifestV1: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptorV1]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptorV1.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalManifestV2: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptorV2]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptorV2.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalManifestV3: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptorV3]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptorV3.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalManifestV4: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptorV4]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptorV4.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalManifestV5: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptorV5]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptorV5.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalRendererDescriptorV1: Encodable {
    let reference: RendererReference
    let displayName: String
    let implementation: RendererImplementation
    let matchers: [RendererMatcher]
    let presentations: [RendererPresentation]
    let approvedAssets: [RendererAsset]
    let capabilities: [RendererCapability]
    let sizeLimits: RendererSizeLimits
    let linkPolicy: RendererLinkPolicy
    let accessibility: RendererAccessibility
    let compatibility: RendererCompatibility
    let priority: Int

    init(_ descriptor: RendererDescriptor) throws {
        reference = descriptor.reference
        displayName = descriptor.displayName
        implementation = descriptor.implementation
        matchers = try Self.sortedCodable(descriptor.matchers)
        presentations = descriptor.presentations.sorted { $0.rawValue < $1.rawValue }
        approvedAssets = descriptor.approvedAssets.sorted()
        capabilities = descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }
        sizeLimits = descriptor.sizeLimits
        linkPolicy = descriptor.linkPolicy
        accessibility = descriptor.accessibility
        compatibility = descriptor.compatibility
        priority = descriptor.priority
    }

    private static func sortedCodable<T: Encodable>(_ values: [T]) throws -> [T] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try values.map { (value: $0, key: try encoder.encode($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}

private struct CanonicalRendererDescriptorV3: Encodable {
    let reference: RendererReference
    let displayName: String
    let implementation: RendererImplementation
    let matchers: [RendererMatcher]
    let presentations: [RendererPresentation]
    let supportedEmbeddingRoles: [RendererEmbeddingRole]
    /// Emitted only when claims exist so every claim-less manifest keeps its
    /// reviewed canonical bytes (and package hash) unchanged.
    let fenceClaims: [RendererFenceClaim]?
    let approvedAssets: [RendererAsset]
    let capabilities: [RendererCapability]
    let sizeLimits: RendererSizeLimits
    let linkPolicy: RendererLinkPolicy
    let accessibility: RendererAccessibility
    let compatibility: RendererCompatibility
    let priority: Int

    init(_ descriptor: RendererDescriptor) throws {
        reference = descriptor.reference
        displayName = descriptor.displayName
        implementation = descriptor.implementation
        matchers = try Self.sortedCodable(descriptor.matchers)
        presentations = descriptor.presentations.sorted { $0.rawValue < $1.rawValue }
        supportedEmbeddingRoles = descriptor.supportedEmbeddingRoles.sorted { $0.rawValue < $1.rawValue }
        fenceClaims = descriptor.hasFenceClaims
            ? descriptor.fenceClaims.sorted { $0.alias < $1.alias }
            : nil
        approvedAssets = descriptor.approvedAssets.sorted()
        capabilities = descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }
        sizeLimits = descriptor.sizeLimits
        linkPolicy = descriptor.linkPolicy
        accessibility = descriptor.accessibility
        compatibility = descriptor.compatibility
        priority = descriptor.priority
    }

    private static func sortedCodable<T: Encodable>(_ values: [T]) throws -> [T] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try values.map { (value: $0, key: try encoder.encode($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}

private struct CanonicalHostNavigation: Encodable {
    let allowedTargetKinds: [RendererHostNavigationTargetKind]

    init(_ declaration: RendererHostNavigationDeclaration) {
        allowedTargetKinds = declaration.allowedTargetKinds.sorted { $0.rawValue < $1.rawValue }
    }
}

private struct CanonicalRendererDescriptorV4: Encodable {
    private struct CanonicalHostNavigation: Encodable {
        let allowedTargetKinds: [RendererHostNavigationTargetKind]

        init(_ declaration: RendererHostNavigationDeclaration) {
            allowedTargetKinds = declaration.allowedTargetKinds.sorted { $0.rawValue < $1.rawValue }
        }
    }
    let reference: RendererReference
    let displayName: String
    let implementation: RendererImplementation
    let matchers: [RendererMatcher]
    let presentations: [RendererPresentation]
    let supportedEmbeddingRoles: [RendererEmbeddingRole]
    let fenceClaims: [RendererFenceClaim]?
    let approvedAssets: [RendererAsset]
    let capabilities: [RendererCapability]
    private let hostNavigation: CanonicalHostNavigation?
    let sizeLimits: RendererSizeLimits
    let linkPolicy: RendererLinkPolicy
    let accessibility: RendererAccessibility
    let compatibility: RendererCompatibility
    let priority: Int

    init(_ descriptor: RendererDescriptor) throws {
        reference = descriptor.reference
        displayName = descriptor.displayName
        implementation = descriptor.implementation
        matchers = try Self.sortedCodable(descriptor.matchers)
        presentations = descriptor.presentations.sorted { $0.rawValue < $1.rawValue }
        supportedEmbeddingRoles = descriptor.supportedEmbeddingRoles.sorted { $0.rawValue < $1.rawValue }
        fenceClaims = descriptor.hasFenceClaims
            ? descriptor.fenceClaims.sorted { $0.alias < $1.alias }
            : nil
        approvedAssets = descriptor.approvedAssets.sorted()
        capabilities = descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }
        hostNavigation = descriptor.hostNavigation.map(CanonicalHostNavigation.init)
        sizeLimits = descriptor.sizeLimits
        linkPolicy = descriptor.linkPolicy
        accessibility = descriptor.accessibility
        compatibility = descriptor.compatibility
        priority = descriptor.priority
    }

    private static func sortedCodable<T: Encodable>(_ values: [T]) throws -> [T] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try values.map { (value: $0, key: try encoder.encode($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}

private struct CanonicalRendererDescriptorV2: Encodable {
    let reference: RendererReference
    let displayName: String
    let implementation: RendererImplementation
    let matchers: [RendererMatcher]
    let presentations: [RendererPresentation]
    let supportedEmbeddingRoles: [RendererEmbeddingRole]
    /// Emitted only when claims exist so every claim-less manifest keeps its
    /// reviewed canonical bytes (and package hash) unchanged.
    let fenceClaims: [RendererFenceClaim]?
    let approvedAssets: [RendererAsset]
    let capabilities: [RendererCapability]
    let sizeLimits: RendererSizeLimits
    let linkPolicy: RendererLinkPolicy
    let accessibility: RendererAccessibility
    let compatibility: RendererCompatibility
    let priority: Int

    init(_ descriptor: RendererDescriptor) throws {
        reference = descriptor.reference
        displayName = descriptor.displayName
        implementation = descriptor.implementation
        matchers = try Self.sortedCodable(descriptor.matchers)
        presentations = descriptor.presentations.sorted { $0.rawValue < $1.rawValue }
        supportedEmbeddingRoles = descriptor.supportedEmbeddingRoles.sorted { $0.rawValue < $1.rawValue }
        fenceClaims = descriptor.hasFenceClaims
            ? descriptor.fenceClaims.sorted { $0.alias < $1.alias }
            : nil
        approvedAssets = descriptor.approvedAssets.sorted()
        capabilities = descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }
        sizeLimits = descriptor.sizeLimits
        linkPolicy = descriptor.linkPolicy
        accessibility = descriptor.accessibility
        compatibility = descriptor.compatibility
        priority = descriptor.priority
    }

    private static func sortedCodable<T: Encodable>(_ values: [T]) throws -> [T] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try values.map { (value: $0, key: try encoder.encode($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}

private struct CanonicalRendererDescriptorV5: Encodable {
    private struct CanonicalAssetRead: Encodable {
        let allowedRoles: [RendererAssetRole]
        let allowedMIMETypes: [RendererMIMEType]
        let maximumExtractedReferenceCount: Int
        let maximumExtractorInputBytes: Int
        let maximumExtractorOutputBytes: Int
        let maximumExtractorExecutionSeconds: Int
        let maximumBytesPerAsset: Int
        let maximumAggregateSessionBytes: Int
        let extractorAsset: RendererRelativePath
        let extractorEntryFunction: String

        init(_ declaration: RendererAssetReadDeclaration) {
            allowedRoles = declaration.allowedRoles.sorted { $0.rawValue < $1.rawValue }
            allowedMIMETypes = declaration.allowedMIMETypes.sorted()
            maximumExtractedReferenceCount = declaration.maximumExtractedReferenceCount
            maximumExtractorInputBytes = declaration.maximumExtractorInputBytes
            maximumExtractorOutputBytes = declaration.maximumExtractorOutputBytes
            maximumExtractorExecutionSeconds = declaration.maximumExtractorExecutionSeconds
            maximumBytesPerAsset = declaration.maximumBytesPerAsset
            maximumAggregateSessionBytes = declaration.maximumAggregateSessionBytes
            extractorAsset = declaration.extractorAsset
            extractorEntryFunction = declaration.extractorEntryFunction
        }
    }

    let reference: RendererReference
    let displayName: String
    let implementation: RendererImplementation
    let matchers: [RendererMatcher]
    let presentations: [RendererPresentation]
    let supportedEmbeddingRoles: [RendererEmbeddingRole]
    let fenceClaims: [RendererFenceClaim]?
    let approvedAssets: [RendererAsset]
    let capabilities: [RendererCapability]
    private let hostNavigation: CanonicalHostNavigation?
    private let assetRead: CanonicalAssetRead?
    let sizeLimits: RendererSizeLimits
    let linkPolicy: RendererLinkPolicy
    let accessibility: RendererAccessibility
    let compatibility: RendererCompatibility
    let priority: Int

    init(_ descriptor: RendererDescriptor) throws {
        reference = descriptor.reference
        displayName = descriptor.displayName
        implementation = descriptor.implementation
        matchers = try Self.sortedCodable(descriptor.matchers)
        presentations = descriptor.presentations.sorted { $0.rawValue < $1.rawValue }
        supportedEmbeddingRoles = descriptor.supportedEmbeddingRoles.sorted { $0.rawValue < $1.rawValue }
        fenceClaims = descriptor.hasFenceClaims
            ? descriptor.fenceClaims.sorted { $0.alias < $1.alias }
            : nil
        approvedAssets = descriptor.approvedAssets.sorted()
        capabilities = descriptor.capabilities.sorted { $0.rawValue < $1.rawValue }
        hostNavigation = descriptor.hostNavigation.map(CanonicalHostNavigation.init)
        assetRead = descriptor.assetRead.map(CanonicalAssetRead.init)
        sizeLimits = descriptor.sizeLimits
        linkPolicy = descriptor.linkPolicy
        accessibility = descriptor.accessibility
        compatibility = descriptor.compatibility
        priority = descriptor.priority
    }

    private static func sortedCodable<T: Encodable>(_ values: [T]) throws -> [T] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try values.map { (value: $0, key: try encoder.encode($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}
