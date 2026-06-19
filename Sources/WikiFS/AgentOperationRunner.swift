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
        DebugLog.ingest("runIngest: begin fileID=\(fileID.rawValue)")
        // Mark this file as "being operated on" for the whole operation (local
        // conversion + agent run). `finish()` clears it when the agent ends.
        launcher.ingestingFileID = fileID
        let stateMarkdown = store.currentStateSnapshot().renderStateFile()
        guard let file = store.ingestedFiles.first(where: { $0.id == fileID }),
              let bytes = store.ingestedSourceBytes(id: fileID)
        else {
            launcher.ingestingFileID = nil
            DebugLog.ingest("runIngest: ABORT — file or source bytes missing for \(fileID.rawValue)")
            return
        }
        DebugLog.ingest("runIngest: file=\(file.filename) ext=\(file.ext) bytes=\(bytes.count)")

        // If the source is a PDF, try to convert it to Markdown locally via
        // docling before the agent ever sees it.  Skip if pdf2md isn't ready.
        // Show a simple status line in the activity area — docling doesn't
        // stream per-page progress, so we animate dots as proof of life.
        var sourceBytes = bytes
        var sourceExt = file.ext
        if file.ext == "pdf" {
            launcher.extractionLog = ""
            DebugLog.extraction("checkReady: probing…")
            if await PdfExtractionService.checkReady() {
                DebugLog.extraction("checkReady: ready — converting \(file.filename)")
                launcher.isExtracting = true
                launcher.extractionPID = nil
                launcher.extractionLog = ""
                defer {
                    launcher.isExtracting = false
                    launcher.extractionPID = nil
                }
                do {
                    let markdown = try await PdfExtractionService.convert(
                        pdfData: bytes,
                        filename: file.filename,
                        onProgress: { line in
                            Task { @MainActor in launcher.extractionLog.append(line) }
                        },
                        onStart: { pid in
                            Task { @MainActor in
                                launcher.extractionPID = pid
                                launcher.extractionLog.append("Started pdf2md (pid \(pid)).\n")
                            }
                        })
                    sourceBytes = markdown.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    DebugLog.extraction("convert: done — \(markdown.count) chars of markdown")
                    launcher.extractionLog.append("PDF conversion done — \(markdown.count) chars extracted.\n")
                } catch {
                    // A cancelled conversion terminates the subprocess, which throws —
                    // treat that as a user cancel and abort the ingest entirely.
                    if Task.isCancelled {
                        DebugLog.extraction("convert: CANCELLED — aborting ingest")
                        launcher.extractionLog.append("PDF conversion cancelled.\n")
                        launcher.ingestingFileID = nil
                        return
                    }
                    let msg = error.localizedDescription
                    DebugLog.extraction("convert: FAILED — \(msg)")
                    launcher.extractionLog.append("PDF conversion: \(msg)\n")
                }
            } else {
                DebugLog.extraction("checkReady: NOT ready — sending raw PDF to agent")
                launcher.extractionLog = "PDF extraction not ready — ~2 GB deps need downloading first."
            }
        }
        DebugLog.ingest("runIngest: handing off to agent (ext=\(sourceExt), bytes=\(sourceBytes.count))")

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

        // If the agent never actually started (preflight/staging failure, or no
        // active wiki), no `finish()` will clear the marker — reconcile here.
        if !launcher.isRunning && launcher.runningKind != .ingest {
            launcher.ingestingFileID = nil
        }
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
