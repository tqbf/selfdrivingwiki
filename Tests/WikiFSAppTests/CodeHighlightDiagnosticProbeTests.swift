#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(3)))
struct CodeHighlightDiagnosticProbeTests {
    private static let sizes = [1_024, 10_240, 102_400]

    @Test("warm-process per-grammar stage probes")
    func warmProcessPerGrammarStageProbes() throws {
        var records: [ProbeRecord] = []
        for language in CodeLanguage.allCases {
            for size in Self.sizes {
                let source = Self.source(language: language, bytes: size)
                let first = try Self.run(source: source, language: language)
                let repeated = try (0..<3).map { _ in
                    try Self.run(source: source, language: language)
                }
                records.append(ProbeRecord(
                    language: language.rawValue,
                    sourceBytes: size,
                    first: first,
                    repeated: repeated))
            }
        }
        try Self.write(records)
    }

    private struct Stage: Codable {
        let setupNanoseconds: UInt64
        let parserNanoseconds: UInt64
        let queryNanoseconds: UInt64
        let rangeValidationNanoseconds: UInt64
        let htmlAssemblyNanoseconds: UInt64
        let totalNanoseconds: UInt64
        let captureCount: UInt32
        let tokenCount: UInt32
        let rangeCount: UInt32
        let peakRSSBytes: UInt64
    }

    private struct ProbeRecord: Codable {
        let language: String
        let sourceBytes: Int
        let first: Stage
        let repeated: [Stage]
    }

    private static func run(source: String, language: CodeLanguage) throws -> Stage {
        var observed: CodeHighlightMeasurement?
        let html = CodeSyntaxHighlighter.highlightedHTML(
            source: source,
            language: language,
            isCancelled: { false },
            measurement: { observed = $0 })
        guard html != nil, let observed else {
            throw NSError(domain: "CodeHighlightDiagnosticProbeTests", code: 1)
        }
        return Stage(
            setupNanoseconds: observed.setupNanoseconds,
            parserNanoseconds: observed.parserNanoseconds,
            queryNanoseconds: observed.queryNanoseconds,
            rangeValidationNanoseconds: observed.rangeValidationNanoseconds,
            htmlAssemblyNanoseconds: observed.htmlAssemblyNanoseconds,
            totalNanoseconds: observed.totalNanoseconds,
            captureCount: observed.captureCount,
            tokenCount: observed.tokenCount,
            rangeCount: observed.tokenCount,
            peakRSSBytes: peakRSSBytes())
    }

    private static func source(language: CodeLanguage, bytes: Int) -> String {
        let unit: String
        switch language {
        case .java: unit = "class Example { int value = 12345; } // fixture\n"
        case .scala: unit = "object Example { val value = 12345 } // fixture\n"
        case .html: unit = "<div class=\"example\">fixture 12345</div>\n"
        case .swift: unit = "let value = 12345 // fixture\n"
        case .json: unit = "{\"value\": 12345, \"fixture\": true}\n"
        }
        let repeated = String(repeating: unit, count: bytes / unit.utf8.count + 1)
        let end = repeated.utf8.index(repeated.utf8.startIndex, offsetBy: bytes)
        return String(decoding: repeated.utf8[..<end], as: UTF8.self)
    }

    private static func peakRSSBytes() -> UInt64 {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return UInt64(usage.ru_maxrss)
    }

    private static func write(_ records: [ProbeRecord]) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "tmp/orchestration/markdown-renderer-embeds/benchmark")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: directory.appending(path: "warm-process-probes.json"))
    }
}
#endif
