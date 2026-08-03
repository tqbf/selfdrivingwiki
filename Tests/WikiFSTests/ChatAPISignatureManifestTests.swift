import Foundation
import Testing

/// Keeps the reviewed persisted-chat API boundary explicit. This is
/// deliberately narrow rather than a proximity search because many files still
/// legitimately contain page IDs, source IDs, or raw compatibility strings.
struct ChatAPISignatureManifestTests {

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
            .appendingPathComponent("Tests/WikiFSTests/Fixtures/ChatAPISignatures.txt")
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
                "malformed chat API signature manifest line: \(line)"
            }
        }
    }

    @Test func allChatEntitySignaturesUseChatID() throws {
        let root = repositoryRoot()
        let entries = try manifestEntries()
        #expect(entries.isEmpty == false, "chat API signature manifest must not be empty")

        for entry in entries {
            #expect(
                entry.signature.contains("ChatID"),
                "manifest entry must assert a ChatID namespace: \(entry.path)"
            )
            let sourceURL = root.appendingPathComponent(entry.path)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(
                source.contains(entry.signature),
                "missing ChatID API signature in \(entry.path): \(entry.signature)"
            )
        }
    }
}
