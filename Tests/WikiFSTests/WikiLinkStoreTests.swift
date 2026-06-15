import Foundation
import Testing
@testable import WikiFSCore

/// Store-level tests for `[[wiki-link]]` resolution + `page_links` maintenance,
/// including the Phase-4 FK-safety regression on `deletePage`.
struct WikiLinkStoreTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-link-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - resolveTitleToID

    @Test func resolvesTitleToID() throws {
        let store = try tempStore()
        let home = try store.createPage(title: "Home")
        #expect(try store.resolveTitleToID("Home") == home.id)
        #expect(try store.resolveTitleToID("Nonexistent") == nil)
    }

    @Test func resolvesDuplicateTitleToLowestULID() throws {
        let store = try tempStore()
        let first = try store.createPage(title: "Dup")   // older → lower ULID
        let second = try store.createPage(title: "Dup")
        #expect(first.id.rawValue < second.id.rawValue)
        #expect(try store.resolveTitleToID("Dup") == first.id)
    }

    // MARK: - replaceLinks

    @Test func replaceLinksWritesResolvedRowsOnly() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")

        try store.replaceLinks(from: a.id, parsedLinks: [
            .init(target: "B", linkText: "the B page"),
            .init(target: "Ghost", linkText: "ghost"),   // unresolved → omitted
        ])

        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.from == a.id.rawValue)
        #expect(links.first?.to == b.id.rawValue)
        #expect(links.first?.linkText == "the B page")
    }

    @Test func replaceLinksDedupesSameTarget() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")

        // Two parsed links resolving to the same page → one row (INSERT OR IGNORE
        // on the (from,to) primary key). (The parser already dedupes by target;
        // this guards the store layer too.)
        try store.replaceLinks(from: a.id, parsedLinks: [
            .init(target: "B", linkText: "first"),
            .init(target: "B", linkText: "second"),
        ])
        #expect(try store.listAllLinks().count == 1)
    }

    @Test func replaceLinksReplacesNotAppends() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        _ = try store.createPage(title: "C")

        try store.replaceLinks(from: a.id, parsedLinks: [.init(target: "B", linkText: "B")])
        #expect(try store.listAllLinks().count == 1)

        // Re-save with a different link set → old rows gone, only new remain.
        try store.replaceLinks(from: a.id, parsedLinks: [.init(target: "C", linkText: "C")])
        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.linkText == "C")
    }

    @Test func selfLinkIsAllowed() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        try store.replaceLinks(from: a.id, parsedLinks: [.init(target: "A", linkText: "A")])
        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.from == a.id.rawValue)
        #expect(links.first?.to == a.id.rawValue)
    }

    // MARK: - listAllLinks ordering

    @Test func listAllLinksOrdersByFromThenTo() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")   // lowest ULID
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")

        try store.replaceLinks(from: c.id, parsedLinks: [.init(target: "A", linkText: "A")])
        try store.replaceLinks(from: a.id, parsedLinks: [
            .init(target: "C", linkText: "C"),
            .init(target: "B", linkText: "B"),
        ])

        let links = try store.listAllLinks()
        // Ordered by (from, to): a→b, a→c, then c→a.
        #expect(links.map { $0.from } == [a.id.rawValue, a.id.rawValue, c.id.rawValue])
        #expect(links[0].to == b.id.rawValue)
        #expect(links[1].to == c.id.rawValue)
        #expect(links[2].to == a.id.rawValue)
    }

    // MARK: - deletePage FK safety (the Phase-4 regression)

    @Test func deletePageCleansUpLinksAsSourceAndTarget() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")

        // A links to B → B is referenced as a link TARGET.
        try store.replaceLinks(from: a.id, parsedLinks: [.init(target: "B", linkText: "B")])
        #expect(try store.listAllLinks().count == 1)

        // Deleting B (a link target) must succeed despite foreign_keys=ON, and
        // the link row touching B must be gone.
        try store.deletePage(id: b.id)
        #expect(try store.listAllLinks().isEmpty)

        // Deleting A (the former link source) must also succeed.
        try store.deletePage(id: a.id)
        #expect(try store.listPages().isEmpty)
    }
}
