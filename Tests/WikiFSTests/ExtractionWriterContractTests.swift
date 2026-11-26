import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore
@testable import WikiFSEngine

@MainActor
struct ExtractionWriterContractTests {
    private struct StaticExtractor: MarkdownExtractor {
        let markdown: String
        var displayName: String { "static" }
        func readiness() async -> ExtractionReadiness { .ready }
        func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String {
            markdown
        }
    }

    private func source(_ store: GRDBWikiStore, filename: String = "evidence.pdf", data: Data = Data("pdf".utf8)) throws -> SourceSummary {
        try store.addSource(filename: filename, data: data)
    }

    private func provenance(_ store: GRDBWikiStore, sourceID: SourceID) throws -> ExtractionProvenance {
        let version = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        return try #require(try store.extractionProvenance(markdownVersionID: version.id))
    }

    private func assertBackend(
        _ backend: ExtractionBackend,
        providerID: ProviderID?,
        modelID: ModelID?
    ) throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        _ = try store.recordMarkdownExtraction(
            sourceID: summary.id, content: "output", backend: backend,
            modelVersion: modelID?.rawValue)
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .backend(backend))
        #expect(value.providerID == providerID)
        #expect(value.modelID == modelID)
    }

    @Test func pdfQueueUsesCanonicalExtraction() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        _ = try store.recordMarkdownExtraction(
            sourceID: summary.id, content: "queue", backend: .localPdf2md,
            modelVersion: "2.0")
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.pdf2md))
        #expect(value.toolVersion == "2.0")
        #expect(value.modelID == nil)
    }

    @Test func pdfSeedUsesCanonicalExtraction() async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let model = WikiStoreModel(store: store)
        _ = try await #require(model.seedPdfMarkdown(
            for: summary.id, content: "seed", backend: .doclingServe, modelVersion: "1.2"))
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.docling))
        #expect(value.toolVersion == "1.2")
    }

    @Test func pdfReextractUsesCanonicalExtraction() async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let model = WikiStoreModel(store: store)
        _ = try #require(await model.reExtractMarkdown(
            for: summary.id, filename: summary.filename,
            using: StaticExtractor(markdown: "re-extracted"), backend: .anthropic,
            modelVersion: "claude-test"))
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .backend(.anthropic))
        #expect(value.providerID == ProviderID(rawValue: "anthropic"))
        #expect(value.modelID == ModelID(rawValue: "claude-test"))
    }

    @Test func acpWriterPersistsTypedPlan() throws {
        try assertBackend(.acp, providerID: nil, modelID: ModelID(rawValue: "gpt-test"))
    }

    @Test func anthropicWriterPersistsTypedPlan() throws {
        try assertBackend(
            .anthropic, providerID: ProviderID(rawValue: "anthropic"),
            modelID: ModelID(rawValue: "claude-test"))
    }

    @Test func geminiWriterPersistsTypedPlan() throws {
        try assertBackend(
            .gemini, providerID: ProviderID(rawValue: "gemini"),
            modelID: ModelID(rawValue: "gemini-test"))
    }

    @Test func doclingWriterPersistsToolVersion() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        _ = try store.recordMarkdownExtraction(
            sourceID: summary.id, content: "docling", backend: .doclingServe,
            modelVersion: "docling-3")
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.docling))
        #expect(value.toolVersion == "docling-3")
        #expect(value.modelID == nil)
    }

    @Test func pdf2mdWriterPersistsToolVersion() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        _ = try store.recordMarkdownExtraction(
            sourceID: summary.id, content: "pdf2md", backend: .localPdf2md,
            modelVersion: "pdf2md-3")
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.pdf2md))
        #expect(value.toolVersion == "pdf2md-3")
    }

    @Test func htmlWriterPersistsToolPlan() async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(
            store, filename: "page.html", data: Data("<h1>Heading</h1><p>Body</p>".utf8))
        // The daemon format route's tag-based floor: a resolution with a nil
        // package producer writes `.tool(.html)` provenance — the same
        // contract the inline pipeline this replaced asserted (P4.3).
        let resolution = HtmlExtractionResolution(
            extract: { "tag-extracted" },
            filename: summary.filename,
            backend: .tagBased,
            producer: nil,
            technique: QueueFormatRoute.htmlToMarkdownTechnique)
        let reference = try QueueFormatRoute.persistHtml(
            store: store, sourceID: summary.id, resolution: resolution,
            markdown: "tag-extracted", nominateActive: false)
        _ = try #require(reference)
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.html))
        #expect(value.providerID == nil)
        #expect(value.modelID == nil)
    }

    @Test func materializerSidecarUsesTypedTool() async throws {
        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        let summary = try await model.storeMaterialized(.init(
            filename: "sidecar.html", data: Data("<p>raw</p>".utf8),
            mimeType: "text/html", extractedMarkdown: "sidecar",
            extractionTechnique: "legacy-sidecar"))
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.materializerSidecar))
    }

    @Test func appleTranscriptUsesTypedTool() async throws {
        try await assertTranscript(technique: ExtractionTool.appleTTML.rawValue, expected: .appleTTML)
    }

    @Test func youtubeTranscriptUsesTypedTool() async throws {
        try await assertTranscript(technique: ExtractionTool.youtubeCaptions.rawValue, expected: .youtubeCaptions)
    }

    @Test func rssTranscriptUsesTypedTool() async throws {
        try await assertTranscript(technique: ExtractionTool.rssPodcastTranscript.rawValue, expected: .rssPodcastTranscript)
    }

    @Test func vimeoTranscriptUsesTypedTool() async throws {
        try await assertTranscript(technique: ExtractionTool.vimeoTranscript.rawValue, expected: .vimeoTranscript)
    }

    @Test func wikictlTranscriptUsesTypedTool() async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        try await SourceCommand.persistRefreshMaterial(
            .derivedMarkdown(content: "refreshed transcript"), sourceID: summary.id, in: store)
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.producer == .tool(.transcript))
    }

    private func assertTranscript(technique: String, expected: ExtractionTool) async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let model = WikiStoreModel(store: store)
        _ = try await #require(model.appendTranscriptMarkdown(
            for: summary.id, content: "transcript", technique: technique))
        let value = try provenance(store, sourceID: summary.id)
        #expect(value.origin == .transcript)
        #expect(value.producer == .tool(expected))
    }
}
