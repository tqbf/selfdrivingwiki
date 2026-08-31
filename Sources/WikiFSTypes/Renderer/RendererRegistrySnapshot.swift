import Foundation

// pattern: Functional Core

/// One alias resolved to its claiming descriptor at a registry moment. The
/// reader's embed plan derives everything it needs from this record: the
/// renderer reference and display name come from the declaring descriptor, the
/// inline MIME type from the claim itself.
public struct RendererFenceClaimAssignment: Hashable, Sendable {
    public let alias: RendererFenceAlias
    public let reference: RendererReference
    public let inlineMIMEType: RendererMIMEType
    public let displayName: String

    public init(
        alias: RendererFenceAlias,
        reference: RendererReference,
        inlineMIMEType: RendererMIMEType,
        displayName: String
    ) {
        self.alias = alias
        self.reference = reference
        self.inlineMIMEType = inlineMIMEType
        self.displayName = displayName
    }
}

/// Deterministic alias → claim resolution shared by the registry snapshot and
/// the render-context build. When two descriptors claim the same alias the
/// existing ``RendererDescriptor/stableTieBreakKey`` decides: higher priority
/// wins, then package ID, version, and registration ID ascending. Install-time
/// validation rejects most collisions before they can reach this tie-break;
/// it remains the deterministic answer for everything else (and for tests).
public enum RendererFenceClaimResolver {
    public static func resolve(
        builtInDescriptors: [RendererDescriptor],
        enabledInstalledDescriptors: [RendererDescriptor] = []
    ) -> [RendererFenceAlias: RendererFenceClaimAssignment] {
        let ordered = (builtInDescriptors + enabledInstalledDescriptors)
            .sorted { $0.stableTieBreakKey < $1.stableTieBreakKey }
        var claims: [RendererFenceAlias: RendererFenceClaimAssignment] = [:]
        for descriptor in ordered {
            for claim in descriptor.fenceClaims where claims[claim.alias] == nil {
                claims[claim.alias] = RendererFenceClaimAssignment(
                    alias: claim.alias,
                    reference: descriptor.reference,
                    inlineMIMEType: claim.inlineMIMEType,
                    displayName: descriptor.displayName)
            }
        }
        return claims
    }
}

/// Immutable registry contents for one renderer-resolution moment.
///
/// The snapshot combines host-owned built-ins with enabled installed package
/// descriptors in one deterministic initializer. Source remains outside this
/// registry: callers ask for renderer matches and keep the host Source view as
/// the permanent fallback when no descriptor matches or resolution fails.
public struct RendererRegistrySnapshot: Hashable, Sendable {
    public let hostProtocolRevision: Int
    public let descriptors: [RendererDescriptor]
    /// Aliases claimed by the combined built-in + enabled installed descriptors.
    /// Superseded or safe-mode-suppressed packages drop out with their claims
    /// because they never enter `descriptors`.
    public let fenceClaims: [RendererFenceAlias: RendererFenceClaimAssignment]

    public init(
        builtInDescriptors: [RendererDescriptor],
        enabledInstalledDescriptors: [RendererDescriptor] = [],
        hostProtocolRevision: Int = RendererRegistrySnapshotDefaults.hostProtocolRevision
    ) throws {
        guard hostProtocolRevision > 0 else {
            throw RendererValidationError.invalidCompatibilityRange
        }
        try Self.validateChannelInvariants(
            builtInDescriptors: builtInDescriptors,
            enabledInstalledDescriptors: enabledInstalledDescriptors)
        let combined = builtInDescriptors + enabledInstalledDescriptors
        try Self.validateUniqueReferences(combined)
        self.hostProtocolRevision = hostProtocolRevision
        self.descriptors = combined.sorted { $0.stableTieBreakKey < $1.stableTieBreakKey }
        self.fenceClaims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: builtInDescriptors,
            enabledInstalledDescriptors: enabledInstalledDescriptors)
    }

    /// The claim answering one rich-fence alias, if any descriptor in this
    /// snapshot claims it.
    public func fenceClaim(for alias: RendererFenceAlias) -> RendererFenceClaimAssignment? {
        fenceClaims[alias]
    }

    public func matching(_ input: RendererMatchInput) -> [RendererDescriptor] {
        RendererResolution.matching(
            descriptors: descriptors,
            input: input,
            hostProtocolRevision: hostProtocolRevision)
    }

    /// Document embedding must always provide the syntax-owned role.
    public func matching(
        _ input: RendererMatchInput,
        requiredEmbeddingRole: RendererEmbeddingRole
    ) -> [RendererDescriptor] {
        RendererResolution.matching(
            descriptors: descriptors,
            input: input,
            requiredEmbeddingRole: requiredEmbeddingRole,
            hostProtocolRevision: hostProtocolRevision)
    }

    public func preferred(
        preference: RendererPreferenceReference?,
        input: RendererMatchInput
    ) -> RendererDescriptor? {
        RendererResolution.preferred(
            descriptors: descriptors,
            preference: preference,
            input: input,
            hostProtocolRevision: hostProtocolRevision)
    }

    public func preferred(
        preference: RendererPreference?,
        input: RendererMatchInput
    ) -> RendererDescriptor? {
        RendererResolution.preferred(
            descriptors: descriptors,
            preference: preference,
            input: input,
            hostProtocolRevision: hostProtocolRevision)
    }

    private static func validateChannelInvariants(
        builtInDescriptors: [RendererDescriptor],
        enabledInstalledDescriptors: [RendererDescriptor]
    ) throws {
        for descriptor in builtInDescriptors {
            guard case .builtIn = descriptor.implementation else {
                throw RendererValidationError.builtInRegistryContainsInstalled(descriptor.reference.registrationID)
            }
        }
        for descriptor in enabledInstalledDescriptors {
            guard case .webPackage = descriptor.implementation else {
                throw RendererValidationError.installedRegistryContainsBuiltIn(descriptor.reference.registrationID)
            }
        }
    }

    private static func validateUniqueReferences(_ descriptors: [RendererDescriptor]) throws {
        var seen = Set<RendererReference>()
        for descriptor in descriptors {
            guard seen.insert(descriptor.reference).inserted else {
                throw RendererValidationError.duplicateRegistration(descriptor.reference.registrationID)
            }
        }
    }
}

public enum RendererRegistrySnapshotDefaults {
    public static let hostProtocolRevision = 1
}
