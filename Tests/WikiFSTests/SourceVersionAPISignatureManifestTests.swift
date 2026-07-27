import Foundation
import Testing

struct SourceVersionAPISignatureManifestTests {

    private struct Entry {
        let path: String
        let signature: String
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func manifestEntries() throws -> [Entry] {
        let manifestURL = repositoryRoot()
            .appendingPathComponent("Tests/WikiFSTests/Fixtures/SourceVersionAPISignatures.txt")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        return try manifest
            .split(whereSeparator: \.isNewline)
            .filter { $0.starts(with: "#") == false && $0.isEmpty == false }
            .map { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].isEmpty == false,
                      parts[1].isEmpty == false
                else {
                    throw ManifestError.malformedLine(String(line))
                }
                return Entry(path: String(parts[0]), signature: String(parts[1]))
            }
    }

    private enum ManifestError: Error, CustomStringConvertible {
        case malformedLine(String)

        var description: String {
            switch self {
            case .malformedLine(let line):
                "malformed source-version API signature manifest line: \(line)"
            }
        }
    }

    @Test func allSourceVersionSignaturesUseSourceVersionID() throws {
        let root = repositoryRoot()
        let entries = try manifestEntries()
        #expect(entries.isEmpty == false, "source-version API signature manifest must not be empty")

        for entry in entries {
            #expect(
                entry.signature.contains("SourceVersionID"),
                "manifest entry must assert a SourceVersionID namespace: \(entry.path)"
            )
            let sourceURL = root.appendingPathComponent(entry.path)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(
                source.contains(entry.signature),
                "missing SourceVersionID API signature in \(entry.path): \(entry.signature)"
            )
        }
    }
}
