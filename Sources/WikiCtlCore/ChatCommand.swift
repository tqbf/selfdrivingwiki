import Foundation
import WikiFSCore

/// The `wikictl chat …` subcommands, executed against an already-opened
/// `WikiStore`. Mirrors `PageCommand` / `SourceCommand` — split from process
/// concerns (arg parsing, stdin, opening the DB) so the whole surface is
/// unit-testable against a temp DB.
///
/// Read-only: `list` prints all chats (TSV or JSON), `get` prints one chat's
/// transcript as rendered markdown (via `ChatTranscriptRenderer`). `rename`
/// updates a chat's title. No other write subcommands — chats are
/// created/appended by the app's chat layer.
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
        case id(PageID)
        case title(String)
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case get(Selector)
        case search(query: String, limit: Int)
        case rename(Selector, to: String)
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
    /// (#637). Tantivy is the sole BM25 search path as of v38 (#634) — FTS5
    /// is gone, so `nil` here means "no BM25 leg" (cosine-only result).
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

    /// Rename a chat's title. Commits — the caller posts the Darwin
    /// notification on `didCommit`. (FTS sidecar removed at v38, #634; Tantivy
    /// re-syncs via the event bus.) Mirrors `SourceCommand.rename`.
    private static func rename(_ selector: Selector, to newTitle: String, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        try store.renameChat(id: id, to: newTitle)
        return Result(output: "Renamed chat to \"\(newTitle)\".", didCommit: true)
    }

    // MARK: - Selector resolution

    private static func resolve(_ selector: Selector, in store: WikiStore) throws -> PageID {
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
