// pattern: Functional Core

import Foundation

struct BenchmarkSummary: Codable, Equatable {
    let p50Milliseconds: Double
    let p95Milliseconds: Double

    static func from(_ samples: [Double]) -> Self? {
        guard samples.isEmpty == false else { return nil }
        let sorted = samples.sorted()
        return Self(
            p50Milliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted[(sorted.count * 95 + 99) / 100 - 1])
    }
}

struct BenchmarkSample: Equatable {
    let parserMilliseconds: Double
    let queryMilliseconds: Double
    let rangeValidationMilliseconds: Double
    let htmlAssemblyMilliseconds: Double
    let totalMilliseconds: Double
    let captureCount: UInt32
    let tokenCount: UInt32
}

struct CodeHighlightBenchmarkReport: Codable, Equatable {
    let schemaVersion: Int
    let artifactKind: String
    let configuration: String
    let compilerFlags: String
    let operatingSystem: String
    let architecture: String
    let hardwareModel: String
    let activeProcessorCount: Int
    let head: String
    let tree: String
    let base: String
    let fixtureID: String
    let fixtureDigestSHA256: String
    let sourceBytes: Int
    let warmupRuns: Int
    let measuredSamples: Int
    let parser: BenchmarkSummary
    let query: BenchmarkSummary
    let rangeValidation: BenchmarkSummary
    let htmlAssembly: BenchmarkSummary
    let total: BenchmarkSummary
    let captureCount: UInt32
    let emittedTokenCount: UInt32
    let validatedRangeCount: UInt32
    let rssScope: String
    let rssDeltaBytes: UInt64
}

enum BenchmarkReportBuilder {
    static func make(
        options: CodeHighlightBenchmarkCommand.Options,
        system: BenchmarkSystemMetadata,
        fixtureID: String,
        fixtureDigestSHA256: String,
        sourceBytes: Int,
        warmupRuns: Int,
        samples: [BenchmarkSample],
        rssDeltaBytes: UInt64
    ) -> CodeHighlightBenchmarkReport? {
        guard let parser = BenchmarkSummary.from(samples.map(\.parserMilliseconds)),
              let query = BenchmarkSummary.from(samples.map(\.queryMilliseconds)),
              let rangeValidation = BenchmarkSummary.from(samples.map(\.rangeValidationMilliseconds)),
              let htmlAssembly = BenchmarkSummary.from(samples.map(\.htmlAssemblyMilliseconds)),
              let total = BenchmarkSummary.from(samples.map(\.totalMilliseconds)),
              let first = samples.first,
              samples.allSatisfy({ $0.captureCount == first.captureCount && $0.tokenCount == first.tokenCount })
        else {
            return nil
        }
        return CodeHighlightBenchmarkReport(
            schemaVersion: 1,
            artifactKind: "fresh-process-release-nested-scala-maximum",
            configuration: "SwiftPM release (-c release)",
            compilerFlags: "SwiftPM -c release; Swift targets -warnings-as-errors; CTreeSitterHighlighting -UDEBUG",
            operatingSystem: system.operatingSystem,
            architecture: system.architecture,
            hardwareModel: system.hardwareModel,
            activeProcessorCount: system.activeProcessorCount,
            head: options.head,
            tree: options.tree,
            base: options.base,
            fixtureID: fixtureID,
            fixtureDigestSHA256: fixtureDigestSHA256,
            sourceBytes: sourceBytes,
            warmupRuns: warmupRuns,
            measuredSamples: samples.count,
            parser: parser,
            query: query,
            rangeValidation: rangeValidation,
            htmlAssembly: htmlAssembly,
            total: total,
            captureCount: first.captureCount,
            emittedTokenCount: first.tokenCount,
            validatedRangeCount: first.tokenCount,
            rssScope: "fresh-process, process-wide ru_maxrss delta after fixture construction; monotonic peak is not allocation attribution",
            rssDeltaBytes: rssDeltaBytes)
    }

    static func encoded(_ report: CodeHighlightBenchmarkReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

struct BenchmarkSystemMetadata: Equatable {
    let operatingSystem: String
    let architecture: String
    let hardwareModel: String
    let activeProcessorCount: Int
}
