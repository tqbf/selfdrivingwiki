#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine

/// The legacy `localPdf2md` and `defuddle` selections map to the reviewed
/// package lineages when those lineages are active, and only to them. An
/// unavailable explicit package selection fails closed. A third-party package
/// with a similar registration cannot capture the default path.
@Suite("Reviewed legacy selection mapping", .serialized, .timeLimit(.minutes(5)))
struct ReviewedLegacySelectionMappingTests {
    /// The default configuration selects `localPdf2md`. With the reviewed
    /// package active, that selection serves through the package adapter.
    @Test func defaultPDFSelectionUsesTheReviewedPackage() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        let preparation = try await services.prepare(backendOverride: nil)
        #expect(preparation.technique == "package:org.selfdrivingwiki.pdf2md")
        await services.shutdown()
    }

    /// Without the reviewed package, the shipped default (the reviewed pdf2md
    /// lineage from the bundled policy) fails closed with the redacted
    /// named-lineage diagnostic.
    @Test func defaultPDFSelectionIsUnavailableWithoutTheReviewedPackage() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: environment.root)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        await #expect(
            throws: ExtractionServicesError.selectedExtractorUnavailable(
                route: .canonicalPDF,
                reference: ProcessExtractionServices.reviewedPDFLogical)
        ) {
            try await services.prepare(backendOverride: nil)
        }
        await services.shutdown()
    }

    /// The explicit `defuddle` HTML selection serves through the reviewed
    /// Defuddle package when it is active. Tag-based extraction does not map.
    @Test func defuddleHTMLSelectionUsesTheReviewedPackage() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        let report = await context.reconcileNow()
        #expect(report.failedPackages.isEmpty)
        #expect(await context.registry.installedMatches(kind: .html).count == 1)
        let htmlMatch = try #require(await context.registry.resolveInstalled(
            ProcessExtractionServices.reviewedHTMLLogical, kind: .html))
        do {
            _ = try await htmlMatch.backend.make()
        } catch {
            Issue.record("HTML package factory failed: \\(error)")
        }
        // A migrated legacy `defuddle` selection is a host reference whose
        // adapter ID remaps to the reviewed package lineage at execution.
        let services = try await ProcessExtractionServices.assemble(
            context: context,
            input: environment.input(htmlSelection: ExtractorRouteHostCatalog.legacyDefuddleReference))

        let extractor = try await services.prepareHTML()
        #expect(extractor is ProcessPackageHTMLExtractor)
        await services.shutdown()
    }

    /// An empty DOCX selection resolves to the reviewed docx2md lineage.
    @Test func defaultDOCXSelectionUsesTheReviewedPackage() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        let extractor = try await services.prepareDOCX()
        #expect(extractor.packageProvenance.revision == ReviewedExtractorPackages.docx2md.revision)
        await services.shutdown()
    }

    /// An unavailable installed DOCX selection remains selected and blocks the route.
    @Test func unavailableInstalledDOCXSelectionFailsClosed() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let unavailable = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.thirdparty"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let services = try await ProcessExtractionServices.assemble(
            context: context,
            input: environment.input(docxSelection: .installed(unavailable)))

        await #expect(
            throws: ExtractionServicesError.selectedExtractorUnavailable(
                route: .canonicalDOCX,
                reference: unavailable)
        ) {
            try await services.prepareDOCX()
        }
        await services.shutdown()
    }

    /// An unavailable installed PDF selection remains selected and blocks the
    /// route. The reviewed pdf2md package must not run automatically.
    @Test func unavailableInstalledPDFSelectionFailsClosed() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let unavailable = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.thirdparty"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let services = try await ProcessExtractionServices.assemble(
            context: context,
            input: environment.input(pdfSelection: .installed(unavailable)))

        await #expect(
            throws: ExtractionServicesError.selectedExtractorUnavailable(
                route: .canonicalPDF,
                reference: unavailable)
        ) {
            try await services.prepare(backendOverride: nil)
        }
        await services.shutdown()
    }

    /// An unavailable installed HTML selection blocks the route. Tag-based
    /// extraction and the reviewed Defuddle package must not run automatically.
    @Test func unavailableInstalledHTMLSelectionFailsClosed() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let unavailable = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.thirdparty"),
            registrationID: try ExtractorRegistrationID(validating: "article"))
        let services = try await ProcessExtractionServices.assemble(
            context: context,
            input: environment.input(htmlSelection: .installed(unavailable)))

        await #expect(
            throws: ExtractionServicesError.selectedExtractorUnavailable(
                route: .canonicalHTML,
                reference: unavailable)
        ) {
            try await services.prepareHTML(backendOverride: nil)
        }
        await services.shutdown()
    }

    /// A third-party installed package cannot capture the default PDF path.
    /// The default requires the reviewed package lineage by exact identity.
    @Test func thirdPartyInstalledPackageCannotCaptureTheDefaultSelection() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: environment.root)
        _ = await context.reconcileNow()

        let thirdPartyRevision = try ExtractorPackageRevisionID(
            packageID: try ExtractorPackageID(validating: "org.example.thirdparty"),
            version: try ExtractorPackageVersion(validating: "9.9.9"),
            digest: ExtractorPackageDigest(
                bytes: Array(repeating: 0xAB, count: 32)))
        let reference = ExtractorReference(
            revision: thirdPartyRevision,
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let key = ExtractionAdapterKey.installed(kind: .pdf, reference: reference)
        _ = try await context.registry.register(
            RegisteredExtractionBackend(
                key: ExtractionBackendKey(kind: .pdf, backendID: "third-party-probe")) {
                .pdf(ExtractionPreparation(
                    extractor: ProbeExtractor(),
                    backend: .localPdf2md,
                    modelVersion: nil,
                    technique: "third-party"))
            },
            key: key)

        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())
        do {
            _ = try await services.prepare(backendOverride: nil)
            Issue.record("third-party package captured the default PDF selection")
        } catch let error as ExtractionServicesError {
            // The bundled default (the reviewed pdf2md lineage) fails closed
            // with the named-lineage diagnostic — it never falls through to
            // the registered third-party probe.
            #expect(error == .selectedExtractorUnavailable(
                route: .canonicalPDF,
                reference: ProcessExtractionServices.reviewedPDFLogical))
        }
        await services.shutdown()
    }

    // MARK: - Support

    private struct ProbeExtractor: MarkdownExtractor {
        var displayName: String { "probe" }
        func readiness() async -> ExtractionReadiness { .ready }
        func convert(
            pdfData: Data,
            filename: String,
            onProgress: (@Sendable (String) -> Void)?
        ) async throws -> String { "" }
    }

    private struct Environment {
        let root: URL
        let layout: ExtractorPackageStoreLayout

        static var reviewedPackagesRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ExtractorPackages", isDirectory: true)
        }

        static func make() throws -> Environment {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("reviewed-mapping-\(UUID().uuidString)", isDirectory: true)
            return Environment(
                root: root,
                layout: try ExtractorPackageStoreLayout(
                    appGroupContainerRoot: root,
                    processRole: .test))
        }

        func input(
            pdfSelection: ExtractionBackendReference? = nil,
            htmlSelection: ExtractionBackendReference? = nil,
            docxSelection: ExtractionBackendReference? = nil
        ) -> ExtractionProcessInput {
            var mutable = ExtractionConfig()
            if let pdfSelection {
                mutable.setExtractorSelection(pdfSelection, for: .canonicalPDF)
            }
            if let htmlSelection {
                mutable.setExtractorSelection(htmlSelection, for: .canonicalHTML)
            }
            if let docxSelection {
                mutable.setExtractorSelection(docxSelection, for: .canonicalDOCX)
            }
            let configuration = mutable
            return ExtractionProcessInput(
                services: MutableExtractionServices(),
                readConfiguration: { configuration },
                readCredential: { _ in nil },
                resolveACP: { _ in nil },
                httpFetcher: FakeHTTPFetcher(responses: []),
                packageContainerDirectory: root,
                packageProcessRole: .test)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct LocalProbeHTMLExtractor: HtmlMarkdownExtractor {
        var displayName: String { "probe-html" }
        func extract(html: String) async -> HtmlExtractionResult? { nil }
    }
}
#endif
