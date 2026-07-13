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
    let command = applyWorkspaceEnv(invocation.command, env: ProcessInfo.processInfo.environment)

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
        let store = try SQLiteWikiStore(databaseURL: resolver.databaseURL(for: descriptor))

        let result = try execute(command, in: store)

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

/// Phase 7: Apply the `WIKI_WORKSPACE` environment variable to commands that
/// support `--workspace` but don't already have one set. This lets the agent
/// subprocess use plain `wikictl page get/upsert` / `index set` commands and
/// have them automatically routed to the ingest's workspace — the runner sets
/// the env var before launching the agent process.
func applyWorkspaceEnv(_ command: ArgumentParser.Command, env: [String: String]) -> ArgumentParser.Command {
    guard let workspaceID = env["WIKI_WORKSPACE"], !workspaceID.isEmpty else {
        return command
    }
    switch command {
    case .get(let selector, let json, let workspace) where workspace == nil:
        return .get(selector, json: json, workspace: workspaceID)
    case .upsert(let id, let title, let bodyFile, let expectHead, let workspace) where workspace == nil:
        return .upsert(id: id, title: title, bodyFile: bodyFile, expectHead: expectHead, workspace: workspaceID)
    case .indexSet(let bodyFile, let workspace) where workspace == nil:
        return .indexSet(bodyFile: bodyFile, workspace: workspaceID)
    default:
        return command
    }
}

/// Execute a parsed `Command`, dispatching to `PageCommand` (the `page …` family),
/// `LogIndexCommand` (the Phase-B `log append` / `index set`), or `SourceCommand`
/// (the `source …` family for raw source reads). The deferred body read (`-` = stdin,
/// else a file path) happens here — the only I/O the parser left for `main`.
func execute(_ command: ArgumentParser.Command, in store: SQLiteWikiStore) throws -> SourceCommand.Result {
    switch command {
    case .list(let json):
        let r = try PageCommand.run(.list(json: json), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .get(let selector, let json, let workspace):
        let r = try PageCommand.run(.get(selector, json: json, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .delete(let id):
        let r = try PageCommand.run(.delete(id: id), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .upsert(let id, let title, let bodyFile, let expectHead, let workspace):
        let body = try readBody(from: bodyFile)
        let r = try PageCommand.run(.upsert(id: id, title: title, body: body, expectHead: expectHead, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .logAppend(let kind, let title, let note, let source):
        let r = try LogIndexCommand.run(.logAppend(kind: kind, title: title, note: note, source: source), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .indexSet(let bodyFile, let workspace):
        let body = try readBody(from: bodyFile)
        let r = try LogIndexCommand.run(.indexSet(body: body, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .search(let query, let limit):
        let r = try PageCommand.run(.search(query: query, limit: limit), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .pageHistory(let selector):
        let r = try PageCommand.run(.history(selector), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .pageRevert(let selector, let versionID):
        let r = try PageCommand.run(.revert(selector, versionID: versionID), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .source(let action):
        return try SourceCommand.run(action, in: store,
                                   cwd: FileManager.default.currentDirectoryPath)
    case .sourceEditMarkdown(let selector, let contentOrFile, let isFile):
        let content: String
        if isFile {
            content = try readBody(from: contentOrFile)
        } else {
            content = contentOrFile
        }
        return try SourceCommand.run(
            .editMarkdown(selector, content: content), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    case .sourceRename(let selector, let to):
        return try SourceCommand.run(
            .rename(selector, to: to), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    case .sourceSetActive(let selector, let versionID):
        return try SourceCommand.run(
            .setActive(selector, versionID: versionID), in: store,
            cwd: FileManager.default.currentDirectoryPath)
    case .sourceRefresh(let selector):
        // `runRefresh` is async (network I/O). Bridge it to the sync `execute`
        // context via a semaphore — the standard CLI async→sync pattern. Safe
        // because `DispatchSemaphore.wait()` blocks only the main thread; the
        // async task signals from its own continuation thread, which never needs
        // to acquire the main thread to signal (signaling is thread-agnostic).
        // WebsiteMaterializer does not hop to the main actor, so no deadlock.
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
    case .admin(let action):
        return try AdminCommand.run(action, in: store)
    case .chat(let action):
        let r = try ChatCommand.run(action, in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
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
func readBody(from source: String) throws -> String {
    if source == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
    return try String(contentsOfFile: source, encoding: .utf8)
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
