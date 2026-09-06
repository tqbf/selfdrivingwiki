import Foundation
import Testing
@testable import WikiFSTypes

struct RendererSourceTypeManifestTests {
    @Test func revisionSixRoundTripsCanonicalSourceType() throws {
        let sourceType = try RendererSourceTypeDeclaration(
            canonicalMIMEType: .init(validating: "text/vnd.example"),
            mimeAliases: [.init(validating: "text/x-example"), .init(validating: "text/example")],
            filenameExtensions: [.init(validating: "example"), .init(validating: "ex")])
        let descriptor = try RendererFixtures.webDescriptor(
            matchers: [
                .normalizedMIME(try .init(validating: "text/vnd.example")),
                .normalizedMIME(try .init(validating: "text/x-example")),
                .normalizedMIME(try .init(validating: "text/example")),
                .extensionFallback(try .init(validating: "example")),
                .extensionFallback(try .init(validating: "ex")),
            ],
            sourceType: sourceType,
            explicitEmbeddingRoles: true)
        let manifest = try makeManifest(revision: RendererManifestRevision.sourceTypes, descriptor: descriptor)
        let canonical = try manifest.canonicalJSON()
        let roundTrip = try JSONDecoder().decode(RendererManifest.self, from: canonical)

        #expect(roundTrip.descriptors.only?.sourceType == sourceType)
        let text = String(decoding: canonical, as: UTF8.self)
        #expect(text.contains(#""mimeAliases":["text/example","text/x-example"]"#))
        #expect(text.contains(#""filenameExtensions":["ex","example"]"#))
    }

    @Test func preRevisionSixRejectsSourceType() throws {
        let descriptor = try descriptorWithSourceType()
        #expect(throws: RendererValidationError.sourceTypeRequiresRevision6) {
            _ = try makeManifest(revision: RendererManifestRevision.assetRead, descriptor: descriptor)
        }
    }

    @Test func sourceTypeRequiresMatchingRoutes() throws {
        let sourceType = try RendererSourceTypeDeclaration(
            canonicalMIMEType: .init(validating: "text/vnd.example"),
            filenameExtensions: [.init(validating: "example")])
        #expect(throws: RendererValidationError.sourceTypeMIMEMatcherMissing(
            try .init(validating: "text/vnd.example"))) {
            _ = try RendererFixtures.webDescriptor(
                matchers: [.extensionFallback(try .init(validating: "example"))],
                sourceType: sourceType)
        }
    }

    @Test(arguments: [
        #"{"canonicalMIMEType":"text/vnd.example","mimeAliases":["text/x-example","text/x-example"],"filenameExtensions":[]}"#,
        #"{"canonicalMIMEType":"text/vnd.example","mimeAliases":[" TEXT/X-EXAMPLE ","text/x-example"],"filenameExtensions":[]}"#,
    ])
    func duplicateMIMEsAreRejected(json: String) {
        #expect(throws: RendererValidationError.self) {
            _ = try JSONDecoder().decode(RendererSourceTypeDeclaration.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"canonicalMIMEType":"text/vnd.example","mimeAliases":[],"filenameExtensions":["ex","ex"]}"#,
        #"{"canonicalMIMEType":"text/vnd.example","mimeAliases":[],"filenameExtensions":[".EX","ex"]}"#,
    ])
    func duplicateExtensionsAreRejected(json: String) {
        #expect(throws: RendererValidationError.self) {
            _ = try JSONDecoder().decode(RendererSourceTypeDeclaration.self, from: Data(json.utf8))
        }
    }

    @Test func optionalOmissionPreservesLegacyDescriptor() throws {
        let descriptor = try RendererFixtures.webDescriptor(explicitEmbeddingRoles: true)
        let manifest = try makeManifest(revision: RendererManifestRevision.sourceTypes, descriptor: descriptor)
        #expect(String(decoding: try manifest.canonicalJSON(), as: UTF8.self).contains("sourceType") == false)
    }

    private func descriptorWithSourceType() throws -> RendererDescriptor {
        try RendererFixtures.webDescriptor(
            matchers: [
                .normalizedMIME(try .init(validating: "text/vnd.example")),
                .extensionFallback(try .init(validating: "example")),
            ],
            sourceType: try .init(
                canonicalMIMEType: .init(validating: "text/vnd.example"),
                filenameExtensions: [.init(validating: "example")]),
            explicitEmbeddingRoles: true)
    }

    private func makeManifest(revision: Int, descriptor: RendererDescriptor) throws -> RendererManifest {
        try RendererManifest(
            revision: revision,
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
