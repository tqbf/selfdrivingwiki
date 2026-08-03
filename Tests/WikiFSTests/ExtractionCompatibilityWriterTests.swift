import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Compatibility writers must preserve their public inputs while persisting
/// through the typed derived-markdown seam.
struct ExtractionCompatibilityWriterTests {
    private func source(_ store: GRDBWikiStore) throws -> SourceSummary {
        try store.addSource(filename: "compatibility.pdf", data: Data("pdf".utf8))
    }

    @Test func appendProcessedMarkdownDerivedCompatibilityRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let version = try store.appendProcessedMarkdown(
            sourceID: summary.id, content: "derived", origin: .extraction,
            note: nil, technique: ExtractionTool.pdf2md.rawValue)
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .extraction)
        #expect(provenance.producer == .tool(.pdf2md))
    }

    @Test func legacyTranscriptWriterRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let version = try store.appendProcessedMarkdown(
            sourceID: summary.id, content: "transcript", origin: .transcript,
            note: nil, technique: ExtractionTool.youtubeCaptions.rawValue)
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .transcript)
        #expect(provenance.producer == .tool(.youtubeCaptions))
    }

    @Test func wikictlTranscriptCompatibilityRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        try SourceCommand.persistRefreshMaterial(
            .derivedMarkdown(content: "cli transcript"), sourceID: summary.id, in: store)
        let version = try #require(try store.processedMarkdownHead(sourceID: summary.id))
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .transcript)
        #expect(provenance.producer == .tool(.transcript))
    }
}
