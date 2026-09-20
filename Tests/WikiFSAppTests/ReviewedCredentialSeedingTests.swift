#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Hosted coverage for the reviewed-package credential seeding (AC.5 of the
/// extractor-package acquisition plan): the bootstrap's seed table drives
/// first-launch grants, revocation survives an unchanged-contract republish,
/// and a contract change (a different marker fingerprint) re-grants.
///
/// `Bundle(url:)` on the repo checkout resolves no resources, so each test
/// builds a fixture bundle — a byte-identical copy of the reviewed
/// `ExtractorPackages/Zotero` tree at
/// `<temp>/ZoteroSeedFixture.bundle/Contents/Resources/ExtractorPackages/Zotero`
/// — and passes `Bundle(url: fixtureRoot)`. Byte-identical matters: the
/// catalog admission validates the pinned digest over the copied tree, so a
/// tampered fixture would fail before the seeding step runs.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ReviewedCredentialSeedingTests {

    private let packageIDRaw = "org.selfdrivingwiki.zotero"
    private let requirementIDRaw = "zotero-api-key"

    // MARK: - Fixtures

    private func makeTempRoot(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Walk up from this file to the directory containing `Package.swift`.
    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw ExtractorValidationError.invalidManifest(
            "ReviewedCredentialSeedingTests could not locate the repo root")
    }

    /// A fixture bundle carrying only the reviewed Zotero package. The other
    /// reviewed packages resolve to nil in it and are skipped by the
    /// bootstrap's per-package "not bundled" path.
    private func makeFixtureBundle() throws -> Bundle {
        let source = try repoRoot()
            .appendingPathComponent("ExtractorPackages/Zotero", isDirectory: true)
        let fixtureRoot = try makeTempRoot("zotero-seed-fixture")
            .appendingPathComponent("ZoteroSeedFixture.bundle", isDirectory: true)
        let payload = fixtureRoot
            .appendingPathComponent("Contents/Resources/ExtractorPackages/Zotero",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: payload)
        return try #require(Bundle(url: fixtureRoot))
    }

    private func makeAppRoot() throws -> URL {
        try makeTempRoot("zotero-seed-appgroup")
    }

    private func makeLayout(_ root: URL) -> ExtractorCredentialAuthorizationStoreLayout {
        ExtractorCredentialAuthorizationStoreLayout(appGroupContainerRoot: root)
    }

    private func snapshot(for root: URL) -> ExtractorCredentialAuthorizationSnapshot? {
        ExtractorCredentialAuthorizationReader(layout: makeLayout(root)).snapshot()
    }

    private func zoteroRecord(
        in snapshot: ExtractorCredentialAuthorizationSnapshot?
    ) -> ExtractorCredentialAuthorizationRecord? {
        snapshot?.records.first {
            $0.authorizationID.packageID.rawValue == packageIDRaw
                && $0.authorizationID.requirementID.rawValue == requirementIDRaw
        }
    }

    private func markerURL(_ root: URL) -> URL {
        makeLayout(root).credentialsRoot
            .appendingPathComponent("extractor-credential-seeds.json")
    }

    private func readMarker(_ root: URL) throws -> [String: String] {
        let data = try Data(contentsOf: markerURL(root))
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func publish(appRoot: URL, bundle: Bundle) async throws {
        await ReviewedExtractorBootstrap.publishBundledPackages(
            appGroupContainerRoot: appRoot, bundle: bundle)
    }

    // MARK: - (a) First publish grants + writes the marker

    @Test func firstPublishGrantsAndWritesSeedMarker() async throws {
        let bundle = try makeFixtureBundle()
        let appRoot = try makeAppRoot()

        try await publish(appRoot: appRoot, bundle: bundle)

        // The grant landed in the authorization store, bound to the legacy
        // zotero Keychain reference.
        let record = try #require(zoteroRecord(in: snapshot(for: appRoot)))
        #expect(record.credentialReference == .zoteroAPIKey())

        // The seed marker records the exact fingerprint the grant pinned.
        let marker = try #require(readMarker(appRoot)[
            "\(packageIDRaw)/\(requirementIDRaw)"])
        #expect(marker == record.fingerprint.value)
    }

    // MARK: - (b) Revoke → republish stays revoked (marker decides)

    @Test func revocationSurvivesRepublishUnderUnchangedContract() async throws {
        let bundle = try makeFixtureBundle()
        let appRoot = try makeAppRoot()
        try await publish(appRoot: appRoot, bundle: bundle)
        try #require(zoteroRecord(in: snapshot(for: appRoot)) != nil)

        // Revoke the way the (future) UI would: delete the authorization
        // record; the marker file is untouched.
        let writer = try ExtractorCredentialAuthorizationWriter(
            layout: makeLayout(appRoot), processRole: .app)
        _ = try await writer.revoke(
            packageID: try ExtractorPackageID(validating: packageIDRaw),
            requirementID: try ExtractorCredentialRequirementID(
                validating: requirementIDRaw))
        #expect(zoteroRecord(in: snapshot(for: appRoot)) == nil)

        // Republish under an unchanged contract: the seeder must NOT
        // resurrect the grant (record absence ≈ revocation, and the marker
        // fingerprint still matches, so nothing is re-granted).
        try await publish(appRoot: appRoot, bundle: bundle)
        #expect(zoteroRecord(in: snapshot(for: appRoot)) == nil)
    }

    // MARK: - (c)/(d) Stale marker fingerprint → republish re-grants

    @Test func changedContractFingerprintRegrantsOnRepublish() async throws {
        let bundle = try makeFixtureBundle()
        let appRoot = try makeAppRoot()
        try await publish(appRoot: appRoot, bundle: bundle)
        let original = try #require(zoteroRecord(in: snapshot(for: appRoot)))

        // A "contract change": the marker claims a different fingerprint was
        // last seeded. First revoke so the re-grant is observable.
        let writer = try ExtractorCredentialAuthorizationWriter(
            layout: makeLayout(appRoot), processRole: .app)
        _ = try await writer.revoke(
            packageID: try ExtractorPackageID(validating: packageIDRaw),
            requirementID: try ExtractorCredentialRequirementID(
                validating: requirementIDRaw))

        var marker = try readMarker(appRoot)
        marker["\(packageIDRaw)/\(requirementIDRaw)"] =
            String(repeating: "ab", count: 32)
        try JSONEncoder().encode(marker).write(to: markerURL(appRoot))

        // Republish: marker ≠ current contract ⇒ a real contract change ⇒
        // the grant reappears with the manifest-pinned fingerprint.
        try await publish(appRoot: appRoot, bundle: bundle)
        let regranted = try #require(zoteroRecord(in: snapshot(for: appRoot)))
        #expect(regranted.fingerprint == original.fingerprint)
        #expect(regranted.fingerprint.value != String(repeating: "ab", count: 32))
    }
}
#endif
