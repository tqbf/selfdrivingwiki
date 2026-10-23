import Foundation
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// `wikictl` — the agent's scriptable path into a wiki.
///
/// Since the fixture-binary split (plans/cli-domain-commands.md §"The fixture
/// binary") this binary has NO local database pathway: every command resolves
/// its `--wiki` selector through the wikid daemon's registry over the socket
/// and executes daemon-side against the daemon's prepared store (the daemon
/// runs the identical command layer, so stdout bytes are unchanged), then —
/// after any committing call — posts a per-wiki Darwin notification so the app
/// refreshes. Disposable fixture databases are the separate build-only
/// `wikictl-fixture` binary's contract; `--database-path`/`WIKI_DB_PATH` are
/// rejected here as usage errors. Raw source reads go through the `wikictl
/// file` family rather than the File Provider mount.
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

    // Job inspection is read-only end to end. Phase 3 of
    // plans/cli-domain-commands.md: it reads the daemon's durable per-wiki
    // queue read over the socket (`queueWikiItems`) — the queue database and
    // the wiki store are opened by the daemon, not here.
    if case .job(let action) = invocation.command {
        do {
            let router = DaemonCommandRouter()
            let (output, emptyList) = try await router.runJob(
                action,
                selector: invocation.wikiSelector)
            print(output)
            if emptyList {
                // #1230 (axi.md principle 5): zero jobs is an answer, not a
                // silence (stdout keeps its exact bytes — the TSV header, or
                // `[]` for --json). The stderr notice says so; exit stays 0.
                FileHandle.standardError.write(Data(ZeroResults.note("job list").utf8))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // The queue family runs against the LIVE daemon over its local socket —
    // the versioned domain envelope transport (Phase 1 of
    // plans/cli-domain-commands.md). The app-only XPC surface is unreachable
    // from a standalone binary. App closed ⇒ socket unlinked ⇒ this fails
    // fast with the explicit not-running error; there is no local fallback.
    if case .queue(let action) = invocation.command {
        do {
            print(try await runQueueCommand(action))
            return 0
        } catch {
            FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // The transcribe family enqueues on-device speech jobs through the same
    // live daemon surface; waiting jobs poll the daemon's queue item-state
    // snapshots (Phase 5 of plans/cli-domain-commands.md). No wiki-store
    // profile and no queue database is ever opened in this process.
    if case .transcribe(let action) = invocation.command {
        do {
            print(try await runTranscribeCommand(action, wikiSelector: invocation.wikiSelector))
            return 0
        } catch {
            FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // `extractor list` is read-only and wiki-independent: no store, no
    // wiki selection — only the machine catalog (App Group container) and
    // describe-only credential presence checks. Dispatching it before the
    // writable runner keeps discovery available even with no wiki selected.
    if case .extractor(.list(let json)) = invocation.command {
        do {
            let containerDirectory = try DatabaseLocation.appGroupContainerDirectory()
            let catalog = try ExtractorSyncCommand.productionCatalogReader(
                containerDirectory: containerDirectory,
                reviewedPackageRoot: ExtractorSyncCommand.reviewedPackageRoot())
            print(try ExtractorListCommand.run(catalog: catalog, json: json))
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
    } catch let conflict as PageCreateConflictError {
        // Create-only conflict (cumulative ingestion, phase 4 §4): the caller's
        // read found no page under the title, but one exists now. Same exit
        // code 3 as the CAS conflict — the agent re-reads the page, reconciles
        // against its head, and writes with --expect-head. Nothing was written.
        let actual = conflict.actualVersionID?.rawValue ?? "(none)"
        let message = """
        wikictl: create-only conflict on page \(conflict.pageID.rawValue) — \
        --create-only requires the title to be absent, \
        but a page now exists under \(conflict.title) (head \(actual)). \
        Read that page, reconcile against its head, and write with --expect-head. \
        Nothing was written.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let conflict as PageExpectedTargetMissingError {
        // Expected-head write whose target no longer exists (deleted or
        // renamed away since the caller's read) — same exit code 3 family:
        // re-read, reconcile, write again. Nothing was written, and no page
        // was silently created.
        let target = conflict.pageID?.rawValue ?? "title \(conflict.title)"
        let message = """
        wikictl: expected-head conflict — the page you pinned (\(target)) \
        does not exist anymore (deleted or renamed since your read). \
        Re-read (`page list` / `page get`), reconcile, and write again. \
        Nothing was written.

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
    } catch let conflict as WikiStrategyConflictError {
        // CAS conflict on the strategy singleton — another editor committed
        // since the caller's read (the app's strategy editor, another agent,
        // another wikictl). Exit code 3 (same convention as the page/source
        // CAS families) signals the agent to re-read, reapply once, and
        // retry once — never loop. The write threw before any row change.
        let expected = conflict.expectedRevision.map { "revision \($0.rawValue)" }
            ?? "absent (no strategy row ever written)"
        let current = conflict.currentRevision.map { "revision \($0.rawValue)" }
            ?? "absent (no strategy row has ever been written)"
        let message = """
        wikictl: CAS conflict on strategy — \
        expected \(expected), \
        but the committed revision is \(current). \
        Re-read (`strategy read`), reapply your edit, and retry once with the \
        new revision. Nothing was written.

        """
        FileHandle.standardError.write(Data(message.utf8))
        return 3
    } catch let failure as SourceCommand.Failure {
        FileHandle.standardError.write(Data("wikictl: \(failure)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
        return 1
    }
}


/// `wikictl queue status|pause|resume|halt` — runs against the live daemon
/// over its local socket (`DaemonWorkloadClient`'s socket backend, Phase 1 of
/// plans/cli-domain-commands.md). `status` renders per-lane truth from the
/// daemon's queue snapshot; the lane controls are pass-through verbs whose
/// effect is durable in the daemon's queue store.
private func runQueueCommand(_ action: QueueCommand.Action) async throws -> String {
    #if os(macOS)
    let client = try DaemonWorkloadClient(
        socket: DaemonScopedRunEnvironment.domainSocketClient(
            environment: ProcessInfo.processInfo.environment))
    switch action {
    case .status(let json):
        let snapshot = try await client.queueSnapshot()
        let lanes: [QueueKind] = [.extraction, .ingestion]
        let statuses: [QueueCommand.LaneStatus] = lanes.map { lane in
            let active = snapshot.activeItems.filter { $0.queue == lane }
            let queued = active.filter { $0.state == .queued }
            return QueueCommand.LaneStatus(
                queue: lane.canonical.rawValue,
                runState: (snapshot.runStates[lane] ?? .running).rawValue,
                running: active.filter { $0.state == .running }.count,
                queued: queued.count,
                waitingForRoute: queued.filter { $0.admissionReason != nil }.count)
        }
        return try QueueCommand.renderStatus(lanes: statuses, json: json)
    case .pause(let lane):
        try await client.pause(lane)
        return QueueCommand.renderLaneChanged(queue: lane, state: "paused")
    case .resume(let lane):
        try await client.resume(lane)
        return QueueCommand.renderLaneChanged(queue: lane, state: "running")
    case .halt(let lane):
        try await client.halt(lane)
        return QueueCommand.renderLaneChanged(queue: lane, state: "halted")
    }
    #else
    throw QueueCommandUnsupportedError()
    #endif
}

private struct QueueCommandUnsupportedError: LocalizedError {
    var errorDescription: String? { "wikictl queue requires macOS (the wikid daemon socket surface)" }
}

/// Enqueue the EXPLICIT on-device speech job for one source through the live
/// daemon workload surface, mirroring the app's provenance-chip menu action:
/// same payload intent, same speech arm, same typed failures (YouTube
/// sources only; no caption fallback). `--wiki` resolves the owning wiki and
/// the source is preflighted BOTH over the daemon's socket (Phase 5 of
/// plans/cli-domain-commands.md) — a wrong-source mistake fails BEFORE
/// anything is enqueued, and this process opens no database. With the default
/// `--wait`, the command polls the daemon's queue item-state snapshots and
/// prints the typed outcome (success, or the queue item's redacted error).
private func runTranscribeCommand(
    _ action: TranscribeCommand.Action,
    wikiSelector: String
) async throws -> String {
    #if os(macOS)
    switch action {
    case .onDevice(let source, let json, let wait):
        guard wikiSelector.isEmpty == false else {
            throw TranscribeCommand.Failure(
                "transcribe on-device: pass --wiki <id> before the subcommand (the wiki that owns the source)")
        }
        // Phases 2 and 5 of plans/cli-domain-commands.md: --wiki resolution
        // AND the source preflight ride the daemon over the socket —
        // resolveWiki for the owning wiki, transcribePreflight for the
        // YouTube-scope check (the daemon reads its own prepared store; this
        // process opens nothing). Both fail fast with the not-running error
        // when the app is closed. There is no local fallback. §7: the
        // container resolves only on the ordinary branch (inside the
        // factory) — a scoped child's container is kernel-denied.
        let descriptor: WikiDescriptor
        do {
            descriptor = try await makeRegistryClient().resolveWiki(selector: wikiSelector)
        } catch let error as DaemonDomainError where error.code == .notFound {
            throw TranscribeCommand.Failure(
                "no wiki matching \(wikiSelector.debugDescription) in the registry")
        }

        // Pre-flight the source against the owning wiki, DAEMON-side: the
        // queue path would fail anyway, but the typed message reads better
        // here and nothing is enqueued for a mistake.
        let sourceID = SourceID(rawValue: source)
        let client = try DaemonWorkloadClient(
            socket: DaemonScopedRunEnvironment.domainSocketClient(
                environment: ProcessInfo.processInfo.environment))
        do {
            let inScope = try await client.transcribePreflight(
                wikiID: descriptor.id, sourceID: sourceID)
            guard inScope else {
                throw TranscribeCommand.Failure(
                    "source \(source) is not a YouTube video in wiki \(wikiSelector) — on-device speech supports YouTube videos only")
            }
        } catch let error as TranscribeCommand.Failure {
            throw error
        } catch {
            // A failed preflight read is surfaced, not swallowed: the agent
            // should see WHY the source could not be verified.
            throw TranscribeCommand.Failure(
                "could not verify source \(source) in wiki \(wikiSelector): \(error.localizedDescription)")
        }

        // The enqueue write is durable in the daemon's queue store even if
        // its reply is slow (the handler runs the dispatch scan inline). A
        // CLI cannot leak a parked continuation — it would never exit — so
        // the call is raced against a bounded local wait and the process
        // exits with a clear note if the reply misses it.
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: descriptor.id,
            payload: QueueItemPayload(
                sourceIDs: [sourceID],
                transcriptionIntent: .onDeviceSpeech))
        // Synchronized single-result box: the detached task writes, the
        // polling loop reads, under one NSLock — the lock is the Sendable
        // invariant. The enqueue write is durable in the daemon's queue
        // store even if its reply is slow (the handler runs the dispatch
        // scan inline), but a CLI cannot leak a parked continuation — it
        // would never exit — so the reply is raced against a bounded local
        // wait and a missed reply exits with a clear note.
        // swiftlint:disable:next unchecked_sendable
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var itemID: String?
            private var error: Error?
            func store(id: String) { lock.lock(); itemID = id; lock.unlock() }
            func store(error: Error) { lock.lock(); self.error = error; lock.unlock() }
            func snapshot() -> (String?, Error?) {
                lock.lock(); defer { lock.unlock() }
                return (itemID, error)
            }
        }
        let box = Box()
        let clientRef = client
        let task = Task.detached {
            do {
                let id = try await clientRef.enqueue(request)
                box.store(id: id.rawValue)
            } catch {
                box.store(error: error)
            }
        }
        let enqueueDeadline = Date().addingTimeInterval(35)
        var snapshot = box.snapshot()
        while snapshot.0 == nil && snapshot.1 == nil && Date() < enqueueDeadline {
            try await Task.sleep(for: .milliseconds(250))
            snapshot = box.snapshot()
        }
        task.cancel()
        if let error = snapshot.1 {
            throw TranscribeCommand.Failure(
                "enqueue failed: \(error.localizedDescription)")
        }
        guard let idRaw = snapshot.0 else {
            FileHandle.standardError.write(Data(
                "wikictl: the enqueue reply is slow — the job was written durably and will run; check `wikictl job list`\n".utf8))
            return json
                ? "{ \"enqueued\": \"pending\" }"
                : "enqueue reply pending; the job was written durably and will run"
        }
        let itemID = QueueItemID(rawValue: idRaw)

        let enqueuedLine = TranscribeCommand.renderEnqueued(
            itemID: itemID.rawValue, source: source, wait: wait)
        if json {
            print("{ \"itemID\": \"\(itemID.rawValue)\", \"enqueued\": true }")
        } else {
            print(enqueuedLine)
        }

        guard wait else { return "" }

        // Phase 5 of plans/cli-domain-commands.md: poll the daemon's
        // `queueItemState` operation — one SHORT item-state snapshot per round
        // trip, sleeping BETWEEN calls — instead of holding this process's own
        // read-only queue-store connection open for the job's duration. Every
        // round trip is bounded by the workload client's per-call deadline;
        // the 165-minute ceiling is the speech wait policy (and the caller's
        // Ctrl-C), never a socket lifetime. There is no local fallback: a
        // daemon failure mid-wait (the app quit, the socket went away)
        // surfaces as this command's error, and an unknown item (the durable
        // terminal history is never deleted) fails instead of polling forever.
        let started = Date()
        let waitLimit = started.addingTimeInterval(
            165 * 60)
        var finalState: String?
        var finalError: String?
        while Date() < waitLimit {
            try Task.checkCancellation()
            let snapshot = try await client.queueItemState(of: itemID)
            switch snapshot.state {
            case QueueItemState.completed.rawValue: finalState = "completed"
            case QueueItemState.failed.rawValue:
                finalError = snapshot.error ?? "failed"
            case QueueItemState.cancelled.rawValue: finalError = "cancelled"
            default: break
            }
            if finalState != nil || finalError != nil { break }
            try await Task.sleep(for: .seconds(5))
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        if finalState == nil && finalError == nil {
            finalError = "wait limit exceeded; the job may still be running"
        }
        let completed = (finalState == "completed")
        if json {
            let errorJSON = finalError.map { message in
                ", \"error\": \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\""
            } ?? ""
            print("{ \"itemID\": \"\(itemID.rawValue)\", \"completed\": \(completed)\(errorJSON), \"elapsedSeconds\": \(elapsed) }")
            return ""
        }
        return TranscribeCommand.renderOutcome(
            source: source,
            completed: completed,
            errorMessage: finalError,
            elapsedSeconds: elapsed)
    }
    #else
    throw TranscribeCommand.Failure(
        "wikictl transcribe requires macOS (the wikid daemon socket surface)")
    #endif
}


private func makeRunner() -> WikiCtlRunner {
    WikiCtlRunner()
}

private func write(_ output: WikiCtlRunner.Output) {
    if !output.stderr.isEmpty {
        FileHandle.standardError.write(output.stderr)
    }
    if !output.stdout.isEmpty {
        FileHandle.standardOutput.write(output.stdout)
    }
    if output.changedWikiID != nil {
        DarwinNotifier.postChange()
    }
}

// MARK: - wiki subcommands (daemon registry over the socket)
//
// Phase 2 of plans/cli-domain-commands.md: every wiki verb routes through the
// daemon's registry over its local socket (`DaemonWikiRegistryClient`) — the
// daemon is the single pathway to `wikis.json` and the per-wiki databases.
// `wiki list` / `wiki rename` reads adopt the app's on-disk registry, so
// app-side creates and renames are visible immediately; `wiki create` runs
// the daemon's creation coordinator (bootstrap + seed + child profile);
// `wiki delete` inherits the daemon's FULL eviction (search runtime shutdown,
// child profile removal, registry row, database artifacts), which closes the
// CLI's old degraded-delete race (a delete that never cleaned the search
// index or raced a live daemon's caches).
//
// App closed ⇒ socket unlinked ⇒ every wiki command fails fast with "the
// wikid daemon is not running — launch the app" (exit 1). No local fallback.
//
// Registry changes become visible to a running app through the same mechanism
// as before: the app's `WikiChangeBridge` re-reads `wikis.json` on every
// wiki-change wake, and the daemon now owns the write.

func runDumpConfig(overlay: String?) -> Int32 {
    do {
        write(try makeRunner().runDumpConfig(overlay: overlay))
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: unable to dump config: \(error)\n".utf8))
        return 1
    }
}

/// The container-scoped registry client for the wiki subcommands. §7: the
/// shared scoped-run factory resolves the credential environment, so a
/// managed child's wiki commands ride the run endpoint with v2 authorization;
/// the container resolves only on the ordinary branch (a scoped child's
/// container is kernel-denied).
private func makeRegistryClient() throws -> DaemonWikiRegistryClient {
    DaemonWikiRegistryClient(socket: try DaemonScopedRunEnvironment.domainSocketClient(
        environment: ProcessInfo.processInfo.environment))
}

func runWikiList() async -> Int32 {
    do {
        let client = try makeRegistryClient()
        let wikis = try await client.listWikis()
        for wiki in wikis {
            // `.rawValue` — the TSV scripting contract carries the raw ULID,
            // not the type's Debug rendering.
            print("\(wiki.id.rawValue)\t\(wiki.displayName)")
        }
        if wikis.isEmpty {
            // #1230 (axi.md principle 5): zero wikis is an answer, not a
            // silence. The stderr notice says so; stdout stays empty; exit
            // stays 0.
            FileHandle.standardError.write(Data(ZeroResults.note("wiki list").utf8))
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

func runWikiCreate(name: String) async -> Int32 {
    do {
        let client = try makeRegistryClient()
        let descriptor = try await client.createWiki(name: name)
        // `.rawValue` — the TSV scripting contract carries the raw ULID,
        // not the type's Debug rendering.
        print("\(descriptor.id.rawValue)\t\(descriptor.displayName)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

func runWikiDelete(id: String) async -> Int32 {
    do {
        let client = try makeRegistryClient()
        // An unknown id throws the daemon's typed notFound ("no wiki matching
        // <id>") — the same failure text the direct-registry path printed.
        try await client.deleteWiki(id: WikiID(rawValue: id))
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

func runWikiRename(id: String, name: String) async -> Int32 {
    do {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            FileHandle.standardError.write(Data("wikictl: wiki rename requires a non-empty name\n".utf8))
            return 1
        }
        let client = try makeRegistryClient()
        try await client.renameWiki(id: WikiID(rawValue: id), name: trimmed)
        return 0
    } catch {
        FileHandle.standardError.write(Data("wikictl: \(error.localizedDescription)\n".utf8))
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
