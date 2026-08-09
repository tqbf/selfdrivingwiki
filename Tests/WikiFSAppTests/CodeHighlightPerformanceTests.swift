#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(2)))
struct CodeHighlightPerformanceTests {
    private static let warmupRuns = 3
    private static let measuredSamples = 20
    private static let hundredKiBBytes = 100 * 1024
    private static let maximumBytes = CodeHighlightingPolicy.maximumHighlightedSourceBytes

    @Test("five-grammar highlighter records non-gating debug diagnostics")
    func recordsDebugDiagnostics() throws {
        try Self.validateCorpus()
        let fixtures = Self.fixtures()

        for _ in 0..<Self.warmupRuns {
            for fixture in fixtures.smallAndMalformed {
                _ = CodeSyntaxHighlighter.highlightedHTML(
                    source: fixture.source,
                    language: fixture.language,
                    isCancelled: { false })
            }
        }

        let fiveGrammarSamples = Self.measure(Self.measuredSamples) {
            for fixture in fixtures.smallAndMalformed.prefix(5) {
                _ = CodeSyntaxHighlighter.highlightedHTML(
                    source: fixture.source,
                    language: fixture.language,
                    isCancelled: { false })
            }
        }
        let hundredKiBSamples = Self.measure(Self.measuredSamples) {
            _ = CodeSyntaxHighlighter.highlightedHTML(
                source: fixtures.hundredKiB,
                language: .swift,
                isCancelled: { false })
        }
        let maxBeforeRSS = Self.peakRSSBytes()
        let maximumSamples = Self.measure(Self.measuredSamples) {
            _ = CodeSyntaxHighlighter.highlightedHTML(
                source: fixtures.maximumScala,
                language: .scala,
                isCancelled: { false })
        }
        let maxAfterRSS = Self.peakRSSBytes()
        let hundredBlockSamples = Self.measure(Self.measuredSamples) {
            _ = MarkdownHTMLRenderer.render(fixtures.hundredBlocks)
        }

        let evidence = Evidence(
            measurementRole: "non-gating-debug-diagnostic",
            configuration: "debug",
            fiveGrammar: Self.summary(fiveGrammarSamples),
            hundredKiB: Self.summary(hundredKiBSamples),
            maximum: Self.summary(maximumSamples),
            hundredBlocks: Self.summary(hundredBlockSamples),
            rssScope: "process-wide ru_maxrss diagnostic; not attributable to the highlighter",
            processWideMaximumRSSDeltaBytes: maxAfterRSS >= maxBeforeRSS ? maxAfterRSS - maxBeforeRSS : 0)
        try Self.writeEvidence(evidence)

        #expect(evidence.hundredKiB.p95Milliseconds >= 0)
        #expect(evidence.maximum.p95Milliseconds >= 0)
        #expect(evidence.hundredBlocks.p95Milliseconds >= 0)
    }

    @Test("nested Scala maximum fixture is deterministic and structurally representative")
    func nestedScalaMaximumFixtureIsDeterministic() {
        let fixture = CodeHighlightBenchmarkFixtures.nestedScalaMaximum()

        #expect(fixture.utf8.count == Self.maximumBytes)
        #expect(fixture.contains("final case class Box[A]"))
        #expect(fixture.contains("Vector.tabulate"))
        #expect(fixture.contains("s\"key-$seed-$outer\""))
        #expect(fixture.contains("Map[String, List[Int]]"))
    }

    /// A filtered `swift test -c release` invocation is the committed
    /// fresh-process shell for the maximum-size Scala RSS probe. The output
    /// environment is intentionally opt-in so ordinary test runs do not write
    /// benchmark evidence.
    @Test("release maximum nested Scala probe writes bounded fresh-process evidence")
    func releaseMaximumNestedScalaProbe() throws {
        guard let rawOutput = ProcessInfo.processInfo.environment["CODE_HIGHLIGHT_RELEASE_PROBE_OUTPUT"] else {
            return
        }

        try Self.validateCorpus()
        let root = Self.repositoryRoot()
        let output = URL(fileURLWithPath: rawOutput).standardizedFileURL
        let expectedDirectory = root
            .appending(path: "tmp/orchestration/markdown-renderer-embeds/benchmark")
            .standardizedFileURL
        guard output.deletingLastPathComponent() == expectedDirectory,
              output.pathExtension == "json"
        else {
            throw BenchmarkError.invalidOutputPath
        }

        let source = CodeHighlightBenchmarkFixtures.nestedScalaMaximum(bytes: Self.maximumBytes)
        let sourceBytes = source.utf8.count
        guard sourceBytes == Self.maximumBytes else { throw BenchmarkError.invalidFixtureSize }

        // Fixture construction deliberately precedes this baseline. `ru_maxrss`
        // is process-wide and monotonic, so the reported delta is a limitation,
        // not an allocation attribution claim.
        let baselineRSS = Self.peakRSSBytes()
        for _ in 0..<Self.warmupRuns {
            _ = CodeSyntaxHighlighter.highlightedHTML(
                source: source,
                language: .scala,
                isCancelled: { false })
        }

        var samples: [ReleaseSample] = []
        samples.reserveCapacity(Self.measuredSamples)
        for _ in 0..<Self.measuredSamples {
            var recorded: CodeHighlightMeasurement?
            guard let html = CodeSyntaxHighlighter.highlightedHTML(
                source: source,
                language: .scala,
                isCancelled: { false },
                measurement: { recorded = $0 }
            ), let measurement = recorded
            else {
                throw BenchmarkError.highlightFailed
            }
            guard html.unicodeScalars.count >= source.unicodeScalars.count else {
                throw BenchmarkError.textContractFailed
            }
            samples.append(ReleaseSample(measurement: measurement))
        }
        let afterRSS = Self.peakRSSBytes()

        let evidence = ReleaseEvidence(
            artifactKind: "fresh-process-release-maximum-scala",
            fixtureSource: "CodeHighlightBenchmarkFixtures",
            fixtureID: CodeHighlightBenchmarkFixtures.nestedScalaMaximumID,
            configuration: ProcessInfo.processInfo.environment["CODE_HIGHLIGHT_RELEASE_PROBE_CONFIGURATION"]
                ?? "unspecified optimized probe configuration",
            compiler: "SwiftPM release; CTreeSitterHighlighting uses -UDEBUG",
            head: ProcessInfo.processInfo.environment["CODE_HIGHLIGHT_RELEASE_PROBE_HEAD"] ?? "unspecified",
            base: ProcessInfo.processInfo.environment["CODE_HIGHLIGHT_RELEASE_PROBE_BASE"] ?? "unspecified",
            sourceBytes: sourceBytes,
            warmupRuns: Self.warmupRuns,
            measuredSamples: Self.measuredSamples,
            parser: Self.summary(samples.map(\.parserMilliseconds)),
            query: Self.summary(samples.map(\.queryMilliseconds)),
            rangeValidation: Self.summary(samples.map(\.rangeValidationMilliseconds)),
            htmlAssembly: Self.summary(samples.map(\.htmlAssemblyMilliseconds)),
            total: Self.summary(samples.map(\.totalMilliseconds)),
            captureCount: samples.first?.captureCount ?? 0,
            emittedTokenCount: samples.first?.tokenCount ?? 0,
            validatedRangeCount: samples.first?.tokenCount ?? 0,
            rssScope: "fresh-process, process-wide ru_maxrss delta after fixture construction; monotonic peak is not allocation attribution",
            rssDeltaBytes: afterRSS >= baselineRSS ? afterRSS - baselineRSS : 0)

        try FileManager.default.createDirectory(at: expectedDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output)
    }

    private struct Fixture: Sendable {
        let language: CodeLanguage
        let source: String
    }

    private struct Summary: Codable {
        let p50Milliseconds: Double
        let p95Milliseconds: Double
    }

    private struct ReleaseSample {
        let parserMilliseconds: Double
        let queryMilliseconds: Double
        let rangeValidationMilliseconds: Double
        let htmlAssemblyMilliseconds: Double
        let totalMilliseconds: Double
        let captureCount: UInt32
        let tokenCount: UInt32

        init(measurement: CodeHighlightMeasurement) {
            parserMilliseconds = Self.milliseconds(measurement.parserNanoseconds)
            queryMilliseconds = Self.milliseconds(measurement.queryNanoseconds)
            rangeValidationMilliseconds = Self.milliseconds(measurement.rangeValidationNanoseconds)
            htmlAssemblyMilliseconds = Self.milliseconds(measurement.htmlAssemblyNanoseconds)
            totalMilliseconds = Self.milliseconds(measurement.totalNanoseconds)
            captureCount = measurement.captureCount
            tokenCount = measurement.tokenCount
        }

        private static func milliseconds(_ nanoseconds: UInt64) -> Double {
            Double(nanoseconds) / 1_000_000
        }
    }

    private struct ReleaseEvidence: Codable {
        let artifactKind: String
        let fixtureSource: String
        let fixtureID: String
        let configuration: String
        let compiler: String
        let head: String
        let base: String
        let sourceBytes: Int
        let warmupRuns: Int
        let measuredSamples: Int
        let parser: Summary
        let query: Summary
        let rangeValidation: Summary
        let htmlAssembly: Summary
        let total: Summary
        let captureCount: UInt32
        let emittedTokenCount: UInt32
        let validatedRangeCount: UInt32
        let rssScope: String
        let rssDeltaBytes: UInt64
    }

    private enum BenchmarkError: Error {
        case invalidOutputPath
        case invalidFixtureSize
        case highlightFailed
        case textContractFailed
    }

    private struct Evidence: Codable {
        let measurementRole: String
        let configuration: String
        let fiveGrammar: Summary
        let hundredKiB: Summary
        let maximum: Summary
        let hundredBlocks: Summary
        let rssScope: String
        let processWideMaximumRSSDeltaBytes: UInt64
    }

    private static func fixtures() -> (smallAndMalformed: [Fixture], hundredKiB: String, maximumScala: String, hundredBlocks: String) {
        let small: [Fixture] = [
            Fixture(language: .java, source: "class Example { int value = 1; }"),
            Fixture(language: .scala, source: "object Example { val value = 1 }"),
            Fixture(language: .html, source: "<div class=\"example\">value</div>"),
            Fixture(language: .swift, source: "let value = 1"),
            Fixture(language: .json, source: "{\"value\": 1}"),
            Fixture(language: .java, source: "class {"),
            Fixture(language: .scala, source: "object { val"),
            Fixture(language: .html, source: "<div><span>"),
            Fixture(language: .swift, source: "func {"),
            Fixture(language: .json, source: "{\"unterminated\": ["),
        ]
        let hundredKiB = CodeHighlightBenchmarkFixtures.source(language: .swift, bytes: hundredKiBBytes)
        let maximumScala = CodeHighlightBenchmarkFixtures.nestedScalaMaximum(bytes: maximumBytes)
        let hundredBlocks = CodeHighlightBenchmarkFixtures.representativeFencedBlocks()
        return (small, hundredKiB, maximumScala, hundredBlocks)
    }

    private static func measure(_ count: Int, operation: () -> Void) -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let started = DispatchTime.now().uptimeNanoseconds
            operation()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            samples.append(Double(elapsed) / 1_000_000)
        }
        return samples
    }

    private static func summary(_ samples: [Double]) -> Summary {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[(sorted.count * 95 + 99) / 100 - 1]
        return Summary(p50Milliseconds: p50, p95Milliseconds: p95)
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func peakRSSBytes() -> UInt64 {
        var usage = rusage()
        let result = getrusage(RUSAGE_SELF, &usage)
        precondition(result == 0, "getrusage(RUSAGE_SELF) failed")
        return UInt64(usage.ru_maxrss)
    }

    private static func validateCorpus() throws {
        let root = repositoryRoot()
        let corpusURL = root.appending(path: "Tests/WikiFSAppTests/Fixtures/CodeHighlightBenchmarkCorpus.json")
        let data = try Data(contentsOf: corpusURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let corpus = object as? [String: Any],
              corpus["artifactKind"] as? String == "deterministic-fixture-metadata",
              corpus["fixtureSource"] as? String == "CodeHighlightBenchmarkFixtures",
              corpus["representativeScalaFixture"] as? String == CodeHighlightBenchmarkFixtures.nestedScalaMaximumID,
              corpus["warmupRuns"] as? Int == warmupRuns,
              corpus["measuredSamples"] as? Int == measuredSamples
        else {
            throw NSError(domain: "CodeHighlightPerformanceTests", code: 1)
        }
    }

    private static func writeEvidence(_ evidence: Evidence) throws {
        let root = repositoryRoot()
        let directory = root.appending(path: "tmp/orchestration/markdown-renderer-embeds/benchmark")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: directory.appending(path: "debug-measurement.json"))
    }
}
#endif
