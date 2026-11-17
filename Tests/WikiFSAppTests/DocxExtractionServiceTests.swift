#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine
@testable import wikid

/// DOCX extraction store path (AC.8), exercised through the DAEMON format
/// route (P4.3 workload migration): the queue's `resolveFormatRoute`
/// recognizes the registration claim, prepares the reviewed docx2md adapter,
/// and `QueueFormatRoute.persistDocx` writes the version. Mirrors
/// `DefuddleExtractionServiceTests`'s store-level shape with in-repo fixture
/// bytes.
@Suite("Reviewed docx2md extractor", .serialized, .timeLimit(.minutes(2)))
struct DocxExtractionServiceTests {

    /// Extraction services whose DOCX route resolves the fixture adapter.
    private struct StubDocxServices: ExtractionServices {
        var extractor: StubDocxExtractor

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareHTML(
            backendOverride: HtmlExtractionBackend?
        ) async throws -> any HtmlMarkdownExtractor {
            throw ExtractionServicesError.unavailable
        }

        func prepareDOCX() async throws -> any DocxMarkdownExtractor {
            extractor
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            StubDocxServices.docxClaims
        }

        static let docxClaims = RegisteredExtractionInputs(claims: [.init(
            kind: .docx,
            mimeTypes: [MimeType.docx],
            filenameExtensions: ["docx"])])
    }

    /// Injected DOCX adapter double: returns the canned result and optionally
    /// carries package provenance like `ProcessPackageDOCXExtractor` does.
    struct StubDocxExtractor: DocxMarkdownExtractor {
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
        func readiness() async -> ExtractionReadiness { .ready }
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

    @Test("package extractor seeds a markdown version with installed-package provenance")
    @MainActor
    func docxExtractionSeedsProcessedMarkdownWithPackageProvenance() async throws {
        let (store, model, source) = try makeStoreWithDocxSource()

        let services = StubDocxServices(extractor: StubDocxExtractor(
            result: DocxExtractionResult(
                markdown: "# Fixture Heading One\n\n**bold text** and _italic text_.\n",
                warnings: ["1 embedded images were not extracted"]),
            provenance: ExtractorPackageExecutionProvenance(
                revision: ReviewedExtractorPackages.docx2md.revision,
                registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
                protocolRevision: .v1)))
        let provider = DaemonQueueExtractionProvider(
            extractionServices: services,
            storeResolver: { _ in store })

        guard case .docx(let docx)? = try await provider.resolveFormatRoute(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            htmlBackendOverride: nil) else {
            Issue.record("expected a DOCX format-route resolution")
            return
        }
        let markdown = try await docx.extract()
        let reference = try #require(await provider.persistDocxExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            resolution: docx, markdown: markdown))
        let versionID = try #require(reference.versionID)
        #expect(versionID.isEmpty == false)

        // The first conversion IS the head the staging path and the
        // provenance chip read.
        let version = try #require(try store.processedMarkdownHead(sourceID: source.id))
        #expect(version.origin == .extraction)
        #expect(version.technique == "extractor-package:org.selfdrivingwiki.docx2md")
        #expect(version.content.contains("# Fixture Heading One"))
        #expect(await model.processedMarkdownHead(for: source)?.id == version.id)
    }

    @Test("empty extractor output fails the conversion and seeds nothing")
    @MainActor
    func emptyDocxExtractionReturnsNil() async throws {
        let (store, model, source) = try makeStoreWithDocxSource()

        let services = StubDocxServices(extractor: StubDocxExtractor(
            result: DocxExtractionResult(markdown: "", warnings: [])))
        let provider = DaemonQueueExtractionProvider(
            extractionServices: services,
            storeResolver: { _ in store })

        guard case .docx(let docx)? = try await provider.resolveFormatRoute(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            htmlBackendOverride: nil) else {
            Issue.record("expected a DOCX format-route resolution")
            return
        }
        // The empty conversion now FAILS THE QUEUE ITEM (the Activity window
        // carries the message) — strictly stronger than the inline path's
        // silent nil.
        await #expect(throws: (any Error).self) {
            try await docx.extract()
        }
        #expect(await model.processedMarkdownHead(for: source) == nil)
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

        let registered = StubDocxServices.docxClaims

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

    @Test("import auto-extraction tracks the in-flight state around the enqueue")
    @MainActor
    func importExtractionTracksInFlightState() async throws {
        let (store, model, source) = try makeStoreWithDocxSource()
        model.registeredExtractionInputs = StubDocxServices.docxClaims
        model.importAutoExtractionKinds = [.docx]

        // The gated auto path marks the source in flight synchronously at
        // commit time; the enqueue closure observes that marker; the marker
        // clears once the enqueue is ACKed (the durable job then owns the
        // converting state over the queue events).
        let observedInFlight = InFlightObservation()
        let enqueued = EnqueueCounter()
        model.enqueueImportFormatJob = { @Sendable sourceID in
            let inFlight = await MainActor.run {
                model.importExtractingSourceIDs.contains(source.id)
            }
            observedInFlight.record(inFlight)
            enqueued.record(sourceID)
            _ = store // keep the store alive for the assertion window
        }

        model.autoExtractIfRegistered(source)
        #expect(model.importExtractingSourceIDs.contains(source.id))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.importExtractingSourceIDs.isEmpty == false {
            guard clock.now < deadline else {
                Issue.record("the import enqueue did not settle within the time limit")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedInFlight.value == true)
        #expect(enqueued.value == [source.id])
    }

    /// Records one boolean from a @Sendable closure.
    private final class InFlightObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded = false

        func record(_ value: Bool) {
            lock.withLock { if value { recorded = true } }
        }

        var value: Bool { lock.withLock { recorded } }
    }

    /// Records the enqueued source IDs from a @Sendable closure.
    private final class EnqueueCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [SourceID] = []

        func record(_ id: SourceID) {
            lock.withLock { ids.append(id) }
        }

        var value: [SourceID] { lock.withLock { ids } }
    }

    @Test("ingestion eligibility follows the extracted head, not the type alone")
    @MainActor
    func ingestionEligibilityFollowsExtractedHead() async throws {
        let (store, model, source) = try makeStoreWithDocxSource()
        model.registeredExtractionInputs = StubDocxServices.docxClaims

        // The TYPE predicate stays false for docx by design (raw docx bytes
        // are never staged), so a head-less docx is not ingestible…
        #expect(await model.shouldAutoIngest(source) == false)
        #expect(await model.isIngestible(source) == false)

        // …but once the daemon format route produces a head, the source is
        // ingestable — the head is what stages.
        let services = StubDocxServices(extractor: StubDocxExtractor(
            result: DocxExtractionResult(markdown: "# Ingestible\n", warnings: [])))
        let provider = DaemonQueueExtractionProvider(
            extractionServices: services,
            storeResolver: { _ in store })
        guard case .docx(let docx)? = try await provider.resolveFormatRoute(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            htmlBackendOverride: nil) else {
            Issue.record("expected a DOCX format-route resolution")
            return
        }
        let markdown = try await docx.extract()
        _ = try await provider.persistDocxExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: source.id,
            resolution: docx, markdown: markdown)
        #expect(await model.processedMarkdownHead(for: source) != nil)
        #expect(await model.isIngestible(source) == true)
    }

    @Test("the import gate closes without an enqueue seam and enqueues with one")
    @MainActor
    func importGateNeedsTheEnqueueSeam() async throws {
        let (store, model, source) = try makeStoreWithDocxSource()
        model.registeredExtractionInputs = StubDocxServices.docxClaims

        // No enqueue seam wired → the gate closes, nothing enqueues.
        model.importAutoExtractionKinds = [.docx]
        model.autoExtractIfRegistered(source)
        #expect(model.importExtractingSourceIDs.isEmpty)

        // With the seam wired, the claimed source enqueues the durable
        // import-conversion job (the daemon converts; the head then lands
        // through the store event path — asserted by the routed gate suite).
        model.enqueueImportFormatJob = { @Sendable _ in }
        let unclaimed = try store.addSource(
            filename: "report-plain.txt", data: Data("plain".utf8))
        model.autoExtractIfRegistered(unclaimed)
        #expect(model.importExtractingSourceIDs.isEmpty)

        model.autoExtractIfRegistered(source)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.importExtractingSourceIDs.isEmpty {
            guard clock.now < deadline else {
                Issue.record("the claimed source never marked in flight")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.importExtractingSourceIDs.contains(source.id))
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
        store.registeredExtractionInputs = StubDocxServices.docxClaims
        let source = try store.addSource(filename: "report.docx", data: Self.fixtureDocx)
        return (store, model, source)
    }
}


#endif
