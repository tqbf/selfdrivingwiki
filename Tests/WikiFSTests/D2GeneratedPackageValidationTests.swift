import Foundation
import Testing
@testable import WikiFSCore

/// Validates the locally generated D2 package (tmp/d2-renderer-package/D2)
/// with the production validator when it exists. Bare offline `swift test` has
/// no generated package, so those runs skip with a note; `make
/// d2-renderer-package` or the CI generation step materializes the folder and
/// the suite runs for real.
@Suite("D2 generated package validation", .serialized, .timeLimit(.minutes(2)))
struct D2GeneratedPackageValidationTests {
    @Test("the generated package passes the production validator")
    func generatedPackageValidates() throws {
        let source = D2PackageFixtures.generatedPackageRoot()
        guard FileManager.default.fileExists(atPath: source.appending(path: "manifest.json").path) else {
            print("→ skip: no generated D2 package; run make d2-renderer-package to exercise this suite")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("D2GeneratedPackageValidationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("D2 package validation cleanup failed.") }
        }

        let validated = try RendererPackageValidator(
            packageRoot: root.appending(path: "packages"),
            stagingRoot: root.appending(path: "staging"))
            .validate(directory: source)

        #expect(validated.manifest.packageID.rawValue == D2PackageFixtures.packageID)
        #expect(validated.manifest.version.rawValue == D2PackageFixtures.packageVersion)
        #expect(validated.manifest.descriptors.map(\.reference.registrationID.rawValue) == [D2PackageFixtures.registrationID])

        // The declared set is exactly what the generator emits: the validator
        // already fails closed on undeclared files, and this pins the set.
        // Regular files only and excluding manifest.json, which declares the
        // set rather than belonging to it.
        let declaredPaths = Set(validated.manifest.assets.map(\.path.rawValue))
        let onDiskPaths = Set(try declaredSetIndependentPaths(source))
        #expect(onDiskPaths == declaredPaths)
        #expect(declaredPaths.contains("index.html"))
        #expect(declaredPaths.contains("d2.wasm"))
        #expect(declaredPaths.contains("wasm_exec.js"))
        #expect(declaredPaths.contains("LICENSE.txt"))
        #expect(declaredPaths.contains("THIRD_PARTY_NOTICES.txt"))
    }

    @Test("provenance records upstream identity, license, and digests")
    func provenanceIsComplete() throws {
        let source = D2PackageFixtures.generatedPackageRoot()
        guard let provenance = try? String(
            contentsOf: source.appending(path: "PROVENANCE.md"), encoding: .utf8) else {
            print("→ skip: no generated D2 package; run make d2-renderer-package to exercise this suite")
            return
        }

        #expect(provenance.contains(D2PackageFixtures.packageVersion))
        #expect(provenance.contains(D2PackageFixtures.upstreamCommit))
        #expect(provenance.contains(D2PackageFixtures.sourceTarballURL))
        #expect(provenance.contains(D2PackageFixtures.sourceTarballSHA256))
        #expect(provenance.contains(D2PackageFixtures.d2WasmSHA256))
        #expect(provenance.contains(D2PackageFixtures.wasmExecSHA256))
        #expect(provenance.contains("MPL-2.0") || provenance.contains("Mozilla Public License"))
        #expect(provenance.contains("github.com/d2lang/d2"))
    }

    @Test("Package.swift gains no D2 resource and no generated-package reference")
    func appBundleStaysFreeOfD2() throws {
        let package = try String(
            contentsOf: D2PackageFixtures.repositoryRoot().appending(path: "Package.swift"),
            encoding: .utf8)
        #expect(!package.contains("RendererPackages/D2"))
        #expect(!package.contains("tmp/d2-renderer-package"))
        #expect(!package.contains("tools/d2"))
    }

    private func declaredSetIndependentPaths(_ directory: URL) throws -> [String] {
        var paths: [String] = []
        let fileManager = FileManager.default
        let enumerator = try #require(
            fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        let basePath = directory.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath) else { continue }
            let relative = String(path.dropFirst(basePath.count))
            if relative != "manifest.json" {
                paths.append(relative)
            }
        }
        return paths.sorted()
    }
}
