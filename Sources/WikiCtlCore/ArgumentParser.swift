import Foundation
import WikiFSCore

/// Pure argument parsing for `wikictl`, split from all process concerns (env,
/// stdin, the DB, the Darwin post) so the whole dispatch surface is unit-testable:
/// a test feeds an `argv` array + an env lookup and asserts on the parsed result,
/// with no filesystem touched.
///
/// Grammar (`plans/llm-wiki.md` Phase A + B surface):
///   wikictl [--wiki <id>] page list [--json]
///   wikictl [--wiki <id>] page get (--title X | --id Y)
///   wikictl [--wiki <id>] page upsert --title X [--id Y] --body-file <path|->
///   wikictl [--wiki <id>] page delete --id Y
///   wikictl [--wiki <id>] log append --kind ingest|query|lint --title X [--note N] [--source <file-id>]
///   wikictl [--wiki <id>] index set --body-file <path|->
///
/// `--wiki` may be omitted when the `WIKI_DB` env var supplies the selector.
public enum ArgumentParser {

    /// A fully-parsed invocation: which wiki, what to do, and — for `upsert` —
    /// where the body comes from. The body is NOT read here (that's I/O); the
    /// parser only records the source so `main` reads it.
    public struct Invocation: Equatable {
        public var wikiSelector: String
        public var command: Command

        public init(wikiSelector: String, command: Command) {
            self.wikiSelector = wikiSelector
            self.command = command
        }
    }

    public enum Command: Equatable {
        case list(json: Bool)
        case get(PageCommand.Selector)
        /// The body source is `-` for stdin or a file path; `main` reads it and
        /// builds the final `PageCommand.Action`.
        case upsert(id: PageID?, title: String, bodyFile: String)
        case delete(id: PageID)
        /// Phase B: append one dated log row. Carries its values directly (no
        /// deferred I/O) — the note is optional. `source` is the ingested-file id
        /// to stamp as ingested (only meaningful with `--kind ingest`).
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: PageID?)
        /// Phase B: rewrite the singleton wiki-index body. Like `upsert`, the body
        /// source is `-` for stdin or a file path; `main` reads it.
        case indexSet(bodyFile: String)
        /// Semantic search: find pages by meaning, not keyword. Returns ranked
        /// results (most relevant first). Falls back to LIKE title match when
        /// embeddings aren't available.
        case search(query: String, limit: Int)
        /// Source commands: list, read, export sources from SQLite.
        case source(SourceCommand.Action)
        /// Edit processed markdown for a source. When `isFile` is true,
        /// `contentOrFile` is a file path (or `-` for stdin); when false it is
        /// the literal markdown content. `main` resolves the file in the former
        /// case before appending.
        case sourceEditMarkdown(SourceCommand.Selector, contentOrFile: String, isFile: Bool)
        /// Rename a source's display name and rewrite links pointing at it.
        case sourceRename(SourceCommand.Selector, to: String)
        /// Nominate a processed-markdown version as the active HEAD (Phase 2).
        case sourceSetActive(SourceCommand.Selector, versionID: PageID)
        /// Re-fetch a source via its provider, appending a new version (Phase 3b).
        case sourceRefresh(SourceCommand.Selector)
        /// Maintenance operations (the `admin …` family). Currently: blob GC.
        case admin(AdminCommand.Action)
        /// Chat commands: list, read chat transcripts from SQLite.
        case chat(ChatCommand.Action)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case usage(String)

        public var description: String {
            switch self {
            case .usage(let text): text
            }
        }
    }

    public static let usageText = """
    usage: wikictl [--wiki <id>] <command>

    Selects the wiki by --wiki <id-or-name> or the WIKI_DB env var.

    commands:
      page list [--json]                     list pages (TSV, or JSON lines)
      page get  (--title X | --id Y)         print a page body (instant SoT read)
      page upsert --title X [--id Y] --body-file <path|->
                                             create-or-update a page from a body
      page delete --id Y                     delete a page
      log append --kind ingest|query|lint --title X [--note N] [--source <file-id>]
                                             append one dated row to log.md;
                                             --source stamps that file "Processed"
      index set --body-file <path|->         rewrite the curated index.md body
      search --query X [--limit N]           semantic search (cosine similarity);
                                             falls back to LIKE title match
      source list [--json]                    list sources (TSV, or JSON lines)
      source cat  (--id X | --name N)         write raw source bytes to stdout
      source export (--id X | --name N) [--out <path>]
                                              materialize a source to disk, print its path
      source edit-markdown (--id X | --name N) (--content <md> | --file <path|->)
                                              replace the processed-markdown HEAD
      source search --query X [--limit N]    semantic search of sources (cosine;
                                              falls back to LIKE name match)
      source set-active (--id X | --name N) --version <smv-id>
                                              nominate a processed-markdown version
                                              as the active HEAD (extraction alt)
      source refresh (--id X | --name N)      re-fetch a website source via its
                                               provider, appending a new version
      admin vacuum-blobs [--apply] [--json]   report (and with --apply, reclaim)
                                               blobs no version row references
      admin vacuum-activities [--apply] [--json]
                                             report (and with --apply, reclaim)
                                               activities no version row references
      admin vacuum-all [--apply] [--json]    report (and with --apply, reclaim)
                                               both orphaned blobs and activities
      chat list [--json]                     list chats (TSV, or JSON lines)
      chat get  (--id X | --title T)         print a chat transcript as markdown
    """

    /// Parse `arguments` (WITHOUT the executable name) plus an env lookup into an
    /// `Invocation`. Throws `Failure.usage` with a specific message on any
    /// malformed input.
    public static func parse(
        _ arguments: [String],
        env: (String) -> String?
    ) throws -> Invocation {
        var args = arguments

        // A leading `--wiki <id>` is optional; otherwise fall back to WIKI_DB.
        var wikiSelector: String?
        if args.first == "--wiki" {
            guard args.count >= 2 else { throw Failure.usage("--wiki requires a value") }
            wikiSelector = args[1]
            args.removeFirst(2)
        } else if let envValue = env("WIKI_DB"), !envValue.isEmpty {
            wikiSelector = envValue
        }
        guard let selector = wikiSelector else {
            throw Failure.usage("no wiki selected — pass --wiki <id> or set WIKI_DB")
        }

        let command: Command
        switch args.first {
        case "page":
            command = try parsePageCommand(Array(args.dropFirst()))
        case "log":
            command = try parseLogCommand(Array(args.dropFirst()))
        case "index":
            command = try parseIndexCommand(Array(args.dropFirst()))
        case "search":
            command = try parseSearchCommand(Array(args.dropFirst()))
        case "source":
            command = try parseSourceCommand(Array(args.dropFirst()))
        case "admin":
            command = try parseAdminCommand(Array(args.dropFirst()))
        case "chat":
            command = try parseChatCommand(Array(args.dropFirst()))
        default:
            throw Failure.usage("unknown command \((args.first ?? "").debugDescription)")
        }
        return Invocation(wikiSelector: selector, command: command)
    }

    private static func parsePageCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("page: missing subcommand") }
        let rest = Array(args.dropFirst())
        let options = try Options(rest)

        switch sub {
        case "list":
            return .list(json: options.flag("--json"))

        case "get":
            return .get(try options.requireSelector())

        case "upsert":
            guard let title = options.value("--title") else {
                throw Failure.usage("page upsert: --title is required")
            }
            guard let bodyFile = options.value("--body-file") else {
                throw Failure.usage("page upsert: --body-file is required (path or -)")
            }
            let id = options.value("--id").map { PageID(rawValue: $0) }
            return .upsert(id: id, title: title, bodyFile: bodyFile)

        case "delete":
            guard let id = options.value("--id") else {
                throw Failure.usage("page delete: --id is required")
            }
            return .delete(id: PageID(rawValue: id))

        default:
            throw Failure.usage("page: unknown subcommand \(sub.debugDescription)")
        }
    }

    private static func parseLogCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("log: missing subcommand") }
        guard sub == "append" else {
            throw Failure.usage("log: unknown subcommand \(sub.debugDescription)")
        }
        let options = try Options(Array(args.dropFirst()))
        guard let kindRaw = options.value("--kind") else {
            throw Failure.usage("log append: --kind is required (ingest|query|lint)")
        }
        guard let kind = LogEntry.Kind(rawValue: kindRaw) else {
            throw Failure.usage(
                "log append: --kind must be one of ingest|query|lint, got \(kindRaw.debugDescription)")
        }
        guard let title = options.value("--title") else {
            throw Failure.usage("log append: --title is required")
        }
        let source = options.value("--source").map { PageID(rawValue: $0) }
        return .logAppend(kind: kind, title: title, note: options.value("--note"), source: source)
    }

    private static func parseSearchCommand(_ args: [String]) throws -> Command {
        let options = try Options(args)
        guard let query = options.value("--query") else {
            throw Failure.usage("search: --query is required")
        }
        let limit: Int
        if let raw = options.value("--limit") {
            guard let n = Int(raw), n > 0, n <= 100 else {
                throw Failure.usage("search: --limit must be 1–100")
            }
            limit = n
        } else {
            limit = 10
        }
        return .search(query: query, limit: limit)
    }

    private static func parseSourceCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("source: missing subcommand") }
        let rest = Array(args.dropFirst())
        let options = try Options(rest)

        switch sub {
        case "list":
            return .source(.list(json: options.flag("--json")))

        case "cat":
            return .source(.cat(try options.requireSourceSelector()))

        case "export":
            let selector = try options.requireSourceSelector()
            return .source(.export(selector, out: options.value("--out")))

        case "edit-markdown":
            return try parseSourceEditMarkdown(options)

        case "rename":
            let selector = try options.requireSourceSelector()
            guard let newName = options.value("--to"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("source rename: --to <new-display-name> is required")
            }
            return .sourceRename(selector, to: newName)

        case "set-active":
            let selector = try options.requireSourceSelector()
            guard let raw = options.value("--version") ?? options.value("--version-id"),
                  !raw.isEmpty else {
                throw Failure.usage("source set-active: --version <smv-id> is required")
            }
            return .sourceSetActive(selector, versionID: PageID(rawValue: raw))

        case "info":
            return .source(.info(try options.requireSourceSelector()))

        case "refresh":
            return .sourceRefresh(try options.requireSourceSelector())

        case "search":
            guard let query = options.value("--query") else {
                throw Failure.usage("source search: --query is required")
            }
            let limit: Int
            if let raw = options.value("--limit") {
                guard let n = Int(raw), n > 0, n <= 100 else {
                    throw Failure.usage("source search: --limit must be 1–100")
                }
                limit = n
            } else {
                limit = 10
            }
            return .source(.search(query: query, limit: limit))

        default:
            throw Failure.usage("source: unknown subcommand \(sub.debugDescription)")
        }
    }

    private static func parseSourceEditMarkdown(_ options: Options) throws -> Command {
        let selector = try options.requireSourceSelector()

        let contentValue = options.value("--content")
        let fileValue = options.value("--file")

        switch (contentValue, fileValue) {
        case (.some, .some):
            throw Failure.usage("source edit-markdown: pass exactly one of --content / --file, not both")
        case (.none, .none):
            throw Failure.usage("source edit-markdown: pass --content <text> or --file <path>")
        case (let content?, nil):
            return .sourceEditMarkdown(selector, contentOrFile: content, isFile: false)
        case (nil, let file?):
            return .sourceEditMarkdown(selector, contentOrFile: file, isFile: true)
        }
    }

    private static func parseAdminCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("admin: missing subcommand") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "vacuum-blobs":
            // `--apply` opts INTO deletion; the default is a safe dry run.
            // `--json` selects machine-readable output.
            let options = try Options(rest, booleanFlags: ["--apply", "--json"])
            return .admin(.vacuumBlobs(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-activities":
            // Same flags as vacuum-blobs (issue #257).
            let options = try Options(rest, booleanFlags: ["--apply", "--json"])
            return .admin(.vacuumActivities(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-all":
            // Combined: both blob + activity orphans in one pass (issue #257).
            let options = try Options(rest, booleanFlags: ["--apply", "--json"])
            return .admin(.vacuumAll(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        default:
            throw Failure.usage("admin: unknown subcommand \(sub.debugDescription)")
        }
    }

    private static func parseChatCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("chat: missing subcommand") }
        let rest = Array(args.dropFirst())
        let options = try Options(rest)

        switch sub {
        case "list":
            return .chat(.list(json: options.flag("--json")))

        case "get":
            return .chat(.get(try options.requireChatSelector()))

        default:
            throw Failure.usage("chat: unknown subcommand \(sub.debugDescription)")
        }
    }

    private static func parseIndexCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("index: missing subcommand") }
        guard sub == "set" else {
            throw Failure.usage("index: unknown subcommand \(sub.debugDescription)")
        }
        let options = try Options(Array(args.dropFirst()))
        guard let bodyFile = options.value("--body-file") else {
            throw Failure.usage("index set: --body-file is required (path or -)")
        }
        return .indexSet(bodyFile: bodyFile)
    }

    /// A tiny `--key value` / `--flag` option bag. Tolerates options in any order;
    /// rejects an unbalanced trailing `--key` with no value.
    private struct Options {
        private var values: [String: String] = [:]
        private var flags: Set<String> = []

        init(_ tokens: [String], booleanFlags: Set<String> = ["--json"]) throws {
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                guard token.hasPrefix("--") else {
                    throw Failure.usage("unexpected argument \(token.debugDescription)")
                }
                // A valueless boolean flag (e.g. `--json`, `--apply`); everything
                // else takes a value.
                if booleanFlags.contains(token) {
                    flags.insert(token)
                    index += 1
                    continue
                }
                guard index + 1 < tokens.count else {
                    throw Failure.usage("\(token) requires a value")
                }
                values[token] = tokens[index + 1]
                index += 2
            }
        }

        func value(_ key: String) -> String? { values[key] }
        func flag(_ key: String) -> Bool { flags.contains(key) }

        /// A `--title X` or `--id Y` page selector (exactly one required).
        func requireSelector() throws -> PageCommand.Selector {
            switch (values["--id"], values["--title"]) {
            case (let id?, nil):
                return .id(PageID(rawValue: id))
            case (nil, let title?):
                return .title(title)
            case (.some, .some):
                throw Failure.usage("pass exactly one of --id / --title, not both")
            case (nil, nil):
                throw Failure.usage("pass one of --id / --title")
            }
        }

        /// A `--id Y` or `--title T` chat selector (exactly one required).
        func requireChatSelector() throws -> ChatCommand.Selector {
            switch (values["--id"], values["--title"]) {
            case (let id?, nil):
                return .id(PageID(rawValue: id))
            case (nil, let title?):
                return .title(title)
            case (.some, .some):
                throw Failure.usage("pass exactly one of --id / --title, not both")
            case (nil, nil):
                throw Failure.usage("pass one of --id / --title")
            }
        }

        /// A `--id Y` or `--name N` source selector (exactly one required).
        func requireSourceSelector() throws -> SourceCommand.Selector {
            switch (values["--id"], values["--name"]) {
            case (let id?, nil):
                return .id(PageID(rawValue: id))
            case (nil, let name?):
                return .name(name)
            case (.some, .some):
                throw Failure.usage("pass exactly one of --id / --name, not both")
            case (nil, nil):
                throw Failure.usage("pass one of --id / --name")
            }
        }
    }
}
