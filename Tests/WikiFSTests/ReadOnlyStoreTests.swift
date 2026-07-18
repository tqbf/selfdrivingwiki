import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the read-only (`query_only`) store the File Provider extension
/// uses: it reads what the writer produced, and rejects writes.
struct ReadOnlyStoreTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ro-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    @Test func readsBackWriterContent() throws {
        let url = tempDatabaseURL()
        let id: PageID
        do {
            let writer = try GRDBWikiStore(databaseURL: url)
            let page = try writer.createPage(title: "Home")
            id = page.id
            try writer.updatePage(id: id, title: "Home", body: "# Welcome\n\nlive body")
        }

        let reader = try GRDBWikiStore(readOnlyURL: url)
        let page = try reader.getPage(id: id)
        #expect(page.title == "Home")
        #expect(page.bodyMarkdown == "# Welcome\n\nlive body")

        let summaries = try reader.listPages(sortBy: .lastUpdated)
        #expect(summaries.contains { $0.id == id })

        let all = try reader.listAllPagesOrderedByID()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
    }

    @Test func enumeratesMultiplePagesOrderedByID() throws {
        let url = tempDatabaseURL()
        let writer = try GRDBWikiStore(databaseURL: url)
        let a = try writer.createPage(title: "Alpha")
        let b = try writer.createPage(title: "Bravo")

        let reader = try GRDBWikiStore(readOnlyURL: url)
        let ids = try reader.listAllPagesOrderedByID().map(\.id.rawValue)
        // ULIDs sort lexicographically in creation order.
        #expect(ids == [a.id.rawValue, b.id.rawValue].sorted())
    }

    @Test func rejectsWrites() throws {
        let url = tempDatabaseURL()
        let page: WikiPage
        do {
            let writer = try GRDBWikiStore(databaseURL: url)
            page = try writer.createPage(title: "Home")
        }

        let reader = try GRDBWikiStore(readOnlyURL: url)
        // query_only=ON must reject the write at the SQLite layer.
        #expect(throws: (any Error).self) {
            try reader.updatePage(id: page.id, title: "Hacked", body: "nope")
        }
        #expect(throws: (any Error).self) {
            _ = try reader.createPage(title: "Should Fail")
        }
    }
}
