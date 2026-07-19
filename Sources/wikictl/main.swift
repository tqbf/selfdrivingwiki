import Foundation
import WikiCtlCore
import WikiFSCore

/// `wikictl` — the agent's write path into a wiki (`plans/llm-wiki.md` Phase A).
///
/// Reads happen via the read-only File Provider mount; WRITES go through this CLI
/// straight to the wiki's `<ulid>.sqlite` in the App Group container. It opens the
/// DB READ-WRITE via the literal App Group path the un-sandboxed app uses (WAL +
/// `busy_timeout=5000` make a second writer process safe), runs one `page`
/// command, prints its output to stdout, and — after any committing call — posts
/// a per-wiki Darwin notification so the app refreshes. It NEVER signals the File
/// Provider itself (single-owner invariant) and NEVER writes the mount.
///
/// Exit codes: 0 success, 2 usage error, 1 runtime error, 3 CAS conflict.
func run() async -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())

    let invocation: ArgumentParser.Invocation
    do {
        invocation = try ArgumentParser.parse(arguments) { ProcessInfo.processInfo.environment[$0] }
    } catch let failure as ArgumentParser.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n\n\(ArgumentParser.usageText)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 2
    }

    // `version` doesn't need a wiki — print and exit before wiki resolution.
    if case .version(let json) = invocation.command {
        if json {
            print("""
            {"appVersion":"\(GeneratedVersion.appVersion)","gitSHA":"\(GeneratedVersion.gitSHA)","commitCount":\(GeneratedVersion.gitCommitCount),"buildVersion":"\(GeneratedVersion.buildVersion)","fullVersion":"\(GeneratedVersion.fullVersionString)"}
            """)
        } else {
            print("wikictl \(GeneratedVersion.fullVersionString)")
            print("  appVersion:  \(GeneratedVersion.appVersion)")
            print("  git SHA:     \(GeneratedVersion.gitSHA)")
            print("  commit:      \(GeneratedVersion.gitCommitCount)")
            print("  build:       \(GeneratedVersion.buildVersion)")
        }
        return 0
    }

    // `wiki` subcommands — registry operations via the wikid daemon.
    // These don't open a store or need a wiki selector.
    if case .wikiList = invocation.command {
        return await runWikiList()
    }
    if case .wikiCreate(let name) = invocation.command {
        return await runWikiCreate(name: name)
    }
    if case .wikiDelete(let id) = invocation.command {
        return await runWikiDelete(id: id)
    }
    if case .wikiRename(let id, let name) = invocation.command {
        return await runWikiRename(id: id, name: name)
    }

    // Phase 7: WIKI_WORKSPACE env var. When set by an isolated ingest run,
    // it auto-applies --workspace to page get/upsert and index set commands
    // that don't already pass --workspace explicitly. This lets the agent
    // subprocess use plain `wikictl` commands without knowing the workspace ID.
    let command = ArgumentParser.applyEnv(invocation.command, env: ProcessInfo.processInfo.environment)

    do {
        // Try the daemon first for wiki resolution. If the daemon isn't running,
        // fall back to direct file access (the existing WikiResolver path).
        // This makes wikictl the first real XPC client of wikid (Phase 1C).
        let descriptor: WikiDescriptor?
        let resolver = try WikiResolver.appGroupContainer()
        if let daemon = try? WikiDaemonConnection.connect(),
           let daemonDesc = try? await daemon.resolveWiki(selector: invocation.wikiSelector) {
            descriptor = daemonDesc
        } else {
            descriptor = resolver.descriptor(forSelector: invocation.wikiSelector)
        }
        guard let descriptor else {
            throw PageCommand.Failure.message(
                "no wiki matching \(invocation.wikiSelector.debugDescription) in the registry")
        }
        let store = try GRDBWikiStore(databaseURL: resolver.databaseURL(for: descriptor))

        let result = try execute(
            command,
            in: store,
            wikiID: descriptor.id,
            containerDirectory: resolver.containerDirectory)

        switch result.payload {
        case .text(let output):
            if !output.isEmpty { print(output) }
        case .bytes(let data):
            FileHandle.standardOutput.write(data)
        }
        // Post the change notification ONLY after a committing write, so a read
        // never wakes the app's change bridge.
        if result.didCommit {
            DarwinNotifier.postChange(forWikiID: descriptor.id)
        }
        return 0
    } catch let failure as PageCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch let conflict as PageConflictError {
        // Phase 1: CAS conflict — the page was edited after the caller read it.
        // Exit code 3 signals the agent to re-read, reapply, and retry once.
        let actual = conflict.actualVersionID ?? "(none)"
        let message = """
        wikictl: CAS conflict on page \(conflict.pageID.rawValue) — \
        expected head \(conflict.expectedVersionID), \
        but actual head is \(actual). \
        Re-read the page, reapply your edit, and retry once.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let failure as SourceCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

/// Execute a parsed `Command`, dispatching to `PageCommand` (the `page …`
/// family), `LogIndexCommand` (the Phase-B `log append` / `index set`), or
/// `SourceCommand` (the `source …` family for raw source reads). The deferred
/// body read (`-` = stdin, else a file path) happens inside the action's `run`
/// via `resolveBodySource` — the only I/O the parser left for execution time.
///
/// `wikiID` + `containerDirectory` thread the on-disk Tantivy index path
/// (`<container>/search-index/<wikiID>/`) to the three search cases so they
/// can resolve a Tantivy BM25 leg via `CLITantivyLegResolver` before invoking
/// the kind-specific `*Command.run(..., bm25Leg:)` (#637). Non-search cases
/// ignore them.
func execute(
    _ command: ArgumentParser.Command,
    in store: GRDBWikiStore,
    wikiID: String,
    containerDirectory: URL
) throws -> SourceCommand.Result {
    switch command {
    case .page(let action):
        let leg: [WikiPageSummary]? = cliPageLegIfSearch(action, wikiID: wikiID, containerDirectory: containerDirectory, store: store)
        let r = try PageCommand.run(action, in: store, bm25Leg: leg)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .logAppend(let kind, let title, let note, let source):
        let r = try LogIndexCommand.run(.logAppend(kind: kind, title: title, note: note, source: source), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .indexSet(let bodyFile, let workspace):
        let body = try readBodyFile(from: bodyFile)
        let r = try LogIndexCommand.run(.indexSet(body: body, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .source(let action):
        if case .refresh(let selector) = action {
            // `runRefresh` is async (network I/O). Bridge it to the sync
            // `execute` context via a semaphore — the standard CLI async→sync
            // pattern. Safe because `DispatchSemaphore.wait()` blocks only the
            // main thread; the async task signals from its own continuation
            // thread, which never needs to acquire the main thread to signal
            // (signaling is thread-agnostic). WebsiteMaterializer does not hop
            // to the main actor, so no deadlock.
            let box = RefreshResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    box.result = try await SourceCommand.runRefresh(
                        selector, in: store, fetcher: URLSessionFetcher())
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
            semaphore.wait()
            if let error = box.error { throw error }
            return box.result ?? SourceCommand.Result(payload: .text(""), didCommit: false)
        }
        return try SourceCommand.run(
            action, in: store,
            cwd: FileManager.default.currentDirectoryPath,
            bm25Leg: cliSourceLegIfSearch(action, wikiID: wikiID, containerDirectory: containerDirectory, store: store))
    case .admin(let action):
        return try AdminCommand.run(action, in: store)
    case .chat(let action):
        return try runChatCommand(action, in: store, wikiID: wikiID, containerDirectory: containerDirectory)
    case .bookmark(let action):
        let r = try BookmarkCommand.run(action, in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .workspace(let action):
        let r = try WorkspaceCommand.run(action, in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .version:
        // Handled before wiki resolution in `run()` — unreachable here.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .wikiList, .wikiCreate, .wikiDelete, .wikiRename:
        // Handled before wiki resolution in `run()` — unreachable here.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    }
}

/// #637: split-out dispatch for the `wikictl chat …` subcommands. Resolves
/// a Tantivy BM25 leg for `.search` before invoking `ChatCommand.run(...,
/// bm25Leg:)`. Mirrors the `page search` / `source search` paths in
/// `execute(...)` — kept as a helper so that function's switch stays compact.
private func runChatCommand(
    _ action: ChatCommand.Action,
    in store: GRDBWikiStore,
    wikiID: String,
    containerDirectory: URL
) throws -> SourceCommand.Result {
    let leg: [ChatSummary]?
    if case .search(let query, let limit) = action {
        leg = CLITantivyLegResolver.resolveChatLeg(
            wikiID: wikiID, containerDirectory: containerDirectory,
            store: store, query: query, limit: limit)
    } else {
        leg = nil
    }
    let r = try ChatCommand.run(action, in: store, bm25Leg: leg)
    return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
}

/// #637: inspect a `SourceCommand.Action` and, when it's `.search`, resolve a
/// Tantivy BM25 leg to thread into `SourceCommand.run(..., bm25Leg:)`. Returns
/// `nil` for every other action (the param is unused by them). Kept as a
/// helper so the switch in `execute(...)` reads cleanly.
private func cliSourceLegIfSearch(
    _ action: SourceCommand.Action,
    wikiID: String,
    containerDirectory: URL,
    store: GRDBWikiStore
) -> [SourceSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return CLITantivyLegResolver.resolveSourceLeg(
        wikiID: wikiID, containerDirectory: containerDirectory,
        store: store, query: query, limit: limit)
}

/// #637: inspect a `PageCommand.Action` and, when it's `.search`, resolve a
/// Tantivy BM25 leg to thread into `PageCommand.run(..., bm25Leg:)`. Returns
/// `nil` for every other action. Mirrors `cliSourceLegIfSearch` so the
/// `page search` / `source search` paths share the same resolve step.
private func cliPageLegIfSearch(
    _ action: PageCommand.Action,
    wikiID: String,
    containerDirectory: URL,
    store: GRDBWikiStore
) -> [WikiPageSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return CLITantivyLegResolver.resolvePageLeg(
        wikiID: wikiID, containerDirectory: containerDirectory,
        store: store, query: query, limit: limit)
}

/// Thread-safe box for the wikictl async→sync semaphore bridge (Phase 3b).
/// `@unchecked Sendable` — the semaphore guarantees the write (in the async
/// task) happens-before the read (after `semaphore.wait()` returns), so the
/// lock is belt-and-suspenders for Swift 6's data-race checker.
final class RefreshResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: SourceCommand.Result?
    private var _error: Error?

    var result: SourceCommand.Result? {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); defer { lock.unlock() }; _result = newValue }
    }
    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); defer { lock.unlock() }; _error = newValue }
    }
}

/// Read an upsert body: `-` reads stdin to EOF; anything else is a file path.
/// Now a thin shim to `readBodyFile` in WikiCtlCore so the body-read contract
/// lives next to `BodySource`/`resolveBodySource`. Kept as a `wikictl`-local
/// helper so existing callers in this file (e.g. `LogIndexCommand` indexSet)
/// read cleanly.
func readBody(from source: String) throws -> String {
    try readBodyFile(from: source)
}

// MARK: - wiki subcommands (via wikid daemon XPC)

func runWikiList() async -> Int32 {
    do {
        let daemon = try WikiDaemonConnection.connect()
        let wikis = try await daemon.listWikis()
        for wiki in wikis {
            print("\(wiki.id)\t\(wiki.displayName)")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

func runWikiCreate(name: String) async -> Int32 {
    do {
        let daemon = try WikiDaemonConnection.connect()
        let descriptor = try await daemon.createWiki(name: name)
        print("\(descriptor.id)\t\(descriptor.displayName)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

func runWikiDelete(id: String) async -> Int32 {
    do {
        let daemon = try WikiDaemonConnection.connect()
        let success = try await daemon.deleteWiki(id: id)
        if !success {
            FileHandle.standardError.write(Data("wikictl: wiki delete failed for \(id)\n".utf8))
            return 1
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

func runWikiRename(id: String, name: String) async -> Int32 {
    do {
        let daemon = try WikiDaemonConnection.connect()
        let success = try await daemon.renameWiki(id: id, name: name)
        if !success {
            FileHandle.standardError.write(Data("wikictl: wiki rename failed for \(id)\n".utf8))
            return 1
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

// `run()` is async — boot a top-level task and wait for it.
exit(await run())
