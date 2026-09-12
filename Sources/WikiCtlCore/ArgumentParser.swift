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
/// `--help`/`-h` on the command path (`wikictl source list --help`) prints
/// scoped help generated from `CLIReference` — the same table that drives
/// subcommand recognition and option validation (#1224).
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
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: SourceID?)
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
        /// Print scoped command usage (`wikictl [source [add]] --help`).
        /// Does not require a wiki selection (#1224).
        case help(CLIHelpScope)
        /// Print build version info. Does not require a wiki selection.
        case version(json: Bool)
        /// Print the resolved Cordis profile. Does not require a wiki selection.
        case dumpConfig(overlay: String?)
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

    /// The top-level usage text, GENERATED from the `CLIReference` spec the
    /// parser routes with — a hand-maintained copy drifts by construction
    /// (#1224).
    public static var usageText: String { CLIReference.helpText(for: .topLevel) }

    /// Parse `arguments` (WITHOUT the executable name) plus an env lookup into an
    /// `Invocation`. Throws `Failure.usage` with a specific message on any
    /// malformed input.
    public static func parse(
        _ arguments: [String],
        env: (String) -> String?
    ) throws -> Invocation {
        var args = arguments

        // #1224: `--help`/`-h` on the command path — top level, family,
        // subcommand, or OKF operation — returns scoped help BEFORE the
        // wiki-selector requirement (help never needs --wiki or WIKI_DB).
        if let scope = CLIReference.resolveHelpScope(args) {
            return Invocation(wikiSelector: "", command: .help(scope))
        }

        // Help and version commands are intercepted BEFORE the wiki selector
        // requirement so they work without --wiki or WIKI_DB.
        if let first = args.first {
            if first == "version" {
                let options = try Options(
                    Array(args.dropFirst()),
                    options: CLIReference.options(forTopLevelCommand: "version"))
                return Invocation(wikiSelector: "", command: .version(json: options.flag("--json")))
            }
            if first == "--version" || first == "-v" {
                return Invocation(wikiSelector: "", command: .version(json: false))
            }
            if first == "--dump-config" {
                let options = try Options(
                    Array(args.dropFirst()),
                    options: CLIReference.options(forTopLevelCommand: "--dump-config"))
                return Invocation(wikiSelector: "", command: .dumpConfig(overlay: options.value("--patch")))
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
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "page"))
        }
        guard CLIReference.leaf(family: "page", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "page", given: sub))
        }
        let rest = Array(args.dropFirst())
        if sub == "okf" {
            return .page(try parsePageOKFCommand(rest))
        }
        // One bag for the family: its option set is the union of the leaves'
        // spec'd options, so an unlisted option is rejected by the same table
        // the help text is generated from (#1224).
        let options = try Options(rest, options: CLIReference.options(forFamily: "page"))

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
            let expectHead = options.value("--expect-head").map(PageVersionID.init(rawValue:))
            let workspace = options.value("--workspace")
            let author = options.value("--author")
            let provenance = try decodePageVersionSources(options.values("--source"))
            return .page(.add(id: id, title: title, body: .file(bodyFile), expectHead: expectHead, workspace: workspace, author: author, provenance: provenance))

        case "delete":
            guard let id = options.value("--id") else {
                throw Failure.usage("page delete: --id is required")
            }
            return .page(.delete(id: PageID(rawValue: id), unlinkIncoming: options.flag("--unlink-incoming")))

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
            guard let versionID = options.value("--version").map(PageVersionID.init(rawValue:)) else {
                throw Failure.usage("page revert: --version is required")
            }
            return .page(.revert(try options.requireSelector(), versionID: versionID))

        case "info":
            return .page(.info(try options.requireSelector()))

        default:
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "page", given: sub))
        }
    }

    private static func parsePageOKFCommand(_ args: [String]) throws -> PageCommand.Action {
        let parsed = try parseOKFCommand(args, version: PageVersionID.init(rawValue:))
        switch parsed {
        case .inspect(let id, let json): return .okfInspect(versionID: id, json: json)
        case .status(let id, let status): return .okfStatus(versionID: id, status: status)
        case .freshness(let id, let input): return .okfFreshness(versionID: id, input: input)
        case .verify(let id, let input): return .okfVerify(versionID: id, input: input)
        case .correct(let id, let input): return .okfCorrect(versionID: id, input: input)
        }
    }

    private static func parseSourceOKFCommand(_ args: [String]) throws -> SourceCommand.Action {
        let parsed = try parseOKFCommand(args, version: SourceMarkdownVersionID.init(rawValue:))
        switch parsed {
        case .inspect(let id, let json): return .okfInspect(versionID: id, json: json)
        case .status(let id, let status): return .okfStatus(versionID: id, status: status)
        case .freshness(let id, let input): return .okfFreshness(versionID: id, input: input)
        case .verify(let id, let input): return .okfVerify(versionID: id, input: input)
        case .correct(let id, let input): return .okfCorrect(versionID: id, input: input)
        }
    }

    private enum ParsedOKFCommand<VersionID> {
        case inspect(VersionID, Bool)
        case status(VersionID, OKFConceptStatus?)
        case freshness(VersionID, OKFFreshnessInput)
        case verify(VersionID, OKFVerificationInput)
        case correct(VersionID, OKFCorrectionInput)
    }

    private static func parseOKFCommand<VersionID>(
        _ args: [String], version: (String) -> VersionID
    ) throws -> ParsedOKFCommand<VersionID> {
        guard let operation = args.first else { throw Failure.usage("okf: missing operation") }
        guard let op = CLIReference.okfOperation(named: operation) else {
            throw Failure.usage(CLIReference.unknownOKFOperationMessage(given: operation))
        }
        let options = try Options(Array(args.dropFirst()), options: op.options)
        guard let rawVersion = options.value("--version"), !rawVersion.isEmpty else {
            throw Failure.usage("okf \(operation): --version is required")
        }
        let versionID = version(rawVersion)
        switch operation {
        case "inspect":
            return .inspect(versionID, options.flag("--json"))
        case "status":
            if options.flag("--clear") { return .status(versionID, nil) }
            guard let rawStatus = options.value("--status"),
                  let status = OKFConceptStatus(rawValue: rawStatus) else {
                throw Failure.usage("okf status: --status must be draft, stable, or deprecated; use --clear to unset")
            }
            return .status(versionID, status)
        case "freshness":
            return .freshness(versionID, try parseFreshness(options, allowRecordedVerification: false))
        case "verify":
            guard let actorRaw = options.value("--by") else {
                throw Failure.usage("okf verify: --by is required")
            }
            let verifier: OKFVerifierIdentity
            do { verifier = try OKFVerifierIdentity(actorRaw) }
            catch { throw Failure.usage(error.localizedDescription) }
            let verifiedAt = try options.value("--at").map(OKFCommandSupport.parseTimestamp) ?? Date()
            guard let basisRaw = options.value("--basis"),
                  let basis = OKFVerificationBasisKind(rawValue: basisRaw) else {
                throw Failure.usage("okf verify: --basis must be human-review, source-checked, or external-revalidation")
            }
            let evidence = try options.values("--evidence").map(OKFCommandSupport.parseEvidence)
            let freshness: OKFFreshnessInput?
            if let ttl = options.value("--ttl") {
                freshness = .ttl(try OKFCommandSupport.parseDuration(ttl), anchor: .recordedVerification)
            } else { freshness = nil }
            return .verify(versionID, .init(
                verifier: verifier, verifiedAt: verifiedAt,
                basis: .init(kind: basis, evidence: evidence, note: options.value("--note")),
                freshness: freshness))
        case "correct":
            guard let verificationRaw = options.value("--verification"), !verificationRaw.isEmpty else {
                throw Failure.usage("okf correct: --verification is required")
            }
            guard let actorRaw = options.value("--by") else {
                throw Failure.usage("okf correct: --by is required")
            }
            let verifier: OKFVerifierIdentity
            do { verifier = try OKFVerifierIdentity(actorRaw) }
            catch { throw Failure.usage(error.localizedDescription) }
            let correctedAt = try options.value("--at").map(OKFCommandSupport.parseTimestamp) ?? Date()
            return .correct(versionID, .init(
                verificationID: .init(rawValue: verificationRaw),
                verifier: verifier, correctedAt: correctedAt,
                reason: options.value("--reason").map(OKFVerificationCorrectionReason.init(reason:))))
        default:
            // Unreachable: recognition is the CLIReference operation table above.
            throw Failure.usage(CLIReference.unknownOKFOperationMessage(given: operation))
        }
    }

    private static func parseFreshness(
        _ options: Options, allowRecordedVerification: Bool
    ) throws -> OKFFreshnessInput {
        if options.flag("--clear") { return .clear }
        if let fixed = options.value("--stale-after") {
            return .fixed(try OKFCommandSupport.parseTimestamp(fixed))
        }
        guard let ttlRaw = options.value("--ttl") else {
            throw Failure.usage("okf freshness: use --clear, --stale-after <ISO-8601>, or --ttl <duration>")
        }
        let duration = try OKFCommandSupport.parseDuration(ttlRaw)
        let anchorRaw = options.value("--anchor") ?? "generated"
        let anchor: OKFFreshnessAnchor
        switch anchorRaw {
        case "generated": anchor = .generated
        case "verification":
            guard let id = options.value("--verification"), !id.isEmpty else {
                throw Failure.usage("verification-anchored freshness requires --verification <id>")
            }
            anchor = .verification(.init(rawValue: id))
        case "recorded-verification" where allowRecordedVerification:
            anchor = .recordedVerification
        default:
            throw Failure.usage("freshness anchor must be generated or verification")
        }
        return .ttl(duration, anchor: anchor)
    }

    private static func parseLogCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "log"))
        }
        guard sub == "append" else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "log", given: sub))
        }
        let options = try Options(Array(args.dropFirst()), options: CLIReference.options(forFamily: "log"))
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
        let source = options.value("--source").map { SourceID(rawValue: $0) }
        return .logAppend(kind: kind, title: title, note: options.value("--note"), source: source)
    }

    private static func parseSourceCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "source"))
        }
        guard CLIReference.leaf(family: "source", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "source", given: sub))
        }
        let rest = Array(args.dropFirst())
        if sub == "okf" {
            return .source(try parseSourceOKFCommand(rest))
        }
        // Family-wide bag: `--markdown` applies to `cat` and `export`, etc. —
        // the spec union drives both acceptance and help (#1224).
        let options = try Options(rest, options: CLIReference.options(forFamily: "source"))

        switch sub {
        case "add":
            let url = options.value("--url")
            let bodyFile = options.value("--body-file")
            guard (url == nil) != (bodyFile == nil) else {
                throw Failure.usage("source add: pass exactly one of --url URL or --body-file <path|->")
            }
            if let url {
                return .source(.addURL(url, allowDuplicateURL: options.flag("--allow-duplicate")))
            }
            guard !options.flag("--allow-duplicate") else {
                throw Failure.usage("source add: --allow-duplicate applies only to --url")
            }
            guard let bodyFile else {
                throw Failure.usage("source add: --body-file is required")
            }
            let name = options.value("--name")
            if bodyFile == "-", name == nil {
                throw Failure.usage("source add: --name is required when --body-file is -")
            }
            return .source(.addFile(path: bodyFile, name: name))
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
            return .source(.setActive(selector, versionID: SourceMarkdownVersionID(rawValue: raw)))

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
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "source", given: sub))
        }
    }

    private static func parseAdminCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "admin"))
        }
        guard CLIReference.leaf(family: "admin", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "admin", given: sub))
        }
        let rest = Array(args.dropFirst())
        // `--apply` opts INTO deletion/repair; the default is a safe dry run.
        // `--json` selects machine-readable output.
        let options = try Options(rest, options: CLIReference.options(forFamily: "admin"))
        switch sub {
        case "vacuum-blobs":
            return .admin(.vacuumBlobs(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-activities":
            // Same flags as vacuum-blobs (issue #257).
            return .admin(.vacuumActivities(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-page-versions":
            // Same flags as vacuum-blobs (Phase 4 — multi-writer hardening).
            return .admin(.vacuumPageVersions(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "vacuum-all":
            // Combined: blobs + activities + page versions in one pass.
            return .admin(.vacuumAll(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        case "repair-mime":
            return .admin(.repairMIME(
                dryRun: !options.flag("--apply"), json: options.flag("--json")))
        default:
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "admin", given: sub))
        }
    }

    private static func parseChatCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "chat"))
        }
        guard CLIReference.leaf(family: "chat", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "chat", given: sub))
        }
        let rest = Array(args.dropFirst())
        let options = try Options(rest, options: CLIReference.options(forFamily: "chat"))

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
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "chat", given: sub))
        }
    }

    private static func parseIndexCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "index"))
        }
        guard sub == "set" else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "index", given: sub))
        }
        let options = try Options(Array(args.dropFirst()), options: CLIReference.options(forFamily: "index"))
        guard let bodyFile = options.value("--body-file") else {
            throw Failure.usage("index set: --body-file is required (path or -)")
        }
        return .indexSet(bodyFile: bodyFile, workspace: options.value("--workspace"))
    }

    // MARK: - bookmark

    private static func parseBookmarkCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "bookmark"))
        }
        guard CLIReference.leaf(family: "bookmark", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "bookmark", given: sub))
        }
        let rest = Array(args.dropFirst())
        let options = try Options(rest, options: CLIReference.options(forFamily: "bookmark"))

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
            let content: BookmarkNode.Content
            switch kind {
            case .pageRef: content = .page(PageID(rawValue: targetID))
            case .sourceRef: content = .source(SourceID(rawValue: targetID))
            case .chatRef: content = .chat(ChatID(rawValue: targetID))
            case .folder:
                throw Failure.usage("bookmark add-ref: folder is not a reference")
            }
            return .bookmark(.addRef(parentID: parentID, content: content))

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
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "bookmark", given: sub))
        }
    }

    private static func parseWorkspaceCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "workspace"))
        }
        guard CLIReference.leaf(family: "workspace", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "workspace", given: sub))
        }
        let options = try Options(Array(args.dropFirst()), options: CLIReference.options(forFamily: "workspace"))

        switch sub {
        case "create":
            let name = options.value("--name")
            return .workspace(.create(name: name))

        case "status":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
                throw Failure.usage("workspace status: --id is required")
            }
            return .workspace(.status(id: id))

        case "abandon":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
                throw Failure.usage("workspace abandon: --id is required")
            }
            return .workspace(.abandon(id: id))

        case "merge":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
                throw Failure.usage("workspace merge: --id is required")
            }
            return .workspace(.merge(id: id))

        case "refresh":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
                throw Failure.usage("workspace refresh: --id is required")
            }
            return .workspace(.refresh(id: id))

        case "conflicts":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
                throw Failure.usage("workspace conflicts: --id is required")
            }
            return .workspace(.conflicts(id: id))

        case "resolve":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }),
                  let pageID = options.value("--page").map({ PageID(rawValue: $0) }),
                  let bodyFile = options.value("--body-file") else {
                throw Failure.usage("workspace resolve: --id, --page, and --body-file are required")
            }
            return .workspace(.resolve(id: id, pageID: pageID, bodyFile: bodyFile))

        case "retry":
            guard let id = options.value("--id").map({ WorkspaceID(rawValue: $0) }) else {
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
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "workspace", given: sub))
        }
    }

    /// A tiny `--key value` / `--flag` option bag. Tolerates options in any
    /// order; rejects an unbalanced trailing `--key` with no value.
    ///
    /// `allowed` comes from the `CLIReference` spec — the same definitions the
    /// help text is generated from — so an unlisted option is a loud usage
    /// error here instead of a silently-ignored token (#1224).
    struct Options {
        private var valuesByKey: [String: [String]] = [:]
        private var flags: Set<String> = []

        init(_ tokens: [String], options allowed: [CLIReference.CLIOption]) throws {
            let byName = Dictionary(allowed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                guard token.hasPrefix("--") else {
                    throw Failure.usage("unexpected argument \(token.debugDescription)")
                }
                guard let spec = byName[token] else {
                    throw Failure.usage(
                        "unexpected option \(token.debugDescription) — run with --help for usage")
                }
                if spec.takesValue {
                    guard index + 1 < tokens.count else {
                        throw Failure.usage("\(token) requires a value")
                    }
                    valuesByKey[token, default: []].append(tokens[index + 1])
                    index += 2
                } else {
                    flags.insert(token)
                    index += 1
                }
            }
        }

        func value(_ key: String) -> String? { valuesByKey[key]?.last }
        func values(_ key: String) -> [String] { valuesByKey[key] ?? [] }
        func flag(_ key: String) -> Bool { flags.contains(key) }

        /// A `--title X` or `--id Y` page selector (exactly one required).
        func requireSelector() throws -> PageCommand.Selector {
            switch (value("--id"), value("--title")) {
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
            switch (value("--id"), value("--title")) {
            case (let id?, nil):
                return .id(ChatID(rawValue: id))
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
            switch (value("--id"), value("--name")) {
            case (let id?, nil):
                return .id(SourceID(rawValue: id))
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
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "wiki"))
        }
        guard CLIReference.leaf(family: "wiki", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "wiki", given: sub))
        }
        let options = try Options(Array(args.dropFirst()), options: CLIReference.options(forFamily: "wiki"))

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
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "wiki", given: sub))
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
        case .page(.add(let id, let title, let bodySource, let expectHead, let workspace, let existingAuthor, let provenance))
            where workspace == nil && workspaceID?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, workspace: workspaceID,
                             author: existingAuthor ?? author, provenance: provenance))
        case .page(.add(let id, let title, let bodySource, let expectHead, let workspace, let existingAuthor, let provenance))
            where existingAuthor == nil && author?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, workspace: workspace,
                             author: author, provenance: provenance))
        case .indexSet(let bodyFile, let workspace)
            where workspace == nil && workspaceID?.isEmpty == false:
            return .indexSet(bodyFile: bodyFile, workspace: workspaceID)
        default:
            return command
        }
    }

    /// Decodes the repeatable external CLI representation at its boundary.
    /// `sourceID` defaults to primary. Empty and unknown roles are rejected.
    private static func decodePageVersionSources(
        _ rawValues: [String]
    ) throws -> [PageVersionSourceInput] {
        try rawValues.map { rawValue in
            let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let sourceID = SourceID(rawValue: String(parts[0]))
            let rawRole = parts.count == 2 ? String(parts[1]) : PageVersionSourceRole.primary.rawValue
            guard let role = PageVersionSourceRole(rawValue: rawRole) else {
                throw PageVersionProvenanceWriteError.invalidRole(rawValue: rawRole)
            }
            return PageVersionSourceInput(sourceID: sourceID, role: role)
        }
    }
}
