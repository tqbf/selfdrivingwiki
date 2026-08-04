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
        self.approvedAssets = assets
        self.capabilities = capabilities
        self.sizeLimits = sizeLimits
        self.linkPolicy = linkPolicy
        self.accessibility = accessibility
        self.compatibility = compatibility
        self.priority = priority
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: container.decode(RendererReference.self, forKey: .reference),
            displayName: container.decode(String.self, forKey: .displayName),
            implementation: container.decode(RendererImplementation.self, forKey: .implementation),
            matchers: container.decode([RendererMatcher].self, forKey: .matchers),
            presentations: container.decode(Set<RendererPresentation>.self, forKey: .presentations),
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
        if matchers.contains(where: { $0.isExtensionFallback == false && $0.matches(input) }) {
            return .strong
        }
        if matchers.contains(where: { $0.isExtensionFallback && $0.matches(input) }) {
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
