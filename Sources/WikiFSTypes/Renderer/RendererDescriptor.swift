import Foundation

// pattern: Functional Core

public struct RendererWebEntryPoint: Codable, Hashable, Sendable {
    public let path: RendererRelativePath

    public init(path: RendererRelativePath) {
        self.path = path
    }
}

public enum RendererImplementation: Codable, Hashable, Sendable {
    case builtIn(BuiltInRendererID)
    case webPackage(RendererWebEntryPoint)
}

public struct RendererAsset: Codable, Hashable, Sendable, Comparable {
    public let path: RendererRelativePath
    public let digest: RendererSHA256Digest

    public init(path: RendererRelativePath, digest: RendererSHA256Digest) {
        self.path = path
        self.digest = digest
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.path < rhs.path }
}

/// One immutable renderer registration. Its reference is also its stable tie-break key.
public struct RendererDescriptor: Codable, Hashable, Sendable {
    public let reference: RendererReference
    public let displayName: String
    public let implementation: RendererImplementation
    public let matchers: [RendererMatcher]
    public let presentations: Set<RendererPresentation>
    public let supportedEmbeddingRoles: Set<RendererEmbeddingRole>
    /// True only when the role set was explicitly present at the decode or
    /// construction boundary. Revision-1 manifests may project the narrow
    /// legacy disclosure role without changing their canonical bytes.
    public let hasExplicitEmbeddingRoles: Bool
    /// Aliases this renderer claims for Markdown rich fences. Claims are
    /// registry data: the trusted built-in table declares its own, and renderer
    /// package manifests may declare them at revision 2 (a revision-1 manifest
    /// carrying claims fails closed in ``RendererManifest``).
    public let fenceClaims: [RendererFenceClaim]
    /// True only when at least one claim exists. Mirrors
    /// ``hasExplicitEmbeddingRoles`` so canonical emission omits the key for
    /// claim-less manifests and their canonical bytes stay stable.
    public var hasFenceClaims: Bool { fenceClaims.isEmpty == false }
    /// True when any claim declares a fence-syntax validation contract. The
    /// manifest layer uses this for the revision-3 fail-closed gate.
    public var hasFenceValidation: Bool { fenceClaims.contains { $0.hasValidation } }
    public let approvedAssets: [RendererAsset]
    public let capabilities: Set<RendererCapability>
    public let sizeLimits: RendererSizeLimits
    public let linkPolicy: RendererLinkPolicy
    public let accessibility: RendererAccessibility
    public let compatibility: RendererCompatibility
    public let priority: Int

    public init(
        reference: RendererReference,
        displayName: String,
        implementation: RendererImplementation,
        matchers: [RendererMatcher],
        presentations: Set<RendererPresentation>,
        supportedEmbeddingRoles: Set<RendererEmbeddingRole> = [.disclosureRow],
        hasExplicitEmbeddingRoles: Bool = false,
        fenceClaims: [RendererFenceClaim] = [],
        approvedAssets: [RendererAsset],
        capabilities: Set<RendererCapability>,
        sizeLimits: RendererSizeLimits,
        linkPolicy: RendererLinkPolicy,
        accessibility: RendererAccessibility,
        compatibility: RendererCompatibility,
        priority: Int
    ) throws {
        guard displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              matchers.isEmpty == false,
              presentations.isEmpty == false else {
            throw RendererValidationError.invalidPresentation
        }
        guard supportedEmbeddingRoles.isEmpty == false else {
            throw RendererValidationError.missingEmbeddingRoles
        }
        let claims = fenceClaims.sorted { $0.alias < $1.alias }
        var seenClaims = Set<RendererFenceAlias>()
        for claim in claims {
            guard seenClaims.insert(claim.alias).inserted else {
                throw RendererValidationError.duplicateFenceClaim(claim.alias)
            }
            guard supportedEmbeddingRoles.contains(.disclosureRow) else {
                throw RendererValidationError.fenceClaimMissingDisclosureRole(claim.alias)
            }
        }
        guard capabilities.contains(.inputRead) else {
            throw RendererValidationError.missingRequiredCapability(.inputRead)
        }
        for capability in capabilities where capability != .inputRead && capability != .externalLink {
            throw RendererValidationError.forbiddenCapability(capability)
        }
        if linkPolicy == .userActivatedExternal && capabilities.contains(.externalLink) == false {
            throw RendererValidationError.missingRequiredCapability(.externalLink)
        }
        if linkPolicy == .none && capabilities.contains(.externalLink) {
            throw RendererValidationError.forbiddenCapability(.externalLink)
        }
        let assets = approvedAssets.sorted()
        guard Set(assets.map(\.path)).count == assets.count else {
            guard let duplicate = RendererDescriptor.firstDuplicatePath(in: assets) else {
                throw RendererValidationError.invalidRelativePath("duplicate asset validation")
            }
            throw RendererValidationError.duplicateAsset(duplicate)
        }
        // A declared fence-validation contract must point at assets this
        // descriptor approves: the engine and wrapper are renderer inputs,
        // so they live under the same approval discipline as every other
        // package byte the descriptor consumes.
        let approvedPaths = Set(assets.map(\.path))
        for claim in claims {
            guard let validation = claim.validation else { continue }
            for path in [validation.engineAssetPath, validation.wrapperAssetPath] where approvedPaths.contains(path) == false {
                throw RendererValidationError.fenceValidationAssetNotApproved(path)
            }
        }
        switch implementation {
        case .builtIn:
            guard presentations == [.native], assets.isEmpty else { throw RendererValidationError.invalidPresentation }
        case let .webPackage(entryPoint):
            guard presentations == [.web], assets.contains(where: { $0.path == entryPoint.path }) else {
                throw RendererValidationError.invalidPresentation
            }
        }
        self.reference = reference
        self.displayName = displayName
        self.implementation = implementation
        self.matchers = matchers
        self.presentations = presentations
        self.supportedEmbeddingRoles = supportedEmbeddingRoles
        self.hasExplicitEmbeddingRoles = hasExplicitEmbeddingRoles
        self.fenceClaims = claims
        self.approvedAssets = assets
        self.capabilities = capabilities
        self.sizeLimits = sizeLimits
        self.linkPolicy = linkPolicy
        self.accessibility = accessibility
        self.compatibility = compatibility
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case reference
        case displayName
        case implementation
        case matchers
        case presentations
        case supportedEmbeddingRoles
        case fenceClaims
        case approvedAssets
        case capabilities
        case sizeLimits
        case linkPolicy
        case accessibility
        case compatibility
        case priority
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reference, forKey: .reference)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(implementation, forKey: .implementation)
        try container.encode(matchers, forKey: .matchers)
        try container.encode(presentations, forKey: .presentations)
        if hasExplicitEmbeddingRoles {
            try container.encode(supportedEmbeddingRoles, forKey: .supportedEmbeddingRoles)
        }
        // Claim-less manifests must not gain a key: canonical bytes and the
        // package hash are stability contracts for already-reviewed packages.
        if hasFenceClaims {
            try container.encode(fenceClaims, forKey: .fenceClaims)
        }
        try container.encode(approvedAssets, forKey: .approvedAssets)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(sizeLimits, forKey: .sizeLimits)
        try container.encode(linkPolicy, forKey: .linkPolicy)
        try container.encode(accessibility, forKey: .accessibility)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encode(priority, forKey: .priority)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitRoles = try container.decodeIfPresent(
            Set<RendererEmbeddingRole>.self,
            forKey: .supportedEmbeddingRoles)
        try self.init(
            reference: container.decode(RendererReference.self, forKey: .reference),
            displayName: container.decode(String.self, forKey: .displayName),
            implementation: container.decode(RendererImplementation.self, forKey: .implementation),
            matchers: container.decode([RendererMatcher].self, forKey: .matchers),
            presentations: container.decode(Set<RendererPresentation>.self, forKey: .presentations),
            supportedEmbeddingRoles: explicitRoles ?? [.disclosureRow],
            hasExplicitEmbeddingRoles: explicitRoles != nil,
            fenceClaims: try container.decodeIfPresent([RendererFenceClaim].self, forKey: .fenceClaims) ?? [],
            approvedAssets: container.decode([RendererAsset].self, forKey: .approvedAssets),
            capabilities: container.decode(Set<RendererCapability>.self, forKey: .capabilities),
            sizeLimits: container.decode(RendererSizeLimits.self, forKey: .sizeLimits),
            linkPolicy: container.decode(RendererLinkPolicy.self, forKey: .linkPolicy),
            accessibility: container.decode(RendererAccessibility.self, forKey: .accessibility),
            compatibility: container.decode(RendererCompatibility.self, forKey: .compatibility),
            priority: container.decode(Int.self, forKey: .priority)
        )
    }

    public var logicalReference: LogicalRendererReference {
        .init(packageID: reference.packageID, registrationID: reference.registrationID)
    }

    /// Match MIME, signature, and artifact matchers first. Extensions are used only
    /// when no stronger matcher from any descriptor succeeds.
    public func matchTier(for input: RendererMatchInput) -> RendererMatchTier? {
        let requiredArtifactMatchers = matchers.filter(\.requiresArtifactValidation)
        guard requiredArtifactMatchers.allSatisfy({ $0.matches(input) }) else {
            return nil
        }
        let routingMatchers = matchers.filter { $0.requiresArtifactValidation == false }
        if routingMatchers.contains(where: { $0.isExtensionFallback == false && $0.matches(input) }) {
            return .strong
        }
        if routingMatchers.contains(where: { $0.isExtensionFallback && $0.matches(input) }) {
            return .extensionFallback
        }
        return nil
    }

    /// Higher priority wins. Equal priorities sort by package ID, then package
    /// version, then registration ID, all ascending. This key never uses install order.
    public var stableTieBreakKey: RendererStableTieBreakKey {
        .init(priority: priority, reference: reference)
    }

    private static func firstDuplicatePath(in assets: [RendererAsset]) -> RendererRelativePath? {
        zip(assets, assets.dropFirst()).first(where: { $0.path == $1.path })?.0.path
    }
}

public enum RendererMatchTier: Int, Comparable, Sendable {
    case extensionFallback
    case strong

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RendererStableTieBreakKey: Comparable, Hashable, Sendable {
    public let priority: Int
    public let reference: RendererReference

    public init(priority: Int, reference: RendererReference) {
        self.priority = priority
        self.reference = reference
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.reference < rhs.reference
    }
}
