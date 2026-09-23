import Foundation
import WikiCtlCore
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

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
        // Scoped help exists (#1224), so the error path points at the nearest
        // help surface instead of dumping the full usage on every typo.
        FileHandle.standardError.write(
            Data("wikictl: \(failure)\nRun `wikictl --help` (or `wikictl <command> --help`) for usage.\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 2
    }

    // Help and version don't need a wiki — print and exit before wiki resolution.
    // The scope selects which surface to print: top-level, one family
    // (`wikictl source --help`), one subcommand (`source add --help`), or one
    // OKF operation (`page okf verify --help`) (#1224).
    if case .help(let scope) = invocation.command {
        print(CLIReference.helpText(for: scope))
        return 0
    }

    if case .version(let json) = invocation.command {
        // The App Group id and WHERE it came from are reported here on purpose.
        // A wrong container is otherwise invisible: the CLI just says "no wiki
        // matching <id> in the registry", which reads as an empty registry
        // rather than as reading the wrong one. `version` needs no wiki, so it
        // still answers when everything else fails — which makes it the right
        // place to look first.
        let group = WikiIdentifiers.appGroupID
        let source = WikiIdentifiers.appGroupIDSource
        if json {
            print("""
            {"appVersion":"\(GeneratedVersion.appVersion)","gitSHA":"\(GeneratedVersion.gitSHA)","commitCount":\(GeneratedVersion.gitCommitCount),"buildVersion":"\(GeneratedVersion.buildVersion)","fullVersion":"\(GeneratedVersion.fullVersionString)","appGroupID":"\(group)","appGroupIDSource":"\(source.rawValue)","appGroupIDConfigured":\(WikiIdentifiers.appGroupIDIsConfigured)}
            """)
        } else {
            print("wikictl \(GeneratedVersion.fullVersionString)")
            print("  appVersion:  \(GeneratedVersion.appVersion)")
            print("  git SHA:     \(GeneratedVersion.gitSHA)")
            print("  commit:      \(GeneratedVersion.gitCommitCount)")
            print("  build:       \(GeneratedVersion.buildVersion)")
            print("  app group:   \(group)")
            print("  group from:  \(source.description)")
            if !WikiIdentifiers.appGroupIDIsConfigured {
                print("")
                print("  ⚠ The App Group id is NOT configured — no wiki can be opened.")
                print("    Run signing/setup.sh, launch from inside the built .app,")
                print("    or export WIKI_APP_GROUP_ID=<your group id>.")
            }
        }
        return 0
    }

    if case .dumpConfig(let overlay) = invocation.command {
        return runDumpConfig(overlay: overlay)
    }

    // `wiki` subcommands — registry operations via direct App Group container
    // access (the app-bound XPC daemon is unreachable from the CLI). These
    // don't need a wiki selector.
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

    // Phase C: daemon-XPC chat commands.
    if case .daemonChatNew(let message) = invocation.command {
        return await runDaemonChatNew(wikiSelector: invocation.wikiSelector, message: message)
    }
    if case .daemonChatSend(let chatID, let message) = invocation.command {
        return await runDaemonChatSend(wikiSelector: invocation.wikiSelector, chatID: chatID, message: message)
    }
    if case .daemonChatStop(let chatID) = invocation.command {
        return await runDaemonChatStop(wikiSelector: invocation.wikiSelector, chatID: chatID)
    }

    // Job inspection is read-only end to end. It bypasses WikiCtlRunner's
    // writable wiki-store profile and opens both SQLite files without
    // migrations or checkpoints.
    if case .job(let action) = invocation.command {
        do {
            print(try await runJobCommand(action, wikiSelector: invocation.wikiSelector))
            return 0
        } catch {
            FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    do {
        let output = try await makeRunner().runOrdinary(
            command: invocation.command,
            wikiSelector: invocation.wikiSelector,
            environment: ProcessInfo.processInfo.environment)
        write(output)
        return 0
    } catch let failure as PageCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch let conflict as PageConflictError {
        // Phase 1: CAS conflict — the page was edited after the caller read it.
        // Exit code 3 signals the agent to re-read, reapply, and retry once.
        let actual = conflict.actualVersionID?.rawValue ?? "(none)"
        let message = """
        wikictl: CAS conflict on page \(conflict.pageID.rawValue) — \
        expected head \(conflict.expectedVersionID), \
        but actual head is \(actual). \
        Re-read the page, reapply your edit, and retry once.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as SourceMarkdownConflictError {
        // CAS conflict on a processed-markdown rewrite — the chain's head
        // moved after the caller read it (another writer won the race). Exit
        // code 3 (same convention as the page CAS) signals the agent to
        // re-read, reapply once, and retry once — never loop.
        let actual = conflict.currentHead?.rawValue ?? "(none)"
        let message = """
        wikictl: CAS conflict on source \(conflict.sourceID.rawValue) — \
        expected head \(conflict.expectedHead.rawValue), \
        but actual head is \(actual). \
        Re-read the processed markdown (`source cat --markdown`), re-read \
        head_version_id (`source info`), reapply your edit, and retry once. \
        Nothing was written. If it conflicts again, report the conflict \
        instead of retrying.

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
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    switch command {
    case .page(let action):
        let leg = await cliPageLegIfSearch(
            action,
            wikiID: wikiID,
            containerDirectory: containerDirectory,
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
    case .logAppend(let kind, let title, let note, let source):
        let r = try LogIndexCommand.run(.logAppend(kind: kind, title: title, note: note, source: source), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .indexSet(let bodyFile, let workspace):
        let body = try readBodyFile(from: bodyFile)
        let r = try LogIndexCommand.run(.indexSet(body: body, workspace: workspace), in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
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
            bm25Leg: await cliSourceLegIfSearch(
                action,
                wikiID: wikiID,
                containerDirectory: containerDirectory,
                store: store))
    case .admin(let action):
        return try AdminCommand.run(action, in: store)
    case .extractor(.sync(let packageName, let force)):
        return try await runExtractorSync(
            packageName: packageName, force: force, in: store,
            wikiID: wikiID, containerDirectory: containerDirectory)
    case .job:
        // Handled before the writable ordinary-command runner.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .chat(let action):
        return try await runChatCommand(
            action,
            in: store,
            wikiID: wikiID,
            containerDirectory: containerDirectory)
    case .bookmark(let action):
        let r = try BookmarkCommand.run(action, in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .workspace(let action):
        let r = try WorkspaceCommand.run(action, in: store)
        return SourceCommand.Result(payload: .text(r.output), didCommit: r.didCommit)
    case .help, .version, .dumpConfig:
        // Handled before wiki resolution in `run()` — unreachable here.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .wikiList, .wikiCreate, .wikiDelete, .wikiRename:
        // Handled before wiki resolution in `run()` — unreachable here.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    case .daemonChatNew, .daemonChatSend, .daemonChatStop:
        // Phase C: handled before wiki resolution in `run()` — unreachable here.
        return SourceCommand.Result(payload: .text(""), didCommit: false)
    }
}

/// `wikictl extractor sync <package>` dispatch: enqueue-only queue wiring.
/// The closure writes the durable `.extraction` item through
/// `QueueStore.enqueue` — the same immediate durable store write
/// `QueueEngine.enqueue` performs — WITHOUT constructing a `QueueEngine`
/// (that needs a worker factory whose provider implementations live in
/// targets `WikiCtlCore` cannot link) and WITHOUT waiting for completion
/// (waiters are per-engine in-memory; a daemon-side completion could never
/// resume a CLI waiter — it would hang). The app or the wikid daemon
/// rehydrates and drains the persisted items on its next dispatch scan /
/// launch.
private func runExtractorSync(
    packageName: String,
    force: Bool,
    in store: GRDBWikiStore,
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    let queueStore = try QueueStore(
        databaseURL: try DatabaseLocation.queueDatabaseURL())
    defer { queueStore.close() }
    // Discovery = durable machine catalog ∪ this process's reviewed overlay.
    // The reviewed root is wherever an `ExtractorPackages/` tree is staged
    // beside this binary (the build layout); when that does not resolve
    // (an app-bundled helper), the durable catalog the app published at
    // launch still carries the record.
    let reviewedRoot = ExtractorSyncCommand.reviewedPackageRoot()
    let catalog = try ExtractorSyncCommand.productionCatalogReader(
        containerDirectory: containerDirectory,
        reviewedPackageRoot: reviewedRoot)
    let output = try await ExtractorSyncCommand.run(
        packageName: packageName,
        force: force,
        in: store,
        containerDirectory: containerDirectory,
        catalog: catalog,
        enqueueJob: { sourceID in
            try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))).id
        })
    return SourceCommand.Result(payload: .text(output), didCommit: true)
}

/// Read durable job state without creating, migrating, or checkpointing either
/// database. A missing queue database is an empty list, not an invitation to
/// create the file.
private func runJobCommand(
    _ action: JobCommand.Action,
    wikiSelector: String
) async throws -> String {
    let resolver = try WikiResolver.appGroupContainer()
    guard let descriptor = resolver.descriptor(forSelector: wikiSelector) else {
        throw PageCommand.Failure.message(
            "no wiki matching \(wikiSelector.debugDescription) in the registry")
    }

    let queueURL = try DatabaseLocation.queueDatabaseURL()
    let items: [QueueItem]
    if FileManager.default.fileExists(atPath: queueURL.path) {
        let queueStore = try QueueStore(readOnlyDatabaseURL: queueURL)
        defer { queueStore.close() }
        items = try queueStore.loadItems(wikiID: descriptor.id)
    } else {
        items = []
    }

    let selectedItems: [QueueItem]
    let json: Bool
    switch action {
    case .list(let wantsJSON):
        selectedItems = items
        json = wantsJSON
    case .get(let id, let wantsJSON):
        guard let item = items.first(where: { $0.id == id }) else {
            throw JobCommand.Failure.notFound(id)
        }
        selectedItems = [item]
        json = wantsJSON
    }

    // The wiki leg goes through WikiReadService — the sanctioned read-only
    // projection seam (the boundary script rejects bare GRDBWikiStore
    // construction in this target). Existence of any processed markdown is
    // what "extraction completed" means here: a byteless placeholder source
    // has none.
    let wikiReadService = WikiReadService(
        databaseURL: resolver.databaseURL(for: descriptor))
    let sourceIDs = Set(selectedItems.flatMap(\.payload.sourceIDs))
    var completedSourceIDs = Set<SourceID>()
    for sourceID in sourceIDs {
        let head = try await wikiReadService.asyncRead { access in
            try access.processedMarkdownHead(sourceID: sourceID)
        }
        if head != nil {
            completedSourceIDs.insert(sourceID)
        }
    }
    await wikiReadService.shutdown()

    let output: String
    switch action {
    case .list:
        output = try JobCommand.renderList(
            items: selectedItems, completedSourceIDs: completedSourceIDs, json: json)
    case .get:
        output = try JobCommand.renderGet(
            item: selectedItems[0], completedSourceIDs: completedSourceIDs, json: json)
    }
    return output
}

/// #637: split-out dispatch for the `wikictl chat …` subcommands. Resolves
/// a Tantivy BM25 leg for `.search` before invoking `ChatCommand.run(...,
/// bm25Leg:)`. Mirrors the `page search` / `source search` paths in
/// `execute(...)` — kept as a helper so that function's switch stays compact.
private func runChatCommand(
    _ action: ChatCommand.Action,
    in store: GRDBWikiStore,
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    let leg: [ChatSummary]?
    if case .search(let query, let limit) = action {
        leg = await CLITantivyLegResolver.resolveChatLeg(
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
    wikiID: WikiID,
    containerDirectory: URL,
    store: GRDBWikiStore
) async -> [SourceSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return await CLITantivyLegResolver.resolveSourceLeg(
        wikiID: wikiID, containerDirectory: containerDirectory,
        store: store, query: query, limit: limit)
}

/// #637: inspect a `PageCommand.Action` and, when it's `.search`, resolve a
/// Tantivy BM25 leg to thread into `PageCommand.run(..., bm25Leg:)`. Returns
/// `nil` for every other action. Mirrors `cliSourceLegIfSearch` so the
/// `page search` / `source search` paths share the same resolve step.
private func cliPageLegIfSearch(
    _ action: PageCommand.Action,
    wikiID: WikiID,
    containerDirectory: URL,
    store: GRDBWikiStore
) async -> [WikiPageSummary]? {
    guard case .search(let query, let limit) = action else { return nil }
    return await CLITantivyLegResolver.resolvePageLeg(
        wikiID: wikiID, containerDirectory: containerDirectory,
        store: store, query: query, limit: limit)
}

/// Read an upsert body: `-` reads stdin to EOF; anything else is a file path.
/// Now a thin shim to `readBodyFile` in WikiCtlCore so the body-read contract
/// lives next to `BodySource`/`resolveBodySource`. Kept as a `wikictl`-local
/// helper so existing callers in this file (e.g. `LogIndexCommand` indexSet)
/// read cleanly.
func readBody(from source: String) throws -> String {
    try readBodyFile(from: source)
}

private func makeRunner() -> WikiCtlRunner {
    WikiCtlRunner { command, store, wikiID, containerDirectory in
        try await execute(
            command,
            in: store,
            wikiID: wikiID,
            containerDirectory: containerDirectory)
    }
}

private func write(_ output: WikiCtlRunner.Output) {
    if !output.stderr.isEmpty {
        FileHandle.standardError.write(output.stderr)
    }
    if !output.stdout.isEmpty {
        FileHandle.standardOutput.write(output.stdout)
    }
    if let wikiID = output.changedWikiID {
        DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
    }
}

// MARK: - wiki subcommands (direct registry access)
//
// These operate directly on `wikis.json` + the per-wiki `<ulid>.sqlite` in the
// App Group container — NOT via the daemon. The wikid daemon is now a bundled,
// app-bound XPC service (Contents/XPCServices/wikid.xpc): it is only reachable
// from within the host app's process, never from this standalone CLI. See
// plans/xpc-service-migration.md. The logic mirrors `WikiDaemon.createWiki` /
// `deleteWiki` / `renameWiki` verbatim, minus the daemon-only store caching +
// event-bus wiring.
//
// Registry-level changes (a new/deleted/renamed wiki) become visible to a
// running app on its NEXT launch: the app drives its registry in-process via
// `WikiRegistryClient` and only watches PER-PAGE Darwin notifications, not
// `wikis.json` itself (WikiChangeBridge). This matches the daemon's prior
// behavior — `createWiki` posted no registry notification either — and is fine
// for the CLI's scripting/headless role (the app creates wikis via its own
// client, not via wikictl).

func runDumpConfig(overlay: String?) -> Int32 {
    do {
        write(try makeRunner().runDumpConfig(overlay: overlay))
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: unable to dump config: \(error)\n".utf8))
        return 1
    }
}

func runWikiList() async -> Int32 {
    do {
        let resolver = try WikiResolver.appGroupContainer()
        let registry = WikiRegistry.load(from: resolver.containerDirectory)
        for wiki in registry.wikis {
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
        write(try makeRunner().runWikiCreate(name: name))
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

func runWikiDelete(id: String) async -> Int32 {
    do {
        let wikiID = WikiID(rawValue: id)
        let resolver = try WikiResolver.appGroupContainer()
        let container = resolver.containerDirectory
        var registry = WikiRegistry.load(from: container)
        guard let descriptor = registry.descriptor(id: wikiID) else {
            FileHandle.standardError.write(Data("wikictl: no wiki matching \(id)\n".utf8))
            return 1
        }

        // Remove from the registry first, then drop the DB files (main + WAL
        // sidecars). Mirrors WikiDaemon.deleteWiki.
        registry.remove(id: wikiID)
        try registry.save(to: container)

        let dbURL = resolver.databaseURL(for: descriptor)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            DebugLog.trying("remove database suffix \(suffix)") { try fm.removeItem(atPath: dbURL.path + suffix) }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

func runWikiRename(id: String, name: String) async -> Int32 {
    do {
        let resolver = try WikiResolver.appGroupContainer()
        let container = resolver.containerDirectory
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            FileHandle.standardError.write(Data("wikictl: wiki rename requires a non-empty name\n".utf8))
            return 1
        }
        let wikiID = WikiID(rawValue: id)
        var registry = WikiRegistry.load(from: container)
        guard registry.descriptor(id: wikiID) != nil else {
            FileHandle.standardError.write(Data("wikictl: no wiki matching \(id)\n".utf8))
            return 1
        }
        registry.rename(id: wikiID, to: trimmed)
        try registry.save(to: container)
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error)\n".utf8))
        return 1
    }
}

// `run()` is async — boot a top-level task and wait for it.
exit(await run())

// MARK: - chat subcommands (RETIRED — live chat is app-only)
//
// `chat new/send/stop` drove LIVE, streaming, persistent ACP sessions hosted
// inside the long-running wikid daemon. That daemon is now a bundled, app-bound
// XPC service (Contents/XPCServices/wikid.xpc) reachable only from the host app
// — a short-lived CLI process can neither reach it nor host a live conversation.
// wikictl stays a READ path for chat; driving a conversation is app-only. These
// commands are kept (so the CLI surface/scripts don't hard-break on an unknown
// subcommand) but fail fast with a clear message. See plans/xpc-service-migration.md.

/// The shared "chat is app-only" failure. Exit 1.
private func chatRetired() -> Int32 {
    let message = "wikictl: live chat is only available in the app (the wikid daemon "
        + "is an app-bound XPC service, not reachable from the CLI)\n"
    FileHandle.standardError.write(Data(message.utf8))
    return 1
}

/// `wikictl chat new "<message>"` — RETIRED (live chat is app-only).
func runDaemonChatNew(wikiSelector: String, message: String) async -> Int32 {
    chatRetired()
}

/// `wikictl chat send <chatID> "<message>"` — RETIRED (live chat is app-only).
func runDaemonChatSend(wikiSelector: String, chatID: String, message: String) async -> Int32 {
    chatRetired()
}

/// `wikictl chat stop <chatID>` — RETIRED (live chat is app-only).
func runDaemonChatStop(wikiSelector: String, chatID: String) async -> Int32 {
    chatRetired()
}
