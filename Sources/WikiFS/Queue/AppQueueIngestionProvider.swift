import Foundation
import WikiFSCore
import WikiFSEngine

/// The app-layer implementation of `QueueIngestionProvider`. Bridges the
/// headless `QueueEngine` (an actor in `WikiFSEngine`) to the `@MainActor`
/// `AgentLauncher` + `WikiStoreModel`.
///
/// The class is `@MainActor` (so it is implicitly `Sendable`). The engine
/// (running off-main) calls the protocol methods via `await`; Swift hops to
/// the main actor for each call.
///
/// Takes over the full `AgentOperationRunner.runMultiIngest` pipeline:
/// 1. `beginIngest` signaling (issue #235)
/// 2. Source reading + staging (reusing already-extracted markdown for PDFs)
/// 3. Workspace create (if `workspacesEnabled`)
/// 4. Agent spawn via `launcher.run(...)`
/// 5. Workspace auto-merge + `endIngest` on completion
///
/// **Provider resolution:** the launcher resolves the selected agent provider
/// internally during `run(...)`. The queue engine uses a fixed "default-ingest"
/// provider ID for per-provider concurrency (limit 1 by default). True per-
/// provider limits are a future refinement.
@MainActor
final class AppQueueIngestionProvider: QueueIngestionProvider {
    private let sessionBox: SessionLookupBox
    private let fileProviderBox: FileProviderBox
    private let wikictlDirectory: String

    /// Resolves the selected agent provider (from `agent-providers.json`) for
    /// the readiness probe. Injectable so tests can stub it without touching the
    /// filesystem or spawning `zsh`. Defaults to reading from the App Group
    /// container, exactly like `AgentLauncher.resolveSelectedProvider`.
    ///
    /// #635: when no provider is enabled, `AgentProvidersConfig.selectedProvider`
    /// falls back to the hardcoded `claudeAcpDefault` static (so the launcher's
    /// own spawn path can still attempt a fresh process if bun is on PATH). But
    /// that fallback masks the operator-disabled state from the readiness probe
    /// — `readiness()` would return `nil` (ready) and the worker would proceed
    /// into `launcher.run(...)`, dead-ending at "Agent process is not running"
    /// against the torn-down subprocess from the cancelled prior turn. To detect
    /// the disabled state we need the FULL provider config (not just
    /// `selectedProvider()`'s post-fallback result), so the probe checks
    /// `enabledProviders.isEmpty` directly via `resolveProviderConfig`.
    private let resolveSelectedProvider: () -> AgentProvider
    private let resolveProviderConfig: () -> AgentProvidersConfig

    init(
        sessionBox: SessionLookupBox,
        fileProviderBox: FileProviderBox,
        wikictlDirectory: String,
        resolveSelectedProvider: @escaping () -> AgentProvider = {
            let dir = (try? DatabaseLocation.appGroupContainerDirectory())
                ?? FileManager.default.temporaryDirectory
            return AgentProvidersConfig.loadOrSeed(from: dir).selectedProvider()
        },
        resolveProviderConfig: @escaping () -> AgentProvidersConfig = {
            let dir = (try? DatabaseLocation.appGroupContainerDirectory())
                ?? FileManager.default.temporaryDirectory
            return AgentProvidersConfig.loadOrSeed(from: dir)
        }
    ) {
        self.sessionBox = sessionBox
        self.fileProviderBox = fileProviderBox
        self.wikictlDirectory = wikictlDirectory
        self.resolveSelectedProvider = resolveSelectedProvider
        self.resolveProviderConfig = resolveProviderConfig
    }

    // MARK: - Readiness (#440, extended #635)

    func readiness() async -> String? {
        // #635: detect the operator-disabled state. `selectedProvider()` falls
        // back to the hardcoded `claudeAcpDefault` when every configured
        // provider is disabled — that fallback passes the existing PATH-based
        // readiness check (bun's binary may well be on PATH), so retry would
        // proceed into `launcher.run(...)` and dead-end at "Agent process is
        // not running" against the torn-down subprocess from the cancelled
        // prior turn. Short-circuit HERE with an actionable message so the
        // worker fast-fails via `QueueIngestionError.notReady` and
        // `handleWorkerFinished` marks the item `.failed` cleanly — surfacing
        // the alert AND the "Configure Agents…" CTA in the Activity window
        // (via `isConfigurationError`, which now matches this message).
        let config = resolveProviderConfig()
        if config.enabledProviders.isEmpty {
            let msg = "Agent is not available — no enabled agent provider. Re-enable the agent in Settings → Agents to retry."
            DebugLog.ingest("AppQueueIngestionProvider.readiness: NO ENABLED PROVIDER (providers=\(config.providers.count))")
            return msg
        }

        let provider = resolveSelectedProvider()
        let message = AgentLauncher.readinessMessage(for: provider)
        if message != nil {
            DebugLog.ingest("AppQueueIngestionProvider.readiness: NOT READY provider=\(provider.id) label=\(provider.label)")
        }
        return message
    }

    // MARK: - QueueIngestionProvider

    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }

        // The launcher is accessed through the session's WikiSession.
        // The session is @MainActor; since this provider is also @MainActor,
        // access is synchronous.
        guard let session = sessionBox.resolveSession(for: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }
        let launcher = session.agentLauncher
        let changeSignaler: any ChangeSignaler
        guard let fp = fileProviderBox.provider else {
            throw QueueIngestionError.spawnFailed("File provider not yet wired — app is still launching")
        }
        changeSignaler = fp

        guard !sourceIDs.isEmpty else {
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("AppQueueIngestionProvider.runIngestion: begin count=\(sourceIDs.count)")

        // Announce the ingest is active BEFORE staging so the Edit preflight
        // (store.isIngestInProgress) blocks during the staging window too
        // (issue #235).
        store.beginIngest()

        // Stage sources — reuse already-extracted markdown for PDFs (the
        // extraction item ran before this ingestion item in the chained path,
        // or the user ran "Extract Markdown" manually).
        let stateMarkdown = store.currentStateSnapshot().renderStateFile()
        var sources: [OperationRequest.StagedSource] = []

        for sourceID in sourceIDs {
            guard let source = store.sources.first(where: { $0.id == sourceID }),
                  let bytes = store.sourceBytes(id: sourceID)
            else {
                DebugLog.ingest("AppQueueIngestionProvider: skipping \(sourceID.rawValue) — source or bytes missing")
                continue
            }

            var sourceBytes = bytes
            var sourceExt = source.ext

            // PDF → reuse extracted markdown if available (extraction already
            // ran via the extraction queue item).
            if MimeType.isPDF(source.mimeType) {
                if let head = store.processedMarkdownHead(for: source) {
                    sourceBytes = head.content.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    DebugLog.extraction("AppQueueIngestionProvider: reusing markdown for \(source.filename)")
                }
            }

            sources.append(OperationRequest.StagedSource(
                bytes: sourceBytes,
                ext: sourceExt,
                displayPath: ingestSourcePath(for: source)
            ))
        }

        guard !sources.isEmpty else {
            store.endIngest()
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("AppQueueIngestionProvider: handing off \(sources.count) source(s)")

        // Workspace-isolated ingestion (Phase 7 of multi-writer hardening).
        // When the capability flag is on, create a workspace, pass the ID
        // to the launcher, and auto-merge on completion.
        if store.workspacesEnabled {
            do {
                let wsID = try store.createWorkspace(
                    name: "ingest-\(sourceIDs.count)", activityID: nil)
                DebugLog.ingest("AppQueueIngestionProvider: workspace isolated, wsID=\(wsID)")

                await runAgent(
                    request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                    launcher: launcher,
                    store: store,
                    wikiID: wikiID,
                    queueItemID: queueItemID,
                    changeSignaler: changeSignaler,
                    ingestingSourceIDs: Set(sourceIDs),
                    workspaceID: wsID,
                    onWorkspaceMerge: { [weak store] in
                        guard let store else { return }
                        do {
                            try store.workspaceMerge(workspaceID: wsID)
                            DebugLog.ingest("AppQueueIngestionProvider: workspace merged wsID=\(wsID)")
                        } catch {
                            DebugLog.ingest("AppQueueIngestionProvider: workspace merge FAILED wsID=\(wsID) — \(error.localizedDescription)")
                        }
                    },
                    onProgress: onProgress,
                    onTranscript: onTranscript,
                    onLiveUsage: onLiveUsage,
                    onPendingPermission: onPendingPermission
                )
            } catch {
                DebugLog.ingest("AppQueueIngestionProvider: workspace creation FAILED — falling back to main, \(error.localizedDescription)")
                await runAgent(
                    request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                    launcher: launcher,
                    store: store,
                    wikiID: wikiID,
                    queueItemID: queueItemID,
                    changeSignaler: changeSignaler,
                    ingestingSourceIDs: Set(sourceIDs),
                    onProgress: onProgress,
                    onTranscript: onTranscript,
                    onLiveUsage: onLiveUsage,
                    onPendingPermission: onPendingPermission
                )
            }
        } else {
            await runAgent(
                request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                launcher: launcher,
                store: store,
                wikiID: wikiID,
                queueItemID: queueItemID,
                changeSignaler: changeSignaler,
                ingestingSourceIDs: Set(sourceIDs),
                onProgress: onProgress,
                onTranscript: onTranscript,
                onLiveUsage: onLiveUsage,
                onPendingPermission: onPendingPermission
            )
        }

        // #528 spike: read the launcher's accumulated run-total usage after
        // the run completes and forward it to the worker (which emits a
        // `.usage` queue event). Done here, after `run()` returns, so the
        // usage reflects all phases (planner → executors → finalizer).
        onUsage?(launcher.runTotalUsage)
        onLogPaths?(launcher.logFileURL, launcher.debugFolderURL)

        // If the agent never spawned (cancelled, preflight failure), clear
        // the ingest flag. The tracker's ingestingSourceIDs will be cleared
        // by the queue event when the item reaches a terminal state.
        if !launcher.isRunning {
            store.endIngest()
        }
    }

    // MARK: - Lint (payload variant of .ingestion)

    func runLint(
        wikiID: String,
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }
        guard let session = sessionBox.resolveSession(for: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }
        let launcher = session.agentLauncher
        let changeSignaler: any ChangeSignaler
        guard let fp = fileProviderBox.provider else {
            throw QueueIngestionError.spawnFailed("File provider not yet wired — app is still launching")
        }
        changeSignaler = fp

        DebugLog.ingest("AppQueueIngestionProvider.runLint: begin wikiID=\(wikiID)")

        await runLintAgent(
            request: .lint(stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            queueItemID: queueItemID,
            changeSignaler: changeSignaler,
            onProgress: onProgress,
            onTranscript: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission
        )
        onUsage?(launcher.runTotalUsage)
        onLogPaths?(launcher.logFileURL, launcher.debugFolderURL)
    }

    func runLintPages(
        wikiID: String,
        pageIDs: [PageID],
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }
        guard let session = sessionBox.resolveSession(for: wikiID) else {
            throw QueueIngestionError.spawnFailed("No session for wikiID=\(wikiID)")
        }
        let launcher = session.agentLauncher
        let changeSignaler: any ChangeSignaler
        guard let fp = fileProviderBox.provider else {
            throw QueueIngestionError.spawnFailed("File provider not yet wired — app is still launching")
        }
        changeSignaler = fp

        DebugLog.ingest("AppQueueIngestionProvider.runLintPages: begin wikiID=\(wikiID) pages=\(pageIDs.count)")

        // Map pageIDs → [(id, title)] via store.summaries, mirroring the
        // AgentOperationRunner.runLintPages call signature.
        let pages: [(id: PageID, title: String)] = pageIDs.compactMap { id in
            guard let s = store.summaries.first(where: { $0.id == id }) else { return nil }
            return (id: id, title: s.title)
        }

        // Run the pre-flight + combined lint, mirroring
        // AgentOperationRunner.runLintPages but with progress + transcript.
        let preflights = pages.map { page in
            let preflight = store.preflightLint(pageID: page.id)
            let allBroken = (preflight?.brokenPageLinks ?? [])
                + (preflight?.brokenSourceLinks ?? [])
                + (preflight?.brokenChatLinks ?? [])
            return (title: page.title, brokenLinks: allBroken)
        }
        let combinedTitle = pages.map(\.title).joined(separator: ", ")
        let combinedBroken = preflights.flatMap(\.brokenLinks)

        await runLintAgent(
            request: .lintPage(
                pageTitle: combinedTitle,
                brokenLinks: combinedBroken,
                stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            queueItemID: queueItemID,
            changeSignaler: changeSignaler,
            onProgress: onProgress,
            onTranscript: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission
        )
        onUsage?(launcher.runTotalUsage)
        onLogPaths?(launcher.logFileURL, launcher.debugFolderURL)
    }

    // MARK: - Private

    /// Run the agent via `launcher.run(...)`. Mirrors
    /// `AgentOperationRunner.run(...)` but adds progress + transcript forwarding.
    /// `queueItemID` is passed through to the launcher so the run's scratch dir
    /// takes the namespaced shape `<id>/runs/<RFC3339>/` (grouped retries,
    /// derivable "latest run" by item ID across app restarts).
    private func runAgent(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        queueItemID: String,
        changeSignaler: any ChangeSignaler,
        ingestingSourceIDs: Set<PageID>,
        workspaceID: String? = nil,
        onWorkspaceMerge: (@MainActor () -> Void)? = nil,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async {
        // Signal the File Provider to refresh the mount before the agent reads.
        await changeSignaler.signalChange()
        let root = changeSignaler.path ?? ""

        // Forward typed agent events to the queue's transcript tracker via the
        // run parameter — assigning `launcher.onAgentEvent` here is a bug:
        // `run()` clears that property in `resetRunArtifacts()` before spawning.
        DebugLog.ingest("AppQueueIngestionProvider.runAgent: onTranscript is \(onTranscript == nil ? "nil" : "set")")

        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            ingestingSourceIDs: ingestingSourceIDs,
            workspaceID: workspaceID,
            queueItemID: queueItemID,
            onEvent: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission,
            providerLabel: resolveSelectedProvider().label,
            onLock: { store.agentRunStarted() },
            onUnlock: {
                store.agentRunEnded()
                if !ingestingSourceIDs.isEmpty { store.endIngest() }
                onWorkspaceMerge?()
            }
        )
    }

    /// Run a lint agent via `launcher.run(...)`. Like `runAgent` but without
    /// workspace isolation or ingest signaling — lint is read-only-ish (it
    /// writes to the log, but not source pages being ingested).
    private func runLintAgent(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        queueItemID: String,
        changeSignaler: any ChangeSignaler,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async {
        await changeSignaler.signalChange()
        let root = changeSignaler.path ?? ""

        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            ingestingSourceIDs: [],
            workspaceID: nil,
            queueItemID: queueItemID,
            onEvent: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission,
            providerLabel: resolveSelectedProvider().label,
            onLock: { store.agentRunStarted() },
            onUnlock: { store.agentRunEnded() }
        )
    }

    private func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }
}
