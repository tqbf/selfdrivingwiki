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

    init(
        sessionBox: SessionLookupBox,
        fileProviderBox: FileProviderBox,
        wikictlDirectory: String
    ) {
        self.sessionBox = sessionBox
        self.fileProviderBox = fileProviderBox
        self.wikictlDirectory = wikictlDirectory
    }

    // MARK: - QueueIngestionProvider

    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void
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
            if source.mimeType == "application/pdf" {
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
                    onProgress: onProgress
                )
            } catch {
                DebugLog.ingest("AppQueueIngestionProvider: workspace creation FAILED — falling back to main, \(error.localizedDescription)")
                await runAgent(
                    request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                    launcher: launcher,
                    store: store,
                    wikiID: wikiID,
                    changeSignaler: changeSignaler,
                    ingestingSourceIDs: Set(sourceIDs),
                    onProgress: onProgress
                )
            }
        } else {
            await runAgent(
                request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                launcher: launcher,
                store: store,
                wikiID: wikiID,
                changeSignaler: changeSignaler,
                ingestingSourceIDs: Set(sourceIDs),
                onProgress: onProgress
            )
        }

        // If the agent never spawned (cancelled, preflight failure), clear
        // the ingest flag. The tracker's ingestingSourceIDs will be cleared
        // by the queue event when the item reaches a terminal state.
        if !launcher.isRunning {
            store.endIngest()
        }
    }

    // MARK: - Private

    /// Run the agent via `launcher.run(...)`. Mirrors
    /// `AgentOperationRunner.run(...)` but adds progress forwarding.
    private func runAgent(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        ingestingSourceIDs: Set<PageID>,
        workspaceID: String? = nil,
        onWorkspaceMerge: (@MainActor () -> Void)? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async {
        // Signal the File Provider to refresh the mount before the agent reads.
        await changeSignaler.signalChange()
        let root = changeSignaler.path ?? ""

        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            ingestingSourceIDs: ingestingSourceIDs,
            workspaceID: workspaceID,
            onLock: { store.agentRunStarted() },
            onUnlock: {
                store.agentRunEnded()
                if !ingestingSourceIDs.isEmpty { store.endIngest() }
                onWorkspaceMerge?()
            }
        )
    }

    private func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }
}
