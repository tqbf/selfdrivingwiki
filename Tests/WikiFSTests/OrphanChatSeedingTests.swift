import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the orphan-chat fix: a persisted chat must never be
/// titled-but-empty (a `chats` row with a title but zero `chat_messages`).
///
/// Root cause being fixed: `WikiStoreModel.startChat` created the `chats` row
/// eagerly at session start (title from the first message), but `chat_messages`
/// were written lazily — only when `AgentLauncher.flushTranscript()` ran at a
/// turn boundary or in `finish()`. If the agent session died before its first
/// turn produced any events, the row was orphaned: a title with no messages.
///
/// Fix: `startChat` now seeds the first user message as `chat_messages` seq 0
/// immediately, and `rollbackChatCreation` deletes a chat whose session never
/// started (preflight/spawn failure). The launcher's
/// `firstMessagePrePersisted` flag keeps the seeded row from being
/// double-inserted on the first transcript flush (modeled here at the model
/// level: a post-seed append continues from seq 1, not 0).
@MainActor
struct OrphanChatSeedingTests {

    private func tempModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - Seeding: a chat is never titled-but-empty

    @Test func startChatSeedsFirstUserMessageImmediately() throws {
        let (model, store) = try tempModel()

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "Set up the home page"))

        // The title is still derived from the first message (unchanged behavior).
        #expect(chat.title.contains("Set up the home page"))

        // The chat is NOT titled-but-empty: the first user message is already
        // persisted at seq 0, so opening it shows the user's prompt even if the
        // agent never responds.
        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 1)
        #expect(messages[0].seq == 0)
        #expect(messages[0].event == .userText("Set up the home page"))
    }

    @Test func startChatUpdatesChatsListWithOneMessage() throws {
        let (model, _) = try tempModel()

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "Hello"))

        // reloadChats() ran inside startChat, so the model's list reflects the
        // seeded message (count 1, not 0).
        let listed = try #require(model.chats.first { $0.id == chat.id })
        #expect(listed.messageCount == 1)
    }

    // MARK: - No duplicate: a post-seed flush continues from seq 1

    @Test func appendAfterSeedContinuesFromSeq1WithoutDuplicatingUserMessage() throws {
        let (model, store) = try tempModel()

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "first"))

        // Simulate the launcher's first transcript flush AFTER it has marked the
        // seeded user message as already-persisted (firstMessagePrePersisted →
        // persistedEventCount bumped past it). The flush therefore sends only the
        // agent's response tail — which must land at seq 1+, not duplicate the
        // user message at seq 0.
        model.appendChatEvents(chatID: chat.id, events: [
            .assistantText("here is the answer"),
            .result(isError: false, text: "done"),
        ])

        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 3)
        #expect(messages.map(\.seq) == [0, 1, 2])
        // seq 0 is still the seeded user message; no duplicate.
        #expect(messages[0].event == .userText("first"))
        #expect(messages[1].event == .assistantText("here is the answer"))
    }

    @Test func seedingThenAppendingManyTurnsKeepsDenseUniqueSeq() throws {
        let (model, store) = try tempModel()

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "q1"))

        // Turn 1 response.
        model.appendChatEvents(chatID: chat.id, events: [.assistantText("a1")])
        // Turn 2: user + response (the continue path appends the user message,
        // since seeding only happens at creation, not on continue).
        model.appendChatEvents(chatID: chat.id, events: [.userText("q2"), .assistantText("a2")])

        let messages = try store.chatMessages(chatID: chat.id)
        // Dense, gap-free, unique seqs — the UNIQUE(chat_id, seq) index holds.
        #expect(messages.map(\.seq) == [0, 1, 2, 3])
        #expect(messages.map(\.event) == [
            .userText("q1"), .assistantText("a1"),
            .userText("q2"), .assistantText("a2"),
        ])
    }

    // MARK: - Rollback: a session that never started leaves no trace

    @Test func rollbackChatCreationDeletesRowAndSeededMessage() throws {
        let (model, store) = try tempModel()

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "doomed"))
        #expect(try store.chatMessages(chatID: chat.id).count == 1)
        #expect(model.chats.contains { $0.id == chat.id })

        // The session never started (preflight/spawn failure) → roll back.
        model.rollbackChatCreation(id: chat.id, toDraft: .newChat)

        // Row + cascaded message both gone; the model's chat list no longer
        // contains the orphan.
        #expect(try store.chatMessages(chatID: chat.id).isEmpty)
        #expect(try store.listChats().isEmpty)
        #expect(model.chats.isEmpty)
    }

    @Test func rollbackRevertsRetargetedTabToDraftComposer() throws {
        let (model, _) = try tempModel()

        model.openTab(.newChat)
        let activeID = try #require(model.activeTabID)

        let chat = try #require(model.startChat(kind: .edit, firstMessage: "doomed"))
        model.retargetActiveTabToChat(chatID: chat.id)
        // The draft-state morph retargeted the tab to .chat(id).
        let retargeted = try #require(model.tabs.first { $0.id == activeID })
        #expect(retargeted.selection == .chat(chat.id))

        model.rollbackChatCreation(id: chat.id, toDraft: .newChat)

        // The tab is reverted to the draft composer, not left on a dead .chat.
        let reverted = try #require(model.tabs.first { $0.id == activeID })
        #expect(reverted.selection == .newChat)
    }

    @Test func rollbackIsHarmlessWhenChatAlreadyAbsent() throws {
        let (model, store) = try tempModel()
        // No chat created — rolling back a never-created id must not throw and
        // must leave the store untouched.
        let phantom = PageID(rawValue: "01PHANTOMCHAT0000000000Z")
        model.rollbackChatCreation(id: phantom, toDraft: .newChat)
        #expect(try store.listChats().isEmpty)
        #expect(model.chats.isEmpty)
    }
}
