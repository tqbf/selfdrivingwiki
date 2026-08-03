import Foundation
import Testing

struct SourceVersionAPISignatureManifestTests {

    private enum EntryKind: String {
        case typed
        case surface
    }

    private struct Entry {
        let key: String
        let kind: EntryKind
        let path: String
        let signature: String
    }

    private let expectedEntryKeys: Set<String> = [
        "source-version.id",
        "source-version.parent-id",
        "source-version.init",
        "source-origin.version-id",
        "source-origin.init",
        "source-markdown-version.source-version-id",
        "source-markdown-version.init",
        "wiki-store.error",
        "wiki-store.active-content-version",
        "wiki-store.append-content-version",
        "wiki-store.record-markdown-extraction",
        "grdb.source-origin.routes-through-origin-from",
        "grdb.source-edit-history.routes-through-origin-from",
        "grdb.private-active-content-version",
        "grdb.public-active-content-version",
        "grdb.read-source-version",
        "grdb.read-source-version.decode-id",
        "grdb.origin-from",
        "grdb.public-append-content-version",
        "grdb.public-append-content-version.writer",
        "grdb.record-markdown-extraction",
        "grdb.public-rollback-source-content",
        "grdb.private-rollback-source-content-body",
        "grdb.public-content-version-history",
    ]

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
                let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4,
                      parts[0].isEmpty == false,
                      parts[1].isEmpty == false,
                      parts[0].isEmpty == false,
                      parts[2].isEmpty == false,
                      parts[3].isEmpty == false,
                      let kind = EntryKind(rawValue: String(parts[1]))
                else {
                    throw ManifestError.malformedLine(String(line))
                }
                return Entry(
                    key: String(parts[0]),
                    kind: kind,
                    path: String(parts[2]),
                    signature: String(parts[3])
                )
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
        #expect(Set(entries.map(\.key)) == expectedEntryKeys, "source-version manifest must enumerate the full reviewed surface set")

        for entry in entries {
            if entry.kind == .typed {
                #expect(
                    entry.signature.contains("SourceVersionID"),
                    "typed manifest entry must assert a SourceVersionID namespace: \(entry.key)"
                )
            }
            let sourceURL = root.appendingPathComponent(entry.path)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(
                source.contains(entry.signature),
                "missing reviewed source-version surface in \(entry.path): \(entry.signature)"
            )
        }
    }

    @Test func liveSourceVersionWritersGenerateTypedIDsAdjacentToRuntimeInserts() throws {
        let sourceURL = repositoryRoot().appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let anchors = [
            "public func addSource(",
            "public func addBytelessSource(",
            "public func appendContentVersion(",
            "public func addSnapshotImage(",
        ]

        for anchor in anchors {
            let window = try #require(
                sourceWindow(in: source, around: anchor, maxLength: 9000),
                "missing live source-version writer anchor: \(anchor)"
            )
            #expect(
                window.contains("let versionID = SourceVersionID(rawValue: ULID.generate())"),
                "live source-version writer lost typed ID generation near \(anchor)"
            )
            #expect(
                window.contains("INSERT INTO source_versions"),
                "live source-version writer lost runtime source_versions insert near \(anchor)"
            )
        }
    }

    private func sourceWindow(in source: String, around anchor: String, maxLength: Int) -> String? {
        guard let range = source.range(of: anchor) else { return nil }
        let lowerBound = range.lowerBound
        let startOffset = source.distance(from: source.startIndex, to: lowerBound)
        let endOffset = min(source.count, startOffset + maxLength)
        let endIndex = source.index(source.startIndex, offsetBy: endOffset)
        return String(source[lowerBound..<endIndex])
    }
}
