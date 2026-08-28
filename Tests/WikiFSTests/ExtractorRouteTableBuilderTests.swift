#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
import WikiFSTypes

/// Pure `ExtractorRouteTableBuilder` coverage: row union, deterministic
/// ordering, version deduplication, stale-selection visibility, and the
/// current choice matrix.
@Suite("Extractor route table builder")
struct ExtractorRouteTableBuilderTests {

    // MARK: - Helpers

    private func mime(_ raw: String) throws -> ExtractorMIMEType {
        try ExtractorMIMEType(validating: raw)
    }

    private func snapshot(
        packageID: String,
        version: String,
        digestHex: String,
        registrationID: String = "main",
        displayName: String,
        packageName: String = "Example Package",
        kinds: Set<ExtractorKind>,
        mimeTypes: [String],
        extensions: Set<String> = []
    ) throws -> ExtractorRouteRegistrationSnapshot {
        try ExtractorRouteRegistrationSnapshot(
            reference: ExtractorReference(
                revision: ExtractorPackageRevisionID(
                    packageID: ExtractorPackageID(validating: packageID),
                    version: ExtractorPackageVersion(validating: version),
                    digest: ExtractorPackageDigest(hex: digestHex)),
                registrationID: ExtractorRegistrationID(validating: registrationID)),
            displayName: displayName,
            packageName: packageName,
            kinds: kinds,
            mimeTypes: Set(mimeTypes.map { try ExtractorMIMEType(validating: $0) }),
            filenameExtensions: Set(extensions.compactMap { ExtractorFileExtension(rawValue: $0) }))
    }

    private func digest(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    // MARK: - AC.6: union and determinism

    @Test func unionsHostActiveAndSavedRoutes() throws {
        let futureRoute = try ExtractorRouteID(kind: .pdf, mimeType: mime("application/epub+zip"))
        var config = ExtractionConfig(backend: .gemini)
        config.setExtractorSelection(.builtIn(.pdf(.acp)), for: futureRoute)
        let input = ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [
                try snapshot(
                    packageID: "org.example.html",
                    version: "1.0.0",
                    digestHex: digest(1),
                    registrationID: "article",
                    displayName: "Article Extractor",
                    kinds: [.html],
                    mimeTypes: ["text/html"]),
            ])
        let rows = ExtractorRouteTableBuilder.build(input)
        // Host PDF + HTML, plus the saved future route. The HTML registration
        // covers the canonical HTML route and adds no new row.
        #expect(rows.count == 3)
        #expect(rows.map(\.route) == [.canonicalPDF, .canonicalHTML, futureRoute])
        #expect(rows[2].savedSelection == .builtIn(.pdf(.acp)))
        // No host execution exists for a future route.
        #expect(rows[2].resolvedSelection == nil)
    }

    @Test func rowsSortDeterministically() throws {
        func buildInput() throws -> ExtractorRouteTableBuilder.Input {
            ExtractorRouteTableBuilder.Input(
                configuration: ExtractionConfig(backend: .acp),
                registrations: [
                    try snapshot(
                        packageID: "org.example.multi",
                        version: "1.0.0",
                        digestHex: digest(2),
                        displayName: "Multi",
                        kinds: [.html, .pdf],
                        mimeTypes: ["application/xhtml+xml", "application/pdf", "text/html"]),
                ])
        }
        let first = ExtractorRouteTableBuilder.build(try buildInput())
        let second = ExtractorRouteTableBuilder.build(try buildInput())
        // Host routes first in host order, then registration-derived routes in
        // typed route order; identical inputs produce identical rows.
        #expect(first.map(\.route) == second.map(\.route))
        #expect(first == second)
        #expect(first.map(\.route).prefix(2) == [.canonicalPDF, .canonicalHTML])
        #expect(first.dropFirst(2).map(\.route) == first.dropFirst(2).map(\.route).sorted())
    }

    @Test func unknownMIMEUsesStableFallbackLabel() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(backend: .acp),
            registrations: [
                try snapshot(
                    packageID: "org.example.x",
                    version: "1.0.0",
                    digestHex: digest(3),
                    displayName: "X Tracts",
                    kinds: [.pdf],
                    mimeTypes: ["application/vnd.exam+x"]),
            ])
        let rows = ExtractorRouteTableBuilder.build(input)
        guard let extra = rows.first(where: { $0.route.mimeType.rawValue == "application/vnd.exam+x" }) else {
            Issue.record("Expected a row for the registration-declared MIME type")
            return
        }
        #expect(extra.descriptor.displayName == "application/vnd.exam+x")
        #expect(extra.descriptor.systemImage == nil)
        #expect(extra.choices.count == 1)
        #expect(extra.choices[0].displayName == "X Tracts")
    }

    // MARK: - AC.7: exact version deduplication

    @Test func multipleExactVersionsProduceOneLogicalChoice() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(backend: .acp),
            registrations: [
                try snapshot(
                    packageID: "org.example.pdf",
                    version: "1.0.0",
                    digestHex: digest(4),
                    displayName: "Main",
                    kinds: [.pdf],
                    mimeTypes: ["application/pdf"]),
                try snapshot(
                    packageID: "org.example.pdf",
                    version: "2.0.0",
                    digestHex: digest(5),
                    displayName: "Main",
                    kinds: [.pdf],
                    mimeTypes: ["application/pdf"]),
                try snapshot(
                    packageID: "org.example.pdf",
                    version: "2.0.0",
                    digestHex: digest(6),
                    displayName: "Main",
                    kinds: [.pdf],
                    mimeTypes: ["application/pdf"]),
            ])
        let pdf = ExtractorRouteTableBuilder.build(input).first { $0.route == .canonicalPDF }
        let packageChoices = pdf?.choices.filter { $0.category == .installedPackage } ?? []
        // Three exact registrations, one logical choice showing the highest revision.
        #expect(packageChoices.count == 1)
        #expect(packageChoices[0].exactSummary?.hasPrefix("2.0.0 · \(digest(6).prefix(12))") == true)
    }

    // MARK: - AC.8: stale selections stay visible with fallback status

    @Test func staleInstalledSelectionRemainsVisibleWithFallback() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig(backend: .acp, htmlBackend: .defuddle)
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        config.setExtractorSelection(.installed(logical), for: .canonicalHTML)
        let rows = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: []))
        let pdf = rows.first { $0.route == .canonicalPDF }
        let html = rows.first { $0.route == .canonicalHTML }
        // The saved choices remain selected and visible…
        #expect(pdf?.savedSelection == .installed(logical))
        #expect(html?.savedSelection == .installed(logical))
        // …while the fixed fallbacks are what resolve.
        #expect(pdf?.resolvedSelection == .pdfBuiltIn(.localPdf2md))
        #expect(html?.resolvedSelection == .htmlBuiltIn(.tagBased))
        #expect(pdf?.status == .usingFallback(description: "Bundled pdf2md extraction"))
        #expect(html?.status == .usingFallback(description: "Tag-based text extraction"))
    }

    @Test func waitingAndFailedSelectionsReportLifecycleStatus() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pending"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig(backend: .acp)
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)

        let waiting = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [],
            failedPackageIDs: [],
            waitingRevisionIDs: [ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.pending"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: try ExtractorPackageDigest(hex: digest(7)))]))
        #expect(waiting.first?.status == .waitingForHostService)

        let failed = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [],
            failedPackageIDs: ["org.example.pending"],
            waitingRevisionIDs: []))
        #expect(failed.first?.status == .failedActivation)
    }

    /// A stale saved installed selection stays selectable in its row's picker:
    /// the builder inserts one unavailable choice carrying the saved reference.
    @Test func staleSelectionRemainsSelectableAsUnavailableChoice() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig(backend: .acp)
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let pdf = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [])).first { $0.route == .canonicalPDF }
        let stale = pdf?.choices.first { $0.category == .unavailable }
        #expect(stale?.reference == .installed(logical))
        #expect(stale?.displayName == "org.example.gone")
        #expect(pdf?.choices.contains { $0.category == .installedPackage } == false)
    }

    /// A logical registration active for the KIND but not the route's MIME
    /// must not resolve on that route: it stays an unavailable stale choice,
    /// and the row reports the fixed fallback instead of Available.
    @Test func incompatibleMIMERegistrationDoesNotResolveOnRoute() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.mime"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig(backend: .acp)
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)
        let rows = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [
                // Same kind (pdf), same logical identity, but a different MIME.
                try snapshot(
                    packageID: "org.example.mime",
                    version: "1.0.0",
                    digestHex: digest(12),
                    displayName: "Mime Package",
                    kinds: [.pdf],
                    mimeTypes: ["application/epub+zip"]),
            ]))
        let pdf = try #require(rows.first { $0.route == .canonicalPDF })
        #expect(pdf.choices.contains { $0.category == .installedPackage } == false)
        #expect(pdf.savedSelection == .installed(logical))
        #expect(pdf.resolvedSelection == .pdfBuiltIn(.localPdf2md))
        #expect(pdf.status == .usingFallback(description: "Bundled pdf2md extraction"))
        // The package does contribute its own epub route row.
        #expect(rows.contains { $0.route.mimeType.rawValue == "application/epub+zip" })
    }

    // MARK: - AC.9: current choice matrix

    @Test func currentRouteChoiceMatrix() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(backend: .acp),
            registrations: [
                try snapshot(
                    packageID: "org.example.pdf",
                    version: "1.0.0",
                    digestHex: digest(9),
                    registrationID: "pdfmain",
                    displayName: "PDF Package",
                    kinds: [.pdf],
                    mimeTypes: ["application/pdf"]),
                try snapshot(
                    packageID: "org.example.html",
                    version: "1.0.0",
                    digestHex: digest(10),
                    registrationID: "htmlmain",
                    displayName: "HTML Package",
                    kinds: [.html],
                    mimeTypes: ["text/html"]),
            ])
        let rows = ExtractorRouteTableBuilder.build(input)
        let pdf = rows.first { $0.route == .canonicalPDF }
        let html = rows.first { $0.route == .canonicalHTML }

        // PDF: reviewed pdf2md, installed PDF packages, ACP, Docling — in that order.
        #expect(pdf?.choices.map { "\($0.displayName)|\($0.category.rawValue)" } == [
            "pdf2md|reviewed-package",
            "PDF Package|installed-package",
            "ACP Provider|connected-service",
            "Docling Serve|connected-service",
        ])
        // HTML: prompt, reviewed Defuddle, installed HTML packages, tag-based.
        #expect(html?.choices.map { "\($0.displayName)|\($0.category.rawValue)" } == [
            "No default (ask each time)|prompt",
            "Defuddle|reviewed-package",
            "HTML Package|installed-package",
            "Tag-based|built-in",
        ])
    }

    /// Source-contract guard: the legacy direct Anthropic and Gemini API
    /// choices never re-enter the route table.
    @Test func directModelAPIChoicesRemainAbsent() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(backend: .anthropic),
            registrations: [])
        let rows = ExtractorRouteTableBuilder.build(input)
        for row in rows {
            for choice in row.choices {
                let payload = String(describing: choice)
                #expect(payload.contains("anthropic") == false)
                #expect(payload.contains("gemini") == false)
                #expect(choice.category != .unavailable)
            }
        }
    }

    /// The reviewed packages attach to their canonical routes only — a
    /// registration-declared future route never inherits host choices.
    @Test func reviewedChoicesStayOnCanonicalRoutes() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(backend: .acp),
            registrations: [
                try snapshot(
                    packageID: "org.example.pdf",
                    version: "1.0.0",
                    digestHex: digest(11),
                    displayName: "Main",
                    kinds: [.pdf],
                    mimeTypes: ["application/epub+zip"]),
            ])
        let rows = ExtractorRouteTableBuilder.build(input)
        let epub = rows.first { $0.route.mimeType.rawValue == "application/epub+zip" }
        #expect(epub?.choices.contains { $0.category == .reviewedPackage } == false)
        #expect(epub?.choices.contains { $0.category == .connectedService } == false)
    }
}
#endif
