import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// `ExtractionConfig` load/save round-trip, defaulting, and resilient decode
/// — mirrors `ZoteroConfigTests`'s temp-directory pattern.
struct ExtractionConfigTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func defaultsAreLocalPdf2mdAndSonnetModel() {
        let config = ExtractionConfig()
        #expect(config.backend == .localPdf2md)
        #expect(config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        #expect(config.anthropicBaseURLOverride == nil)
        #expect(config.geminiModel == ExtractionConfig.defaultGeminiModel)
        #expect(config.geminiBaseURLOverride == nil)
        #expect(config.doclingServeEndpoint == nil)
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
        #expect(loaded == config)
    }

    @Test func missingFileLoadsDefaults() {
        let config = ExtractionConfig.load(from: tempDirectory())
        #expect(config == ExtractionConfig())
    }

    @Test func corruptFileLoadsDefaults() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ExtractionConfig.fileName, isDirectory: false)
        try Data("not json".utf8).write(to: url)
        #expect(ExtractionConfig.load(from: dir) == ExtractionConfig())
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
    }

    @Test func unknownBackendValueDegradesToLocalPdf2md() throws {
        // A future/typo'd backend raw value shouldn't crash the decode; it falls
        // back to the safe local default (mirrors `load`'s corrupt-file rule).
        let json = Data(#"{"backend":"totally_made_up"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .localPdf2md)
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
        #expect(loaded == config)
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
        #expect(loaded.backend == .acp)
        #expect(loaded.acpProviderId == "claude-acp")
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

    // MARK: - Issue #799 PR1: HTML + Podcast backend round-trip

    /// AC.1: `ExtractionConfig` round-trips all three backend fields
    /// (PDF + HTML + Podcast) via save/load.
    @Test func htmlAndPodcastBackendsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .doclingServe
        config.htmlBackend = .tagBased
        config.podcastBackend = .appleTranscript
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.backend == .doclingServe)
        #expect(loaded.htmlBackend == .tagBased)
        #expect(loaded.podcastBackend == .appleTranscript)
    }

    /// AC.1 (negative case): both new fields round-trip nil when explicitly
    /// reset — the "prompt me" state must survive a save/load.
    @Test func htmlAndPodcastBackendsRoundTripNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(
            backend: .anthropic,
            htmlBackend: nil,
            podcastBackend: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.htmlBackend == nil)
        #expect(loaded.podcastBackend == nil)
    }

    /// AC.2: a legacy config file written before issue #799 PR1 shipped (no
    /// `htmlBackend` / `podcastBackend` keys) decodes both new fields as nil
    /// — the user is prompted to pick a backend on first extraction.
    /// Mirrors `acpProviderIdDecodesAsNilWhenAbsent` forward-compat contract.
    @Test func htmlAndPodcastBackendsDecodeAsNilWhenAbsent() throws {
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
    }

    /// Unknown raw values for the new backends degrade silently to nil —
    /// symmetric with `unknownBackendValueDegradesToLocalPdf2md` for the PDF
    /// `backend` field (a future/typo'd raw value doesn't crash the decode,
    /// the whole config still loads, the optional field just ends up nil). A
    /// typo'd `htmlBackend` therefore picks "prompt me" rather than rejecting
    /// the entire config — same resilient-decode philosophy as the existing
    /// fields, and the safer posture for a fresh-install user who hand-edited
    /// the JSON.
    @Test func unknownHtmlAndPodcastBackendValuesDegradeToNil() throws {
        let json = Data(#"""
        {"backend":"anthropic","htmlBackend":"whisper","podcastBackend":"rev_ai"}
        """#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
    }

    /// A config with the new backends also persists the existing PDF backend
    /// unchanged — the three fields coexist in one file without crosstalk.
    @Test func pdfBackendSurvivesWhenNewBackendsAreSet() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .acp
        config.acpProviderId = "claude-acp"
        config.htmlBackend = .defuddle
        config.podcastBackend = .appleTranscript
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded.backend == .acp)
        #expect(loaded.acpProviderId == "claude-acp")
        #expect(loaded.htmlBackend == .defuddle)
        #expect(loaded.podcastBackend == .appleTranscript)
    }

    @Test func logicalExtractorFieldsAreAbsentInLegacyConfig() throws {
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"anthropic"}"#.utf8))
        #expect(config.pdfExtractor == nil)
        #expect(config.htmlExtractor == nil)
    }

    @Test func builtInAndInstalledExtractorSelectionsRoundTrip() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.html"),
            registrationID: try ExtractorRegistrationID(validating: "article"))
        let config = ExtractionConfig(
            backend: .gemini,
            htmlBackend: .tagBased,
            pdfExtractor: .builtIn(.pdf(.localPdf2md)),
            htmlExtractor: .installed(logical))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ExtractionConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.backend == .gemini)
        #expect(decoded.htmlBackend == .tagBased)
    }

    @Test func malformedLogicalExtractorSelectionDegradesToNil() throws {
        let data = Data(#"{"backend":"anthropic","pdfExtractor":{"kind":"future"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ExtractionConfig.self, from: data)
        #expect(decoded.backend == .anthropic)
        #expect(decoded.pdfExtractor == nil)
    }

    @Test func legacyAndExplicitBuiltInSelectionsKeepTheirPrecedence() {
        let legacy = ExtractionConfig(backend: .anthropic, htmlBackend: .defuddle)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: legacy, activeRegistrations: []).selection == .pdfBuiltIn(.anthropic))
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: legacy, activeRegistrations: []).selection == .htmlBuiltIn(.defuddle))

        let explicit = ExtractionConfig(
            backend: .gemini,
            htmlBackend: .defuddle,
            pdfExtractor: .builtIn(.pdf(.doclingServe)),
            htmlExtractor: .builtIn(.html(.tagBased)))
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: explicit, activeRegistrations: []).selection == .pdfBuiltIn(.doclingServe))
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: explicit, activeRegistrations: []).selection == .htmlBuiltIn(.tagBased))
    }

    @Test func installedSelectionRanksBySemanticVersionThenExactRevision() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let low = try activeRegistration(logical: logical, version: "1.9.0", digestByte: 9, kinds: [.pdf])
        let prerelease = try activeRegistration(logical: logical, version: "2.0.0-beta.1", digestByte: 10, kinds: [.pdf])
        let highA = try activeRegistration(logical: logical, version: "2.0.0", digestByte: 1, kinds: [.pdf])
        let highB = try activeRegistration(logical: logical, version: "2.0.0+other", digestByte: 2, kinds: [.pdf])
        let config = ExtractionConfig(backend: .gemini, pdfExtractor: .installed(logical))
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
        let pdfConfig = ExtractionConfig(backend: .gemini, pdfExtractor: .installed(logical))
        let pdf = ExtractorSelectionResolver.resolvePDF(configuration: pdfConfig, activeRegistrations: [htmlOnly])
        #expect(pdf.selection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(pdf.diagnostic == .unavailableInstalled(logical))
        #expect(pdfConfig.pdfExtractor == .installed(logical))

        let htmlConfig = ExtractionConfig(htmlBackend: .defuddle, htmlExtractor: .installed(logical))
        let html = ExtractorSelectionResolver.resolveHTML(configuration: htmlConfig, activeRegistrations: [])
        #expect(html.selection == .unavailableInstalled(kind: .html, reference: logical))
        #expect(html.diagnostic == .unavailableInstalled(logical))
        #expect(htmlConfig.htmlExtractor == .installed(logical))
    }

    // MARK: - Route selections (typed MIME routes)

    /// AC.2: a config file without `routeExtractors` decodes to an empty record
    /// list, the route accessors fall through to the legacy reference fields,
    /// and PDF/HTML resolution is byte-for-byte the same decision the pre-route
    /// entry points produced.
    @Test func legacyPDFAndHTMLFieldsResolveWithoutRouteRecords() throws {
        let json = Data(#"""
        {"backend":"gemini","htmlBackend":"defuddle","pdfExtractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}},"htmlExtractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        let inCode = ExtractionConfig(
            backend: .gemini,
            htmlBackend: .defuddle,
            pdfExtractor: .builtIn(.pdf(.acp)),
            htmlExtractor: .builtIn(.html(.tagBased)))
        #expect(decoded == inCode)
        #expect(decoded.routeExtractors.isEmpty)
        #expect(decoded.extractorSelection(for: .canonicalPDF) == decoded.pdfExtractor)
        #expect(decoded.extractorSelection(for: .canonicalHTML) == decoded.htmlExtractor)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: decoded, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolvePDF(configuration: inCode, activeRegistrations: []))
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: decoded, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolveHTML(configuration: inCode, activeRegistrations: []))
    }

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
        var first = ExtractionConfig(backend: .gemini)
        first.setExtractorSelection(.installed(logical), for: .canonicalHTML)
        first.setExtractorSelection(.builtIn(.pdf(.doclingServe)), for: .canonicalPDF)
        first.setExtractorSelection(.installed(logical), for: future.route)
        var second = ExtractionConfig(backend: .gemini)
        second.setExtractorSelection(.installed(logical), for: future.route)
        second.setExtractorSelection(.builtIn(.pdf(.doclingServe)), for: .canonicalPDF)
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
        var config = ExtractionConfig(backend: .gemini, routeExtractors: [htmlRecord])

        config.setExtractorSelection(.builtIn(.pdf(.acp)), for: .canonicalPDF)
        #expect(config.routeExtractors.count == 2)
        #expect(config.routeExtractors.contains { $0.route == .canonicalPDF })

        config.setExtractorSelection(.builtIn(.pdf(.doclingServe)), for: .canonicalPDF)
        #expect(config.routeExtractors.count == 2)
        #expect(config.extractorSelection(for: .canonicalHTML) == .installed(htmlLogical))
        #expect(config.extractorSelection(for: .canonicalPDF) == .builtIn(.pdf(.doclingServe)))

        config.setExtractorSelection(nil, for: .canonicalPDF)
        #expect(config.routeExtractors.count == 1)
        #expect(config.extractorSelection(for: .canonicalHTML) == .installed(htmlLogical))
        #expect(config.extractorSelection(for: .canonicalPDF) == nil)
    }

    /// AC.3 + AC.11 persistence half: a canonical route write dual-writes the
    /// matching legacy reference field so old builds reading `pdfExtractor` /
    /// `htmlExtractor` resolve the same selection; removal clears both. The
    /// older `backend` / `htmlBackend` fields stay owned by the Settings
    /// mapping and are not rewritten here.
    @Test func canonicalRouteWritesKeepLegacyFieldsTruthful() throws {
        var config = ExtractionConfig(backend: .anthropic, htmlBackend: .defuddle)

        config.setExtractorSelection(.builtIn(.pdf(.acp)), for: .canonicalPDF)
        #expect(config.pdfExtractor == .builtIn(.pdf(.acp)))
        #expect(config.backend == .anthropic)

        config.setExtractorSelection(.builtIn(.html(.tagBased)), for: .canonicalHTML)
        #expect(config.htmlExtractor == .builtIn(.html(.tagBased)))
        #expect(config.htmlBackend == .defuddle)

        config.setExtractorSelection(nil, for: .canonicalPDF)
        #expect(config.pdfExtractor == nil)
        config.setExtractorSelection(nil, for: .canonicalHTML)
        #expect(config.htmlExtractor == nil)

        // A non-canonical route record never touches legacy fields.
        let future = try ExtractorRouteID(kind: .pdf, mimeType: ExtractorMIMEType(validating: "application/epub+zip"))
        config.setExtractorSelection(.builtIn(.pdf(.acp)), for: future)
        #expect(config.pdfExtractor == nil)
        #expect(config.routeExtractors.count == 1)

        // Round-trips through disk.
        let dir = tempDirectory()
        try config.save(to: dir)
        #expect(ExtractionConfig.load(from: dir) == config)
    }

    /// DOCX route persistence (AC.6): an installed selection round-trips
    /// through the canonicalDOCX route record and dual-writes the
    /// `docxExtractor` field (which has no older legacy layer beneath it),
    /// and removal clears both.
    @Test func docxRouteSelectionRoundTripsAndDualWrites() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.docx"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        var config = ExtractionConfig(backend: .localPdf2md)

        config.setExtractorSelection(.installed(logical), for: .canonicalDOCX)
        #expect(config.docxExtractor == .installed(logical))
        #expect(config.routeExtractors.contains { $0.route == .canonicalDOCX })
        #expect(config.extractorSelection(for: .canonicalDOCX) == .installed(logical))
        // The legacy PDF/HTML fields are untouched.
        #expect(config.pdfExtractor == nil)
        #expect(config.htmlExtractor == nil)

        // Round-trips through disk.
        let dir = tempDirectory()
        try config.save(to: dir)
        #expect(ExtractionConfig.load(from: dir) == config)

        config.setExtractorSelection(nil, for: .canonicalDOCX)
        #expect(config.docxExtractor == nil)
        #expect(config.extractorSelection(for: .canonicalDOCX) == nil)
        #expect(config.routeExtractors.isEmpty)
    }

    /// DOCX degrade path (AC.6): a config file written before the
    /// `docxExtractor` key existed decodes with the field nil, and a
    /// malformed value degrades to nil without rejecting the file.
    @Test func docxExtractorFieldDegradesToNil() throws {
        let absent = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"anthropic"}"#.utf8))
        #expect(absent.docxExtractor == nil)

        let malformed = try JSONDecoder().decode(ExtractionConfig.self, from: Data(#"{"backend":"anthropic","docxExtractor":{"kind":"future"}}"#.utf8))
        #expect(malformed.docxExtractor == nil)
        #expect(malformed.backend == .anthropic)
    }

    /// DOCX route resolution (AC.7): the resolver reports `.noDOCXSelection`
    /// with no saved selection, an installed selection with an active
    /// registration resolves to it, and an inactive selection surfaces the
    /// redacted unavailable diagnostic. A cross-kind builtIn stray degrades
    /// to "no selection" (there is no built-in DOCX backend to resolve to).
    @Test func docxRouteSelectionResolves() throws {
        // No selection → .noDOCXSelection (execution defaults to the
        // reviewed lineage at the engine layer).
        let empty = ExtractionConfig()
        #expect(ExtractorSelectionResolver.resolveDOCX(configuration: empty, activeRegistrations: []).selection == .noDOCXSelection)

        // Active registration → the exact reference.
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.docx"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let active = try activeRegistration(logical: logical, version: "1.0.0", digestByte: 3, kinds: [.docx])
        let config = ExtractionConfig(docxExtractor: .installed(logical))
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

        // A builtIn stray degrades to no selection instead of a foreign backend.
        let stray = ExtractionConfig(docxExtractor: .builtIn(.html(.tagBased)))
        #expect(ExtractorSelectionResolver.resolveDOCX(configuration: stray, activeRegistrations: [active]).selection == .noDOCXSelection)

        // The route-aware entry dispatches canonicalDOCX.
        #expect(ExtractorSelectionResolver.resolve(
            .canonicalDOCX,
            configuration: empty,
            activeRegistrations: [])?.selection == .noDOCXSelection)
    }

    /// AC.2/AC.3: duplicate records for one route in a hand-edited file resolve
    /// to the same single record regardless of their order in the file, with
    /// malformed records dropped through the logged decode seam.
    @Test func duplicateRouteRecordsResolveDeterministicallyAndLogBoundedDiagnostic() throws {
        let builtInRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}}}
        """#
        let installedRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"installed","installed":{"packageID":"org.example.pdf","registrationID":"main"}}}
        """#
        let htmlRecord = #"""
        {"route":{"kind":"html","mimeType":"text/html"},"extractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#
        let firstOrder = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(builtInRecord),\#(installedRecord),\#(htmlRecord)]}"#.utf8))
        let secondOrder = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(installedRecord),\#(htmlRecord),\#(builtInRecord)]}"#.utf8))
        #expect(firstOrder == secondOrder)
        #expect(firstOrder.routeExtractors.count == 2)

        // The winner is the canonically-greatest record for the route (here the
        // installed reference, which sorts after the built-in one).
        #expect(firstOrder.extractorSelection(for: .canonicalPDF) ==
            .installed(LogicalExtractorReference(
                packageID: try ExtractorPackageID(validating: "org.example.pdf"),
                registrationID: try ExtractorRegistrationID(validating: "main"))))
        #expect(firstOrder.extractorSelection(for: .canonicalHTML) == .builtIn(.html(.tagBased)))

        // A wholly malformed array and a malformed record both degrade without
        // throwing, keeping whatever records remain valid.
        let malformedArray = try JSONDecoder().decode(
            ExtractionConfig.self, from: Data(#"{"backend":"gemini","routeExtractors":"nope"}"#.utf8))
        #expect(malformedArray.routeExtractors.isEmpty)
        let malformedRecord = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(builtInRecord),{"route":{"kind":"pdf","mimeType":"bogus"}}]}"#.utf8))
        #expect(malformedRecord.routeExtractors.count == 1)
        #expect(malformedRecord.extractorSelection(for: .canonicalPDF) == .builtIn(.pdf(.acp)))
    }

    /// A malformed record must not swallow later valid records: Foundation's
    /// JSONDecoder leaves an unkeyed container's index in place after a failed
    /// decode, so the decode seam consumes the bad element and continues.
    @Test func malformedRecordDoesNotTruncateLaterValidRecords() throws {
        let builtInRecord = #"""
        {"route":{"kind":"pdf","mimeType":"application/pdf"},"extractor":{"kind":"builtIn","builtIn":{"kind":"pdf","backend":"acp"}}}
        """#
        let htmlRecord = #"""
        {"route":{"kind":"html","mimeType":"text/html"},"extractor":{"kind":"builtIn","builtIn":{"kind":"html","backend":"tagBased"}}}
        """#
        let malformed = #"{"route":{"kind":"pdf","mimeType":"bogus"}}"#

        // Malformed record first.
        let badFirst = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(malformed),\#(builtInRecord),\#(htmlRecord)]}"#.utf8))
        #expect(badFirst.routeExtractors.count == 2)
        #expect(badFirst.extractorSelection(for: .canonicalPDF) == .builtIn(.pdf(.acp)))
        #expect(badFirst.extractorSelection(for: .canonicalHTML) == .builtIn(.html(.tagBased)))

        // Malformed record in the middle.
        let badMiddle = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(builtInRecord),\#(malformed),\#(htmlRecord)]}"#.utf8))
        #expect(badMiddle == badFirst)

        // Multiple malformed records still terminate.
        let allBad = try JSONDecoder().decode(
            ExtractionConfig.self,
            from: Data(#"{"backend":"gemini","routeExtractors":[\#(malformed),\#(malformed)]}"#.utf8))
        #expect(allBad.routeExtractors.isEmpty)
    }

    /// AC.4: PDF/HTML resolution produces the same decision whether a selection
    /// is expressed as a legacy reference field or an equivalent route record,
    /// and a route record overrides a conflicting legacy field. Unavailable
    /// installed selections keep the logical identity and diagnostic.
    @Test func routeResolutionMatchesLegacyEntryPoints() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let pdfOnly = try activeRegistration(logical: logical, version: "1.0.0", digestByte: 3, kinds: [.pdf])
        var config = ExtractionConfig(backend: .acp, htmlBackend: .tagBased, pdfExtractor: .builtIn(.pdf(.localPdf2md)))

        // Legacy reference and equivalent route record resolve identically.
        let legacyPDF = ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly])
        #expect(legacyPDF.selection == .pdfBuiltIn(.localPdf2md))
        config.setExtractorSelection(.builtIn(.pdf(.localPdf2md)), for: .canonicalPDF)
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly]) == legacyPDF)

        // A route record overrides a conflicting legacy field.
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let recordPDF = ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: [pdfOnly])
        #expect(recordPDF.selection == .installed(kind: .pdf, reference: pdfOnly.reference))
        #expect(recordPDF.diagnostic == nil)

        // An unavailable installed route record stays unavailable with the same
        // diagnostic as the equivalent legacy selection.
        config.pdfExtractor = nil
        let unavailableRecord = config
        let unavailablePDF = ExtractorSelectionResolver.resolvePDF(configuration: unavailableRecord, activeRegistrations: [])
        #expect(unavailablePDF.selection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(unavailablePDF.diagnostic == .unavailableInstalled(logical))
        let legacyUnavailable = ExtractionConfig(
            backend: .acp,
            htmlBackend: .tagBased,
            pdfExtractor: .installed(logical))
        #expect(ExtractorSelectionResolver.resolvePDF(configuration: legacyUnavailable, activeRegistrations: []) == unavailablePDF)

        // HTML: route record overrides htmlBackend; removal restores the
        // legacy path exactly.
        var htmlConfig = ExtractionConfig(backend: .gemini, htmlBackend: .defuddle)
        htmlConfig.setExtractorSelection(.builtIn(.html(.tagBased)), for: .canonicalHTML)
        let recordHTML = ExtractorSelectionResolver.resolveHTML(configuration: htmlConfig, activeRegistrations: [])
        #expect(recordHTML.selection == .htmlBuiltIn(.tagBased))
        #expect(recordHTML == ExtractorSelectionResolver.resolveHTML(
            configuration: ExtractionConfig(backend: .gemini, htmlExtractor: .builtIn(.html(.tagBased))),
            activeRegistrations: []))
        htmlConfig.setExtractorSelection(nil, for: .canonicalHTML)
        #expect(ExtractorSelectionResolver.resolveHTML(configuration: htmlConfig, activeRegistrations: []).selection == .htmlBuiltIn(.defuddle))
    }

    /// The route-aware entry point agrees with the per-kind entry points on the
    /// canonical routes and declines routes without a host execution path.
    @Test func routeAwareEntryMatchesPerKindEntryPoints() throws {
        let config = ExtractionConfig(backend: .anthropic, htmlBackend: .defuddle)
        #expect(ExtractorSelectionResolver.resolve(.canonicalPDF, configuration: config, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolvePDF(configuration: config, activeRegistrations: []))
        #expect(ExtractorSelectionResolver.resolve(.canonicalHTML, configuration: config, activeRegistrations: []) ==
            ExtractorSelectionResolver.resolveHTML(configuration: config, activeRegistrations: []))
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
