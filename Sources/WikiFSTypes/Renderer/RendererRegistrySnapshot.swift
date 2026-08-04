import Foundation

// pattern: Functional Core

/// Immutable registry contents for one renderer-resolution moment.
///
/// The snapshot combines host-owned built-ins with enabled installed package
/// descriptors in one deterministic initializer. Source remains outside this
/// registry: callers ask for renderer matches and keep the host Source view as
/// the permanent fallback when no descriptor matches or resolution fails.
public struct RendererRegistrySnapshot: Hashable, Sendable {
    public let hostProtocolRevision: Int
    public let descriptors: [RendererDescriptor]

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
    }

    public func matching(_ input: RendererMatchInput) -> [RendererDescriptor] {
        RendererResolution.matching(
            descriptors: descriptors,
            input: input,
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
