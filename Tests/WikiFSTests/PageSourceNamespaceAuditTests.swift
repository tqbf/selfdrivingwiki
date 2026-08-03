import Foundation
import Testing

/// Guards the provenance seam's PageID/SourceID separation without scanning
/// unrelated compatibility SQL elsewhere in the repository.
struct PageSourceNamespaceAuditTests {
    private func provenanceSources() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let relativePaths = [
            "Sources/WikiFSTypes/PageVersionSource.swift",
            "Sources/WikiFSCore/Store/WikiStore.swift",
            "Sources/WikiFSCore/Store/GRDBWikiStore.swift",
            "Sources/WikiFSCore/Core/PageUpsert.swift",
            "Sources/WikiCtlCore/PageCommand.swift",
            "Sources/WikiCtlCore/ArgumentParser.swift",
        ]
        return try relativePaths.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
    }

    @Test func productionProvenanceCodeHasNoRawPageSourceComparison() throws {
        let combined = try provenanceSources().joined(separator: "\n")
        let forbidden = [
            "pageID.rawValue == sourceID.rawValue",
            "sourceID.rawValue == pageID.rawValue",
            "PageID(rawValue: sourceID.rawValue)",
            "SourceID(rawValue: pageID.rawValue)",
        ]
        for expression in forbidden {
            #expect(!combined.contains(expression), "provenance code must not compare PageID and SourceID raw values: \(expression)")
        }
    }

    @Test func pageAndSourceIDsCannotCrossAPIBoundary() throws {
        let types = try provenanceSources().first ?? ""
        #expect(types.contains("let sourceID: SourceID"))
        #expect(types.contains("let pageVersionID: PageVersionID"))
        #expect(types.contains("let pageID: PageID"))
        #expect(!types.contains("let sourceID: String"))
        #expect(!types.contains("let pageID: String"))
    }
}
