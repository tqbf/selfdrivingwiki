import Foundation
import WikiFSCore

/// Shared launch seam for UI surfaces that run an agent operation. The toolbar
/// sheet, file detail pane, and page-bottom query field all gather inputs the
/// same way, then delegate here so staging, mount refresh, and edit-lock behavior
/// do not drift.
@MainActor
public enum AgentOperationRunner {
    /// Ingest a single file via the existing detail-view path. Builds a
    /// single-element `[StagedSource]` and delegates to `runIngestSources`.
    public static func runIngest(
        sourceID: PageID,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: QueueEngine,
        extractionProvider: any QueueExtractionProvider
    ) async {
        await runMultiIngest(
            sourceIDs: [sourceID],
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory,
            extractionCoordinator: extractionCoordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider)
    }

    /// Ingest multiple files in a SINGLE agent run. All sources are staged together
    /// as `source-1.<ext>`, `source-2.<ext>`, … — the agent reads them all,
    /// cross-references, and writes pages/index/log in one pass.
    public static func runMultiIngest(
        sourceIDs: [PageID],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: QueueEngine,
        extractionProvider: any QueueExtractionProvider
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

        // The extraction coordinator is retained in the signature for legacy
        // paths (seedPdfMarkdown fallback) but the queue engine now drives
        // extraction via `extractionProvider` — the provider resolves the
        // extractor + readiness + convert + persistence off-main.
        let backendName = extractionCoordinator.config.backend
        DebugLog.ingest("runMultiIngest: backend=\(backendName)")

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
                    // Already extracted — use existing markdown, skip extraction entirely.
                    sourceBytes = head.content.data(using: .utf8) ?? bytes
                    sourceExt = "md"
                    DebugLog.extraction("runMultiIngest: reusing existing markdown for \(source.filename) — \(head.content.count) chars")
                } else {
                    // No existing markdown → enqueue extraction via the queue engine.
                    // The worker resolves the extractor, checks readiness, converts,
                    // and persists (seedPdfMarkdown) — all off-main. We wait for
                    // completion; on failure we fall through with the raw PDF,
                    // matching today's graceful-fallback behavior.
                    let request = QueueItemRequest(
                        queue: .extraction,
                        wikiID: wikiID,
                        payload: QueueItemPayload(sourceIDs: [source.id]))
                    do {
                        let itemID = try await queueEngine.enqueue(request)
                        let result = await queueEngine.waitForCompletion(of: itemID)
                        switch result {
                        case .success:
                            DebugLog.extraction("runMultiIngest: extraction completed for \(source.filename)")
                            // Re-read the extracted markdown head now that the
                            // worker has persisted it. If it landed, use it; if
                            // not (edge case), fall through with raw PDF.
                            if let head = store.processedMarkdownHead(for: source) {
                                sourceBytes = head.content.data(using: .utf8) ?? bytes
                                sourceExt = "md"
                            }
                        case .failure(let error):
                            DebugLog.extraction("runMultiIngest: extraction failed for \(source.filename) — \(error.localizedDescription), using raw PDF")
                        }
                    } catch {
                        DebugLog.extraction("runMultiIngest: enqueue failed for \(source.filename) — \(error.localizedDescription), using raw PDF")
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

        // Phase 7: workspace-isolated ingestion. When the capability flag is on,
        // create a workspace, pass the workspace ID to the launcher so it injects
        // `WIKI_WORKSPACE` into the child process's per-spawn environment (NOT
        // process-global setenv — which would leak to chat-edit agents spawned
        // mid-ingest via the interactive lane), and auto-merge on completion.
        // When the flag is off, behavior is identical to today (writes to main).
        if store.workspacesEnabled {
            do {
                let wsID = try store.createWorkspace(
                    name: "ingest-\(sourceIDs.count)", activityID: nil)
                DebugLog.ingest("runMultiIngest: workspace isolated, wsID=\(wsID)")
                await run(
                    request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                    launcher: launcher,
                    store: store,
                    wikiID: wikiID,
                    changeSignaler: changeSignaler,
                    wikictlDirectory: wikictlDirectory,
                    ingestingSourceIDs: Set(sourceIDs),
                    workspaceID: wsID,
                    onWorkspaceMerge: { [weak store] in
                        // Auto-merge after the agent finishes. The merge is
                        // best-effort: if it conflicts, the workspace is parked
                        // and surfaced via the conflict verbs (main is safe).
                        guard let store else { return }
                        do {
                            try store.workspaceMerge(workspaceID: wsID)
                            DebugLog.ingest("runMultiIngest: workspace merged wsID=\(wsID)")
                        } catch {
                            DebugLog.ingest("runMultiIngest: workspace merge FAILED wsID=\(wsID) — \(error.localizedDescription)")
                        }
                    })
            } catch {
                DebugLog.ingest("runMultiIngest: workspace creation FAILED — falling back to main, \(error.localizedDescription)")
                await run(
                    request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                    launcher: launcher,
                    store: store,
                    wikiID: wikiID,
                    changeSignaler: changeSignaler,
                    wikictlDirectory: wikictlDirectory,
                    ingestingSourceIDs: Set(sourceIDs))
            }
        } else {
            await run(
                request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
                launcher: launcher,
                store: store,
                wikiID: wikiID,
                changeSignaler: changeSignaler,
                wikictlDirectory: wikictlDirectory,
                ingestingSourceIDs: Set(sourceIDs))
        }

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

    public static func runQuery(
        question: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await run(
            request: .query(
                question: trimmed,
                stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory
        )
    }

    public static func startChat(
        firstMessage: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.agent("startChat: enter msg=\"\(trimmed.prefix(80))\" provider=\(launcher.resolveSelectedProvider().id)") // TEMP DEBUG
        guard !trimmed.isEmpty else {
            DebugLog.agent("startChat: early-return — empty message") // TEMP DEBUG
            return
        }

        // Chats are write-capable, so they must flush pending drafts on agent
        // start. Refuse to start only if an ingest is in progress (extraction OR
        // agent phase issue #235). The old `isAgentRunning` edit-lock guard was
        // removed — CAS (page versions, W0) prevents data races.
        if Self.shouldBlockEditStart(
            isIngestInProgress: store.isIngestInProgress) {
            DebugLog.agent("startChat: edit-blocked (isIngestInProgress=\(store.isIngestInProgress))") // TEMP DEBUG
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        await changeSignaler.signalChange()
        // The mount is reference-only (the agent reads via `wikictl`); proceed even
        // when it isn't mounted, passing an empty WIKI_ROOT. The prompt tells the
        // agent to read via `wikictl` only when the mount is unavailable.
        let root = changeSignaler.path ?? ""
        DebugLog.agent("startChat: wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // Persist the chat from the first message (issue #119). Best-effort:
        // a store failure yields chat == nil and the session runs unpersisted.
        let chat = store.startChat(kind: .edit, firstMessage: trimmed)

        // D2 draft-state morph: if a chat row was created, retarget the active
        // tab IN PLACE from the draft state (.newChat) to .chat(id). The tab's
        // UUID survives → tab order, drag/drop, and per-tab history are preserved.
        // The chat "becomes" its tab — reopenable, restorable like any page.
        if let chat {
            store.retargetActiveTabToChat(chatID: chat.id)
        }

        // Start the interactive session. The agent-run lifecycle is ref-counted
        // (agentRunStarted/agentRunEnded) for sidebar reload on last-run-end;
        // no edit lock — CAS (page versions, W0) prevents data races.
        DebugLog.agent("startChat: calling launcher.startInteractiveQuery wikiID=\(wikiID) chatID=\(chat?.id.rawValue ?? "nil")") // TEMP DEBUG
        await launcher.startInteractiveQuery(
            firstMessage: trimmed,
            stateMarkdown: store.currentStateSnapshot().renderStateFile(),
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            chatID: chat?.id.rawValue,
            // The model seeded the first user message at chat creation; tell the
            // launcher so it skips double-inserting it on the first flush.
            firstMessagePrePersisted: chat != nil,
            onLock: { store.agentRunStarted() },
            onUnlock: { store.agentRunEnded() },
            // Weak store: if the user switches wikis mid-session the model may be
            // torn down — persistence degrades to a no-op rather than writing into
            // the wrong wiki (issue #119).
            onTranscript: chat.map { chat -> (@MainActor ([AgentEvent]) -> Void) in
                return { [weak store] events in store?.appendChatEvents(chatID: chat.id, events: events) }
            },
            onSummary: chat.map { chat -> (@MainActor (PageID, String) -> Void) in
                return { [weak store] id, summary in store?.updateChatSummary(chatID: id, summary: summary) }
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
            DebugLog.agent("startChat: ROLLBACK chat=\(chat.id.rawValue) preflightError=\(launcher.preflightError ?? "?")") // TEMP DEBUG
            store.rollbackChatCreation(id: chat.id, toDraft: .newChat)
        }
        DebugLog.agent("startChat: done preflightError=\(launcher.preflightError ?? "nil")") // TEMP DEBUG
    }

    // MARK: - Pure predicates

    /// Whether a write-capable chat session should be blocked from starting.
    /// Never blocks — CAS (page versions, W0) prevents data races, and the
    /// generation gate serializes active generation (a chat started during an
    /// ingest queues behind it). Kept as a static predicate for test backwards
    /// compatibility; always returns false.
    static func shouldBlockEditStart(
        isIngestInProgress: Bool
    ) -> Bool {
        false
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
    public static func continueChat(
        chatID: PageID,
        message: String,
        store: WikiStoreModel,
        launcher: AgentLauncher,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.agent("continueChat: enter chatID=\(chatID.rawValue) msg=\"\(trimmed.prefix(80))\" provider=\(launcher.resolveSelectedProvider().id)") // TEMP DEBUG
        guard !trimmed.isEmpty else {
            DebugLog.agent("continueChat: early-return — empty message") // TEMP DEBUG
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
        DebugLog.agent("continueChat: takeover decision=\(decision) (isRunning=\(launcher.isRunning) isInteractiveSession=\(launcher.isInteractiveSession) isGenerating=\(launcher.isGenerating) isAwaitingGenerationSlot=\(launcher.isAwaitingGenerationSlot))") // TEMP DEBUG
        switch decision {
        case .refused:
            DebugLog.agent("continueChat: refused — launcher mid-generation") // TEMP DEBUG (existed; re-tagged)
            return
        case .betweenTurns:
            // End the OTHER chat's session first. stopAgent() cancels any
            // pending send, asks the backend to cancel the session, then calls
            // finish(-1) SYNCHRONOUSLY on the main actor — which runs the final
            // flushTranscript() (persisting the other chat's tail) and clears its
            // transcriptSink + activeChatID before we take over. Nothing is lost.
            DebugLog.agent("continueChat: ending between-turns session before takeover") // TEMP DEBUG (existed; re-tagged)
            launcher.stopAgent()
        case .idle:
            DebugLog.agent("continueChat: idle — taking over directly") // TEMP DEBUG
        }

        // Refuse if an ingest is in progress (issue #235). The old
        // `isAgentRunning` guard was removed — CAS (page versions, W0)
        // prevents data races, so concurrent agent runs are fine.
        if Self.shouldBlockEditStart(
            isIngestInProgress: store.isIngestInProgress) {
            DebugLog.agent("continueChat: edit-blocked (isIngestInProgress=\(store.isIngestInProgress))") // TEMP DEBUG
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        await changeSignaler.signalChange()
        let root = changeSignaler.path ?? ""
        DebugLog.agent("continueChat: chatID=\(chatID.rawValue) wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // Build the condensed transcript + new message as the first prompt.
        let history = store.chatMessages(chatID: chatID)
        let firstMessage = continuationPreamble(from: history, newMessage: trimmed)
        DebugLog.agent("continueChat: historyRows=\(history.count) preambleChars=\(firstMessage.count) displayMsg=\(trimmed.count)") // TEMP DEBUG

        // Start a fresh session writing to the SAME chat row. activeChatID = chat.id
        // flips ChatView to live for this tab (seq continues, title
        // preserved, updatedAt bumps on the first persisted append). The sink is
        // keyed by chatID and appends to the same row.
        DebugLog.agent("continueChat: calling launcher.startInteractiveQuery wikiID=\(wikiID) chatID=\(chatID.rawValue)") // TEMP DEBUG
        await launcher.startInteractiveQuery(
            firstMessage: firstMessage,
            firstMessageDisplay: trimmed,
            stateMarkdown: store.currentStateSnapshot().renderStateFile(),
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            chatID: chatID.rawValue,
            historySeed: history.map(\.event),
            onLock: { store.agentRunStarted() },
            onUnlock: { store.agentRunEnded() },
            onTranscript: { [weak store] events in
                store?.appendChatEvents(chatID: chatID, events: events)
            },
            onSummary: { [weak store] id, summary in
                store?.updateChatSummary(chatID: id, summary: summary)
            })
    }

    public static func runLint(
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        await run(
            request: .lint(stateMarkdown: store.currentStateSnapshot().renderStateFile()),
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory)
    }

    /// Pre-flight one or more pages (fix `\]]` brackets + detect broken links),
    /// then run a single LLM lint with all the findings.  A single page gets
    /// its own run; multiple pages are combined into one agent pass.
    public static func runLintPages(
        pages: [(id: PageID, title: String)],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
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
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory)
    }

    private static func run(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: String,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String,
        ingestingSourceIDs: Set<PageID> = [],
        workspaceID: String? = nil,
        onWorkspaceMerge: (@MainActor () -> Void)? = nil
    ) async {
        switch request {
        case .ingest:
            break
        case .query, .lint, .lintPage:
            await changeSignaler.signalChange()
        }
        // The mount path is reference-only in the prompts (the agent reads pages and
        // raw sources via `wikictl`/SQLite, not the mount), so every operation can
        // proceed even when the File Provider isn't mounted — it just gets an empty
        // WIKI_ROOT, and the prompt tells the agent to read via `wikictl` only.
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
                // Ingest runs also clear the ingest-in-progress flag (issue #235).
                if !ingestingSourceIDs.isEmpty { store.endIngest() }
                // Phase 7: if this was a workspace-isolated ingest, auto-merge
                // now that the agent has finished writing to the workspace.
                onWorkspaceMerge?()
            }
        )
    }

    private static func ingestSourcePath(for source: SourceSummary) -> String {
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }
}
