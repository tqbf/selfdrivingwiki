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
        compatibility: RendererCompatibility? = nil,
        priority: Int = 0
    ) throws -> RendererDescriptor {
        try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registrationID),
            displayName: "Example Viewer",
            implementation: .builtIn(.pdf),
            matchers: matchers,
            presentations: [.native],
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
        priority: Int = 0
    ) throws -> RendererDescriptor {
        guard let entry = assets.first else { throw RendererValidationError.invalidPresentation }
        return try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registrationID),
            displayName: "Example Web Viewer",
            implementation: .webPackage(.init(path: entry.path)),
            matchers: matchers,
            presentations: [.web],
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
