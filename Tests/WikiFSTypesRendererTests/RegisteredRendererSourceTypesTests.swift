import Foundation
import Testing
@testable import WikiFSTypes

struct RegisteredRendererSourceTypesTests {
    @Test func aliasNormalizesToCanonical() throws {
        let descriptor = try makeDescriptor(
            registration: "example",
            displayName: "Example",
            canonical: "text/vnd.example",
            aliases: ["application/x-example"],
            extensions: ["example"])
        let catalog = RegisteredRendererSourceTypes(descriptors: [descriptor])
        let result = catalog.resolve(
            mimeType: "application/x-example",
            filenameExtension: "example",
            boundedBytes: Data("hello".utf8),
            bytesAreComplete: true)
        #expect(result.resolution?.canonicalMIMEType.rawValue == "text/vnd.example")
    }

    @Test func conflictingMIMEDoesNotUseExtension() throws {
        let catalog = RegisteredRendererSourceTypes(descriptors: [try makeDescriptor()])
        let result = catalog.resolve(
            mimeType: "text/plain",
            filenameExtension: "example",
            boundedBytes: Data("hello".utf8),
            bytesAreComplete: true)
        #expect(result == .noMatch)
    }

    @Test func sharedMIMEWithoutArtifactEvidenceIsAmbiguous() throws {
        let first = try makeDescriptor(registration: "first", displayName: "First", extensions: ["one"])
        let second = try makeDescriptor(registration: "second", displayName: "Second", extensions: ["two"])
        let catalog = RegisteredRendererSourceTypes(descriptors: [first, second])
        let mime = try RendererMIMEType(validating: "application/json")
        #expect(catalog.resolveWithoutBytes(mimeType: mime, fileExtension: nil) == .ambiguous)
    }

    @Test func completeArtifactBetweenLimitsMatches() throws {
        let padding = String(repeating: " ", count: RendererMatchingLimits.maximumSniffByteCount + 32)
        let bytes = Data("{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]\(padding)}".utf8)
        #expect(bytes.count < ContentArtifactValidationLimits.maximumInputByteCount)
        let descriptor = try makeDescriptor(
            matchers: [
                .normalizedMIME(try .init(validating: "application/json")),
                .extensionFallback(try .init(validating: "example")),
                .boundedJSON(try .init(
                    properties: ["type": .stringEquals("excalidraw"), "version": .integerEquals(2)],
                    arrays: ["elements": .object])),
            ])
        let result = RegisteredRendererSourceTypes(descriptors: [descriptor]).resolve(
            mimeType: "application/json",
            filenameExtension: "example",
            boundedBytes: bytes,
            bytesAreComplete: true)
        #expect(result.resolution != nil)
    }

    @Test func artifactAboveMaximumFailsClosed() throws {
        let bytes = Data(repeating: 0x20, count: ContentArtifactValidationLimits.maximumInputByteCount + 1)
        let descriptor = try makeDescriptor(matchers: [
            .normalizedMIME(try .init(validating: "application/json")),
            .extensionFallback(try .init(validating: "example")),
            .boundedJSON(try .init(properties: [:], arrays: [:])),
        ])
        let result = RegisteredRendererSourceTypes(descriptors: [descriptor]).resolve(
            mimeType: "application/json",
            filenameExtension: "example",
            boundedBytes: bytes,
            bytesAreComplete: false)
        #expect(result == .noMatch)
    }

    @Test func signatureNeverReadsArtifactChannel() throws {
        let signature = try RendererSignature(offset: 0, bytes: [0xAA])
        let descriptor = try makeDescriptor(matchers: [
            .boundedSignature(signature),
            .normalizedMIME(try .init(validating: "application/json")),
            .extensionFallback(try .init(validating: "example")),
        ])
        let input = try RendererMatchInput(
            mimeType: nil,
            fileExtension: nil,
            sniffedBytes: Data(),
            artifactInput: .init(bytes: Data([0xAA]), isComplete: true),
            artifactKind: .source)
        #expect(descriptor.matchTier(for: input) == nil)
    }

    private func makeDescriptor(
        registration: String = "example",
        displayName: String = "Example",
        canonical: String = "application/json",
        aliases: [String] = [],
        extensions: [String] = ["example"],
        matchers: [RendererMatcher]? = nil
    ) throws -> RendererDescriptor {
        let canonicalMIME = try RendererMIMEType(validating: canonical)
        let aliasMIMEs = try Set(aliases.map(RendererMIMEType.init(validating:)))
        let fileExtensions = try Set(extensions.map(RendererFileExtension.init(validating:)))
        let routes = matchers ?? ([.normalizedMIME(canonicalMIME)]
            + aliasMIMEs.map(RendererMatcher.normalizedMIME)
            + fileExtensions.map(RendererMatcher.extensionFallback))
        return try RendererFixtures.webDescriptor(
            registrationID: .init(validating: registration),
            matchers: routes,
            sourceType: .init(
                canonicalMIMEType: canonicalMIME,
                mimeAliases: aliasMIMEs,
                filenameExtensions: fileExtensions),
            explicitEmbeddingRoles: true)
    }
}
