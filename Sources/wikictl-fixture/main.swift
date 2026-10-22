import Foundation
import WikiCtlCore
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

// `wikictl-fixture` — the BUILD-ONLY companion CLI for disposable fixture
// databases (plans/cli-domain-commands.md §"The fixture binary"). It is a
// developer/CI tool: it runs WikiCtlCore's ordinary command layer against ONE
// explicit `--database-path <file>` database opened in-process through
// ``CLIStoreProfile``. It is never bundled into the app (build.sh stages only
// `wikictl` into Contents/Helpers) and is never a production pathway.
//
// The shipping `wikictl` has NO local database pathway at all: it rejects
// `--database-path`/`WIKI_DB_PATH` and routes every command through the wikid
// daemon. This binary owns the opposite surface: it REQUIRES the explicit
// database selector, rejects `--wiki`/`WIKI_DB` (live wikis are the daemon's
// registry world), and refuses the daemon-backed families (queue, transcribe,
// job, wiki lifecycle, live chat, extractor list) that only make sense against
// a running app.
//
// Exit codes: 0 success, 2 usage error, 1 runtime error, 3 CAS conflict — the
// same convention as `wikictl`.

let fixtureUsageText = """
wikictl-fixture — run wikictl commands against a disposable fixture database (developer/CI tool, never bundled with the app)

USAGE:
  wikictl-fixture --database-path <file> <command> [arguments...]
  wikictl-fixture --database-path=<file> <command> [arguments...]
  WIKI_DB_PATH=<file> wikictl-fixture <command> [arguments...]

The database must be an ABSOLUTE path to a .sqlite file OUTSIDE the App Group
container. The selector goes BEFORE the subcommand.

Commands come from the wikictl command layer (page, source, log, index, chat,
bookmark, workspace, strategy, admin, extractor sync/fetch). Daemon-backed
families (queue, transcribe, job, wiki lifecycle, live chat, extractor list)
are rejected here — run `wikictl` with the app running for those. Command
help: `wikictl-fixture --help` prints this text; per-command surfaces match
`wikictl <command> --help`.

Exit codes: 0 success, 2 usage error, 1 runtime error, 3 CAS conflict.
"""

func run() async -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())

    // Fixture help is its own surface: it documents the explicit-database
    // selector the shipping wikictl no longer accepts.
    if arguments.first == "--help" || arguments.first == "-h" {
        print(fixtureUsageText)
        return 0
    }

    // The explicit-database selector is REQUIRED and must lead the arguments.
    // `--wiki`/`WIKI_DB` are refused inside the parser — live wikis are
    // wikictl's daemon-routed surface, and a fixture run must never touch the
    // registry.
    let invocation: FixtureInvocation
    do {
        invocation = try FixtureArgumentParser.parse(arguments) {
            ProcessInfo.processInfo.environment[$0]
        }
    } catch let failure as ArgumentParser.Failure {
        FileHandle.standardError.write(
            Data("wikictl-fixture: \(failure)\nRun `wikictl-fixture --help` for usage.\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error)\n".utf8))
        return 2
    }

    let command: ArgumentParser.Command
    do {
        // Reuse WikiCtlCore's command layer verbatim — the fixture binary adds
        // only its own selector, never its own command grammar.
        command = try ArgumentParser.parseCommand(invocation.arguments)
    } catch let failure as ArgumentParser.Failure {
        FileHandle.standardError.write(
            Data("wikictl-fixture: \(failure)\nRun `wikictl-fixture --help` for usage.\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error)\n".utf8))
        return 2
    }

    // Daemon-backed families have no meaning against a fixture database: they
    // resolve wikis through the running app's daemon, which this binary never
    // contacts.
    switch command {
    case .queue, .transcribe, .job, .wikiList, .wikiCreate, .wikiDelete, .wikiRename,
         .daemonChatNew, .daemonChatSend, .daemonChatStop, .extractor(.list):
        return fixtureUsageError(
            "\(familyName(for: command)) is daemon-backed — run `wikictl` with the app running; wikictl-fixture executes only local commands against the fixture database")
    case .help, .version, .dumpConfig:
        return fixtureUsageError(
            "wikictl-fixture has no help/version/dump-config subcommands — see `wikictl-fixture --help`")
    default:
        break
    }

    // Validate the selection at this typed boundary (absolute, .sqlite,
    // outside the App Group container) and resolve it — the machinery that
    // moved out of WikiCtlCore with the fixture split.
    let databaseURL: URL
    do {
        databaseURL = try FixtureWikiResolver.validatedDatabasePath(invocation.databasePath)
    } catch let error as FixtureSelectionError {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error.localizedDescription)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error)\n".utf8))
        return 2
    }
    let target: ResolvedWikiTarget
    do {
        target = try FixtureWikiResolver().resolve(databaseURL: databaseURL)
    } catch {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error)\n".utf8))
        return 2
    }

    do {
        let resolvedCommand = ArgumentParser.applyEnv(
            command, env: ProcessInfo.processInfo.environment)
        let result = try await CLIStoreProfile.withStore(
            databaseURL: target.databaseURL,
            wikiID: target.wikiID,
            containerDirectory: target.containerDirectory
        ) { store in
            try await execute(
                resolvedCommand,
                in: store,
                wikiID: target.wikiID,
                containerDirectory: target.containerDirectory)
        }
        write(result, wikiID: target.wikiID)
        return 0
    } catch let failure as PageCommand.Failure {
        FileHandle.standardError.write(Data("wikictl-fixture: \(failure)\n".utf8))
        return 1
    } catch let conflict as PageConflictError {
        // CAS conflict — the page was edited after the caller read it. Exit 3
        // signals the agent to re-read, reapply, and retry once.
        let actual = conflict.actualVersionID?.rawValue ?? "(none)"
        let message = """
        wikictl-fixture: CAS conflict on page \(conflict.pageID.rawValue) — \
        expected head \(conflict.expectedVersionID), \
        but actual head is \(actual). \
        Re-read the page, reapply your edit, and retry once.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as PageCreateConflictError {
        let actual = conflict.actualVersionID?.rawValue ?? "(none)"
        let message = """
        wikictl-fixture: create-only conflict on page \(conflict.pageID.rawValue) — \
        --create-only requires the title to be absent, \
        but a page now exists under \(conflict.title) (head \(actual)). \
        Read that page, reconcile against its head, and write with --expect-head. \
        Nothing was written.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as PageExpectedTargetMissingError {
        let target = conflict.pageID?.rawValue ?? "title \(conflict.title)"
        let message = """
        wikictl-fixture: expected-head conflict — the page you pinned (\(target)) \
        does not exist anymore (deleted or renamed since your read). \
        Re-read (`page list` / `page get`), reconcile, and write again. \
        Nothing was written.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as SourceMarkdownConflictError {
        let actual = conflict.currentHead?.rawValue ?? "(none)"
        let message = """
        wikictl-fixture: CAS conflict on source \(conflict.sourceID.rawValue) — \
        expected head \(conflict.expectedHead.rawValue), \
        but actual head is \(actual). \
        Re-read the processed markdown (`source cat --markdown`), re-read \
        head_version_id (`source info`), reapply your edit, and retry once. \
        Nothing was written. If it conflicts again, report the conflict \
        instead of retrying.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as WikiStrategyConflictError {
        let expected = conflict.expectedRevision.map { "revision \($0.rawValue)" }
            ?? "absent (no strategy row ever written)"
        let current = conflict.currentRevision.map { "revision \($0.rawValue)" }
            ?? "absent (no strategy row has ever been written)"
        let message = """
        wikictl-fixture: CAS conflict on strategy — \
        expected \(expected), \
        but the committed revision is \(current). \
        Re-read (`strategy read`), reapply your edit, and retry once with the \
        new revision. Nothing was written.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let failure as SourceCommand.Failure {
        FileHandle.standardError.write(Data("wikictl-fixture: \(failure)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("wikictl-fixture: \(error)\n".utf8))
        return 1
    }
}

func fixtureUsageError(_ message: String) -> Int32 {
    FileHandle.standardError.write(
        Data("wikictl-fixture: \(message)\nRun `wikictl-fixture --help` for usage.\n".utf8))
    return 2
}

/// The human family label for a daemon-backed command rejected by the fixture
/// binary's guard above.
private func familyName(for command: ArgumentParser.Command) -> String {
    switch command {
    case .queue: "queue"
    case .transcribe: "transcribe"
    case .job: "job"
    case .wikiList, .wikiCreate, .wikiDelete, .wikiRename: "wiki"
    case .daemonChatNew, .daemonChatSend, .daemonChatStop: "live chat"
    case .extractor(.list): "extractor list"
    default: "this command"
    }
}

/// Execute a parsed `Command` against the fixture store — the SAME local
/// executor `wikictl`'s explicit-database branch ran before the fixture split
/// (moved here verbatim, plans/cli-domain-commands.md §"The fixture binary").
/// The deferred body read (`-` = stdin, else a file path) happens inside the
/// action's `run` via `resolveBodySource` — the only I/O the parser left for
/// execution time.
///
/// `wikiID` routes the three search cases to the daemon's index via
/// `CLITantivyLegResolver` — on a fixture run the daemon usually answers no
/// hits (the fixture wiki is not in its registry), which means NO BM25 leg,
/// never an error. `containerDirectory` feeds the fence validator and the
/// extractor commands.
func execute(
    _ command: ArgumentParser.Command,
    in store: GRDBWikiStore,
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    switch command {
    case .page(let action):
        let leg = try await cliPageLegIfSearch(
            action,
            wikiID: wikiID,
            store: store)
        // The package-driven fence validator resolves from the machine
        // renderer package store. An unresolvable layout skips validation
        // (nil semantics) rather than failing the command.
        let fenceValidator = DebugLog.trying("resolve fence validation service", operation: {
            try FenceSyntaxValidationService(
                layout: RendererPackageStoreLayout(appGroupContainerRoot: containerDirectory))
        })
        let r = try PageCommand.run(action, in: store, validator: fenceValidator, bm25Leg: leg)
        return SourceCommand.Result(
            payload: .text(r.output),
            didCommit: r.didCommit,
            stderrOutput: r.stderrOutput
        )
    case .logAppend(let kind, let title, let note, let source, let author):
        // The author arrived resolved (flag > env) via `applyEnv`. Parse it
        // through the typed `PageAuthor` seam HERE — the single boundary
        // between parse-land strings and command-land types.
        let r = try LogIndexCommand.run(
            .logAppend(kind: kind, title: title, note: note, source: source,
                       author: PageAuthor(rawValue: author)),
            in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .indexSet(let bodyFile, let workspace):
        let body = try readBodyFile(from: bodyFile)
        let r = try LogIndexCommand.run(.indexSet(body: body, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .transcribe:
        // Rejected before execution by the daemon-family guard in `run()`.
        throw ArgumentParser.Failure.usage("transcribe requires no wiki store context")
    case .source(let action):
        if case .addURL(let rawInput, let allowDuplicateURL) = action {
            return try await SourceCommand.runAddURL(
                rawInput, allowDuplicateURL: allowDuplicateURL,
                in: store, fetcher: URLSessionFetcher())
        }
        if case .refresh(let selector) = action {
            return try await SourceCommand.runRefresh(
                selector,
                in: store,
                fetcher: URLSessionFetcher())
        }
        return try SourceCommand.run(
            action, in: store,
            cwd: FileManager.default.currentDirectoryPath,
            bm25Leg: try await cliSourceLegIfSearch(
                action,
                wikiID: wikiID,
                store: store))
    case .admin(let action):
        return try AdminCommand.run(action, in: store)
    case .extractor(.sync(let packageName, let force)):
        return try await runExtractorSync(
            packageName: packageName, force: force, in: store,
            wikiID: wikiID, containerDirectory: containerDirectory)
    case .extractor(.fetch(let packageName, let itemKey, let force)):
        return try await runExtractorFetch(
            packageName: packageName, itemKey: itemKey, force: force, in: store,
            wikiID: wikiID, containerDirectory: containerDirectory)
    case .extractor(.list):
        // Rejected before execution by the daemon-family guard in `run()`.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .job, .queue:
        // Rejected before execution by the daemon-family guard in `run()`.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .chat(let action):
        return try await runChatCommand(
            action,
            in: store,
            wikiID: wikiID)
    case .bookmark(let action):
        let r = try BookmarkCommand.run(action, in: store)
        return SourceCommand.Result(
            payload: .text(r.output), didCommit: r.didCommit,
            stderrOutput: r.stderrOutput)
    case .workspace(let action):
        let r = try WorkspaceCommand.run(action, in: store)
        return SourceCommand.Result(
            payload: .text(r.output), didCommit: r.didCommit,
            stderrOutput: r.stderrOutput)
    case .strategy(let action):
        let r = try StrategyCommand.run(action, in: store)
        return SourceCommand.Result(
            payload: .text(r.output),
            didCommit: r.didCommit,
            stderrOutput: r.stderrOutput)
    case .help, .version, .dumpConfig:
        // Rejected before execution by the guard in `run()`.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .wikiList, .wikiCreate, .wikiDelete, .wikiRename:
        // Rejected before execution by the guard in `run()`.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .daemonChatNew, .daemonChatSend, .daemonChatStop:
        // Rejected before execution by the guard in `run()`.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    }
}

/// Resolve a Tantivy BM25 leg for `chat search` before invoking
/// `ChatCommand.run(..., bm25Leg:)`. Mirrors the page/source helpers below.
private func runChatCommand(
    _ action: ChatCommand.Action,
    in store: GRDBWikiStore,
    wikiID: WikiID
) async throws -> SourceCommand.Result {
    let leg: [ChatSummary]?
    if case .search(let query, let limit) = action {
        leg = try await CLITantivyLegResolver.resolveChatLeg(
            wikiID: wikiID, store: store, query: query, limit: limit)
    } else {
        leg = nil
    }
    let r = try ChatCommand.run(action, in: store, bm25Leg: leg)
    return SourceCommand.Result(
        payload: .text(r.output), didCommit: r.didCommit,
        stderrOutput: r.stderrOutput)
}

/// Inspect a `SourceCommand.Action` and, when it's `.search`, resolve a Tantivy
/// BM25 leg to thread into `SourceCommand.run(..., bm25Leg:)`. Returns `nil`
/// for every other action.
private func cliSourceLegIfSearch(
    _ action: SourceCommand.Action,
    wikiID: WikiID,
    store: GRDBWikiStore
) async throws -> [SourceSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return try await CLITantivyLegResolver.resolveSourceLeg(
        wikiID: wikiID, store: store, query: query, limit: limit)
}

/// Inspect a `PageCommand.Action` and, when it's `.search`, resolve a Tantivy
/// BM25 leg to thread into `PageCommand.run(..., bm25Leg:)`. Returns `nil`
/// for every other action.
private func cliPageLegIfSearch(
    _ action: PageCommand.Action,
    wikiID: WikiID,
    store: GRDBWikiStore
) async throws -> [WikiPageSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return try await CLITantivyLegResolver.resolvePageLeg(
        wikiID: wikiID, store: store, query: query, limit: limit)
}

private func write(_ result: SourceCommand.Result, wikiID: WikiID) {
    switch result.payload {
    case .text(let text):
        if !text.isEmpty {
            FileHandle.standardOutput.write(Data("\(text)\n".utf8))
        }
    case .bytes(let bytes):
        if !bytes.isEmpty {
            FileHandle.standardOutput.write(bytes)
        }
    }
    if let stderrText = result.stderrOutput, !stderrText.isEmpty {
        FileHandle.standardError.write(Data(stderrText.utf8))
    }
    if result.didCommit {
        DarwinNotifier.postChange()
    }
}

// `run()` is async — boot a top-level task and wait for it.
exit(await run())
