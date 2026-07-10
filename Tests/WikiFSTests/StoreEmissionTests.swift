import Testing
import Foundation
@testable import WikiFSCore

/// Per-method correctness net for store emission (AC.2, AC.8). A spy subscriber
/// on an in-memory store's bus asserts the exact `(kind, id, change)` event for
/// every EMIT method. Delivery is async (handlers run on the main actor via
/// `Task`), so a lock-guarded collector is polled until the event lands; because
/// events arrive a runloop tick after `emit`, prerequisite mutations are awaited
/// (then the collector cleared) before the mutation under test runs.
@Suite(.tags(.integration))
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

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Fresh temp-file store + per-wiki bus + spy subscriber.
    private func makeHarness() throws -> (SQLiteWikiStore, WikiEventBus, Recorder) {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (store, bus, recorder)
    }

    private func provenance() -> SourceProvenance {
        SourceProvenance(agentName: "test", activityKind: "import")
    }

    private func addSeedSource(_ store: SQLiteWikiStore) throws -> SourceSummary {
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
        try store.appendContentVersion(sourceID: s.id, data: Data("b2".utf8), mimeType: nil, provenance: nil)
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
        try store.appendProcessedMarkdown(sourceID: s.id, content: "# md", origin: "seed", note: nil)
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func recordMarkdownExtractionEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        try await drain(rec)
        try store.recordMarkdownExtraction(sourceID: s.id, content: "# md", backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: "x")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .source)
        #expect(events.last?.change == .updated)
        #expect(events.last?.id == s.id.rawValue)
    }

    @Test func revertProcessedMarkdownEmitsSourceUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        let s = try addSeedSource(store)
        let v1 = try store.appendProcessedMarkdown(sourceID: s.id, content: "v1", origin: "seed", note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: s.id, content: "v2", origin: "seed", note: nil)
        try await drain(rec)
        try store.revertProcessedMarkdown(sourceID: s.id, to: v1.id)
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

    @Test func updateSystemPromptEmitsSystemPromptUpdated() async throws {
        let (store, _, rec) = try makeHarness()
        try store.updateSystemPrompt(body: "# new prompt")
        let events = try await awaitEvents(rec)
        #expect(events.last?.kind == .systemPrompt)
        #expect(events.last?.change == .updated)
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

    // MARK: - Nil-bus store (wikictl path)

    @Test func nilBusStoreEmitsSilently() throws {
        // A store with no bus (the wikictl path) must not crash on mutation and
        // must not emit anything (there is nothing to emit into).
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(store.eventBus == nil)
        let page = try store.createPage(title: "Silent")
        #expect(page.title == "Silent")
    }
}
