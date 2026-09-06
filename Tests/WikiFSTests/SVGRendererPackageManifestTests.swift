import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Manifest-declaration behavior for the reviewed SVG renderer package:
/// revision 2 identity, the single `svg` fence claim, the read-only contract,
/// and the matching tiers the reader consumes. This suite lives in the
/// always-run test target, so CI decodes the real manifest even though the
/// hosted suites are gated behind `WIKIFS_APP_TESTS=1`.
@Suite("SVG renderer package manifest", .serialized)
struct SVGRendererPackageManifestTests {
    private let manifest: RendererManifest
    private let descriptor: RendererDescriptor

    init() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/SVG", isDirectory: true)
        manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: packageRoot.appendingPathComponent("manifest.json")))
        descriptor = try #require(manifest.descriptors.first)
    }

    @Test("the manifest decodes at revision 6 with the reviewed identity")
    func manifestDecodesWithReviewedIdentity() throws {
        #expect(manifest.revision == RendererManifestRevision.sourceTypes)
        #expect(manifest.packageID.rawValue == "org.selfdrivingwiki.svg-readonly")
        #expect(manifest.version.rawValue == "1.1.1")
        #expect(descriptor.reference.packageID.rawValue == "org.selfdrivingwiki.svg-readonly")
        #expect(descriptor.reference.version.rawValue == "1.1.1")
        #expect(descriptor.reference.registrationID.rawValue == "svg")
        #expect(descriptor.displayName == "SVG")
        #expect(descriptor.priority == 100)
        #expect(descriptor.implementation == .webPackage(.init(path: try .init(validating: "index.html"))))
    }

    @Test("revision 6 grants exactly the svg fence claim and source type")
    func fenceClaimIsExact() throws {
        let claim = try #require(descriptor.fenceClaims.only)
        #expect(claim.alias == RendererFenceAlias(rawValue: "svg"))
        #expect(claim.inlineMIMEType == RendererMIMEType(rawValue: "image/svg+xml"))
        let sourceType = try #require(descriptor.sourceType)
        #expect(sourceType.canonicalMIMEType == RendererMIMEType(rawValue: "image/svg+xml"))
        #expect(sourceType.mimeAliases.isEmpty)
        #expect(sourceType.filenameExtensions == [RendererFileExtension(rawValue: "svg")])
    }

    @Test("the claim keeps the read-only contract and the disclosure role")
    func readOnlyContractHolds() throws {
        #expect(descriptor.capabilities == [.inputRead])
        #expect(descriptor.linkPolicy == .none)
        #expect(descriptor.presentations == [.web])
        #expect(descriptor.supportedEmbeddingRoles == [.inlineContent, .disclosureRow])
        #expect(descriptor.sizeLimits.maximumInputByteCount == 16_000_000)
        #expect(descriptor.sizeLimits.maximumDecodedByteCount == 16_000_000)
    }

    @Test("an image/svg+xml source selects the package; other sources do not")
    func mimeMatchingSelectsThePackage() throws {
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let svgBytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        let mimeInput = try RendererMatchInput(
            mimeType: try .init(validating: "image/svg+xml"),
            fileExtension: try .init(validating: "svg"),
            sniffedBytes: svgBytes,
            artifactKind: .source)
        let extensionInput = try RendererMatchInput(
            mimeType: nil,
            fileExtension: try .init(validating: "svg"),
            sniffedBytes: svgBytes,
            artifactKind: .source)
        let otherInput = try RendererMatchInput(
            mimeType: try .init(validating: "text/plain"),
            fileExtension: try .init(validating: "txt"),
            sniffedBytes: Data("hello".utf8),
            artifactKind: .source)

        #expect(snapshot.matching(mimeInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(extensionInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(otherInput).isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
