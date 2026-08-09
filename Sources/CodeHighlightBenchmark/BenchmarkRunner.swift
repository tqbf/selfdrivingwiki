// pattern: Imperative Shell

import CryptoKit
import Darwin
import Foundation
import WikiFSCodeHighlighting

enum CodeHighlightBenchmarkRunner {
    private static let warmupRuns = 3
    private static let measuredSamples = 20
    private static let evidenceDirectory = "tmp/orchestration/markdown-renderer-embeds/benchmark"

    enum Error: LocalizedError {
        case releaseBuildRequired
        case invalidOutputPath
        case outputExists
        case invalidFixtureSize
        case highlightFailed
        case nonDeterministicCounts
        case reportBuildFailed
        case rusageFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .releaseBuildRequired:
                "CodeHighlightBenchmark must run with swift run -c release"
            case .invalidOutputPath:
                "benchmark output must be a new JSON file directly under \(evidenceDirectory)"
            case .outputExists:
                "benchmark evidence output already exists"
            case .invalidFixtureSize:
                "nested Scala fixture did not match the accepted byte limit"
            case .highlightFailed:
                "production highlighter returned plain fallback during the benchmark"
            case .nonDeterministicCounts:
                "production highlighter produced inconsistent capture or token counts"
            case .reportBuildFailed:
                "benchmark report could not summarize the collected samples"
            case .rusageFailed(let code):
                "getrusage(RUSAGE_SELF) failed with code \(code)"
            }
        }
    }

    static func run(options: CodeHighlightBenchmarkCommand.Options) throws {
        #if DEBUG
        throw Error.releaseBuildRequired
        #else
        let outputURL = try validatedOutputURL(for: options.outputPath)
        guard FileManager.default.fileExists(atPath: outputURL.path) == false else { throw Error.outputExists }

        let source = CodeHighlightBenchmarkFixtures.nestedScalaMaximum()
        guard source.utf8.count == CodeHighlightingPolicy.maximumHighlightedSourceBytes else {
            throw Error.invalidFixtureSize
        }
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()

        // Fixture creation precedes the RSS baseline. Build discovery, process
        // setup, JSON serialization, and file writes all remain outside samples.
        let baselineRSS = try peakRSSBytes()
        for _ in 0..<warmupRuns {
            guard CodeSyntaxHighlighter.highlightedHTML(
                source: source,
                language: .scala,
                isCancelled: { false }
            ) != nil else {
                throw Error.highlightFailed
            }
        }

        var samples: [BenchmarkSample] = []
        samples.reserveCapacity(measuredSamples)
        for _ in 0..<measuredSamples {
            let started = DispatchTime.now().uptimeNanoseconds
            var measured: CodeHighlightMeasurement?
            guard CodeSyntaxHighlighter.highlightedHTML(
                source: source,
                language: .scala,
                isCancelled: { false },
                measurement: { measured = $0 }
            ) != nil,
            let measured
            else {
                throw Error.highlightFailed
            }
            let ended = DispatchTime.now().uptimeNanoseconds
            samples.append(BenchmarkSample(
                parserMilliseconds: milliseconds(measured.parserNanoseconds),
                queryMilliseconds: milliseconds(measured.queryNanoseconds),
                rangeValidationMilliseconds: milliseconds(measured.rangeValidationNanoseconds),
                htmlAssemblyMilliseconds: milliseconds(measured.htmlAssemblyNanoseconds),
                totalMilliseconds: milliseconds(ended - started),
                captureCount: measured.captureCount,
                tokenCount: measured.tokenCount))
        }
        let afterRSS = try peakRSSBytes()
        guard let report = BenchmarkReportBuilder.make(
            options: options,
            system: systemMetadata(),
            fixtureID: CodeHighlightBenchmarkFixtures.nestedScalaMaximumID,
            fixtureDigestSHA256: digest,
            sourceBytes: source.utf8.count,
            warmupRuns: warmupRuns,
            samples: samples,
            rssDeltaBytes: afterRSS >= baselineRSS ? afterRSS - baselineRSS : 0)
        else {
            throw Error.nonDeterministicCounts
        }
        let data = try BenchmarkReportBuilder.encoded(report)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .withoutOverwriting)
        #endif
    }

    private static func validatedOutputURL(for outputPath: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        let expectedDirectory = root.appending(path: evidenceDirectory).standardizedFileURL
        let output = root.appending(path: outputPath).standardizedFileURL
        guard output.pathExtension == "json", output.deletingLastPathComponent().path == expectedDirectory.path else {
            throw Error.invalidOutputPath
        }
        return output
    }

    private static func peakRSSBytes() throws -> UInt64 {
        var usage = rusage()
        let result = getrusage(RUSAGE_SELF, &usage)
        guard result == 0 else { throw Error.rusageFailed(result) }
        return UInt64(usage.ru_maxrss)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func systemMetadata() -> BenchmarkSystemMetadata {
        BenchmarkSystemMetadata(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture(),
            hardwareModel: sysctlString("hw.model") ?? "unavailable",
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    private static func architecture() -> String {
        var value = utsname()
        guard uname(&value) == 0 else { return "unavailable" }
        let machine = value.machine
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else { return nil }
        return String(
            decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }
}
