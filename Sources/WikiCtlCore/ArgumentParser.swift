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
///   wikictl [--wiki <id>] log append --kind ingest|query|lint|repo --title X [--note N]
///   wikictl [--wiki <id>] index set --body-file <path|->
///   wikictl [--wiki <id>] repo list [--json]
///   wikictl [--wiki <id>] repo get --name owner/repo
///   wikictl [--wiki <id>] repo mark-ingested --name owner/repo --commit <sha>
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
        /// deferred I/O) — the note is optional.
        case logAppend(kind: LogEntry.Kind, title: String, note: String?)
        /// Phase B: rewrite the singleton wiki-index body. Like `upsert`, the body
        /// source is `-` for stdin or a file path; `main` reads it.
        case indexSet(bodyFile: String)
        /// Repo tracking: the agent's read + watermark surface over `tracked_repos`.
        /// Repos are addressed by their `owner/repo` NAME, never by ULID — the
        /// agent is handed the name in its prompt and never sees an id.
        case repoList(json: Bool)
        case repoGet(name: String)
        case repoMarkIngested(name: String, commit: String)
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
      log append --kind \(LogEntry.Kind.optionList) --title X [--note N]
                                             append one dated row to log.md
      index set --body-file <path|->         rewrite the curated index.md body
      repo list [--json]                     list tracked git repositories
      repo get --name owner/repo             print one repo's tracking state
      repo mark-ingested --name owner/repo --commit <sha>
                                             record that the wiki now covers <sha>
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
        case "repo":
            command = try parseRepoCommand(Array(args.dropFirst()))
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
            throw Failure.usage("log append: --kind is required (\(LogEntry.Kind.optionList))")
        }
        guard let kind = LogEntry.Kind(rawValue: kindRaw) else {
            throw Failure.usage(
                "log append: --kind must be one of \(LogEntry.Kind.optionList), "
                + "got \(kindRaw.debugDescription)")
        }
        guard let title = options.value("--title") else {
            throw Failure.usage("log append: --title is required")
        }
        return .logAppend(kind: kind, title: title, note: options.value("--note"))
    }

    /// `repo list|get|mark-ingested`. Everything selects by `--name owner/repo`,
    /// matching how the agent is told about repos; there is deliberately no
    /// `--id` form, and no `add`/`remove` — adding a repo means cloning it, which
    /// is the app's job, not the agent's.
    private static func parseRepoCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw Failure.usage("repo: missing subcommand") }
        let options = try Options(Array(args.dropFirst()))

        switch sub {
        case "list":
            return .repoList(json: options.flag("--json"))

        case "get":
            guard let name = options.value("--name") else {
                throw Failure.usage("repo get: --name is required (owner/repo)")
            }
            return .repoGet(name: name)

        case "mark-ingested":
            guard let name = options.value("--name") else {
                throw Failure.usage("repo mark-ingested: --name is required (owner/repo)")
            }
            guard let commit = options.value("--commit"), !commit.isEmpty else {
                throw Failure.usage("repo mark-ingested: --commit is required (a commit sha)")
            }
            return .repoMarkIngested(name: name, commit: commit)

        default:
            throw Failure.usage("repo: unknown subcommand \(sub.debugDescription)")
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

        init(_ tokens: [String]) throws {
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                guard token.hasPrefix("--") else {
                    throw Failure.usage("unexpected argument \(token.debugDescription)")
                }
                // `--json` is the only valueless flag; everything else takes a value.
                if token == "--json" {
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
    }
}
