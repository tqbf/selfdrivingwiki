import Foundation
import SQLite3
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// AC.4 ingest contract: a unique package claim replaces absent, generic, or
/// explicitly aliased MIME with the package canonical MIME; conflicting MIME,
/// binary signatures, malformed/truncated artifacts, and ambiguity fail
/// closed. Signatures stay bounded to the 4 KiB channel while complete
/// artifact validation uses the independently bounded 64 KiB channel.
@Suite("Renderer source-type ingest", .serialized)
struct RendererSourceTypeIngestTests {
    @Test func aliasNormalizesToCanonical() throws {
        let (store, _) = try makeStoreWithMermaidCatalog()
        let source = try store.addSource(
            filename: "sequence.mmd",
            data: Data("sequenceDiagram\n  A->>B: hi\n".utf8),
            mimeType: "application/vnd.chipnuts.karaoke-mmd")
        #expect(source.mimeType == "text/vnd.mermaid")
    }

    @Test func extensionOnlyNormalizesTextSource() throws {
        let (store, _) = try makeStoreWithMermaidCatalog()
        let source = try store.addSource(
            filename: "architecture.mmd",
            data: Data("flowchart TD\n    A --> B\n".utf8))
        #expect(source.mimeType == "text/vnd.mermaid")
    }

    @Test func conflictingMIMEIsPreserved() throws {
        let (store, _) = try makeStoreWithMermaidCatalog()
        let source = try store.addSource(
            filename: "notes.mmd",
            data: Data("plain-ish notes\n".utf8),
            mimeType: "text/plain")
        // text/plain is a valid MIME that no claim declares: extension
        // evidence alone must not overwrite it.
        #expect(source.mimeType == "text/plain")
    }

    @Test func binarySignatureWins() throws {
        let (store, _) = try makeStoreWithMermaidCatalog()
        let source = try store.addSource(
            filename: "disguised.mmd",
            data: Data("%PDF-1.7 rest".utf8))
        #expect(source.mimeType == "application/pdf")
    }

    @Test func ambiguousClaimFailsClosed() throws {
        let (store, catalog) = try makeStoreWithMermaidCatalog()
        // A second descriptor claiming the same alias with a different
        // canonical makes the alias ambiguous.
        let canonical = try RendererMIMEType(validating: "text/vnd.other")
        let alias = try RendererMIMEType(validating: "application/vnd.chipnuts.karaoke-mmd")
        let ext = try RendererFileExtension(validating: "mmd")
        let asset = RendererAsset(
            path: try .init(validating: "index.html"),
            digest: try RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
        let challenger = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: "org.example.challenger"),
                version: try .init(validating: "1.0.0"),
                registrationID: try .init(validating: "challenger")),
            displayName: "Challenger",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [.normalizedMIME(canonical), .normalizedMIME(alias), .extensionFallback(ext)],
            sourceType: .init(canonicalMIMEType: canonical, mimeAliases: [alias], filenameExtensions: [ext]),
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
        var claims = catalog.claims
        claims.insert(.init(descriptor: challenger))
        store.registeredRendererSourceTypes = RegisteredRendererSourceTypes(claims: claims)

        let source = try store.addSource(
            filename: "ambiguous.mmd",
            data: Data("graph TD\n".utf8),
            mimeType: "application/vnd.chipnuts.karaoke-mmd")
        // Fail closed: no package normalization happened; the trusted
        // declared MIME survives.
        #expect(source.mimeType == "application/vnd.chipnuts.karaoke-mmd")
    }

    @Test func completeArtifactBetweenSniffAndArtifactLimitsMatches() throws {
        let (store, _) = try makeStoreWithBigJSONClaim()
        let padding = String(repeating: " ", count: RendererMatchingLimits.maximumSniffByteCount)
        let bytes = Data("{\"k\":\"v\",\"elements\":[{}]\(padding)}".utf8)
        #expect(bytes.count > RendererMatchingLimits.maximumSniffByteCount)
        #expect(bytes.count <= ContentArtifactValidationLimits.maximumInputByteCount)
        let source = try store.addSource(
            filename: "sheet.bigjson",
            data: bytes,
            mimeType: "application/x-bigjson")
        #expect(source.mimeType == "application/json")
    }

    @Test func artifactAboveMaximumFailsClosed() throws {
        let (store, _) = try makeStoreWithBigJSONClaim()
        let bytes = Data(repeating: 0x20, count: ContentArtifactValidationLimits.maximumInputByteCount + 8)
        let source = try store.addSource(
            filename: "sheet.bigjson",
            data: bytes,
            mimeType: "application/x-bigjson")
        #expect(source.mimeType == "application/x-bigjson")
    }

    // MARK: - Fixtures

    private func makeStoreWithMermaidCatalog() throws -> (GRDBWikiStore, RegisteredRendererSourceTypes) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        let catalog = RegisteredRendererSourceTypes(descriptors: manifest.descriptors)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-type-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.registeredRendererSourceTypes = catalog
        return (store, catalog)
    }

    private func makeStoreWithBigJSONClaim() throws -> (GRDBWikiStore, RegisteredRendererSourceTypes) {
        let canonical = try RendererMIMEType(validating: "application/json")
        let alias = try RendererMIMEType(validating: "application/x-bigjson")
        let ext = try RendererFileExtension(validating: "bigjson")
        let constraints = try RendererJSONConstraints(
            properties: ["k": .stringEquals("v")],
            arrays: ["elements": .object])
        let asset = RendererAsset(
            path: try .init(validating: "index.html"),
            digest: try RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
        let descriptor = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: "org.example.bigjson"),
                version: try .init(validating: "1.0.0"),
                registrationID: try .init(validating: "bigjson")),
            displayName: "Big JSON",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [
                .normalizedMIME(canonical),
                .normalizedMIME(alias),
                .extensionFallback(ext),
                .boundedJSON(constraints),
            ],
            sourceType: .init(canonicalMIMEType: canonical, mimeAliases: [alias], filenameExtensions: [ext]),
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
        let catalog = RegisteredRendererSourceTypes(descriptors: [descriptor])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-type-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.registeredRendererSourceTypes = catalog
        return (store, catalog)
    }
}
