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

        // If the source is a PDF, try to convert it to Markdown locally via
        // docling before the agent ever sees it.  Skip if pdf2md isn't ready.
        // Show a simple status line in the activity area — docling doesn't
        // stream per-page progress, so we animate dots as proof of life.
        var sourceBytes = bytes
        var sourceExt = file.ext
        if file.ext == "pdf" {
            launcher.extractionLog = ""
            if await PdfExtractionService.checkReady() {
                launcher.extractionLog = "Converting PDF"
                // Animate dots while conversion runs.
                let dotTask = Task { @MainActor in
                    for _ in 0... {
                        guard !Task.isCancelled else { break }
                        try? await Task.sleep(for: .seconds(1))
                        launcher.extractionLog.append(".")
                    }
                }
                do {
                    let markdown = try await PdfExtractionService.convert(
                        pdfData: bytes, filename: file.filename)
                    dotTask.cancel()
                    sourceBytes = markdown.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    launcher.extractionLog = "PDF conversion done — \(markdown.count) chars extracted."
                } catch {
                    dotTask.cancel()
                    let msg = error.localizedDescription
                    print("[pdf2md] \(msg)")
                    launcher.extractionLog = "PDF conversion: \(msg)"
                }
            } else {
                launcher.extractionLog = "PDF extraction not ready — ~2 GB deps need downloading first."
            }
        }

        await run(
            request: .ingest(
                sourceBytes: sourceBytes,
                ext: sourceExt,
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
        case .ingest:
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
        } else {
            return
        }

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
