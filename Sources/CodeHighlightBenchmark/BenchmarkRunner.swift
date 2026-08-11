// pattern: Imperative Shell

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
        let digest = fixtureDigest(Data(source.utf8))

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

    private static func fixtureDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        #else
        let digest = PortableSHA256.digest(data)
        #endif
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func peakRSSBytes() throws -> UInt64 {
        var usage = rusage()
        #if canImport(Darwin)
        let result = getrusage(RUSAGE_SELF, &usage)
        #else
        let result = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
        #endif
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

    #if canImport(Darwin)
    private static func sysctlString(_ name: String) -> String? {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else { return nil }
        return String(
            decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }
    #else
    private static func sysctlString(_: String) -> String? { nil }
    #endif
}

#if !canImport(CryptoKit)
private enum PortableSHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(_ data: Data) -> [UInt8] {
        var message = Array(data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var hash = initialHash
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                schedule[index] =
                    (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let first = smallSigma1(schedule[index - 2])
                let second = schedule[index - 7]
                let third = smallSigma0(schedule[index - 15])
                let fourth = schedule[index - 16]
                schedule[index] = first &+ second &+ third &+ fourth
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let choice = (e & f) ^ ((~e) & g)
                let first = bigSigma1(e)
                let temp1 = h &+ first &+ choice &+ roundConstants[index] &+ schedule[index]
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = bigSigma0(a)
                let temp2 = second &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            hash[0] &+= a
            hash[1] &+= b
            hash[2] &+= c
            hash[3] &+= d
            hash[4] &+= e
            hash[5] &+= f
            hash[6] &+= g
            hash[7] &+= h
        }

        return hash.flatMap { word in
            [
                UInt8(truncatingIfNeeded: word >> 24),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word),
            ]
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static func smallSigma0(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 7) ^ rotateRight(value, by: 18) ^ (value >> 3)
    }

    private static func smallSigma1(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 17) ^ rotateRight(value, by: 19) ^ (value >> 10)
    }

    private static func bigSigma0(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 2) ^ rotateRight(value, by: 13) ^ rotateRight(value, by: 22)
    }

    private static func bigSigma1(_ value: UInt32) -> UInt32 {
        rotateRight(value, by: 6) ^ rotateRight(value, by: 11) ^ rotateRight(value, by: 25)
    }
}
#endif
