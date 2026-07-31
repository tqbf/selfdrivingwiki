import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Store-level contracts for the immutable page-version/source edge table.
struct PageVersionSourceStoreTests {
    private func citedVersion(
        in store: GRDBWikiStore
    ) throws -> (pageID: PageID, sourceID: SourceID, versionID: PageVersionID) {
        let page = try store.createPage(title: "Claim")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "tester",
            provenance: [.init(sourceID: source.id, role: .primary)])
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        return (page.id, source.id, versionID)
    }

    @Test func insertsTypedEdge() throws {
        let store = try TestStoreFactory.inMemory()
        let cited = try citedVersion(in: store)
        #expect(try store.pageVersionSources(versionID: cited.versionID) == [
            .init(pageVersionID: cited.versionID, sourceID: cited.sourceID, role: .primary),
        ])
    }

    @Test func rejectsUnknownRoleAtBoundary() {
        #expect(throws: PageVersionProvenanceWriteError.invalidRole(rawValue: "unknown")) {
            _ = try ArgumentParser.parse(
                ["--wiki", "test", "page", "add", "--title", "Claim", "--body-file", "-",
                 "--source", "source:unknown"], env: { _ in nil })
        }
    }

    @Test func enforcesUniqueTriple() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Claim")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let input = PageVersionSourceInput(sourceID: source.id, role: .primary)

        #expect(throws: PageVersionProvenanceWriteError.duplicateInput(sourceID: source.id, role: .primary)) {
            try store.updatePage(id: page.id, title: page.title, body: "Claim", lastEditedBy: "tester", provenance: [input, input])
        }
        #expect(try store.pageHeadSources(pageID: page.id).isEmpty)
    }

    @Test func pageDeleteCascadesEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let cited = try citedVersion(in: store)
        try store.deletePage(id: cited.pageID)
        #expect(try store.pageVersionSources(versionID: cited.versionID).isEmpty)
    }

    @Test func versionGCcascadesEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let cited = try citedVersion(in: store)
        try store.deletePage(id: cited.pageID)
        _ = try store.vacuumPageVersions(dryRun: false)
        #expect(try store.pageVersionSources(versionID: cited.versionID).isEmpty)
    }

    @Test func sourceDeleteIsRestricted() throws {
        let store = try TestStoreFactory.inMemory()
        let cited = try citedVersion(in: store)
        #expect(throws: WikiStoreError.self) { try store.deleteSource(id: cited.sourceID) }
        #expect(try store.getSource(id: cited.sourceID).id == cited.sourceID)
    }

    @Test func edgeHasNoUpdateOrDeleteAPI() throws {
        let production = try String(contentsOfFile: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift").path, encoding: .utf8)
        #expect(!production.contains("public func updatePageVersionSource"))
        #expect(!production.contains("public func deletePageVersionSource"))
    }
}
