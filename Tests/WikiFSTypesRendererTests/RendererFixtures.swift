import Foundation
@testable import WikiFSTypes

enum RendererFixtures {
    static let packageID = try! RendererPackageID(validating: "org.example.viewer")
    static let version = try! RendererPackageVersion(validating: "1.2.3")
    static let registrationID = try! RendererRegistrationID(validating: "viewer")

    static func nativeDescriptor(
        version: RendererPackageVersion = version,
        registrationID: RendererRegistrationID = registrationID,
        matchers: [RendererMatcher] = [.normalizedMIME(try! RendererMIMEType(validating: "application/pdf"))],
        embeddingRoles: Set<RendererEmbeddingRole> = [.disclosureRow],
        explicitEmbeddingRoles: Bool = false,
        compatibility: RendererCompatibility? = nil,
        priority: Int = 0
    ) throws -> RendererDescriptor {
        try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registrationID),
            displayName: "Example Viewer",
            implementation: .builtIn(.pdf),
            matchers: matchers,
            presentations: [.native],
            supportedEmbeddingRoles: embeddingRoles,
            hasExplicitEmbeddingRoles: explicitEmbeddingRoles,
            approvedAssets: [],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try compatibility ?? .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: priority
        )
    }

    static func webDescriptor(
        assets: [RendererAsset] = [webAsset()],
        packageID: RendererPackageID = packageID,
        version: RendererPackageVersion = version,
        registrationID: RendererRegistrationID = registrationID,
        matchers: [RendererMatcher] = [.artifactKind(.source)],
        embeddingRoles: Set<RendererEmbeddingRole> = [.disclosureRow],
        explicitEmbeddingRoles: Bool = false,
        priority: Int = 0
    ) throws -> RendererDescriptor {
        guard let entry = assets.first else { throw RendererValidationError.invalidPresentation }
        return try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registrationID),
            displayName: "Example Web Viewer",
            implementation: .webPackage(.init(path: entry.path)),
            matchers: matchers,
            presentations: [.web],
            supportedEmbeddingRoles: embeddingRoles,
            hasExplicitEmbeddingRoles: explicitEmbeddingRoles,
            approvedAssets: assets,
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: priority
        )
    }

    static func webAsset(path: String = "index.html") -> RendererAsset {
        RendererAsset(
            path: try! .init(validating: path),
            digest: try! RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
    }

    static func input(
        mime: String? = "application/pdf",
        fileExtension: String? = "pdf",
        bytes: Data = Data("%PDF".utf8),
        artifact: RendererArtifactKind? = .source
    ) throws -> RendererMatchInput {
        try .init(
            mimeType: try mime.map(RendererMIMEType.init(validating:)),
            fileExtension: try fileExtension.map(RendererFileExtension.init(validating:)),
            sniffedBytes: bytes,
            artifactKind: artifact
        )
    }
}

/// Deterministic, bounded Phase 6 inputs. These fixtures deliberately stop at
/// the artifact-discriminator boundary; document decoding and rendering belong
/// to later Phase 6 slices.
enum Phase6RendererArtifactFixtures {
    static let excalidraw = Data("""
    {"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}}
    """.utf8)

    static let jsonCanvas = Data("""
    {"nodes":[],"edges":[]}
    """.utf8)

    static let malformedExcalidraw = Data("""
    {"type":"excalidraw","version":1,"elements":[]}
    """.utf8)

    static let malformedJSONCanvas = Data("""
    {"nodes":{},"edges":[]}
    """.utf8)

    static let malformedJSON = Data("{".utf8)

    static func descriptor(
        packageID: String,
        registrationID: String,
        fileExtension: String,
        artifact: RendererJSONArtifact
    ) throws -> RendererDescriptor {
        try RendererFixtures.webDescriptor(
            packageID: try .init(validating: packageID),
            registrationID: try .init(validating: registrationID),
            matchers: [
                .normalizedMIME(try .init(validating: "application/json")),
                .extensionFallback(try .init(validating: fileExtension)),
                .boundedJSONArtifact(artifact),
            ])
    }

    static func input(
        bytes: Data,
        fileExtension: String
    ) throws -> RendererMatchInput {
        try .init(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: fileExtension),
            sniffedBytes: bytes,
            artifactKind: .source)
    }
}
