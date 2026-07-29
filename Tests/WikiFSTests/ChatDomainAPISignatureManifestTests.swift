import Foundation
import Testing

/// Keeps the reviewed chat-domain identifier surface explicit.
struct ChatDomainAPISignatureManifestTests {

    private struct Entry {
        let path: String
        let signature: String
    }

    private enum ManifestError: Error, CustomStringConvertible {
        case malformedLine(String)

        var description: String {
            switch self {
            case .malformedLine(let line):
                "malformed chat-domain API signature manifest line: \(line)"
            }
        }
    }

    private func normalizedWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func manifestEntries() throws -> [Entry] {
        let manifestURL = repositoryRoot()
            .appendingPathComponent("Tests/WikiFSTests/Fixtures/ChatDomainAPISignatures.txt")
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

    @Test func chatDomainIdentifierSignaturesRemainTyped() throws {
        let root = repositoryRoot()
        let entries = try manifestEntries()
        #expect(entries.isEmpty == false, "chat-domain API signature manifest must not be empty")

        for entry in entries {
            let sourceURL = root.appendingPathComponent(entry.path)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let normalizedSource = normalizedWhitespace(source)
            let normalizedSignature = normalizedWhitespace(entry.signature)
            #expect(
                normalizedSource.contains(normalizedSignature),
                "missing typed chat-domain API signature in \(entry.path): \(entry.signature)"
            )
        }
    }

    @Test func chatDomainConfigurationSurfacesStayTyped() throws {
        let root = repositoryRoot()
        let forbiddenFragmentsByPath: [String: [String]] = [
            "Sources/WikiFSEngine/ChatAgentRuntime.swift": [
                "public let optionID: String",
                "public let valueID: String",
                "func setConfiguration(_ change: String",
            ],
            "Sources/WikiFSEngine/ChatDomain.swift": [
                "currentValueID: String?",
                "availableModes: [String]",
                "optionID: String",
                "valueID: String",
            ],
        ]

        for (path, forbiddenFragments) in forbiddenFragmentsByPath {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            let normalizedSource = normalizedWhitespace(source)
            for forbiddenFragment in forbiddenFragments {
                #expect(
                    normalizedSource.contains(normalizedWhitespace(forbiddenFragment)) == false,
                    "unexpected stringly-typed chat configuration fragment in \(path): \(forbiddenFragment)"
                )
            }
        }
    }
}
