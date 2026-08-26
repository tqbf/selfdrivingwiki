import Foundation
import Testing
import WikiDaemonContract

@Suite("Extractor package architecture boundaries")
struct ExtractorPackageArchitectureBoundaryTests {
    @Test func signedProbeReplyRequiresEveryBoundary() {
        let passed = SignedWikiDExtractorProbeReply(
            requestID: "request",
            reviewedPackageResolved: true,
            operationDirectoryIsPrivate: true,
            protocolExchangeSucceeded: true,
            processGroupTerminated: true,
            fixtureChildTerminated: true)
        #expect(passed.passed)

        let failed = SignedWikiDExtractorProbeReply(
            requestID: "request",
            reviewedPackageResolved: true,
            operationDirectoryIsPrivate: true,
            protocolExchangeSucceeded: true,
            processGroupTerminated: true,
            fixtureChildTerminated: false)
        #expect(!failed.passed)
    }

    @Test func packageCodeCannotEnterSwiftOrCordisBoundaries() throws {
        let root = repositoryRoot()
        let packageRoot = root.appendingPathComponent("ExtractorPackages", isDirectory: true)
        let swiftFiles = try FileManager.default.subpathsOfDirectory(atPath: packageRoot.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(swiftFiles.isEmpty)

        let manifest = try String(
            contentsOf: packageRoot
                .appendingPathComponent("SignedWikiDExtractorFixture/manifest.json"),
            encoding: .utf8)
        for forbidden in ["CordisContext", "PluginDefinition", "dependencies", "listeners", "services"] {
            #expect(!manifest.contains(forbidden))
        }
    }

    @Test func productionProbeUsesMachServiceAndNoAnonymousListener() throws {
        let root = repositoryRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/test-signed-wikid-extractor.sh"),
            encoding: .utf8)
        #expect(script.contains("/Applications/${APP_NAME}.app"))
        #expect(script.contains("WIKIFS_SIGNED_EXTRACTOR_PROBE_REPORT"))
        #expect(!script.contains("NSXPCListener.anonymous"))
        #expect(!script.contains("@testable import wikid"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
