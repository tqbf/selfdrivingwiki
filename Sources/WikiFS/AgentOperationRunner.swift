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

        // Announce the ingest is active BEFORE extraction so the Edit preflight
        // (store.isIngestInProgress) blocks during the extraction window too
        // (issue #235). The defer clears it on any exit where the agent process
        // did NOT spawn (early returns, extraction cancel, spawn failure). When
        // the process does spawn, the ingest run's onUnlock clears it on exit.
        store.beginIngest()
        defer {
            if !launcher.isRunning { store.endIngest() }
        }

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
                        let cfg = extractionCoordinator.config
                        store.seedPdfMarkdown(
                            for: source.id, content: markdown,
                            backend: cfg.backend, modelVersion: cfg.currentModelVersion)
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

    static func startChat(
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
            DebugLog.agent("startChat: no active wiki — bailing")
            return
        }

        // If the query agent wants edit permissions, it must take the edit lock.
        // Refuse to start if an ingest is in progress (extraction OR agent phase)
        // or if another agent already holds the lock (issue #235).
        if Self.shouldBlockEditStart(
            allowWikiEdits: allowWikiEdits,
            isAgentRunning: store.isAgentRunning,
            isIngestInProgress: store.isIngestInProgress) {
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        await fileProvider.signalChange()
        // The mount is reference-only (the agent reads via `wikictl`); proceed even
        // when it isn't mounted, passing an empty WIKI_ROOT. The prompt tells the
        // agent to read via `wikictl` only when the mount is unavailable.
        let root = fileProvider.path ?? ""
        DebugLog.agent("startChat: wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // Persist the chat from the first message (issue #119). Best-effort:
        // a store failure yields chat == nil and the session runs unpersisted.
        let chat = store.startChat(kind: allowWikiEdits ? .edit : .ask, firstMessage: trimmed)

        // D2 draft-state morph: if a chat row was created, retarget the active
        // tab IN PLACE from the draft state (.ask/.edit) to .chat(id). The tab's
        // UUID survives → tab order, drag/drop, and per-tab history are preserved.
        // The chat "becomes" its tab — reopenable, restorable like any page.
        if let chat {
            store.retargetActiveTabToChat(chatID: chat.id)
        }

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
            // D2: pass the chat row id so the launcher records it as
            // activeChatID — ChatView's source-of-truth switch. `nil`
            // when startChat failed (session runs unpersisted, no live tab).
            chatID: chat?.id.rawValue,
            // The model seeded the first user message at chat creation; tell the
            // launcher so it skips double-inserting it on the first flush.
            firstMessagePrePersisted: chat != nil,
            onLock: { if allowWikiEdits { store.beginAgentRun() } },
            onUnlock: { if allowWikiEdits { store.endAgentRun() } },
            // Per-turn edit lock: release between turns (re-acquire on the next
            // send). Lives in the launcher — not the view — so it fires even when
            // the Query view is unmounted (the bug fix). Gated on `allowWikiEdits`
            // so a read-only session never touches the lock.
            onTurnBoundary: { if allowWikiEdits { store.setAgentRunning($0) } },
            // Weak store: if the user switches wikis mid-session the model may be
            // torn down — persistence degrades to a no-op rather than writing into
            // the wrong wiki (issue #119).
            onTranscript: chat.map { chat -> (@MainActor ([AgentEvent]) -> Void) in
                return { [weak store] events in store?.appendChatEvents(chatID: chat.id, events: events) }
            }
        )

        // If the session never started — a preflight failure (e.g. the agent
        // binary wasn't found) or a spawn failure — `startInteractiveQuery` sets
        // `preflightError` synchronously before returning. The chat row the model
        // just created (with its seeded first message) would otherwise linger in
        // history as a dead chat. Roll it back: drop the row and revert
        // the tab to the draft composer. (A process that spawns OK then dies
        // immediately isn't caught here, but seeding guarantees that chat still
        // holds its first message — never titled-but-empty.)
        if let chat, launcher.preflightError != nil {
            store.rollbackChatCreation(id: chat.id, toDraft: allowWikiEdits ? .edit : .ask)
        }
    }

    // MARK: - Pure predicates (issue #235)

    /// Whether an Edit-mode session should be blocked from starting because an
    /// ingest is in progress or another agent holds the edit lock. Pure so the
    /// (allowWikiEdits × isAgentRunning × isIngestInProgress) matrix is unit-
    /// testable without driving a live launcher or store. Used by both
    /// `startChat` and `continueChat`.
    ///
    /// `isIngestInProgress` covers the extraction window (pdf2md) that
    /// `isAgentRunning` misses (it only fires at spawn commit). Ask mode
    /// (allowWikiEdits == false) is never blocked — it is read-only and
    /// lock-exempt.
    static func shouldBlockEditStart(
        allowWikiEdits: Bool,
        isAgentRunning: Bool,
        isIngestInProgress: Bool
    ) -> Bool {
        allowWikiEdits && (isAgentRunning || isIngestInProgress)
    }

    // MARK: - Continue a persisted chat (D3, seeded-fallback)

    /// How a takeover of a kind's launcher should proceed, given its state when a
    /// *different* chat asks to continue. Pure so the matrix is unit-
    /// testable without driving a live launcher. The runner consults this BEFORE
    /// touching the launcher; `refused` means the composer should already be
    /// disabled (it is the guard) and `continueChat` bails.
    ///
    /// - idle: nothing is running → take over directly.
    /// - betweenTurns: an interactive session is open but not generating → end it
    ///   first (`stopAgent()` → final flush persists its tail), then take over.
    /// - refused: a turn is actively streaming (or queued to) → cannot interrupt.
    ///   (The three logical states from the spec — idle / between-turns /
    ///   mid-generation — map to idle / betweenTurns / refused respectively,
    ///   since a refused takeover is the "mid-generation" outcome.)
    public enum ContinueTakeover: Equatable {
        case idle
        case betweenTurns
        case refused
    }

    /// Classify a launcher's state for the takeover decision. `refused` covers
    /// mid-generation (`isGenerating` or queued for the gate
    /// `isAwaitingGenerationSlot`) — the composer is already disabled in that
    /// state, and `continueChat` treats this as a hard bail.
    static func continueTakeoverDecision(
        isRunning: Bool,
        isInteractiveSession: Bool,
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool
    ) -> ContinueTakeover {
        // Mid-generation (or queued to start one) → never interrupt. This is the
        // existing one-active-generation-at-a-time invariant.
        if isGenerating || isAwaitingGenerationSlot {
            return .refused
        }
        // Between-turns: an interactive session process is alive but idle (the
        // turn boundary released the gate and the edit lock). End it first, then
        // take over. A non-interactive run that is somehow alive without the
        // generation flag is also treated as betweenTurns (end-then-take-over) so
        // we never strand a process.
        if isRunning && isInteractiveSession {
            return .betweenTurns
        }
        if isRunning {
            return .betweenTurns
        }
        return .idle
    }

    /// Build the first prompt for a seeded-fallback continue: a "continuing an
    /// earlier chat" preamble carrying the last N user/assistant turns
    /// (the `.text` projection — never `event_json`), byte-capped, followed by
    /// the new user message.
    ///
    /// Pure and unit-tested: the caller hands in the persisted `chat_messages`
    /// (already ordered by `seq`) and the new message; this returns the exact
    /// string sent as the first turn of the fresh session.
    ///
    /// - Only `user` and `assistant` roles contribute (tool calls / results /
    ///   system rows are noise for re-seeding context).
    /// - The most recent N *matching* rows are kept (last-wins), then the whole
    ///   preamble is trimmed from the front so the UTF-8 byte budget holds.
    /// - The new user message is ALWAYS included in full (it is the actual
    ///   question); only the transcript window is elided to fit the budget.
    static func continuationPreamble(
        from messages: [ChatMessage],
        newMessage: String,
        maxTurns: Int = 10,
        maxBytes: Int = 12_000
    ) -> String {
        // Project to (role, text) for user/assistant rows only. `.result`
        // duplicates `.assistantText` (same turn, same text) — skip it when
        // the preceding turn is an `.assistantText` with identical text. A
        // standalone `.result` (no preceding `.assistantText`) is kept so a
        // turn that only emitted a result is not lost.
        var turns: [(role: String, text: String)] = []
        for msg in messages {
            switch msg.event {
            case .userText(let text):
                turns.append(("user", text))
            case .assistantText(let text):
                turns.append(("assistant", text))
            case .result(_, let text) where !text.isEmpty:
                if let last = turns.last, last.role == "assistant", last.text == text {
                    continue  // duplicates the preceding .assistantText — skip
                }
                turns.append(("assistant", text))
            default:
                break
            }
        }

        // Take the last N matching rows (most recent context wins).
        let recent: [(role: String, text: String)] = {
            let start = max(0, turns.count - maxTurns)
            return Array(turns[start...])
        }()

        let header = """
        You are continuing an earlier chat about this wiki. \
        Here is the transcript so far, condensed for context. \
        Pick up where it left off.

        """
        let footer = "\n\n--- new message ---\n\(newMessage)"

        let headerBytes = header.utf8.count
        let footerBytes = footer.utf8.count
        let budget = max(0, maxBytes - headerBytes - footerBytes)

        // Render the transcript window oldest→newest, byte-capped. Drop oldest
        // rows first (then trim the oldest surviving row's head) until it fits.
        var rendered: [String] = []
        var used = 0
        // Walk newest→oldest accumulating, so the most recent context survives
        // the cap; then reverse for chronological order.
        for turn in recent.reversed() {
            let line = "[\(turn.role)] \(turn.text)"
            let bytes = line.utf8.count + 1  // +1 for the joining newline
            if used + bytes > budget, !rendered.isEmpty {
                break
            }
            if used + bytes > budget {
                // The very first (most recent) row exceeds the budget alone —
                // include a head-trimmed slice so SOME recent context survives.
                let headBudget = max(0, budget - used - 1)
                if headBudget > 0 {
                    let prefixBytes = Array(line.utf8.prefix(headBudget))
                    let cut = String(decoding: prefixBytes, as: UTF8.self)
                    rendered.append(cut + "…")
                    used += cut.utf8.count + 2  // ellipsis + newline approx
                }
                break
            }
            rendered.append(line)
            used += bytes
        }
        let body = rendered.reversed().joined(separator: "\n")

        return header + body + footer
    }

    /// Continue a persisted chat via seeded-fallback (D3). Starts a fresh
    /// interactive session whose first prompt embeds a condensed transcript, then
    /// streams into the SAME chat row (`seq` continues, title preserved,
    /// `updatedAt` bumps it to the top of Recent). Session identity / `--resume`
    /// is Phase B — not attempted here (the CLI backend's `resume` returns nil).
    ///
    /// Takeover rules (one live session per kind remains the invariant):
    /// - **idle** → take over directly.
    /// - **between-turns** (a different chat's session is open but idle) →
    ///   `stopAgent()` first. That triggers `finish(-1)`, which runs the FINAL
    ///   `flushTranscript()` BEFORE clearing `transcriptSink` — so the other
    ///   chat's in-flight tail is persisted to its own chat row with
    ///   nothing lost. Only THEN do we take over.
    /// - **mid-generation** → refuse (the composer is already disabled; this is a
    ///   guard). Returns without spawning.
    static func continueChat(
        chatID: PageID,
        message: String,
        mode: QueryMode,
        store: WikiStoreModel,
        launcher: AgentLauncher,
        manager: WikiManager,
        fileProvider: FileProviderSpike,
        allowWikiEdits: Bool
    ) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let wikiID = manager.activeWikiID else {
            DebugLog.agent("continueChat: no active wiki — bailing")
            return
        }

        // Guard: refuse mid-generation. The composer is already disabled in that
        // state (ChatView.isComposerEnabled), but this is a hard guard so
        // a race (enabled-check → send) can never interrupt a live turn.
        let decision = continueTakeoverDecision(
            isRunning: launcher.isRunning,
            isInteractiveSession: launcher.isInteractiveSession,
            isGenerating: launcher.isGenerating,
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot)
        switch decision {
        case .refused:
            DebugLog.agent("continueChat: refused — launcher mid-generation")
            return
        case .betweenTurns:
            // End the OTHER chat's session first. stopAgent() cancels any
            // pending send, asks the backend to cancel the session, then calls
            // finish(-1) SYNCHRONOUSLY on the main actor — which runs the final
            // flushTranscript() (persisting the other chat's tail) and clears its
            // transcriptSink + activeChatID before we take over. Nothing is lost.
            DebugLog.agent("continueChat: ending between-turns session before takeover")
            launcher.stopAgent()
        case .idle:
            break
        }

        // Edit-lock sanity: refuse if an ingest is in progress (extraction OR
        // agent phase) or holds the lock and we want edits (issue #235).
        if Self.shouldBlockEditStart(
            allowWikiEdits: allowWikiEdits,
            isAgentRunning: store.isAgentRunning,
            isIngestInProgress: store.isIngestInProgress) {
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        await fileProvider.signalChange()
        let root = fileProvider.path ?? ""
        DebugLog.agent("continueChat: chatID=\(chatID.rawValue) wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // Build the condensed transcript + new message as the first prompt.
        let history = store.chatMessages(chatID: chatID)
        let firstMessage = continuationPreamble(from: history, newMessage: trimmed)

        // Start a fresh session writing to the SAME chat row. activeChatID = chat.id
        // flips ChatView to live for this tab (seq continues, title
        // preserved, updatedAt bumps on the first persisted append). The sink is
        // keyed by chatID and appends to the same row.
        await launcher.startInteractiveQuery(
            firstMessage: firstMessage,
            firstMessageDisplay: trimmed,
            stateMarkdown: store.currentStateSnapshot().renderStateFile(),
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            allowWikiEdits: allowWikiEdits,
            chatID: chatID.rawValue,
            onLock: { if allowWikiEdits { store.beginAgentRun() } },
            onUnlock: { if allowWikiEdits { store.endAgentRun() } },
            onTurnBoundary: { if allowWikiEdits { store.setAgentRunning($0) } },
            onTranscript: { [weak store] events in
                store?.appendChatEvents(chatID: chatID, events: events)
            })
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

    /// Pre-flight one or more pages (fix `\]]` brackets + detect broken links),
    /// then run a single LLM lint with all the findings.  A single page gets
    /// its own run; multiple pages are combined into one agent pass.
    static func runLintPages(
        pages: [(id: PageID, title: String)],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) async {
        let preflights = pages.map { page in
            let preflight = store.preflightLint(pageID: page.id)
            return (title: page.title, brokenLinks: preflight?.brokenPageLinks ?? [])
        }
        let combinedTitle = pages.map(\.title).joined(separator: ", ")
        let combinedBroken = preflights.flatMap(\.brokenLinks)
        await run(
            request: .lintPage(
                pageTitle: combinedTitle,
                brokenLinks: combinedBroken,
                stateMarkdown: store.currentStateSnapshot().renderStateFile()),
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
        case .query, .lint, .lintPage:
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
            onUnlock: {
                if takeEditLock { store.endAgentRun() }
                // Ingest runs also clear the ingest-in-progress flag (issue #235).
                if !ingestingSourceIDs.isEmpty { store.endIngest() }
            }
        )
    }

    private static func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }
}
