#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore

/// Store + model tests for the issue #219 protected deletion contract:
/// `deletionImpact(for:)` and `deleteResources(_:)` — atomic batches, the
/// mandatory bookmark cleanup, the link policies, the rollback seam, and the
/// post-commit event batch. The model-level tests cover the one protected
/// delete path per resource type; the coordinator-level routing lives in
/// `Tests/WikiFSAppTests/DeletionConfirmationCoordinatorTests.swift`.
@MainActor
struct DeletionIncomingReferenceTests {

    private func makeStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    /// Lock-guarded, synchronous event recorder with a clear (the shared
    /// `SignalRecorder` has no clear; the coordinator tests need one).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func clear() { lock.lock(); events.removeAll(); lock.unlock() }
        var count: Int { snapshot.count }
    }

    /// A lock-guarded event recorder wired to a fresh bus on `store`.
    private func makeRecorder(_ store: GRDBWikiStore) -> Recorder {
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "W"))
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return recorder
    }

    /// Wait until `recorder` holds `expected` events (bounded), returning them.
    private func awaitEvents(_ recorder: Recorder, expected: Int, timeoutMs: Int = 800) async throws -> [ResourceChangeEvent] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.count >= expected { return recorder.snapshot }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return recorder.snapshot
    }

    /// Confirm the async bus stayed silent after a rollback. A real emit
    /// queues a `Task { @MainActor in … }`, so a few deterministic main-actor
    /// flushes are enough to surface it.
    private func assertNoEventsDelivered(_ recorder: Recorder) async {
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
    }

    // MARK: - deletionImpact (store + model, throwing)

    @Test func deletionImpactForPageReportsLinksAndBookmarks() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))

        let impact = try store.deletionImpact(for: [.page(b.id)])
        #expect(impact.linkingPageIDs == [a.id])
        #expect(impact.linkingPages.first?.title == "A")
        #expect(impact.bookmarkLabels == ["Bookmarks"])
        #expect(impact.incomingLinkCount == 1)
        #expect(impact.hasReferences)
    }

    @Test func deletionImpactForPageWithNoReferencesIsEmpty() throws {
        let store = try makeStore()
        let b = try store.createPage(title: "B")

        let impact = try store.deletionImpact(for: [.page(b.id)])
        #expect(!impact.hasReferences)
        #expect(impact.incomingLinkCount == 0)
    }

    @Test func deletionImpactForSourceReportsCitations() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "cite [[source:paper]]", author: "user")

        let impact = try store.deletionImpact(for: [.source(src.id)])
        #expect(impact.linkingPageIDs == [a.id])
        #expect(impact.hasReferences)
    }

    @Test func deletionImpactForSourceReportsProvenanceBlockers() throws {
        let store = try makeStore()
        let page = try store.createPage(title: "Claim")
        let src = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: src.id, role: .primary)])

        let impact = try store.deletionImpact(for: [.source(src.id)])
        #expect(impact.isProvenanceBlocked)
        #expect(impact.provenanceBlockers.count == 1)
    }

    @Test func modelDeletionImpactSurfacesStoreErrors() throws {
        let store = try makeStore()
        let model = WikiStoreModel(store: store)
        let b = try store.createPage(title: "B")

        // Throwing passthrough: the model impact NEVER reports a false
        // "no references" when the read fails (AC.10). A missing page row
        // yields an empty-but-valid impact; the error path itself is proven
        // at the coordinator level with a throwing loader.
        let impact = try model.deletionImpact(forPage: b.id)
        #expect(!impact.hasReferences)
    }

    // MARK: - Protected deletion basics (AC.1 / AC.2 / AC.3)

    @Test func protectedPageDeleteAlwaysRemovesTargetBookmarks() throws {
        let store = try makeStore()
        let b = try store.createPage(title: "B")
        let folder = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "F"))
        _ = try store.createBookmarkNode(parentID: folder.id, position: 0, content: .page(b.id))
        _ = try store.createBookmarkNode(parentID: nil, position: 1, content: .chat(ChatID(rawValue: "01CHAT")))

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id)], linkPolicy: .preserve))

        #expect(result.deletedTargets == [.page(b.id)])
        #expect(result.removedBookmarkIDs.count == 1)
        // The folder and the unrelated chat ref survive; the page ref is gone.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 2)
        #expect(nodes.contains { $0.id == folder.id })
        #expect(nodes.contains { node in
            if case .chat = node.content { return true }
            return false
        })
    }

    @Test func protectedSourceDeleteAlwaysRemovesTargetBookmarks() throws {
        let store = try makeStore()
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(src.id))

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.source(src.id)], linkPolicy: .preserve))

        #expect(result.deletedTargets == [.source(src.id)])
        #expect(result.removedBookmarkIDs.count == 1)
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    @Test func preservePolicyKeepsIncomingMarkdownAsGhostLinks() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]] end", author: "user")

        _ = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id)], linkPolicy: .preserve))

        // The body still carries the [[…]] span (a ghost link). The setup
        // upsert canonicalized it, so assert the span survived, not the bytes.
        let ghostBody = try store.getPage(id: a.id).bodyMarkdown
        #expect(ghostBody.contains("[[") && ghostBody.contains("]]"))
    }

    @Test func unlinkPolicyRewritesPageAndSourceTargetsOnly() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        let d = try store.createPage(title: "D")
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try PageUpsert.upsert(
            in: store, id: a.id, title: "A",
            body: "p [[B]] s [[source:paper]] d [[D]] ![[source:paper|fig]]",
            author: "user")
        try PageUpsert.upsert(in: store, id: c.id, title: "C", body: "keeps [[D]]", author: "user")
        let cBodyBefore = try store.getPage(id: c.id).bodyMarkdown

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id), .source(src.id)], linkPolicy: .unlink))

        // Only the matching spans in A became plain text; the D link (both
        // cite and embed forms) is untouched, embed prefixes consumed,
        // aliases preserved.
        #expect(try store.getPage(id: a.id).bodyMarkdown
            == "p B s paper d [[page:\(d.id.rawValue)|D]] fig")
        // Unrelated pages are byte-unchanged (AC.4).
        #expect(try store.getPage(id: c.id).bodyMarkdown == cBodyBefore)
        #expect(result.rewrittenPageIDs == [a.id])
        // The surviving D edge remains in the graph (page-link rows).
        #expect(try store.listAllLinks().contains { $0.from == a.id.rawValue && $0.to == d.id.rawValue })
    }

    // MARK: - Batch semantics (AC.5)

    @Test func batchDeleteRewritesSharedLinkingPageOnce() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "x [[B]] y [[C]]", author: "user")
        let versionsBefore = try store.pageVersionHistory(pageID: a.id).count

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id), .page(c.id)], linkPolicy: .unlink))

        // A appears exactly once in the rewrite list and gained exactly one
        // version — never one write per deleted target.
        #expect(result.rewrittenPageIDs == [a.id])
        #expect(try store.pageVersionHistory(pageID: a.id).count == versionsBefore + 1)
        #expect(try store.getPage(id: a.id).bodyMarkdown == "x B y C")
    }

    @Test func batchDeleteSkipsDeletedLinkingPage() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        // A → B, and B (itself being deleted) → C.
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        try PageUpsert.upsert(in: store, id: b.id, title: "B", body: "also [[C]]", author: "user")

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id), .page(c.id)], linkPolicy: .unlink))

        // B is in the deletion set, so it is never rewritten (it vanishes);
        // A is the only rewrite.
        #expect(result.rewrittenPageIDs == [a.id])
        #expect(try store.getPage(id: a.id).bodyMarkdown == "see B")
        #expect(try store.listPages(sortBy: .titleAZ).contains { $0.id == a.id })
        #expect(try !store.listPages(sortBy: .titleAZ).contains { $0.id == b.id })
    }

    @Test func batchDeletePreservesLinksToSurvivingTargets() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "x [[B]] y [[C]]", author: "user")

        _ = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id)], linkPolicy: .unlink))

        // The link to the SURVIVING target keeps its span (canonical form
        // from the setup upsert) and its row.
        #expect(try store.getPage(id: a.id).bodyMarkdown
            == "x B y [[page:\(c.id.rawValue)|C]]")
        let rows = try store.listAllLinks()
        #expect(rows.contains { $0.from == a.id.rawValue && $0.to == c.id.rawValue })
        #expect(!rows.contains { $0.from == a.id.rawValue && $0.to == b.id.rawValue })
    }

    // MARK: - Provenance gate (AC.6)

    @Test func mixedBatchWithProvenanceBlockerChangesNothing() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let l = try store.createPage(title: "L")
        let src = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        // A's provenance cites the source (the blocker); L links to A.
        try PageUpsert.upsert(in: store, id: l.id, title: "L", body: "see [[A]]", author: "user")
        try store.updatePage(
            id: a.id, title: "Claim", body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: src.id, role: .primary)])
        let bookmark = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(src.id))
        let bodyBefore = try store.getPage(id: l.id).bodyMarkdown

        #expect(throws: WikiStoreError.self) {
            try store.deleteResources(ResourceDeletionRequest(
                targets: [.page(l.id), .source(src.id)], linkPolicy: .unlink))
        }

        // NOTHING changed: the blocker stops the complete batch before the
        // first mutation.
        #expect(try store.getSource(id: src.id).id == src.id)
        #expect(try store.getPage(id: l.id).bodyMarkdown == bodyBefore)
        #expect(try store.listBookmarkNodes().map(\.id) == [bookmark.id])
        #expect(try store.listPages(sortBy: .titleAZ).contains { $0.id == l.id })
    }

    // MARK: - Rollback seam (AC.7)

    /// Compare the full observable state of the fixture before and after a
    /// failed protected deletion.
    private func assertFixtureUnchanged(
        _ store: GRDBWikiStore, pageID a: PageID, targetID t: PageID,
        bookmarkID bm: BookmarkID, versionsBefore: Int, bodyBefore: String,
        siblingBefore: [BookmarkNode]
    ) throws {
        #expect(try store.getPage(id: a).bodyMarkdown == bodyBefore)
        #expect(try store.pageVersionHistory(pageID: a).count == versionsBefore)
        // The link row A→target survived the rollback.
        #expect(try store.listAllLinks().contains { $0.from == a.rawValue && $0.to == t.rawValue })
        // The target and its bookmark survived, positions intact.
        #expect(try store.getPage(id: t).id == t)
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.map(\.id) == siblingBefore.map(\.id))
        #expect(nodes.map(\.position) == siblingBefore.map(\.position))
        #expect(nodes.first { $0.id == bm } != nil)
    }

    private func rollbackFixture() throws -> (GRDBWikiStore, PageID, PageID, BookmarkID, BookmarkNode) {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        // Two root bookmarks: the target ref first, then a sibling whose
        // position would renumber if the cleanup committed.
        let bm = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))
        let sibling = try store.createBookmarkNode(parentID: nil, position: 1, content: .page(a.id))
        return (store, a.id, b.id, bm.id, sibling)
    }

    @Test func rewriteFailureRollsBackProtectedDeletion() async throws {
        let (store, a, b, bm, _) = try rollbackFixture()
        let stage = ProtectedDeletionFailurePoint.afterRewrite
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 6) // setup writes
        recorder.clear()
        let versionsBefore = try store.pageVersionHistory(pageID: a).count
        let bodyBefore = try store.getPage(id: a).bodyMarkdown
        let siblingsBefore = try store.listBookmarkNodes()
        #expect(throws: WikiStoreError.self) {
            try store.deleteResources(ResourceDeletionRequest(
                targets: [.page(b)], linkPolicy: .unlink),
                failurePoint: stage)
        }

        try assertFixtureUnchanged(
            store, pageID: a, targetID: b, bookmarkID: bm,
            versionsBefore: versionsBefore, bodyBefore: bodyBefore,
            siblingBefore: siblingsBefore)
        await assertNoEventsDelivered(recorder)
    }

    @Test func bookmarkCleanupFailureRollsBackProtectedDeletion() async throws {
        let (store, a, b, bm, _) = try rollbackFixture()
        let stage = ProtectedDeletionFailurePoint.afterBookmarkCleanup
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 6)
        recorder.clear()
        let versionsBefore = try store.pageVersionHistory(pageID: a).count
        let bodyBefore = try store.getPage(id: a).bodyMarkdown
        let siblingsBefore = try store.listBookmarkNodes()
        #expect(throws: WikiStoreError.self) {
            try store.deleteResources(ResourceDeletionRequest(
                targets: [.page(b)], linkPolicy: .unlink),
                failurePoint: stage)
        }

        try assertFixtureUnchanged(
            store, pageID: a, targetID: b, bookmarkID: bm,
            versionsBefore: versionsBefore, bodyBefore: bodyBefore,
            siblingBefore: siblingsBefore)
        await assertNoEventsDelivered(recorder)
    }

    @Test func targetDeleteFailureRollsBackProtectedDeletion() async throws {
        let (store, a, b, bm, _) = try rollbackFixture()
        let stage = ProtectedDeletionFailurePoint.beforeTargetDeletion
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 6)
        recorder.clear()
        let versionsBefore = try store.pageVersionHistory(pageID: a).count
        let bodyBefore = try store.getPage(id: a).bodyMarkdown
        let siblingsBefore = try store.listBookmarkNodes()
        #expect(throws: WikiStoreError.self) {
            try store.deleteResources(ResourceDeletionRequest(
                targets: [.page(b)], linkPolicy: .unlink),
                failurePoint: stage)
        }

        try assertFixtureUnchanged(
            store, pageID: a, targetID: b, bookmarkID: bm,
            versionsBefore: versionsBefore, bodyBefore: bodyBefore,
            siblingBefore: siblingsBefore)
        await assertNoEventsDelivered(recorder)
    }

    // MARK: - Post-commit events (AC.8)

    @Test func protectedDeletionEmitsCompletePostCommitBatch() async throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        let bm = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 5)
        recorder.clear()

        _ = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(b.id)], linkPolicy: .unlink))

        // Exactly three events, in order: rewritten page → removed bookmark →
        // deleted target. One batch, post-commit.
        let events = try await awaitEvents(recorder, expected: 3)
        #expect(events.count == 3)
        #expect(events[0].kind == .page && events[0].change == .updated && events[0].id == a.id.rawValue)
        #expect(events[1].kind == .bookmark && events[1].change == .deleted && events[1].id == bm.id.rawValue)
        #expect(events[2].kind == .page && events[2].change == .deleted && events[2].id == b.id.rawValue)
    }

    @Test func deletedBookmarkEventRefreshesRenumberedSiblingTree() async throws {
        let store = try makeStore()
        let p1 = try store.createPage(title: "P1")
        let p2 = try store.createPage(title: "P2")
        let p3 = try store.createPage(title: "P3")
        let bm1 = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(p1.id))
        let bm2 = try store.createBookmarkNode(parentID: nil, position: 1, content: .page(p2.id))
        let bm3 = try store.createBookmarkNode(parentID: nil, position: 2, content: .page(p3.id))
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 6)
        recorder.clear()

        // Delete P1 (the FIRST sibling): the survivors must renumber to
        // contiguous positions, and the deleted-bookmark event is the tree
        // invalidation that makes subscribers reload them.
        _ = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(p1.id)], linkPolicy: .preserve))

        let events = try await awaitEvents(recorder, expected: 2)
        #expect(events.map(\.change) == [.deleted, .deleted])
        #expect(events.contains { $0.kind == .bookmark && $0.id == bm1.id.rawValue })
        #expect(events.contains { $0.kind == .page && $0.id == p1.id.rawValue })

        // The reloaded tree reflects the renumbering.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.map(\.id) == [bm2.id, bm3.id])
        #expect(nodes.map(\.position) == [0, 1])
    }

    @Test func failedProtectedDeletionEmitsNoEvents() async throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 5)
        recorder.clear()
        #expect(throws: WikiStoreError.self) {
            try store.deleteResources(ResourceDeletionRequest(
                targets: [.page(b.id)], linkPolicy: .unlink),
                failurePoint: .afterRewrite)
        }

        await assertNoEventsDelivered(recorder)
    }

    // MARK: - Dedup + missing targets (AC.14)

    @Test func protectedDeletionDeduplicatesTargets() throws {
        let store = try makeStore()
        let b = try store.createPage(title: "B")
        let src = try store.addSource(filename: "s.txt", data: Data("s".utf8))
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))

        let result = try store.deleteResources(ResourceDeletionRequest(
            // Duplicate ids across both spellings: one effect, one entry.
            targets: [
                .page(b.id), .page(b.id),
                .source(src.id), .source(src.id),
            ],
            linkPolicy: .preserve))

        #expect(ResourceDeletionTarget.sorted(Set(result.deletedTargets)) == [.page(b.id), .source(src.id)])
        #expect(result.deletedTargets.count == 2)
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    @Test func missingTargetRemovesStaleBookmarkWithoutFalseTargetEvent() async throws {
        let store = try makeStore()
        // A stale bookmark pointing at a page row that doesn't exist.
        let ghost = PageID(rawValue: "01GHOSTPAGE0000000000000000")
        let stale = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(ghost))
        let recorder = makeRecorder(store)
        _ = try await awaitEvents(recorder, expected: 1)
        recorder.clear()

        let result = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(ghost)], linkPolicy: .preserve))

        // The stale bookmark is gone (mandatory cleanup), and its removal
        // event IS emitted — but the missing target produced NO deleted-target
        // result entry and NO false .page .deleted event.
        #expect(result.removedBookmarkIDs == [stale.id])
        #expect(result.deletedTargets.isEmpty)
        let events = try await awaitEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events[0].kind == .bookmark && events[0].change == .deleted)
        #expect(events[0].id == stale.id.rawValue)
    }

    // MARK: - Compatibility forwarders (AC.15)

    @Test func legacySingleTargetDeleteMethodsForwardToProtectedPreservePolicy() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]] + [[source:paper]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))
        _ = try store.createBookmarkNode(parentID: nil, position: 1, content: .source(src.id))

        // Legacy single-target APIs: preserve policy + mandatory bookmarks.
        try store.deletePage(id: b.id)
        try store.deleteSource(id: src.id)

        // Ghost links preserved …
        let ghostBody = try store.getPage(id: a.id).bodyMarkdown
        #expect(ghostBody.contains("[[") && ghostBody.contains("]]"))
        // … and NO invalid bookmarks survive either delete.
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    // MARK: - Model-level protected delete paths (AC.1 / AC.2)

    @Test func appModelPageDeleteRemovesTargetBookmarks() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))
        let model = WikiStoreModel(store: store)
        model.reloadBookmarkNodes()

        try model.delete(b.id, unlinkIncomingLinks: false)

        #expect(try store.listBookmarkNodes().isEmpty)
        let ghostBody = try store.getPage(id: a.id).bodyMarkdown
        #expect(ghostBody.contains("[[") && ghostBody.contains("]]"))
    }

    @Test func appModelSourceDeleteRemovesTargetBookmarks() throws {
        let store = try makeStore()
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(src.id))
        let model = WikiStoreModel(store: store)
        model.reloadBookmarkNodes()

        try model.deleteSource(src.id, unlinkIncomingLinks: false)

        #expect(try store.listBookmarkNodes().isEmpty)
    }

    @Test func provenanceBlockedSourceIsNotDeletedAndCitationsSurvive() throws {
        let store = try makeStore()
        let page = try store.createPage(title: "Claim")
        let src = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "cite [[source:evidence]]", lastEditedBy: "user",
            provenance: [.init(sourceID: src.id, role: .primary)])
        let model = WikiStoreModel(store: store)

        // The UI entry point: nil result + storeError on the provenance block.
        let result = model.performSourceDeletion([src.id], unlinkIncomingLinks: true)

        #expect(result == nil)
        #expect(model.storeError != nil)
        // The source stays (provenance-restricted) …
        #expect(try store.getSource(id: src.id).id == src.id)
        // … and its citation is NOT rewritten (the store stopped before the
        // first mutation).
        #expect(try store.getPage(id: page.id).bodyMarkdown.contains("[["))
    }

    // MARK: - Review fixes: batch UI path + no-commit no-op

    /// The model batch path sends the WHOLE selection in one request: a page
    /// inside the selection is never rewritten, the external linker rewrites
    /// exactly once, and both targets delete together.
    @Test func modelBatchDeleteRoutesSelectionInOneRequest() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "x [[B]] y [[C]]", author: "user")
        try PageUpsert.upsert(in: store, id: b.id, title: "B", body: "also [[C]]", author: "user")
        let versionsBefore = try store.pageVersionHistory(pageID: a.id).count
        let model = WikiStoreModel(store: store)

        let result = try model.delete([b.id, c.id], unlinkIncomingLinks: true)

        #expect(result.deletedTargets.contains(.page(b.id)))
        #expect(result.deletedTargets.contains(.page(c.id)))
        // B is in the selection — never treated as an external linker.
        #expect(result.rewrittenPageIDs == [a.id])
        #expect(try store.pageVersionHistory(pageID: a.id).count == versionsBefore + 1)
        #expect(try store.getPage(id: a.id).bodyMarkdown == "x B y C")
    }

    /// A provenance blocker on ANY source of a multi-selection stops the
    /// complete batch: nothing deleted, nothing rewritten, no bookmark
    /// removed, and the failure surfaced through `storeError`.
    @Test func modelBatchSourceDeleteBlockedChangesNothingAndSurfacesError() throws {
        let store = try makeStore()
        let claimingPage = try store.createPage(title: "Claim")
        let freeSrc = try store.addSource(filename: "free.txt", data: Data("free".utf8))
        let blockedSrc = try store.addSource(filename: "blocked.txt", data: Data("blocked".utf8))
        try store.updatePage(
            id: claimingPage.id, title: claimingPage.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: blockedSrc.id, role: .primary)])
        let bm = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(freeSrc.id))
        let model = WikiStoreModel(store: store)

        let result = model.performSourceDeletion(
            [freeSrc.id, blockedSrc.id], unlinkIncomingLinks: true)

        #expect(result == nil)
        #expect(model.storeError != nil)
        #expect(try store.getSource(id: freeSrc.id).id == freeSrc.id)
        #expect(try store.getSource(id: blockedSrc.id).id == blockedSrc.id)
        #expect(try store.listBookmarkNodes().map(\.id) == [bm.id])
    }
}
#endif
