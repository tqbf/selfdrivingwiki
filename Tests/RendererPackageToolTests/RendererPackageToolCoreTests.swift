import Foundation
import RendererPackageToolCore
import Testing
import WikiFSCore

@Suite("Renderer package tool core", .serialized, .timeLimit(.minutes(1)))
struct RendererPackageToolCoreTests {
    @Test("valid package returns stable identity and removes invocation root")
    func validPackageReturnsStableJSONIdentityWithoutActivation() throws {
        let fixture = try Fixture()
        defer { fixture.removeTestRoot() }

        let output = try fixture.executor().execute(
            arguments: ["validate", fixture.packageRoot.path])
        let manifestData = try Data(contentsOf: fixture.packageRoot.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(RendererManifest.self, from: manifestData)

        let expectedPackageHash = try manifest.packageHash().hex
        #expect(output.packageID == "org.example.readonly")
        #expect(output.version == "1.0.0")
        #expect(output.registrationIDs == ["example"])
        #expect(output.packageHash == expectedPackageHash)
        #expect(output.packageHash == output.packageHash.lowercased())
        #expect(!FileManager.default.fileExists(atPath: fixture.invocationRoot.path))
    }

    @Test("invalid inputs fail with typed errors and remove invocation root", arguments: InvalidCase.allCases)
    func invalidInputsFailAndCleanInvocationRoot(testCase: InvalidCase) throws {
        let fixture = try Fixture()
        defer { fixture.removeTestRoot() }
        let arguments = try fixture.arguments(for: testCase)

        do {
            _ = try fixture.executor().execute(arguments: arguments)
            Issue.record("Expected validation to fail for \(testCase)")
        } catch let failure as RendererPackageToolFailure {
            #expect(testCase.accepts(failure))
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.invocationRoot.path))
    }

    @Test("validation uses only injected invocation roots and leaves a sentinel machine store unchanged")
    func validationIsConfinedToInjectedRootAndLeavesSentinelMachineStoreUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.removeTestRoot() }
        let machineIndex = fixture.testRoot.appending(path: "machine-store/index.json")
        try FileManager.default.createDirectory(
            at: machineIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("{\"generation\":41,\"sentinel\":true}".utf8)
        try sentinel.write(to: machineIndex)
        let roots = ValidatorRootRecorder()
        let executor = RendererPackageToolExecutor(
            validationRootFactory: { fixture.invocationRoot },
            validatorFactory: { packagesRoot, stagingRoot, fileManager in
                roots.record(packagesRoot: packagesRoot, stagingRoot: stagingRoot)
                return RendererPackageValidator(
                    packageRoot: packagesRoot,
                    stagingRoot: stagingRoot,
                    fileManager: fileManager,
                    diagnose: { _ in })
            })

        _ = try executor.execute(arguments: ["validate", fixture.packageRoot.path])

        #expect(roots.packagesRoot?.standardizedFileURL.path == fixture.invocationRoot.appending(path: "packages").standardizedFileURL.path)
        #expect(roots.stagingRoot?.standardizedFileURL.path == fixture.invocationRoot.appending(path: "staging").standardizedFileURL.path)
        #expect(roots.packagesRoot?.path.hasPrefix(machineIndex.deletingLastPathComponent().path) == false)
        #expect(try Data(contentsOf: machineIndex) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: fixture.invocationRoot.path))
    }

    @Test("cleanup failure overrides validation success")
    func cleanupFailureOverridesSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.removeTestRoot() }
        let executor = RendererPackageToolExecutor(
            validationRootFactory: { fixture.invocationRoot },
            rootCleanup: { _ in throw CocoaError(.fileWriteUnknown) })

        #expect(throws: RendererPackageToolFailure.cleanupFailed) {
            _ = try executor.execute(arguments: ["validate", fixture.packageRoot.path])
        }
    }
}

enum InvalidCase: CaseIterable, CustomStringConvertible {
    case missingArguments
    case file
    case malformedManifest
    case undeclaredAsset
    case hashMismatch

    var description: String {
        switch self {
        case .missingArguments: "missing arguments"
        case .file: "file instead of folder"
        case .malformedManifest: "malformed manifest"
        case .undeclaredAsset: "undeclared asset"
        case .hashMismatch: "asset hash mismatch"
        }
    }

    func accepts(_ failure: RendererPackageToolFailure) -> Bool {
        switch (self, failure) {
        case (.missingArguments, .invalidArguments),
             (.file, .validation(.sourceIsNotDirectory)),
             (.malformedManifest, .validation(.malformedManifest)),
             (.undeclaredAsset, .validation(.undeclaredFile("undeclared.css"))),
             (.hashMismatch, .validation(.assetHashMismatch("index.html"))):
            true
        default:
            false
        }
    }
}

private final class ValidatorRootRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPackagesRoot: URL?
    private var recordedStagingRoot: URL?

    var packagesRoot: URL? { lock.withLock { recordedPackagesRoot } }
    var stagingRoot: URL? { lock.withLock { recordedStagingRoot } }

    func record(packagesRoot: URL, stagingRoot: URL) {
        lock.withLock {
            recordedPackagesRoot = packagesRoot
            recordedStagingRoot = stagingRoot
        }
    }
}

private final class Fixture: @unchecked Sendable {
    let testRoot: URL
    let packageRoot: URL
    let invocationRoot: URL

    init() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-package-tool-tests-\(UUID().uuidString)", isDirectory: true)
        packageRoot = testRoot.appendingPathComponent("package", isDirectory: true)
        invocationRoot = testRoot.appendingPathComponent("invocation", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.templateRoot, to: packageRoot)
    }

    func executor() -> RendererPackageToolExecutor {
        RendererPackageToolExecutor(validationRootFactory: { self.invocationRoot })
    }

    func arguments(for testCase: InvalidCase) throws -> [String] {
        switch testCase {
        case .missingArguments:
            return []
        case .file:
            return ["validate", packageRoot.appending(path: "index.html").path]
        case .malformedManifest:
            try Data("not json".utf8).write(to: packageRoot.appending(path: "manifest.json"))
        case .undeclaredAsset:
            try Data("body {}".utf8).write(to: packageRoot.appending(path: "undeclared.css"))
        case .hashMismatch:
            let manifestURL = packageRoot.appending(path: "manifest.json")
            var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            manifest = manifest.replacingOccurrences(
                of: "3fd4edb473cf5a4617fc44a8d1c42f708a274122d7e2c7b424931dc97ffd0f33",
                with: String(repeating: "0", count: 64))
            try Data(manifest.utf8).write(to: manifestURL)
        }
        return ["validate", packageRoot.path]
    }

    func removeTestRoot() {
        guard FileManager.default.fileExists(atPath: testRoot.path) else { return }
        do { try FileManager.default.removeItem(at: testRoot) }
        catch { Issue.record("Renderer package tool fixture cleanup failed: \(error)") }
    }

    private static let templateRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "docs/skills/renderer-package-maintainer/assets/minimal-renderer-package")
}
