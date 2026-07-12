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
        case get(PageCommand.Selector, json: Bool, workspace: String? = nil)
        /// The body source is `-` for stdin or a file path; `main` reads it and
        /// builds the final `PageCommand.Action`. `expectHead` carries the CAS
        /// expectation for Phase 1 agent writes (nil = blind write).
        case upsert(id: PageID?, title: String, bodyFile: String, expectHead: String? = nil, workspace: String? = nil)
        case delete(id: PageID)
        /// Phase B: append one dated log row. Carries its values directly (no
        /// deferred I/O) — the note is optional. `source` is the ingested-file id
        /// to stamp as ingested (only meaningful with `--kind ingest`).
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: PageID?)
        /// Phase B: rewrite the singleton wiki-index body. Like `upsert`, the body
        /// source is `-` for stdin or a file path; `main` reads it.
        case indexSet(bodyFile: String, workspace: String? = nil)
        /// Semantic search: find pages by meaning, not keyword. Returns ranked
        /// results (most relevant first). Falls back to LIKE title match when
        /// embeddings aren't available.
        case search(query: String, limit: Int)
        /// Page version history (W0, PR #312).
        case pageHistory(PageCommand.Selector)
        /// Revert a page to a specific version (W0, PR #312).
        case pageRevert(PageCommand.Selector, versionID: String)
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
        /// Bookmark commands: list, create, rename, delete, move (#239).
        case bookmark(BookmarkCommand.Action)
        /// Workspace commands (W1, PR #312): create, status, abandon, merge.
        case workspace(WorkspaceCommand.Action)
        /// Print build version info. Does not require a wiki selection.
        case version(json: Bool)
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
    `version` / `--version` / `-v` prints build info and needs no wiki.

    commands:
      version [--json]                       print build version info; --json for machine-readable
      page list [--json]                     list pages (TSV, or JSON lines)
      page get  (--title X | --id Y) [--json] [--workspace W]
                                             print a page body; --json adds head_version_id;
                                             --workspace W reads the staged version
      page upsert --title X [--id Y] --body-file <path|-> [--expect-head <ver>] [--workspace W]
                                             create-or-update a page;
                                             --expect-head enables CAS (exit 3 on conflict);
                                             --workspace W writes into workspace W
      page delete --id Y                     delete a page
      page history (--title X | --id Y)       show version history (W0)
      page revert (--title X | --id Y) --version V
                                              revert a page to version V (W0)
      log append --kind ingest|query|lint --title X [--note N] [--source <file-id>]
                                             append one dated row to log.md;
                                             --source stamps that file "Processed"
      index set --body-file <path|-> [--workspace W]
                                             rewrite the curated index.md body;
                                             --workspace W stages into workspace W
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
      admin vacuum-page-versions [--apply] [--json]
                                              report (and with --apply, reclaim)
                                                page versions no ref/workspace references
      admin vacuum-all [--apply] [--json]    report (and with --apply, reclaim)
                                               orphaned blobs, activities, and page versions
      chat list [--json]                     list chats (TSV, or JSON lines)
      chat get  (--id X | --title T)         print a chat transcript as markdown
      chat search --query X [--limit N]      semantic + keyword search of chats
      chat rename (--id X | --title T) --to <new-title>
                                               rename a chat
      bookmark list [--json]                   list bookmark nodes (TSV, or JSON)
      bookmark create-folder [--parent ID] --name <name>
                                               create a bookmark folder
      bookmark add-ref [--parent ID] --kind <page|source|chat> --target <id>
                                               add a page/source/chat ref to bookmarks
      bookmark rename --id <node-id> --to <new-name>
                                               rename a bookmark folder
      bookmark delete --id <node-id>           delete a bookmark node (cascades)
      bookmark move --id <node-id> [--parent ID] [--position N]
                                               move a bookmark node
      workspace create [--name N]              create a workspace (prints ID)
      workspace status --id W                  show workspace status + pages
      workspace abandon --id W                abandon a workspace (GC refs)
      workspace merge --id W                   fast-forward merge into main
      workspace refresh --id W                 re-base workspace against current main
      workspace conflicts --id W               list per-page conflict details
      workspace resolve --id W --page P --body-file <path|->
                                               resolve a conflict with the given body
      workspace retry --id W                   re-open + re-merge after resolving conflicts
      workspace reap [--ttl <seconds>]         abandon stale open workspaces (default 3600s)
    """

    /// Parse `arguments` (WITHOUT the executable name) plus an env lookup into an
    /// `Invocation`. Throws `Failure.usage` with a specific message on any
    /// malformed input.
    public static func parse(
        _ arguments: [String],
        env: (String) -> String?
    ) throws -> Invocation {
        var args = arguments

        // `version` / `--version` / `-v` — print build version info and exit.
        // Intercepted BEFORE the wiki selector requirement so it works without
        // --wiki or WIKI_DB.
        if let first = args.first {
            if first == "version" {
                let options = try Options(Array(args.dropFirst()), booleanFlags: ["--json"])
                return Invocation(wikiSelector: "", command: .version(json: options.flag("--json")))
            }
            if first == "--version" || first == "-v" {
                return Invocation(wikiSelector: "", command: .version(json: false))
            }
        }

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
        case "bookmark":
            command = try parseBookmarkCommand(Array(args.dropFirst()))
        case "workspace":
            command = try parseWorkspaceCommand(Array(args.dropFirst()))
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
            return .get(try options.requireSelector(), json: options.flag("--json"), workspace: options.value("--workspace"))

        case "upsert":
            guard let title = options.value("--title") else {
                throw Failure.usage("page upsert: --title is required")
            }
            guard let bodyFile = options.value("--body-file") else {
                throw Failure.usage("page upsert: --body-file is required (path or -)")
            }
            let id = options.value("--id").map { PageID(rawValue: $0) }
            let expectHead = options.value("--expect-head")
            let workspace = options.value("--workspace")
            return .upsert(id: id, title: title, bodyFile: bodyFile, expectHead: expectHead, workspace: workspace)

        case "delete":
            guard let id = options.value("--id") else {
                throw Failure.usage("page delete: --id is required")
            }
            return .delete(id: PageID(rawValue: id))

        case "history":
            return .pageHistory(try options.requireSelector())

        case "revert":
            guard let versionID = options.value("--version") else {
                throw Failure.usage("page revert: --version is required")
            }
            return .pageRevert(try options.requireSelector(), versionID: versionID)

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
        case "vacuum-page-versions":
            // Same flags as vacuum-blobs (Phase 4 — multi-writer hardening).
            let options = try Options(rest, booleanFlags: ["--apply", "--json"])
            return .admin(.vacuumPageVersions(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-all":
            // Combined: blobs + activities + page versions in one pass.
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

        case "search":
            guard let query = options.value("--query") else {
                throw Failure.usage("chat search: --query is required")
            }
            let limit: Int
            if let raw = options.value("--limit") {
                guard let n = Int(raw), n > 0, n <= 100 else {
                    throw Failure.usage("chat search: --limit must be 1–100")
                }
                limit = n
            } else {
                limit = 10
            }
            return .chat(.search(query: query, limit: limit))

        case "rename":
            let selector = try options.requireChatSelector()
            guard let newName = options.value("--to"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("chat rename: --to <new-title> is required")
            }
            return .chat(.rename(selector, to: newName))

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
        return .indexSet(bodyFile: bodyFile, workspace: options.value("--workspace"))
    }

    // MARK: - bookmark

    private static func parseBookmarkCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("bookmark: missing subcommand") }
        let rest = Array(args.dropFirst())
        let options = try Options(rest)

        switch sub {
        case "list":
            return .bookmark(.list(json: options.flag("--json")))

        case "create-folder":
            guard let name = options.value("--name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("bookmark create-folder: --name <folder-name> is required")
            }
            let parentID = options.value("--parent")  // nil = root
            return .bookmark(.createFolder(parentID: parentID, name: name))

        case "add-ref":
            guard let kindStr = options.value("--kind") else {
                throw Failure.usage("bookmark add-ref: --kind <page|source|chat> is required")
            }
            let kind: BookmarkNodeKind
            switch kindStr {
            case "page": kind = .pageRef
            case "source": kind = .sourceRef
            case "chat": kind = .chatRef
            default:
                throw Failure.usage("bookmark add-ref: --kind must be page, source, or chat")
            }
            guard let targetID = options.value("--target"), !targetID.isEmpty else {
                throw Failure.usage("bookmark add-ref: --target <id> is required")
            }
            let parentID = options.value("--parent")
            return .bookmark(.addRef(parentID: parentID, kind: kind, targetID: PageID(rawValue: targetID)))

        case "rename":
            guard let id = options.value("--id"), !id.isEmpty else {
                throw Failure.usage("bookmark rename: --id <node-id> is required")
            }
            guard let newName = options.value("--to"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("bookmark rename: --to <new-name> is required")
            }
            return .bookmark(.rename(id: id, to: newName))

        case "delete":
            guard let id = options.value("--id"), !id.isEmpty else {
                throw Failure.usage("bookmark delete: --id <node-id> is required")
            }
            return .bookmark(.delete(id: id))

        case "move":
            guard let id = options.value("--id"), !id.isEmpty else {
                throw Failure.usage("bookmark move: --id <node-id> is required")
            }
            let toParent = options.value("--parent")  // nil = root
            let position: Int
            if let raw = options.value("--position") {
                guard let n = Int(raw) else {
                    throw Failure.usage("bookmark move: --position must be an integer")
                }
                position = n
            } else {
                position = -1  // Append to end
            }
            return .bookmark(.move(id: id, toParentID: toParent, position: position))

        default:
            throw Failure.usage("bookmark: unknown subcommand \(sub.debugDescription)")
        }
    }

    private static func parseWorkspaceCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("workspace: missing subcommand") }
        let options = try Options(Array(args.dropFirst()))

        switch sub {
        case "create":
            let name = options.value("--name")
            return .workspace(.create(name: name))

        case "status":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace status: --id is required")
            }
            return .workspace(.status(id: id))

        case "abandon":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace abandon: --id is required")
            }
            return .workspace(.abandon(id: id))

        case "merge":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace merge: --id is required")
            }
            return .workspace(.merge(id: id))

        case "refresh":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace refresh: --id is required")
            }
            return .workspace(.refresh(id: id))

        case "conflicts":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace conflicts: --id is required")
            }
            return .workspace(.conflicts(id: id))

        case "resolve":
            guard let id = options.value("--id"),
                  let pageID = options.value("--page").map({ PageID(rawValue: $0) }),
                  let bodyFile = options.value("--body-file") else {
                throw Failure.usage("workspace resolve: --id, --page, and --body-file are required")
            }
            return .workspace(.resolve(id: id, pageID: pageID, bodyFile: bodyFile))

        case "retry":
            guard let id = options.value("--id") else {
                throw Failure.usage("workspace retry: --id is required")
            }
            return .workspace(.retry(id: id))

        case "reap":
            let ttlStr = options.value("--ttl") ?? "3600"
            guard let ttl = TimeInterval(ttlStr) else {
                throw Failure.usage("workspace reap: --ttl must be a number (seconds)")
            }
            return .workspace(.reap(ttl: ttl))

        default:
            throw Failure.usage("workspace: unknown subcommand \(sub.debugDescription)")
        }
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
