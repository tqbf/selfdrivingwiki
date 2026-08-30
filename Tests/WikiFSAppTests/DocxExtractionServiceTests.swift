#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// DOCX extraction store path (AC.8): `WikiStoreModel.extractDocx` reads the
/// source's `.docx` bytes, runs the injected package adapter, and seeds a
/// processed-markdown version. Mirrors `DefuddleExtractionServiceTests`'s
/// store-level shape with in-repo fixture bytes.
@Suite("Reviewed docx2md extractor", .serialized, .timeLimit(.minutes(2)))
struct DocxExtractionServiceTests {

    @Test("package extractor seeds a markdown version with installed-package provenance")
    @MainActor
    func docxExtractionSeedsProcessedMarkdownWithPackageProvenance() async throws {
        let (store, model, sourceID) = try makeStoreWithDocxSource()

        let extractor = StubDocxExtractor(
            result: DocxExtractionResult(
                markdown: "# Fixture Heading One\n\n**bold text** and _italic text_.\n",
                warnings: ["1 embedded images were not extracted"]),
            provenance: ExtractorPackageExecutionProvenance(
                revision: ReviewedExtractorPackages.docx2md.revision,
                registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
                protocolRevision: .v1))

        let version = try #require(await model.extractDocx(for: sourceID, extractor: extractor))
        #expect(version.origin == .extraction)
        #expect(version.technique == "extractor-package:org.selfdrivingwiki.docx2md")
        #expect(version.content.contains("# Fixture Heading One"))
        // The new version becomes the head the staging path and the provenance
        // chip read.
        #expect(model.processedMarkdownHead(for: sourceID)?.id == version.id)
    }

    @Test("a double without package provenance records the legacy docx technique")
    @MainActor
    func docxExtractionWithoutPackageProvenanceRecordsLegacyTechnique() async throws {
        let (store, model, sourceID) = try makeStoreWithDocxSource()

        let version = try #require(
            await model.extractDocx(for: sourceID, extractor: StubDocxExtractor(result: DocxExtractionResult(
                markdown: "# Plain conversion\n",
                warnings: []))))
        // Only a test double can hit this arm; production DOCX adapters always
        // carry package provenance.
        #expect(version.technique == "docx-to-markdown")
    }

    @Test("empty extractor output returns nil and seeds nothing")
    @MainActor
    func emptyDocxExtractionReturnsNil() async throws {
        let (store, model, sourceID) = try makeStoreWithDocxSource()

        let version = await model.extractDocx(
            for: sourceID,
            extractor: StubDocxExtractor(result: DocxExtractionResult(markdown: "", warnings: [])))
        #expect(version == nil)
        #expect(model.processedMarkdownHead(for: sourceID) == nil)
    }

    // MARK: - Helpers

    /// An in-container store seeded with the committed fixture `.docx` as a
    /// real binary source row.
    @MainActor
    private func makeStoreWithDocxSource() throws -> (GRDBWikiStore, WikiStoreModel, SourceID) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx2md-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "docx2md-store"))
        let model = WikiStoreModel(store: store)
        let source = try store.addSource(filename: "report.docx", data: Self.fixtureDocx)
        return (store, model, source.id)
    }

    /// The committed conversion fixture from `tools/docx2md/tests/fixtures/`.
    /// The package directory must contain only manifest-declared files, so
    /// the fixture lives with the package sources and is read from there.
    private static var fixtureDocx: Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("docx2md", isDirectory: true)
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("fixture.docx")
        return (try? Data(contentsOf: url)) ?? Data("fixture-unavailable".utf8)
    }
}

/// Injected DOCX adapter double: returns the canned result and optionally
/// carries package provenance like `ProcessPackageDOCXExtractor` does.
private struct StubDocxExtractor: DocxMarkdownExtractor {
    let result: DocxExtractionResult?
    var provenance: ExtractorPackageExecutionProvenance?

    init(result: DocxExtractionResult?, provenance: ExtractorPackageExecutionProvenance? = nil) {
        self.result = result
        self.provenance = provenance
    }

    func extract(docx: Data) async -> DocxExtractionResult? { result }
}

extension StubDocxExtractor: ProcessPackageProvenanceProviding {
    var displayName: String { "stub-docx2md" }
    var packageProvenance: ExtractorPackageExecutionProvenance {
        provenance ?? ExtractorPackageExecutionProvenance(
            revision: ReviewedExtractorPackages.docx2md.revision,
            registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
            protocolRevision: .v1)
    }
}
#endif
