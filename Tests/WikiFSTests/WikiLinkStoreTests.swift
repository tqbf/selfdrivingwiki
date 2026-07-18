import Foundation
import Testing
@testable import WikiFSCore

/// Store-level tests for `[[wiki-link]]` resolution + `page_links` maintenance,
/// including the Phase-4 FK-safety regression on `deletePage`.
struct WikiLinkStoreTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-link-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
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
        let a = try store.createPage(title: "Dup")
        let b = try store.createPage(title: "Dup")
        // Two ULIDs minted in the same millisecond order by their random bits, not
        // by creation order — so don't assume the first-created id is the lower one.
        // Derive the expected winner from the actual ids; the contract under test is
        // that resolveTitleToID returns the lowest-ULID duplicate.
        let expectedLowest = min(a.id.rawValue, b.id.rawValue)
        #expect(try store.resolveTitleToID("Dup")?.rawValue == expectedLowest)
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
        // Contract: ordered by (from_page_id, to_page_id) ascending. ULIDs minted in
        // the same millisecond order by their random bits, so derive the expected
        // order from the actual ids rather than assuming creation order == lexical
        // order. The three links are a→b, a→c, c→a.
        let expected = [
            (a.id.rawValue, b.id.rawValue),
            (a.id.rawValue, c.id.rawValue),
            (c.id.rawValue, a.id.rawValue),
        ]
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        .map { "\($0.0)->\($0.1)" }
        #expect(links.map { "\($0.from)->\($0.to)" } == expected)
    }

    // MARK: - `#` inside a page title / source name

    @Test func replaceLinksResolvesPageTitleContainingHash() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let sharp = try store.createPage(title: "Agentic Static Analysis for C# Security Auditing")

        // Parsing splits the title at the `#` in "C#"; replaceLinks must retry
        // with the fragment re-attached and land the row on the real page.
        try store.replaceLinks(from: a.id, parsedLinks:
            WikiLinkParser.parse("[[Agentic Static Analysis for C# Security Auditing]]"))

        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.to == sharp.id.rawValue)
    }

    @Test func replaceLinksResolvesSourceCitationWithHashInName() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let src = try store.addSource(filename: "C# Notes.md", data: Data("hi".utf8))

        // The `#"` quote anchor is the delimiter, so the citation's name keeps
        // its "C#" and resolves (via the extension-stripping fallback).
        try store.replaceLinks(from: a.id, parsedLinks:
            WikiLinkParser.parse("[[source:C# Notes#\"a passage\"]]"))

        #expect(try store.sourceLinkingPages(to: src.id) == [a.id])
    }

    @Test func replaceLinksResolvesHashTitleWithRealAnchor() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let guide = try store.createPage(title: "C# Guide")

        // `#`-containing title PLUS a real section anchor — the longest name
        // that resolves wins ("C# Guide"), the rest is the anchor.
        try store.replaceLinks(from: a.id, parsedLinks:
            WikiLinkParser.parse("[[C# Guide#Methods]]"))

        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.to == guide.id.rawValue)
    }

    @Test func replaceLinksBothHashTitlesLand() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let guide = try store.createPage(title: "C# Guide")
        let notes = try store.createPage(title: "C# Notes")

        // Two `#`-titles sharing the mis-split base "C" — parse keeps both
        // (raw-target dedup) and each resolves to its own page.
        try store.replaceLinks(from: a.id, parsedLinks:
            WikiLinkParser.parse("[[C# Guide]] and [[C# Notes]]"))

        let targets: Set<String> = Set(try store.listAllLinks().map(\.to))
        #expect(targets == [guide.id.rawValue, notes.id.rawValue])
    }

    @Test func replaceLinksResolvesSourceNameWithHashWithoutQuoteAnchor() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        let src = try store.addSource(filename: "C# Notes.md", data: Data("hi".utf8))

        // No quote anchor → the name mis-splits at "C#"; the fragment-re-attach
        // fallback must still resolve the source.
        try store.replaceLinks(from: a.id, parsedLinks:
            WikiLinkParser.parse("[[source:C# Notes]]"))

        #expect(try store.sourceLinkingPages(to: src.id) == [a.id])
    }

    // MARK: - Lenient source-name resolution (pass 3)

    @Test func nearMissCitationResolvesUniqueLooseMatch() throws {
        let store = try tempStore()
        let src = try store.addSource(
            filename: "Agentic Static Analysis for C# Security Auditing.pdf",
            data: Data("%PDF".utf8))
        // Cited with a "(2026)" suffix the stored name doesn't have, and
        // without the ".pdf" the stored name does have.
        let resolved = try store.resolveSourceByName(
            "Agentic Static Analysis for C# Security Auditing (2026)")
        #expect(resolved == src.id)
    }

    @Test func ambiguousLooseMatchDoesNotResolve() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "Report (2025).pdf", data: Data("%PDF 2025".utf8))
        _ = try store.addSource(filename: "Report (2026).pdf", data: Data("%PDF 2026".utf8))
        // "Report" loose-matches both → refuse to guess.
        #expect(try store.resolveSourceByName("Report") == nil)
    }

    @Test func exactMatchBeatsLooseMatch() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "Paper.pdf", data: Data("%PDF".utf8))
        let exact = try store.addSource(filename: "Paper (2026).md", data: Data("hi".utf8))
        // "Paper (2026)" extension-strip-matches the second source exactly;
        // the loose tier (which would see both) must not be consulted.
        #expect(try store.resolveSourceByName("Paper (2026)") == exact.id)
    }

    // MARK: - LinkReconciler (startup self-heal)

    @Test func reconcileHealsCitationSavedBeforeSourceExisted() async throws {
        let store = try tempStore()
        let page = try store.createPage(title: "P")
        let body = "cites [[source:Agentic Static Analysis for C# Security Auditing (2026)#\"q\"]]"
        try store.updatePage(id: page.id, title: "P", body: body)
        try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(body))

        // Source ingested AFTER the page was saved → no link row yet.
        let src = try store.addSource(
            filename: "Agentic Static Analysis for C# Security Auditing.pdf",
            data: Data("%PDF".utf8))
        #expect(try store.sourceLinkingPages(to: src.id).isEmpty)

        try await LinkReconciler.reconcileAll(in: store)
        #expect(try store.sourceLinkingPages(to: src.id) == [page.id])
    }

    @Test func reconcileIsIdempotent() async throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        try store.updatePage(id: a.id, title: "A", body: "see [[B]]")
        try store.replaceLinks(from: a.id, parsedLinks: WikiLinkParser.parse("see [[B]]"))

        try await LinkReconciler.reconcileAll(in: store)
        try await LinkReconciler.reconcileAll(in: store)
        let links = try store.listAllLinks()
        #expect(links.count == 1)
        #expect(links.first?.from == a.id.rawValue)
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
        #expect(try store.listPages(sortBy: .lastUpdated).isEmpty)
    }

    @Test func deletePageCleansUpSourceLinks() throws {
        let store = try tempStore()

        // Create page A (independent, should survive)
        let pageA = try store.createPage(title: "A")

        // Ingest a source file
        let source = try store.addSource(filename: "test.txt", data: Data("test content".utf8))

        // Create page B that links to the source
        let pageB = try store.createPage(title: "B")

        // Create a source link from B to the source
        try store.replaceLinks(from: pageB.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: source.filename)
        ])

        // Verify the source link was created
        let sourceLinksBefore = try store.listAllSourceLinks()
        #expect(sourceLinksBefore.count == 1)
        #expect(sourceLinksBefore[0].from == pageB.id.rawValue)
        #expect(sourceLinksBefore[0].to == source.id.rawValue)

        // Delete page B — this must NOT throw (this was the bug: FK constraint on source_links.from_page_id)
        try store.deletePage(id: pageB.id)

        // Verify the source link was cleaned up
        #expect(try store.listAllSourceLinks().isEmpty)

        // Verify page A still exists
        let remainingPages = try store.listPages(sortBy: .lastUpdated)
        #expect(remainingPages.count == 1)
        #expect(remainingPages[0].id == pageA.id)

        // Verify the source still exists (deletePage should only clean source_links, not sources table)
        let sources = try store.listSources()
        #expect(sources.count == 1)
        #expect(sources[0].id == source.id)
        #expect(sources[0].filename == "test.txt")
    }

    // MARK: - Embed edges `role='embed'` (Phase 4a, AC.3)

    @Test func replaceLinksWritesCiteAndEmbedAsSeparateRows() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "A")
        let source = try store.addSource(filename: "img.png", data: Data([0x89]))

        // One cite + one embed to the SAME source → two rows (cite role='cite',
        // embed role='embed'; the `source_links_edge` unique index treats role
        // as part of the key so both survive INSERT OR IGNORE).
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: "img.png"),
            .init(linkType: .source, target: source.filename, linkText: "img.png", isEmbed: true),
        ])
        #expect(try store.listAllSourceLinks().count == 2)
    }

    @Test func replaceLinksDedupesDuplicateEmbeds() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "A")
        let source = try store.addSource(filename: "img.png", data: Data([0x89]))

        // Two embed links to the same source → one row (INSERT OR IGNORE on
        // the unique index collapses them).
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: "img.png", isEmbed: true),
            .init(linkType: .source, target: source.filename, linkText: "img.png", isEmbed: true),
        ])
        #expect(try store.listAllSourceLinks().count == 1)
    }
}
