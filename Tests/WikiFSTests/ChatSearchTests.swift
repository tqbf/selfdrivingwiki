import Testing
import Foundation
import SQLite3
@testable import WikiCtlCore
@testable import WikiFSCore

/// Store-level tests for semantic + FTS search over persisted chats
/// (issue #245, schema v28). The lexical (FTS5/BM25) path runs fully under
/// `swift test` (it is NOT app-gated like the vec semantic path); the semantic
/// cosine path needs the bundled embedding model, so these tests exercise the
/// FTS backbone plus the chunk-embedding mechanics (`storeChatChunks`,
/// `missingChatEmbeddingWork`, incremental no-wipe) that are model-independent.
@Suite struct ChatSearchTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-search-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - FTS backbone (always runs)

    @Test func searchFindsChatByMessageBodyWithNeutralTitle() throws {
        let store = try tempStore()
        // Title says nothing about entanglement; the assistant message does.
        let chat = try store.createChat(kind: .edit, title: "Misc Notes")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("explain something"),
            .assistantText("Quantum entanglement links particles across distance."),
        ])
        let hits = try store.searchSimilarChats(query: "entanglement", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id == chat.id)
    }

    @Test func searchAccumulatesBodyAcrossMultipleAppends() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Project")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("talk about thermodynamics"),
        ])
        // A distinct term appended in a SEPARATE flush must still be searchable —
        // the sidecar rebuild concatenates the whole chat each append.
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("Photosynthesis converts light into chemical energy."),
        ])
        #expect(try store.searchSimilarChats(query: "photosynthesis", limit: 10).first?.id == chat.id)
    }

    @Test func searchRespectsLimit() throws {
        let store = try tempStore()
        for i in 0..<5 {
            let chat = try store.createChat(kind: .edit, title: "Chat \(i)")
            _ = try store.appendChatMessages(chatID: chat.id, events: [
                .assistantText("Report \(i) discusses the budget forecast."),
            ])
        }
        let hits = try store.searchSimilarChats(query: "budget", limit: 2)
        #expect(hits.count == 2)
    }

    @Test func searchEmptyWhenNoMatch() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Greetings")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("Hello there, how can I help?"),
        ])
        #expect(try store.searchSimilarChats(query: "zzznomatchxyz", limit: 10).isEmpty)
    }

    @Test func searchReflectsRename() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Old Title")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("A body with no distinctive keywords."),
        ])
        // The old title is searchable before rename.
        #expect(try store.searchSimilarChats(query: "Old", limit: 10).first?.id == chat.id)
        try store.renameChat(id: chat.id, to: "Completely Renamed")
        // New title is now searchable…
        #expect(try store.searchSimilarChats(query: "Renamed", limit: 10).first?.id == chat.id)
        // …and the old one no longer matches (the body has none of those words).
        #expect(try store.searchSimilarChats(query: "Old", limit: 10).isEmpty)
    }

    @Test func sidecarNotPopulatedUntilFirstAppend() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Placeholder")
        // A chat with no messages has an empty body → nothing to match.
        #expect(try store.searchSimilarChats(query: "Placeholder", limit: 10).isEmpty)
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("Now the body has Placeholder in it."),
        ])
        #expect(try store.searchSimilarChats(query: "Placeholder", limit: 10).first?.id == chat.id)
    }

    // MARK: - Chunk-embedding mechanics (model-independent)

    @Test func missingChatEmbeddingWorkListsChatsWithoutChunks() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Discussed")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("user turn about ideas"),
            .assistantText("assistant turn with prose"),
        ])
        let work = store.missingChatEmbeddingWork()
        #expect(work.contains { $0.id == chat.id })
        // The embeddable text includes the title + the user/assistant prose.
        let entry = try #require(work.first { $0.id == chat.id })
        #expect(entry.text.contains("Discussed"))
        #expect(entry.text.contains("user turn about ideas"))
        #expect(entry.text.contains("assistant turn with prose"))
    }

    @Test func storeChatChunksMarksChatAsEmbedded() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "To Embed")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("hi")])
        // Bulk-embed via the upgrade path (replace-all semantics).
        try store.storeChatChunks(id: chat.id, chunks: [Data(repeating: 0, count: 16)])
        let work = store.missingChatEmbeddingWork()
        #expect(!work.contains { $0.id == chat.id })
    }

    /// The core incremental invariant: appending messages must NOT wipe a chat's
    /// existing chunk embeddings (chats are append-only; only the bulk upgrade
    /// path deletes-then-reinserts). Verified through `missingChatEmbeddingWork`
    /// so it is independent of the bundled embedding model.
    @Test func appendChatMessagesDoesNotWipeExistingChunks() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Incremental")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("first turn")])
        try store.storeChatChunks(id: chat.id, chunks: [Data(repeating: 1, count: 16)])
        // Embedded now.
        #expect(!store.missingChatEmbeddingWork().contains { $0.id == chat.id })
        // A later append (which re-embeds only the new message when vec is
        // available, else no-ops) must leave the prior chunks intact.
        _ = try store.appendChatMessages(chatID: chat.id, events: [.assistantText("second turn")])
        #expect(!store.missingChatEmbeddingWork().contains { $0.id == chat.id })
    }

    @Test func deleteChatRemovesItsChunks() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Doomed")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("bye")])
        try store.storeChatChunks(id: chat.id, chunks: [Data(repeating: 2, count: 16)])
        try store.deleteChat(id: chat.id)
        // The ON DELETE CASCADE on chat_chunks removes them; the chat is gone
        // from missing-work entirely (no row to be "missing").
        #expect(store.missingChatEmbeddingWork().isEmpty)
        #expect(try store.searchSimilarChats(query: "Doomed", limit: 10).isEmpty)
    }

    // MARK: - wikictl `chat search`

    @Test func chatSearchCommandOutputsTSV() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Mars Colony")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("We discussed terraforming the Martian surface."),
        ])
        let result = try ChatCommand.run(.search(query: "terraforming", limit: 10), in: store)
        #expect(result.didCommit == false)
        let cols = result.output.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(String(cols[0]) == chat.id.rawValue)
        #expect(String(cols[1]) == "Mars Colony")
        #expect(String(cols[2]) == "edit")
        #expect(String(cols[3]) == "1")
    }

    @Test func parseChatSearchRequiresQuery() throws {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(["--wiki", "W", "chat", "search"], env: noEnv)
        }
    }

    @Test func parseChatSearchAcceptsLimit() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "chat", "search", "--query", "hello", "--limit", "3",
        ], env: noEnv)
        guard case .chat(let action) = inv.command,
              case .search(let query, let limit) = action else {
            Issue.record("expected .chat(.search)"); return
        }
        #expect(query == "hello")
        #expect(limit == 3)
    }

    // MARK: - wikictl `chat rename`

    @Test func chatRenameByIdCommitsAndUpdatesTitle() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Old Title")
        let result = try ChatCommand.run(
            .rename(.id(chat.id), to: "New Title"), in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("New Title"))
        // Store-level verify: the title actually changed.
        let chats = try store.listAllChatsOrderedByID()
        #expect(chats.first(where: { $0.id == chat.id })?.title == "New Title")
    }

    @Test func chatRenameByTitleResolvesAndRenames() throws {
        let store = try tempStore()
        _ = try store.createChat(kind: .edit, title: "Original Title")
        let result = try ChatCommand.run(
            .rename(.title("Original Title"), to: "Renamed"), in: store
        )
        #expect(result.didCommit == true)
        let chats = try store.listAllChatsOrderedByID()
        #expect(chats.first?.title == "Renamed")
    }

    @Test func parseChatRenameRequiresTo() throws {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse([
                "--wiki", "W", "chat", "rename", "--id", "abc",
            ], env: noEnv)
        }
    }

    @Test func parseChatRenameByIdProducesCorrectAction() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "chat", "rename", "--id", "abc123", "--to", "New Name",
        ], env: noEnv)
        guard case .chat(let action) = inv.command,
              case .rename(let selector, let newTitle) = action else {
            Issue.record("expected .chat(.rename)"); return
        }
        guard case .id(let id) = selector else {
            Issue.record("expected .id selector"); return
        }
        #expect(id.rawValue == "abc123")
        #expect(newTitle == "New Name")
    }

    @Test func parseChatRenameByTitleProducesCorrectAction() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "chat", "rename", "--title", "Old", "--to", "New",
        ], env: noEnv)
        guard case .chat(let action) = inv.command,
              case .rename(let selector, let newTitle) = action else {
            Issue.record("expected .chat(.rename)"); return
        }
        guard case .title(let title) = selector else {
            Issue.record("expected .title selector"); return
        }
        #expect(title == "Old")
        #expect(newTitle == "New")
    }
}
