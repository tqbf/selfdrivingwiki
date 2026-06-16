import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the shared upsert+reparse seam (`PageUpsert`) that the app model and
/// `wikictl` both call — the doc's "no second drifting implementation in the CLI"
/// guarantee lives here.
struct PageUpsertTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-upsert-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - create vs update

    @Test func upsertByTitleCreatesWhenAbsent() throws {
        let store = try tempStore()
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Fresh", body: "hi")
        #expect(outcome.didCreate)
        let page = try store.getPage(id: outcome.id)
        #expect(page.title == "Fresh")
        #expect(page.bodyMarkdown == "hi")
    }

    @Test func upsertByTitleUpdatesExisting() throws {
        let store = try tempStore()
        let created = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let updated = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v2")
        #expect(!updated.didCreate)
        // Same page resolved by title, not a second one.
        #expect(updated.id == created.id)
        #expect(try store.getPage(id: created.id).bodyMarkdown == "v2")
        #expect(try store.listPages().count == 1)
    }

    @Test func upsertByExplicitIDUpdatesThatPage() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Original")
        let outcome = try PageUpsert.upsert(in: store, id: page.id, title: "Renamed", body: "body")
        #expect(!outcome.didCreate)
        #expect(outcome.id == page.id)
        let reloaded = try store.getPage(id: page.id)
        #expect(reloaded.title == "Renamed")
        #expect(reloaded.bodyMarkdown == "body")
    }

    @Test func upsertByTitleResolvesDuplicateToLowestULID() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "Dup")
        let b = try store.createPage(title: "Dup")
        // `ULID.generate()` is NOT monotonic within a millisecond (80 independent
        // random bits), so creation order does not guarantee ULID order — pick the
        // actually-lowest ULID to assert against rather than assuming `a` < `b`.
        let lowest = a.id.rawValue < b.id.rawValue ? a.id : b.id
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Dup", body: "edited")
        #expect(outcome.id == lowest)
        #expect(try store.getPage(id: lowest).bodyMarkdown == "edited")
    }

    // MARK: - link reparse (the load-bearing reason it's shared)

    @Test func upsertReparsesLinksFromBody() throws {
        let store = try tempStore()
        _ = try store.createPage(title: "Target")
        let outcome = try PageUpsert.upsert(
            in: store,
            id: nil,
            title: "Home",
            body: "see [[Target]] and [[Ghost]]"
        )
        let links = try store.listAllLinks()
        // Only the resolvable link is written; the ghost target is omitted.
        #expect(links.count == 1)
        #expect(links.first?.from == outcome.id.rawValue)
        #expect(links.first?.linkText == "Target")
    }

    @Test func upsertReplacesLinksNotAppends() throws {
        let store = try tempStore()
        _ = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        let outcome = try PageUpsert.upsert(in: store, id: nil, title: "Src", body: "[[A]]")
        #expect(try store.listAllLinks().count == 1)

        // A second upsert with a different link set replaces, not appends.
        _ = try PageUpsert.upsert(in: store, id: outcome.id, title: "Src", body: "[[B]]")
        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.linkText == "B")
    }

    @MainActor
    @Test func upsertMatchesInAppModelLinkGraph() throws {
        // The doc's core promise: a CLI-style upsert and an in-app save leave the
        // SAME page_links rows. Drive one wiki via PageUpsert directly and an
        // identical-content one via the model, then compare the link graphs.
        let cli = try tempStore()
        _ = try cli.createPage(title: "X")
        let cliOutcome = try PageUpsert.upsert(in: cli, id: nil, title: "P", body: "[[X]] [[X]]")

        let appStore = try tempStore()
        _ = try appStore.createPage(title: "X")
        let model = WikiStoreModel(store: appStore)
        model.newPage(title: "P")
        model.draftBody = "[[X]] [[X]]"
        model.save()

        let cliLinks = try cli.listAllLinks().map(\.linkText)
        let appLinks = try appStore.listAllLinks().map(\.linkText)
        #expect(cliLinks == appLinks)
        #expect(cliLinks == ["X"])    // deduped by target, resolved
        #expect(cliOutcome.id.rawValue.isEmpty == false)
    }
}
