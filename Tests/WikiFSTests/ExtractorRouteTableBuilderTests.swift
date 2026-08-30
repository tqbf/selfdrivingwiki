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
        sourceCategory: ExtractorRouteSourceCategory = .installedPackage,
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
            sourceCategory: sourceCategory,
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
        var config = ExtractionConfig()
        config.setExtractorSelection(ExtractorRouteHostCatalog.acpReference, for: futureRoute)
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
        // Host PDF + HTML + DOCX, plus the saved future route. The HTML
        // registration covers the canonical HTML route and adds no new row.
        #expect(rows.count == 4)
        #expect(rows.map(\.route) == [.canonicalPDF, .canonicalHTML, .canonicalDOCX, futureRoute])
        #expect(rows[3].savedSelection == ExtractorRouteHostCatalog.acpReference)
        // No host execution exists for a future route.
        #expect(rows[3].resolvedSelection == nil)
    }

    @Test func rowsSortDeterministically() throws {
        func buildInput() throws -> ExtractorRouteTableBuilder.Input {
            ExtractorRouteTableBuilder.Input(
                configuration: ExtractionConfig(),
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
        #expect(first.map(\.route).prefix(3) == [.canonicalPDF, .canonicalHTML, .canonicalDOCX])
        #expect(first.dropFirst(3).map(\.route) == first.dropFirst(3).map(\.route).sorted())
    }

    @Test func unknownMIMEUsesStableGenericLabel() throws {
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(),
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
            configuration: ExtractionConfig(),
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

    @Test func activeReviewedPackageAppearsOnceFromCatalogProjection() throws {
        let reviewed = try snapshot(
            packageID: ProcessExtractionServices.reviewedPDFLogical.packageID.rawValue,
            version: "1.0.0",
            digestHex: digest(16),
            registrationID: ProcessExtractionServices.reviewedPDFLogical.registrationID.rawValue,
            displayName: "pdf2md",
            sourceCategory: .reviewedPackage,
            kinds: [.pdf],
            mimeTypes: ["application/pdf"])
        let rows = ExtractorRouteTableBuilder.build(.init(
            configuration: ExtractionConfig(),
            registrations: [reviewed],
            availableRegistrations: [reviewed]))
        let pdf = try #require(rows.first { $0.route == .canonicalPDF })
        let matches = pdf.choices.filter {
            $0.reference == .installed(ProcessExtractionServices.reviewedPDFLogical)
        }
        #expect(matches.count == 1)
        #expect(matches.first?.category == .reviewedPackage)
    }

    /// DOCX route scenario: an active reviewed docx2md registration projects
    /// onto the canonical DOCX route as a single reviewed-package choice,
    /// alongside the nil "no default" host choice. The host never hardcodes
    /// the package row.
    @Test func activeReviewedDocxPackageAppearsOnTheDocxRoute() throws {
        let reviewed = try snapshot(
            packageID: ProcessExtractionServices.reviewedDOCXLogical.packageID.rawValue,
            version: "1.0.0",
            digestHex: digest(17),
            registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID.rawValue,
            displayName: "docx2md Document",
            sourceCategory: .reviewedPackage,
            kinds: [.docx],
            mimeTypes: ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
            extensions: ["docx"])
        let rows = ExtractorRouteTableBuilder.build(.init(
            configuration: ExtractionConfig(),
            registrations: [reviewed],
            availableRegistrations: [reviewed]))
        let docx = try #require(rows.first { $0.route == .canonicalDOCX })
        // Explicit "no default" host choice + the registration-derived package row.
        #expect(docx.choices.count == 2)
        #expect(docx.choices[0].reference == .none)
        let matches = docx.choices.filter {
            $0.reference == .installed(ProcessExtractionServices.reviewedDOCXLogical)
        }
        #expect(matches.count == 1)
        #expect(matches.first?.category == .reviewedPackage)
        // With no saved selection, the DOCX route is not blocked — execution
        // defaults to the reviewed lineage.
        #expect(docx.savedSelection == nil)
    }

    // MARK: - AC.8: stale selections stay visible and blocked

    @Test func staleSelectionIsPreservedAndUnavailable() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig()
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
        // The unavailable identity remains resolved and both routes are blocked.
        #expect(pdf?.resolvedSelection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(html?.resolvedSelection == .unavailableInstalled(kind: .html, reference: logical))
        #expect(pdf?.status == .packageNotInstalled)
        #expect(html?.status == .packageNotInstalled)
    }

    @Test func waitingAndFailedSelectionsReportLifecycleStatus() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pending"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig()
        config.setExtractorSelection(.installed(logical), for: .canonicalPDF)

        let waiting = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [],
            installedRevisionIDs: [],
            waitingRevisionIDs: [ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.pending"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: try ExtractorPackageDigest(hex: digest(7)))]))
        #expect(waiting.first?.status == .waitingForHostActivation)

        let presentButUnavailable = ExtractorRouteTableBuilder.build(ExtractorRouteTableBuilder.Input(
            configuration: config,
            registrations: [],
            installedRevisionIDs: [ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.pending"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: try ExtractorPackageDigest(hex: digest(7)))],
            waitingRevisionIDs: []))
        #expect(presentButUnavailable.first?.status == .unavailableSelection)
    }

    /// A stale saved installed selection stays selectable in its row's picker:
    /// the builder inserts one unavailable choice carrying the saved reference.
    @Test func staleSelectionRemainsSelectableAsUnavailableChoice() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig()
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
    /// must not resolve on that route. It stays an unavailable stale choice,
    /// and the row reports an unavailable selection.
    @Test func incompatibleMIMERegistrationDoesNotResolveOnRoute() throws {
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.mime"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        var config = ExtractionConfig()
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
        #expect(pdf.resolvedSelection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(pdf.status == .packageNotInstalled)
        // The package does contribute its own epub route row.
        #expect(rows.contains { $0.route.mimeType.rawValue == "application/epub+zip" })
    }

    // MARK: - AC.9: current choice matrix

    @Test func currentRouteChoiceMatrix() throws {
        let active = [
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
        ]
        let available = active + [
            try snapshot(
                packageID: ProcessExtractionServices.reviewedPDFLogical.packageID.rawValue,
                version: "1.0.0",
                digestHex: digest(13),
                registrationID: ProcessExtractionServices.reviewedPDFLogical.registrationID.rawValue,
                displayName: "pdf2md",
                sourceCategory: .reviewedPackage,
                kinds: [.pdf],
                mimeTypes: ["application/pdf"]),
            try snapshot(
                packageID: ProcessExtractionServices.reviewedDoclingLogical.packageID.rawValue,
                version: "1.0.0",
                digestHex: digest(14),
                registrationID: ProcessExtractionServices.reviewedDoclingLogical.registrationID.rawValue,
                displayName: "Docling Serve",
                sourceCategory: .reviewedPackage,
                kinds: [.pdf],
                mimeTypes: ["application/pdf"]),
            try snapshot(
                packageID: ProcessExtractionServices.reviewedHTMLLogical.packageID.rawValue,
                version: "1.0.0",
                digestHex: digest(15),
                registrationID: ProcessExtractionServices.reviewedHTMLLogical.registrationID.rawValue,
                displayName: "Defuddle",
                sourceCategory: .reviewedPackage,
                kinds: [.html],
                mimeTypes: ["text/html"]),
        ]
        let input = ExtractorRouteTableBuilder.Input(
            configuration: ExtractionConfig(),
            registrations: active,
            availableRegistrations: available)
        let rows = ExtractorRouteTableBuilder.build(input)
        let pdf = rows.first { $0.route == .canonicalPDF }
        let html = rows.first { $0.route == .canonicalHTML }

        // PDF: reviewed packages and installed packages sort by package ID,
        // followed by the host-owned ACP service.
        #expect(pdf?.choices.map { "\($0.displayName)|\($0.category.rawValue)" } == [
            "Docling Serve|reviewed-package",
            "pdf2md|reviewed-package",
            "PDF Package|installed-package",
            "ACP Provider|connected-service",
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
            configuration: ExtractionConfig(),
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
            configuration: ExtractionConfig(),
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
