import Foundation

// pattern: Functional Core

public enum RendererManifestRevision {
    public static let current = 1
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
        guard revision == RendererManifestRevision.current else {
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
        return try encoder.encode(CanonicalManifest(self))
    }

    /// SHA-256 of a versioned envelope that embeds normalized manifest JSON and
    /// every asset's canonical lowercase digest. The format label prevents a
    /// future envelope revision from sharing this hash namespace.
    public func packageHash() throws -> RendererSHA256Digest {
        let manifestObject = try JSONSerialization.jsonObject(with: canonicalJSON(), options: [.fragmentsAllowed])
        let envelope: [String: Any] = [
            "format": "selfdrivingwiki.renderer-package-hash",
            "revision": RendererManifestRevision.current,
            "manifest": manifestObject,
            "assets": assets.map { ["path": $0.path.rawValue, "sha256": $0.digest.hex] },
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return RendererSHA256.digest(data)
    }
}

private struct CanonicalManifest: Encodable {
    let revision: Int
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let descriptors: [CanonicalRendererDescriptor]
    let assets: [RendererAsset]

    init(_ manifest: RendererManifest) throws {
        revision = manifest.revision
        packageID = manifest.packageID
        version = manifest.version
        descriptors = try manifest.descriptors.map(CanonicalRendererDescriptor.init)
        assets = manifest.assets.sorted()
    }
}

private struct CanonicalRendererDescriptor: Encodable {
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
        matchers = try CanonicalRendererDescriptor.sortedCodable(descriptor.matchers)
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
