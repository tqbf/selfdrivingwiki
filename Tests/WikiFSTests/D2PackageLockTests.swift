import Foundation
import Testing

/// The provenance lock (`tools/d2/d2-package.lock.json`) is the supply-chain
/// pin: the exact upstream source tarball URL and digest, the pinned commit,
/// the WASM build recipe (tool versions and flags), the extracted-file
/// digests, and the expected digests of every generated package asset.
@Suite("D2 package lock", .serialized)
struct D2PackageLockTests {
    private let lock: [String: Any]

    init() throws {
        let data = try Data(contentsOf: D2PackageFixtures.toolsDirectory().appending(path: "d2-package.lock.json"))
        lock = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hexDigest(_ value: Any) -> Bool {
        guard let text = value as? String, text.count == 64 else { return false }
        return text.allSatisfy { $0.isASCII && (($0.isNumber || ("a"..."f").contains($0))) }
    }

    @Test("the lock pins the upstream source tarball, commit, and digest")
    func upstreamIsPinned() throws {
        let upstream = try #require(lock["upstream"] as? [String: Any])
        #expect(upstream["name"] as? String == "d2lang/d2")
        #expect(upstream["version"] as? String == D2PackageFixtures.upstreamVersion)
        #expect(upstream["commit"] as? String == D2PackageFixtures.upstreamCommit)
        #expect(upstream["sourceTarballURL"] as? String == D2PackageFixtures.sourceTarballURL)
        #expect(upstream["sourceTarballSHA256"] as? String == D2PackageFixtures.sourceTarballSHA256)
        #expect(hexDigest(try #require(upstream["sourceTarballSHA256"])))
    }

    @Test("the WASM build recipe is pinned with tool versions and flags")
    func buildRecipeIsPinned() throws {
        let build = try #require(lock["build"] as? [String: Any])
        #expect(build["goVersion"] as? String == "go1.27.0")
        #expect(build["sourcePackage"] as? String == "./d2js")
        let optimizeFlags = try #require(build["optimizeFlags"] as? [String])
        #expect(optimizeFlags.first == "-Oz")
        #expect(!optimizeFlags.contains("'-all'") && !optimizeFlags.contains("-all"))
        let wasmExec = try #require(lock["wasmExec"] as? [String: Any])
        #expect(wasmExec["sha256"] as? String == D2PackageFixtures.wasmExecSHA256)
        #expect(hexDigest(try #require(wasmExec["sha256"])))
    }

    @Test("the package identity matches the shared fixture constants")
    func identityMatchesPlan() throws {
        let package = try #require(lock["package"] as? [String: Any])
        #expect(package["packageID"] as? String == D2PackageFixtures.packageID)
        #expect(package["version"] as? String == D2PackageFixtures.packageVersion)
        #expect(package["registrationID"] as? String == D2PackageFixtures.registrationID)
        #expect(package["displayName"] as? String == D2PackageFixtures.displayName)
        #expect(package["priority"] as? Int == D2PackageFixtures.priority)
        // Upstream and package versions move together: a regeneration bump is
        // an explicit lock edit, never a silent drift.
        #expect(package["version"] as? String == D2PackageFixtures.upstreamVersion)
        let sizeLimits = try #require(package["sizeLimits"] as? [String: Any])
        #expect(sizeLimits["maximumInputByteCount"] as? Int == D2PackageFixtures.maximumInputByteCount)
        let capabilities = try #require(package["capabilities"] as? [String])
        #expect(capabilities == ["inputRead"])
        #expect(package["linkPolicy"] as? String == "none")
        let roles = try #require(package["supportedEmbeddingRoles"] as? [String])
        #expect(roles == ["disclosureRow"])
    }

    @Test("expected assets cover the wrapper, licenses, and provenance")
    func expectedAssetsCoverThePackage() throws {
        let expected = try #require(lock["expectedAssets"] as? [String: Any])
        let requiredPaths = [
            "LICENSE.txt",
            "PROVENANCE.md",
            "THIRD_PARTY_NOTICES.txt",
            "d2-viewer.js",
            "d2.wasm",
            "index.html",
            "wasm_exec.js",
        ]
        for path in requiredPaths {
            #expect(hexDigest(try #require(expected[path], "missing expected digest for \(path)")))
        }
        // The built WASM digest is the supply-chain pin for the build recipe.
        #expect(expected["d2.wasm"] as? String == D2PackageFixtures.d2WasmSHA256)
        // A pinned wall-clock date keeps PROVENANCE.md byte-reproducible.
        let generatedAt = try #require(lock["generatedAt"] as? String)
        #expect(generatedAt.isEmpty == false)
        #expect(generatedAt.contains("T") == false, "generatedAt must be a pinned date, not a timestamp")
    }
}
