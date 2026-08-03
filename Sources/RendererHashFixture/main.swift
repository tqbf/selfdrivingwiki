import Foundation
import WikiFSTypes

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// pattern: Imperative Shell

private func packageHash(order: String) throws -> String {
    let packageID = try RendererPackageID(validating: "org.example.viewer")
    let version = try RendererPackageVersion(validating: "1.2.3")
    let registrationID = try RendererRegistrationID(validating: "viewer")
    let asset = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "a", count: 64)))
    let matchers: [RendererMatcher] = order == "reverse"
        ? [.extensionFallback(try .init(validating: "pdf")), .artifactKind(.source), .normalizedMIME(try .init(validating: "application/pdf"))]
        : [.normalizedMIME(try .init(validating: "application/pdf")), .artifactKind(.source), .extensionFallback(try .init(validating: "pdf"))]
    let capabilities: Set<RendererCapability> = order == "reverse" ? [.externalLink, .inputRead] : [.inputRead, .externalLink]
    let descriptor = try RendererDescriptor(
        reference: .init(packageID: packageID, version: version, registrationID: registrationID),
        displayName: "Web Viewer",
        implementation: .webPackage(.init(path: asset.path)),
        matchers: matchers,
        presentations: [.web],
        approvedAssets: [asset],
        capabilities: capabilities,
        sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
        linkPolicy: .userActivatedExternal,
        accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
        compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
        priority: 1
    )
    return try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset]).packageHash().hex
}

do {
    // This executable's stdout is its test protocol, not an app diagnostic.
    // swiftlint:disable:next diagnostic_print
    print(try packageHash(order: CommandLine.arguments.dropFirst().first ?? "forward"))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
