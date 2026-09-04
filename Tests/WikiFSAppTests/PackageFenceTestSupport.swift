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

    /// An installed Mermaid descriptor with a manifest-declared fence claim
    /// plus its revision-3 validation contract — the stand-in mirrors the
    /// shipped RendererPackages/Mermaid manifest.
    static func installedMermaidDescriptor() -> RendererDescriptor {
        let entry = RendererAsset(
            path: RendererRelativePath(rawValue: "index.html")!,
            digest: RendererSHA256.digest(Data("<html>mermaid</html>".utf8)))
        let engine = RendererAsset(
            path: RendererRelativePath(rawValue: "mermaid.min.js")!,
            digest: RendererSHA256.digest(Data("engine".utf8)))
        let wrapper = RendererAsset(
            path: RendererRelativePath(rawValue: "validate.js")!,
            digest: RendererSHA256.digest(Data("wrapper".utf8)))
        return try! RendererDescriptor(
            reference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.mermaid-readonly")!,
                version: RendererPackageVersion(rawValue: "1.0.1")!,
                registrationID: RendererRegistrationID(rawValue: "mermaid")!),
            displayName: "Mermaid",
            implementation: .webPackage(.init(path: entry.path)),
            matchers: [
                .normalizedMIME(RendererMIMEType(rawValue: "text/mermaid")!),
                .extensionFallback(RendererFileExtension(rawValue: "mmd")!),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: [.inlineContent, .disclosureRow],
            hasExplicitEmbeddingRoles: true,
            fenceClaims: [
                RendererFenceClaim(
                    alias: RendererFenceAlias(rawValue: "mermaid")!,
                    inlineMIMEType: RendererMIMEType(rawValue: "text/mermaid")!,
                    validation: try! RendererFenceValidationDeclaration(
                        engineAssetPath: engine.path,
                        wrapperAssetPath: wrapper.path,
                        entryFunction: "__sdw_validate_fence")),
            ],
            approvedAssets: [engine, entry, wrapper],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 90)
    }

    /// Claims for every host-known alias: the built-in table plus installed
    /// package manifest-declared claims (Excalidraw, Mermaid, and JSON Canvas).
    static var builtInAndInstalledClaims: [RendererFenceAlias: RendererFenceClaimAssignment] {
        RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [
                installedExcalidrawDescriptor(),
                installedMermaidDescriptor(),
                installedJSONCanvasDescriptor(),
            ])
    }

    /// An installed JSON Canvas descriptor with a manifest-declared fence claim.
    /// JSON Canvas is a Web package only; the reviewed package claims
    /// `jsoncanvas` at install time.
    static func installedJSONCanvasDescriptor() -> RendererDescriptor {
        let asset = RendererAsset(
            path: RendererRelativePath(rawValue: "index.html")!,
            digest: RendererSHA256.digest(Data("<html>json canvas</html>".utf8)))
        return try! RendererDescriptor(
            reference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.json-canvas-readonly")!,
                version: RendererPackageVersion(rawValue: "1.0.1")!,
                registrationID: RendererRegistrationID(rawValue: "json-canvas")!),
            displayName: "JSON Canvas",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [
                .normalizedMIME(RendererMIMEType(rawValue: "application/json")!),
                .extensionFallback(RendererFileExtension(rawValue: "canvas")!),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: [.inlineContent, .disclosureRow],
            hasExplicitEmbeddingRoles: true,
            fenceClaims: [
                RendererFenceClaim(
                    alias: RendererFenceAlias(rawValue: "jsoncanvas")!,
                    inlineMIMEType: RendererMIMEType(rawValue: "application/json")!),
            ],
            approvedAssets: [asset],
            capabilities: [.inputRead, .externalLink, .hostNavigation],
            hostNavigation: try! .init(allowedTargetKinds: [.page, .source, .namedContent]),
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .userActivatedExternal,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 110)
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
                version: RendererPackageVersion(rawValue: "1.0.1")!,
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
