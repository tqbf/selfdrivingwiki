import Foundation
import WikiFSCore

/// Shared launch seam for UI surfaces that run an agent operation. The toolbar
/// sheet, file detail pane, and page-bottom query field all gather inputs the
/// same way, then delegate here so staging, mount refresh, and edit-lock behavior
/// do not drift.
@MainActor
enum AgentOperationRunner {
    /// Ingest a single file via the existing detail-view path. Builds a
    /// single-element `[StagedSource]` and delegates to `runIngestSources`.
    static func runIngest(
        sourceID: PageID,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        await runMultiIngest(
            fileIDs: [sourceID],
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider)
    }

    /// Ingest multiple files in a SINGLE agent run. All sources are staged together
    /// as `source-1.<ext>`, `source-2.<ext>`, … — the agent reads them all,
    /// cross-references, and writes pages/index/log in one pass.
    static func runMultiIngest(
        fileIDs: [PageID],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        guard !fileIDs.isEmpty else { return }
        DebugLog.ingest("runMultiIngest: begin count=\(fileIDs.count)")

        // NOTE: `ingestingFileIDs` (the agent-phase flag) is NOT set here. It is
        // assigned at spawn commit inside `AgentLauncher.run` (around `onLock`),
        // so a pure extraction or a queued ingest never mislabels rows as
        // "Ingesting…" or greys out a peer's Ingest button. The extraction-phase
        // flag (`extractingFileIDs`) is set around the pdf2md block below.
        let stateMarkdown = store.currentStateSnapshot().renderStateFile()

        var sources: [OperationRequest.StagedSource] = []
        for fileID in fileIDs {
            guard let file = store.sources.first(where: { $0.id == fileID }),
                  let bytes = store.sourceBytes(id: fileID)
            else {
                DebugLog.ingest("runMultiIngest: skipping \(fileID.rawValue) — file or bytes missing")
                continue
            }
            DebugLog.ingest("runMultiIngest: file=\(file.filename) ext=\(file.ext) bytes=\(bytes.count)")

            var sourceBytes = bytes
            var sourceExt = file.ext

            // PDF → Markdown: if markdown was already extracted (via the standalone
            // "Extract Markdown" button or a prior ingest), reuse it — don't re-run
            // pdf2md. Only extract when no processed markdown exists yet.
            if file.mimeType == "application/pdf" {
                if let head = store.processedMarkdownHead(for: file) {
                    // Already extracted — use existing markdown, skip pdf2md entirely.
                    sourceBytes = head.content.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    DebugLog.extraction("runMultiIngest: reusing existing markdown for \(file.filename) — \(head.content.count) chars")
                } else {
                let acquired = await launcher.awaitExtractionSlot()
                guard acquired, !Task.isCancelled else {
                    // Cancelled while queued for the extraction slot (or never
                    // acquired) — own nothing, just bail this ingest.
                    if acquired { launcher.releaseExtractionSlot() }
                    return
                }
                launcher.extractingFileIDs.insert(file.id)
                defer {
                    launcher.extractingFileIDs.remove(file.id)
                    launcher.releaseExtractionSlot()
                }
                launcher.extractionLog = ""
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
                        DebugLog.extraction("convert: done — \(markdown.count) chars")
                        launcher.extractionLog.append("PDF conversion done — \(markdown.count) chars extracted.\n")
                        // Persist extracted markdown as v1 in the version chain.
                        // Double-seed guard: if a head already exists, reuse it.
                        store.seedPdfMarkdown(for: file.id, content: markdown)
                    } catch {
                        if Task.isCancelled {
                            DebugLog.extraction("convert: CANCELLED")
                            // The `defer` above removes this file's id and releases
                            // the slot; also clear the whole set as a belt-and-
                            // suspenders (the slot serializes, so it holds at most
                            // this one id) to preserve the old cancel-clears-state
                            // behavior.
                            launcher.extractingFileIDs = []
                            return
                        }
                        DebugLog.extraction("convert: FAILED — \(error.localizedDescription)")
                        launcher.extractionLog.append("PDF conversion: \(error.localizedDescription)\n")
                    }
                } else {
                    launcher.extractionLog = "PDF extraction not ready — sending raw PDF to agent."
                }
                } // end else (no existing markdown → extract)
            } // end if file.ext == "pdf"

            sources.append(OperationRequest.StagedSource(
                bytes: sourceBytes,
                ext: sourceExt,
                displayPath: ingestSourcePath(for: file)))
        }

        guard !sources.isEmpty else {
            // No spawn will commit, so the agent-phase flag stays empty. The
            // extraction-phase flag was already cleared per-iteration by the
            // `defer` above. Nothing to clear here but keep the abort log.
            DebugLog.ingest("runMultiIngest: ABORT — no valid sources after filtering")
            return
        }

        DebugLog.ingest("runMultiIngest: handing off \(sources.count) source(s), totalBytes=\(sources.reduce(0) { $0 + $1.bytes.count })")
        await run(
            request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider,
            ingestingFileIDs: Set(fileIDs))

        // If the ingest Task was cancelled while queued for the spawn slot (behind a
        // running query), `launcher.run` returned without spawning and never set
        // `ingestingFileIDs` (it's assigned at spawn commit). Clear whichever phase
        // flags might be set as a belt-and-suspenders so the file row never hangs.
        // Already-extracted markdown was seeded before this call and is preserved.
        if Task.isCancelled {
            launcher.ingestingFileIDs = []
            launcher.extractingFileIDs = []
            return
        }

        if !launcher.isRunning && launcher.runningKind != .ingest {
            launcher.ingestingFileIDs = []
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

        await launcher.startInteractiveQuery(
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
        fileProvider: FileProviderSpike,
        ingestingFileIDs: Set<PageID> = []
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

        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            ingestingFileIDs: ingestingFileIDs,
            onLock: { store.beginAgentRun() },
            onUnlock: { store.endAgentRun() }
        )
    }

    private static func ingestSourcePath(for file: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: file.id.rawValue, ext: file.ext)
        return "files/by-id/\(leaf)"
    }
}
