#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine

/// The legacy `localPdf2md` and `defuddle` selections map to the reviewed
/// package lineages when those lineages are active, and only to them. A
/// third-party package with a similar registration cannot capture the default
/// path, the fallback path, or the tag-based fallback.
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

    /// Without the reviewed package, the retired in-process PDF adapter is not
    /// available. The caller can surface the setup failure and use its fixed
    /// non-recursive fallback.
    @Test func defaultPDFSelectionIsUnavailableWithoutTheReviewedPackage() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: environment.root)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        do {
            _ = try await services.prepare(backendOverride: nil)
            Issue.record("retired local PDF adapter remained available")
        } catch let error as ExtractionServicesError {
            #expect(error == .unavailable)
        }
        await services.shutdown()
    }

    /// The explicit `defuddle` HTML selection serves through the reviewed
    /// Defuddle package when it is active. The tag-based fallback never maps.
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
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input(htmlBackend: .defuddle))

        let extractor = try await services.prepareHTML()
        #expect(extractor is ProcessPackageHTMLExtractor)
        await services.shutdown()
    }

    /// An unavailable installed PDF selection falls back to the reviewed
    /// package lineage, never to a conflicting third-party choice. The
    /// fallback resolves by reviewed identity, so it cannot recurse through
    /// the same unavailable logical reference.
    @Test func unavailableInstalledSelectionFallsBackToTheReviewedPackage() async throws {
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
            input: environment.input(pdfExtractor: .installed(unavailable)))

        let preparation = try await services.prepare(backendOverride: nil)
        #expect(preparation.technique == "package:org.selfdrivingwiki.pdf2md")
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
            #expect(error == .unavailable)
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
            pdfExtractor: ExtractionBackendReference? = nil,
            htmlBackend: HtmlExtractionBackend? = nil
        ) -> ExtractionProcessInput {
            var mutable = ExtractionConfig()
            mutable.htmlBackend = htmlBackend
            if let pdfExtractor {
                mutable.pdfExtractor = pdfExtractor
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
