import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.7 — the acquisition pipeline is provider-neutral.
///
/// A FAKE non-Zotero fetcher package (claiming `application/x-fake-source`)
/// drives the exact same registry namespace, persistence mutators, and
/// provenance columns as the reviewed Zotero lineage — no host branch
/// privileges a provider, package ID, or MIME. The returned parent
/// identifier is acquisition data (`sources.external_item_key`), never a
/// host identity (`source_versions.external_identity` stays NULL). The
/// schema itself carries only provider-neutral column names.
@Suite("Fetcher provider neutrality", .serialized, .timeLimit(.minutes(2)))
struct FetcherProviderNeutralityTests {

    private static let wikiID = WikiID(rawValue: "w")
    private static let fakeMIME = "application/x-fake-source"
    private typealias PipelineProvider = FetcherQueuePipelineTests.PipelineProvider

    // MARK: - Fixtures

    private static let fakePackageID = try! ExtractorPackageID(validating: "org.example.fake")
    private static let fakeDigest =
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private static var fakeRevision: ExtractorPackageRevisionID {
        ExtractorPackageRevisionID(
            packageID: fakePackageID,
            version: ExtractorPackageVersion(rawValue: "2.0.0")!,
            digest: try! ExtractorPackageDigest(hex: fakeDigest))
    }

    private func seedFakeSource(_ store: GRDBWikiStore) throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: "EXTSRC1",
            mimeType: Self.fakeMIME,
            provenance: SourceProvenance(
                agentName: "fake-provider",
                activityKind: "fetch",
                plan: "https://example.org/items/EXTSRC1/file",
                externalRef: "https://example.org/items/EXTSRC1/file",
                externalIdentity: "EXTSRC1"),
            role: .primary)
        return summary.id
    }

    // MARK: - A non-Zotero fetcher runs the identical pipeline

    @Test func fakeNonZoteroFetcherRegistersAndPersistsLikeAnyFetcher() async throws {
        // The fake fetcher registers under the SAME kind-free namespace as
        // the Zotero lineage — keyed by reference, with its claims (the
        // synthetic input MIME) coming from manifest-derived presentation
        // data, never from a host branch.
        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(
            revision: Self.fakeRevision,
            registrationID: try ExtractorRegistrationID(validating: "acquire"))
        let claimedMIME = try ExtractorMIMEType(validating: Self.fakeMIME)
        let batch = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installedFetcher(reference: reference),
                backend: RegisteredExtractionBackend(
                    key: ExtractionBackendKey(kind: .pdf, backendID: "placeholder")) {
                    throw ExtractionServicesError.unavailable
                },
                presentation: ExtractorRegistrationPresentation(
                    displayName: "Fake Acquirer",
                    packageName: "Fake",
                    role: .fetcher,
                    kinds: [],
                    mimeTypes: [claimedMIME],
                    filenameExtensions: []))
        ])

        // The registry surfaces it exactly like any fetcher registration.
        let snapshots = await registry.installedRegistrationSnapshots()
        let snapshot = try #require(snapshots.first { $0.reference == reference })
        #expect(snapshot.role == .fetcher)
        #expect(snapshot.mimeTypes.map(\.rawValue) == [Self.fakeMIME])
        let logical = LogicalExtractorReference(
            packageID: Self.fakePackageID,
            registrationID: reference.registrationID)
        #expect(await registry.resolveInstalledFetcher(logical) != nil)

        // Persistence runs through the same real store mutators with the
        // fake package's own provenance.
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedFakeSource(store)
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-neutral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        let queueStore = try QueueStore(
            databaseURL: queueURL.appendingPathComponent("queue.sqlite"))
        defer { queueStore.close() }
        let provider = PipelineProvider(store: store, queueStore: queueStore)

        let bytes = Data("%PDF-1.4 fake-provider acquisition".utf8)
        let resolution = FetcherResolution(
            fetch: { _ in
                .sourceBytes(FetchedSourceBytes(
                    bytes: bytes,
                    mimeType: try ExtractorMIMEType(validating: "application/pdf"),
                    originalFilename: "report.pdf",
                    reportedMetadata: try ExtractorReportedMetadata(toolName: "fake"),
                    articleMetadata: try ExtractorArticleMetadata(
                        title: "An External Study", identifier: "EXT-1")))
            },
            claimedMIMEType: claimedMIME,
            filename: "EXTSRC1",
            producer: ExtractionInstalledPackageProducer(
                revision: Self.fakeRevision,
                registrationID: reference.registrationID,
                protocolRevision: .v5,
                reportedMetadata: try ExtractorReportedMetadata(toolName: "fake")))
        let outcome = try await resolution.fetch { _ in }
        let referenceResult = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        #expect(referenceResult != nil)

        // The blob, provenance, and lifecycle all advanced — with the FAKE
        // package's data, through the same code path the Zotero lineage
        // uses.
        let summary = try #require(try store.listSources().first { $0.id == sourceID })
        #expect(summary.byteSize == bytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.externalItemKey == "EXT-1")
        #expect(summary.externalItemTitle == "An External Study")
        #expect(try store.sourceContent(id: sourceID) == bytes)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // The returned parent identifier is acquisition DATA on the source
        // row — the acquired content version itself carries NO host
        // external identity.
        let acquired = try #require(try store.activeContentVersion(sourceID: sourceID))
        #expect(acquired.externalIdentity == nil)
        #expect(acquired.mimeType == "application/pdf")

        await batch.dispose()
        #expect(await registry.resolveInstalledFetcher(logical) == nil)
    }

    // MARK: - Schema neutrality

    @Test func freshSchemaCarriesOnlyNeutralColumnNames() throws {
        let store = try TestStoreFactory.inMemory()
        let present = { (column: String) in
            store.scalarText(
                "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name = '\(column)';"
            ) == "1"
        }
        #expect(present("external_item_key"))
        #expect(present("external_item_title"))
        #expect(present("fetch_state"))
        #expect(present("fetch_producer"))
        // The Zotero-named columns are gone — a fetcher package is not a
        // Zotero concept.
        #expect(present("zotero_item_key") == false)
        #expect(present("zotero_item_title") == false)
    }
}
