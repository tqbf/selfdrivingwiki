import Foundation
import Testing

struct SourceMarkdownVersionAPISignatureManifestTests {

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

    private let typeEntries: Set<String> = [
        "source-markdown-version.id",
        "source-markdown-version.parent-id",
        "source-markdown-version.init",
        "extraction-alternative.id",
        "wiki-store.error",
        "wiki-store.select-active-markdown",
        "wiki-store.processed-markdown-version",
        "wiki-store.source-derived-chains",
        "wiki-store.processed-markdown-agent-names",
        "wiki-store.revert-processed-markdown",
        "wiki-store.set-active-markdown",
        "grdb.private-derived-version-ids",
        "grdb.private-derived-version-id-by-ordinal",
        "grdb.public-processed-markdown-version",
        "grdb.public-source-derived-chains",
        "grdb.public-processed-markdown-agent-names",
        "grdb.public-processed-markdown-alternatives.active-head",
        "grdb.private-resolve-version-pin",
        "grdb.public-append-processed-markdown.writer",
        "grdb.public-revert-processed-markdown",
        "grdb.public-set-active-markdown",
        "grdb.read-markdown-version",
        "grdb.read-markdown-version.decode-id",
        "grdb.private-markdown-derived-ref",
        "grdb.private-upsert-markdown-derived-ref",
        "grdb.private-append-processed-markdown-inline",
        "grdb.private-live-insert-markdown-version",
        "grdb.public-source-link-pin",
        "grdb.public-processed-markdown-producer",
        "model.processed-markdown-version",
        "model.source-derived-chains",
        "model.select-source-by-id",
        "model.pending-pinned-extraction",
        "model.consume-pending-pinned-extraction",
        "model.set-active-markdown",
        "model.processed-markdown-agent-names",
        "extraction-compare.left-id",
        "extraction-compare.right-id",
        "extraction-compare.selection-binding",
        "extraction-compare.set-active",
        "reader-markdown.pinned-extraction-id",
        "wiki-reader.context-pinned-extraction-id",
        "render-context.source-derived-chain",
        "render-context.pinned-extraction-id",
        "cli.source-command.set-active",
        "cli.source-command.run-set-active",
        "cli.argument-parser.source-set-active",
        "links.pin-from-url",
        "links.linkified.pin-id",
    ]

    private let surfaceEntries: Set<String> = [
        "wiki-store.processed-markdown-history",
        "wiki-store.processed-markdown-alternatives",
        "wiki-store.append-processed-markdown",
        "wiki-store.record-markdown-extraction",
        "grdb.public-processed-markdown-history",
        "grdb.public-processed-markdown-alternatives",
        "grdb.public-append-processed-markdown",
        "grdb.public-record-markdown-extraction",
        "grdb.public-replace-links",
        "model.processed-markdown-history",
        "model.save-processed-markdown",
        "model.seed-pdf-markdown",
        "model.re-extract-markdown",
        "model.processed-markdown-alternatives",
        "source-detail.consume-pinned-extraction",
        "source-detail.pending-pin-on-change",
        "source-detail.has-multiple-extractions",
        "source-detail.history-menu",
        "source-detail.nominate-active",
        "extraction-compare.refresh-alternatives",
        "wiki-reader.on-wikilink-pinned-route",
    ]

    private let reviewCriticalEntries: Set<String> = [
        "wiki-store.processed-markdown-history",
        "wiki-store.processed-markdown-alternatives",
        "wiki-store.append-processed-markdown",
        "wiki-store.record-markdown-extraction",
        "model.processed-markdown-history",
        "model.save-processed-markdown",
        "model.re-extract-markdown",
        "model.processed-markdown-alternatives",
        "model.select-source-by-id",
        "model.set-active-markdown",
        "extraction-compare.left-id",
        "extraction-compare.right-id",
        "extraction-compare.selection-binding",
        "extraction-compare.set-active",
        "source-detail.consume-pinned-extraction",
        "source-detail.pending-pin-on-change",
        "source-detail.history-menu",
        "source-detail.nominate-active",
        "reader-markdown.pinned-extraction-id",
        "wiki-reader.context-pinned-extraction-id",
        "wiki-reader.on-wikilink-pinned-route",
        "grdb.private-derived-version-id-by-ordinal",
        "grdb.private-resolve-version-pin",
        "grdb.public-source-link-pin",
        "links.pin-from-url",
        "links.linkified.pin-id",
    ]

    private var expectedEntryKeys: Set<String> {
        typeEntries.union(surfaceEntries)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func manifestEntries() throws -> [Entry] {
        let manifestURL = repositoryRoot()
            .appendingPathComponent("Tests/WikiFSTests/Fixtures/SourceMarkdownVersionAPISignatures.txt")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        return try manifest
            .split(whereSeparator: \.isNewline)
            .filter { $0.starts(with: "#") == false && $0.isEmpty == false }
            .map { line in
                let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4,
                      parts[0].isEmpty == false,
                      parts[1].isEmpty == false,
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
                "malformed source-markdown-version API signature manifest line: \(line)"
            }
        }
    }

    @Test func allMarkdownVersionSignaturesUseSourceMarkdownVersionID() throws {
        let root = repositoryRoot()
        let entries = try manifestEntries()
        #expect(entries.isEmpty == false, "source-markdown-version API signature manifest must not be empty")
        #expect(entries.count == expectedEntryKeys.count, "source-markdown-version manifest must not duplicate or omit reviewed entries")
        #expect(Set(entries.map(\.key)) == expectedEntryKeys, "source-markdown-version manifest must enumerate the full reviewed surface set")
        #expect(reviewCriticalEntries.isSubset(of: expectedEntryKeys), "review-critical source-markdown-version seams must stay explicitly enumerated in the expected key set")
        #expect(reviewCriticalEntries.isSubset(of: Set(entries.map(\.key))), "review-critical source-markdown-version seams must stay explicitly enumerated in the fixture")

        for entry in entries {
            if entry.kind == .typed {
                #expect(
                    entry.signature.contains("SourceMarkdownVersionID"),
                    "typed manifest entry must assert a SourceMarkdownVersionID namespace: \(entry.key)"
                )
            }
            let sourceURL = root.appendingPathComponent(entry.path)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(
                source.contains(entry.signature),
                "missing reviewed source-markdown-version surface in \(entry.path): \(entry.signature)"
            )
        }
    }

    @Test func liveWritersGenerateTypedIDsAdjacentToRuntimeInserts() throws {
        let sourceURL = repositoryRoot().appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let anchors = [
            "public func appendProcessedMarkdown(",
            "public func revertProcessedMarkdown(",
            "public func recordMarkdownExtraction(",
            "private func appendProcessedMarkdownInline(",
        ]

        for anchor in anchors {
            let window = try #require(
                sourceWindow(in: source, around: anchor, maxLength: 9000),
                "missing live source-markdown-version writer anchor: \(anchor)"
            )
            #expect(
                window.contains("SourceMarkdownVersionID(rawValue: ULID.generate())"),
                "live source-markdown-version writer lost typed ID generation near \(anchor)"
            )
            #expect(
                window.contains("INSERT INTO source_markdown_versions"),
                "live source-markdown-version writer lost runtime source_markdown_versions insert near \(anchor)"
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
