import Foundation
import WikiFSCore

/// Shared launch seam for UI surfaces that run an agent operation. The toolbar
/// sheet, file detail pane, and page-bottom query field all gather inputs the
/// same way, then delegate here so staging, mount refresh, and edit-lock behavior
/// do not drift.
@MainActor
enum AgentOperationRunner {
    static func runIngest(
        fileID: PageID,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        let stateMarkdown = store.currentStateSnapshot().renderStateFile()
        guard let file = store.ingestedFiles.first(where: { $0.id == fileID }),
              let bytes = store.ingestedSourceBytes(id: fileID)
        else { return }

        await run(
            request: .ingest(
                sourceBytes: bytes,
                ext: file.ext,
                sourcePath: ingestSourcePath(for: file),
                stateMarkdown: stateMarkdown),
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider)
    }

    /// Bring the wiki up to date with one tracked repository.
    ///
    /// Mirrors `runIngest`, with the one structural difference that defines the
    /// feature: there are no source bytes to stage, so this gathers the git facts
    /// FIRST — head, ancestry, commit range, diff, file list — decides the
    /// `RepoSyncPlan` from them, and stages that as `REPO_STATE.md`. The plan is
    /// computed here rather than in the tracker because the tracker's view can be
    /// minutes stale by the time a queued repo actually runs.
    ///
    /// Returns once the run has STARTED; the launcher streams it from there.
    static func runRepoIngest(
        repo: TrackedRepo,
        tracker: RepoTracker,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        guard let wikiID = manager.activeWikiID else { return }
        guard let head = repo.headCommit, !head.isEmpty else {
            tracker.recordError("Not cloned yet — fetch this repository first.", for: repo.id)
            return
        }
        guard let directory = try? RepoCheckoutLocation.directory(
            wikiID: wikiID, repoID: repo.id.rawValue),
            FileManager.default.fileExists(atPath: directory.path)
        else {
            tracker.recordError("The local checkout is missing. Remove and re-add.", for: repo.id)
            return
        }

        let path = directory.path
        do {
            let snapshot = try await repoSnapshot(repo: repo, head: head, path: path)
            guard snapshot.plan.hasWork else {
                tracker.clearActivity(for: repo.id)
                return
            }
            await run(
                request: .repoIngest(
                    repoName: repo.name,
                    repoPath: path,
                    stateMarkdown: store.currentStateSnapshot().renderStateFile(),
                    repoStateMarkdown: snapshot.renderStateFile(),
                    plan: snapshot.plan),
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        } catch {
            tracker.recordError("\(error)", for: repo.id)
        }
    }

    /// Collect the git facts for one repo pass and fold them into the staged
    /// snapshot. Every command comes from `GitCommandPlan`; the ONLY judgement
    /// here is the ancestry probe, which is what distinguishes "10 new commits"
    /// from "history was rewritten and the range is meaningless".
    private static func repoSnapshot(
        repo: TrackedRepo,
        head: String,
        path: String
    ) async throws -> RepoStateSnapshot {
        let trackedFiles = try await GitRunner.lines(GitCommandPlan.listFiles(at: path))
        let watermark = repo.lastIngestedCommit.flatMap { $0.isEmpty ? nil : $0 }

        var continuous = false
        var changedFiles: [String] = []
        if let watermark, watermark != head {
            continuous = await GitRunner.succeeds(
                GitCommandPlan.isAncestor(at: path, ancestor: watermark, descendant: head))
            if continuous {
                changedFiles = try await GitRunner.lines(
                    GitCommandPlan.changedFiles(at: path, from: watermark, to: head))
            }
        }

        let plan = RepoSyncPlan.decide(
            headCommit: head,
            lastIngestedCommit: watermark,
            historyIsContinuous: continuous,
            changedFileCount: changedFiles.count,
            trackedFileCount: trackedFiles.count)

        // An incremental pass describes the RANGE; a first (or post-force-push)
        // pass describes the checkout as it stands.
        let isIncremental: Bool
        if case .incremental = plan { isIncremental = true } else { isIncremental = false }
        let from = isIncremental ? watermark : nil

        let commitLines = try await GitRunner.lines(
            GitCommandPlan.logRange(
                at: path, from: from, to: head,
                limit: RepoStateSnapshot.maxListedCommits + 1))
        let diffStat: String? = isIncremental && from != nil
            ? try? await GitRunner.run(GitCommandPlan.diffStat(at: path, from: from!, to: head))
            : nil
        let committedAt = try? await GitRunner.run(GitCommandPlan.commitDate(at: path, ref: head))

        return RepoStateSnapshot.make(
            name: repo.name,
            remoteURL: repo.remoteURL,
            branch: repo.branch,
            clonePath: path,
            headCommit: head,
            headCommittedAt: committedAt,
            lastIngestedCommit: watermark,
            allCommitLines: commitLines,
            diffStat: diffStat,
            allFiles: isIncremental ? changedFiles : trackedFiles,
            trackedFileCount: trackedFiles.count,
            plan: plan)
    }

    static func runQuery(
        question: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await run(
            request: .query(
                question: trimmed,
                stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider)
    }

    static func startQueryConversation(
        firstMessage: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let wikiID = manager.activeWikiID else { return }

        await fileProvider.signalChange()
        guard let root = fileProvider.path else { return }

        launcher.startInteractiveQuery(
            firstMessage: trimmed,
            stateMarkdown: store.currentStateSnapshot().renderStateFile(),
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            repos: store.repoContexts(wikiID: wikiID),
            onLock: { store.beginAgentRun() },
            onUnlock: { store.endAgentRun() }
        )
    }

    static func runLint(
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        await run(
            request: .lint(stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider)
    }

    private static func run(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        guard let wikiID = manager.activeWikiID else { return }

        switch request {
        case .ingest, .repoIngest:
            break
        case .query, .lint:
            await fileProvider.signalChange()
        }
        let root: String
        if let resolvedRoot = fileProvider.path {
            root = resolvedRoot
        } else if case .ingest = request {
            // Ingest stages both the raw source bytes and WIKI_STATE.md from SQLite,
            // so it can proceed even if the File Provider mount URL is still being
            // resolved. Query/Lint keep requiring the mount for raw-file reads.
            root = ""
        } else if case .repoIngest = request {
            // Same reasoning: a repo pass reads the checkout and the two staged
            // state files, all on real local disk. Requiring the mount would make
            // unattended updates fail whenever the domain is still settling.
            root = ""
        } else {
            return
        }

        launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            repos: store.repoContexts(wikiID: wikiID),
            onLock: { store.beginAgentRun() },
            onUnlock: { store.endAgentRun() }
        )
    }

    private static func ingestSourcePath(for file: IngestedFileSummary) -> String {
        let leaf = FilenameEscaping.byIDIngestedFilename(fileID: file.id.rawValue, ext: file.ext)
        return "files/by-id/\(leaf)"
    }
}
