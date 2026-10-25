import Foundation
import WikiFSCore

/// Pure argument parsing for `wikictl`, split from all process concerns (env,
/// stdin, the DB, the Darwin post) so the whole dispatch surface is unit-testable:
/// a test feeds an `argv` array + an env lookup and asserts on the parsed result,
/// with no filesystem touched.
///
/// Grammar (`plans/llm-wiki.md` Phase A + B surface):
///   wikictl [--wiki <id> | --wiki=<id>] page list [--json]
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
///
/// An EXPLICIT database selector (`--database-path`/`WIKI_DB_PATH`) is NOT
/// part of this grammar. Since the fixture-binary split (plans/cli-domain-
/// commands.md §"The fixture binary") the shipping `wikictl` has NO local
/// database pathway: both spellings are rejected with a usage error that names
/// the build-only `wikictl-fixture` binary, which owns the fixture surface.
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
        /// `author` is the run's resolved identity in its raw stored form
        /// (`agent:<kind>` / `chat:<id>` / a plain name): nil from the parser
        /// (`log append` takes no `--author` flag), filled from `WIKI_AUTHOR`
        /// by ``applyEnv(_:env:)`` so `LogIndexCommand` can refuse
        /// agent-authored `--source` stamps (#1367).
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: SourceID?, author: String? = nil)
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
        /// `wikictl extractor sync <package>` — create one byteless source
        /// per configured acquisition key of `<package>` and enqueue its
        /// extraction job. Generic family: new acquisition packages add a
        /// dispatch case, not a CLI family.
        case extractor(ExtractorSyncCommand.Action)
        /// Read-only durable queue job inspection.
        case job(JobCommand.Action)
        /// Per-lane queue truth + lane controls over the live daemon.
        case queue(QueueCommand.Action)
        /// Explicit on-device speech transcription over the live daemon.
        case transcribe(TranscribeCommand.Action)
        /// Workspace commands (W1, PR #312): create, status, abandon, merge.
        case workspace(WorkspaceCommand.Action)
        /// Strategy commands: read, save, reset for the per-wiki editorial
        /// strategy singleton. Save/reset carry the REQUIRED CAS expectation
        /// (`.absent` = no strategy row has ever been written).
        case strategy(StrategyCommand.Action)
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
            // `extractor list` is read-only discovery over the machine
            // catalog (App Group container): it never needs a wiki, so it
            // bypasses the selector requirement too. `extractor sync`
            // still requires one.
            if first == "extractor", args.dropFirst().first == "list" {
                return Invocation(
                    wikiSelector: "",
                    command: try parseExtractorCommand(Array(args.dropFirst())))
            }
        }

        // A leading `--wiki <id>`/`--wiki=<id>` or its `WIKI_DB` env fallback.
        // The explicit-database selector (`--database-path`/`WIKI_DB_PATH`)
        // was REMOVED from wikictl with the fixture-binary split: the raw
        // strings are rejected below, never silently treated as an unknown
        // command. The selector string is typed at the runner boundary by the
        // daemon router (resolveWiki over the socket) — never inside the
        // parser.
        if args.first == "--database-path" || args.first?.hasPrefix("--database-path=") == true {
            throw Failure.usage(
                "--database-path was removed from wikictl — disposable fixture databases "
                    + "are the build-only `wikictl-fixture` binary; pass --wiki <id> to select a live wiki")
        }
        if let envValue = env("WIKI_DB_PATH"), !envValue.isEmpty {
            throw Failure.usage(
                "WIKI_DB_PATH was removed from wikictl — disposable fixture databases "
                    + "are the build-only `wikictl-fixture` binary; pass --wiki <id> (or set WIKI_DB) to select a live wiki")
        }
        var wikiSelector: String?
        if args.first == "--wiki" {
            guard args.count >= 2 else { throw Failure.usage("--wiki requires a value") }
            wikiSelector = args[1]
            args.removeFirst(2)
        } else if let first = args.first, first.hasPrefix("--wiki=") {
            let value = String(first.dropFirst("--wiki=".count))
            guard !value.isEmpty else { throw Failure.usage("--wiki requires a value") }
            wikiSelector = value
            args.removeFirst()
        } else if let envValue = env("WIKI_DB"), !envValue.isEmpty {
            wikiSelector = envValue
        }
        let selectedWikiSelector = wikiSelector ?? ""
        guard !selectedWikiSelector.isEmpty else {
            throw Failure.usage(
                "no wiki selected — pass --wiki <id> (or --wiki=<id>), or set WIKI_DB")
        }

        return Invocation(
            wikiSelector: selectedWikiSelector,
            command: try parseCommand(args))
    }

    /// Parse ONLY the command portion (family + subcommand + options) — no
    /// leading wiki selector. Shared by `wikictl`'s ``parse`` and the
    /// build-only `wikictl-fixture` binary, which owns its own
    /// `--database-path` selector parsing ahead of this call. One command
    /// grammar, two binaries — no duplication.
    public static func parseCommand(_ args: [String]) throws -> Command {
        guard let first = args.first else {
            throw Failure.usage("no command given")
        }
        let command: Command
        switch first {
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
        case "extractor":
            command = try parseExtractorCommand(Array(args.dropFirst()))
        case "job":
            command = try parseJobCommand(Array(args.dropFirst()))
        case "queue":
            command = try parseQueueCommand(Array(args.dropFirst()))
        case "transcribe":
            command = try parseTranscribeCommand(Array(args.dropFirst()))
        case "workspace":
            command = try parseWorkspaceCommand(Array(args.dropFirst()))
        case "strategy":
            command = try parseStrategyCommand(Array(args.dropFirst()))
        default:
            throw Failure.usage("unknown command \((args.first ?? "").debugDescription)")
        }
        return command
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
            let createOnly = options.flag("--create-only")
            let workspace = options.value("--workspace")
            // Expected-state gate (cumulative ingestion, plan phase 4 §4):
            // `--create-only` and `--expect-head` state contradictory
            // preconditions (page must NOT exist vs. page must exist at the
            // given head), so combining them is a usage error, not a
            // resolution order question. `--create-only` also cannot target
            // an explicit id (an id IS an existing-page target) or stage into
            // a workspace (staging resolves absence itself).
            if createOnly, expectHead != nil {
                throw Failure.usage(
                    "page add: --create-only and --expect-head are mutually exclusive — "
                    + "--create-only writes a page that must NOT exist, --expect-head "
                    + "writes a page that must. Pick one."
                )
            }
            if createOnly, id != nil {
                throw Failure.usage(
                    "page add: --create-only cannot be combined with --id — an explicit "
                    + "id targets an existing page; drop --create-only or --id."
                )
            }
            if createOnly, workspace != nil {
                throw Failure.usage(
                    "page add: --create-only cannot be combined with --workspace — "
                    + "workspace staging resolves page absence itself."
                )
            }
            let author = options.value("--author")
            let provenance = try decodePageVersionSources(options.values("--source"))
            return .page(.add(id: id, title: title, body: .file(bodyFile), expectHead: expectHead, createOnly: createOnly, workspace: workspace, author: author, provenance: provenance))

        case "patch":
            // The exact ranged write (REQ-52): `page patch --id <PageID>
            // --expect-head <head> (--hunk <json> --defect <class>)…
            // [--hunk-file <path>]`. Inline pairs and the file are mutually
            // exclusive; inline pairs must strictly alternate.
            let form = try Self.parsePatchForm(commandName: "page patch", options: options)
            return .page(.patch(
                id: form.id, expectHead: form.expectHead,
                hunks: form.hunks, defectClasses: form.defectClasses,
                author: form.author, lintReceipt: form.lintReceipt))

        case "propose-patch":
            // W5a tier 2: the STAGED form of patch — same shape, held for
            // human review instead of written.
            let form = try Self.parsePatchForm(commandName: "page propose-patch", options: options)
            return .page(.proposePatch(
                id: form.id, expectHead: form.expectHead,
                hunks: form.hunks, defectClasses: form.defectClasses,
                author: form.author, lintReceipt: form.lintReceipt))

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

    /// The parsed shared form of `page patch` / `page propose-patch`.
    struct PatchForm {
        let id: PageID
        let expectHead: PageVersionID
        let hunks: [PagePatchHunk]
        let defectClasses: [LintDefectClass]
        let author: String?
        let lintReceipt: String?
    }

    /// The exact ranged form shared by `page patch` and its tier-2 twin
    /// `page propose-patch`: `--id <PageID> --expect-head <head>
    /// (--hunk <json> --defect <class>)… [--hunk-file <path>]`. Inline pairs
    /// and the file are mutually exclusive; inline pairs must strictly
    /// alternate. `commandName` only labels the usage errors.
    static func parsePatchForm(commandName: String, options: Options) throws -> PatchForm {
        guard let id = options.value("--id") else {
            throw Failure.usage("\(commandName): --id is required (stable page identity)")
        }
        guard let expectHeadRaw = options.value("--expect-head"), let expectHead = PageVersionID(rawValue: expectHeadRaw) as PageVersionID? else {
            throw Failure.usage("\(commandName): --expect-head is required — read the head with `page get --json` first (CAS)")
        }
        let inlineHunks = options.values("--hunk")
        let inlineDefects = options.values("--defect")
        let hunkFile = options.value("--hunk-file")
        var pairs: [(hunk: PagePatchHunk, defect: LintDefectClass)]
        if let hunkFile {
            guard inlineHunks.isEmpty, inlineDefects.isEmpty else {
                throw Failure.usage(
                    "\(commandName): --hunk-file cannot be combined with --hunk or --defect — pick one form")
            }
            pairs = try Self.decodeHunkFile(at: hunkFile, commandName: commandName)
        } else {
            // Strict alternation from the observed command-line order:
            // hunk, defect, hunk, defect… Rejects reversed order,
            // consecutive hunks, and unpaired classes positionally.
            let order = options.optionOrder().filter { $0 == "--hunk" || $0 == "--defect" }
            guard order.count == inlineHunks.count + inlineDefects.count, !order.isEmpty else {
                throw Failure.usage(
                    "\(commandName): at least one --hunk <json> --defect <class> pair is required")
            }
            // Positional alternation first (each violation names itself),
            // then the trailing-unpaired check.
            for (index, key) in order.enumerated() {
                let expected = index % 2 == 0 ? "--hunk" : "--defect"
                guard key == expected else {
                    if index == 0 {
                        throw Failure.usage(
                            "\(commandName): a --hunk must come before each --defect (reversed order)")
                    }
                    if index % 2 == 0 {
                        // A complete pair already ended; this is an
                        // extra class after it.
                        throw Failure.usage(
                            "\(commandName): unpaired --defect after position \(index) — every hunk takes exactly one defect class")
                    }
                    throw Failure.usage(
                        "\(commandName): --defect must directly follow its --hunk (consecutive hunks at position \(index + 1))")
                }
            }
            guard order.count % 2 == 0 else {
                throw Failure.usage(
                    "\(commandName): unpaired --hunk/--defect — every hunk needs exactly one defect class")
            }
            guard inlineHunks.count == inlineDefects.count else {
                throw Failure.usage(
                    "\(commandName): \(inlineHunks.count) hunk(s) but \(inlineDefects.count) defect class(es)")
            }
            pairs = try zip(inlineHunks, inlineDefects).map { hunkJSON, defectRaw in
                let hunk = try Self.decodeHunkJSON(hunkJSON, commandName: commandName)
                guard let defect = LintDefectClass(rawValue: defectRaw) else {
                    throw Failure.usage(
                        "\(commandName): unknown defect class \(defectRaw.debugDescription) — expected D01–D28")
                }
                return (hunk, defect)
            }
        }
        return PatchForm(
            id: PageID(rawValue: id), expectHead: expectHead,
            hunks: pairs.map(\.hunk), defectClasses: pairs.map(\.defect),
            author: options.value("--author"),
            lintReceipt: options.value("--lint-receipt"))
    }

    private static func parsePageOKFCommand(_ args: [String]) throws -> PageCommand.Action {        let parsed = try parseOKFCommand(args, version: PageVersionID.init(rawValue:))
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
        // `--source` is the agent-asserted "this ingest completed" switch: it
        // stamps the file Ingested in the UI. It is only meaningful for an
        // ingest, so reject it up front on other kinds instead of silently
        // ignoring a flag the caller believed had an effect. An empty value
        // fails the same way — the caller meant to name a file and did not.
        if let rawSource = options.value("--source"), rawSource.isEmpty {
            throw Failure.usage("log append: --source requires a file id")
        }
        if source != nil, kind != .ingest {
            throw Failure.usage(
                "log append: --source is only valid with --kind ingest — it marks that file Ingested. A \(kind.rawValue) entry names sources in its title/note instead.")
        }
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
            // `--expect-head` is REQUIRED: the CAS token protects a concurrent
            // human/extraction/agent rewrite from being silently clobbered.
            let selector = try options.requireSourceSelector()
            let contentValue = options.value("--content")
            let fileValue = options.value("--file")
            guard let rawHead = options.value("--expect-head"),
                  !rawHead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.usage("""
                source edit-markdown: --expect-head <version-id> is required — \
                read the chain head first (`source info --id <id>` prints \
                head_version_id), then retry with it. On exit 3 (conflict), \
                re-read, reapply once, retry once.
                """)
            }
            let expectedHead = SourceMarkdownVersionID(rawValue: rawHead)
            switch (contentValue, fileValue) {
            case (.some, .some):
                throw Failure.usage("source edit-markdown: pass exactly one of --content / --file, not both")
            case (.none, .none):
                throw Failure.usage("source edit-markdown: pass --content <text> or --file <path>")
            case (let content?, nil):
                return .source(.editMarkdown(selector, content: .inline(content), expectedHead: expectedHead))
            case (nil, let file?):
                return .source(.editMarkdown(selector, content: .file(file), expectedHead: expectedHead))
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

    private static func parseExtractorCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "extractor"))
        }
        guard CLIReference.leaf(family: "extractor", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "extractor", given: sub))
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            // Discovery leaf: no positional, no wiki, no writes — it only
            // reads the machine catalog and describes credentials.
            let options = try Options(rest, options: CLIReference.options(forFamily: "extractor"))
            return .extractor(.list(json: options.flag("--json")))
        case "fetch":
            // Ad-hoc acquisition: one item key now. Same positional package
            // name contract as `sync`; `--item` names the key to acquire
            // (validated against the declaration at execution).
            let packageName = rest.first
            guard let packageName, !packageName.hasPrefix("-") else {
                throw Failure.usage("extractor fetch: name the acquisition package (see 'wikictl help extractor' for the grammar; `wikictl extractor list` shows the installed packages)")
            }
            let options = try Options(Array(rest.dropFirst()), options: CLIReference.options(forFamily: "extractor"))
            guard let itemKey = options.value("--item"), !itemKey.isEmpty else {
                throw Failure.usage("extractor fetch: --item <key> is required — the item key to acquire through the package (`wikictl extractor list` shows each package's key rules)")
            }
            return .extractor(.fetch(
                packageName: packageName,
                itemKey: itemKey,
                force: options.flag("--force")))
        case "sync":
            // The leaf's positional argument: the acquisition package name. It
            // stays a RAW string here — which names are valid is catalog data
            // (the sync declarations the machine has installed), resolved at
            // execution time after wiki selection, never a compiled set. The
            // remainder is flags; `--force` re-enqueues extraction for
            // already-synced acquisition URLs.
            let packageName = rest.first
            guard let packageName, !packageName.hasPrefix("-") else {
                throw Failure.usage("extractor sync: name the acquisition package to sync (see 'wikictl help extractor' for the grammar; syncable packages are the ones the catalog declares)")
            }
            let options = try Options(Array(rest.dropFirst()), options: CLIReference.options(forFamily: "extractor"))
            return .extractor(.sync(packageName: packageName, force: options.flag("--force")))
        default:
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "extractor", given: sub))
        }
    }

    private static func parseJobCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "job"))
        }
        guard CLIReference.leaf(family: "job", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "job", given: sub))
        }
        let options = try Options(
            Array(args.dropFirst()), options: CLIReference.options(forFamily: "job"))
        switch sub {
        case "list":
            return .job(.list(json: options.flag("--json")))
        case "get":
            guard let rawID = options.value("--id") else {
                throw Failure.usage("job get: --id is required")
            }
            return .job(.get(
                id: QueueItemID(rawValue: rawID),
                json: options.flag("--json")))
        default:
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "job", given: sub))
        }
    }

    private static func parseTranscribeCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "transcribe"))
        }
        guard CLIReference.leaf(family: "transcribe", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "transcribe", given: sub))
        }
        guard sub == "on-device" else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "transcribe", given: sub))
        }
        let options = try Options(
            Array(args.dropFirst()), options: CLIReference.options(forFamily: "transcribe"))
        guard let source = options.value("--source") else {
            throw Failure.usage("transcribe on-device: --source is required (the source ID)")
        }
        return .transcribe(.onDevice(
            source: source,
            json: options.flag("--json"),
            wait: options.flag("--no-wait") == false))
    }

    private static func parseQueueCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "queue"))
        }
        guard CLIReference.leaf(family: "queue", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "queue", given: sub))
        }
        let options = try Options(
            Array(args.dropFirst()), options: CLIReference.options(forFamily: "queue"))
        switch sub {
        case "status":
            return .queue(.status(json: options.flag("--json")))
        case "pause", "resume", "halt":
            guard let laneValue = options.value("--lane") else {
                throw Failure.usage("queue \(sub): --lane is required (extraction|ingestion)")
            }
            guard let lane = QueueKind(rawValue: laneValue) else {
                throw Failure.usage("queue \(sub): unknown lane \(laneValue.debugDescription) (use extraction|ingestion)")
            }
            switch sub {
            case "pause":
                return .queue(.pause(lane))
            case "resume":
                return .queue(.resume(lane))
            default:
                return .queue(.halt(lane))
            }
        default:
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "queue", given: sub))
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
            return .workspace(.resolve(id: id, pageID: pageID, body: .file(bodyFile)))

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

    private static func parseStrategyCommand(_ args: [String]) throws -> Command {
        guard let sub = args.first else {
            throw Failure.usage(CLIReference.missingSubcommandMessage(familyName: "strategy"))
        }
        guard CLIReference.leaf(family: "strategy", named: sub) != nil else {
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "strategy", given: sub))
        }
        let options = try Options(Array(args.dropFirst()), options: CLIReference.options(forFamily: "strategy"))

        switch sub {
        case "read":
            return .strategy(.read(json: options.flag("--json")))

        case "save":
            // `--content` is inline; `--file` defers to BodySource resolution
            // (read at execution time, not parse time — the parser stays pure).
            let contentValue = options.value("--content")
            let fileValue = options.value("--file")
            let content: BodySource
            switch (contentValue, fileValue) {
            case (.some, .some):
                throw Failure.usage("strategy save: pass exactly one of --content / --file, not both")
            case (.none, .none):
                throw Failure.usage("strategy save: pass --content <text> or --file <path|->")
            case (let inline?, nil):
                content = .inline(inline)
            case (nil, let file?):
                content = .file(file)
            }
            let expect = try parseStrategyExpectation(options, sub: "save")
            return .strategy(.save(
                name: options.value("--name"),
                content: content,
                expect: expect,
                json: options.flag("--json")))

        case "reset":
            let expect = try parseStrategyExpectation(options, sub: "reset")
            return .strategy(.reset(expect: expect, json: options.flag("--json")))

        default:
            // Unreachable: recognition is the CLIReference leaf table above.
            throw Failure.usage(CLIReference.unknownSubcommandMessage(familyName: "strategy", given: sub))
        }
    }

    /// `--expect-revision` is REQUIRED for save/reset — the CAS token that
    /// keeps a concurrent human/agent edit from being silently clobbered.
    /// `absent` spells the never-written row (the store's `nil` expectation —
    /// true absence, not a reset tombstone, which keeps a real revision); a
    /// positive integer pins the committed revision. `0` is the floor no
    /// committed row stores, so it is rejected with the `absent` spelling
    /// pointed at rather than silently compared.
    private static func parseStrategyExpectation(
        _ options: Options, sub: String
    ) throws -> StrategyCommand.ExpectedRevision {
        guard let raw = options.value("--expect-revision"),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.usage("""
                strategy \(sub): --expect-revision <n|absent> is required — \
                read the committed revision first (`strategy read` prints it), \
                then retry with it. `absent` means no strategy row has ever \
                been written. On exit 3 (conflict), re-read, reapply once, \
                and retry once.
                """)
        }
        if raw == "absent" { return .absent }
        guard let value = Int64(raw), value >= 1 else {
            throw Failure.usage(
                "strategy \(sub): --expect-revision must be a committed revision number (≥ 1) or `absent`, got \(raw.debugDescription)")
        }
        return .revision(WikiStrategyRevision(rawValue: value))
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
        private var observedOptionOrder: [String] = []

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
                observedOptionOrder.append(token)
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
        /// The option keys in the order they appeared on the command line —
        /// `page patch`'s `--hunk <json> --defect <class>` pairs are
        /// POSITIONAL (one class per hunk, alternating), so their sequence
        /// carries meaning the grouped maps lose.
        func optionOrder() -> [String] { observedOptionOrder }

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
    ///   For `log append` (which takes no `--author` flag) the env value rides
    ///   along as the row's author identity so `LogIndexCommand` can refuse an
    ///   agent-authored `--source` Ingested stamp (#1367); the stamp gate keys
    ///   on the typed `PageAuthor` parse of this value.
    public static func applyEnv(
        _ command: Command, env: [String: String]
    ) -> Command {
        let workspaceID = env["WIKI_WORKSPACE"]
        let author = env["WIKI_AUTHOR"]
        switch command {
        case .page(.get(let selector, let json, let workspace))
            where workspace == nil && workspaceID?.isEmpty == false:
            return .page(.get(selector, json: json, workspace: workspaceID))
        case .page(.add(let id, let title, let bodySource, let expectHead, let createOnly, let workspace, let existingAuthor, let provenance))
            where workspace == nil && workspaceID?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, createOnly: createOnly, workspace: workspaceID,
                             author: existingAuthor ?? author, provenance: provenance))
        case .page(.add(let id, let title, let bodySource, let expectHead, let createOnly, let workspace, let existingAuthor, let provenance))
            where existingAuthor == nil && author?.isEmpty == false:
            return .page(.add(id: id, title: title, body: bodySource,
                             expectHead: expectHead, createOnly: createOnly, workspace: workspace,
                             author: author, provenance: provenance))
        case .indexSet(let bodyFile, let workspace)
            where workspace == nil && workspaceID?.isEmpty == false:
            return .indexSet(bodyFile: bodyFile, workspace: workspaceID)
        case .logAppend(let kind, let title, let note, let source, let existingAuthor)
            where existingAuthor == nil && author?.isEmpty == false:
            // #1367: route the resolved run author onto `log append` so the
            // stamp gate in `LogIndexCommand` can tell an agent-authored run
            // (`agent:<kind>`) from the ad-hoc chat/shell path. `log append`
            // takes no `--author` flag, so the env is the only source; the
            // guard keeps the precedence shape (flag > env) if one is added.
            return .logAppend(kind: kind, title: title, note: note, source: source, author: author)
        default:
            return command
        }
    }

    /// Decode one inline `--hunk <json>` argument at the boundary: one JSON
    /// object with the half-open byte bounds, exact expected text,
    /// replacement, and validity reason.
    private static func decodeHunkJSON(_ json: String, commandName: String = "page patch") throws -> PagePatchHunk {
        guard let data = json.data(using: .utf8) else {
            throw Failure.usage("\(commandName): --hunk is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(PagePatchHunk.self, from: data)
        } catch {
            throw Failure.usage(
                "\(commandName): --hunk must be one JSON object "
                + #"{"startByte":Int,"endByte":Int,"oldText":String,"newText":String,"reason":String} — decode failed: \#(error.localizedDescription)"#)
        }
    }

    /// Decode the `--hunk-file` document: `{"version":1,"hunks":[{"defect":
    /// "Dxx","startByte":…,…}]}` — the same hunk fields with per-hunk classes.
    private static func decodeHunkFile(
        at path: String, commandName: String = "page patch"
    ) throws -> [(hunk: PagePatchHunk, defect: LintDefectClass)] {
        guard let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else {
            throw Failure.usage("\(commandName): --hunk-file is unreadable or empty: \(path)")
        }
        do {
            let document = try JSONDecoder().decode(PagePatchHunkFile.self, from: data)
            guard document.version == PagePatchHunkFile.version else {
                throw Failure.usage(
                    "\(commandName): --hunk-file version \(document.version) unsupported (expected \(PagePatchHunkFile.version))")
            }
            return try document.hunks.map { entry in
                guard let defect = LintDefectClass(rawValue: entry.defect) else {
                    throw Failure.usage(
                        "\(commandName): unknown defect class \(entry.defect.debugDescription) in --hunk-file — expected D01–D28")
                }
                return (
                    PagePatchHunk(
                        startByte: entry.startByte, endByte: entry.endByte,
                        oldText: entry.oldText, newText: entry.newText, reason: entry.reason),
                    defect
                )
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.usage(
                "\(commandName): --hunk-file must be {\"version\":1,\"hunks\":[…]} — decode failed: \(error.localizedDescription)")
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
