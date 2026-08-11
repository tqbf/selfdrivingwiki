#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCodeHighlighting

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
            _ = MarkdownHTMLRenderer.render(fixtures.hundredBlocks, options: .reader)
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

    private struct Fixture: Sendable {
        let language: CodeLanguage
        let source: String
    }

    private struct Summary: Codable {
        let p50Milliseconds: Double
        let p95Milliseconds: Double
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
              corpus["representativeScalaFixtureDigestSHA256"] as? String == "2eb53bd571b7491b37080b27b5d0f927f6551168ee94e4d47b574f3363360f75",
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
