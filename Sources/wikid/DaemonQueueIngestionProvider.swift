import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

#if canImport(WikiFSEngine)

/// The daemon-layer implementation of `QueueIngestionProvider`. Mirrors
/// `AppQueueIngestionProvider` but talks to `GRDBWikiStore` directly — no
/// `WikiStoreModel`, no `FileProviderFacade`, no `SessionLookupBox`.
///
/// Unlike the app's `@MainActor` provider, this type is `@unchecked Sendable`.
/// It hops to the main actor when constructing + reading the `AgentLauncher`
/// (which is `@MainActor`).
final class DaemonQueueIngestionProvider: QueueIngestionProvider {
    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let storeResolver: @Sendable (String) -> GRDBWikiStore?
    private let queueStore: QueueStore
    private let resolveSelectedProvider: @Sendable () -> AgentProvider
    private let resolveProviderConfig: @Sendable () -> AgentProvidersConfig

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        storeResolver: @escaping @Sendable (String) -> GRDBWikiStore?,
        queueStore: QueueStore,
        resolveSelectedProvider: @escaping @Sendable () -> AgentProvider,
        resolveProviderConfig: @escaping @Sendable () -> AgentProvidersConfig
    ) {
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.storeResolver = storeResolver
        self.queueStore = queueStore
        self.resolveSelectedProvider = resolveSelectedProvider
        self.resolveProviderConfig = resolveProviderConfig
    }

    // MARK: - Readiness (#440, extended #635)

    func readiness() async -> String? {
        let config = resolveProviderConfig()
        if config.enabledProviders.isEmpty {
            let msg = "Agent is not available — no enabled agent provider. Re-enable the agent in Settings → Providers to retry."
            DebugLog.ingest("DaemonQueueIngestionProvider.readiness: NO ENABLED PROVIDER (providers=\(config.providers.count))")
            return msg
        }

        let provider = resolveSelectedProvider()
        let message = AgentLauncher.readinessMessage(for: provider)
        if message != nil {
            DebugLog.ingest("DaemonQueueIngestionProvider.readiness: NOT READY provider=\(provider.id) label=\(provider.label)")
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
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID)")
        }

        guard !sourceIDs.isEmpty else {
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("DaemonQueueIngestionProvider.runIngestion: begin count=\(sourceIDs.count)")

        let launcher = await makeLauncher()

        let stateMarkdown = daemonStateMarkdown(from: store)

        var sources: [OperationRequest.StagedSource] = []
        let allSources = (try? store.listSources()) ?? []
        for sourceID in sourceIDs {
            guard let source = allSources.first(where: { $0.id == sourceID }),
                  let bytes = try? store.sourceContent(id: sourceID)
            else {
                DebugLog.ingest("DaemonQueueIngestionProvider: skipping \(sourceID.rawValue) — source or bytes missing")
                continue
            }

            let head = try? store.processedMarkdownHead(sourceID: source.id)
            let staged = Self.stagedBytesAndExt(
                for: source,
                originalBytes: bytes,
                processedMarkdownHead: head)
            if staged.ext == "md" && staged.bytes != bytes {
                DebugLog.extraction("DaemonQueueIngestionProvider: reusing markdown for \(source.filename) (\(head?.origin.rawValue ?? "?"))")
            }

            sources.append(OperationRequest.StagedSource(
                bytes: staged.bytes,
                ext: staged.ext,
                displayPath: ingestSourcePath(for: source),
                name: source.effectiveName,
                sourceID: source.id.rawValue
            ))
        }

        guard !sources.isEmpty else {
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("DaemonQueueIngestionProvider: handing off \(sources.count) source(s)")

        let providerLabel = resolveSelectedProvider().label

        await launcher.run(
            request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: SystemPrompt.defaultBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            ingestingSourceIDs: Set(sourceIDs),
            workspaceID: nil,
            queueItemID: queueItemID,
            queueStore: queueStore,
            onEvent: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission,
            providerLabel: providerLabel,
            onLock: { },
            onUnlock: { DarwinNotifier.postChange(forWikiID: wikiID) }
        )

        let results = await launcherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
    }

    // MARK: - Lint

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
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID)")
        }
        let launcher = await makeLauncher()

        DebugLog.ingest("DaemonQueueIngestionProvider.runLint: begin wikiID=\(wikiID)")

        let stateMarkdown = daemonStateMarkdown(from: store)
        let providerLabel = resolveSelectedProvider().label

        await runLintAgent(
            request: .lint(stateMarkdown: stateMarkdown),
            launcher: launcher,
            wikiID: wikiID,
            queueItemID: queueItemID,
            providerLabel: providerLabel,
            onTranscript: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission)
        let results = await launcherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
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
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID)")
        }
        let launcher = await makeLauncher()

        DebugLog.ingest("DaemonQueueIngestionProvider.runLintPages: begin wikiID=\(wikiID) pages=\(pageIDs.count)")

        let allPages = (try? store.listPages(sortBy: .lastUpdated)) ?? []
        let pages: [(id: PageID, title: String)] = pageIDs.compactMap { id in
            guard let s = allPages.first(where: { $0.id == id }) else { return nil }
            return (id: id, title: s.title)
        }

        let combinedTitle = pages.map(\.title).joined(separator: ", ")
        let stateMarkdown = daemonStateMarkdown(from: store)
        let providerLabel = resolveSelectedProvider().label

        await runLintAgent(
            request: .lintPage(
                pageTitle: combinedTitle,
                brokenLinks: [],
                stateMarkdown: stateMarkdown),
            launcher: launcher,
            wikiID: wikiID,
            queueItemID: queueItemID,
            providerLabel: providerLabel,
            onTranscript: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission)
        let results = await launcherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
    }

    // MARK: - Private

    private func makeLauncher() async -> AgentLauncher {
        await MainActor.run {
            let launcher = AgentLauncher(
                generationGate: GenerationGate(laneLimits: [.ingest: 1, .interactive: 3]),
                extractionCoordinator: extractionCoordinator)
            launcher.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
            return launcher
        }
    }

    private struct LauncherResults {
        let usage: SessionUsage?
        let logURL: URL?
        let debugURL: URL?
        let exitStatus: Int32?
        let hadTurnFailure: Bool
    }

    private func launcherResults(_ launcher: AgentLauncher) async -> LauncherResults {
        await MainActor.run {
            LauncherResults(
                usage: launcher.runTotalUsage,
                logURL: launcher.logFileURL,
                debugURL: launcher.debugFolderURL,
                exitStatus: launcher.exitStatus,
                hadTurnFailure: launcher.runHadTurnFailure)
        }
    }

    private func runLintAgent(
        request: OperationRequest,
        launcher: AgentLauncher,
        wikiID: String,
        queueItemID: String,
        providerLabel: String?,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async {
        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: SystemPrompt.defaultBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            ingestingSourceIDs: [],
            workspaceID: nil,
            queueItemID: queueItemID,
            queueStore: queueStore,
            onEvent: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission,
            providerLabel: providerLabel,
            onLock: { },
            onUnlock: { DarwinNotifier.postChange(forWikiID: wikiID) }
        )
    }

    private func daemonStateMarkdown(from store: GRDBWikiStore) -> String {
        let titles = (try? store.listPages(sortBy: .lastUpdated)) ?? []
        let indexBody = (try? store.getWikiIndex())?.body ?? WikiIndex.defaultBody
        let logEntries = (try? store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries)) ?? []
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        let bookmarks = (try? store.listBookmarkNodes()) ?? []
        let snapshot = WikiStateSnapshot.make(
            allTitles: titles.map(\.title),
            indexBody: indexBody,
            logLines: logLines,
            bookmarkNodes: bookmarks)
        return snapshot.renderStateFile()
    }

    private func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }

    /// The pure half of the staging decision: what (bytes, ext) should the
    /// staging path hand the agent for this source? Mirrors
    /// `AppQueueIngestionProvider._stagedBytesAndExt` exactly (PR2 §5.6).
    private static func stagedBytesAndExt(
        for source: SourceSummary,
        originalBytes: Data,
        processedMarkdownHead: SourceMarkdownVersion?
    ) -> (bytes: Data, ext: String) {
        let kind = ContentKind.resolve(
            mimeType: source.mimeType,
            provider: nil,
            ext: source.ext)
        guard kind.capabilities.hasFileExtractionBackend,
              let head = processedMarkdownHead,
              let markdownBytes = head.content.data(using: .utf8) else {
            return (originalBytes, source.ext)
        }
        return (markdownBytes, "md")
    }
}

#endif
