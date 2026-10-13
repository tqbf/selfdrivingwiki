import Foundation
import Testing
@testable import WikiFSCore

/// Persistence contract for the `chat_attachments` table
/// (plans/chat-attachment-persistence.md): ordered target writes, replace-all
/// semantics, checked decode, behavioral event discipline (exactly one
/// post-commit `.chat` event per successful write, ZERO on failure), the
/// ABORT-trigger rollback proofs, and the literal restart (a fresh store +
/// model over the same DB file restores the targets).
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatAttachmentPersistenceTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-persist-\(UUID().uuidString).sqlite")
    }

    private func makeStore() throws -> GRDBWikiStore {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        return store
    }

    /// Counts post-commit `.chat` events by change kind. The bus dispatches
    /// handlers via `Task`, so assertions poll with a bounded wait.
    @MainActor
    private final class EventCounter {
        private(set) var created = 0
        private(set) var updated = 0
        private var token: SubscriptionToken?

        func attach(to bus: WikiEventBus) {
            token = bus.subscribe(nil) { [weak self] event in
                guard event.kind == .chat else { return }
                switch event.change {
                case .created: self?.created += 1
                case .updated: self?.updated += 1
                default: break
                }
            }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    // MARK: - Write/read contract (AC.1)

    @Test("setChatAttachments writes ordered, typed rows (page/source/chat)")
    func setWritesOrderedTargets() throws {
        let store = try makeStore()
        let chat = try store.createChat(kind: .edit, title: "")

        let targets: [ChatAttachmentTarget] = [
            .source(SourceID(rawValue: "01HORDER1")),
            .page(PageID(rawValue: "01HORDER2")),
            .chat(ChatID(rawValue: "01HORDER3")),
        ]
        try store.setChatAttachments(chatID: chat.id, targets: targets)

        #expect(try store.chatAttachments(chatID: chat.id) == targets)
    }

    @Test("setChatAttachments replaces wholesale (no stale rows)")
    func setReplacesWholesale() throws {
        let store = try makeStore()
        let chat = try store.createChat(kind: .edit, title: "")
        try store.setChatAttachments(chatID: chat.id, targets: [
            .page(PageID(rawValue: "01HOLD1")),
            .page(PageID(rawValue: "01HOLD2")),
            .page(PageID(rawValue: "01HOLD3")),
        ])

        try store.setChatAttachments(chatID: chat.id, targets: [
            .source(SourceID(rawValue: "01HNEW")),
        ])

        #expect(try store.chatAttachments(chatID: chat.id)
            == [.source(SourceID(rawValue: "01HNEW"))])
    }

    @Test("setChatAttachments on a missing chat throws chatNotFound")
    func setOnMissingChatThrows() throws {
        let store = try makeStore()
        do {
            try store.setChatAttachments(
                chatID: ChatID(rawValue: "01HMISSING"),
                targets: [.page(PageID(rawValue: "01HX"))])
            Issue.record("missing chat must throw")
        } catch let error as WikiStoreError {
            guard case .chatNotFound = error else {
                Issue.record("expected chatNotFound, got \(error)")
                return
            }
        }
    }

    @Test("an unknown persisted kind tag throws on read (checked decode)")
    func unknownKindTagThrowsOnRead() throws {
        let url = tempURL()
        let store = try GRDBWikiStore(databaseURL: url)
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let chat = try store.createChat(kind: .edit, title: "")
        store.close()

        // A future build (or corruption) wrote a tag this build cannot know.
        try MetadataSQLiteFixtureSupport.execute(
            """
            INSERT INTO chat_attachments (chat_id, kind, raw_id, position)
            VALUES ('\(chat.id.rawValue)', 'bookmark', '01HBOGUS', 0);
            """,
            at: url)
        let reopened = try GRDBWikiStore(databaseURL: url)

        #expect(throws: WikiStoreError.self) {
            try reopened.chatAttachments(chatID: chat.id)
        }
    }

    // MARK: - Restart (AC.3)

    @Test("a fresh store over the same DB file restores the targets")
    func restartFreshStoreRestoresTargets() throws {
        let url = tempURL()
        let first = try GRDBWikiStore(databaseURL: url)
        first.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let chat = try first.createChat(kind: .edit, title: "")
        let targets: [ChatAttachmentTarget] = [
            .page(PageID(rawValue: "01HRESTART")),
            .chat(ChatID(rawValue: "01HRESTART2")),
        ]
        try first.setChatAttachments(chatID: chat.id, targets: targets)

        let second = try GRDBWikiStore(databaseURL: url)
        #expect(try second.chatAttachments(chatID: chat.id) == targets)
    }

    // MARK: - Rename keeps target identity (AC.10, identity half)

    @Test("renames do not disturb the persisted target identities")
    func renamesKeepTargetIdentity() throws {
        let store = try makeStore()
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        let page = try store.createPage(title: "Before")
        let source = try store.addSource(filename: "before.pdf", data: Data("b".utf8))
        let chat = try store.createChat(kind: .edit, title: "Chat Before")
        let targets: [ChatAttachmentTarget] = [
            .page(page.id), .source(source.id), .chat(chat.id),
        ]
        try store.setChatAttachments(chatID: chat.id, targets: targets)

        // Rename all three through the model (cache-refreshing paths).
        model.reloadFromStore()
        model.rename(page.id, to: "After")
        model.renameSource(id: source.id, to: "after.pdf")
        model.renameChat(id: chat.id, to: "Chat After")
        model.reloadFromStore()

        // The persisted identities are unchanged.
        #expect(try store.chatAttachments(chatID: chat.id) == targets)
    }

    // MARK: - Behavioral events + rollback (AC.8 / AC.4)

    @Test("each successful write emits exactly one post-commit .chat event")
    func successfulWritesEmitExactlyOneEventEach() async throws {
        let store = try makeStore()
        let counter = EventCounter()
        counter.attach(to: store.eventBus!)

        let chat = try store.createChat(kind: .edit, title: "", attachments: [
            .page(PageID(rawValue: "01HEVT")),
        ])
        #expect(await waitUntil { counter.created == 1 }, "composed create emits one .created")
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 0 })

        try store.setChatAttachments(chatID: chat.id, targets: [
            .source(SourceID(rawValue: "01HEVT2")),
        ])
        #expect(await waitUntil { counter.updated == 1 }, "set emits one .updated")
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.created == 1 })
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 1 },
                "no duplicate events settle in later")
    }

    @Test("an attachment-insert failure rolls the composed create back: no chat, no rows, zero events")
    func composedCreateRollsBackOnAttachmentFailure() async throws {
        let url = tempURL()
        let store = try GRDBWikiStore(databaseURL: url)
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let counter = EventCounter()
        counter.attach(to: store.eventBus!)
        // Seed an existing chat so the failure provably happens AFTER a chat
        // insert is possible (the composed create inserts a NEW row).
        _ = try store.createChat(kind: .edit, title: "Seed")
        #expect(await waitUntil { counter.created == 1 })

        // Fail every future chat_attachments insert.
        try MetadataSQLiteFixtureSupport.execute(
            """
            CREATE TRIGGER fail_chat_attachments_insert
            BEFORE INSERT ON chat_attachments
            BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """,
            at: url)

        do {
            _ = try store.createChat(kind: .edit, title: "Doomed", attachments: [
                .page(PageID(rawValue: "01HDOOM")),
            ])
            Issue.record("the composed create must fail when the attachment insert fails")
        } catch {
            // Expected: the injected ABORT surfaces here.
        }

        // Rollback proof: no doomed chat, no attachment rows, zero events.
        #expect(try store.listChats().map(\.title) == ["Seed"])
        let seeded = try #require(try store.listChats().first)
        #expect(try store.chatAttachments(chatID: seeded.id).isEmpty)
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.created == 1 },
                "the failed write emitted no .created event")
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 0 })
        _ = url

        // Cleanup: drop the trigger so the store stays usable in-test.
        try MetadataSQLiteFixtureSupport.execute(
            "DROP TRIGGER IF EXISTS fail_chat_attachments_insert;", at: url)
    }

    @Test("a failed setChatAttachments rolls back: old rows intact, zero events")
    func setRollbackKeepsOldRows() async throws {
        let url = tempURL()
        let store = try GRDBWikiStore(databaseURL: url)
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let counter = EventCounter()
        counter.attach(to: store.eventBus!)
        let chat = try store.createChat(kind: .edit, title: "")
        let original: [ChatAttachmentTarget] = [
            .page(PageID(rawValue: "01HKEEP1")),
            .page(PageID(rawValue: "01HKEEP2")),
        ]
        try store.setChatAttachments(chatID: chat.id, targets: original)
        #expect(await waitUntil { counter.updated == 1 })

        try MetadataSQLiteFixtureSupport.execute(
            """
            CREATE TRIGGER fail_chat_attachments_insert
            BEFORE INSERT ON chat_attachments
            BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """,
            at: url)

        do {
            try store.setChatAttachments(chatID: chat.id, targets: [
                .source(SourceID(rawValue: "01HNEVER")),
            ])
            Issue.record("the replacement must fail under the injected trigger")
        } catch {
            // Expected.
        }

        #expect(try store.chatAttachments(chatID: chat.id) == original,
                "the old set survives the rolled-back replacement")
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 1 },
                "the failed write emitted no .updated event")

        try MetadataSQLiteFixtureSupport.execute(
            "DROP TRIGGER IF EXISTS fail_chat_attachments_insert;", at: url)
        // The gate is usable again after the trigger is dropped.
        try store.setChatAttachments(chatID: chat.id, targets: [
            .source(SourceID(rawValue: "01HAFTER")),
        ])
        #expect(await waitUntil { counter.updated == 2 })
    }
}
