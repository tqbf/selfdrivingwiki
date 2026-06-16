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

        await fileProvider.signalChange()
        guard let root = fileProvider.path else { return }

        launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            onLock: { store.beginAgentRun() },
            onUnlock: { store.endAgentRun() }
        )
    }

    private static func ingestSourcePath(for file: IngestedFileSummary) -> String {
        let leaf = FilenameEscaping.byIDIngestedFilename(fileID: file.id.rawValue, ext: file.ext)
        return "files/by-id/\(leaf)"
    }
}
