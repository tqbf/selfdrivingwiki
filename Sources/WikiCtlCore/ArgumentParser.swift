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
///   wikictl [--wiki <id>] page add --title X [--id Y] --body-file <path|->
///   wikictl [--wiki <id>] page delete --id Y
///   wikictl [--wiki <id>] log append --kind ingest|query|lint --title X [--note N] [--source <file-id>]
///   wikictl [--wiki <id>] index set --body-file <path|->
///
/// `--wiki` may be omitted when the `WIKI_DB` env var supplies the selector.
public enum ArgumentParser {

    /// A fully-parsed invocation: which wiki, what to do, and — for `page add`
    /// and `index set` — where the body comes from. The body is NOT read here
    /// (that's I/O); the parser only records the source so the action's `run`
    /// reads it.
    public struct Invocation: Equatable {
        public var wikiSelector: String
        public var command: Command

        public init(wikiSelector: String, command: Command) {
            self.wikiSelector = wikiSelector
            self.command = command
        }
    }

    public enum Command: Equatable {
        /// `wikictl page …` — page reads/writes (list, get, add, delete,
        /// search, history, revert). The action carries `BodySource` for
        /// `add`, resolved by `PageCommand.run` just before the write.
        case page(PageCommand.Action)
        /// Phase B: append one dated log row. Carries its values directly (no
        /// deferred I/O) — the note is optional. `source` is the ingested-file
        /// id to stamp as ingested (only meaningful with `--kind ingest`).
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: PageID?)
        /// Phase B: rewrite the singleton wiki-index body. The body source is
        /// `-` for stdin or a file path; `main` reads it.
        case indexSet(bodyFile: String, workspace: String? = nil)
        /// Source commands: list, read, edit-markdown, rename, set-active,
        /// refresh, semantic search — all routed through `source <subcommand>`.
        /// `editMarkdown` carries `BodySource`, resolved by `SourceCommand.run`.
        case source(SourceCommand.Action)
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
        /// `wikictl wiki list/create/delete/rename` — registry operations routed
        /// through the `wikid` daemon via XPC. These bypass the `--wiki` selector
        /// requirement (they operate on the registry, not a specific wiki's store).
        case wikiList
        case wikiCreate(name: String)
        case wikiDelete(id: String)
        case wikiRename(id: String, name: String)

        /// Phase C: daemon-XPC chat commands. `chat new/send/stop` drive
        /// interactive sessions on the daemon (no app needed).
        case daemonChatNew(message: String)
        case daemonChatSend(chatID: String, message: String)
        case daemonChatStop(chatID: String)
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
      page add --title X [--id Y] --body-file <path|-> [--expect-head <ver>] [--workspace W] [--author <who>]
                                              create-or-update a page;
                                              --expect-head enables CAS (exit 3 on conflict);
                                              --workspace W writes into workspace W;
                                              --author <who> stamps created_by/last_edited_by (defaults to WIKI_AUTHOR env)
      page delete --id Y                     delete a page
      page search --query X [--limit N]       semantic search (cosine similarity);
                                              falls back to LIKE title match
      page history (--title X | --id Y)       show version history (W0)
      page revert (--title X | --id Y) --version V
                                              revert a page to version V (W0)
      page info (--title X | --id Y)          print page identity + origin provenance
                                              (HEAD's agent/activity + full edit history)
      log append --kind ingest|query|lint --title X [--note N] [--source <file-id>]
                                              append one dated row to log.md;
                                              --source stamps that file "Processed"
      index set --body-file <path|-> [--workspace W]
                                              rewrite the curated index.md body;
                                              --workspace W stages into workspace W
      source list [--json]                    list sources (TSV, or JSON lines)
      source cat  (--id X | --name N) [--markdown]
                                              write raw source bytes (or extracted markdown
                                              with --markdown) to stdout
      source export (--id X | --name N) [--out <path>] [--markdown]
                                              materialize a source to disk, print its path; --markdown exports the .md sibling
      source edit-markdown (--id X | --name N) (--content <md> | --file <path|->)
                                              replace the processed-markdown HEAD
      source search --query X [--limit N]    semantic search of sources (cosine;
                                              falls back to LIKE name match)
      source set-active (--id X | --name N) --version <smv-id>
                                              nominate a processed-markdown version
                                              as the active HEAD (extraction alt)
      source rename (--id X | --name N) --to <new-name>
                                              rename a source's display name
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
            // `wiki` subcommands — registry operations via the wikid daemon.
            // Bypass the --wiki selector requirement (same as `version`).
            if first == "wiki" {
                return Invocation(wikiSelector: "", command: try parseWikiCommand(Array(args.dropFirst())))
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
        let options = try Options(rest, booleanFlags: ["--json"])

        switch sub {
        case "list":
            return .page(.list(json: options.flag("--json")))

        case "get":
            return .page(.get(try options.requireSelector(), json: options.flag("--json"), workspace: options.value("--workspace")))

        case "add":
            guard let title = options.value("--title") else {
                throw Failure.usage("page add: --title is required")
            }
            guard let bodyFile = options.value("--body-file") else {
                throw Failure.usage("page add: --body-file is required (path or -)")
            }
            let id = options.value("--id").map { PageID(rawValue: $0) }
            let expectHead = options.value("--expect-head")
            let workspace = options.value("--workspace")
            let author = options.value("--author")
            return .page(.add(id: id, title: title, body: .file(bodyFile), expectHead: expectHead, workspace: workspace, author: author))

        case "delete":
            guard let id = options.value("--id") else {
                throw Failure.usage("page delete: --id is required")
            }
            return .page(.delete(id: PageID(rawValue: id)))

        case "search":
            guard let query = options.value("--query") else {
                throw Failure.usage("page search: --query is required")
            }
            let limit: Int
            if let raw = options.value("--limit") {
                guard let n = Int(raw), n > 0, n <= 100 else {
                    throw Failure.usage("page search: --limit must be 1–100")
                }
                limit = n
            } else {
                limit = 10
            }
            return .page(.search(query: query, limit: limit))

        case "history":
            return .page(.history(try options.requireSelector()))

        case "revert":
            guard let versionID = options.value("--version") else {
                throw Failure.usage("page revert: --version is required")
            }
            return .page(.revert(try options.requireSelector(), versionID: versionID))

        case "info":
            return .page(.info(try options.requireSelector()))

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

    private static func parseSourceCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("source: missing subcommand") }
        let rest = Array(args.dropFirst())
        // `--markdown` applies to `cat` and `export`; include it here so the
        // outer parse doesn't reject it as a value flag needing an argument.
        let options = try Options(rest, booleanFlags: ["--json", "--markdown"])

        switch sub {
        case "list":
            return .source(.list(json: options.flag("--json")))

        case "cat":
            return .source(.cat(try options.requireSourceSelector(), markdown: options.flag("--markdown")))

        case "export":
            let selector = try options.requireSourceSelector()
            return .source(.export(selector, out: options.value("--out"), markdown: options.flag("--markdown")))

        case "edit-markdown":
            // `--content` is inline; `--file` defers to BodySource resolution
            // (read at execution time, not parse time — the parser stays pure).
            let selector = try options.requireSourceSelector()
            let contentValue = options.value("--content")
            let fileValue = options.value("--file")
            switch (contentValue, fileValue) {
            case (.some, .some):
                throw Failure.usage("source edit-markdown: pass exactly one of --content / --file, not both")
            case (.none, .none):
                throw Failure.usage("source edit-markdown: pass --content <text> or --file <path>")
            case (let content?, nil):
                return .source(.editMarkdown(selector, content: .inline(content)))
            case (nil, let file?):
                return .source(.editMarkdown(selector, content: .file(file)))
            }

        case "rename":
            let selector = try options.requireSourceSelector()
            guard let newName = options.value("--to"), !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("source rename: --to <new-display-name> is required")
            }
            return .source(.rename(selector, to: newName))

        case "set-active":
            let selector = try options.requireSourceSelector()
            guard let raw = options.value("--version") ?? options.value("--version-id"),
                  !raw.isEmpty else {
                throw Failure.usage("source set-active: --version <smv-id> is required")
            }
            return .source(.setActive(selector, versionID: PageID(rawValue: raw)))

        case "info":
            return .source(.info(try options.requireSourceSelector()))

        case "refresh":
            return .source(.refresh(try options.requireSourceSelector()))

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

        case "new":
            // Phase C: daemon-XPC chat. Needs a message (positional or --message).
            let message = options.value("--message")
                ?? rest.first
                ?? ""
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("chat new: a message is required (positional or --message)")
            }
            return .daemonChatNew(message: message)

        case "send":
            let chatID = try options.value("--chat-id")
                ?? rest.first ?? { throw Failure.usage("chat send: --chat-id <id> is required") }()
            let message = options.value("--message")
                ?? rest.dropFirst().first
                ?? ""
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("chat send: a message is required (positional or --message)")
            }
            return .daemonChatSend(chatID: chatID, message: message)

        case "stop":
            let chatID = try options.value("--chat-id")
                ?? rest.first ?? { throw Failure.usage("chat stop: --chat-id <id> is required") }()
            return .daemonChatStop(chatID: chatID)

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

    /// `wikictl wiki list/create/delete/rename` — registry operations routed
    /// through the `wikid` daemon via XPC.
    private static func parseWikiCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("wiki: missing subcommand (list, create, delete, rename)") }
        let options = try Options(Array(args.dropFirst()))

        switch sub {
        case "list":
            return .wikiList

        case "create":
            let name = options.value("--name") ?? "Untitled Wiki"
            return .wikiCreate(name: name)

        case "delete":
            guard let id = options.value("--id") else {
                throw Failure.usage("wiki delete: --id is required")
            }
            return .wikiDelete(id: id)

        case "rename":
            guard let id = options.value("--id") else {
                throw Failure.usage("wiki rename: --id is required")
            }
            guard let name = options.value("--name") else {
                throw Failure.usage("wiki rename: --name is required")
            }
            return .wikiRename(id: id, name: name)

        default:
            throw Failure.usage("wiki: unknown subcommand \(sub.debugDescription) (list, create, delete, rename)")
        }
    }

    /// Apply per-spawn environment variables to commands that support them but
    /// don't already have them set explicitly. This lets the agent subprocess
    /// use plain `wikictl page get/add` / `index set` commands and have them
    /// automatically routed — the runner sets the env var before launching the
    /// agent process.
    ///
    /// - `WIKI_WORKSPACE`: routes writes/reads to the ingest's workspace
    ///   (only when `--workspace` isn't already passed).
    /// - `WIKI_AUTHOR`: stamps `created_by`/`last_edited_by` provenance (#397)
    ///   so agent-written pages are distinguishable from human-written ones. The
    ///   launcher injects `chat:<chatID>` (chat-driven) or `agent:<kind>` (one-shot
    ///   ingest/lint/query). An explicit `--author` flag always wins over the env.
    public static func applyEnv(
        _ command: Command, env: [String: String]
    ) -> Command {
        let workspaceID = env["WIKI_WORKSPACE"]
        let author = env["WIKI_AUTHOR"]
        switch command {
        case .page(.get(let selector, let json, let workspace))
            where workspace == nil && workspaceID?.isEmpty == false:
            return .page(.get(selector, json: json, workspace: workspaceID))
        case .page(.add(let id, let title, let bodySource, let expectHead, let workspace, let existingAuthor))
            where workspace == nil && workspaceID?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, workspace: workspaceID,
                             author: existingAuthor ?? author))
        case .page(.add(let id, let title, let bodySource, let expectHead, let workspace, let existingAuthor))
            where existingAuthor == nil && author?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, workspace: workspace,
                             author: author))
        case .indexSet(let bodyFile, let workspace)
            where workspace == nil && workspaceID?.isEmpty == false:
            return .indexSet(bodyFile: bodyFile, workspace: workspaceID)
        default:
            return command
        }
    }
}
