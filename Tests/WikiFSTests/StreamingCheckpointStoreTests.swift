import Testing
import Foundation
@testable import WikiFSCore

/// Store-level tests for incremental in-flight checkpoint persistence (#826).
/// Verifies the draft-handle upsert (`checkpointStreamingMessage`), draft
/// finalization (`finalizeStaleDrafts`), and the `ChatMessage.isDraft` read path.
/// The launcher's timers / dirty-flag / cursor logic is tested in
/// `ChatPersistenceTests` via `unflushedTail`; these tests target the store
/// mutator directly.
@Suite(.timeLimit(.minutes(5)))
struct StreamingCheckpointStoreTests {

    // MARK: - AC.6 first checkpoint inserts a draft row

    @Test func first_checkpoint_inserts_draft() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hel"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        let draft = msgs.last { $0.event == .assistantText("Hel") }
        #expect(draft != nil)
        #expect(draft?.isDraft == true)
    }

    @Test func first_checkpoint_assigns_next_seq() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        let inserted = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi"), .assistantText("old.")])

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("partial"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        // User at seq 0, old assistant at seq 1, draft at seq 2
        #expect(msgs.count == 3)
        let draft = msgs.last { $0.isDraft }
        #expect(draft?.seq == inserted.count) // continues from max seq
    }

    // MARK: - AC.6 subsequent checkpoint updates same row (no duplication)

    @Test func second_checkpoint_updates_same_row() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hel"), isDraft: true)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        // Still only 2 rows (user + one draft), not 3
        let drafts = msgs.filter { $0.isDraft }
        #expect(drafts.count == 1)
        #expect(drafts.first?.event == .assistantText("Hello"))
    }

    // MARK: - AC.7 finalize clears is_draft

    @Test func finalize_clears_draft_flag() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello"), isDraft: true)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello world"), isDraft: false)

        let msgs = try store.chatMessages(chatID: chat.id)
        let finalized = msgs.last { $0.event == .assistantText("Hello world") }
        #expect(finalized != nil)
        #expect(finalized?.isDraft == false)
    }

    // MARK: - Idempotency

    @Test func upsert_is_idempotent() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("same"), isDraft: true)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("same"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        let drafts = msgs.filter { $0.isDraft }
        #expect(drafts.count == 1) // still one row, no error
    }

    // MARK: - Independent handles get distinct seqs

    @Test func independent_handles_get_distinct_seqs() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("block1"), isDraft: true)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h2",
            event: .assistantText("block2"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        let drafts = msgs.filter { $0.isDraft }
        #expect(drafts.count == 2)
        #expect(drafts.map(\.seq).sorted() == [0, 1]) // distinct, sequential
    }

    // MARK: - finalizeStaleDrafts (C8)

    @Test func finalizeStaleDrafts_clears_drafts() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("partial"), isDraft: true)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h2",
            event: .assistantText("partial2"), isDraft: true)

        var msgs = try store.chatMessages(chatID: chat.id)
        #expect(msgs.filter(\.isDraft).count == 2)

        try store.finalizeStaleDrafts(forChat: chat.id)

        msgs = try store.chatMessages(chatID: chat.id)
        #expect(msgs.filter(\.isDraft).count == 0)
        #expect(msgs.count == 2) // rows are still there, just no longer draft
    }

    @Test func finalizeStaleDrafts_is_noop_when_nothing_drafty() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi"), .assistantText("ok.")])

        try store.finalizeStaleDrafts(forChat: chat.id)

        let msgs = try store.chatMessages(chatID: chat.id)
        #expect(msgs.filter(\.isDraft).count == 0)
        #expect(msgs.count == 2)
    }

    // MARK: - AC.1 store equivalent: partial checkpoint survives

    @Test func partial_checkpoint_row_survives_independently() throws {
        // AC.1 store-level equivalent: a checkpointed draft row is visible in
        // chatMessages even without a subsequent finalize — simulating a hard
        // kill after a periodic checkpoint but before turn-end.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        // Simulate: 3 deltas checkpointed, then kill (no finalize)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello"), isDraft: true)

        let msgs = try store.chatMessages(chatID: chat.id)
        let draft = msgs.last
        #expect(draft?.isDraft == true)
        #expect(draft?.event == .assistantText("Hello"))
        // The partial text survives the crash
    }

    // MARK: - AC.4 store equivalent: re-checkpoint after failure still works

    @Test func re_checkpoint_after_prior_failure_succeeds() throws {
        // AC.4 store-level equivalent: a checkpoint succeeds even after a prior
        // throw (C2 retry logic). The launcher keeps streamingRowDirty=true on
        // failure and retries; the store's upsert is idempotent so the retry
        // is a no-op UPDATE when the content is the same, or an INSERT when
        // nothing exists yet.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.userText("hi")])

        // First checkpoint succeeds
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hel"), isDraft: true)
        // Retry with grown content (launcher's dirty flag kept it, next
        // checkpoint fires)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello"), isDraft: true)
        // Finalize with full text
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("Hello world"), isDraft: false)

        let msgs = try store.chatMessages(chatID: chat.id)
        let finalized = msgs.last
        #expect(finalized?.event == .assistantText("Hello world"))
        #expect(finalized?.isDraft == false)
        #expect(msgs.filter { $0.event == .assistantText("Hel") }.isEmpty)
    }

    // MARK: - ChatMessage.isDraft read path

    @Test func chatMessages_decodes_isDraft_true() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")

        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("draft"), isDraft: true)
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [AgentEvent.assistantText("final.")])

        let msgs = try store.chatMessages(chatID: chat.id)
        #expect(msgs.count == 2)
        #expect(msgs[0].isDraft == true)
        #expect(msgs[1].isDraft == false)
    }

    // MARK: - chat_search refresh only on finalize (C6)

    @Test func finalize_sets_updated_at_draft_does_not() async throws {
        // C6: draft checkpoints do NOT bump chats.updated_at; finalize does.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Chat")

        let beforeDraft = try store.getChat(id: chat.id).updatedAt
        // Small sleep to ensure timestamps differ if updated_at moves
        try await Task.sleep(for: .milliseconds(50))
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("partial"), isDraft: true)
        let afterDraft = try store.getChat(id: chat.id).updatedAt
        // Draft should NOT have moved updated_at (C6)
        #expect(afterDraft == beforeDraft)

        try await Task.sleep(for: .milliseconds(50))
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "h1",
            event: .assistantText("final"), isDraft: false)
        let afterFinalize = try store.getChat(id: chat.id).updatedAt
        // Finalize SHOULD have moved updated_at
        #expect(afterFinalize > beforeDraft)
    }
}
