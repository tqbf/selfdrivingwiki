import Foundation
import Testing
@testable import WikiFSCore

/// Tests for W0 — page versioning & CAS (PR #312).
///
/// Covers: CAS conflict detection, version chain ordering, revert, the
/// default-active rule (no ref → MAX(id)), and migration seeding.
@MainActor
struct PageVersionTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - CAS conflict detection

    @Test func casConflictWhenHeadMoved() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Test Page")
        // First versioned save (blind — no CAS expectation, backward-compatible).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Test Page", body: "v1 body",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head != nil)

        // Simulate a concurrent write: another writer commits a new version.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Test Page", body: "v2 body (concurrent)",
            expectedHeadVersionID: head)  // passes CAS — head matches

        // Now the original editor tries to save with the STALE head → conflict.
        #expect(throws: PageConflictError.self) {
            _ = try store.appendPageVersion(
                pageID: page.id, title: "Test Page", body: "v2 body (original editor)",
                expectedHeadVersionID: head)  // stale — head moved to v2
        }
    }

    @Test func casPassesWhenHeadUnchanged() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Stable Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Stable Page", body: "v1",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)

        // Second save with the correct head → succeeds.
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Stable Page", body: "v2",
            expectedHeadVersionID: head)
        #expect(v2 != head)
    }

    @Test func blindWriteWhenExpectedHeadIsNil() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Blind Page")
        // nil = no CAS check, backward-compatible.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Blind Page", body: "v1",
            expectedHeadVersionID: nil)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Blind Page", body: "v2",
            expectedHeadVersionID: nil)
        let history = try store.pageVersionHistory(pageID: page.id)
        // 2 appends + 1 root version seeded by createPage (Phase 3).
        #expect(history.count == 3)
    }

    // MARK: - Version chain ordering

    @Test func historyIsOrderedByULID() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Chain Page")
        for i in 0..<5 {
            _ = try store.appendPageVersion(
                pageID: page.id, title: "Chain Page", body: "v\(i)",
                expectedHeadVersionID: nil)
        }
        let history = try store.pageVersionHistory(pageID: page.id)
        // 5 appends + 1 root version seeded by createPage (Phase 3).
        #expect(history.count == 6)
        // ULIDs are time-ordered; the chain should be ascending.
        for i in 1..<history.count {
            #expect(history[i].id > history[i - 1].id, "version \(i) should come after \(i-1) in ULID order")
        }
    }

    @Test func parentIDLinksChain() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Parent Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Parent Page", body: "v1",
            expectedHeadVersionID: nil)
        let v1Head = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Parent Page", body: "v2",
            expectedHeadVersionID: v1Head)
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history[0].parentID == nil)  // root (seeded by createPage)
        #expect(history[1].parentID == history[0].id)  // v1's parent is root
        #expect(history[2].parentID == v1Head)  // v2's parent is v1
    }

    // MARK: - Revert

    @Test func revertRestoresBodyFromVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Revert Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Page", body: "original body",
            expectedHeadVersionID: nil)
        let v1Head = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Page", body: "modified body",
            expectedHeadVersionID: v1Head)

        // Revert to v1.
        try store.revertPage(pageID: page.id, to: v1Head!)
        let page2 = try store.getPage(id: page.id)
        #expect(page2.bodyMarkdown == "original body")
    }

    @Test func revertRepointsActiveVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Revert Head Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Head Page", body: "v1",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Head Page", body: "v2",
            expectedHeadVersionID: v1)

        // Head should be v2.
        let headAfterV2 = try store.pageHeadVersionID(pageID: page.id)
        #expect(headAfterV2 != v1)

        // Revert to v1.
        try store.revertPage(pageID: page.id, to: v1)
        let headAfterRevert = try store.pageHeadVersionID(pageID: page.id)
        #expect(headAfterRevert == v1)
    }

    // MARK: - Default-active rule

    @Test func defaultActiveIsMaxID() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Default Page")
        // Phase 3: createPage seeds a root version + ref atomically.
        // The first versioned save writes a new version + updates the ref.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Default Page", body: "v1",
            expectedHeadVersionID: nil)
        // Head should be the last version (the ref points at it).
        let head = try store.pageHeadVersionID(pageID: page.id)
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(head == history.last?.id)
    }

    // MARK: - Body mirror + FTS

    @Test func bodyMirrorUpdatedAfterVersionedSave() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Mirror Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Mirror Page", body: "versioned body",
            expectedHeadVersionID: nil)
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "versioned body")
    }

    // MARK: - Phase 3: head-ref invariant (AC3)

    @Test func createPageSeedsRootVersionAndRef() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Ref Page")

        // createPage should seed a root version + page-content ref.
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head != nil, "createPage should seed a root version")

        // The ref should point at the root version.
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 1)
        #expect(history[0].parentID == nil, "root version has no parent")
        #expect(head == history[0].id, "ref points at the root version")
    }

    @Test func v34BackfillEveryPageHasRef() throws {
        let store = try tempStore()
        // Create pages and append versions (which write refs).
        let page1 = try store.createPage(title: "Page One")
        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "body 1",
            expectedHeadVersionID: nil)
        let page2 = try store.createPage(title: "Page Two")
        _ = try store.appendPageVersion(
            pageID: page2.id, title: "Page Two", body: "body 2",
            expectedHeadVersionID: nil)

        // Every page should have a page-content ref pointing at its head.
        for page in [page1, page2] {
            let head = try store.pageHeadVersionID(pageID: page.id)
            #expect(head != nil)
        }
    }

    @Test func v34Idempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v34-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("WikiFS.sqlite")

        let store1 = try GRDBWikiStore(databaseURL: dbURL)
        let page = try store1.createPage(title: "Idempotent Page")
        _ = try store1.appendPageVersion(
            pageID: page.id, title: "Idempotent Page", body: "body",
            expectedHeadVersionID: nil)
        let headBefore = try store1.pageHeadVersionID(pageID: page.id)
        let historyBefore = try store1.pageVersionHistory(pageID: page.id)

        // Reopen the same DB — migrations re-run but v34 finds all pages
        // already have refs, so it's a no-op.
        let store2 = try GRDBWikiStore(databaseURL: dbURL)
        let headAfter = try store2.pageHeadVersionID(pageID: page.id)
        let historyAfter = try store2.pageVersionHistory(pageID: page.id)
        #expect(headBefore == headAfter)
        #expect(historyBefore.count == historyAfter.count)
    }

    // MARK: - Phase 4: amend + GC (AC4)

    @Test func sameActorSavesCoalesceIntoOneVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Amend Page")

        // First versioned save (with actor identity).
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Amend Page", body: "initial body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // Second save by the SAME actor, immediately (within the 5s window).
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Amend Page", body: "amended body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-A")

        // The amend should have returned the SAME version id (head unchanged).
        #expect(v1 == v2, "same-actor save within window should amend (same version id)")

        // Still only 1 versioned save + 1 root = 2 rows (no new version appended).
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 2, "amend should not append a version row")

        // The body should reflect the amended content.
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "amended body")

        // The head version's blob should point at the amended body.
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head == v1)
    }

    @Test func guardedHeadNotAmended() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Guarded Page")

        // v1 — first save by agent-A (amend fails: root's actor is nil → append)
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v1 body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // v2 — save by agent-B (amend fails: different actor → append)
        // This makes v1 have a child (v2).
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v2 body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-B")

        // v3 — save by agent-A (amend fails: different actor → append)
        // This makes v2 have a child (v3).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v3 body",
            expectedHeadVersionID: v2, lastEditedBy: "agent-A")

        // Revert to v2, making it the head. v2 has a child (v3).
        try store.revertPage(pageID: page.id, to: v2)

        // Now save by agent-A — same actor as pages.last_edited_by (still
        // "agent-A" from v3's append). BUT v2 has a child → amend guard fails → append.
        let v4 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v4 body",
            expectedHeadVersionID: v2, lastEditedBy: "agent-A")

        #expect(v4 != v2, "head with children should NOT be amended (new version id)")

        // Also test the workspace_refs guard: if a workspace references the head,
        // the save should append.
        let page2 = try store.createPage(title: "Workspace Guarded Page")
        // wv1 — first save by agent-B (amend fails: root's actor is nil → append)
        let wv1 = try store.appendPageVersion(
            pageID: page2.id, title: "Workspace Guarded Page", body: "ws v1",
            expectedHeadVersionID: nil, lastEditedBy: "agent-B")

        // Create a workspace and stage a write to page2 (this creates a
        // workspace_refs row referencing wv1 as base_version_id).
        let wsID = try store.createWorkspace(name: "test-ws", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page2.id,
            title: "Workspace Guarded Page", body: "ws staged")

        // Save again by agent-B — same actor, within window, no children,
        // BUT a workspace_refs row references wv1 → amend guard fails → append.
        let wv2 = try store.appendPageVersion(
            pageID: page2.id, title: "Workspace Guarded Page", body: "ws v2",
            expectedHeadVersionID: wv1, lastEditedBy: "agent-B")

        #expect(wv2 != wv1, "head referenced by workspace_refs should NOT be amended")
    }

    @Test func vacuumPageVersionsDeletesOnlyUnreachable() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Vacuum Page")

        // Root version (from createPage) + 2 appends (different actors to
        // prevent amend coalescing, ensuring distinct version rows).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Vacuum Page", body: "v1",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")
        let head = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Vacuum Page", body: "v2",
            expectedHeadVersionID: head, lastEditedBy: "agent-B")

        // All versions are reachable via the parent chain from the ref target.
        // Dry-run: should report 0 orphans and not delete anything.
        let dryReport = try store.vacuumPageVersions(dryRun: true)
        #expect(dryReport.applied == false, "dry-run should not apply")
        #expect(dryReport.deletedCount == 0, "all versions should be reachable")

        let historyAfterDry = try store.pageVersionHistory(pageID: page.id)
        #expect(historyAfterDry.count == 3, "dry-run should not delete versions")

        // Applied vacuum should also find 0 orphans (all reachable).
        let appliedReport = try store.vacuumPageVersions(dryRun: false)
        #expect(appliedReport.applied == true)
        #expect(appliedReport.deletedCount == 0, "no orphans to delete")
        let historyAfterApply = try store.pageVersionHistory(pageID: page.id)
        #expect(historyAfterApply.count == historyAfterDry.count, "applied vacuum should not change count when 0 orphans")
    }

    @Test func amendAfterWindowExpiresAppends() async throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Window Page")

        // First versioned save.
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Window Page", body: "v1 body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // Wait for the coalescing window (5s) to expire.
        // Use Task.sleep (not Thread.sleep) so we don't block the cooperative
        // thread pool / main actor — Thread.sleep on a @MainActor test stalls
        // every other @MainActor test on CI's constrained runner (#732).
        try await Task.sleep(for: .seconds(6))

        // Second save by same actor — but window expired, so should append.
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Window Page", body: "v2 body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-A")

        #expect(v1 != v2, "save after window expiry should append (new version id)")

        // 1 root + 2 versioned saves = 3 versions.
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 3, "two appends + root")
    }

    // MARK: - Page provenance (#page-provenance): AC.1, AC.2, AC.3, AC.4

    /// AC.1 — after a "chat" creates a page (the simulation of an ingestion
    /// executor creating a page via `wikictl page upsert --author chat:<id>`),
    /// `pageOrigin(pageID:)` returns a non-nil `PageOrigin` whose `agentName`
    /// is `chat:<id>`, `agentKind` is `"chat"`, `activityKind` is `"import"`,
    /// and `savedAt` is approximately now. The agent row was deduped via
    /// `ensureAgent(name:kind:)` — NOT the shared `legacy-import` — so the
    /// activity's `agent_id` points at the real chat identity.
    @Test func pageOriginReflectsChatAuthorOnCreate() throws {
        let store = try tempStore()
        let chatID = "chat:01JTESTCHAT00000000"
        let page = try store.createPage(title: "Chat-Created", createdBy: chatID)

        guard let origin = try store.pageOrigin(pageID: page.id) else {
            Issue.record("pageOrigin returned nil for a freshly created page")
            return
        }
        #expect(origin.agentName == chatID, "agentName should be \(chatID) (got \(origin.agentName))")
        #expect(origin.agentKind == "chat", "agentKind for chat:<id> is 'chat'")
        #expect(origin.activityKind == "import", "root activity is 'import'")
        #expect(origin.title == "Chat-Created")
        // savedAt is "now" (within 5s — the test runs fast).
        let drift = abs(origin.savedAt.timeIntervalSinceNow)
        #expect(drift < 5.0, "savedAt should be ~now (drift \(drift)s)")
    }

    /// AC.1 (variant) — when the createPage author is `agent:<kind>`
    /// (e.g. an ingestion executor), `agentKind` is `"agent"` and `agentName`
    /// is `agent:<kind>`.
    @Test func pageOriginReflectsAgentKindOnCreate() throws {
        let store = try tempStore()
        let agentLabel = "agent:ingest"
        let page = try store.createPage(title: "Ingest Page", createdBy: agentLabel)

        let origin = try store.pageOrigin(pageID: page.id)
        #expect(origin?.agentName == agentLabel)
        #expect(origin?.agentKind == "agent")
        #expect(origin?.activityKind == "import")
    }

    /// #763 — `PageUpsert.upsert` with `author: "agent:ingest"` (the exact
    /// path wikictl's `page add` takes during non-workspace ingestion) must
    /// stamp `agent:ingest`, NOT degrade to `legacy-import`. `PageUpsert` does
    /// create+update back-to-back with the same author, so the amend coalescing
    /// path fires — the root activity's agent must survive the amend.
    @Test func pageOriginReflectsAgentIngestAfterUpsertAmend() throws {
        let store = try tempStore()
        let outcome = try PageUpsert.upsert(
            in: store, id: nil, title: "Ingested Page",
            body: "# Ingested Page\n\nSome content from ingestion.",
            author: "agent:ingest")

        #expect(outcome.didCreate, "should be a new page")
        let origin = try store.pageOrigin(pageID: outcome.id)
        #expect(origin != nil, "pageOrigin should resolve")
        #expect(origin?.agentName == "agent:ingest",
                "ingestion agent should be 'agent:ingest', not 'legacy-import' (got \(origin?.agentName ?? "nil"))")
        #expect(origin?.agentKind == "agent",
                "agent kind should be 'agent' (got \(origin?.agentKind ?? "nil"))")
    }

    /// #763 — re-ingesting an existing page (created by the user) with
    /// `agent:ingest` must stamp `agent:ingest` on the new version, NOT
    /// preserve the old `legacy-import`/`user` agent via amend coalescing.
    /// The amend fires when same-actor, but here the actor CHANGES (user →
    /// agent:ingest), so a new version + activity is appended.
    @Test func reIngestExistingPageStampsAgentIngest() throws {
        let store = try tempStore()
        // Create with "user" first (simulates a pre-existing page).
        let page = try store.createPage(title: "Re-ingest", createdBy: "user")
        _ = page

        // Now the agent re-ingests: title resolves to existing → updatePage.
        let outcome = try PageUpsert.upsert(
            in: store, id: nil, title: "Re-ingest",
            body: "# Re-ingest\n\nUpdated by ingestion.",
            author: "agent:ingest")

        #expect(!outcome.didCreate, "should update the existing page")
        let origin = try store.pageOrigin(pageID: outcome.id)
        #expect(origin?.agentName == "agent:ingest",
                "re-ingest agent should be 'agent:ingest' (got \(origin?.agentName ?? "nil"))")
    }

    /// #763 — re-ingesting an existing page with IDENTICAL content (a no-op
    /// write, the `wikictl` idempotent re-write case). The no-op guard in
    /// `appendPageVersionLocked` bumps only `pages.last_edited_by` without
    /// creating a new version/activity — so the page-content ref still points
    /// at the OLD version whose activity may have `legacy-import` (pre-#713).
    @Test func reIngestIdenticalContentPreservesOldAgent() throws {
        let store = try tempStore()
        // Simulate a pre-#713 page: created with no author → legacy-import.
        let page = try store.createPage(title: "Same Content", createdBy: nil)
        try store.updatePage(id: page.id, title: "Same Content",
                             body: "identical body", lastEditedBy: nil)
        let beforeOrigin = try store.pageOrigin(pageID: page.id)
        #expect(beforeOrigin?.agentName == "legacy-import",
                "pre-fix page should have legacy-import (got \(beforeOrigin?.agentName ?? "nil"))")

        // Now re-ingest the SAME content with agent:ingest.
        _ = try PageUpsert.upsert(
            in: store, id: nil, title: "Same Content",
            body: "identical body", author: "agent:ingest")

        // #763: the no-op guard now checks if the author changed. Since the
        // old page had `last_edited_by = nil` (→ legacy-import activity), and
        // the new save has `author = "agent:ingest"`, a new version + activity
        // IS created (the author changed). The ref now points to the new
        // version with agent:ingest.
        let afterOrigin = try store.pageOrigin(pageID: page.id)
        #expect(afterOrigin?.agentName == "agent:ingest",
                "no-op re-ingest with different author should stamp new agent — got \(afterOrigin?.agentName ?? "nil")")
    }

    /// AC.1 (degraded path) — a `createPage` with no author (nil) falls back
    /// to the shared `legacy-import` agent. `pageOrigin` reports `agentName
    /// == "legacy-import"` and `agentKind == "software"`. No crash, no data
    /// loss. (Pre-v39 rows look the same — they degraded identically.)
    @Test func pageOriginDegradesToLegacyImportWhenNoAuthor() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "No-Author Page", createdBy: nil)

        let origin = try store.pageOrigin(pageID: page.id)
        #expect(origin?.agentName == "legacy-import")
        #expect(origin?.agentKind == "software")
        #expect(origin?.activityKind == "import")
    }

    /// AC.2 — a freshly-created-then-edited page (with a DISTINCT author on
    /// the edit so `tryAmendPageVersion` cannot coalesce). `pageEditHistory`
    /// returns EXACTLY 2 entries (the empty-root `'import'` + the `'edit'`),
    /// and `entry.last` pins the chat author + edited body — so it cannot
    /// pass trivially off the create-double-row artifact.
    @Test func pageEditHistoryCountsCreateAndEdit() throws {
        let store = try tempStore()
        // Create with one author (an ingestion agent)…
        let createAuthor = "agent:ingest"
        let page = try store.createPage(title: "Edit Chain", createdBy: createAuthor)
        // …then edit with a DISTINCT author (a chat) so the amend-coalescer
        // returns nil (different actor) and the version-append actually runs.
        let editAuthor = "chat:01JTESTCHAT00000001"
        try store.updatePage(
            id: page.id, title: "Edit Chain", body: "edited body",
            lastEditedBy: editAuthor)

        let history = try store.pageEditHistory(pageID: page.id)
        #expect(history.count == 2, "fresh create+edit yields 2 origin entries (got \(history.count))")

        // entry[0] = root (the create's empty-root 'import' activity).
        #expect(history[0].activityKind == "import")
        #expect(history[0].agentName == createAuthor)
        #expect(history[0].agentKind == "agent")

        // entry[1] = the edit — pinned to the chat author + the edited body.
        #expect(history[1].activityKind == "edit")
        #expect(history[1].agentName == editAuthor)
        #expect(history[1].agentKind == "chat")
        // The title is the version's stored title (which equals what
        // updatePage wrote).
        #expect(history[1].title == "Edit Chain")

        // pageOrigin(pageID:) reflects the HEAD = entry[1] (the chat edit).
        let head = try store.pageOrigin(pageID: page.id)
        #expect(head?.agentName == editAuthor)
        #expect(head?.agentKind == "chat")
        #expect(head?.activityKind == "edit")
    }

    /// AC.3 — the CAS-OFF path (`updatePage` with no `expectedHeadVersionID`,
    /// the `wikictl` default) now appends a `page_versions` + `activities`
    /// row, closing the pre-v39 "records nothing" hole. Verified by row count
    /// before/after. Uses DISTINCT authors (per §5.3 LOW note) so the amend
    /// short-circuit does not suppress the new version row.
    @Test func updatePageCASOffAppendsVersionAndActivity() throws {
        let store = try tempStore()
        let createAuthor = "agent:create"
        let page = try store.createPage(title: "CAS-Off", createdBy: createAuthor)

        // Before: 1 page_versions row (the empty root), 1 activity (create's
        // 'import').
        let versionsBefore = try store.pageVersionHistory(pageID: page.id)
        #expect(versionsBefore.count == 1)
        let activitiesBefore = store.scalarText(
            "SELECT COUNT(*) FROM activities;"
        )
        let beforeCount = Int(activitiesBefore) ?? -1
        #expect(beforeCount == 1, "createPage seeds one 'import' activity")

        // CAS-off update with a DISTINCT author (so amend can't coalesce).
        try store.updatePage(
            id: page.id, title: "CAS-Off", body: "first edit",
            lastEditedBy: "chat:01JTESTCHAT00000002")

        let versionsAfter = try store.pageVersionHistory(pageID: page.id)
        #expect(versionsAfter.count == 2, "CAS-off update appends a version row (got \(versionsAfter.count))")

        let activitiesAfterRaw = store.scalarText(
            "SELECT COUNT(*) FROM activities;"
        )
        let afterCount = Int(activitiesAfterRaw) ?? -1
        #expect(afterCount == beforeCount + 1, "CAS-off update adds one activity row")
    }

    /// AC.4 — page activities' `agent_id` resolves via `ensureAgent` to a REAL
    /// named agent (not the shared `legacy-import`) when `lastEditedBy` is
    /// non-null. Verified by querying the activity's agent row directly.
    @Test func pageEditActivityPointsAtRealNamedAgent() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Real Agent", createdBy: "agent:ingest")
        try store.updatePage(
            id: page.id, title: "Real Agent", body: "edited",
            lastEditedBy: "chat:01JTESTCHAT00000003")

        // The HEAD activity (on the just-appended version) should point at a
        // real `chat:<id>` agent, NOT the shared `legacy-import`. Verified by
        // joining the HEAD version's activity to agents.name.
        guard let head = try store.pageHeadVersionID(pageID: page.id) else {
            Issue.record("expected a HEAD version after the update")
            return
        }
        let agentName = store.scalarText("""
        SELECT a.name FROM page_versions pv
        JOIN activities act ON act.id = pv.activity_id
        JOIN agents a ON a.id = act.agent_id
        WHERE pv.id = '\(head)';
        """)
        #expect(agentName == "chat:01JTESTCHAT00000003",
                "HEAD activity agent should be the chat (got \(agentName))")

        let agentKind = store.scalarText("""
        SELECT a.kind FROM page_versions pv
        JOIN activities act ON act.id = pv.activity_id
        JOIN agents a ON a.id = act.agent_id
        WHERE pv.id = '\(head)';
        """)
        #expect(agentKind == "chat", "HEAD activity agent kind is 'chat'")
    }

    /// AC.4 (degraded) — when `lastEditedBy` is nil/empty, the activity's
    /// `agent_id` falls back to the legacy-import shared agent. No crash, no
    /// data loss.
    @Test func pageEditNilAuthorDegradesToLegacyImport() throws {
        let store = try tempStore()
        // Create with a chat author so the root activity has a real agent.
        let page = try store.createPage(title: "Degrade", createdBy: "chat:01JDEGRADE000000001")
        // UpdatePage with lastEditedBy=nil — the append (CAS-off, no
        // amend-can-fire because pages.last_edited_by="chat:…" ≠ nil) lands a
        // new activity pointing at legacy-import.
        try store.updatePage(
            id: page.id, title: "Degrade", body: "v2", lastEditedBy: nil)

        guard let head = try store.pageHeadVersionID(pageID: page.id) else {
            Issue.record("expected a HEAD version")
            return
        }
        let agentName = store.scalarText("""
        SELECT a.name FROM page_versions pv
        JOIN activities act ON act.id = pv.activity_id
        JOIN agents a ON a.id = act.agent_id
        WHERE pv.id = '\(head)';
        """)
        #expect(agentName == "legacy-import",
                "nil author degrades to legacy-import (got \(agentName))")
    }

    /// AC.8 (migration ladder sanity) — a fresh DB must report the current
    /// `user_version`. The v38→39 step was a no-op `PRAGMA user_version = 39`
    /// (the write-path change was the real fix); v39→40 adds the per-message
    /// summary columns (`plans/chat-summary.md` §3.3).
    @Test func v39SchemaVersionAfterMigration() throws {
        #expect(GRDBWikiStore.schemaVersion == 41,
                "schemaVersion must report 41 after the wikictl-prompt-migration bump")
        let store = try tempStore()
        let v = store.pragmaValue("user_version")
        #expect(v == "41", "fresh DB stamps user_version = 41 (got \(v))")
    }
}
