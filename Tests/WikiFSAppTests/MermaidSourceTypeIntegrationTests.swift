#if os(macOS)
import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFS

/// AC.6: with the Mermaid package active, the Testbed-shaped karaoke-MIME
/// `.mmd` source is text-presentable, transcludes as readable Mermaid source,
/// labels itself from the package display name, and stays renderer-matchable.
/// Without the claim it falls back generically.
@Suite("Mermaid source-type integration", .serialized, .timeLimit(.minutes(2)))
struct MermaidSourceTypeIntegrationTests {
    @Test func karaokeAliasResolvesThroughPackage() throws {
        let (store, _) = try makeStoreWithCatalog()
        let source = try store.addSource(
            filename: "sequence.mmd",
            data: Data("sequenceDiagram\n  A->>B: hi\n".utf8),
            mimeType: "application/vnd.chipnuts.karaoke-mmd")
        #expect(source.mimeType == "text/vnd.mermaid")
        #expect(MimeType.isSourceTextPresentable(source.mimeType))
    }

    @Test func transclusionUsesCanonicalTextNature() throws {
        // Ingest with no catalog and an explicit karaoke MIME: the row stays
        // a non-text platform alias with no markdown head.
        let store = try makeStore()
        let source = try store.addSource(
            filename: "embedded.mmd",
            data: Data("graph TD\n    A --> B\n".utf8),
            mimeType: "application/vnd.chipnuts.karaoke-mmd")
        #expect(source.mimeType == "application/vnd.chipnuts.karaoke-mmd")

        // Without the claim the read path fails closed: no embed body.
        let withoutClaim = try TransclusionEmbedder.sourceEmbedBody(
            testFixtureStore: store,
            id: source.id,
            rendererSourceTypes: .none)
        #expect(withoutClaim == nil)

        // With the claim the same row resolves to the canonical text MIME
        // and transcludes as readable Mermaid source.
        let withClaim = try TransclusionEmbedder.sourceEmbedBody(
            testFixtureStore: store,
            id: source.id,
            rendererSourceTypes: MermaidIntegrationFixtures.catalog)
        #expect(withClaim == "graph TD\n    A --> B\n")
    }

    @Test func provenanceUsesDescriptorDisplayName() throws {
        let (store, _) = try makeStoreWithCatalog()
        let source = try store.addSource(
            filename: "labeled.mmd",
            data: Data("graph LR\n  X --> Y\n".utf8),
            mimeType: "text/vnd.mermaid")
        let label = SourceProvenanceLabel.combine(
            provider: "File",
            ext: source.ext,
            mimeType: source.mimeType,
            rendererSourceTypes: MermaidIntegrationFixtures.catalog)
        #expect(label == "File / Mermaid")
    }

    @Test func packageAbsenceFallsBack() throws {
        // No catalog: the karaoke alias is an unknown platform MIME, the
        // source stores it as given when declared, and nothing crashes.
        let store = try makeStore()
        let source = try store.addSource(
            filename: "plain.mmd",
            data: Data("graph TD\n A-->B".utf8))
        // Generic UTF-8 text fallback, still readable and presentable.
        #expect(source.mimeType == "text/plain")
        #expect(MimeType.isSourceTextPresentable(source.mimeType))
        let bytes = try store.sourceContent(id: source.id)
        #expect(String(data: bytes, encoding: .utf8) == "graph TD\n A-->B")
    }

    // MARK: - Fixtures

    private func makeStore() throws -> GRDBWikiStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mermaid-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
    }

    private func makeStoreWithCatalog() throws -> (GRDBWikiStore, RegisteredRendererSourceTypes) {
        let store = try makeStore()
        store.registeredRendererSourceTypes = MermaidIntegrationFixtures.catalog
        return (store, MermaidIntegrationFixtures.catalog)
    }
}

/// The reviewed Mermaid claim, decoded once from the committed manifest.
enum MermaidIntegrationFixtures {
    static let catalog: RegisteredRendererSourceTypes = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try! JSONDecoder().decode(
            RendererManifest.self,
            from: try! Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        return RegisteredRendererSourceTypes(descriptors: manifest.descriptors)
    }()
}
#endif
