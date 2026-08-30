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
        let (_, model, source) = try makeStoreWithDocxSource()

        let extractor = StubDocxExtractor(
            result: DocxExtractionResult(
                markdown: "# Fixture Heading One\n\n**bold text** and _italic text_.\n",
                warnings: ["1 embedded images were not extracted"]),
            provenance: ExtractorPackageExecutionProvenance(
                revision: ReviewedExtractorPackages.docx2md.revision,
                registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
                protocolRevision: .v1))

        let version = try #require(await model.extractDocx(for: source.id, extractor: extractor))
        #expect(version.origin == .extraction)
        #expect(version.technique == "extractor-package:org.selfdrivingwiki.docx2md")
        #expect(version.content.contains("# Fixture Heading One"))
        // The new version becomes the head the staging path and the provenance
        // chip read.
        #expect(model.processedMarkdownHead(for: source)?.id == version.id)
    }

    @Test("empty extractor output returns nil and seeds nothing")
    @MainActor
    func emptyDocxExtractionReturnsNil() async throws {
        let (_, model, source) = try makeStoreWithDocxSource()

        let version = await model.extractDocx(
            for: source.id,
            extractor: StubDocxExtractor(result: DocxExtractionResult(markdown: "", warnings: [])))
        #expect(version == nil)
        #expect(model.processedMarkdownHead(for: source) == nil)
    }

    @Test("a registered docx extraction recognizes a dropped .docx, not a zip")
    @MainActor
    func docxDropImportIsRecognizedByTheRegistration() async throws {
        // A .docx IS a zip: the byte sniffer reports application/zip. The
        // ACTIVE registration's declared inputs (mimeTypes +
        // filenameExtensions from the docx2md manifest) are what recognize
        // the file — drop a .docx with the registration wired and the source
        // stores as Word; without it, the same bytes stay a zip binary.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx2md-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "docx2md-drop"))
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let registered = RegisteredExtractionInputs(claims: [.init(
            kind: .docx,
            mimeTypes: [MimeType.docx],
            filenameExtensions: ["docx"])])

        store.registeredExtractionInputs = registered
        let dropHints = ContentTypeDetectionHints(filename: "report.docx")
        let source: SourceSummary = try store.addSource(
            filename: "report.docx",
            data: Self.fixtureDocx,
            detectionHints: dropHints,
            ingestMetadata: nil,
            provenance: nil,
            role: .primary,
            originalPath: nil,
            activityID: nil,
            resolvedDisplayName: nil)

        #expect(source.mimeType == MimeType.docx)
        #expect(source.ext == "docx")
        let kind = ContentKind.resolve(
            mimeType: source.mimeType, provider: nil, ext: source.ext,
            registeredInputs: registered)
        #expect(kind == .docx)
        #expect(kind.capabilities.extractionPath == .docxBackend)
        #expect(kind.capabilities.hasFileExtractionBackend)

        // Without the registration, the same bytes import as a zip.
        store.registeredExtractionInputs = .none
        let secondHints = ContentTypeDetectionHints(filename: "report-2.docx")
        let unregistered: SourceSummary = try store.addSource(
            filename: "report-2.docx",
            data: Self.fixtureDocx + Data([0x00]),
            detectionHints: secondHints,
            ingestMetadata: nil,
            provenance: nil,
            role: .primary,
            originalPath: nil,
            activityID: nil,
            resolvedDisplayName: nil)
        #expect(unregistered.mimeType == MimeType.zip)
    }

    @Test("import auto-extraction seeds a markdown head when the registration is active")
    @MainActor
    func docxImportAutoExtractionSeedsHead() async throws {
        let (_, model, source) = try makeStoreWithDocxSource()
        model.registeredExtractionInputs = RegisteredExtractionInputs(claims: [.init(
            kind: .docx,
            mimeTypes: [MimeType.docx],
            filenameExtensions: ["docx"])])

        // No extractor wired → the gate closes, nothing runs.
        await model.runDocxImportExtraction(sourceID: source.id)
        #expect(model.processedMarkdownHead(for: source) == nil)

        // With the registration's extractor wired, the import conversion
        // seeds the markdown head with the package producer.
        model.docxImportExtractor = {
            StubDocxExtractor(
                result: DocxExtractionResult(
                    markdown: "# Auto extracted\n",
                    warnings: []),
                provenance: ExtractorPackageExecutionProvenance(
                    revision: ReviewedExtractorPackages.docx2md.revision,
                    registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
                    protocolRevision: .v1))
        }
        await model.runDocxImportExtraction(sourceID: source.id)

        let head = try #require(model.processedMarkdownHead(for: source))
        #expect(head.content.contains("# Auto extracted"))
        #expect(head.technique == "extractor-package:org.selfdrivingwiki.docx2md")
    }

    // MARK: - Helpers

    /// An in-container store seeded with the committed fixture `.docx` as a
    /// real binary source row.
    @MainActor
    private func makeStoreWithDocxSource() throws -> (store: GRDBWikiStore, model: WikiStoreModel, source: SourceSummary) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx2md-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "docx2md-store"))
        let model = WikiStoreModel(store: store)
        // The store's source rows classify through the registration surface
        // in production; seed the same surface so the fixture source's own
        // classification matches.
        store.registeredExtractionInputs = RegisteredExtractionInputs(claims: [.init(
            kind: .docx,
            mimeTypes: [MimeType.docx],
            filenameExtensions: ["docx"])])
        let source = try store.addSource(filename: "report.docx", data: Self.fixtureDocx)
        return (store, model, source)
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
        do {
            return try Data(contentsOf: url)
        } catch {
            fatalError("Required DOCX fixture is unreadable: \(error.localizedDescription)")
        }
    }
}

/// Injected DOCX adapter double: returns the canned result and optionally
/// carries package provenance like `ProcessPackageDOCXExtractor` does.
private struct StubDocxExtractor: DocxMarkdownExtractor {
    let result: DocxExtractionResult?
    var provenance: ExtractorPackageExecutionProvenance?

    var packageProvenance: ExtractorPackageExecutionProvenance {
        provenance ?? ExtractorPackageExecutionProvenance(
            revision: ReviewedExtractorPackages.docx2md.revision,
            registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
            protocolRevision: .v1)
    }

    init(result: DocxExtractionResult?, provenance: ExtractorPackageExecutionProvenance? = nil) {
        self.result = result
        self.provenance = provenance
    }

    func extract(docx: Data) async -> DocxExtractionResult? { result }
}


#endif
