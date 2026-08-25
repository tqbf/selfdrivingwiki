import Testing
import Foundation
@testable import WikiFSCore

/// Per-method correctness net for store emission (AC.2, AC.8). A spy subscriber
/// on an in-memory store's bus asserts the exact `(kind, id, change)` event for
/// every EMIT method. Delivery is async (handlers run on the main actor via
/// `Task`), so a lock-guarded collector is polled until the event lands; because
/// events arrive a runloop tick after `emit`, prerequisite mutations are awaited
/// (then the collector cleared) before the mutation under test runs.
@Suite
struct StoreEmissionTests {

    /// Lock-guarded, synchronous collector — the `@MainActor` handler appends
    /// without awaiting.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func clear() { lock.lock(); events.removeAll(); lock.unlock() }
        var count: Int { snapshot.count }
    }

    /// Wait until `recorder` holds `expected` events (bounded), returning them.
    private func awaitEvents(_ recorder: Recorder, expected: Int = 1, timeoutMs: Int = 800) async throws -> [ResourceChangeEvent] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.count >= expected { return recorder.snapshot }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return recorder.snapshot
    }

    /// Await every event emitted by the prerequisite batch, then clear the
    /// recorder so only the mutation under test is observed. Callers pass the
    /// batch's known number of public mutator calls instead of sampling the
    /// partially delivered async recorder.
    private func drain(_ recorder: Recorder, expected: Int = 1) async throws {
        _ = try await awaitEvents(recorder, expected: expected)
        recorder.clear()
    }

    /// Confirm the async bus stayed silent after a synchronous no-op/throwing
    /// mutation path. A real emit queues a `Task { @MainActor in … }`, so a few
    /// deterministic main-actor flushes are enough to surface it.
    private func assertNoEventsDelivered(_ recorder: Recorder) async {
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
    }

    /// Fresh in-memory store + per-wiki bus + spy subscriber.
    private func makeHarness() throws -> (GRDBWikiStore, WikiEventBus, Recorder) {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "W"))
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (store, bus, recorder)
    }

    private func provenance() -> SourceProvenance {
        SourceProvenance(agentName: "test", activityKind: "import")
    }

    private func addSeedSource(_ store: GRDBWikiStore) throws -> SourceSummary {
        try store.addSource(filename: "blob.bin", data: Data("bytes".utf8))
    }

    // MARK: - Pages

    @Test func createPageEmitsPageCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Hello")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == page.id.rawValue)
    }

    @Test func updatePageEmitsPageUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Hello")
        try await drain(rec)
        try store.updatePage(id: page.id, title: "World", body: "body")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == page.id.rawValue)
    }

    /// AC.6 — `updatePage` after the page-provenance refactor composes the
    /// version-append logic via `appendPageVersionLocked` (a private `db:`-
    /// taking helper that does NOT emit). This MUST emit EXACTLY one
    /// `.page .updated` event per call — the refactor's HIGH hazard
    /// (`plans/page-provenance.md` §5.3) is that delegating to public
    /// `appendPageVersion` would double-emit AND re-enter `mutate`. The
    /// structural fix is one emit per public wrapper; this test catches a
    /// regression by counting events.
    ///
    /// Uses a DISTINCT author (`lastEditedBy: "agent-edit"`) from the create
    /// page (which had `createdBy: nil` → `last_edited_by = nil`) so the
    /// `tryAmendPageVersion` same-actor coalescer cannot short-circuit and
    /// `appendPageVersionLocked` actually runs. (Per AC.3 / §5.3 LOW note.)
    @Test func test_updatePage_after_versioning_refactor_emits_single_page_updated() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Provenance")
        try await drain(rec)
        let beforeUpdate = rec.count
        try store.updatePage(
            id: page.id, title: "Provenance (edited)", body: "edited body",
            lastEditedBy: "agent-edit")
        // Exactly ONE new event for the update — no double-emit, no deadlock.
        let events = try await awaitEvents(rec, expected: beforeUpdate + 1)
        let newEvents = Array(events.dropFirst(beforeUpdate))
        #expect(newEvents.count == 1, "updatePage must emit exactly one event (got \(newEvents.count))")
        #expect(newEvents.first?.kind == .page)
        #expect(newEvents.first?.change == .updated)
        #expect(newEvents.first?.id == page.id.rawValue)
    }

    @Test func deletePageEmitsPageDeleted() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Hello")
        try await drain(rec)
        try store.deletePage(id: page.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .deleted)
        #expect(events.last?.id == page.id.rawValue)
    }

    @Test func replaceLinksEmitsPageUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Hello")
        try await drain(rec)
        try store.replaceLinks(from: page.id, parsedLinks: [])
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == page.id.rawValue)
    }

    /// #817 — `restorePage` (append-only restore) emits exactly one
    /// `.page .updated` event (routed through `mutate()`). Mirrors the
    /// `revertProcessedMarkdown` emission posture on the source side.
    @Test func restorePageEmitsPageUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Restore Emit")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Restore Emit", body: "v1",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Restore Emit", body: "v2",
            expectedHeadVersionID: v1)
        try await drain(rec, expected: 3)

        try store.restorePage(pageID: page.id, to: v1)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == page.id.rawValue)
    }

    // MARK: - OKF metadata

    @Test func pageOKFStatusEmitsOneOwningPageUpdate() async throws {
        let (store, _, recorder) = try makeHarness()
        let page = try store.createPage(title: "OKF status")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        try await drain(recorder)

        try store.setPageOKFStatus(versionID: versionID, status: .draft)

        let events = try await awaitEvents(recorder)
        #expect(events.count == 1)
        #expect(events[0].kind == .page)
        #expect(events[0].change == .updated)
        #expect(events[0].id == page.id.rawValue)
    }

    @Test func sourceMarkdownOKFStatusEmitsOneOwningSourceUpdate() async throws {
        let (store, _, recorder) = try makeHarness()
        let source = try store.addSource(filename: "source.txt", data: Data("raw".utf8))
        let markdown = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "processed", origin: .user,
            note: nil, technique: nil)
        try await drain(recorder, expected: 2)

        try store.setSourceMarkdownOKFStatus(versionID: markdown.id, status: .stable)

        let events = try await awaitEvents(recorder)
        #expect(events.count == 1)
        #expect(events[0].kind == .source)
        #expect(events[0].change == .updated)
        #expect(events[0].id == source.id.rawValue)
    }

    @Test func combinedVerificationAndFreshnessEmitsOnce() async throws {
        let (store, _, recorder) = try makeHarness()
        let page = try store.createPage(title: "Combined OKF mutation")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        try await drain(recorder)

        _ = try store.recordPageOKFVerification(
            versionID: versionID,
            verifier: try OKFVerifierIdentity("human:reviewer"),
            verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            basis: .init(kind: .humanReview),
            freshnessPolicy: .ttl(seconds: 600, anchor: .recordedVerification))

        let events = try await awaitEvents(recorder)
        #expect(events.count == 1)
        #expect(events[0].kind == .page)
        #expect(events[0].change == .updated)
        #expect(events[0].id == page.id.rawValue)
    }

    @Test func invalidOKFEvidenceEmitsNothing() async throws {
        let (store, _, recorder) = try makeHarness()
        let page = try store.createPage(title: "Invalid OKF evidence")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        try await drain(recorder)

        #expect(throws: OKFMetadataError.self) {
            try store.recordPageOKFVerification(
                versionID: versionID,
                verifier: try OKFVerifierIdentity("human:reviewer"),
                verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
                basis: .init(
                    kind: .sourceChecked,
                    evidence: [.source(SourceID(rawValue: "missing-source"))]),
                freshnessPolicy: nil)
        }
        await assertNoEventsDelivered(recorder)
    }

    // MARK: - Sources

    @Test func addSourceEmitsSourceCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try store.addSource(filename: "blob.bin", data: Data("bytes".utf8))
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func addBytelessSourceEmitsSourceCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try store.addBytelessSource(
            filename: "youtube-x", mimeType: "video/youtube",
            provenance: provenance(), role: .primary)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func addSnapshotImageEmitsSourceCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let activityID = try store.ensureFetchActivity(provenance: provenance())
        try await drain(rec)
        let s = try store.addSnapshotImage(
            filename: "img.png", data: Data("png".utf8), mimeType: "image/png",
            originalPath: "/p", sourceURL: URL(string: "https://example.com")!,
            activityID: activityID, role: .media)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func deleteSourceEmitsSourceDeleted() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        try store.deleteSource(id: s.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .deleted)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func appendContentVersionEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        _ = try store.appendContentVersion(sourceID: s.id, data: Data("b2".utf8), mimeType: nil, provenance: nil)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func rollbackSourceContentEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        let v2 = try store.appendContentVersion(sourceID: s.id, data: Data("b2".utf8), mimeType: nil, provenance: nil)
        try await drain(rec, expected: 2)
        try store.rollbackSourceContent(sourceID: s.id, to: v2.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func renameSourceEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        try store.renameSource(id: s.id, to: "New Name")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func markSourceIngestedEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        try store.markSourceIngested(id: s.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    // MARK: - Processed markdown

    @Test func appendProcessedMarkdownEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        _ = try store.appendProcessedMarkdown(sourceID: s.id, content: "# md", origin: .extraction, note: nil)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func appendProcessedMarkdownTranscriptOriginEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        _ = try store.appendProcessedMarkdown(
            sourceID: s.id, content: "# Transcript",
            origin: .transcript, note: nil,
            technique: "youtube-captions")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func recordMarkdownExtractionEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        _ = try store.recordMarkdownExtraction(sourceID: s.id, content: "# md", backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: "x")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func revertProcessedMarkdownEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        let v1 = try store.appendProcessedMarkdown(sourceID: s.id, content: "v1", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: s.id, content: "v2", origin: .extraction, note: nil)
        try await drain(rec, expected: 3)
        _ = try store.revertProcessedMarkdown(sourceID: s.id, to: v1.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func setActiveMarkdownEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        let v = try store.recordMarkdownExtraction(sourceID: s.id, content: "# md", backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: "x")
        try await drain(rec, expected: 2)
        try store.setActiveMarkdown(sourceID: s.id, to: v.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func markdownVersionMutatorsKeepEmissionIDsSourceScoped() async throws {
        let (store, _, rec) = try makeHarness()
        let source = try addSeedSource(store)
        let appended = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v1", origin: .extraction, note: nil)
        try await drain(rec, expected: 2)

        try store.setActiveMarkdown(sourceID: source.id, to: appended.id)
        var events = try await awaitEvents(rec)
        #expect(events.last?.id == source.id.rawValue)
        #expect(events.last?.id != appended.id.rawValue)

        try await drain(rec)
        _ = try store.revertProcessedMarkdown(sourceID: source.id, to: appended.id)
        events = try await awaitEvents(rec)
        #expect(events.last?.id == source.id.rawValue)
        #expect(events.last?.id != appended.id.rawValue)
    }

    @Test func revertProcessedMarkdownUnknownVersionEmitsNothingAndKeepsHeadUnchanged() async throws {
        let (store, _, rec) = try makeHarness()
        let source = try addSeedSource(store)
        let first = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v1", origin: .extraction, note: nil)
        try await drain(rec, expected: 2)
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v2", origin: .extraction, note: nil)
        try await drain(rec)
        try store.setActiveMarkdown(sourceID: source.id, to: first.id)
        try await drain(rec)

        let previousHead = try #require(try store.processedMarkdownHead(sourceID: source.id))
        let previousBatchHead = try #require(try store.processedMarkdownHeadsBySource()[source.id.rawValue])
        let missing = SourceMarkdownVersionID(rawValue: "01JUNKNOWNMARKDOWNVERSION000")

        do {
            _ = try store.revertProcessedMarkdown(sourceID: source.id, to: missing)
            Issue.record("expected revertProcessedMarkdown to throw sourceMarkdownVersionNotFound")
        } catch let error as WikiStoreError {
            switch error {
            case .sourceMarkdownVersionNotFound(let missingID):
                #expect(missingID == missing)
            default:
                Issue.record("unexpected revertProcessedMarkdown error: \(error)")
            }
        }

        await assertNoEventsDelivered(rec)
        let headAfter = try #require(try store.processedMarkdownHead(sourceID: source.id))
        let batchHeadAfter = try #require(try store.processedMarkdownHeadsBySource()[source.id.rawValue])
        #expect(headAfter.id == previousHead.id)
        #expect(headAfter.content == previousHead.content)
        #expect(batchHeadAfter.id == previousBatchHead.id)
    }

    @Test func setActiveMarkdownUnknownVersionEmitsNothingAndKeepsHeadUnchanged() async throws {
        let (store, _, rec) = try makeHarness()
        let source = try addSeedSource(store)
        let first = try store.recordMarkdownExtraction(
            sourceID: source.id, content: "v1", backend: .anthropic,
            sourceVersionID: nil, note: nil, modelVersion: "x")
        try await drain(rec, expected: 2)
        _ = try store.recordMarkdownExtraction(
            sourceID: source.id, content: "v2", backend: .anthropic,
            sourceVersionID: nil, note: nil, modelVersion: "x")
        try await drain(rec)
        try store.setActiveMarkdown(sourceID: source.id, to: first.id)
        try await drain(rec)

        let previousHead = try #require(try store.processedMarkdownHead(sourceID: source.id))
        let previousBatchHead = try #require(try store.processedMarkdownHeadsBySource()[source.id.rawValue])
        let missing = SourceMarkdownVersionID(rawValue: "01JUNKNOWNMARKDOWNVERSION001")

        do {
            try store.setActiveMarkdown(sourceID: source.id, to: missing)
            Issue.record("expected setActiveMarkdown to throw sourceMarkdownVersionNotFound")
        } catch let error as WikiStoreError {
            switch error {
            case .sourceMarkdownVersionNotFound(let missingID):
                #expect(missingID == missing)
            default:
                Issue.record("unexpected setActiveMarkdown error: \(error)")
            }
        }

        await assertNoEventsDelivered(rec)
        let headAfter = try #require(try store.processedMarkdownHead(sourceID: source.id))
        let batchHeadAfter = try #require(try store.processedMarkdownHeadsBySource()[source.id.rawValue])
        #expect(headAfter.id == previousHead.id)
        #expect(headAfter.content == previousHead.content)
        #expect(batchHeadAfter.id == previousBatchHead.id)
    }

    // MARK: - Singletons + log

    @Test func updateSystemPromptIsNoOpAndEmitsNothing() async throws {
        let (store, _, rec) = try makeHarness()
        try store.updateSystemPrompt(body: "# new prompt")
        let events = try await awaitEvents(rec)
        // updateSystemPrompt is a no-op (table removed in v42); no event emitted.
        #expect(events.isEmpty || events.last?.kind != .systemPrompt)
    }

    @Test func appendLogEmitsLogCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let entry = try store.appendLog(kind: .ingest, title: "did a thing", note: nil)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .log)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == entry.id.rawValue)
    }

    @Test func updateWikiIndexEmitsWikiIndexUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        try store.updateWikiIndex(body: "# index")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .wikiIndex)
        #expect(events.last?.change == .updated)
    }

    // MARK: - Bookmarks (AC.8)

    @Test func createBookmarkNodeEmitsBookmarkCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "F"))
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == node.id.rawValue)
    }

    @Test func updateBookmarkNodeEmitsBookmarkUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "F"))
        try await drain(rec)
        try store.renameBookmarkFolder(id: node.id, to: "G")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == node.id.rawValue)
    }

    @Test func deleteBookmarkNodeEmitsBookmarkDeleted() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "F"))
        try await drain(rec)
        try store.deleteBookmarkNode(id: node.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .deleted)
        #expect(events.last?.id == node.id.rawValue)
    }

    @Test func moveBookmarkNodeEmitsBookmarkUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "F"))
        try await drain(rec)
        try store.moveBookmarkNode(id: node.id, toParentID: nil, position: 1)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == node.id.rawValue)
    }

    // MARK: - Chats (#119)

    @Test func createChatEmitsChatCreated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func appendChatMessagesEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        _ = try store.appendChatMessages(chatID: chat.id, events: [AgentEvent.userText("test")])
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    /// Per-message summary emit (chat-summary plan §3.5 + AC.2). The new
    /// `updateMessageSummary` mutator MUST route through `mutate()` and emit a
    /// `.chat .updated` event on the chat the message belongs to (the
    /// projection + model subscribe to `.chat` changes; there is no
    /// `.message` resource kind). Modeled on
    /// `appendChatMessagesEmitsChatUpdated` above.
    @Test func updateMessageSummaryEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        let messages = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.assistantText("text.")])
        try await drain(rec)
        try store.updateMessageSummary(
            chatID: chat.id, messageID: messages[0].id,
            summary: "one-liner.", kind: .defaultTruncation)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func renameChatEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        try store.renameChat(id: chat.id, to: "Renamed")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func deleteChatEmitsChatDeleted() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        try store.deleteChat(id: chat.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .deleted)
        #expect(events.last?.id == chat.id.rawValue)
    }

    /// ACP session ID write/clear (#830). The new `updateChatAcpSessionId`
    /// mutator MUST route through `mutate()` and emit a `.chat .updated`
    /// event. Modeled on `updateMessageSummaryEmitsChatUpdated`.
    @Test func updateChatAcpSessionIdEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: AcpSessionID(rawValue: "acp-123"))
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    /// Per-chat model override (composer `ProviderSelector` pin). MUST route
    /// through `mutate()` and emit a `.chat .updated` event, same as
    /// `updateChatAcpSessionId` — the picker's local UI state (`chatModelOverride`
    /// in `ProviderSelector`) reads back through the store's `chats` mirror,
    /// which is only kept fresh by this event.
    @Test func updateChatModelOverrideEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        try store.updateChatModelOverride(id: chat.id, providerId: ProviderID(rawValue: "acme"), modelId: ModelID(rawValue: "acme-1"))
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func updateChatModelAndThinkingSelectionEmitsOneCoherentEvent() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(
            kind: .edit,
            title: "Test Chat",
            modelProviderId: ProviderID(rawValue: "old"),
            modelId: ModelID(rawValue: "old-model"),
            configuredThinkingOptionID: ChatConfigurationValueID(rawValue: "high"),
            effectiveThinkingOptionID: ChatConfigurationValueID(rawValue: "high"))
        try await drain(rec)

        try store.updateChatModelAndThinkingSelection(
            chatID: chat.id,
            providerID: ProviderID(rawValue: "new"),
            modelID: ModelID(rawValue: "new-model"),
            configuredThinkingID: ChatConfigurationValueID(rawValue: "high"),
            effectiveThinkingID: ChatConfigurationValueID(rawValue: "low"))
        let events = try await awaitEvents(rec)
        let matching = events.filter { $0.kind == .chat && $0.id == chat.id.rawValue }
        #expect(matching.count == 1)
        #expect(matching.first?.change == .updated)

        let observed = try store.getChat(id: chat.id)
        #expect(observed.modelId == ModelID(rawValue: "new-model"))
        #expect(observed.effectiveThinkingOptionID == ChatConfigurationValueID(rawValue: "low"))
    }

    /// Incremental in-flight checkpoint (#826). The `checkpointStreamingMessage`
    /// mutator MUST route through `mutate()` and emit a `.chat .updated` event
    /// — it is a real content mutation (writes `event_json`, `text`), not
    /// derived data. Modeled on `appendChatMessagesEmitsChatUpdated`.
    @Test func checkpointStreamingMessageEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hello")])
        try await drain(rec)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "draft-1",
            event: .assistantText("partial"), isDraft: true)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    /// Finalize stale drafts on reopen (C8, #826). The `finalizeStaleDrafts`
    /// mutator MUST route through `mutate()` and emit a `.chat .updated` event.
    @Test func finalizeStaleDraftsEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "draft-1",
            event: .assistantText("partial"), isDraft: true)
        try await drain(rec)
        try store.finalizeStaleDrafts(forChat: chat.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func enqueuePersistedChatTurnEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func claimPersistedChatTurnEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try await drain(rec)
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func editPersistedChatTurnEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try await drain(rec)
        _ = try store.editPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "edited",
            contextReferences: [.page(PageID(rawValue: "page-1"))],
            editedAt: Date(timeIntervalSince1970: 2)
        )
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func removePersistedQueuedChatTurnEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try await drain(rec)
        let removed = try store.removePersistedQueuedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1")
        )
        #expect(removed)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func markPersistedChatTurnProviderSubmittedEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )
        try await drain(rec)
        _ = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-1"),
            submittedAt: Date(timeIntervalSince1970: 3)
        )
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func finishPersistedChatTurnEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-1"),
            submittedAt: Date(timeIntervalSince1970: 3)
        )
        try await drain(rec)
        _ = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: "done"
        )
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    @Test func rejectedStoreTransitionWritesNothingAndEmitsNothing() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "cmd-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                userText: "queued", contextReferences: [], submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )
        try await drain(rec, expected: 3)

        do {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: ChatTurnID(rawValue: "turn-1"),
                claimID: ChatTurnClaimID(rawValue: "stale-claim"), usage: .init(inputTokens: 1)
            )
            Issue.record("expected stale chat-turn claim")
        } catch let error as MetadataStoreError {
            #expect(error == .staleChatTurnClaim)
        }

        await assertNoEventsDelivered(rec)
        let turn = try #require(try store.listPersistedChatTurns(chatID: chat.id).first)
        #expect(turn.state == .claimed)
        #expect(turn.usage.inputTokens == nil)
    }

    @Test func appendChatTranscriptItemsEmitsChatUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let chat = try store.createChat(kind: .edit, title: "Test Chat")
        try await drain(rec)
        _ = try store.appendChatTranscriptItems(chatID: chat.id, items: [
            .message(.init(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                text: "Hello",
                createdAt: Date(timeIntervalSince1970: 1)
            ))
        ])
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
    }

    // MARK: - Nil-bus store (wikictl path)

    @Test func nilBusStoreEmitsSilently() throws {
        // A store with no bus (the wikictl path) must not crash on mutation and
        // must not emit anything (there is nothing to emit into).
        let store = try TestStoreFactory.inMemory()
        #expect(store.eventBus == nil)
        let page = try store.createPage(title: "Silent")
        #expect(page.title == "Silent")
    }
}
