#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import CodeHighlightBenchmark
@testable import WikiFSCodeHighlighting

struct CodeHighlightBenchmarkTests {
    private static let head = "74079438437ad3177671285c4993392c6c135b9f"
    private static let tree = "384bcd0841e6f659ca8b94502a2a8d3927fc59d5"
    private static let base = "14f07d60093daf25596522924a77b6fa0742a23d"

    @Test("closed nested Scala command accepts only complete exact identity arguments")
    func parsesClosedNestedScalaCommand() throws {
        let options = try CodeHighlightBenchmarkCommand.parse(arguments: [
            CodeHighlightBenchmarkCommand.nestedScalaProbe,
            "--output", "tmp/orchestration/markdown-renderer-embeds/benchmark/f2.json",
            "--head", Self.head,
            "--tree", Self.tree,
            "--base", Self.base,
        ])

        #expect(options.head == Self.head)
        #expect(options.tree == Self.tree)
        #expect(options.base == Self.base)
        #expect(options.outputPath == "tmp/orchestration/markdown-renderer-embeds/benchmark/f2.json")
    }

    @Test("closed nested Scala command rejects incomplete and noncanonical identity arguments")
    func rejectsInvalidCommandArguments() {
        #expect(throws: CodeHighlightBenchmarkCommand.Error.missingArgument("--tree")) {
            try CodeHighlightBenchmarkCommand.parse(arguments: [
                CodeHighlightBenchmarkCommand.nestedScalaProbe,
                "--output", "tmp/orchestration/markdown-renderer-embeds/benchmark/f2.json",
                "--head", Self.head,
                "--base", Self.base,
            ])
        }
        #expect(throws: CodeHighlightBenchmarkCommand.Error.invalidSHA("--head")) {
            try CodeHighlightBenchmarkCommand.parse(arguments: [
                CodeHighlightBenchmarkCommand.nestedScalaProbe,
                "--output", "tmp/orchestration/markdown-renderer-embeds/benchmark/f2.json",
                "--head", "74079438",
                "--tree", Self.tree,
                "--base", Self.base,
            ])
        }
    }

    @Test("nested Scala fixture has the exact accepted size and stable digest")
    func nestedScalaFixtureIsExactAndStable() {
        let fixture = CodeHighlightBenchmarkFixtures.nestedScalaMaximum()
        #expect(fixture.utf8.count == CodeHighlightingPolicy.maximumHighlightedSourceBytes)
        let digest = SHA256.hash(data: Data(fixture.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "2eb53bd571b7491b37080b27b5d0f927f6551168ee94e4d47b574f3363360f75")
        #expect(fixture.contains("final case class Box[A]"))
        #expect(fixture.contains("Vector.tabulate"))
    }

    @Test("benchmark report uses deterministic machine-readable schema")
    func reportSchemaIsDeterministic() throws {
        let options = try CodeHighlightBenchmarkCommand.parse(arguments: [
            CodeHighlightBenchmarkCommand.nestedScalaProbe,
            "--output", "tmp/orchestration/markdown-renderer-embeds/benchmark/f2.json",
            "--head", Self.head,
            "--tree", Self.tree,
            "--base", Self.base,
        ])
        let sample = BenchmarkSample(
            parserMilliseconds: 1,
            queryMilliseconds: 2,
            rangeValidationMilliseconds: 3,
            htmlAssemblyMilliseconds: 4,
            totalMilliseconds: 10,
            captureCount: 12,
            tokenCount: 11)
        let report = try #require(BenchmarkReportBuilder.make(
            options: options,
            system: BenchmarkSystemMetadata(
                operatingSystem: "testOS",
                architecture: "arm64",
                hardwareModel: "test-machine",
                activeProcessorCount: 1),
            fixtureID: CodeHighlightBenchmarkFixtures.nestedScalaMaximumID,
            fixtureDigestSHA256: String(repeating: "a", count: 64),
            sourceBytes: CodeHighlightingPolicy.maximumHighlightedSourceBytes,
            warmupRuns: 3,
            samples: Array(repeating: sample, count: 20),
            rssDeltaBytes: 42))
        let first = try BenchmarkReportBuilder.encoded(report)
        let second = try BenchmarkReportBuilder.encoded(report)
        #expect(first == second)
        let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["measuredSamples"] as? Int == 20)
        #expect(object["fixtureID"] as? String == CodeHighlightBenchmarkFixtures.nestedScalaMaximumID)
        #expect(object["rssDeltaBytes"] as? Int == 42)
    }
}
#endif
