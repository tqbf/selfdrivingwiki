#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine

/// The legacy `.doclingServe` selection maps to the reviewed Docling Serve
/// package lineage (issue #1159 — AC.18), records that lineage (and never the
/// interim `.localPdf2md` package tag), and the route host catalog presents
/// Docling as a reviewed package choice.
@Suite("Reviewed Docling legacy mapping", .serialized, .timeLimit(.minutes(5)))
struct ReviewedDoclingLegacyMappingTests {

    /// A saved `.doclingServe` selection serves through the reviewed package
    /// with its existing typed reference — no copy, no re-entry.
    @Test func legacySelectionUsesReviewedLineageAndExistingReference() async throws {
        let environment = try Environment.make(
            configuration: { configuration in
                configuration.backend = .doclingServe
            })
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        let preparation = try await services.prepare(backendOverride: nil)
        // The technique names the reviewed package lineage, not the retired
        // in-process adapter.
        #expect(preparation.technique == "package:org.selfdrivingwiki.docling-serve")
        // The provenance records the reviewed lineage + protocol revision 2.
        let provenance = try #require(preparation.packageProvenance)
        #expect(provenance.revision.packageID.rawValue == "org.selfdrivingwiki.docling-serve")
        #expect(provenance.protocolRevision == .v2)
        #expect(provenance.registrationID.rawValue == "document")
        await services.shutdown()
    }

    /// The interim `.localPdf2md` backend tag must never be used for a
    /// Docling selection (plan step 11).
    @Test func legacySelectionRecordsReviewedLineageAndDoclingBackendTag() async throws {
        let environment = try Environment.make(
            configuration: { configuration in
                configuration.backend = .doclingServe
            })
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        let preparation = try await services.prepare(backendOverride: nil)
        #expect(preparation.packageProvenance != nil)
        #expect(preparation.backend != .localPdf2md)
        #expect(preparation.technique?.contains("pdf2md") == false)
        await services.shutdown()
    }

    /// The legacy selection is preserved in the route record but the mapped
    /// reviewed lineage refuses to resolve silently: a Docling selection
    /// whose lineage is unavailable fails closed instead of falling back to
    /// pdf2md (PR 4 review HIGH-3, plan step 12).
    @Test func unavailableDoclingLineageFailsClosedInsteadOfSwappingPackages() async throws {
        let environment = try Environment.make(
            configuration: { configuration in
                configuration.backend = .doclingServe
            })
        defer { environment.cleanup() }

        // Assemble WITHOUT the reviewed bundle root: the reviewed Docling
        // lineage is absent, exactly like a Mac where the package was
        // removed or failed admission.
        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: environment.root)
        _ = await context.reconcileNow()
        let services = try await ProcessExtractionServices.assemble(
            context: context, input: environment.input())

        do {
            _ = try await services.prepare(backendOverride: nil)
            Issue.record("a Docling selection silently swapped to another extractor")
        } catch let error as ExtractionServicesError {
            #expect(error == .unavailable)
        }
        await services.shutdown()
    }

    /// The host catalog owns no package choices. A validated package snapshot
    /// supplies the reviewed Docling choice.
    @Test func routeBuilderProjectsDoclingFromPackageSnapshot() throws {
        #expect(
            ExtractorRouteHostCatalog.choices(for: .canonicalPDF)
                .contains { $0.category == .reviewedPackage } == false)
        let package = ReviewedExtractorPackages.doclingServe
        let snapshot = ExtractorRouteRegistrationSnapshot(
            reference: ExtractorReference(
                revision: package.revision,
                registrationID: try ExtractorRegistrationID(validating: "document")),
            sourceCategory: .reviewedPackage,
            displayName: "Docling Serve",
            packageName: "Docling Serve",
            kinds: [.pdf],
            mimeTypes: [ExtractorRouteID.canonicalPDF.mimeType],
            filenameExtensions: [])
        let row = try #require(ExtractorRouteTableBuilder.build(.init(
            configuration: ExtractionConfig(backend: .acp),
            registrations: [],
            availableRegistrations: [snapshot])).first { $0.route == .canonicalPDF })
        let choice = try #require(row.choices.first { $0.displayName == "Docling Serve" })
        #expect(choice.category == .reviewedPackage)
        #expect(choice.reference == .installed(ProcessExtractionServices.reviewedDoclingLogical))
    }

    // MARK: - Support

    private struct Environment {
        let root: URL
        let layout: ExtractorPackageStoreLayout
        let seedConfiguration: (inout ExtractionConfig) -> Void

        static var reviewedPackagesRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ExtractorPackages", isDirectory: true)
        }

        static func make(
            configuration: @escaping (inout ExtractionConfig) -> Void
        ) throws -> Environment {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("docling-mapping-\(UUID().uuidString)", isDirectory: true)
            return Environment(
                root: root,
                layout: try ExtractorPackageStoreLayout(
                    appGroupContainerRoot: root,
                    processRole: .test),
                seedConfiguration: configuration)
        }

        func input() -> ExtractionProcessInput {
            var mutable = ExtractionConfig()
            seedConfiguration(&mutable)
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
}
#endif
