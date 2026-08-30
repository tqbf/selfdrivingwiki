import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// `ExtractionConfig` load/save round-trip, defaulting, resilient decode, and
/// the one-time migration of the retired typed selection keys into the generic
/// route-record table — mirrors `ZoteroConfigTests`'s temp-directory pattern.
struct ExtractionConfigTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A validated host reference for adapter literals used in tests.
    private func host(_ rawValue: String) -> ExtractionBackendReference {
        guard let adapterID = HostExtractorID(rawValue: rawValue) else {
            fatalError("invalid host adapter literal: \(rawValue)")
        }
        return .host(HostExtractorReference(adapterID: adapterID))
    }

    /// A loaded config always carries the bundled default-route records, so
    /// round-trip equality compares against the defaults-applied value.
    private func withDefaults(_ config: ExtractionConfig) -> ExtractionConfig {
        config.applying(defaults: .bundled)
    }

    /// The in-disk value of an in-memory config: the retired typed fields are
    /// decode-only and not persisted, so a round trip resets them to defaults.
    private func persisted(_ config: ExtractionConfig) -> ExtractionConfig {
        var result = config
        result.backend = .localPdf2md
        result.htmlBackend = nil
        return withDefaults(result)
    }

    @Test func defaultsAreLocalPdf2mdAndSonnetModel() {
        let config = ExtractionConfig()
        #expect(config.backend == .localPdf2md)
        #expect(config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        #expect(config.anthropicBaseURLOverride == nil)
        #expect(config.geminiModel == ExtractionConfig.defaultGeminiModel)
        #expect(config.geminiBaseURLOverride == nil)
        #expect(config.doclingServeEndpoint == nil)
        #expect(config.routeExtractors.isEmpty)
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .gemini
        config.anthropicModel = "claude-sonnet-4-6"
        config.anthropicBaseURLOverride = "https://proxy.example.com"
        config.geminiModel = "gemini-3.1-flash-lite"
        config.geminiBaseURLOverride = "https://vertex.example.com"
        config.doclingServeEndpoint = "http://localhost:5001"
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == persisted(config))
    }

    /// A fresh install loads the bundled default-route policy: the PDF route
    /// defaults to the reviewed pdf2md lineage and the DOCX route to the
    /// reviewed docx2md lineage. HTML has no shipped default (prompt).
    @Test func missingFileLoadsBundledRouteDefaults() throws {
        let config = ExtractionConfig.load(from: tempDirectory())
        #expect(config == withDefaults(ExtractionConfig()))

        let pdf2md = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.pdf2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let docx2md = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.docx2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        #expect(config.extractorSelection(for: .canonicalPDF) == .installed(pdf2md))
        #expect(config.extractorSelection(for: .canonicalDOCX) == .installed(docx2md))
        #expect(config.extractorSelection(for: .canonicalHTML) == nil)
    }

    @Test func corruptFileLoadsBundledDefaults() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ExtractionConfig.fileName, isDirectory: false)
        try Data("not json".utf8).write(to: url)
        #expect(ExtractionConfig.load(from: dir) == withDefaults(ExtractionConfig()))
    }

    @Test func partialJSONFillsMissingFieldsWithDefaults() throws {
        // A file written by an older version that only knew `backend` should
        // still load, with the newer fields defaulting rather than throwing.
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        #expect(config.anthropicBaseURLOverride == nil)
        #expect(config.geminiModel == ExtractionConfig.defaultGeminiModel)
        #expect(config.geminiBaseURLOverride == nil)
        #expect(config.doclingServeEndpoint == nil)
        // The retired `backend` value migrates into a PDF host record.
        #expect(config.extractorSelection(for: .canonicalPDF) == host("anthropic"))
    }

    @Test func unknownBackendValueDegradesToLocalPdf2md() throws {
        // A future/typo'd backend raw value shouldn't crash the decode; it
        // falls back to the safe local default and contributes no route
        // record (the bundled default policy still fills the route).
        let json = Data(#"{"backend":"totally_made_up"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .localPdf2md)
        #expect(config.routeExtractors.isEmpty)
    }

    @Test func nilFieldsRoundTripAsNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(
            backend: .doclingServe,
            anthropicModel: "claude-opus-4-8",
            anthropicBaseURLOverride: nil,
            doclingServeEndpoint: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == persisted(config))
        #expect(loaded.anthropicBaseURLOverride == nil)
        #expect(loaded.doclingServeEndpoint == nil)
    }

    @Test func backendDisplayNameAndHelpTextForAllCases() {
        for backend in ExtractionBackend.allCases {
            #expect(!backend.displayName.isEmpty)
            #expect(!backend.helpText.isEmpty)
        }
        #expect(ExtractionBackend.localPdf2md.displayName == "Local pdf2md")
        #expect(ExtractionBackend.acp.displayName == "ACP Provider")
        #expect(ExtractionBackend.anthropic.displayName == "Claude (Anthropic API)")
        #expect(ExtractionBackend.gemini.displayName == "Gemini (Google AI)")
        #expect(ExtractionBackend.doclingServe.displayName == "Docling Serve")
    }

    @Test func acpBackendRoundTripsAgentName() {
        #expect(ExtractionBackend.acp.agentName == "acp-extraction")
        #expect(ExtractionBackend.from(agentName: "acp-extraction") == .acp)
    }

    @Test func acpProviderIdRoundTrips() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .acp
        config.acpProviderId = "claude-acp"
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        // The provider id persists; the retired `backend` field does not, so
        // the PDF route resolves through the bundled default policy.
        #expect(loaded.acpProviderId == "claude-acp")
        let pdf2md = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.pdf2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        #expect(loaded.extractorSelection(for: .canonicalPDF) == .installed(pdf2md))
    }

    @Test func acpProviderIdDecodesAsNilWhenAbsent() throws {
        // A file written before the .acp backend existed (no acpProviderId key)
        // decodes with nil — forward-compatible.
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.acpProviderId == nil)
    }

    @Test func acpProviderIdRoundTripsNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(backend: .acp, acpProviderId: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded.acpProviderId == nil)
    }

    // MARK: - Podcast backend (a transcript setting, not a route selection)

    @Test func podcastBackendRoundTrips() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.podcastBackend = .appleTranscript
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == withDefaults(config))
        #expect(loaded.podcastBackend == .appleTranscript)
    }

    /// The retired `htmlBackend` field is a decode-only migration input: a
    /// decode adopts it into an HTML route record, and a re-encode never
    /// writes the key again.
    @Test func htmlBackendFieldIsDecodeOnly() throws {
        let json = Data(#"{"backend":"anthropic","htmlBackend":"defuddle"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.htmlBackend == .defuddle)
        #expect(config.extractorSelection(for: .canonicalHTML) == host("defuddle"))

        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["htmlBackend"] == nil)
    }

    @Test func htmlAndPodcastBackendsDecodeAsNilWhenAbsent() throws {
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
    }

    /// Unknown raw values for the retired optional fields degrade silently to
    /// nil — symmetric with `unknownBackendValueDegradesToLocalPdf2md`: the
    /// whole config still loads and no route record is produced.
    @Test func unknownHtmlAndPodcastBackendValuesDegradeToNil() throws {
        let json = Data(#"""
        {"backend":"anthropic","htmlBackend":"whisper","podcastBackend":"rev_ai"}
        """#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
        // The unknown HTML/podcast values contribute nothing, but the backend
        // value still migrates into its PDF host record.
        #expect(config.extractorSelection(for: .canonicalPDF) == host("anthropic"))
        #expect(config.extractorSelection(for: .canonicalHTML) == nil)
    }

    // MARK: - Migration of the retired selection keys

    /// Every retired key migrates in one file without crosstalk. The more
    /// specific extractor keys win over the older typed backend fields, and
    /// the re-encoded file keeps only `routeExtractors`.
    @Test func legacySelectionKeysMigrateIntoRouteRecords() throws {
        let json = Data(#"""
        {"backend":"doclingServe","htmlBackend":"defuddle",
         "pdfExtractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}},
         "htmlExtractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.extractorSelection(for: .canonicalPDF) == host("acp"))
        #expect(config.extractorSelection(for: .canonicalHTML) == host("tagBased"))

        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["backend"] == nil)
        #expect(object?["htmlBackend"] == nil)
        #expect(object?["pdfExtractor"] == nil)
        #expect(object?["htmlExtractor"] == nil)
        #expect(object?["routeExtractors"] != nil)
    }

    /// A legacy `backend` value without an extractor key becomes a host
    /// reference record. `.localPdf2md` was the shipped default, so it leaves
    /// the record absent and the bundled policy fills the route instead.
    @Test func legacyBackendValuesMigrateToHostRecords() throws {
        let acp = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"acp"}"#.utf8))
        #expect(acp.extractorSelection(for: .canonicalPDF) == host("acp"))

        let docling = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"doclingServe"}"#.utf8))
        #expect(docling.extractorSelection(for: .canonicalPDF) == host("doclingServe"))

        let retired = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"anthropic"}"#.utf8))
        #expect(retired.extractorSelection(for: .canonicalPDF) == host("anthropic"))

        let shippedDefault = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"localPdf2md"}"#.utf8))
        #expect(shippedDefault.extractorSelection(for: .canonicalPDF) == nil)
    }

    /// An explicit route record wins over a retired key for the same route:
    /// the record already claims the route, so the legacy value is ignored.
    @Test func routeRecordsWinOverLegacyKeys() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let record = """
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"installed",\
        "installed":{"packageID":"org.example.pdf","registrationID":"main"}}}
        """
        let json = Data(#"""
        {"backend":"acp","routeExtractors":[\#(record)]}
        """#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.extractorSelection(for: .canonicalPDF) == .installed(logical))
    }

    /// A malformed legacy key degrades to the next-older layer instead of
    /// rejecting the file: the malformed `pdfExtractor` value is ignored and
    /// the `backend` value still migrates — the same resilient-decode
    /// philosophy as every other field.
    @Test func malformedLegacyKeyDegradesToNoRecord() throws {
        let json = Data(#"{"backend":"anthropic","pdfExtractor":{"kind":"future"}}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.extractorSelection(for: .canonicalPDF) == host("anthropic"))
    }

    // MARK: - Route records

    @Test func routeRecordsRoundTripAndLegacyKeysStayAbsent() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.html"),
            registrationID: try ExtractorRegistrationID(validating: "article"))
        let config = ExtractionConfig(
            backend: .gemini,
            routeExtractors: [
                .init(route: .canonicalPDF, extractor: host("acp")),
                .init(route: .canonicalHTML, extractor: .installed(logical)),
            ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ExtractionConfig.self, from: data)
        var reset = config
        reset.backend = .localPdf2md
        reset.htmlBackend = nil
        #expect(decoded == reset)
        // The retired `backend` field is not persisted, so the decode falls
        // back to its default regardless of the in-memory value.
        #expect(decoded.backend == .localPdf2md)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["pdfExtractor"] == nil)
        #expect(object?["htmlExtractor"] == nil)
        #expect(object?["docxExtractor"] == nil)
    }

    @Test func installedSelectionRanksBySemanticVersionThenExactRevision() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let low = try activeRegistration(logical: logical, version: "1.9.0", digestByte: 9, kinds: [.pdf])
        let prerelease = try activeRegistration(logical: logical, version: "2.0.0-beta.1", digestByte: 10, kinds: [.pdf])
        let highA = try activeRegistration(logical: logical, version: "2.0.0", digestByte: 1, kinds: [.pdf])
        let highB = try activeRegistration(logical: logical, version: "2.0.0+other", digestByte: 2, kinds: [.pdf])
        var config = ExtractionConfig()
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let decision = ExtractorSelectionResolver.resolvePDF(
            configuration: config,
            activeRegistrations: [highA, prerelease, low, highB])
        #expect(decision.selection == .installed(kind: .pdf, reference: highB.reference))
        #expect(decision.diagnostic == nil)
    }

    @Test func unavailableExplicitSelectionResolvesAsUnavailable() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.missing"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let htmlOnly = try activeRegistration(logical: logical, version: "9.0.0", digestByte: 9, kinds: [.html])
        var pdfConfig = ExtractionConfig()
        pdfConfig.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let pdf = ExtractorSelectionResolver.resolvePDF(configuration: pdfConfig, activeRegistrations: [htmlOnly])
        #expect(pdf.selection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(pdf.diagnostic == .unavailableInstalled(logical))
        #expect(pdfConfig.extractorSelection(for: .canonicalPDF) == .installed(logical))

        var htmlConfig = ExtractionConfig()
        htmlConfig.setExtractorSelection(.installed(logical), for: .canonicalHTML)
        let html = ExtractorSelectionResolver.resolveHTML(configuration: htmlConfig, activeRegistrations: [])
        #expect(html.selection == .unavailableInstalled(kind: .html, reference: logical))
        #expect(html.diagnostic == .unavailableInstalled(logical))
        #expect(htmlConfig.extractorSelection(for: .canonicalHTML) == .installed(logical))
    }

    /// A host reference resolves as itself: the route supplies the input
    /// format, the reference only names the host adapter.
    @Test func hostSelectionsResolveAsHost() throws {
        var config = ExtractionConfig()
        config.setExtractorSelection(host("acp"), for: .canonicalPDF)
        config.setExtractorSelection(host("tagBased"), for: .canonicalHTML)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: []).selection == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "acp")!)))
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: []).selection == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "tagBased")!)))
    }

    /// An explicit `.none` record resolves to no selection — the shipped
    /// default stays disabled and nothing refills it.
    @Test func explicitNoneResolvesToNoSelection() throws {
        var config = ExtractionConfig()
        config.setExtractorSelection(ExtractionBackendReference.none, for: .canonicalPDF)
        config.setExtractorSelection(ExtractionBackendReference.none, for: .canonicalHTML)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: []).selection == .noSelection)
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: []).selection == .noSelection)
    }

    /// Without a stored record the bundled default policy participates: the
    /// PDF route defaults to the reviewed pdf2md lineage (unavailable here,
    /// because the test provides no active registration) and HTML, which the
    /// policy does not cover, resolves to no selection.
    @Test func bundledDefaultsParticipateWhenNoRecordExists() throws {
        let pdf2md = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.pdf2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let pdf = ExtractorSelectionResolver.resolvePDF(
            configuration: ExtractionConfig(), activeRegistrations: [])
        #expect(pdf.selection == .unavailableInstalled(kind: .pdf, reference: pdf2md))
        #expect(pdf.diagnostic == .unavailableInstalled(pdf2md))

        let html = ExtractorSelectionResolver.resolveHTML(
            configuration: ExtractionConfig(), activeRegistrations: [])
        #expect(html.selection == .noSelection)
    }

    // MARK: - Route selection writes

    /// AC.3: records encode in deterministic route order regardless of the order
    /// they were inserted. Determinism is asserted through the real persistence
    /// path (`JSONSidecarConfig.save`), whose encoder sorts keys; bare
    /// `JSONEncoder()` output is hash-ordered and not a determinism contract.
    @Test func routeSelectionsEncodeInDeterministicOrder() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let future = ExtractorRouteSelectionRecord(
            route: try ExtractorRouteID(kind: .pdf, mimeType: ExtractorMIMEType(validating: "application/epub+zip")),
            extractor: .installed(logical))
        var first = ExtractionConfig()
        first.setExtractorSelection(.installed(logical), for: .canonicalHTML)
        first.setExtractorSelection(host("doclingServe"), for: .canonicalPDF)
        first.setExtractorSelection(.installed(logical), for: future.route)
        var second = ExtractionConfig()
        second.setExtractorSelection(.installed(logical), for: future.route)
        second.setExtractorSelection(host("doclingServe"), for: .canonicalPDF)
        second.setExtractorSelection(.installed(logical), for: .canonicalHTML)
        #expect(first == second)

        // Identical configs persist byte-for-byte identical files, and records
        // appear in canonical route order (kind raw value, then MIME raw value:
        // "html text/html" < "pdf application/epub+zip" < "pdf application/pdf").
        let firstDir = tempDirectory()
        let secondDir = tempDirectory()
        try first.save(to: firstDir)
        try second.save(to: secondDir)
        let firstBytes = try Data(contentsOf: firstDir.appendingPathComponent(ExtractionConfig.fileName))
        let secondBytes = try Data(contentsOf: secondDir.appendingPathComponent(ExtractionConfig.fileName))
        #expect(firstBytes == secondBytes)
        #expect(try routeMIMEOrder(in: firstBytes) == ["text/html", "application/epub+zip", "application/pdf"])
    }

    /// AC.3: replacing one route's selection leaves every other route record
    /// untouched, including future non-canonical routes.
    @Test func routeSelectionReplacementPreservesOtherRoutes() throws {
        let htmlLogical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.html"),
            registrationID: try ExtractorRegistrationID(validating: "article"))
        let htmlRecord = ExtractorRouteSelectionRecord(route: .canonicalHTML, extractor: .installed(htmlLogical))
        var config = ExtractionConfig(routeExtractors: [htmlRecord])

        config.setExtractorSelection(host("acp"), for: .canonicalPDF)
        #expect(config.routeExtractors.count == 2)
        #expect(config.routeExtractors.contains { $0.route == .canonicalPDF })

        config.setExtractorSelection(host("doclingServe"), for: .canonicalPDF)
        #expect(config.routeExtractors.count == 2)
        #expect(config.extractorSelection(for: .canonicalHTML) == .installed(htmlLogical))
        #expect(config.extractorSelection(for: .canonicalPDF) == host("doclingServe"))

        config.setExtractorSelection(nil, for: .canonicalPDF)
        #expect(config.routeExtractors.count == 1)
        #expect(config.extractorSelection(for: .canonicalHTML) == .installed(htmlLogical))
        #expect(config.extractorSelection(for: .canonicalPDF) == nil)
    }

    /// A canonical route write touches ONLY the route table: the retired
    /// typed fields keep whatever value they decoded with and are never
    /// rewritten by selection writes.
    @Test func canonicalRouteWritesTouchOnlyRouteRecords() throws {
        var config = ExtractionConfig(backend: .anthropic, htmlBackend: .defuddle)

        config.setExtractorSelection(host("acp"), for: .canonicalPDF)
        #expect(config.extractorSelection(for: .canonicalPDF) == host("acp"))
        #expect(config.backend == .anthropic)

        config.setExtractorSelection(host("tagBased"), for: .canonicalHTML)
        #expect(config.extractorSelection(for: .canonicalHTML) == host("tagBased"))
        #expect(config.htmlBackend == .defuddle)

        config.setExtractorSelection(nil, for: .canonicalPDF)
        #expect(config.extractorSelection(for: .canonicalPDF) == nil)
        config.setExtractorSelection(nil, for: .canonicalHTML)
        #expect(config.extractorSelection(for: .canonicalHTML) == nil)

        // A non-canonical route record never touches other routes.
        let future = try ExtractorRouteID(kind: .pdf, mimeType: ExtractorMIMEType(validating: "application/epub+zip"))
        config.setExtractorSelection(host("acp"), for: future)
        #expect(config.extractorSelection(for: .canonicalPDF) == nil)
        #expect(config.routeExtractors.count == 1)

        // Round-trips through disk.
        let dir = tempDirectory()
        try config.save(to: dir)
        #expect(ExtractionConfig.load(from: dir) == persisted(config))
    }

    /// DOCX route persistence (AC.6): installed and explicit-none selections
    /// round-trip through the generic canonical DOCX route record. DOCX has
    /// no retired legacy field.
    @Test func docxRouteSelectionRoundTrips() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.docx"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        var config = ExtractionConfig()

        config.setExtractorSelection(.installed(logical), for: .canonicalDOCX)
        #expect(config.routeExtractors.contains { $0.route == .canonicalDOCX })
        #expect(config.extractorSelection(for: .canonicalDOCX) == .installed(logical))
        #expect(config.extractorSelection(for: .canonicalPDF) == nil)
        #expect(config.extractorSelection(for: .canonicalHTML) == nil)

        // Round-trips through disk.
        let dir = tempDirectory()
        try config.save(to: dir)
        #expect(ExtractionConfig.load(from: dir) == withDefaults(config))

        config.setExtractorSelection(nil, for: .canonicalDOCX)
        #expect(config.extractorSelection(for: .canonicalDOCX) == nil)
        #expect(config.routeExtractors.isEmpty)
    }

    /// An explicit `.none` DOCX record persists (it disables the bundled
    /// reviewed-package default) and survives a save/load.
    @Test func docxExplicitNoneRecordPersists() throws {
        var config = ExtractionConfig()
        config.setExtractorSelection(ExtractionBackendReference.none, for: .canonicalDOCX)
        #expect(config.extractorSelection(for: .canonicalDOCX) == ExtractionBackendReference.none)

        let dir = tempDirectory()
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        // The explicit record wins over the bundled default policy.
        #expect(loaded.extractorSelection(for: .canonicalDOCX) == ExtractionBackendReference.none)
    }

    /// DOCX route resolution (AC.7): the resolver reports the bundled
    /// reviewed-package default when no record exists, an active installed
    /// selection resolves to it, an inactive selection surfaces the redacted
    /// diagnostic, an explicit `.none` disables the route, and a host stray
    /// resolves as itself (execution fails closed — no DOCX host adapters
    /// exist).
    @Test func docxRouteSelectionResolves() throws {
        // No record → the bundled reviewed docx2md lineage; with no active
        // registration it fails closed with the redacted diagnostic.
        let reviewed = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.docx2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let empty = ExtractionConfig()
        let defaulted = ExtractorSelectionResolver.resolveDOCX(configuration: empty, activeRegistrations: [])
        #expect(defaulted.selection == .unavailableInstalled(kind: .docx, reference: reviewed))

        // Active registration → the exact reference.
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.docx"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let active = try activeRegistration(logical: logical, version: "1.0.0", digestByte: 3, kinds: [.docx])
        var config = ExtractionConfig()
        config.setExtractorSelection(.installed(logical), for: .canonicalDOCX)
        let decision = ExtractorSelectionResolver.resolveDOCX(
            configuration: config, activeRegistrations: [active])
        #expect(decision.selection == .installed(kind: .docx, reference: active.reference))
        #expect(decision.diagnostic == nil)

        // Inactive package → fail closed with the redacted diagnostic.
        let decisionUnavailable = ExtractorSelectionResolver.resolveDOCX(
            configuration: config, activeRegistrations: [])
        #expect(decisionUnavailable.selection == .unavailableInstalled(kind: .docx, reference: logical))
        #expect(decisionUnavailable.diagnostic == .unavailableInstalled(logical))

        // A cross-kind installed reference never resolves in the DOCX namespace.
        let htmlOnly = try activeRegistration(logical: logical, version: "9.0.0", digestByte: 9, kinds: [.html])
        let crossKind = ExtractorSelectionResolver.resolveDOCX(
            configuration: config, activeRegistrations: [htmlOnly])
        #expect(crossKind.selection == .unavailableInstalled(kind: .docx, reference: logical))

        // Explicit `.none` disables the shipped default.
        var disabled = ExtractionConfig()
        disabled.setExtractorSelection(ExtractionBackendReference.none, for: .canonicalDOCX)
        #expect(ExtractorSelectionResolver.resolveDOCX(configuration: disabled, activeRegistrations: [active]).selection == .noSelection)

        // A host stray under the DOCX route resolves as itself; the engine
        // fails closed because no DOCX host adapter is registered.
        var stray = ExtractionConfig()
        stray.setExtractorSelection(host("tagBased"), for: .canonicalDOCX)
        #expect(ExtractorSelectionResolver.resolveDOCX(configuration: stray, activeRegistrations: [active]).selection
            == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "tagBased")!)))

        // The route-aware entry dispatches canonicalDOCX.
        #expect(ExtractorSelectionResolver.resolve(.canonicalDOCX, configuration: empty, activeRegistrations: []) != nil)
    }

    /// AC.2/AC.3: duplicate records for one route in a hand-edited file resolve
    /// to the same single record regardless of their order in the file, with
    /// malformed records dropped through the logged decode seam. Legacy
    /// `builtIn` payloads still decode (as host references) so files written
    /// by earlier builds keep their selections.
    @Test func duplicateRouteRecordsResolveDeterministicallyAndLogBoundedDiagnostic() throws {
        let legacyRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}}}
        """#
        let installedRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"installed","installed":{"packageID":"org.example.pdf","registrationID":"main"}}}
        """#
        let legacyHTMLRecord = #"""
        {"route":{"kind":"html","mimeType":"text/html"},"extractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#
        let firstOrder = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(legacyRecord),\#(installedRecord),\#(legacyHTMLRecord)]}"#.utf8))
        let secondOrder = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(installedRecord),\#(legacyHTMLRecord),\#(legacyRecord)]}"#.utf8))
        #expect(firstOrder == secondOrder)
        #expect(firstOrder.routeExtractors.count == 2)

        // The winner is the canonically-greatest record for the route (here
        // the installed reference, which sorts after the host one).
        #expect(firstOrder.extractorSelection(for: .canonicalPDF) ==
            .installed(LogicalExtractorReference(
                packageID: try ExtractorPackageID(validating: "org.example.pdf"),
                registrationID: try ExtractorRegistrationID(validating: "main"))))
        #expect(firstOrder.extractorSelection(for: .canonicalHTML) == host("tagBased"))

        // A wholly malformed array and a malformed record both degrade without
        // throwing, keeping whatever records remain valid.
        let malformedArray = try JSONDecoder().decode(
            ExtractionConfig.self, from: Data(#"{"routeExtractors":"nope"}"#.utf8))
        #expect(malformedArray.routeExtractors.isEmpty)
        let malformedRecord = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(legacyRecord),{"route":{"kind":"pdf","mimeType":"bogus"}}]}"#.utf8))
        #expect(malformedRecord.routeExtractors.count == 1)
        #expect(malformedRecord.extractorSelection(for: .canonicalPDF) == host("acp"))
    }

    /// A malformed record must not swallow later valid records: Foundation's
    /// JSONDecoder leaves an unkeyed container's index in place after a failed
    /// decode, so the decode seam consumes the bad element and continues.
    @Test func malformedRecordDoesNotTruncateLaterValidRecords() throws {
        let legacyRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}}}
        """#
        let legacyHTMLRecord = #"""
        {"route":{"kind":"html","mimeType":"text/html"},"extractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#
        let malformed = #"{"route":{"kind":"pdf","mimeType":"bogus"}}"#

        // Malformed record first.
        let badFirst = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(malformed),\#(legacyRecord),\#(legacyHTMLRecord)]}"#.utf8))
        #expect(badFirst.routeExtractors.count == 2)
        #expect(badFirst.extractorSelection(for: .canonicalPDF) == host("acp"))
        #expect(badFirst.extractorSelection(for: .canonicalHTML) == host("tagBased"))

        // Malformed record in the middle.
        let badMiddle = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(legacyRecord),\#(malformed),\#(legacyHTMLRecord)]}"#.utf8))
        #expect(badMiddle == badFirst)

        // Multiple malformed records still terminate.
        let allBad = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"routeExtractors":[\#(malformed),\#(malformed)]}"#.utf8))
        #expect(allBad.routeExtractors.isEmpty)
    }

    /// AC.4: PDF/HTML resolution produces the same decision whether a selection
    /// is expressed as a retired key or an equivalent route record, and a
    /// route record overrides a conflicting legacy key. Unavailable installed
    /// selections keep the logical identity and diagnostic.
    @Test func routeResolutionMatchesLegacyEntryPoints() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let pdfOnly = try activeRegistration(logical: logical, version: "1.0.0", digestByte: 3, kinds: [.pdf])
        let legacyJSON = Data(#"""
        {"backend":"gemini","htmlBackend":"defuddle","pdfExtractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}}}
        """#.utf8)
        var config = try JSONDecoder().decode(ExtractionConfig.self, from: legacyJSON)

        // Migrated legacy key and an equivalent explicit record resolve
        // identically.
        let legacyPDF = ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly])
        #expect(legacyPDF.selection == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "acp")!)))
        config.setExtractorSelection(host("acp"), for: .canonicalPDF)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly]) == legacyPDF)

        // A route record overrides a conflicting legacy value.
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let recordPDF = ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly])
        #expect(recordPDF.selection == .installed(kind: .pdf, reference: pdfOnly.reference))
        #expect(recordPDF.diagnostic == nil)

        // An unavailable installed route record stays unavailable with the
        // same diagnostic as the equivalent legacy selection; once the record
        // is removed the bundled default policy participates instead.
        config.setExtractorSelection(nil, for: .canonicalPDF)
        let defaultedPDF = ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [])
        let pdf2md = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.pdf2md"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        #expect(defaultedPDF.selection == .unavailableInstalled(kind: .pdf, reference: pdf2md))
        #expect(defaultedPDF.diagnostic == .unavailableInstalled(pdf2md))
        var explicitUnavailable = ExtractionConfig()
        explicitUnavailable.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: explicitUnavailable, activeRegistrations: [])
            == .init(
                selection: .unavailableInstalled(kind: .pdf, reference: logical),
                diagnostic: .unavailableInstalled(logical)))

        // HTML: the migrated record drives resolution; removal restores the
        // no-selection state exactly.
        let migratedHTML = ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: [])
        #expect(migratedHTML.selection == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "defuddle")!)))
        config.setExtractorSelection(host("tagBased"), for: .canonicalHTML)
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: [])
            .selection == .host(HostExtractorReference(adapterID: HostExtractorID(rawValue: "tagBased")!)))
        config.setExtractorSelection(nil, for: .canonicalHTML)
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: []).selection == .noSelection)
    }

    /// The route-aware entry point agrees with the per-kind entry points on the
    /// canonical routes and declines routes without a host execution path.
    @Test func routeAwareEntryMatchesPerKindEntryPoints() throws {
        let config = ExtractionConfig(backend: .anthropic, htmlBackend: .defuddle)
        #expect(ExtractorSelectionResolver.resolve(.canonicalPDF, configuration: config, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: []))
        #expect(ExtractorSelectionResolver.resolve(.canonicalHTML, configuration: config, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: []))
        #expect(ExtractorSelectionResolver.resolve(.canonicalDOCX, configuration: config, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolveDOCX(configuration: config, activeRegistrations: []))
        let future = try ExtractorRouteID(kind: .html, mimeType: ExtractorMIMEType(validating: "application/xhtml+xml"))
        #expect(ExtractorSelectionResolver.resolve(future, configuration: config, activeRegistrations: []) == nil)
    }

    /// Decodes the raw `routeExtractors` array from encoded JSON and returns the
    /// MIME types in persisted order — a byte-order probe for determinism.
    private func routeMIMEOrder(in data: Data) throws -> [String] {
        struct Probe: Decodable {
            let route: ProbeRoute
            struct ProbeRoute: Decodable { let mimeType: String }
        }
        struct Envelope: Decodable { let routeExtractors: [Probe] }
        return try JSONDecoder().decode(Envelope.self, from: data).routeExtractors.map(\.route.mimeType)
    }

    private func activeRegistration(
        logical: LogicalExtractorReference,
        version: String,
        digestByte: UInt8,
        kinds: Set<ExtractorKind>
    ) throws -> ActiveExtractorRegistration {
        let revision = ExtractorPackageRevisionID(
            packageID: logical.packageID,
            version: try ExtractorPackageVersion(validating: version),
            digest: try ExtractorPackageDigest(bytes: Array(repeating: digestByte, count: ExtractorPackageDigest.byteCount)))
        return ActiveExtractorRegistration(
            reference: ExtractorReference(revision: revision, registrationID: logical.registrationID),
            kinds: kinds,
            protocolRevision: .v1)
    }
}
