#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore

/// Opt-in signed integration test for the production app and embedded XPC service.
///
/// Run this test from the repository root:
///
///     WIKIFS_SIGNED_EXTRACTOR_TESTS=1 swift test --filter SignedWikiDExtractorLaunchTests
@Suite("Signed wikid extractor launch", .serialized, .timeLimit(.minutes(15)))
struct SignedWikiDExtractorLaunchTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["WIKIFS_SIGNED_EXTRACTOR_TESTS"] == "1"
    }

    @Test(.enabled(if: enabled))
    func productionServiceSpawnsExchangesAndCancelsFixture() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = root.appendingPathComponent("scripts/test-signed-wikid-extractor.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        let result = try await AsyncProcessRunner.run(.init(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: root,
            outputMode: .combined))
        let output = String(decoding: result.combinedData.suffix(16 * 1024), as: UTF8.self)
        #expect(result.terminationStatus == 0, Comment(rawValue: output))
        #expect(output.contains("signed wikid extractor boundary passed"), Comment(rawValue: output))
    }
}
#endif
