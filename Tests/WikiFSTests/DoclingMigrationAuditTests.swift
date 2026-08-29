import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// Execution-scope audit (issue #1159 — AC.19): after the Docling migration
/// no PRODUCTION host Docling extraction adapter remains. `DoclingServeClient`
/// survives only as the shared request implementation behind the Settings
/// connection test (the app target), never as an extraction execution path in
/// the engine or daemon.
struct DoclingExecutionScopeAuditTests {

    /// Engine sources must not construct `DoclingServeClient` nor register a
    /// host Docling execution backend. The watch list is the ENTIRE engine
    /// module directory (PR 4 review HIGH-2: a hard-coded file list let a
    /// bypass survive in a file that was not listed).
    @Test func noProductionHostAdapterOrDirectConstruction() throws {
        let engineDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WikiFSEngine", isDirectory: true)
        let forbidden = [
            "DoclingServeClient(",
            "readCredential(.doclingServeToken)",
            "secret(.doclingServeToken)",
        ]
        let enumerator = FileManager.default.enumerator(
            at: engineDirectory, includingPropertiesForKeys: nil)
        var checked = 0
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            checked += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                #expect(
                    source.contains(needle) == false,
                    "\(file.lastPathComponent) must not construct a host Docling execution path: \(needle)")
            }
        }
        #expect(checked > 10, "expected to scan the engine module sources")
    }

}

/// The typed Docling timeout field (#1159): deterministic Codable round trip
/// and the 600-second compatibility default for files written before the
/// field existed.
struct ExtractionConfigDoclingTimeoutTests {

    @Test func timeoutFieldRoundTripsDeterministically() throws {
        var configuration = ExtractionConfig()
        configuration.doclingServeEndpoint = "http://127.0.0.1:8000"
        configuration.doclingServeTimeoutMilliseconds = 900_000
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ExtractionConfig.self, from: data)
        #expect(decoded.doclingServeTimeoutMilliseconds == 900_000)
        #expect(decoded.effectiveDoclingServeTimeoutMilliseconds == 900_000)
        #expect(
            String(decoding: data, as: UTF8.self).contains("doclingServeTimeoutMilliseconds"))
    }

    @Test func absentFieldKeepsTheCompatibilityDefault() throws {
        // A legacy config without the key decodes cleanly and keeps the
        // exact pre-field behavior: 600 seconds.
        let legacy = """
        {"backend":"localPdf2md"}
        """
        let decoded = try JSONDecoder().decode(
            ExtractionConfig.self, from: Data(legacy.utf8))
        #expect(decoded.doclingServeTimeoutMilliseconds == nil)
        #expect(decoded.effectiveDoclingServeTimeoutMilliseconds == 600_000)
    }

    @Test func outOfRangeValuesFallBackToTheDefault() {
        var configuration = ExtractionConfig()
        configuration.doclingServeTimeoutMilliseconds = 0
        #expect(configuration.effectiveDoclingServeTimeoutMilliseconds == 600_000)
        configuration.doclingServeTimeoutMilliseconds = 1_800_001
        #expect(configuration.effectiveDoclingServeTimeoutMilliseconds == 600_000)
        configuration.doclingServeTimeoutMilliseconds = 1
        #expect(configuration.effectiveDoclingServeTimeoutMilliseconds == 1)
    }
}
