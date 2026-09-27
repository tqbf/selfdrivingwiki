import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.2 — registry-level routing for fetcher registrations.
///
/// Fetchers live in their own kind-free registry namespace
/// (`.installedFetcher(reference:)`): a same-MIME extractor registration can
/// never satisfy a fetcher selection, and a fetcher key never satisfies a
/// kind-routed lookup. Settings-facing rows and route snapshots carry the
/// declared role. The selection-table rule (`prepareFetcher`'s decision
/// input) is pinned through `ExtractionConfig.fetcherSelectionOrDefault`
/// plus the bundled defaults, because `ProcessExtractionServices` is only
/// constructible through the full production boot path.
@Suite("Fetcher registration routing")
struct FetcherRegistrationRoutingTests {

    // MARK: - Fixtures

    private static let packageID = try! ExtractorPackageID(validating: "org.example.fetcher")
    private static let registrationID = try! ExtractorRegistrationID(validating: "attachment")

    private static func reference(version: String, digest: String) throws -> ExtractorReference {
        ExtractorReference(
            revision: ExtractorPackageRevisionID(
                packageID: packageID,
                version: ExtractorPackageVersion(rawValue: version)!,
                digest: try ExtractorPackageDigest(hex: digest)),
            registrationID: registrationID)
    }

    private static let versionOneDigest =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let versionTwoDigest =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    /// The registration's logical identity (package + registration, no
    /// version) — what a stored selection names.
    private static var logical: LogicalExtractorReference {
        LogicalExtractorReference(packageID: packageID, registrationID: registrationID)
    }

    /// A registered backend whose adapter closure is never invoked by the
    /// registry-level reads these tests perform.
    private static func backend() -> RegisteredExtractionBackend {
        RegisteredExtractionBackend(
            key: ExtractionBackendKey(kind: .pdf, backendID: "placeholder")) {
            throw ExtractionServicesError.unavailable
        }
    }

    // MARK: - Fetcher namespace resolution

    @Test func resolveInstalledFetcherFindsRegistrationAndPicksHighestRevision() async throws {
        let registry = ExtractionBackendRegistry()
        let lower = try Self.reference(version: "1.0.0", digest: Self.versionOneDigest)
        let higher = try Self.reference(version: "2.0.0", digest: Self.versionTwoDigest)
        _ = try await registry.register(Self.backend(), key: .installedFetcher(reference: lower))
        _ = try await registry.register(Self.backend(), key: .installedFetcher(reference: higher))

        let match = await registry.resolveInstalledFetcher(Self.logical)
        let key = try #require(match?.key)
        guard case .installedFetcher(let resolved) = key else {
            Issue.record("expected the fetcher namespace key")
            return
        }
        // Install or registration order never matters: the highest
        // compatible revision wins.
        #expect(resolved.revision.version.rawValue == "2.0.0")
        #expect(resolved.revision.digest.hex == Self.versionTwoDigest)
    }

    @Test func fetcherAndExtractorNamespacesAreDisjoint() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = try Self.reference(version: "1.0.0", digest: Self.versionOneDigest)

        // An EXTRACTOR registration of the SAME package, registration, and
        // MIME claim — but registered under a kind key — does not satisfy a
        // fetcher selection.
        _ = try await registry.register(
            Self.backend(), key: .installed(kind: .pdf, reference: reference))
        let fetcherMatch = await registry.resolveInstalledFetcher(Self.logical)
        #expect(fetcherMatch == nil)

        // And the reverse: a fetcher key does not satisfy a kind-routed
        // lookup, even with no extractor registered under that kind.
        let fetcherOnly = ExtractionBackendRegistry()
        _ = try await fetcherOnly.register(
            Self.backend(), key: .installedFetcher(reference: reference))
        let kindMatch = await fetcherOnly.resolveInstalled(Self.logical, kind: .pdf)
        #expect(kindMatch == nil)
    }

    @Test func containsRevisionCoversFetcherKeysAndFollowsBatchDisposal() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = try Self.reference(version: "1.0.0", digest: Self.versionOneDigest)
        let batch = try await registry.registerBatch([
            ExtractionBatchEntry(key: .installedFetcher(reference: reference), backend: Self.backend())
        ])
        #expect(await registry.containsRevision(reference.revision))
        await batch.dispose()
        // Batch cleanup removes membership, so stale plugin definitions
        // cannot admit removed code.
        #expect(await registry.containsRevision(reference.revision) == false)
    }

    // MARK: - Settings rows and route snapshots

    @Test func installedPackageRowsCarryRoleAndKindlessFetchers() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = try Self.reference(version: "1.0.0", digest: Self.versionOneDigest)
        _ = try await registry.register(
            Self.backend(), key: .installedFetcher(reference: reference))
        _ = try await registry.register(
            Self.backend(), key: .installed(kind: .pdf, reference: reference))

        let rows = await registry.installedPackageRows()
        let fetcherRow = try #require(rows.first { $0.role == .fetcher })
        #expect(fetcherRow.kind == nil)
        #expect(fetcherRow.packageID == reference.revision.packageID.rawValue)
        let extractorRow = try #require(rows.first { $0.role == .extractor })
        #expect(extractorRow.kind == .pdf)
    }

    @Test func installedRegistrationSnapshotsCarryRoleAndClaims() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = try Self.reference(version: "1.0.0", digest: Self.versionOneDigest)
        let claimedMIME = try ExtractorMIMEType(validating: "application/x-fake-source")
        let batch = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installedFetcher(reference: reference),
                backend: Self.backend(),
                presentation: ExtractorRegistrationPresentation(
                    displayName: "Fake Fetcher",
                    packageName: "Fake",
                    role: .fetcher,
                    kinds: [],
                    mimeTypes: [claimedMIME],
                    filenameExtensions: []))
        ])
        let snapshots = await registry.installedRegistrationSnapshots()
        let snapshot = try #require(snapshots.first { $0.reference == reference })
        #expect(snapshot.role == .fetcher)
        #expect(snapshot.kinds.isEmpty)
        #expect(snapshot.mimeTypes.map(\.rawValue) == ["application/x-fake-source"])
        await batch.dispose()
        #expect(await registry.installedRegistrationSnapshots().isEmpty)
    }

    // MARK: - Selection-table rule (prepareFetcher's decision input)

    /// `ProcessExtractionServices.prepareFetcher` resolves
    /// `configuration.fetcherSelectionOrDefault(for:)` and fails closed
    /// unless it is `.installed`; these tests pin that input's state
    /// machine without assembling the full production services object.
    @Test func freshConfigSuppliesReviewedZoteroFetcherDefault() {
        let config = ExtractionConfig()
        let selection = config.fetcherSelectionOrDefault(for: .canonicalZotero)
        guard case .installed(let logical)? = selection else {
            Issue.record("expected the bundled reviewed fetcher default, got \(String(describing: selection))")
            return
        }
        #expect(logical.packageID.rawValue == ReviewedExtractorPackages.zotero.packageID.rawValue)
    }

    @Test func explicitNoneSelectionNeverRevivesTheDefault() {
        var config = ExtractionConfig()
        config.setFetcherSelection(ExtractionBackendReference.none, for: .canonicalZotero)
        // The stored disable wins over the bundled default — `prepareFetcher`
        // throws `selectedFetcherUnavailable` for this record instead of
        // silently reviving the reviewed lineage.
        #expect(config.fetcherSelectionOrDefault(for: .canonicalZotero)
            == ExtractionBackendReference.none)
    }

    @Test func storedInstalledSelectionWinsOverTheDefault() throws {
        var config = ExtractionConfig()
        let stored = LogicalExtractorReference(
            packageID: Self.packageID,
            registrationID: Self.registrationID)
        config.setFetcherSelection(.installed(stored), for: .canonicalZotero)
        let selection = config.fetcherSelectionOrDefault(for: .canonicalZotero)
        #expect(selection == .installed(stored))
    }

    @Test func bundledExtractorRoutesContainNoZoteroRoute() throws {
        // Acquisition moved to the fetcher route table: no extractor route
        // claims the synthetic `application/zotero` MIME anymore.
        let zoteroMIME = try #require(
            ExtractorMIMEType(rawValue: ContentTypeRegistry.zoteroAttachment))
        let zoteroRoutes = ExtractorRouteDefaults.bundled.routeExtractors.filter {
            $0.route.mimeType == zoteroMIME
        }
        #expect(zoteroRoutes.isEmpty)
        // …while the fetcher table carries the canonical zotero route.
        #expect(ExtractorRouteDefaults.bundled.fetcherDefault(for: .canonicalZotero) != nil)
    }
}
