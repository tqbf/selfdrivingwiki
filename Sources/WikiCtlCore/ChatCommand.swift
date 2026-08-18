import Foundation
import WikiFSCore

/// The `wikictl chat …` subcommands, executed against an already-opened
/// `WikiStore`. Mirrors `PageCommand` / `SourceCommand` — split from process
/// concerns (arg parsing, stdin, opening the DB) so the whole surface is
/// unit-testable against a temp DB.
///
/// `list` prints all chats (TSV or JSON), `get` prints one chat's transcript as
/// rendered markdown (via `ChatTranscriptRenderer`), and `search` searches
/// chat summaries. `rename` updates a chat's title. `repair` is a guarded,
/// dry-run-by-default recovery of one typed assistant message from a retained
/// debug trace. Other chat messages are created/appended by the app's chat
/// layer.
public enum ChatCommand {

    /// What a command produced: text to print and whether it COMMITTED a write.
    /// Read commands have `didCommit = false`; `rename` commits.
    public struct Result: Equatable {
        public var output: String
        public var didCommit: Bool

        public init(output: String, didCommit: Bool) {
            self.output = output
            self.didCommit = didCommit
        }
    }

    /// How a chat is selected for `get`.
    public enum Selector: Equatable {
        case id(ChatID)
        case title(String)
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case get(Selector)
        case search(query: String, limit: Int)
        case rename(Selector, to: String)
        case repair(
            chatID: ChatID,
            updatesFile: String,
            messageID: ChatMessageID,
            expectedSHA256: String?,
            apply: Bool
        )
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Run one action against `store`. Reads never commit; `rename` does.
    ///
    /// `bm25Leg` is the pre-resolved Tantivy BM25 leg for the `.search` action
    /// (#637). Post-#634 this is the SOLE BM25 leg (FTS5 was dropped); `nil`
    /// (the default) means no BM25 results — only the cosine semantic leg runs.
    /// Caller-resolved via `CLITantivyLegResolver.resolveChatLeg(...)` in
    /// `wikictl`'s `execute()`.
    public static func run(
        _ action: Action,
        in store: WikiStore,
        bm25Leg: [ChatSummary]? = nil
    ) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .get(let selector):
            return try get(selector, in: store)
        case .search(let query, let limit):
            return try search(query: query, limit: limit, bm25Leg: bm25Leg, in: store)
        case .rename(let selector, let newTitle):
            return try rename(selector, to: newTitle, in: store)
        case .repair(let chatID, let updatesFile, let messageID, let expectedSHA256, let apply):
            return try repair(
                chatID: chatID,
                updatesFile: updatesFile,
                messageID: messageID,
                expectedSHA256: expectedSHA256,
                apply: apply,
                in: store)
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let chats = try store.listAllChatsOrderedByID()
        if json {
            let data = IndexGenerators.chatsJSONL(chats: chats)
            return Result(
                output: String(decoding: data, as: UTF8.self),
                didCommit: false
            )
        }
        // TSV: id <tab> title <tab> kind <tab> messages, one chat per line.
        let lines = chats.map { chat in
            "\(chat.id.rawValue)\t\(chat.title)\t\(chat.kind.rawValue)\t\(chat.messageCount)"
        }
        return Result(
            output: lines.joined(separator: "\n"),
            didCommit: false
        )
    }

    // MARK: - get

    /// Print one chat's transcript as rendered markdown (via
    /// `ChatTranscriptRenderer`). The same bytes the File Provider projects at
    /// `chats/by-id/<ULID>.md`.
    private static func get(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let chats = try store.listAllChatsOrderedByID()
        guard let summary = chats.first(where: { $0.id == id }) else {
            throw Failure.message("chat not found: \(id.rawValue)")
        }
        let messages = try store.chatMessages(chatID: id)
        let transcript = ChatTranscriptRenderer.render(summary: summary, messages: messages)
        return Result(output: transcript, didCommit: false)
    }

    // MARK: - search

    /// Hybrid (FTS + semantic) search over chat conversations. Mirrors
    /// `PageCommand.search` / `SourceCommand.search`: ranks chats by how well
    /// their message text matches the query. Output is TSV
    /// (id <tab> title <tab> kind <tab> messages), best match first.
    private static func search(
        query: String, limit: Int, bm25Leg: [ChatSummary]?, in store: WikiStore
    ) throws -> Result {
        let results = try store.searchSimilarChats(query: query, limit: limit, bm25Leg: bm25Leg)
        let output: String = results.map { chat in
            let title = chat.title.replacingOccurrences(of: "\t", with: " ")
            return "\(chat.id.rawValue)\t\(title)\t\(chat.kind.rawValue)\t\(chat.messageCount)"
        }.joined(separator: "\n")
        return Result(output: output, didCommit: false)
    }

    // MARK: - rename

    /// Rename a chat's title and rebuild the `chat_search` FTS sidecar.
    /// Commits — the caller posts the Darwin notification on `didCommit`.
    /// Mirrors `SourceCommand.rename`.
    private static func rename(_ selector: Selector, to newTitle: String, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        try store.renameChat(id: id, to: newTitle)
        return Result(output: "Renamed chat to \"\(newTitle)\".", didCommit: true)
    }

    // MARK: - repair

    private static func repair(
        chatID: ChatID,
        updatesFile: String,
        messageID: ChatMessageID,
        expectedSHA256: String?,
        apply: Bool,
        in store: WikiStore
    ) throws -> Result {
        if apply && expectedSHA256 == nil {
            throw Failure.message("chat repair: --expected-sha256 is required with --apply")
        }

        let updates: Data
        do {
            updates = try Data(contentsOf: URL(fileURLWithPath: updatesFile))
        } catch {
            throw Failure.message("chat repair: cannot read updates file \(updatesFile.debugDescription): \(error.localizedDescription)")
        }
        let recovered: ChatRecovery.RecoveredResponse
        do {
            recovered = try ChatRecovery.recover(from: updates)
        } catch let failure as ChatRecovery.Failure {
            throw Failure.message("chat repair: \(failure)")
        }

        let typedItems = try readAllTranscriptItems(chatID: chatID, from: store)
        let legacyMessages = try store.chatMessages(chatID: chatID)
        let matches = typedItems.compactMap { persisted -> PersistedChatTranscriptItem? in
            guard case .message(let item) = persisted.item, item.messageID == messageID else { return nil }
            return persisted
        }
        if matches.isEmpty {
            if typedItems.isEmpty && !legacyMessages.isEmpty {
                throw Failure.message("chat repair: refusing legacy-only chat; no typed transcript identity is available")
            }
            throw Failure.message("chat repair: app message ID not found: \(messageID.rawValue)")
        }
        guard matches.count == 1 else {
            throw Failure.message("chat repair: app message ID is ambiguous: \(messageID.rawValue)")
        }
        let persisted = matches[0]
        guard case .message(let existing) = persisted.item else {
            throw Failure.message("chat repair: app message ID is not a message: \(messageID.rawValue)")
        }
        guard existing.role == .assistant else {
            throw Failure.message("chat repair: app message ID is not an assistant message: \(messageID.rawValue)")
        }
        guard legacyMessages.count == typedItems.count else {
            throw Failure.message("chat repair: typed transcript and compatibility projection are out of sync")
        }
        let compatibilitySequence = Int(persisted.cursor.rawValue - 1)
        guard let compatibility = legacyMessages.first(where: { $0.seq == compatibilitySequence }),
              case .assistantText(let currentText) = compatibility.event else {
            throw Failure.message("chat repair: compatibility assistant row is missing for cursor \(persisted.cursor.rawValue)")
        }
        guard existing.text == currentText else {
            throw Failure.message("chat repair: typed transcript and compatibility assistant text are out of sync")
        }

        let oldDigest = RendererSHA256.digest(Data(currentText.utf8)).hex
        let newDigest = RendererSHA256.digest(Data(recovered.text.utf8)).hex
        if apply {
            guard let expectedSHA256 else {
                throw Failure.message("chat repair: --expected-sha256 is required with --apply")
            }
            do {
                _ = try RendererSHA256Digest(hex: expectedSHA256)
            } catch {
                throw Failure.message("chat repair: --expected-sha256 must be a lowercase 64-character SHA-256 digest")
            }
            guard oldDigest == expectedSHA256 else {
                throw Failure.message("chat repair: expected SHA-256 \(expectedSHA256), but current text is \(oldDigest); refusing to write")
            }
            let replacement = ChatTranscriptItem.message(ChatTranscriptMessageItem(
                messageID: existing.messageID,
                turnID: existing.turnID,
                role: existing.role,
                text: recovered.text,
                createdAt: existing.createdAt
            ))
            let persisted = try store.appendChatTranscriptItems(chatID: chatID, items: [replacement])
            guard persisted.count == 1 else {
                throw Failure.message("chat repair: store did not upsert exactly one transcript item")
            }
        }

        let mode = apply ? "repaired" : "dry run; would repair"
        return Result(
            output: "\(mode) chat \(chatID.rawValue) message \(messageID.rawValue)\nupdates: \(updatesFile)\nold SHA-256: \(oldDigest)\nnew SHA-256: \(newDigest)\nold characters: \(currentText.count)\nnew characters: \(recovered.text.count)",
            didCommit: apply)
    }

    private static func readAllTranscriptItems(
        chatID: ChatID,
        from store: WikiStore
    ) throws -> [PersistedChatTranscriptItem] {
        let pageSize = 200
        var items: [PersistedChatTranscriptItem] = []
        var cursor: ChatTranscriptCursor?
        while true {
            let page = try store.readChatTranscriptPage(chatID: chatID, after: cursor, limit: pageSize)
            items.append(contentsOf: page.items)
            guard page.items.count == pageSize,
                  let next = page.nextCursor,
                  next != cursor else { break }
            cursor = next
        }
        return items
    }

    // MARK: - Selector resolution

    private static func resolve(_ selector: Selector, in store: WikiStore) throws -> ChatID {
        switch selector {
        case .id(let id):
            return id
        case .title(let title):
            guard let id = try store.resolveChatByTitle(title) else {
                throw Failure.message("no chat titled \(title.debugDescription)")
            }
            return id
        }
    }
}
