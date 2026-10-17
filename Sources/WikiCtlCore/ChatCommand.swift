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
    /// `stderrOutput` carries the zero-results notice (#1230) — the process
    /// layer writes it to stderr so stdout stays byte-identical.
    public struct Result: Equatable {
        public var output: String
        public var didCommit: Bool
        public var stderrOutput: String?

        public init(output: String, didCommit: Bool, stderrOutput: String? = nil) {
            self.output = output
            self.didCommit = didCommit
            self.stderrOutput = stderrOutput
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
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let chats = try store.listAllChatsOrderedByID()
        // #1230 (axi.md principle 5): a zero-row run says so on stderr while
        // stdout keeps its exact bytes (empty TSV, empty JSON-lines stream).
        let emptyNote = chats.isEmpty ? ZeroResults.note("chat list") : nil
        if json {
            let data = IndexGenerators.chatsJSONL(chats: chats)
            return Result(
                output: String(decoding: data, as: UTF8.self),
                didCommit: false,
                stderrOutput: emptyNote
            )
        }
        // TSV: id <tab> title <tab> kind <tab> messages, one chat per line.
        let lines = chats.map { chat in
            "\(chat.id.rawValue)\t\(chat.title)\t\(chat.kind.rawValue)\t\(chat.messageCount)"
        }
        return Result(
            output: lines.joined(separator: "\n"),
            didCommit: false,
            stderrOutput: emptyNote
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
        // #1230 (axi.md principle 5): name the query in the zero-results
        // notice so "0 results" states what matched nothing. stdout is
        // byte-identical in both cases.
        return Result(
            output: output, didCommit: false,
            stderrOutput: results.isEmpty
                ? ZeroResults.note("chat search \(query.debugDescription)") : nil)
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
