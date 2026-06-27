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
        fileProvider: FileProviderSpike,
        extractionCoordinator: ExtractionCoordinator
    ) async {
        await runMultiIngest(
            sourceIDs: [sourceID],
            launcher: launcher,
            store: store,
            manager: manager,
            fileProvider: fileProvider,
            extractionCoordinator: extractionCoordinator)
    }

    /// Ingest multiple files in a SINGLE agent run. All sources are staged together
    /// as `source-1.<ext>`, `source-2.<ext>`, … — the agent reads them all,
    /// cross-references, and writes pages/index/log in one pass.
    static func runMultiIngest(
        sourceIDs: [PageID],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike,
        extractionCoordinator: ExtractionCoordinator
    ) async {
        guard !sourceIDs.isEmpty else { return }
        DebugLog.ingest("runMultiIngest: begin count=\(sourceIDs.count)")

        // NOTE: `ingestingSourceIDs` (the agent-phase flag) is NOT set here. It is
        // assigned at spawn commit inside `AgentLauncher.run` (around `onLock`),
        // so a pure extraction or a queued ingest never mislabels rows as
        // "Ingesting…" or greys out a peer's Ingest button. The extraction-phase
        // flag (`extractingSourceIDs`) is set around the pdf2md block below.
        let stateMarkdown = store.currentStateSnapshot().renderStateFile()

        // Resolve the selected backend once — it won't change mid-run. Every
        // backend (local pdf2md / Claude / Docling Serve) goes through the same
        // `readiness()` + `convert()` contract, so this path is backend-agnostic.
        let extractor = extractionCoordinator.current()
        DebugLog.ingest("runMultiIngest: backend=\(extractor.displayName)")

        var sources: [OperationRequest.StagedSource] = []
        for sourceID in sourceIDs {
            guard let source = store.sources.first(where: { $0.id == sourceID }),
                  let bytes = store.sourceBytes(id: sourceID)
            else {
                DebugLog.ingest("runMultiIngest: skipping \(sourceID.rawValue) — source or bytes missing")
                continue
            }
            DebugLog.ingest("runMultiIngest: source=\(source.filename) ext=\(source.ext) bytes=\(bytes.count)")

            var sourceBytes = bytes
            var sourceExt = source.ext

            // PDF → Markdown: if markdown was already extracted (via the standalone
            // "Extract Markdown" button or a prior ingest), reuse it — don't re-run
            // pdf2md. Only extract when no processed markdown exists yet.
            if source.mimeType == "application/pdf" {
                if let head = store.processedMarkdownHead(for: source) {
                    // Already extracted — use existing markdown, skip pdf2md entirely.
                    sourceBytes = head.content.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    DebugLog.extraction("runMultiIngest: reusing existing markdown for \(source.filename) — \(head.content.count) chars")
                } else {
                let acquired = await launcher.awaitExtractionSlot()
                guard acquired, !Task.isCancelled else {
                    // Cancelled while queued for the extraction slot (or never
                    // acquired) — own nothing, just bail this ingest.
                    if acquired { launcher.releaseExtractionSlot() }
                    return
                }
                launcher.extractingSourceIDs.insert(source.id)
                defer {
                    launcher.extractingSourceIDs.remove(source.id)
                    launcher.releaseExtractionSlot()
                }
                switch await extractor.readiness() {
                case .ready:
                    DebugLog.extraction("readiness: ready — converting \(source.filename) via \(extractor.displayName)")
                    launcher.isExtracting = true
                    launcher.extractionPID = nil
                    launcher.extractionLog = ""
                    defer {
                        launcher.isExtracting = false
                        launcher.extractionPID = nil
                    }
                    do {
                        // No `onStart(pid:)` here — the protocol is PID-free.
                        // Only the local backend has a PID, and it reports it via
                        // the `onProgress` line; remote/model backends have none,
                        // so the sidebar just shows "Converting…".
                        let markdown = try await extractor.convert(
                            pdfData: bytes,
                            filename: source.filename,
                            onProgress: { line in
                                Task { @MainActor in launcher.extractionLog.append(line) }
                            })
                        sourceBytes = markdown.data(using: .utf8) ?? bytes
                        sourceExt = "md"
                        DebugLog.extraction("convert: done — \(markdown.count) chars")
                        launcher.extractionLog.append("PDF conversion done — \(markdown.count) chars extracted.\n")
                        // Persist extracted markdown as v1 in the version chain.
                        // Double-seed guard: if a head already exists, reuse it.
                        store.seedPdfMarkdown(for: source.id, content: markdown)
                    } catch {
                        if Task.isCancelled {
                            DebugLog.extraction("convert: CANCELLED")
                            // The `defer` above removes this file's id and releases
                            // the slot; also clear the whole set as a belt-and-
                            // suspenders (the slot serializes, so it holds at most
                            // this one id) to preserve the old cancel-clears-state
                            // behavior.
                            launcher.extractingSourceIDs = []
                            return
                        }
                        DebugLog.extraction("convert: FAILED — \(error.localizedDescription)")
                        launcher.extractionLog.append("PDF conversion: \(error.localizedDescription)\n")
                    }
                case .needsSetup(let message), .notInstalled(let message):
                    // Backend unconfigured (no API key / endpoint) or the local
                    // deps aren't installed — show the reason and fall through so
                    // the raw PDF is sent to the agent as-is.
                    DebugLog.extraction("readiness: not ready — \(message)")
                    launcher.extractionLog = message
                }
                } // end else (no existing markdown → extract)
            } // end if source.mimeType == "application/pdf"

            sources.append(OperationRequest.StagedSource(
                bytes: sourceBytes,
                ext: sourceExt,
                displayPath: ingestSourcePath(for: source)))
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
            ingestingSourceIDs: Set(sourceIDs))

        // If the ingest Task was cancelled while queued for the spawn slot (behind a
        // running query), `launcher.run` returned without spawning and never set
        // `ingestingSourceIDs` (it's assigned at spawn commit). Clear whichever phase
        // flags might be set as a belt-and-suspenders so the file row never hangs.
        // Already-extracted markdown was seeded before this call and is preserved.
        if Task.isCancelled {
            launcher.ingestingSourceIDs = []
            launcher.extractingSourceIDs = []
            return
        }

        if !launcher.isRunning && launcher.runningKind != .ingest {
            launcher.ingestingSourceIDs = []
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
            fileProvider: fileProvider,
            takeEditLock: false)
    }

    static func startQueryConversation(
        firstMessage: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike,
        allowWikiEdits: Bool = false
    ) async {
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let wikiID = manager.activeWikiID else {
            DebugLog.agent("startQueryConversation: no active wiki — bailing")
            return
        }

        // If the query agent wants edit permissions, it must take the edit lock.
        // Refuse to start if another agent (ingest) already holds it.
        if allowWikiEdits && store.isAgentRunning {
            launcher.preflightError = "An ingestion is updating the wiki. Wait for it to finish, or use the Ask tab for a read-only conversation."
            return
        }

        await fileProvider.signalChange()
        // The mount is reference-only (the agent reads via `wikictl`); proceed even
        // when it isn't mounted, passing an empty WIKI_ROOT. The prompt tells the
        // agent to read via `wikictl` only when the mount is unavailable.
        let root = fileProvider.path ?? ""
        DebugLog.agent("startQueryConversation: wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // Edit mode takes the edit lock; Ask mode is forced read-only by the seatbelt
        // sandbox and never acquires the lock at all.
        await launcher.startInteractiveQuery(
            firstMessage: trimmed,
            stateMarkdown: store.currentStateSnapshot().renderStateFile(),
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            allowWikiEdits: allowWikiEdits,
            onLock: { if allowWikiEdits { store.beginAgentRun() } },
            onUnlock: { if allowWikiEdits { store.endAgentRun() } },
            // Per-turn edit lock: release between turns (re-acquire on the next
            // send). Lives in the launcher — not the view — so it fires even when
            // the Query view is unmounted (the bug fix). Gated on `allowWikiEdits`
            // so a read-only session never touches the lock.
            onTurnBoundary: { if allowWikiEdits { store.setAgentRunning($0) } }
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
        ingestingSourceIDs: Set<PageID> = [],
        takeEditLock: Bool = true
    ) async {
        guard let wikiID = manager.activeWikiID else { return }

        // Refuse to start if we need the edit lock and another agent holds it.
        if takeEditLock && store.isAgentRunning {
            launcher.preflightError = "The query agent is currently editing the wiki. Wait for it to finish before ingesting."
            return
        }

        switch request {
        case .ingest:
            break
        case .query, .lint:
            await fileProvider.signalChange()
        }
        // The mount path is reference-only in the prompts (the agent reads pages and
        // raw sources via `wikictl`/SQLite, not the mount), so every operation can
        // proceed even when the File Provider isn't mounted — it just gets an empty
        // WIKI_ROOT, and the prompt tells the agent to read via `wikictl` only.
        let root = fileProvider.path ?? ""

        await launcher.run(
            request: request,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            ingestingSourceIDs: ingestingSourceIDs,
            onLock: { if takeEditLock { store.beginAgentRun() } },
            onUnlock: { if takeEditLock { store.endAgentRun() } }
        )
    }

    private static func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }
}
