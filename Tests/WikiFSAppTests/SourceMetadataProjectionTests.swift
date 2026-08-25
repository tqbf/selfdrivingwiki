import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct SourceMetadataProjectionTests {
    @Test func sourceProjectionWithZeroAlternativesOmitsCompareAction() { #expect(!hasCompare(alternatives: 0)) }
    @Test func sourceProjectionWithOneAlternativeOmitsCompareAction() { #expect(!hasCompare(alternatives: 1)) }
    @Test func sourceProjectionWithTwoAlternativesIncludesCompareAction() { #expect(hasCompare(alternatives: 2)) }
    @Test func sourceProjectionIncludesModelWhenPresent() { #expect(fields(provenance(model: "model")).contains(.model)) }
    @Test func sourceProjectionOmitsModelWhenAbsent() { #expect(!fields(provenance(model: nil)).contains(.model)) }
    @Test func sourceProjectionIncludesProviderWhenPresent() { #expect(fields(provenance(provider: "provider")).contains(.provider)) }
    @Test func sourceProjectionOmitsProviderWhenAbsent() { #expect(!fields(provenance(provider: nil)).contains(.provider)) }
    @Test func sourceProjectionIncludesToolVersionWhenPresent() { #expect(fields(provenance(toolVersion: "1.0")).contains(.backend)) }
    @Test func sourceProjectionOmitsToolVersionWhenAbsent() { #expect(!fields(provenance(toolVersion: nil)).contains(.backend)) }
    @Test func sourceProjectionIncludesExtractionDateWhenPresent() { #expect(fields(provenance()).contains(.extractionDate)) }
    @Test func sourceProjectionOmitsExtractionDateWhenAbsent() { #expect(!fields(nil).contains(.extractionDate)) }
    @Test func sourceProjectionIncludesSourceVersionWhenPresent() { #expect(fields(provenance(sourceVersion: "version")).contains(.sourceVersion)) }
    @Test func sourceProjectionOmitsSourceVersionWhenAbsent() { #expect(!fields(provenance(sourceVersion: nil)).contains(.sourceVersion)) }
    @Test func sourceProjectionIncludesExtractionVersionWhenPresent() { #expect(fields(nil, markdown: markdown()).contains(.extractionVersion)) }
    @Test func sourceProjectionOmitsExtractionVersionWhenAbsent() { #expect(!fields(nil, markdown: nil).contains(.extractionVersion)) }
    @Test func sourceProjectionIncludesHashWhenPresent() { #expect(fields(nil, markdown: markdown(hash: "hash")).contains(.hash)) }
    @Test func sourceProjectionOmitsHashWhenAbsent() { #expect(!fields(nil, markdown: markdown(hash: nil)).contains(.hash)) }

    private func hasCompare(alternatives: Int) -> Bool { fields(nil, alternatives: alternatives).contains(.compareExtractions) }
    private func fields(_ provenance: ExtractionProvenance?, markdown: SourceMarkdownVersion? = nil, alternatives: Int = 0) -> [MetadataFieldID] {
        SourceMetadataProjection.make(input: .init(
            source: source(), markdown: markdown, extraction: provenance,
            alternativeCount: alternatives, okfMetadata: .init()
        )).sections.flatMap(\.rows).map(\.id)
    }
    private func source() -> SourceSummary { .init(id: .init(rawValue: "source"), filename: "source.pdf", ext: "pdf", mimeType: "application/pdf", byteSize: 12, createdAt: .distantPast, updatedAt: .distantPast, version: 1) }
    private func markdown(hash: String? = nil) -> SourceMarkdownVersion { .init(id: .init(rawValue: "markdown"), sourceID: .init(rawValue: "source"), parentID: nil, content: "", origin: .extraction, note: nil, createdAt: .distantPast, blobHash: hash) }
    private func provenance(provider: String? = "provider", model: String? = "model", toolVersion: String? = nil, sourceVersion: String? = nil) -> ExtractionProvenance {
        .init(markdownVersionID: .init(rawValue: "markdown"), sourceID: .init(rawValue: "source"), origin: .extraction, producer: .backend(.anthropic), providerID: provider.map(ProviderID.init(rawValue:)), modelID: model.map(ModelID.init(rawValue:)), toolVersion: toolVersion, createdAt: .distantPast, sourceVersionID: sourceVersion.map(SourceVersionID.init(rawValue:)))
    }
}
