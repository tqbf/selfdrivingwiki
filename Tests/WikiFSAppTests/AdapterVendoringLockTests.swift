#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import WikiFSEngine

/// AC.1 (`plans/acp-adapter-vendoring.md`): the generated vendoring records
/// cannot drift. `scripts/sync-acp-adapter.sh` writes
/// `tools/claude-acp-adapter/adapter.lock.json`, the `package.json`
/// dependency pin, and `VendoredAdapterPin.swift` from ONE version variable;
/// this suite pins the generated records to each other AND to the committed
/// bytes on disk, so a hand-edited record or a rebuilt bundle fails here even
/// if the shell gate (`make acp-adapter`) never ran. Pure Swift — no network,
/// no subprocess.
@Suite struct AdapterVendoringLockTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var lockURL: URL {
        repositoryRoot.appending(path: "tools/claude-acp-adapter/adapter.lock.json")
    }

    private var packageJSONURL: URL {
        repositoryRoot.appending(path: "tools/claude-acp-adapter/package.json")
    }

    /// The subset of `adapter.lock.json` the tests consume (the generator
    /// owns the full document shape).
    private struct AdapterLock: Decodable {
        let version: String
        let package: String
        let entryPoint: String
        let tarballURL: String
        let distIntegrity: String
        let distShasum: String
        let bundle: String
        let fileDigests: [String: String]
    }

    private struct VendorPackageJSON: Decodable {
        let dependencies: [String: String]
    }

    private func loadLock() throws -> AdapterLock {
        try JSONDecoder().decode(AdapterLock.self, from: Data(contentsOf: lockURL))
    }

    private func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The compile-time pin, the lock record, and the package.json
    /// dependency pin must all state the SAME version — the version is
    /// hand-editable in exactly one place (the sync script's variable) and
    /// generated everywhere else.
    @Test func pinnedVersionAgreesAcrossEveryGeneratedRecord() throws {
        let lock = try loadLock()
        #expect(lock.version == VendoredAdapterPin.vendoredAdapterPinnedVersion)
        #expect(lock.package == VendoredAdapterPin.vendoredAdapterPackageSpec)

        let package = try JSONDecoder().decode(
            VendorPackageJSON.self, from: Data(contentsOf: packageJSONURL))
        #expect(
            package.dependencies[VendoredAdapterPin.vendoredAdapterPackageSpec]
                == VendoredAdapterPin.vendoredAdapterPinnedVersion)
    }

    /// The provenance metadata is complete and internally consistent: the
    /// canonical npm tarball URL for the pinned version, a SHA-512 dist
    /// integrity, the legacy hex SHA-1 shasum, the adapter's bin entry point,
    /// and the committed bundle path it names.
    @Test func provenanceMetadataIsCompleteAndConsistent() throws {
        let lock = try loadLock()
        #expect(lock.entryPoint == "dist/index.js")
        #expect(
            lock.tarballURL
                == "https://registry.npmjs.org/@agentclientprotocol/claude-agent-acp/-/claude-agent-acp-\(lock.version).tgz")
        #expect(lock.distIntegrity.hasPrefix("sha512-"))
        #expect(lock.distShasum.count == 40)
        #expect(lock.bundle == "Resources/claude-acp-adapter.bundle.js")
        #expect(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appending(path: lock.bundle).path))
    }

    /// The digests recorded in the lock match the committed bytes on disk —
    /// a hand edit to the bundle, the package.json pin, or the lockfile
    /// without a re-sync fails here.
    @Test func committedFileDigestsMatchTheLockRecord() throws {
        let lock = try loadLock()
        // Every reviewed input is covered — the committed bundle, the
        // vendor package.json, and the committed bun.lock.
        #expect(
            Set(lock.fileDigests.keys) == [
                "Resources/claude-acp-adapter.bundle.js",
                "tools/claude-acp-adapter/bun.lock",
                "tools/claude-acp-adapter/package.json",
            ])
        for (relativePath, expectedDigest) in lock.fileDigests {
            let fileURL = repositoryRoot.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                Issue.record("\(relativePath) is missing but recorded in adapter.lock.json")
                continue
            }
            let actual = try sha256Hex(of: fileURL)
            #expect(
                actual == expectedDigest,
                "\(relativePath) changed without re-running scripts/sync-acp-adapter.sh")
        }
    }
}
#endif
