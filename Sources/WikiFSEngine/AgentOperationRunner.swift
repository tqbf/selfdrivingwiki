#if os(macOS)
import Foundation
import WikiFSCore

/// Shared launch seam for UI surfaces that run an agent operation. The toolbar
/// sheet, file detail pane, and page-bottom query field all gather inputs the
/// same way, then delegate here so staging, mount refresh, and edit-lock behavior
/// do not drift.
@MainActor
public enum AgentOperationRunner {
    public static func runQuery(
        question: String,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher) else { return }
        await run(
            request: .query(
                question: trimmed,
                stateMarkdown: stateMarkdown),
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
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.agent("startChat: enter msg=\"\(trimmed.prefix(80))\" provider=\(launcher.resolveSelectedProvider().id)")
        guard !trimmed.isEmpty else {
            DebugLog.agent("startChat: early-return — empty message")
            return
        }

        // Chats are write-capable, so they must flush pending drafts on agent
        // start. Refuse to start only if an ingest is in progress (extraction OR
        // agent phase issue #235). The old `isAgentRunning` edit-lock guard was
        // removed — CAS (page versions, W0) prevents data races.
        if Self.shouldBlockEditStart(
            isIngestInProgress: store.isIngestInProgress) {
            DebugLog.agent("startChat: edit-blocked (isIngestInProgress=\(store.isIngestInProgress))")
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        // Capture the wiki state BEFORE the mount signal or the chat row: a
        // strategy read failure refuses the run entirely (no chat created, no
        // session started) rather than launching under invented Default
        // instructions.
        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher) else { return }

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
        let persistedChatID: ChatID? = chat?.id

        // Start the interactive session. The agent-run lifecycle is ref-counted
        // (agentRunStarted/agentRunEnded) for sidebar reload on last-run-end;
        // no edit lock — CAS (page versions, W0) prevents data races.
        DebugLog.agent("startChat: calling launcher.startInteractiveQuery wikiID=\(wikiID.rawValue) chatID=\(chat?.id.rawValue ?? "nil")")
        await launcher.startInteractiveQuery(
            firstMessage: trimmed,
            stateMarkdown: stateMarkdown,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            chatID: persistedChatID,
            // The model seeded the first user message at chat creation; tell the
            // launcher so it skips double-inserting it on the first flush.
            firstMessagePrePersisted: chat != nil,
            onAcpSessionId: chat.map { chat -> (@MainActor (AcpSessionID?) -> Void) in
                return { [weak store] sessionId in
                    guard let store else { return }
                    if let sessionId {
                        store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: sessionId)
                    }
                }
            },
            onLock: { store.agentRunStarted() },
            onUnlock: { store.agentRunEnded() },
            // Weak store: if the user switches wikis mid-session the model may be
            // torn down — persistence degrades to a no-op rather than writing into
            // the wrong wiki (issue #119).
            onTranscript: chat.map { chat -> (@MainActor ([AgentEvent]) -> Void) in
                return { [weak store] events in store?.appendChatEvents(chatID: chat.id, events: events) }
            },
            onMessageSummary: chat.map { chat -> (@MainActor (ChatID) -> Void) in
                return { [weak store] id in
                    Self.summarizePendingMessages(chatID: id, store: store, launcher: launcher)
                }
            },
            onStreamingCheckpoint: { [weak store] chatID, handle, event, isDraft in
                store?.checkpointStreamingMessage(
                    chatID: chatID, handle: handle, event: event, isDraft: isDraft) ?? false
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
            DebugLog.agent("startChat: ROLLBACK chat=\(chat.id.rawValue) preflightError=\(launcher.preflightError ?? "?")")
            store.rollbackChatCreation(id: chat.id, toDraft: .newChat)
        }
        DebugLog.agent("startChat: done preflightError=\(launcher.preflightError ?? "nil")")
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
    public enum ContinueTakeover: Equatable, Sendable {        case idle
        case betweenTurns
        case refused
    }

    /// Classify a launcher's state for the takeover decision. `refused` covers
    /// mid-generation (`isGenerating` or queued for the gate
    /// `isAwaitingGenerationSlot`) — the composer is already disabled in that
    /// state, and `continueChat` treats this as a hard bail.
    public static func continueTakeoverDecision(
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

    // MARK: - Adaptive preamble budget (#825)

    // The preamble window scales with conversation depth rather than a flat
    // 10-turn / 12 KB cap, so deep conversations keep more early context. Every
    // value is bounded by the ceilings below, so the preamble can never blow
    // the model's context window. See `adaptivePreambleBudget`.

    /// Eligible-turn depth at and below which the floor (legacy) budget applies.
    static let adaptiveFloorDepth = 10
    /// Eligible-turn depth at and above which the ceiling budget is reached.
    static let adaptiveCeilingDepth = 80
    /// Floor of the turn-count window (also the legacy flat cap).
    static let adaptiveFloorTurns = 10
    /// Ceiling of the turn-count window.
    static let adaptiveCeilingTurns = 40
    /// Floor of the byte budget, in UTF-8 bytes (also the legacy flat cap).
    static let adaptiveFloorBytes = 12_000
    /// Ceiling of the byte budget, in UTF-8 bytes.
    static let adaptiveCeilingBytes = 48_000

    /// Project persisted messages to the (role, text) turns the preamble
    /// re-seeds: `.userText` and `.assistantText` rows, plus a standalone
    /// `.result`'s text, deduplicated against an identical preceding
    /// `.assistantText`. Pure, and shared by `continuationPreamble` and the
    /// adaptive budget so depth is measured the same way the window is filled.
    public static func projectedPreambleTurns(
        from messages: [ChatMessage]
    ) -> [(role: String, text: String)] {
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
        return turns
    }

    /// Compute the adaptive (maxTurns, maxBytes) preamble window for a
    /// conversation of `eligibleTurns` user/assistant turns (#825). The window
    /// grows with depth so deep conversations don't lose all early context, and
    /// is bounded by `adaptiveCeilingTurns` / `adaptiveCeilingBytes`.
    ///
    /// Pure and unit-tested. Piecewise-linear ramp over depth:
    ///   - depth ≤ `adaptiveFloorDepth` → floor budget (the legacy cap).
    ///   - floor < depth < ceiling → linear interpolation floor → ceiling.
    ///   - depth ≥ `adaptiveCeilingDepth` → ceiling budget (saturated).
    ///
    /// `eligibleTurns` is `projectedPreambleTurns(from:).count`. Depth 0 still
    /// yields the floor budget; `continuationPreamble` then just bounds the
    /// header + new message, as before.
    public static func adaptivePreambleBudget(
        eligibleTurns depth: Int
    ) -> (maxTurns: Int, maxBytes: Int) {
        let lo = Self.adaptiveFloorDepth
        let hi = Self.adaptiveCeilingDepth
        guard hi > lo else {
            return (Self.adaptiveCeilingTurns, Self.adaptiveCeilingBytes)
        }
        let clamped = min(max(depth, lo), hi)
        let t = Double(clamped - lo) / Double(hi - lo)  // 0…1 across the ramp
        let maxTurns = Int((Double(Self.adaptiveFloorTurns)
            + t * Double(Self.adaptiveCeilingTurns - Self.adaptiveFloorTurns)).rounded())
        let maxBytes = Int((Double(Self.adaptiveFloorBytes)
            + t * Double(Self.adaptiveCeilingBytes - Self.adaptiveFloorBytes)).rounded())
        return (maxTurns, maxBytes)
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
    ///
    /// `maxTurns` / `maxBytes` default to the legacy flat cap for backward
    /// compatibility; `continueChat` passes an adaptive budget from
    /// `adaptivePreambleBudget` (#825).
    public static func continuationPreamble(
        from messages: [ChatMessage],
        newMessage: String,
        maxTurns: Int = 10,
        maxBytes: Int = 12_000
    ) -> String {
        // Project to (role, text) turns (shared with the adaptive budget).
        let turns = projectedPreambleTurns(from: messages)

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
        chatID: ChatID,
        message: String,
        store: WikiStoreModel,
        launcher: AgentLauncher,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.agent("continueChat: enter chatID=\(chatID.rawValue) msg=\"\(trimmed.prefix(80))\" provider=\(launcher.resolveSelectedProvider().id)")
        guard !trimmed.isEmpty else {
            DebugLog.agent("continueChat: early-return — empty message")
            return
        }

        // Guard: refuse mid-generation. The composer is already disabled in that
        // state (ChatDetailView.isComposerEnabled), but this is a hard guard so
        // a race (enabled-check → send) can never interrupt a live turn.
        let decision = continueTakeoverDecision(
            isRunning: launcher.isRunning,
            isInteractiveSession: launcher.isInteractiveSession,
            isGenerating: launcher.isGenerating,
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot)
        DebugLog.agent("continueChat: takeover decision=\(decision) (isRunning=\(launcher.isRunning) isInteractiveSession=\(launcher.isInteractiveSession) isGenerating=\(launcher.isGenerating) isAwaitingGenerationSlot=\(launcher.isAwaitingGenerationSlot))")
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
            DebugLog.agent("continueChat: idle — taking over directly")
        }

        // Refuse if an ingest is in progress (issue #235). The old
        // `isAgentRunning` guard was removed — CAS (page versions, W0)
        // prevents data races, so concurrent agent runs are fine.
        if Self.shouldBlockEditStart(
            isIngestInProgress: store.isIngestInProgress) {
            DebugLog.agent("continueChat: edit-blocked (isIngestInProgress=\(store.isIngestInProgress))")
            launcher.preflightError = "An ingestion is in progress. Wait for it to finish before starting a chat."
            return
        }

        // Capture the wiki state BEFORE the mount signal: a strategy read
        // failure refuses the run (no session takeover) rather than launching
        // under invented Default instructions.
        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher) else { return }

        await changeSignaler.signalChange()
        let root = changeSignaler.path ?? ""
        DebugLog.agent("continueChat: chatID=\(chatID.rawValue) wikiRoot=\(root.isEmpty ? "<mount unavailable>" : root)")

        // C8 (#826): finalize any stale draft rows from an interrupted turn
        // (hard kill before finalize ran). Cheap single UPDATE → is_draft=0 so
        // the draft flag stays meaningful over time. Must run BEFORE
        // chatMessages so the seed reflects finalized state.
        store.finalizeStaleDrafts(forChat: chatID)

        // Build the condensed transcript + new message as the first prompt.
        // #825: the preamble window is adaptive — it scales with conversation
        // depth (more turns for longer chats, up to a ceiling) instead of the
        // legacy flat 10-turn / 12 KB cap. This is the FALLBACK path (used when
        // ACP resume fails / returns nil); the resume path sends the raw
        // `trimmed` message via `firstMessageDisplay`, which is unaffected here.
        let history = store.chatMessages(chatID: chatID)
        let budget = Self.adaptivePreambleBudget(
            eligibleTurns: Self.projectedPreambleTurns(from: history).count)
        let firstMessage = continuationPreamble(
            from: history, newMessage: trimmed,
            maxTurns: budget.maxTurns, maxBytes: budget.maxBytes)
        // #830: Read the chat's prior ACP session ID so startInteractiveQuery
        // can attempt resume before falling back to the fresh-start + preamble.
        let priorAcpSessionId = store.getChat(id: chatID)?.acpSessionId
        DebugLog.agent("continueChat: historyRows=\(history.count) preambleChars=\(firstMessage.count) displayMsg=\(trimmed.count) priorAcpSessionId=\(priorAcpSessionId?.rawValue ?? "nil")")

        // Start a fresh session writing to the SAME chat row. activeChatID = chat.id
        // flips ChatDetailView to live for this tab (seq continues, title
        // preserved, updatedAt bumps on the first persisted append). The sink is
        // keyed by chatID and appends to the same row.
        let continuedChatID: ChatID = chatID
        DebugLog.agent("continueChat: calling launcher.startInteractiveQuery wikiID=\(wikiID.rawValue) chatID=\(chatID.rawValue)")
        await launcher.startInteractiveQuery(
            firstMessage: firstMessage,
            firstMessageDisplay: trimmed,
            stateMarkdown: stateMarkdown,
            wikiID: wikiID,
            wikiRoot: root,
            systemPrompt: store.currentSystemPromptBody(),
            wikictlDirectory: wikictlDirectory,
            chatID: continuedChatID,
        historySeed: history.map { $0.event },
            priorAcpSessionId: priorAcpSessionId,
            onAcpSessionId: { [weak store] sessionId in
                guard let store else { return }
                store.updateChatAcpSessionId(chatID: chatID, acpSessionId: sessionId)
            },
            onLock: { store.agentRunStarted() },
            onUnlock: { store.agentRunEnded() },
            onTranscript: { [weak store] events in
                store?.appendChatEvents(chatID: chatID, events: events)
            },
            onMessageSummary: { [weak store] id in
                Self.summarizePendingMessages(chatID: id, store: store, launcher: launcher)
            },
            onStreamingCheckpoint: { [weak store] chatID, handle, event, isDraft in
                store?.checkpointStreamingMessage(
                    chatID: chatID, handle: handle, event: event, isDraft: isDraft) ?? false
            })
    }

    public static func runLint(
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async {
        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher) else { return }
        await run(
            request: .lint(stateMarkdown: stateMarkdown),
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory)
    }

    /// The shared per-page lint plan (plan §5.2): the typed request plus the
    /// exact snapshot and pre-flight report the run must account for. Built
    /// identically for the app UI, the app queue, and the daemon queue —
    /// each page gets its OWN run, artifacts, and outcome; titles are never
    /// joined.
    public struct LintPagePlan: Sendable {
        public let request: OperationRequest
        public let snapshot: LintPageSnapshot
        public let preflight: LintPreflightReport
        /// The rollout gate's decision (§6.13) after the local circuit
        /// breaker had its say: the tier, the approval row, and the reason
        /// for any report-only outcome.
        public let authority: LintRepairAuthority
        /// The breaker configuration this run records its outcome under —
        /// set for repair-authorized runs AND tier-2 staged-proposal runs
        /// (the live pipeline + provider/model/effort tuple; tier 2 has no
        /// approval row).
        public let breakerKey: LintRepairBreakerKey?
        /// The breaker the trusted host consulted, so the accounting records
        /// into the SAME state it read.
        public let breaker: LintRepairBreaker?
        /// Whether every fact-dependent verification check (the identity,
        /// citation, and origin facts) was available when this plan's
        /// pre-run scan loaded. A `false` here propagates into the apply
        /// verification's gate — missing required facts fail verification
        /// (recovery + breaker accounting), never a verified verdict over
        /// degraded facts.
        public let requiredChecksAvailable: Bool

        /// A report-only plan instructs the agent not to patch.
        public var repairAuthorized: Bool { authority.isRepairCapable }
        /// The recorded reason for the plan's authority.
        public var gateReason: String { authority.reason ?? "accepted configuration" }
    }

    /// The gate components the coordinator consults with. Today every field
    /// is the `unconfigured` placeholder (review M8 hard-fails it to
    /// report-only); a later wiring passes the live configuration.
    struct LintGateInputs: Sendable {
        let provider: String
        let model: String
        let modelRevision: String?
        let effort: String

        static let unconfigured = LintGateInputs(
            provider: "unconfigured", model: "unconfigured",
            modelRevision: nil, effort: "unconfigured")
    }

    /// Build one page's lint plan: coherent snapshot → injected facts →
    /// pure scan → staged artifact contents. Shared by the app UI, the app
    /// queue, and the daemon queue (plan §5.2). Returns `nil` when the page
    /// does not exist (the caller records a skipped outcome).
    public static func makeLintPagePlan(
        store: WikiStore,
        pageID: PageID,
        stateMarkdown: String
    ) async -> LintPagePlan? {
        await makeLintPagePlan(
            store: store, pageID: pageID, stateMarkdown: stateMarkdown,
            gateInputs: .unconfigured,
            selection: { inputs in
                try LintCoordinatorGate.selection(
                    provider: inputs.provider, model: inputs.model,
                    modelRevision: inputs.modelRevision, effort: inputs.effort)
            },
            breaker: LintRepairBreaker.production())
    }

    /// The plan builder with the gate and breaker injected (tests drive a
    /// repair-authorized selection through here; production always passes
    /// the shipped gate).
    static func makeLintPagePlan(
        store: WikiStore,
        pageID: PageID,
        stateMarkdown: String,
        gateInputs: LintGateInputs,
        selection: (LintGateInputs) throws -> LintRolloutSelection,
        breaker: LintRepairBreaker
    ) async -> LintPagePlan? {
        let read: PageCoherentRead?
        do {
            read = try store.readPageCoherent(id: pageID)
        } catch WikiStoreError.notFound {
            return nil
        } catch {
            DebugLog.agent("lint plan: coherent read failed for \(pageID.rawValue): \(error)")
            return nil
        }
        guard let read else { return nil }
        let snapshot = LintPageSnapshot(read)
        let resolution: LintResolutionFacts
        var requiredChecksAvailable = true
        do {
            resolution = try LintResolutionFacts.load(from: store)
        } catch {
            DebugLog.agent("lint plan: resolution facts unavailable, scanning without identity facts: \(error)")
            resolution = LintResolutionFacts()
            // The identity facts are a required verification check: their
            // failure must gate the run's verification, never read clean.
            requiredChecksAvailable = false
        }
        let citations: LintCitationFacts?
        do {
            citations = try LintCitationFacts.load(from: store, body: snapshot.body)
        } catch {
            DebugLog.agent("lint plan: citation facts unavailable, D09 records its limit: \(error)")
            citations = nil
            // D09's missing-facts limit is not a finding — the load failure
            // gates availability instead.
            requiredChecksAvailable = false
        }
        let origins: LintOriginURLFacts?
        do {
            origins = try LintOriginURLFacts.load(from: store, body: snapshot.body)
        } catch {
            DebugLog.agent("lint plan: origin facts unavailable, D11 records its limit: \(error)")
            origins = nil
            // D11 is the same shape.
            requiredChecksAvailable = false
        }
        let history = LintHistoryFacts.load(from: store, snapshot: snapshot)
        if case .readFailed(let reason) = history.availability {
            DebugLog.agent("lint plan: history facts unavailable, D27 blocks its section: \(reason)")
            // Same shape as the identity facts above: a required check that
            // could not run gates the run's verification availability
            // instead of reading clean over a blocked section.
            requiredChecksAvailable = false
        }
        let parsed = ParsedMarkdownDocument(parsing: snapshot.body)
        let fenceValidation = await Self.lintFenceValidationFacts(
            body: snapshot.body, fenceFacts: parsed.fenceFacts)
        let report = LintPagePreflight.scan(
            snapshot: snapshot, resolution: resolution,
            citations: citations, originURLs: origins,
            history: history, fenceValidation: fenceValidation)
        // The rollout gate (§6.13): consult BEFORE authorizing repairs.
        // Review M8: components that need a configured provider/model are
        // NOT silently hashed as constants — an unknown component
        // hard-fails to report-only BEFORE any manifest consultation, so a
        // placeholder configuration is never matched against the shipped
        // approval matrix. W2a: a matched approval then passes the local
        // circuit breaker, which can only demote it. W5a: a staged-proposal
        // selection passes the breaker too — tier 2 records under the SAME
        // live-pipeline + provider/model/effort key (no approval row is
        // involved), and a tripped breaker pauses proposals for that
        // configuration.
        let gateSelection: LintRolloutSelection
        do {
            gateSelection = try selection(gateInputs)
        } catch {
            gateSelection = .reportOnly(reason: "gate unavailable: \(error)")
        }
        var breakerKey: LintRepairBreakerKey?
        switch gateSelection {
        case .repairAuthorized, .stagedProposal:
            do {
                breakerKey = LintRepairBreakerKey(
                    pipeline: try LintAcceptanceManifest.Pipeline.live(),
                    provider: gateInputs.provider, model: gateInputs.model,
                    effort: gateInputs.effort)
            } catch {
                // `authority(after:key:)` demotes a nil key.
                DebugLog.agent("lint plan: breaker key unavailable, demoting: \(error)")
                breakerKey = nil
            }
        case .reportOnly:
            breakerKey = nil
        }
        let authority = breaker.authority(after: gateSelection, key: breakerKey)
        let gateReason = authority.reason ?? "accepted configuration"
        let request = OperationRequest.lintPage(
            page: LintPageIdentity(snapshot),
            mode: authority.runMode,
            gateReason: gateReason,
            preflightReportMarkdown: report.renderedMarkdown(),
            runReportMarkdown: LintRunReportText.render(snapshot: snapshot, preflight: report),
            stateMarkdown: stateMarkdown)
        return LintPagePlan(
            request: request, snapshot: snapshot, preflight: report,
            authority: authority, breakerKey: breakerKey, breaker: breaker,
            requiredChecksAvailable: requiredChecksAvailable)
    }

    /// Package-validation facts for the body's rich fences, or `nil` when the
    /// machine package store cannot be opened (the scan records the limit).
    public static func lintFenceValidationFacts(
        body: String,
        fenceFacts: [MarkdownFenceFact]
    ) async -> LintFenceValidationFacts? {
        let layout: RendererPackageStoreLayout?
        do {
            layout = try RendererPackageStoreLayout.production()
        } catch {
            // A machine without a resolvable package store has no validation
            // service; the scan records D28's honest limit instead.
            DebugLog.agent("lint plan: renderer package store unavailable, D28 records its limit: \(error)")
            layout = nil
        }
        guard let layout else { return nil }
        return await LintFenceValidationFacts.load(
            body: body, fenceFacts: fenceFacts,
            service: FenceSyntaxValidationService(layout: layout))
    }

    /// The dispatch outcome of one requested page (plan §5.3). Missing or
    /// unreadable pages stay visible as skipped/blocked — never empty clean
    /// audits.
    public struct LintPageDispatchOutcome: Sendable, Equatable {
        public enum Status: Equatable, Sendable {
            case dispatched
            case skipped
            case failed
        }

        public let pageID: PageID
        public let title: String
        public let status: Status
        public let detail: String
        /// The authority the run ended under (nil for pages that never got a
        /// plan). A rejected patch moves it to `.budgetExceeded`.
        public let authority: LintRepairAuthority?
        /// The auto-revert outcome after a verification failure, as its own
        /// fact — the status stays `.failed` either way.
        public let revert: LintRevertOutcome?

        public init(
            pageID: PageID, title: String, status: Status, detail: String,
            authority: LintRepairAuthority? = nil, revert: LintRevertOutcome? = nil
        ) {
            self.pageID = pageID
            self.title = title
            self.status = status
            self.detail = detail
            self.authority = authority
            self.revert = revert
        }

        /// The bad write may still be in place: a human must look.
        public var isFlagged: Bool { revert?.isFlagged == true }

        /// The queue report's per-page outcome record input.
        public var queueReportOutcome: QueueIngestionReporting.LintPageOutcome {
            let result: QueueIngestionReporting.LintPageOutcome.Result
            switch status {
            case .dispatched: result = .passed
            case .skipped: result = .skipped
            case .failed: result = .failed
            }
            return QueueIngestionReporting.LintPageOutcome(
                pageID: pageID, title: title, result: result, detail: detail,
                authority: authority, revert: revert)
        }
    }

    /// The byte ranges where `after` actually differs from `before`, observed
    /// from the store's own bytes (common prefix/suffix trim → the changed
    /// middle region). This is the verification gate's "applied hunks" input:
    /// findings inside these ranges were legitimately rewritten; a finding
    /// that vanishes OUTSIDE them changed in an unattributed way.
    /// Nonisolated: pure over its inputs — the W5a apply service reuses it
    /// off the main actor.
    nonisolated static func observedChangeRanges(before: String, after: String) -> [PagePatchHunk] {
        let a = Array(before.utf8)
        let b = Array(after.utf8)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldEnd = a.count - suffix
        let newEnd = b.count - suffix
        guard prefix < oldEnd || prefix < newEnd else { return [] } // identical
        return [PagePatchHunk(
            startByte: prefix,
            endByte: oldEnd,
            oldText: String(decoding: a[prefix..<oldEnd], as: UTF8.self),
            newText: String(decoding: b[prefix..<newEnd], as: UTF8.self),
            reason: "observed change region (store bytes)")]
    }

    /// Dispatch ONE selected-page lint run and return its outcome. A page's
    /// failure never becomes another page's clean audit; the caller decides
    /// whether to continue.
    public static func runOneLintPage(
        pageID: PageID,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async -> LintPageDispatchOutcome {
        let runStart = Date()
        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher),
              let plan = await makeLintPagePlan(
                store: store.internalStore, pageID: pageID, stateMarkdown: stateMarkdown) else {
            return LintPageDispatchOutcome(
                pageID: pageID, title: "", status: .skipped,
                detail: "page does not exist (deleted or renamed before the run)")
        }
        await run(
            request: plan.request,
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory)

        return accountForLintRun(
            plan: plan, pageID: pageID, launcher: launcher,
            store: store.internalStore, runStart: runStart)
    }

    /// The host-agnostic POST-RUN ACCOUNTING for one lint page (plan
    /// §5.9–§5.13, review M1): read the filled run report from the run
    /// scratch, validate coverage against THIS plan's inventory, re-scan
    /// the written bytes and run the REQ-54 compare with store-observed
    /// change regions, detect the agent's own log append, and append the
    /// host's `--kind lint` record. Every host (app UI, app queue, daemon
    /// queue) runs the SAME accounting; a launcher exit status alone never
    /// produces a passing outcome.
    ///
    /// W2a enforcement: a verification failure triggers ONE CAS-guarded
    /// revert to the inspected head; a daemon patch-budget rejection marks
    /// the write phase not performed; a repair-authorized run records its
    /// outcome in the circuit breaker; and the audit line names the
    /// authority tier and approval row. `producedHead` is the head the run's
    /// own write produced when the host knows it (the daemon's
    /// written-version record); otherwise the head read after the run
    /// stands in for it.
    public static func accountForLintRun(
        plan: LintPagePlan,
        pageID: PageID,
        launcher: AgentLauncher,
        store: WikiStore,
        runStart: Date,
        producedHead: PageVersionID? = nil
    ) -> LintPageDispatchOutcome {
        accountForLintRun(
            plan: plan, pageID: pageID,
            scratchDirectory: launcher.lastScratchDirectory,
            store: store, runStart: runStart, producedHead: producedHead)
    }

    /// The accounting body over an explicit run scratch (tests stage a
    /// filled run report there directly).
    static func accountForLintRun(
        plan: LintPagePlan,
        pageID: PageID,
        scratchDirectory: URL?,
        store: WikiStore,
        runStart: Date,
        producedHead: PageVersionID?
    ) -> LintPageDispatchOutcome {
        // Post-run accounting: the host reads the filled run report back
        // from the run's scratch and validates coverage against THIS plan's
        // inventory (REQ-31/32). The agent's claims never stand alone.
        var detail = "audited head \(plan.snapshot.headVersionID?.rawValue ?? "none")"
        var status = LintPageDispatchOutcome.Status.dispatched
        var authority = plan.authority
        var revert: LintRevertOutcome?
        let pageTitleToken = plan.snapshot.title

        // The run's lint log entries, read once: the daemon's budget
        // rejection record and the agent's own append both live here.
        let recentLintEntries: [LogEntry]?
        do {
            recentLintEntries = try store.recentLogEntries(limit: 200)
                .filter { $0.kind == .lint && $0.timestamp >= runStart }
        } catch {
            DebugLog.agent("lint dispatch: log read failed; treating the agent log as missing: \(error)")
            recentLintEntries = nil
        }
        // W2a §3: the trusted daemon rejected this page's patch WHOLE for
        // exceeding the run's patch budget — no repair happened.
        let budgetTitle = LintPatchBudget.auditTitlePrefix + pageTitleToken
        if let rejection = recentLintEntries?.first(where: { $0.title == budgetTitle }) {
            let numbers = rejection.note ?? "budget_exceeded"
            authority = authority.demoted(to: .budgetExceeded, reason: numbers)
            detail += "; write phase not performed — patch rejected whole: \(numbers)"
        }

        // The validated run report, if the run scratch carried a parseable
        // one — hoisted so the findings labels below can name each
        // detection's assigned outcome.
        var parsed: ParsedLintRunReport?
        if let scratch = scratchDirectory {
            let reportURL = scratch.appendingPathComponent(AgentStaging.lintRunReportFileName)
            let reportText: String?
            do {
                reportText = try String(contentsOf: reportURL, encoding: .utf8)
            } catch {
                DebugLog.agent("lint dispatch: run report unreadable at \(reportURL.path): \(error)")
                reportText = nil
            }
            if let text = reportText {
                do {
                    parsed = try LintRunReportParser.parse(text)
                } catch {
                    DebugLog.agent("lint dispatch: run report unparseable: \(error)")
                    parsed = nil
                }
            } else {
                parsed = nil
            }
            if let parsed {
                switch LintCoverageValidator.validate(
                    parsed: parsed, snapshot: plan.snapshot, preflight: plan.preflight) {
                case .complete:
                    detail += "; run-report coverage complete"
                case .rejected(let reasons):
                    status = .failed
                    detail += "; run-report coverage rejected: "
                        + reasons.prefix(3).joined(separator: "; ")
                }
                // §5.12: unresolved/blocked findings stay named in the host
                // record — a coverage-complete report can still carry them.
                let openFindings = parsed.entries.compactMap { entry -> String? in
                    guard case .finding(let id) = entry.kind else { return nil }
                    switch entry.outcome {
                    case .unresolved, .checkBlocked, .pending:
                        return id
                    case .repaired, .validAsWritten, .outsideLintScope:
                        return nil
                    }
                }
                if openFindings.isEmpty == false {
                    detail += "; unresolved: \(openFindings.joined(separator: ","))"
                }
                if authority.tier == .stagedProposal {
                    // W5a tier 2: the run STAGED proposals instead of
                    // writing — there is no written head to verify, and a
                    // staging run's report may not claim `.repaired` (or a
                    // written-head verification) AT ALL. The applied/
                    // unapplied truth is the trusted apply path's own audit
                    // records (`Lint proposal applied — <title>` with an
                    // exact `outcome=` label and proposal id), and the
                    // review UI renders from those — never from the child's
                    // words. Any repair claim — through ANY row kind
                    // (`finding` or `item`; `item D08-1 repaired` once
                    // slipped past a finding-only check) — is fabricated
                    // success: coverage FAILS and the claimed findings
                    // stay on the unresolved list. Even a trusted applied
                    // record does not launder a claim: an
                    // `applied-then-reverted` outcome, ANOTHER proposal's
                    // application, or a same-title page's record would
                    // otherwise read as success.
                    // (If post-approval claim support is ever genuinely
                    // needed, it must join an EXACT successful outcome by
                    // proposal ID + page + run + written head and re-verify
                    // the claimed findings — deliberately not built now.)
                    let claimedRepairs = parsed.entries.filter { entry in
                        if case .repaired = entry.outcome { return true }
                        return false
                    }
                    let claimedRepairIDs = claimedRepairs.compactMap { entry -> String? in
                        switch entry.kind {
                        case .item(let id), .finding(let id): return id
                        case .check: return nil
                        }
                    }
                    let claimsWrittenHead = parsed.verification?.writtenHead != nil
                    if claimedRepairs.isEmpty == false || claimsWrittenHead {
                        status = .failed
                        detail += "; tier-2 report rejected: "
                            + "\(claimedRepairs.count) repair claim(s)"
                            + (claimsWrittenHead
                                ? " and a written-head verification claim"
                                : "")
                            + " — a staging run may not claim repairs; the trusted apply records are the truth"
                        // The claimed findings are NOT repaired — they
                        // stay named on the unresolved list.
                        if claimedRepairIDs.isEmpty == false {
                            detail += "; unresolved: "
                                + claimedRepairIDs.joined(separator: ",")
                        }
                    }
                    // Fold the daemon's staged-proposal audit entries into
                    // the record so the durable per-page trace carries the
                    // proposal count and record references ("N proposed").
                    detail += Self.stagedProposalDetail(
                        pageToken: pageTitleToken, runStart: runStart, store: store)
                } else {
                    // REQ-54: the app-side verification gate — re-scan the
                    // WRITTEN bytes and compare against the pre-run scan using
                    // hunks OBSERVED from the store (prefix/suffix-trimmed
                    // change region), never the agent's claims alone.
                    let claimedRepairs = Set(parsed.entries.compactMap { entry -> String? in
                        guard case .finding(let id) = entry.kind,
                              case .repaired = entry.outcome else { return nil }
                        return id
                    })
                    do {
                        let writtenRead = try store.readPageCoherent(id: pageID)
                        // Review M3(a): the written scan runs with the SAME
                        // fact set as the pre-run scan (M3(a) fix) so D09/D27/
                        // D28 findings persist or resolve consistently — never
                        // vanishing because the second scan was facts-less.
                        // Every fact load failure marks a required check
                        // unavailable — the compare fails closed over
                        // degraded facts instead of verifying them.
                        var writtenChecksAvailable = true
                        let resolution: LintResolutionFacts
                        do {
                            resolution = try LintResolutionFacts.load(from: store)
                        } catch {
                            DebugLog.agent("lint dispatch: resolution facts unavailable for verification: \(error)")
                            resolution = LintResolutionFacts()
                            writtenChecksAvailable = false
                        }
                        let citations: LintCitationFacts?
                        do {
                            citations = try LintCitationFacts.load(from: store, body: writtenRead.body)
                        } catch {
                            DebugLog.agent("lint dispatch: citation facts unavailable for written scan: \(error)")
                            citations = nil
                            writtenChecksAvailable = false
                        }
                        let origins: LintOriginURLFacts?
                        do {
                            origins = try LintOriginURLFacts.load(from: store, body: writtenRead.body)
                        } catch {
                            DebugLog.agent("lint dispatch: origin facts unavailable for written scan: \(error)")
                            origins = nil
                            writtenChecksAvailable = false
                        }
                        let writtenSnapshot = LintPageSnapshot(writtenRead)
                        let history = LintHistoryFacts.load(
                            from: store, snapshot: writtenSnapshot)
                        if case .readFailed(let reason) = history.availability {
                            DebugLog.agent("lint dispatch: history facts unavailable for written scan: \(reason)")
                            // D27's read failure blocks its section, not a
                            // finding — the written verification the run
                            // promised cannot have run, so it gates the
                            // compare's availability like every other fact
                            // load.
                            writtenChecksAvailable = false
                        }
                        // D28's fence-validation facts are async; the compare
                        // only needs findings that carry candidate repairs, and
                        // D28 findings never do — omitting them here cannot
                        // flip a verdict.
                        let writtenScan = LintPagePreflight.scan(
                            snapshot: writtenSnapshot,
                            resolution: resolution,
                            citations: citations,
                            originURLs: origins,
                            history: history)
                        let observed = Self.observedChangeRanges(
                            before: plan.snapshot.body, after: writtenSnapshot.body)
                        // The run's written head: the daemon's record when the
                        // host has it, else the head read now. A difference is
                        // the written-vs-current divergence the compare reports.
                        let writtenHead = producedHead ?? writtenRead.headVersionID
                        let verdict = LintVerification.compare(
                            before: plan.preflight,
                            written: writtenScan,
                            appliedHunks: observed,
                            claimedRepairFindingIDs: claimedRepairs,
                            writtenHead: writtenHead,
                            currentHead: writtenRead.headVersionID,
                            requiredChecksAvailable: plan.requiredChecksAvailable
                                && writtenChecksAvailable)
                        switch verdict.status {
                        case .verified:
                            detail += "; verification verified on the written head"
                            Self.recordBreakerOutcome(.clean, plan: plan, authority: authority)
                        case .verifiedWrittenHeadDiverged(let current):
                            detail += "; verification verified on the written head; current head diverged to \(current.rawValue)"
                            Self.recordBreakerOutcome(.clean, plan: plan, authority: authority)
                        case .failed(let reasons):
                            status = .failed
                            detail += "; verification failed: "
                                + reasons.prefix(3).joined(separator: "; ")
                            // W2a §2: never leave a bad write in place silently,
                            // never clobber a concurrent edit.
                            let outcome = Self.revertFailedLintWrite(
                                store: store, pageID: pageID,
                                inspectedHead: plan.snapshot.headVersionID,
                                writtenHead: writtenHead)
                            revert = outcome
                            detail += "; \(outcome.auditLabel)"
                            Self.recordBreakerOutcome(.verificationFailure, plan: plan, authority: authority)
                        }
                    } catch {
                        status = .failed
                        detail += "; written-version verification could not run: \(error)"
                    }
                }
            } else {
                status = .failed
                detail += "; run report missing or unparseable in the run scratch"
            }
        } else {
            detail += "; no run scratch to read the run report from"
        }

        // Plan §5.13/§5.14: the record carries what the trusted pre-flight
        // scan DETECTED — class labels, counts, evidence — with the outcome
        // the validated report assigned to each. A report-only run writes
        // nothing, so these labels are the only durable findings data its
        // Run Details rendering can read.
        detail += "; " + LintPageRecordFacts.findingsDetail(
            preflight: plan.preflight, report: parsed)

        // §5.12: the HOST appends the required `--kind lint` entry for the
        // completed audit and detects whether the AGENT's own append
        // committed. A missing agent log (or a failed host append) means the
        // run can never report complete success.
        let writtenHead: PageVersionID?
        do {
            writtenHead = try store.readPageCoherent(id: pageID).headVersionID
        } catch {
            DebugLog.agent("lint dispatch: post-run read failed: \(error)")
            writtenHead = nil
        }
        detail += "; written_head=\(writtenHead?.rawValue ?? plan.snapshot.headVersionID?.rawValue ?? "none")"
        // Review M7: the agent's log entry must name THIS page (the task
        // template's title includes the page name), not just any lint entry
        // appended since the run started — a concurrent lint elsewhere must
        // not satisfy this page's contract. The daemon's own records (the
        // budget rejection and the W5a staged-proposal entries) name the
        // page too, but they are not the agent's log.
        let agentLogCommitted = recentLintEntries?.contains { entry in
            entry.title.hasPrefix(LintPatchBudget.auditTitlePrefix) == false
                && entry.title.hasPrefix(LintProposalAudit.stagedAuditTitlePrefix) == false
                && (entry.title.contains(pageTitleToken)
                    || entry.note?.contains(pageTitleToken) == true)
        } ?? false
        if agentLogCommitted == false {
            status = .failed
            detail += "; AGENT LOG MISSING — the agent never appended its --kind lint entry"
        }
        // W2a §4: every outcome traces back to what allowed it.
        detail += "; \(authority.auditLabels)"
        do {
            try store.appendLog(
                kind: .lint,
                title: "Selected-page lint — \(pageTitleToken)",
                note: "host audit record; \(detail)")
        } catch {
            status = .failed
            detail += "; HOST LOG APPEND FAILED: \(error)"
        }
        return LintPageDispatchOutcome(
            pageID: pageID, title: plan.snapshot.title, status: status, detail: detail,
            authority: authority, revert: revert)
    }

    /// W2a §2: put a verification-failed page back to the run's inspected
    /// head — ONLY while the current head is still the head this run wrote
    /// (an expected-head CAS inside the store transaction). A concurrent
    /// writer's version is never clobbered: the revert is refused and the
    /// page flagged. Nonisolated: store-atomic + logging only — the W5a
    /// apply service reuses it off the main actor.
    nonisolated static func revertFailedLintWrite(
        store: WikiStore,
        pageID: PageID,
        inspectedHead: PageVersionID?,
        writtenHead: PageVersionID?
    ) -> LintRevertOutcome {
        guard let inspectedHead else {
            return .notAttempted(reason: "no inspected head to return to")
        }
        guard let writtenHead else {
            return .notAttempted(reason: "no written head")
        }
        guard writtenHead != inspectedHead else {
            return .notAttempted(reason: "the run wrote nothing")
        }
        do {
            try store.revertPage(pageID: pageID, to: inspectedHead, expectingHead: writtenHead)
            DebugLog.agent("lint dispatch: reverted \(pageID.rawValue) to \(inspectedHead.rawValue) after a verification failure")
            return .reverted(to: inspectedHead, from: writtenHead)
        } catch let conflict as PageConflictError {
            DebugLog.agent("lint dispatch: revert refused for \(pageID.rawValue) — head moved to \(conflict.actualVersionID?.rawValue ?? "none")")
            return .refusedHeadDiverged(written: writtenHead, current: conflict.actualVersionID)
        } catch {
            DebugLog.agent("lint dispatch: revert failed for \(pageID.rawValue): \(error)")
            return .failed(reason: "\(error)")
        }
    }

    /// Record a repair run's outcome in the breaker — only for runs that ran
    /// under a shipped approval (a report-only, demoted, or budget-rejected
    /// run made no repair to judge).
    private static func recordBreakerOutcome(
        _ kind: LintRepairOutcomeKind,
        plan: LintPagePlan,
        authority: LintRepairAuthority
    ) {
        guard authority.tier == .shippedApproval,
              let breaker = plan.breaker, let key = plan.breakerKey else { return }
        breaker.record(kind, for: key)
    }

    /// The tier-2 record segments for one run's page (W5a §3): read the
    /// daemon's staged-proposal audit entries back (the trusted host wrote
    /// one per staged proposal, titled with the page) and render the
    /// `proposals=N; staged_proposal=<id>` labels the durable per-page
    /// record carries — the review UI's "N proposed" data source.
    static func stagedProposalDetail(
        pageToken: String,
        runStart: Date,
        store: WikiStore
    ) -> String {
        let labels = LintProposalAudit.recordLabels(
            proposals: stagedProposalNotes(pageToken: pageToken, runStart: runStart, store: store))
        return labels.isEmpty ? "" : "; \(labels)"
    }

    /// The daemon's staged-proposal audit notes for one page since the run
    /// started — the TRUSTED staged records (the title prefix is reserved to
    /// the host, so a child cannot forge one).
    static func stagedProposalNotes(
        pageToken: String,
        runStart: Date,
        store: WikiStore
    ) -> [LintProposalAudit.StagedNote] {
        let entries: [LogEntry]
        do {
            entries = try store.recentLogEntries(limit: 200)
                .filter { $0.kind == .lint && $0.timestamp >= runStart }
        } catch {
            DebugLog.agent("lint dispatch: log read failed; staged proposals not counted: \(error)")
            return []
        }
        return entries
            .filter { $0.title == LintProposalAudit.stagedAuditTitlePrefix + pageToken }
            .compactMap { LintProposalAudit.parseStagedNote($0.note) }
    }

    /// Dispatch selected-page lint runs SEQUENTIALLY — one run, scope, and
    /// outcome per requested page. Pages already handled are never retried
    /// because another page failed; cancellation stops future pages.
    public static func runLintPages(
        pages: [PageID],
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String
    ) async -> [LintPageDispatchOutcome] {
        var outcomes: [LintPageDispatchOutcome] = []
        for pageID in pages {
            if Task.isCancelled {
                outcomes.append(LintPageDispatchOutcome(
                    pageID: pageID, title: "", status: .skipped,
                    detail: "run cancelled before this page started"))
                continue
            }
            let outcome = await runOneLintPage(
                pageID: pageID, launcher: launcher, store: store, wikiID: wikiID,
                changeSignaler: changeSignaler, wikictlDirectory: wikictlDirectory)
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// Render the `WIKI_STATE.md` for one operation request, or surface the
    /// failure as the launcher's preflight error and return nil so NO request
    /// is built. A strategy read failure must never degrade to the Default
    /// strategy: authoritative editorial instructions cannot be invented from
    /// a store error (the same contract as the daemon chat's per-turn strategy
    /// read).
    /// Internal so the evaluation dispatch (`LintEvaluationDispatch.swift`)
    /// can drive the same preflight capture production runs use.
    static func stateMarkdownForRequest(
        store: WikiStoreModel,
        launcher: AgentLauncher
    ) -> String? {
        do {
            return try store.currentStateSnapshot().renderStateFile()
        } catch {
            DebugLog.agent("operation preflight: wiki state capture failed — no request: \(error)")
            launcher.preflightError = error.localizedDescription
            return nil
        }
    }

    /// Internal so the evaluation dispatch (`LintEvaluationDispatch.swift`)
    /// can drive the same launcher dispatch production runs use.
    static func run(
        request: OperationRequest,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String,
        ingestingSourceIDs: Set<SourceID> = [],
        workspaceID: WorkspaceID? = nil,
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
        let leaf = FilenameEscaping.byIDSourceFilename(sourceID: source.id, ext: source.ext)
        return "sources/by-id/\(leaf)"
    }

    // MARK: - Per-message summary (chat-summary plan §6.1)

    /// Summarize all unsummarized assistant messages in `chatID` per the
    /// configured summarizer mode (chat-summary plan §6.1). Called from the
    /// `onMessageSummary` sink wired into `startInteractiveQuery`, which fires
    /// once in `AgentLauncher.finish()` after `flushTranscript()` commits the
    /// turn's messages.
    ///
    /// **Mode dispatch** gates STRICTLY on `stageProviderIds["summarizer"]`
    /// (chat-summary plan §5.1 invariant — never `provider(forStage:)`):
    /// - **Default** (empty/absent pin): inline `ChatSummary.summaryExtract`
    ///   via `MessageSummarizer.defaultSummary` — pure, cheap, no model call.
    /// - **Model** (non-empty pin): off-main `Task` driving a one-shot ACP
    ///   session per message via the injected `AgentBackend`. The DB write is
    ///   marshalled back to `@MainActor`.
    ///
    /// **Idempotency (AC.6):** only messages with `summary == nil` are
    /// summarized — the store query is the compute-once guard. Re-firing the
    /// sink (e.g. on a second turn) is a no-op for already-summarized rows.
    ///
    /// **Chat-level summary (issue #411):** the FIRST summarizable message's
    /// summary is cached on the message as it
    /// is written. This is the only writer of that column — the launcher no
    /// longer computes its own always-truncated version, which is what made the
    /// subtitle abbreviate even in Model mode.
    @MainActor
    static func summarizePendingMessagesForTesting(
        chatID: ChatID,
        store: WikiStoreModel?,
        launcher: AgentLauncher
    ) async {
        guard let store else { return }
        await summarizePendingMessagesNow(
            chatID: chatID,
            store: store,
            launcher: launcher)
    }

    @MainActor
    private static func summarizePendingMessages(
        chatID: ChatID, store: WikiStoreModel?, launcher: AgentLauncher
    ) {
        guard let store else {
            DebugLog.ingest("summarizePendingMessages: store torn down, skipping")
            return
        }
        Task { @MainActor in
            await Self.summarizePendingMessagesNow(
                chatID: chatID,
                store: store,
                launcher: launcher)
        }
    }

    @MainActor
    private static func summarizePendingMessagesNow(
        chatID: ChatID,
        store: WikiStoreModel,
        launcher: AgentLauncher
    ) async {
        // v54 (#1266): pending summaries are detected on the durable
        // transcript (`chat_transcript_items`), not the compatibility
        // `chat_messages` projection.
        var items: [PersistedChatTranscriptItem] = []
        var after: ChatTranscriptCursor?
        // Page budget: guards against a concurrent-writer livelock.
        for _ in 0..<1000 {
            let page = store.readChatTranscriptPage(
                chatID: chatID, after: after, limit: 200)
            items.append(contentsOf: page.items)
            guard let next = page.nextCursor else { break }
            after = next
        }
        let pending = MessageSummarizer.pendingSummaryTargets(from: items)
        guard !pending.isEmpty else { return }
        guard let services = launcher.providerServices else {
            Self.writeDefaultSummaries(chatID: chatID, pending: pending, store: store)
            return
        }
        do {
            let preparation = try await services.prepareSummarization()
            switch preparation {
            case .defaultTruncation:
                Self.writeDefaultSummaries(chatID: chatID, pending: pending, store: store)
            case .model(let preparation):
                await Self.runModelSummarization(
                    chatID: chatID,
                    pending: pending,
                    services: services,
                    preparation: preparation,
                    store: store)
                await services.release(preparation.selection.token)
            case .appleIntelligence:
                // In process, no snapshot or lease — nothing to release.
                await Self.runAppleIntelligenceSummarization(
                    chatID: chatID,
                    pending: pending,
                    services: services,
                    store: store)
            }
        } catch AgentProviderRuntimeError.unavailable {
            Self.writeDefaultSummaries(chatID: chatID, pending: pending, store: store)
        } catch {
            DebugLog.agent("AgentOperationRunner: summarization preparation failed: \(error)")
        }
    }

    @MainActor
    private static func writeDefaultSummaries(
        chatID: ChatID,
        pending: [(cursor: ChatTranscriptCursor, text: String)],
        store: WikiStoreModel
    ) {
        for target in pending {
            let summary = MessageSummarizer.defaultSummary(for: target.text)
            guard !summary.isEmpty else { continue }
            store.updateMessageSummary(chatID: chatID, cursor: target.cursor, summary: summary, kind: .defaultTruncation)
        }
    }

    /// Runs one-shot summarizer sessions through one frozen provider preparation.
    @MainActor
    private static func runModelSummarization(
        chatID: ChatID,
        pending: [(cursor: ChatTranscriptCursor, text: String)],
        services: any AgentProviderServices,
        preparation: AgentOperationPreparation,
        store: WikiStoreModel
    ) async {
        for target in pending {
            do {
                guard let summary = try await services.modelSummary(
                    text: target.text,
                    preparation: preparation) else {
                    // Issue #1276 strict tier: nil is a FAILED summarization
                    // (launch failure, empty reply, preamble-only reply) —
                    // `MessageSummarizer.oneShotReply` swallows the error and
                    // returns nil. Degrade to the truncation summary exactly
                    // like the thrown path; never a silent unsummarized row
                    // (#1279 found this branch skipping the fallback).
                    DebugLog.agent("AgentOperationRunner: model summary returned nil — degrading to truncation")
                    Self.writeDefaultSummaries(chatID: chatID, pending: [target], store: store)
                    continue
                }
                store.updateMessageSummary(
                    chatID: chatID, cursor: target.cursor,
                    summary: summary, kind: .model)
            } catch {
                // Issue #1276 strict tier: a launch failure (e.g. an adapter
                // the strict sandbox fences) must DEGRADE to the default
                // truncation summary — never leave the message unsummarized.
                DebugLog.agent("AgentOperationRunner: model summary failed — degrading to truncation: \(error.localizedDescription)")
                Self.writeDefaultSummaries(chatID: chatID, pending: [target], store: store)
            }
        }
    }

    /// Drive Apple Intelligence summarization for the pending batch. Mirrors
    /// `runModelSummarization` without the preparation and the release: the
    /// AI turn runs in process, so there is no token to retire. The same
    /// strict-tier degradation applies — a nil result (empty reply, error,
    /// timeout) degrades to the truncation summary, never a silent
    /// unsummarized row.
    @MainActor
    private static func runAppleIntelligenceSummarization(
        chatID: ChatID,
        pending: [(cursor: ChatTranscriptCursor, text: String)],
        services: any AgentProviderServices,
        store: WikiStoreModel
    ) async {
        for target in pending {
            guard let summary = await services.appleIntelligenceSummary(text: target.text) else {
                DebugLog.agent("AgentOperationRunner: Apple Intelligence summary returned nil — degrading to truncation")
                Self.writeDefaultSummaries(chatID: chatID, pending: [target], store: store)
                continue
            }
            // Non-throwing: `WikiStoreModel.updateMessageSummary` logs write
            // failures itself (same as `writeDefaultSummaries` above).
            store.updateMessageSummary(
                chatID: chatID, cursor: target.cursor,
                summary: summary, kind: .model)
        }
    }
}
#endif
