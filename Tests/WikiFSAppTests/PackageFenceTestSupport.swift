#if os(macOS)
import Foundation
import WikiFSTypes
@testable import WikiFS

/// Shared package-fence test fixtures: claim maps as the app resolves them,
/// and stand-in descriptors mirroring the shipped manifests.
enum PackageFenceTestSupport {
    static let installedPackageID = RendererPackageID(rawValue: "org.selfdrivingwiki.excalidraw-readonly")!
    static let installedPackageVersion = RendererPackageVersion(rawValue: "1.0.5")!
    static let installedRegistrationID = RendererRegistrationID(rawValue: "excalidraw")!
    static let installedDisplayName = "Excalidraw"

    static var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Excalidraw", isDirectory: true)
    }

    /// Claims for every host-known alias: the built-in table plus an installed
    /// package's manifest-declared claim.
    static var builtInAndInstalledClaims: [RendererFenceAlias: RendererFenceClaimAssignment] {
        RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            enabledInstalledDescriptors: [installedExcalidrawDescriptor()])
    }

    /// An installed Excalidraw descriptor with a manifest-declared fence claim.
    static func installedExcalidrawDescriptor() -> RendererDescriptor {
        let asset = RendererAsset(
            path: RendererRelativePath(rawValue: "index.html")!,
            digest: RendererSHA256.digest(Data("<html>excalidraw</html>".utf8)))
        return try! RendererDescriptor(
            reference: RendererReference(
                packageID: installedPackageID,
                version: installedPackageVersion,
                registrationID: installedRegistrationID),
            displayName: installedDisplayName,
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [
                .normalizedMIME(RendererMIMEType(rawValue: "application/json")!),
                .boundedJSON(try! RendererJSONConstraints(
                    properties: [
                        "type": .stringEquals("excalidraw"),
                        "version": .integerEquals(2),
                    ],
                    arrays: ["elements": .object])),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: [.inlineContent, .disclosureRow],
            hasExplicitEmbeddingRoles: true,
            fenceClaims: [
                RendererFenceClaim(
                    alias: RendererFenceAlias(rawValue: "excalidraw")!,
                    inlineMIMEType: RendererMIMEType(rawValue: "application/json")!),
            ],
            approvedAssets: [asset],
            capabilities: [.inputRead, .externalLink],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .userActivatedExternal,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 110)
    }

    /// A stand-in for the generated D2 package descriptor: identical shape to
    /// the lock-declared manifest (disclosureRow, d2 claim, text/plain).
    static func d2Descriptor() -> RendererDescriptor {
        let asset = RendererAsset(
            path: RendererRelativePath(rawValue: "index.html")!,
            digest: RendererSHA256.digest(Data("<html>d2</html>".utf8)))
        return try! RendererDescriptor(
            reference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.d2-readonly")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!,
                registrationID: RendererRegistrationID(rawValue: "d2")!),
            displayName: "D2",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [.extensionFallback(RendererFileExtension(rawValue: "d2")!)],
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            fenceClaims: [
                RendererFenceClaim(
                    alias: RendererFenceAlias(rawValue: "d2")!,
                    inlineMIMEType: RendererMIMEType(rawValue: "text/plain")!),
            ],
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 100)
    }
}
#endif
