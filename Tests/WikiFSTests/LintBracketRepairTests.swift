import Foundation
import Testing
@testable import WikiFSCore

/// Phase 0 lint pre-flight regression tests: the coherent page read
/// (`PageCoherentRead`) and the CAS-guarded bracket auto-fix.
///
/// Races run against ONE file-backed WAL database opened through TWO real
/// `GRDBWikiStore` connections, so the competing writer is a genuine
/// concurrent SQLite writer, not a mock.
@MainActor
@Suite
struct LintSnapshotTests {

    private func tempFileStore() throws -> (store: GRDBWikiStore, url: URL) {
        try TestStoreFactory.fileBacked(prefix: "sdw-lint-snapshot")
    }

    /// Seed a page with one real content version carrying provenance, and
    /// return its head.
    @discardableResult
    private func seedPage(
        _ store: GRDBWikiStore, title: String, body: String,
        sourceName: String = "Smith2023"
    ) throws -> (page: WikiPage, head: PageVersionID?, source: SourceSummary) {
        let source = try store.addSource(filename: "\(sourceName).md", data: Data("raw bytes".utf8))
        let page = try store.createPage(
            title: title, body: body, createdBy: "test",
            provenance: [.init(sourceID: source.id, role: .primary)])
        let head = try store.pageHeadVersionID(pageID: page.id)
        return (page, head, source)
    }

    // MARK: - Coherent read

    /// `readPageCoherent` returns the body, head, and head provenance that
    /// belong to ONE snapshot: the head names a version whose recorded inputs
    /// are exactly the returned provenance, and the body is the pages-row
    /// body of that same state.
    @Test func coherentReadReturnsOneSnapshot() throws {
        let store = try TestStoreFactory.inMemory()
        let seeded = try seedPage(store, title: "Coherent", body: "body with [[source:Smith2023]]")

        let read = try store.readPageCoherent(id: seeded.page.id)
        #expect(read.id == seeded.page.id)
        #expect(read.title == "Coherent")
        #expect(read.body == "body with [[source:Smith2023]]")
        #expect(read.headVersionID == seeded.head)
        #expect(read.headSourceInputs == [.init(sourceID: seeded.source.id, role: .primary)])
    }

    /// The competing-writer contract: a coherent read taken BEFORE another
    /// writer commits supports a CAS write that fails cleanly (nothing
    /// written), and the NEXT coherent read sees the competitor's body AND
    /// head together — never a torn mix of the old body with the new head.
    @Test func coherentReadUnderCompetingWriter() throws {
        let (storeA, url) = try tempFileStore()
        let storeB = try GRDBWikiStore(databaseURL: url)
        let seeded = try seedPage(storeA, title: "Raced", body: "v1 body [[Page\\]]")

        // Connection A's snapshot of v1.
        let snapshot1 = try storeA.readPageCoherent(id: seeded.page.id)
        #expect(snapshot1.body == "v1 body [[Page\\]]")
        #expect(snapshot1.headVersionID == seeded.head)

        // Connection B commits a genuinely concurrent version.
        _ = try storeB.appendPageVersion(
            pageID: seeded.page.id, title: "Raced", body: "v2 body (competitor)",
            expectedHeadVersionID: snapshot1.headVersionID, lastEditedBy: "competitor")

        // A's CAS write composed from snapshot1 must now conflict — and
        // leave no trace.
        #expect(throws: PageConflictError.self) {
            _ = try PageUpsert.upsert(
                in: storeA, id: seeded.page.id, title: snapshot1.title,
                body: "v1 body [[Page]]",
                expectedHeadVersionID: snapshot1.headVersionID,
                author: PageAuthor.agent("lint").rawValue,
                provenance: snapshot1.headSourceInputs)
        }
        #expect(try storeA.getPage(id: seeded.page.id).bodyMarkdown == "v2 body (competitor)")

        // The NEXT coherent read is one snapshot of the NEW state: B's body
        // with B's head. The competitor declared no provenance on its
        // version, so the new head carries none — the SEED version still
        // holds the original input.
        let snapshot2 = try storeA.readPageCoherent(id: seeded.page.id)
        #expect(snapshot2.body == "v2 body (competitor)")
        #expect(snapshot2.headVersionID != snapshot1.headVersionID)
        #expect(snapshot2.headSourceInputs.isEmpty)
        #expect(try storeA.pageVersionSources(versionID: seeded.head!).map(\.sourceID) == [seeded.source.id])
    }

    /// A missing page surfaces as `WikiStoreError.notFound` — never as an
    /// empty snapshot.
    @Test func coherentReadMissingPageThrows() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(throws: WikiStoreError.self) {
            _ = try store.readPageCoherent(id: PageID(rawValue: "01HZY6X7Q8M2V3ABCDERSTU9WZ"))
        }
    }
}

/// Phase 0 bracket auto-fix regression tests: the temporary CAS write path
/// (captured head + unchanged provenance, one recomposition, hard stop after
/// a second conflict, honest success reporting).
@MainActor
@Suite
struct LintBracketRepairTests {

    private func tempFileStore() throws -> (store: GRDBWikiStore, url: URL) {
        try TestStoreFactory.fileBacked(prefix: "sdw-lint-bracket")
    }

    @discardableResult
    private func seedDamagedPage(_ store: GRDBWikiStore, title: String = "Bracket Page") throws
        -> (page: WikiPage, head: PageVersionID?, source: SourceSummary)
    {
        let source = try store.addSource(filename: "Smith2023.md", data: Data("raw".utf8))
        let page = try store.createPage(
            title: title,
            body: "Intro sentence.\n\nSee [[Other Page\\]] and [[source:Smith2023\\]] for details.",
            createdBy: "seed",
            provenance: [.init(sourceID: source.id, role: .primary)])
        let head = try store.pageHeadVersionID(pageID: page.id)
        return (page, head, source)
    }

    private func makeModel(store: GRDBWikiStore) -> WikiStoreModel {
        let model = WikiStoreModel(store: store)
        return model
    }

    /// The bracket fix is a CAS write carrying the captured head and the
    /// head's unchanged source inputs: exactly one new version, provenance
    /// preserved, `agent:lint` authorship, original/written heads and repair
    /// locations recorded.
    @Test func casPreservesProvenance() throws {
        let store = try tempFileStore().store
        let seeded = try seedDamagedPage(store)
        let model = makeModel(store: store)

        let preflight = model.preflightLint(pageID: seeded.page.id)
        let preflightUnwrapped = try #require(preflight)
        #expect(preflightUnwrapped.didFixLinks == true)
        #expect(preflightUnwrapped.fixFailure == nil)
        #expect(preflightUnwrapped.inspectedHead == seeded.head)
        let writtenHead = try #require(preflightUnwrapped.writtenHead)
        #expect(writtenHead != seeded.head)

        // The stored body is the FIXED body (store-canonicalized): no `\]]`
        // remains, the unresolved page link stays raw, the source citation is
        // canonicalized to its ULID form.
        let stored = try store.getPage(id: seeded.page.id)
        #expect(!stored.bodyMarkdown.contains("\\]]"))
        #expect(stored.bodyMarkdown.contains("[[Other Page]]"))
        #expect(stored.bodyMarkdown.contains("[[source:\(seeded.source.id.rawValue)|Smith2023]]"))

        // Exactly one new version was appended by the fix.
        #expect(try store.pageVersionHistory(pageID: seeded.page.id).count == 2)

        // Provenance survived: the new head carries the seed's source input.
        let headSources = try store.pageHeadSources(pageID: seeded.page.id)
        #expect(headSources.map(\.sourceID) == [seeded.source.id])
        #expect(headSources.map(\.role) == [.primary])

        // Repair locations: one UTF-16 range per repaired link, in the
        // ORIGINAL body, pointing at `[[…\]]` spans.
        #expect(preflightUnwrapped.repairLocations.count == 2)
        let original = "Intro sentence.\n\nSee [[Other Page\\]] and [[source:Smith2023\\]] for details." as NSString
        for range in preflightUnwrapped.repairLocations {
            let span = original.substring(with: range)
            #expect(span.hasPrefix("[["), "repair location \(range) must cover a link span, got \(span)")
            #expect(span.hasSuffix("]]"))
        }

        // The fix was authored by the lint agent, not an unknown editor.
        let origin = try #require(try store.pageOrigin(pageID: seeded.page.id))
        #expect(origin.agentName == .agent("lint"))
    }

    /// A body with no bracket damage performs NO write: same head, same
    /// version count, no failure recorded.
    @Test func cleanBodyWritesNothing() throws {
        let store = try tempFileStore().store
        let source = try store.addSource(filename: "s.md", data: Data("raw".utf8))
        let page = try store.createPage(
            title: "Clean", body: "Nothing to fix [[Other Page]]",
            provenance: [.init(sourceID: source.id, role: .primary)])
        let headBefore = try store.pageHeadVersionID(pageID: page.id)

        let model = makeModel(store: store)
        let preflight = try #require(model.preflightLint(pageID: page.id))

        #expect(preflight.didFixLinks == false)
        #expect(preflight.writtenHead == nil)
        #expect(preflight.fixFailure == nil)
        #expect(preflight.repairLocations.isEmpty)
        #expect(try store.pageHeadVersionID(pageID: page.id) == headBefore)
        #expect(try store.pageVersionHistory(pageID: page.id).count == 1)
    }

    /// One conflict recomposes against the competitor's body and commits:
    /// the stored result is the fix of the COMPETITOR's text — the old
    /// proposal is never replayed over the new head.
    @Test func oneConflictRecomposes() throws {
        let (store, url) = try tempFileStore()
        let competitor = try GRDBWikiStore(databaseURL: url)
        let seeded = try seedDamagedPage(store)
        let model = makeModel(store: store)

        model.preflightBeforeWriteAttempt = { attempt in
            guard attempt == 1 else { return }
            // A concurrent writer commits between the model's read and its
            // first write — through a second real connection. Its body still
            // carries bracket damage, so recomposition has something to fix.
            // A distinct actor keeps the write out of the autosave
            // amend/coalescing window (same-actor saves amend in place).
            _ = try? competitor.appendPageVersion(
                pageID: seeded.page.id, title: seeded.page.title,
                body: "Competitor rewrote this. See [[Brand New Page\\]] here.",
                expectedHeadVersionID: nil, lastEditedBy: "competitor-1")
        }

        let preflight = try #require(model.preflightLint(pageID: seeded.page.id))

        #expect(preflight.didFixLinks == true)
        #expect(preflight.fixFailure == nil)
        // The stored body fixes the COMPETITOR's body, not our first snapshot.
        let stored = try store.getPage(id: seeded.page.id)
        #expect(stored.bodyMarkdown == "Competitor rewrote this. See [[Brand New Page]] here.")
        // Versions: seed + competitor + recomposed fix.
        #expect(try store.pageVersionHistory(pageID: seeded.page.id).count == 3)
        // The recomposed commit carried the FRESH head's inputs — the
        // competitor declared none on its version, so the new head has none.
        let headSources = try store.pageHeadSources(pageID: seeded.page.id)
        #expect(headSources.isEmpty)
    }

    /// A second conflict stops the repair: no lint write after the second
    /// CAS failure, the failure is reported, and the concurrent edits stand.
    @Test func secondConflictStopsTheRepair() throws {
        let (store, url) = try tempFileStore()
        let competitor = try GRDBWikiStore(databaseURL: url)
        let seeded = try seedDamagedPage(store)
        let model = makeModel(store: store)

        model.preflightBeforeWriteAttempt = { attempt in
            // Every attempt races against a fresh competing commit whose body
            // still carries bracket damage — so each recomposition proposes
            // another fix, and each write conflicts again. A distinct actor
            // per attempt keeps each write out of the autosave
            // amend/coalescing window (same-actor saves amend in place).
            _ = try? competitor.appendPageVersion(
                pageID: seeded.page.id, title: seeded.page.title,
                body: "Competitor move \(attempt) [[New Page\\]]",
                expectedHeadVersionID: nil, lastEditedBy: "competitor-\(attempt)")
        }

        let preflight = try #require(model.preflightLint(pageID: seeded.page.id))

        #expect(preflight.didFixLinks == false)
        #expect(preflight.fixFailure == .conflictLimitReached)
        #expect(preflight.writtenHead == nil)
        // Versions: seed + competitor(1) + competitor(2) — ZERO lint writes.
        #expect(try store.pageVersionHistory(pageID: seeded.page.id).count == 3)
        let stored = try store.getPage(id: seeded.page.id)
        #expect(stored.bodyMarkdown.hasPrefix("Competitor move "),
                "the concurrent writer's body must stand; lint wrote nothing")
    }

    /// A dirty editor draft is never overwritten by the auto-fix: the fix
    /// commits to the store, but the user's unsaved edits stay in the editor.
    @Test func dirtyDraftIsNotOverwritten() throws {
        let store = try tempFileStore().store
        let seeded = try seedDamagedPage(store)
        let model = makeModel(store: store)

        #expect(model.selectPage(byID: seeded.page.id))
        let userDraft = "MY UNSAVED EDITS — hands off"
        model.draftBody = userDraft

        let preflight = try #require(model.preflightLint(pageID: seeded.page.id))
        #expect(preflight.didFixLinks == true, "the fix still commits to the store")
        #expect(model.draftBody == userDraft,
                "a dirty draft must never be clobbered by the auto-fix")
    }
}
