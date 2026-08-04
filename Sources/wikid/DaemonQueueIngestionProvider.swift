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
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?
    private let queueStore: QueueStore
    private let resolveSelectedProvider: @Sendable () -> AgentProvider
    private let resolveProviderConfig: @Sendable () -> AgentProvidersConfig

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
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
        let loginShellPath = await PathPreflight.loginShellPATH()
        let message = AgentLauncher.readinessMessage(
            for: provider,
            searchPath: loginShellPath)
        if message != nil {
            DebugLog.ingest("DaemonQueueIngestionProvider.readiness: NOT READY provider=\(provider.id) label=\(provider.label)")
        }
        return message
    }

    // MARK: - QueueIngestionProvider

    func runIngestion(
        wikiID: WikiID,
        sourceIDs: [SourceID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID.rawValue)")
        }

        guard !sourceIDs.isEmpty else {
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("Queue trace=\(queueItemID.rawValue) stage=daemon-provider event=started wiki=\(wikiID.rawValue) sources=\(sourceIDs.count)")

        let launcher = await makeLauncher()

        let stateMarkdown = daemonStateMarkdown(from: store)

        var sources: [OperationRequest.StagedSource] = []
        let allSources = (DebugLog.trying("listSources", operation: { try store.listSources() })) ?? []
        for sourceID in sourceIDs {
            guard let source = allSources.first(where: { $0.id == sourceID }),
                  let bytes = DebugLog.trying("sourceContent", operation: { try store.sourceContent(id: sourceID) })
            else {
                DebugLog.ingest("DaemonQueueIngestionProvider: skipping \(sourceID.rawValue) — source or bytes missing")
                continue
            }

            let head = DebugLog.trying("processedMarkdownHead", operation: { try store.processedMarkdownHead(sourceID: source.id) })
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
                sourceID: source.id
            ))
        }

        guard !sources.isEmpty else {
            throw QueueIngestionError.noSources
        }

        DebugLog.ingest("Queue trace=\(queueItemID.rawValue) stage=daemon-provider event=handoff wiki=\(wikiID.rawValue) target=launcher sources=\(sources.count)")

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
            onUnlock: { DarwinNotifier.postChange(forWikiID: wikiID.rawValue) }
        )

        let results = try await completedLauncherResults(launcher)
        DebugLog.ingest("Queue trace=\(queueItemID.rawValue) stage=daemon-provider event=launcher-returned wiki=\(wikiID.rawValue) exitStatus=\(results.exitStatus.map(String.init) ?? "nil") turnFailed=\(results.hadTurnFailure)")
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
    }

    // MARK: - Lint

    func runLint(
        wikiID: WikiID,
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID.rawValue)")
        }
        let launcher = await makeLauncher()

        DebugLog.ingest("DaemonQueueIngestionProvider.runLint: begin wikiID=\(wikiID.rawValue)")

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
        let results = try await completedLauncherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
    }

    func runLintPages(
        wikiID: WikiID,
        pageIDs: [PageID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID.rawValue)")
        }
        let launcher = await makeLauncher()

        DebugLog.ingest("DaemonQueueIngestionProvider.runLintPages: begin wikiID=\(wikiID.rawValue) pages=\(pageIDs.count)")

        let allPages = (DebugLog.trying("listPages", operation: { try store.listPages(sortBy: .lastUpdated) })) ?? []
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
        let results = try await completedLauncherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The agent turn exceeded the time ceiling or failed unexpectedly (exit status \(status)).")
        }
    }

    // MARK: - Tracked repositories

    func runRepositoryWork(
        wikiID: WikiID,
        request: RepositoryWorkRequest,
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            throw QueueIngestionError.spawnFailed("No store for wikiID=\(wikiID.rawValue)")
        }

        if request.action == .update,
           let error = resolveProviderConfig().agentOperationConfigurationError(
               forStages: [ACPIngestStage.planner.rawValue]) {
            throw QueueIngestionError.notReady(error)
        }

        switch request.action {
        case .clone:
            _ = try await clone(
                repositoryID: request.repositoryID,
                wikiID: wikiID,
                store: store,
                onProgress: onProgress)
        case .fetch:
            _ = try await fetch(
                repositoryID: request.repositoryID,
                wikiID: wikiID,
                store: store,
                onProgress: onProgress)
        case .update:
            let repository = try await fetch(
                repositoryID: request.repositoryID,
                wikiID: wikiID,
                store: store,
                onProgress: onProgress)
            try await updateWiki(
                repository: repository,
                wikiID: wikiID,
                store: store,
                queueItemID: queueItemID,
                onProgress: onProgress,
                onTranscript: onTranscript,
                onUsage: onUsage,
                onLiveUsage: onLiveUsage,
                onLogPaths: onLogPaths,
                onPendingPermission: onPendingPermission)
        }

        // Repository metadata mutations deliberately use no per-row event: a
        // checkout is not a File Provider resource. Publish the existing coarse
        // cross-process change instead, so the app refreshes its model projection.
        if request.action != .update {
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
        }
    }

    // MARK: - Private

    private func clone(
        repositoryID: TrackedRepoID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> TrackedRepo {
        let repository = try store.getRepo(id: repositoryID)
        let checkout = try DaemonRepoCheckout.directory(wikiID: wikiID, repositoryID: repository.id)
        if DaemonRepoCheckout.exists(checkout) {
            guard repository.branch != nil else {
                throw QueueIngestionError.spawnFailed(
                    "Repository checkout already exists before the initial clone completed: \(repository.name)")
            }
            return try await fetch(
                repositoryID: repositoryID, wikiID: wikiID, store: store, onProgress: onProgress)
        }

        onProgress("Cloning \(repository.name)…")
        _ = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.clone(
                remote: repository.remoteURL,
                into: checkout.path,
                branch: repository.branch))
        let branch = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.currentBranch(at: checkout.path))
        let head = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.revParse(at: checkout.path, ref: "HEAD"))
        try store.setRepoBranch(id: repository.id, branch: branch)
        try store.updateRepoSync(id: repository.id, headCommit: head, fetchedAt: Date())
        onProgress("Cloned \(repository.name) at \(String(head.prefix(7)))")
        return try store.getRepo(id: repository.id)
    }

    private func fetch(
        repositoryID: TrackedRepoID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> TrackedRepo {
        var repository = try store.getRepo(id: repositoryID)
        guard repository.branch != nil else {
            repository = try await clone(
                repositoryID: repositoryID, wikiID: wikiID, store: store, onProgress: onProgress)
            return repository
        }
        let checkout = try DaemonRepoCheckout.directory(wikiID: wikiID, repositoryID: repository.id)
        guard DaemonRepoCheckout.exists(checkout) else {
            throw QueueIngestionError.spawnFailed(
                "Repository checkout is missing for \(repository.name). Retry the clone.")
        }
        guard let branch = repository.branch else {
            throw QueueIngestionError.spawnFailed("Repository branch is unavailable for \(repository.name)")
        }
        onProgress("Fetching \(repository.name)…")
        _ = try await DaemonGitRunner.requireSuccess(GitCommandPlan.fetch(at: checkout.path))
        let head = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.revParse(at: checkout.path, ref: "origin/\(branch)"))
        _ = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.resetHard(at: checkout.path, to: head))
        try store.updateRepoSync(id: repository.id, headCommit: head, fetchedAt: Date())
        onProgress("Fetched \(repository.name) at \(String(head.prefix(7)))")
        return try store.getRepo(id: repository.id)
    }

    private func updateWiki(
        repository: TrackedRepo,
        wikiID: WikiID,
        store: GRDBWikiStore,
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        guard let branch = repository.branch, let head = repository.headCommit else {
            throw QueueIngestionError.spawnFailed("Repository clone did not produce a branch and head commit")
        }
        let checkout = try DaemonRepoCheckout.directory(wikiID: wikiID, repositoryID: repository.id)
        let files = lines(try await DaemonGitRunner.requireSuccess(GitCommandPlan.listFiles(at: checkout.path)))
        let historyIsContinuous: Bool
        if let last = repository.lastIngestedCommit {
            historyIsContinuous = try await DaemonGitRunner.run(
                GitCommandPlan.isAncestor(at: checkout.path, ancestor: last, descendant: head)).status == 0
        } else {
            historyIsContinuous = true
        }
        let changedFiles: [String]
        let commits: [String]
        let diffStat: String?
        if let last = repository.lastIngestedCommit, last != head, historyIsContinuous {
            changedFiles = lines(try await DaemonGitRunner.requireSuccess(
                GitCommandPlan.changedFiles(at: checkout.path, from: last, to: head)))
            commits = lines(try await DaemonGitRunner.requireSuccess(
                GitCommandPlan.logRange(at: checkout.path, from: last, to: head, limit: RepoStateSnapshot.maxListedCommits)))
            diffStat = try await DaemonGitRunner.requireSuccess(
                GitCommandPlan.diffStat(at: checkout.path, from: last, to: head))
        } else {
            changedFiles = files
            commits = lines(try await DaemonGitRunner.requireSuccess(
                GitCommandPlan.logRange(at: checkout.path, from: nil, to: head, limit: RepoStateSnapshot.maxListedCommits)))
            diffStat = nil
        }

        let plan = RepoSyncPlan.decide(
            headCommit: head,
            lastIngestedCommit: repository.lastIngestedCommit,
            historyIsContinuous: historyIsContinuous,
            changedFileCount: changedFiles.count,
            trackedFileCount: files.count)
        guard plan.hasWork else {
            onProgress("\(repository.name) is already up to date")
            return
        }

        let committedAt = try await DaemonGitRunner.requireSuccess(
            GitCommandPlan.commitDate(at: checkout.path, ref: head))
        let snapshot = RepoStateSnapshot.make(
            name: repository.name,
            remoteURL: repository.remoteURL,
            branch: branch,
            clonePath: checkout.path,
            headCommit: head,
            headCommittedAt: committedAt,
            lastIngestedCommit: repository.lastIngestedCommit,
            allCommitLines: commits,
            diffStat: diffStat,
            allFiles: plan == .upToDate ? [] : (plan.tier == .opusCurator ? changedFiles : files),
            trackedFileCount: files.count,
            plan: plan)
        let readerWorkPlan = RepoReaderWorkPlan.make(paths: changedFiles)
        let readerDigests: String?
        if plan.tier == .opusCurator, readerWorkPlan.isEligibleForReaderFanout {
            readerDigests = try await runReaderFanout(
                repository: repository,
                wikiID: wikiID,
                repoStateMarkdown: snapshot.renderStateFile(),
                workPlan: readerWorkPlan,
                onTranscript: onTranscript)
        } else {
            readerDigests = nil
        }

        onProgress("Updating the wiki from \(repository.name)…")
        let launcher = await makeLauncher()
        await launcher.run(
            request: .repositoryUpdate(
                stateMarkdown: daemonStateMarkdown(from: store),
                repoStateMarkdown: snapshot.renderStateFile(),
                checkoutPath: checkout.path,
                repositoryName: repository.name,
                headCommit: head,
                readerDigestsMarkdown: readerDigests),
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: SystemPrompt.defaultBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            queueItemID: queueItemID,
            queueStore: queueStore,
            onEvent: onTranscript,
            onLiveUsage: onLiveUsage,
            onPendingPermission: onPendingPermission,
            providerLabel: resolveSelectedProvider().label,
            onLock: { },
            onUnlock: { DarwinNotifier.postChange(forWikiID: wikiID.rawValue) })
        let results = try await completedLauncherResults(launcher)
        onUsage?(results.usage)
        onLogPaths?(results.logURL, results.debugURL)
        if let status = results.exitStatus, status != 0, results.hadTurnFailure {
            throw QueueIngestionError.spawnFailed(
                "The repository curator failed unexpectedly (exit status \(status)).")
        }
    }

    private func runReaderFanout(
        repository: TrackedRepo,
        wikiID: WikiID,
        repoStateMarkdown: String,
        workPlan: RepoReaderWorkPlan,
        onTranscript: (@Sendable (AgentEvent) -> Void)?
    ) async throws -> String {
        guard workPlan.isEligibleForReaderFanout else {
            throw QueueIngestionError.spawnFailed(
                "Repository fan-out requires two or more nonempty reader allowlists")
        }

        let digests = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for assignment in workPlan.assignments {
                onTranscript?(.subagent(
                    subagentType: "repo-reader",
                    description: "\(repository.name) reader \(assignment.ordinal)",
                    isCompletion: false))
                group.addTask { [self] in
                    let launcher = await makeLauncher()
                    try Task.checkCancellation()
                    try await withTaskCancellationHandler {
                        await launcher.run(
                            request: .repositoryReader(
                                repoStateMarkdown: repoStateMarkdown,
                                checkoutPath: try DaemonRepoCheckout.directory(
                                    wikiID: wikiID, repositoryID: repository.id).path,
                                assignedPaths: assignment.paths),
                            wikiID: wikiID,
                            wikiRoot: "",
                            systemPrompt: RepoReaderAgent.prompt,
                            wikictlDirectory: HelpersLocation.wikictlDirectory,
                            onLock: { },
                            onUnlock: { })
                    } onCancel: {
                        Task { @MainActor in
                            launcher.stopAgent()
                        }
                    }
                    try Task.checkCancellation()
                    let results = try await completedLauncherResults(launcher)
                    if let status = results.exitStatus, status != 0 {
                        throw QueueIngestionError.spawnFailed(
                            "Repository reader \(assignment.ordinal) failed (exit status \(status)).")
                    }
                    let digest = await MainActor.run {
                        launcher.events.compactMap { event -> String? in
                            switch event {
                            case .assistantText(let text): return text
                            case .result(let isError, let text): return isError ? nil : text
                            default: return nil
                            }
                        }.joined(separator: "\n")
                    }
                    guard !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw QueueIngestionError.spawnFailed(
                            "Repository reader \(assignment.ordinal) returned no digest.")
                    }
                    return (assignment.ordinal, digest)
                }
            }
            var result: [(Int, String)] = []
            for try await digest in group {
                onTranscript?(.subagent(
                    subagentType: "repo-reader",
                    description: "\(repository.name) reader \(digest.0)",
                    isCompletion: true))
                result.append(digest)
            }
            return result
        }
        return digests.sorted { $0.0 < $1.0 }.map { ordinal, digest in
            "## Reader \(ordinal)\n\n\(digest)"
        }.joined(separator: "\n\n")
    }

    private func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
    }

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
        let preflightError: String?
    }

    private func launcherResults(_ launcher: AgentLauncher) async -> LauncherResults {
        await MainActor.run {
            LauncherResults(
                usage: launcher.runTotalUsage,
                logURL: launcher.logFileURL,
                debugURL: launcher.debugFolderURL,
                exitStatus: launcher.exitStatus,
                hadTurnFailure: launcher.runHadTurnFailure,
                preflightError: launcher.preflightError)
        }
    }

    /// Queue items must not report completion when the launcher refused to
    /// start. Preflight failures are configuration errors the user can fix.
    private func completedLauncherResults(_ launcher: AgentLauncher) async throws -> LauncherResults {
        let results = await launcherResults(launcher)
        if let preflightError = results.preflightError, !preflightError.isEmpty {
            throw QueueIngestionError.notReady(preflightError)
        }
        return results
    }

    private func runLintAgent(
        request: OperationRequest,
        launcher: AgentLauncher,
        wikiID: WikiID,
        queueItemID: QueueItem.ID,
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
            onUnlock: { DarwinNotifier.postChange(forWikiID: wikiID.rawValue) }
        )
    }

    private func daemonStateMarkdown(from store: GRDBWikiStore) -> String {
        DaemonWikiState.stateMarkdown(from: store)
    }

    private func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id, ext: source.ext)
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
