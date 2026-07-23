import Testing
import Foundation
@testable import WikiFSCore

/// Per-method correctness net for store emission (AC.2, AC.8). A spy subscriber
/// on an in-memory store's bus asserts the exact `(kind, id, change)` event for
/// every EMIT method. Delivery is async (handlers run on the main actor via
/// `Task`), so a lock-guarded collector is polled until the event lands; because
/// events arrive a runloop tick after `emit`, prerequisite mutations are awaited
/// (then the collector cleared) before the mutation under test runs.
@Suite(.timeLimit(.minutes(5)))
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

    /// Await `recorder`'s current pending event(s), then clear it — used after a
    /// prerequisite mutation so only the mutation under test is observed.
    private func drain(_ recorder: Recorder) async throws {
        _ = try await awaitEvents(recorder, expected: max(recorder.count, 1))
        recorder.clear()
    }

    /// Fresh in-memory store + per-wiki bus + spy subscriber.
    private func makeHarness() throws -> (GRDBWikiStore, WikiEventBus, Recorder) {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: "W")
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
        try await drain(rec)

        try store.restorePage(pageID: page.id, to: v1)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .page)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == page.id.rawValue)
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
        try await drain(rec)
        try store.rollbackSourceContent(sourceID: s.id, to: PageID(rawValue: v2.id))
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
        try await drain(rec)
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
        try await drain(rec)
        try store.setActiveMarkdown(sourceID: s.id, to: v.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
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
        let node = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder, label: "F", targetID: nil)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .created)
        #expect(events.last?.id == node.id)
    }

    @Test func updateBookmarkNodeEmitsBookmarkUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder, label: "F", targetID: nil)
        try await drain(rec)
        try store.updateBookmarkNode(id: node.id, label: "G")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == node.id)
    }

    @Test func deleteBookmarkNodeEmitsBookmarkDeleted() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder, label: "F", targetID: nil)
        try await drain(rec)
        try store.deleteBookmarkNode(id: node.id)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .deleted)
        #expect(events.last?.id == node.id)
    }

    @Test func moveBookmarkNodeEmitsBookmarkUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let node = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder, label: "F", targetID: nil)
        try await drain(rec)
        try store.moveBookmarkNode(id: node.id, toParentID: nil, position: 1)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .bookmark)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == node.id)
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
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: "acp-123")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .chat)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == chat.id.rawValue)
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
