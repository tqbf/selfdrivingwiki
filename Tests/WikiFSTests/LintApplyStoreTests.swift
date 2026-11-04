import Foundation
import Testing
import WikiFSLinks
import WikiFSCore
import WikiFSTypes

/// The exact Apply semantics on the real GRDB store: one-event commits, the
/// canonicalization refusal, stale-head refusal, deleted-page refusal, and
/// append-only history.
struct LintApplyStoreTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-apply-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    @Test func applyCommitsPreviewedCandidateExactlyOnce() throws {
        let store = try tempStore()
        // lintCapture on a missing page is nil (the capture contract).
        #expect(try store.lintCapture(pageID: PageID(rawValue: "missing")) == nil)

        let created = try PageUpsert.upsert(
            in: store, id: nil, title: "Notes", body: "v1")
        let head1 = try #require(try store.pageHeadVersionID(pageID: created.id))
        let capture2 = try #require(try store.lintCapture(pageID: created.id))
        #expect(capture2.body == "v1")
        #expect(capture2.headVersionID == head1)

        // The candidate the user previewed (canonicalization is a no-op on
        // link-free bodies, so the previewed bytes ARE the canonical bytes).
        let candidate = "v1 repaired"
        let versionCountBefore = try store.pageVersionHistory(pageID: created.id).count
        _ = try PageUpsert.upsert(
            in: store, id: created.id, title: "Notes", body: candidate,
            expectation: .expectedHead(head1), author: PageAuthor.agent("lint-repair").rawValue,
            expectedCanonicalBody: candidate)
        let versionCountAfter = try store.pageVersionHistory(pageID: created.id).count
        #expect(versionCountAfter == versionCountBefore + 1)
        #expect(try store.getPage(id: created.id).bodyMarkdown == candidate)
        // History is append-only: the old version is still readable.
        let history = try store.pageVersionHistory(pageID: created.id)
        #expect(history.count == versionCountAfter)
    }

    @Test func lintCaptureIsNilForMissingPage() throws {
        let store = try tempStore()
        let capture = try store.lintCapture(pageID: PageID(rawValue: "nope"))
        #expect(capture == nil)
    }

    @Test func canonicalizationConflictRefusesZeroWrites() throws {
        let store = try tempStore()
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let head = try #require(try store.pageHeadVersionID(pageID: target.id))
        // The candidate references a page title that does not resolve YET.
        let candidate = "See [[Later Page]] for details.\n"
        // Preview parity: canonicalizing the candidate with public resolvers
        // leaves it byte-identical (Later Page does not exist).
        let previewed = (try WikiLinkRewriter.canonicalize(
            in: candidate,
            resolvePage: { try store.resolveTitleToID($0) },
            resolveSource: { try store.resolveSourceByName($0) },
            resolveChat: { try store.resolveChatByTitle($0) })) ?? candidate
        #expect(previewed == candidate)

        // Now a competing writer creates "Later Page" — the title graph moved.
        _ = try PageUpsert.upsert(in: store, id: nil, title: "Later Page", body: "x")
        // The store's head for Notes is unchanged, so a naive CAS would pass.
        #expect(try store.pageHeadVersionID(pageID: target.id) == head)

        // Apply with the pinned candidate: in-transaction canonicalization
        // now rewrites [[Later Page]] to ULID form → different bytes than
        // previewed → refuse with ZERO writes.
        #expect(throws: PageCanonicalizationConflictError.self) {
            _ = try PageUpsert.upsert(
                in: store, id: target.id, title: "Notes", body: candidate,
                expectation: .expectedHead(head),
                author: PageAuthor.agent("lint-repair").rawValue,
                expectedCanonicalBody: previewed)
        }
        // Zero writes: the body is unchanged and no version was appended.
        #expect(try store.getPage(id: target.id).bodyMarkdown == "v1")
        let versions = try store.pageVersionHistory(pageID: target.id)
        #expect(versions.count == 1) // only the original v1
    }

    @Test func canonicalizationStableApplyCommitsWhenGraphUnchanged() throws {
        let store = try tempStore()
        // Create the linked page FIRST so the candidate's link resolves
        // identically at preview and Apply time.
        _ = try PageUpsert.upsert(in: store, id: nil, title: "Later Page", body: "x")
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let head = try #require(try store.pageHeadVersionID(pageID: target.id))
        let candidate = "See [[Later Page]] for details.\n"
        // Preview.
        let previewed = (try WikiLinkRewriter.canonicalize(
            in: candidate,
            resolvePage: { try store.resolveTitleToID($0) },
            resolveSource: { try store.resolveSourceByName($0) },
            resolveChat: { try store.resolveChatByTitle($0) })) ?? candidate
        // The canonical form rewrites the title link to ULID form.
        #expect(previewed != candidate)
        #expect(previewed.contains("page:"))
        // Apply commits the PREVIEWED bytes.
        _ = try PageUpsert.upsert(
            in: store, id: target.id, title: "Notes", body: previewed,
            expectation: .expectedHead(head),
            author: PageAuthor.agent("lint-repair").rawValue,
            expectedCanonicalBody: previewed)
        #expect(try store.getPage(id: target.id).bodyMarkdown == previewed)
    }

    @Test func staleHeadRefusedWithZeroWrites() throws {
        let store = try tempStore()
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let staleHead = try #require(try store.pageHeadVersionID(pageID: target.id))
        // A competing writer advances the head.
        _ = try PageUpsert.upsert(in: store, id: target.id, title: "Notes", body: "v2",
                                  expectation: .unrestricted)
        #expect(throws: PageConflictError.self) {
            _ = try PageUpsert.upsert(
                in: store, id: target.id, title: "Notes", body: "v1 repaired",
                expectation: .expectedHead(staleHead),
                author: PageAuthor.agent("lint-repair").rawValue,
                expectedCanonicalBody: "v1 repaired")
        }
        #expect(try store.getPage(id: target.id).bodyMarkdown == "v2")
    }

    @Test func deletedPageRefusedWithZeroWrites() throws {
        let store = try tempStore()
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let head = try #require(try store.pageHeadVersionID(pageID: target.id))
        try store.deletePage(id: target.id)
        #expect(throws: PageExpectedTargetMissingError.self) {
            _ = try PageUpsert.upsert(
                in: store, id: target.id, title: "Notes", body: "v1 repaired",
                expectation: .expectedHead(head),
                author: PageAuthor.agent("lint-repair").rawValue,
                expectedCanonicalBody: "v1 repaired")
        }
    }

    @Test func doubleApplyAdvancesHeadSoSecondRefuses() throws {
        let store = try tempStore()
        let target = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "v1")
        let head = try #require(try store.pageHeadVersionID(pageID: target.id))
        // First Apply commits.
        _ = try PageUpsert.upsert(
            in: store, id: target.id, title: "Notes", body: "v1 repaired",
            expectation: .expectedHead(head),
            author: PageAuthor.agent("lint-repair").rawValue,
            expectedCanonicalBody: "v1 repaired")
        // The session's pinned head is now stale — a second click on Apply
        // (same snapshot head) refuses.
        #expect(throws: PageConflictError.self) {
            _ = try PageUpsert.upsert(
                in: store, id: target.id, title: "Notes", body: "v1 repaired",
                expectation: .expectedHead(head),
                author: PageAuthor.agent("lint-repair").rawValue,
                expectedCanonicalBody: "v1 repaired")
        }
    }

    @Test func lintCaptureCarriesResolutionFacts() throws {
        let store = try tempStore()
        _ = try PageUpsert.upsert(in: store, id: nil, title: "Alpha", body: "a")
        _ = try PageUpsert.upsert(in: store, id: nil, title: "Beta", body: "b")
        let alphaID = try #require(try store.resolveTitleToID("Alpha"))
        let capture = try #require(try store.lintCapture(pageID: alphaID))
        #expect(capture.title == "Alpha")
        #expect(capture.facts.knownPageTitles.contains("Beta"))
        #expect(capture.facts.pagesAvailable)
    }
}
