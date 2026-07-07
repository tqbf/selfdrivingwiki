import Foundation
import Observation
import WikiFSCore

/// Runs the three `claude -p` operations — Ingest / Query / Lint — against the
/// currently-selected wiki, streaming a live activity feed back into the app
/// (`plans/llm-wiki.md` Phase C). Generalizes the v0 agent launcher: instead of a
/// free-form shell command, it spawns a scoped `claude -p` invocation built by the
/// pure `OperationCommand.build(...)` seam, now with `--output-format stream-json`
/// so the run is visible as it happens instead of silent until the final result.
///
/// Allowed because the app is **un-sandboxed** (`WikiFS/WikiFS.entitlements` — no
/// `com.apple.security.app-sandbox`); a sandboxed app could not `Process`-spawn.
///
/// `@MainActor @Observable`: the view binds `events`, `isRunning`, `exitStatus`,
/// `preflightError`, and `logFileURL`. State is mutated on the main actor from the
/// pipe `readabilityHandler`s — we NEVER block on `waitUntilExit`; completion
/// arrives via `terminationHandler`, which is also where the per-wiki edit lock
/// releases.
@MainActor
@Observable
final class AgentLauncher {
    /// The live, ordered activity feed for the current/last run: typed events parsed
    /// from the stream-json NDJSON. The UI renders these as tool-call rows, prose,
    /// and a final result. Appended on the main actor as lines arrive.
    ///
    /// Exposed without `private(set)` so tests can simulate "a transcript is
    /// visible" via `@testable import WikiFS`, without requiring a real spawned
    /// process.
    var events: [AgentEvent] = []
    /// The raw combined transcript (raw stream-json stdout + stderr) kept alongside
    /// the typed `events`, so the UI / a debugger can see exactly what the CLI
    /// emitted. This is the in-memory mirror of the on-disk `run.jsonl`.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing transcript
    /// state via `@testable import WikiFS`.
    var rawTranscript = ""
    /// stderr captured separately (claude's diagnostics): a failed start, a flag
    /// error, an auth prompt. Surfaced prominently in the UI rather than swallowed.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing stderr
    /// state via `@testable import WikiFS`.
    var stderr = ""
    var extractionLog = ""
    /// True while a local `pdf2md` conversion subprocess is running (before the
    /// agent itself starts). Drives the PDF-extraction spinner / Cancel affordance.
    var isExtracting = false
    /// PID of the running `pdf2md` conversion subprocess, surfaced in the UI so a
    /// stuck conversion can be identified (and killed) by the user.
    var extractionPID: Int32?
    /// The ingested-file ids whose **agent run** is in flight — set only once the
    /// claude spawn is actually committed (around `onLock`), and cleared in
    /// `finish()`. Drives the per-file "Ingesting…" row label and the cross-file
    /// `isAnySourceIngesting` Ingest-button greyout. This is the **agent phase**
    /// flag; it is NOT set during the pdf2md extraction phase that precedes the
    /// spawn (see `extractingSourceIDs`), so a pure extraction no longer mislabels
    /// a row as "Ingesting…" or greys out another file's Ingest button.
    var ingestingSourceIDs: Set<PageID> = []
    /// The ingested-file ids whose **pdf2md conversion** is in flight — set around
    /// the pdf2md block of EITHER extraction path (the ingest-path conversion in
    /// `AgentOperationRunner.runMultiIngest`, and the standalone
    /// `SourceDetailView.runExtraction`), and cleared when the conversion ends
    /// (success or failure). Drives the per-file "Extracting…" row label and the
    /// standalone Extract button's per-file disable. This is the **extraction
    /// phase** flag; it never feeds the cross-file Ingest greyout (that is
    /// `ingestingSourceIDs` only) and never touches the generation gate or edit lock.
    var extractingSourceIDs: Set<PageID> = []
    /// The in-flight ingest operation Task (set by `IngestSheetView`). Cancelling
    /// it aborts a running `pdf2md` conversion (via its task-cancellation handler).
    /// Held here so `stop()` — driven from the transcript sidebar too — can cancel
    /// the conversion phase, not just the agent process. Self-clears when done.
    @ObservationIgnored var ingestTask: Task<Void, Never>?
    /// The in-flight standalone extraction Task (set by the Extract Markdown button
    /// in `SourceDetailView`). Mirror of `ingestTask` for the standalone
    /// extract path — cancelled by `stop()` so the pdf2md subprocess is terminated
    /// via `PdfExtractionService`'s `onCancel` handler. Self-clears when done.
    @ObservationIgnored var extractTask: Task<Void, Never>?
    /// True while a spawned `claude -p` process is alive (one-shot runs: from spawn
    /// to finish; interactive sessions: from spawn to session end, across all turns).
    /// Set at spawn commit in `run()` and `startInteractiveQuery()`; cleared in
    /// `finish()`. This is NOT coupled to the generation gate — the gate serializes
    /// ACTIVE GENERATION (a turn in flight), not process lifetime. An interactive
    /// session's process is alive between turns without holding the gate.
    ///
    /// Exposed without `private(set)` so tests can simulate "process alive" state
    /// via `@testable import WikiFS`, without requiring a real spawned process.
    var isRunning = false
    /// True only while the agent is actively producing output. For one-shot runs
    /// (ingest/lint/query) this mirrors `isRunning` for the run's duration. For an
    /// interactive query session it tracks the *current turn*: set when a message is
    /// sent, cleared when the terminal `.result` or `.messageStop` event arrives —
    /// so an open-but-idle session does not show a perpetual spinner. Every UI
    /// spinner / Stop affordance keys off this rather than the raw `isRunning`.
    private(set) var isGenerating = false
    /// True while an interactive session is queued waiting to acquire the shared
    /// generation gate (another launcher is currently generating). Cleared when the
    /// slot is acquired, when the wait is cancelled, or when the session ends.
    /// Published so the UI can show a "Waiting for the other session to finish…"
    /// hint and keep `canSend` false — the message is NOT silently dropped.
    private(set) var isAwaitingGenerationSlot = false
    /// Exit status of the last finished process, or nil if none finished / one is
    /// running.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing exit
    /// status via `@testable import WikiFS`.
    var exitStatus: Int32?
    /// Set when the PATH preflight fails (claude not resolvable) or the spawn
    /// itself throws; shown in the UI instead of spawning. Cleared on the next
    /// successful run. Settable from `AgentOperationRunner` for silent-failure
    /// paths where no agent process is spawned.
    var preflightError: String?
    /// The kind of the operation currently running (drives the UI title / spinner).
    ///
    /// Exposed without `private(set)` so tests can simulate "a non-query run is
    /// active" (e.g. `.ingest`) via `@testable import WikiFS`, without requiring a
    /// real spawned process.
    var runningKind: WikiOperation.Kind?
    /// The per-run `run.jsonl` backend log on disk (raw stream-json), so the UI can
    /// offer a "Reveal log" affordance. Its sibling `run.stderr.log` holds stderr.
    private(set) var logFileURL: URL?
    /// Wall-clock start time for the current/last run. Used by the UI to show a
    /// heartbeat instead of a context-free spinner.
    private(set) var runStartedAt: Date?
    /// Last time stdout/stderr produced bytes, or the run state changed. A live
    /// process with an old `lastActivityAt` is not necessarily dead, but the UI can
    /// name that it is quiet.
    private(set) var lastActivityAt: Date?
    /// The spawned process ID while running, useful context when a run looks quiet.
    private(set) var currentProcessID: Int32?

    /// Builds the login-shell PATH-resolved `claude` path. Injected so tests can
    /// stub it; the app uses the real login-shell preflight.
    @ObservationIgnored var resolveClaude: () -> PathPreflight.Result = {
        PathPreflight.resolveOnLoginShell(executable: "claude")
    }

    /// The App Group container directory for loading `AgentCommandConfig`. When
    /// nil (the default), resolved via `DatabaseLocation.appGroupContainerDirectory()`
    /// at spawn time. Injected for tests; existing `AgentLauncher()` call sites are
    /// unchanged.
    var containerDirectory: URL? = nil

    /// The agent backend. Default `ClaudeCLIBackend` (today's Claude-CLI
    /// stream-json code, moved behind the `AgentBackend` port). Injectable so
    /// tests can substitute a stub backend.
    @ObservationIgnored var backend: AgentBackend = ClaudeCLIBackend()
    /// The active session handle (nil when no session is live). Replaces the
    /// old `process: Process?` — the launcher never touches a `Process` directly.
    @ObservationIgnored private var sessionHandle: SessionHandle?
    /// The edit-lock release closure for the current run (nil when no lock is held).
    /// Stored so `finish()` — and thus the completion watchdog — can release the
    /// lock even when the process's `terminationHandler` never fires. Without this,
    /// a process that dies unreconciled strands `store.isAgentRunning` (and the
    /// "Agent is updating the wiki" banner) forever.
    @ObservationIgnored private var onUnlockHandler: (@MainActor @Sendable () -> Void)?
    /// Per-turn edit-lock callback for interactive query sessions. Fires on every
    /// REAL `isGenerating` transition (acquire on `true`, release on `false`). The
    /// runner installs it so the per-turn lock releases BETWEEN turns even when the
    /// Query view is not on screen — the old view-side `.onChange(of: isGenerating)`
    /// never fired while the view was unmounted, so the lock stuck until session end.
    /// `nil` for one-shot runs (those lock for the whole run via `onLock`/`onUnlock`
    /// only). Cleared in `finish()` and `resetRunArtifacts()`.
    ///
    /// Per-turn semantics (Step 6): for an Edit-mode interactive session, the
    /// generation gate release (per turn) now genuinely lets ingest run between
    /// turns. The per-turn lock release via `onTurnBoundary(false)` is the mechanism
    /// that makes this visible to the wiki store.
    @ObservationIgnored private var onTurnBoundaryHandler: (@MainActor (Bool) -> Void)?
    /// Persistence callback for an interactive query conversation (issue #119).
    /// Receives the not-yet-persisted TAIL of `events` at each turn boundary and
    /// once more at `finish()` — never the full array, so repeated flushes stay
    /// cheap. The sink's owner (`AgentOperationRunner`) is what actually writes to
    /// the store; the launcher only knows "hand this slice somewhere." `nil` for
    /// one-shot runs and whenever no chat has been created for the session (e.g.
    /// `store.startChat` failed). Cleared in `finish()` and `resetRunArtifacts()`.
    @ObservationIgnored private var transcriptSink: (@MainActor ([AgentEvent]) -> Void)?
    /// Cursor into `events`: the count already handed to `transcriptSink`. Makes
    /// `flushTranscript()` incremental — each call only sends events appended since
    /// the last flush — and idempotent when nothing new arrived since the last call.
    private var persistedEventCount = 0
    /// Backstop poller that reconciles the UI if the process `terminationHandler`
    /// is ever missed (see `startCompletionWatchdog`). Cancelled on teardown.
    private var watchdogTask: Task<Void, Never>?
    /// True while the last row in `events` is an in-progress `.assistantText` row
    /// being grown by streamed `.assistantTextDelta` chunks (issue #121). Reset by
    /// any other event (a tool call, a turn boundary, …) so unrelated `.assistantText`
    /// rows are never merged together.
    private var isStreamingAssistantRow = false
    /// Append-only handle to the per-run `run.jsonl` (raw stream-json).
    private var logHandle: FileHandle?
    /// Append-only handle to the per-run `run.stderr.log`.
    private var stderrLogHandle: FileHandle?
    /// True when the running process is waiting for user turns over stdin.
    private(set) var isInteractiveSession = false
    /// The chat row the current live interactive session is writing to (D2).
    /// Set by the runner when it installs the transcript sink — this is the chat
    /// whose `.chat(id)` tab is live-streaming. `ConversationView` uses it as the
    /// source-of-truth switch: when `activeChatID == chatID`, render
    /// `launcher.events` (in-memory, streaming); otherwise render the persisted
    /// `store.chatMessages(chatID:)`. Cleared in `startNewConversation()` (retarget
    /// back to draft) and in `finish()` AFTER the final turn-boundary flush has
    /// committed — clearing it too early re-sources the view from the store before
    /// the tail lands, producing a transient truncated transcript (D2 flip-timing).
    var activeChatID: String?
    /// Stored, cancellable Task for the current interactive send (which waits for
    /// the generation gate before writing to stdin). Cancelled by `stopAgent()` and
    /// `finish()` so an in-flight gate wait doesn't outlive the session.
    @ObservationIgnored private var interactiveSendTask: Task<Void, Never>?

    /// Pure predicate for the Query page's debug cluster (spinner / Stop / Activity
    /// menu): the cluster is visible only while a QUERY turn is actively generating.
    /// Extracted as a pure static function so it is unit-testable without driving
    /// launcher state. The View calls this with its `launcher` state.
    static func showsQueryDebugControls(
        isGenerating: Bool, runningKind: WikiOperation.Kind?
    ) -> Bool {
        isGenerating && runningKind == .query
    }

    /// Centralize EVERY `isGenerating` transition through this one method so the
    /// per-turn callback fires from a single place and redundant transitions (no
    /// real change) are skipped. This is the single owner of the `isGenerating`
    /// invariant: the lock toggles exactly once per real transition, never on a
    /// no-op reassignment. Routing through a method (not a `didSet`) avoids
    /// Observation-macro interaction pitfalls.
    private func setGenerating(_ value: Bool) {
        guard isGenerating != value else { return }
        isGenerating = value
        onTurnBoundaryHandler?(value)
    }

    /// Per-turn generation-gate release policy. Interactive sessions release the
    /// gate at EACH turn boundary (`.messageStop`/`.result`) so a peer launcher or
    /// ingest run can generate between turns. One-shot runs (ingest/lint/query) do
    /// NOT release per-turn — they hold the gate through `finish()`. Releasing in
    /// a one-shot would double-release with `finish()`, but `releaseGenerationSlot`
    /// is idempotent, so the real invariant being encoded is: one-shot runs must
    /// hold the gate for their full duration so no peer generation interleaves.
    /// Extracted as a pure static so the policy is unit-testable without driving
    /// launcher state.
    static func releasesGenerationSlotPerTurn(isInteractiveSession: Bool) -> Bool {
        isInteractiveSession
    }

    /// Pure selection of the interactive-query sandbox. When "Allow wiki edits" is
    /// OFF, the read-only seatbelt sandbox wins REGARDLESS of `editSandbox` — a
    /// global sandbox config can never override the forced read-only boundary. When
    /// ON, `editSandbox` is used (which may itself be `nil`, i.e. fail-open
    /// un-sandboxed). Extracted as a pure static so the read-only-wins invariant is
    /// unit-testable without driving spawn state.
    static func selectQuerySandbox(
        allowWikiEdits: Bool,
        editSandbox: SandboxProfile.SandboxInvocation?,
        readOnlySandbox: SandboxProfile.SandboxInvocation
    ) -> SandboxProfile.SandboxInvocation? {
        allowWikiEdits ? editSandbox : readOnlySandbox
    }

    // MARK: - Three independent mechanisms (relationship)

    /// The launcher coordinates three INDEPENDENT mechanisms. They never touch each
    /// other's state; understanding the boundaries is what keeps extraction from
    /// blocking the user.
    ///
    /// 1. **Generation gate** (`generationGate` / `awaitGenerationSlot` /
    ///    `releaseGenerationSlot`, per-launcher `holdsGenerationSlot` tracks THIS
    ///    launcher's gate state): serializes ACTIVE GENERATION globally across all
    ///    launchers sharing the same `GenerationGate` instance. One active generation
    ///    at a time across ingest / ask / edit / lint, regardless of which launcher
    ///    initiates it. CRITICALLY, "active generation" is scoped differently per path:
    ///    - One-shot runs (ingest/lint/query): hold the gate for the whole run.
    ///    - Interactive sessions (ask/edit): hold the gate only for ONE TURN (from
    ///      send to `messageStop`/`result`). The process itself stays alive between
    ///      turns WITHOUT holding the gate, so both Ask and Edit sessions can coexist
    ///      simultaneously; only one generates at a time.
    ///    `isRunning` is per-instance: it means "THIS launcher has a claude process
    ///    alive." It is NOT coupled to gate ownership — an interactive session's
    ///    `isRunning` stays true across idle turns when the gate is free.
    ///
    /// 2. **Edit lock** (`store.isAgentRunning`), driven by TWO mechanisms:
    ///      - **Session level** (`onLock`/`onUnlock` around the spawn): for
    ///        one-shot runs (ingest/lint/query) and the lifetime of an interactive
    ///        query session, the lock is `true` while a `claude` process is running.
    ///      - **Per-turn** (`onTurnBoundary`, interactive query ONLY): for an
    ///        edit-enabled interactive query, the lock additionally RELEASES between
    ///        turns (`messageStop`/`result`) and RE-ACQUIRES on the next send — so
    ///        the user can ingest while the query agent is idle mid-session. Because
    ///        the generation gate now releases between turns too, ingest can actually
    ///        run during that window (the gate is free when editing is unlocked).
    ///        This is owned by `setGenerating` (single source of truth for the
    ///        transition), not by any View. Neither extraction path touches the lock.
    ///
    /// 3. **Extraction slot** (`extractionWaiters` / `awaitExtractionSlot` /
    ///    `releaseExtractionSlot`, held ↔ `isExtractionSlotBusy`): serializes ONLY
    ///    `pdf2md` conversions against each other (the VLM pipeline is heavy; one
    ///    conversion at a time on a single local machine). Acquiring it does NOT set
    ///    `isRunning`, does NOT set `isExtracting`, and does NOT fire `onLock`. A
    ///    `claude` query run starting during an extraction still runs immediately —
    ///    it takes the generation gate, which the extraction lock never holds.
    ///
    /// The phase flags `extractingSourceIDs` (extraction phase) and
    /// `ingestingSourceIDs` (agent phase, set at spawn commit) are the UI-facing
    /// projection of which lock/phase a file is in; they are kept separate so a
    /// pure extraction is never labeled "Ingesting…" and never greys out a peer's
    /// Ingest button.

    // MARK: - Shared generation gate

    /// The shared gate that serializes all ACTIVE GENERATION. All launchers sharing
    /// the same `GenerationGate` instance contend on a single FIFO queue — ingest,
    /// ask-turn, edit-turn, and lint never generate simultaneously. Each instance
    /// has its own `isRunning` flag (process alive) and `holdsGenerationSlot` flag
    /// (currently generating), which are now DECOUPLED — an interactive session's
    /// process can be alive without holding the gate (between turns).
    let generationGate: GenerationGate

    /// The number of generation requests currently queued for the slot (test seam).
    /// Delegates to the shared gate so single-launcher tests observe the same
    /// count as before.
    var generationSlotWaiterCount: Int { generationGate.waiterCount }

    /// True while this launcher holds the generation gate. For one-shot runs: held
    /// from slot acquire to `finish()`. For interactive sessions: held only while a
    /// turn is in flight (from `sendInteractiveMessage`'s send to `ingestStdout`'s
    /// `endsGeneration` event). Private — observable externally via `isGenerating`.
    @ObservationIgnored private var holdsGenerationSlot = false

    let extractionCoordinator: ExtractionCoordinator

    init(generationGate: GenerationGate = GenerationGate(),
         extractionCoordinator: ExtractionCoordinator = ExtractionCoordinator(
            containerDirectory: FileManager.default.temporaryDirectory)) {
        self.generationGate = generationGate
        self.extractionCoordinator = extractionCoordinator
    }

    /// Wait for the shared generation gate, returning `true` iff this caller
    /// acquired it (and `holdsGenerationSlot` is now `true`). Returns `false` if
    /// the wait was cancelled before the slot was handed over — in that case the
    /// caller owns nothing and must simply return (no release). Cancellation-safe:
    /// a cancelled waiter self-removes from the gate's queue and is never handed
    /// the slot. See `GenerationGate` for the full FIFO + cancellation protocol.
    ///
    /// NOTE: this does NOT touch `isRunning`. Process lifetime (`isRunning`) is
    /// decoupled from generation serialization (`holdsGenerationSlot`).
    func awaitGenerationSlot() async -> Bool {
        let ok = await generationGate.acquire()
        if ok { holdsGenerationSlot = true }
        return ok
    }

    /// Release the generation gate, handing it to the next live waiter (FIFO) or
    /// freeing it. Idempotent: guarded by `holdsGenerationSlot` so double-calls
    /// (e.g. from `finish()` racing an interactive turn's `endsGeneration` release)
    /// are safe. Does NOT touch `isRunning`.
    func releaseGenerationSlot() {
        guard holdsGenerationSlot else { return }
        holdsGenerationSlot = false
        generationGate.release()
    }

    // MARK: - Serialized extraction slot (pdf2md only)

    /// The separate, independent lock that serializes `pdf2md` conversions against
    /// each other. See the "three independent mechanisms" overview above. Held ↔
    /// `isExtractionSlotBusy`. Same FIFO + cancellation-safe shape as the generation
    /// gate, but with its OWN state — it never touches `isRunning`, `isExtracting`,
    /// `onLock`/`onUnlock`, or the generation gate. A `claude` query run starting
    /// while an extraction holds this lock still acquires the generation gate
    /// immediately.
    private var extractionWaiters: [ExtractionWaiter] = []

    /// One queued extraction request. Same shape and rationale as `GenerationWaiter`:
    /// a class so the cancellation handler can identify its waiter by reference and
    /// self-remove it from `extractionWaiters` — a cancelled waiter must never be
    /// handed the slot. `@unchecked Sendable` because it is only ever touched on the
    /// main actor.
    private final class ExtractionWaiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var didReceiveSlot = false
        var didCancel = false
    }

    /// True while a pdf2md conversion holds the extraction lock. Independent of
    /// `isRunning` (generation gate) and `store.isAgentRunning` (edit lock).
    private(set) var isExtractionSlotBusy = false

    /// The number of extraction requests currently queued for the slot (test seam).
    var extractionSlotWaiterCount: Int { extractionWaiters.count }

    /// Wait for the extraction slot, returning `true` iff this caller acquired it
    /// (and `isExtractionSlotBusy` is now `true`). Returns `false` if the wait was
    /// cancelled before the slot was handed over — in that case the caller owns
    /// nothing and must simply return (no release). Cancellation-safe: a cancelled
    /// waiter self-removes from the queue and is never handed the slot. Does NOT
    /// set `isRunning`, `isExtracting`, or fire `onLock` — fully independent of the
    /// generation gate and edit lock.
    func awaitExtractionSlot() async -> Bool {
        // Fast path: slot free and nobody queued — acquire atomically. No
        // suspension point, so no other main-actor task can interleave.
        if !isExtractionSlotBusy && extractionWaiters.isEmpty {
            isExtractionSlotBusy = true
            return true
        }
        let waiter = ExtractionWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if waiter.didCancel {
                    // Cancelled before we could register — resume immediately, don't
                    // enqueue. The caller will see `didReceiveSlot == false`.
                    c.resume()
                    return
                }
                waiter.continuation = c
                extractionWaiters.append(waiter)
            }
        } onCancel: {
            // Hop to the main actor to self-remove. A cancelled waiter must not be
            // handed the slot; if it already was (race with `releaseExtractionSlot`),
            // do nothing — the woken caller will see `Task.isCancelled` and bail,
            // releasing the slot it was handed.
            Task { @MainActor [weak self] in
                guard let self else { return }
                waiter.didCancel = true
                if let idx = self.extractionWaiters.firstIndex(where: { $0 === waiter }),
                   let c = waiter.continuation {
                    self.extractionWaiters.remove(at: idx)
                    c.resume()
                }
            }
        }
        return waiter.didReceiveSlot
    }

    /// Release the extraction slot, handing it to the next live waiter (FIFO) or
    /// freeing it. Called by both extraction paths in a `defer` once the conversion
    /// ends (success or failure). `isExtractionSlotBusy` stays `true` on a handoff
    /// so the transfer is atomic.
    func releaseExtractionSlot() {
        while let head = extractionWaiters.first {
            extractionWaiters.removeFirst()
            if head.didCancel {
                // Already resumed by its cancel handler; don't hand the slot to a
                // dead task.
                continue
            }
            head.didReceiveSlot = true
            head.continuation?.resume()
            return
        }
        // No live waiters: free the slot.
        isExtractionSlotBusy = false
    }

    /// Extract markdown from a PDF source, serialising through the extraction
    /// slot and updating UI state.  Same code path whether triggered from the
    /// detail view or the sidebar context menu.
    func extractPDF(store: WikiStoreModel, id: PageID, filename: String, data: Data) async {
        // Wait for the extraction slot (serialises pdf2md conversions).
        let acquired = await awaitExtractionSlot()
        guard acquired, !Task.isCancelled else {
            if acquired { releaseExtractionSlot() }
            return
        }
        isExtracting = true
        extractingSourceIDs.insert(id)
        extractionLog = ""
        defer {
            isExtracting = false
            extractingSourceIDs.remove(id)
            releaseExtractionSlot()
        }

        let extractor = extractionCoordinator.current()
        switch await extractor.readiness() {
        case .ready:
            do {
                let markdown = try await extractor.convert(
                    pdfData: data, filename: filename,
                    onProgress: { line in
                        Task { @MainActor in self.extractionLog.append(line) }
                    })
                let cfg = extractionCoordinator.config
                _ = store.seedPdfMarkdown(
                    for: id, content: markdown,
                    backend: cfg.backend, modelVersion: cfg.currentModelVersion)
                extractionLog = "Markdown extracted — \(markdown.count) chars."
                DebugLog.extraction("Extracted \(filename): \(markdown.count) chars")
            } catch {
                if Task.isCancelled {
                    extractionLog = "Extraction cancelled."
                } else {
                    extractionLog = "Extraction failed: \(error.localizedDescription)"
                }
                DebugLog.extraction("Extract failed for \(filename): \(error.localizedDescription)")
            }
        case .needsSetup(let message), .notInstalled(let message):
            extractionLog = message
            DebugLog.extraction("Extract backend not ready for \(filename): \(message)")
        }
    }

    /// Ingest a single source.  Convenience — delegates to `ingestSources`.
    func ingestSource(
        sourceID: PageID,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) {
        ingestSources(sourceIDs: [sourceID], store: store, manager: manager, fileProvider: fileProvider)
    }

    /// Ingest one or more sources.  Single entrypoint for both the detail view
    /// and the sidebar context menu — handles extraction, staging, agent spawn,
    /// and UI state tracking.
    func ingestSources(
        sourceIDs: [PageID],
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike
    ) {
        ingestTask?.cancel()
        let task = Task {
            defer { ingestTask = nil }
            await AgentOperationRunner.runMultiIngest(
                sourceIDs: sourceIDs,
                launcher: self,
                store: store,
                manager: manager,
                fileProvider: fileProvider,
                extractionCoordinator: extractionCoordinator)
        }
        ingestTask = task
    }

    /// Run an operation `request` against one wiki. Serializes on the generation gate:
    /// if another `claude -p` run is generating, this `await`s until it finishes (or
    /// this task is cancelled). Returns without spawning if cancelled while queued.
    ///
    /// The launcher OWNS the per-run scratch dir, so it also owns STAGING: it creates
    /// scratch, writes `WIKI_STATE.md` (and, for Ingest, `source.<ext>`) from the
    /// bytes the caller read from SQLite, then finalizes the `WikiOperation` with the
    /// resulting absolute scratch paths so the `-p` prompt points the agent at
    /// reliable local disk — never the ~5s-laggy read-only mount.
    ///
    /// - `request` carries the per-op intent + the source bytes/state text gathered
    ///   at click time.
    /// - `wikiID`/`wikiRoot`/`systemPrompt` come from the active wiki at click time
    ///   (`wikiRoot` resolved from the FP manager — never hardcoded).
    /// - `wikictlDirectory` is the dir holding the embedded `wikictl`
    ///   (`Self Driving Wiki.app/Contents/Helpers`), prepended to the child's PATH so the
    ///   agent's `wikictl` calls resolve.
    /// - `onLock`/`onUnlock` are the edit-lock callbacks: `onLock` fires before the
    ///   spawn, `onUnlock` from `finish()` (so a killed agent, or one whose
    ///   `terminationHandler` was missed and is reconciled by the watchdog, still
    ///   releases). Both run on the main actor.
    /// - `ingestingSourceIDs` is the **agent phase** flag for THIS run: the ids whose
    ///   ingest is now committing. The launcher assigns it to `self.ingestingSourceIDs`
    ///   at spawn commit (around `onLock`) — NOT while queued for the slot — so a
    ///   pure extraction or a queued ingest never sets it. Empty for query/lint
    ///   runs (the default), which keeps the flag clear and the cross-file Ingest
    ///   greyout unblocked. Cleared in `finish()`.
    func run(
        request: OperationRequest,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        ingestingSourceIDs: Set<PageID> = [],
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void
    ) async {
        // Serialize on the shared generation gate. Extraction does NOT take the
        // gate, so a pdf2md conversion may overlap a query run; only the active
        // generation serializes.
        let acquired = await awaitGenerationSlot()
        guard acquired, !Task.isCancelled else {
            // Cancelled while queued (self-removed; gate not acquired) — bail without
            // touching the gate. If we were handed the gate then cancelled (race),
            // give it back so a queued peer isn't stranded.
            if acquired { releaseGenerationSlot() }
            if Task.isCancelled {
                preflightError = "Run cancelled before starting."
            } else {
                preflightError = "Another operation is already running. Wait for it to finish and try again."
            }
            return
        }

        // Set isRunning NOW (gate acquired = this run is committed). This is the
        // explicit assignment that decouples process lifetime from gate ownership.
        isRunning = true

        // PREFLIGHT + STAGING run AFTER the gate is acquired, so any early-return
        // below must `isRunning = false` + `releaseGenerationSlot()` to hand the gate
        // to the next waiter (or free it). The edit lock (`onLock`) fires only on a
        // successful spawn, so a preflight/staging failure does NOT lock editing.
        resetRunArtifacts()

        // Load agent command config fresh at spawn time so Settings changes apply
        // without a restart.
        let dir = containerDirectory ?? (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory
        let agentConfig = AgentCommandConfig.load(from: dir)

        let resolvedPath: String
        switch PathPreflight.resolveOnLoginShell(executable: agentConfig.resolvedExecutable()) {
        case .found(let path):
            resolvedPath = path
        case .missing(let reason):
            preflightError = reason
            isRunning = false
            releaseGenerationSlot()
            return
        }
        preflightError = nil

        guard let scratch = makeScratchDirectory() else {
            preflightError = "Could not create a scratch working directory for the agent."
            isRunning = false
            releaseGenerationSlot()
            return
        }

        // Stage inputs into scratch from reliable local disk, then finalize the
        // operation with the staged absolute paths. A staging failure aborts the run
        // (a run that couldn't stage would fall back to probing the laggy mount).
        let operation: WikiOperation
        do {
            operation = try request.stage(into: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            isRunning = false
            releaseGenerationSlot()
            return
        }

        let pdf2mdScriptPath = resolvePdf2mdScriptPath()
        let sandbox = resolveSandboxInvocation(
            wikiID: wikiID, scratch: scratch, dir: dir, pdf2mdScriptPath: pdf2mdScriptPath)
        if sandbox != nil { createSandboxTmpDir(in: scratch) }

        // RESERVE per-run metadata. isRunning is already `true` (set above).
        let now = Date()
        runningKind = operation.kind
        runStartedAt = now
        lastActivityAt = now
        openLogFiles(in: scratch)
        // A one-shot run is "generating" for its whole duration. One-shot runs
        // never install `onTurnBoundaryHandler` (it stays nil here), so this is a
        // pure UI flag — the edit lock for one-shot runs is owned by
        // `onLock`/`onUnlock` around the spawn, not the per-turn callback.
        setGenerating(true)
        // SPAWN COMMIT: the agent phase now begins. Assign the agent-phase flag
        // (`ingestingSourceIDs`) here — NOT while queued for the gate — so the
        // "Ingesting…" label and the cross-file Ingest greyout activate only once
        // the spawn is actually committed. For query/lint this is empty (default),
        // which clears any stale flag. See `extractingSourceIDs` for the separate
        // extraction-phase flag, which the runner manages around the pdf2md block.
        self.ingestingSourceIDs = ingestingSourceIDs
        onLock()
        onUnlockHandler = onUnlock

        // Build the backend profile. The launcher resolves app-level concerns
        // (scratch dir, sandbox, config, executable path); the backend owns
        // OperationCommand assembly + Process spawn + parse/encode.
        let cli = CLIProfile(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            resolvedExecutable: resolvedPath,
            command: agentConfig,
            sandbox: sandbox,
            onStdoutChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestRawStdout(chunk) }
            },
            onStderrChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestStderr(chunk) }
            })
        let profile = BackendProfile(
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: cli)

        do {
            DebugLog.agent("run: spawning kind=\(operation.kind.rawValue) wikiID=\(wikiID) exe=\(resolvedPath)")
            let session = try await backend.start(
                profile: profile,
                systemPrompt: systemPrompt,
                onExit: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.finish(status: Int32(status))
                    }
                })
            sessionHandle = session
            startCompletionWatchdog()

            // Consume the per-turn stream in a background Task (fire-and-forget:
            // run() returns after spawn commit; the stream is drained async).
            // This replaces the old readabilityHandler → ingestStdout path.
            let backend = self.backend
            let generationGateReleasesPerTurn = Self.releasesGenerationSlotPerTurn(
                isInteractiveSession: isInteractiveSession)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stream = await backend.send(
                    TurnInput(userText: ""), into: session)
                for await event in stream {
                    self.mergeOrAppend(event)
                    if AgentEvent.endsGeneration(event) {
                        self.setGenerating(false)
                        self.flushTranscript()
                        if generationGateReleasesPerTurn {
                            self.releaseGenerationSlot()
                        }
                    }
                }
            }
        } catch {
            DebugLog.agent("run: spawn FAILED: \(error.localizedDescription)")
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            // Clear the agent-phase ingest flag so spawn failure doesn't strand
            // the "Ingesting…" row label or the cross-file Ingest greyout. finish()
            // is not called on this path, so we clear explicitly here.
            self.ingestingSourceIDs = []
            releaseEditLock()
            // Release the generation gate so a queued peer isn't stranded.
            // Also clear isRunning (set above at gate acquire; spawn failed).
            isRunning = false
            releaseGenerationSlot()
        }
    }

    /// Heartbeat logger + stale-idle detector. Replaces the old liveness-poller
    /// (which polled `process?.isRunning` — impossible now that `Process` lives
    /// behind the `AgentBackend` port). The backend's `onExit` callback is the
    /// sole completion signal: it fires exactly once from `terminationHandler`
    /// and drives `finish()`. This watchdog logs a heartbeat for post-hoc
    /// analysis and warns if the session has been idle for a long time, but it
    /// no longer reconciles a missed `terminationHandler` (the `onExit` gate is
    /// one-shot and reliable — `Process.terminationHandler` always fires on
    /// process exit, including crash/kill).
    private func startCompletionWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isRunning else { return }
                let pid = self.currentProcessID ?? -1
                let idle = self.lastActivityAt.map { Date().timeIntervalSince($0) } ?? -1
                DebugLog.agent(
                    "heartbeat pid=\(pid) isRunning=\(self.isRunning) "
                    + "events=\(self.events.count) idleSec=\(String(format: "%.1f", idle))")
            }
        }
    }

    /// Start a stdin-backed query conversation. The first user message is sent
    /// immediately after the process launches (via `sendInteractiveMessage`, which
    /// acquires the generation gate for that first turn). Later turns use
    /// `sendInteractiveMessage` as well — each acquires the gate for its duration.
    ///
    /// IMPORTANT: this function does NOT acquire the generation gate for the session.
    /// The process stays alive between turns without holding the gate, allowing
    /// another launcher's process to coexist. The gate is held only per-turn.
    ///
    /// - Parameter allowWikiEdits: when `false` (default), the agent runs under a
    ///   READ-ONLY seatbelt sandbox that physically blocks all writes to the wiki DB.
    /// - Parameter onTranscript: persistence sink (issue #119). Receives the
    ///   not-yet-persisted tail of `events` at each turn boundary and once more at
    ///   `finish()`. `nil` (the default) when the caller has no chat to persist
    ///   into (e.g. `store.startChat` failed) — the session simply runs unpersisted.
    func startInteractiveQuery(
        firstMessage: String,
        stateMarkdown: String,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        allowWikiEdits: Bool = false,
        chatID: String? = nil,
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void,
        onTurnBoundary: @escaping @MainActor (Bool) -> Void,
        onTranscript: (@MainActor ([AgentEvent]) -> Void)? = nil
    ) async {
        // No gate acquisition here — the interactive session does NOT hold the gate
        // for its lifetime, only per-turn (via sendInteractiveMessage). Two sessions
        // can coexist as processes; only one generates at a time via the gate.

        // Preflight (no gate held — early returns here don't need gate release).
        resetRunArtifacts()

        // Load agent command config fresh at spawn time.
        let dir = containerDirectory ?? (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory
        let agentConfig = AgentCommandConfig.load(from: dir)

        let resolvedPath: String
        switch PathPreflight.resolveOnLoginShell(executable: agentConfig.resolvedExecutable()) {
        case .found(let path):
            resolvedPath = path
        case .missing(let reason):
            preflightError = reason
            return
        }
        preflightError = nil

        guard let scratch = makeScratchDirectory() else {
            preflightError = "Could not create a scratch working directory for the agent."
            return
        }

        let stateFilePath: String
        do {
            stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        let operation = WikiOperation.queryConversation(
            stateFilePath: stateFilePath, allowWikiEdits: allowWikiEdits)
        // When "Allow wiki edits" is off, force a read-only seatbelt sandbox that
        // physically blocks writes to the wiki DB — regardless of global sandbox
        // settings (the read-only sandbox ALWAYS wins over the edit sandbox, so a
        // global config can never punch through the forced read-only boundary).
        // When on, use the existing opt-in sandbox behavior (which may itself be
        // `nil`, i.e. fail-open un-sandboxed). Resolved separately then handed to the
        // pure selector so the invariant is unit-testable.
        let pdf2mdScriptPath = resolvePdf2mdScriptPath()
        let editSandbox = resolveSandboxInvocation(
            wikiID: wikiID, scratch: scratch, dir: dir, pdf2mdScriptPath: pdf2mdScriptPath)
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let readOnlySandbox = SandboxProfile.readOnlyInvocation(
            homePath: homePath, scratchDir: scratch.path, pdf2mdScriptPath: pdf2mdScriptPath)
        let sandbox = Self.selectQuerySandbox(
            allowWikiEdits: allowWikiEdits,
            editSandbox: editSandbox,
            readOnlySandbox: readOnlySandbox)
        if sandbox != nil { createSandboxTmpDir(in: scratch) }

        // RESERVE per-run metadata. isRunning will be set at spawn commit below
        // (after backend.start succeeds).
        let now = Date()
        runningKind = operation.kind
        runStartedAt = now
        lastActivityAt = now
        openLogFiles(in: scratch)
        // SPAWN COMMIT: a query conversation never ingests, so the agent-phase flag
        // is empty — clearing any stale value (mirrors `run`'s spawn-commit).
        self.ingestingSourceIDs = []
        onLock()
        onUnlockHandler = onUnlock
        // Install the per-turn callback now so it's ready when the first turn's
        // transition fires. It fires on every real transition for the session's
        // lifetime; `finish()` / `resetRunArtifacts()` clear it. This is what lets
        // the lock release between turns EVEN WHEN the Query view is not on screen
        // (the old view `.onChange` never fired while unmounted).
        onTurnBoundaryHandler = onTurnBoundary
        // Install the transcript sink alongside the per-turn callback (issue #119):
        // both are per-session callbacks assigned once resetRunArtifacts() has run
        // (which clears any stale sink from a prior run).
        transcriptSink = onTranscript
        // D2: record the chat row this live session is writing to. This is the
        // source-of-truth switch for ConversationView — when it matches a tab's
        // chatID, that tab renders `launcher.events` (streaming) instead of the
        // persisted store. Set here (after resetRunArtifacts cleared any prior
        // value) so the flip is live from the first streamed token.
        activeChatID = chatID
        // NOTE: do NOT `setGenerating(true)` here. The first turn's transition is
        // owned by `sendInteractiveMessage(firstMessage)` below (after the gate is
        // acquired). If we set it here, `sendInteractiveMessage`'s gate-guard would
        // see `isGenerating == true` and bail — claude would block on stdin forever.

        // Build the backend profile (the backend owns OperationCommand assembly).
        let cli = CLIProfile(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            resolvedExecutable: resolvedPath,
            command: agentConfig,
            sandbox: sandbox,
            onStdoutChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestRawStdout(chunk) }
            },
            onStderrChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestStderr(chunk) }
            })
        let profile = BackendProfile(
            scratchDirectory: scratch,
            isReadOnly: !allowWikiEdits,
            cli: cli)

        do {
            DebugLog.agent("startInteractiveQuery: spawning exe=\(resolvedPath)")
            let session = try await backend.start(
                profile: profile,
                systemPrompt: systemPrompt,
                onExit: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.finish(status: Int32(status))
                    }
                })
            sessionHandle = session
            // SPAWN COMMIT: process is alive. isRunning = true (process alive across turns).
            isInteractiveSession = true
            isRunning = true
            DebugLog.agent("startInteractiveQuery: spawned")
            // Start the first turn — this acquires the generation gate for turn 1.
            sendInteractiveMessage(firstMessage)
            // Mirror `run()`: arm the completion watchdog so a process that exits
            // without a reconciling `onExit` still clears `isRunning`.
            // Interactive sessions stay alive between turns; the watchdog only acts
            // when the OS reports the process gone, so a live idle session is safe.
            startCompletionWatchdog()
        } catch {
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            isInteractiveSession = false
            isRunning = false
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            releaseEditLock()
            // Cancel any queued send task (shouldn't exist yet, but guard for safety).
            interactiveSendTask?.cancel()
            interactiveSendTask = nil
            isAwaitingGenerationSlot = false
            // No gate to release — we never acquired it for the session.
        }
    }

    /// Send one user turn to the active interactive query session.
    ///
    /// This function acquires the shared generation gate for the duration of the turn
    /// (from the write to stdin until the agent emits `messageStop`/`result`). The
    /// acquisition is ASYNC and may wait if another launcher is currently generating.
    /// While waiting, `isAwaitingGenerationSlot` is `true` so the UI can show a hint.
    func sendInteractiveMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldSendMessage(
            isRunning: isRunning,
            isInteractiveSession: isInteractiveSession,
            isGenerating: isGenerating,
            isAwaitingGenerationSlot: isAwaitingGenerationSlot,
            message: trimmed
        ) else { return }

        // Signal that we're waiting for the gate. The UI shows a hint; canSend = false.
        isAwaitingGenerationSlot = true

        // Spawn a cancellable task that acquires the generation gate, then sends
        // the turn to the backend and consumes the per-turn stream. Stored so
        // stopAgent()/finish() can cancel a pending wait.
        let backend = self.backend
        let session = self.sessionHandle
        interactiveSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.awaitGenerationSlot()
            self.isAwaitingGenerationSlot = false
            guard ok, !Task.isCancelled, self.isInteractiveSession,
                  let session else {
                // Acquired the gate then bailed (cancelled or session ended) — give
                // it back so a queued peer isn't stranded.
                if ok { self.releaseGenerationSlot() }
                return
            }
            self.events.append(.userText(trimmed))
            self.setGenerating(true)    // fires onTurnBoundary(true) → edit lock (Edit only)
            self.lastActivityAt = Date()
            // Send the turn and consume the per-turn stream. The backend writes
            // the NDJSON line to stdin; the stream finishes at `.messageStop`
            // (turn boundary) or `.result` (session end).
            let stream = await backend.send(
                TurnInput(userText: trimmed), into: session)
            for await event in stream {
                self.mergeOrAppend(event)
                if AgentEvent.endsGeneration(event) {
                    self.setGenerating(false)
                    self.flushTranscript()
                    if Self.releasesGenerationSlotPerTurn(
                        isInteractiveSession: self.isInteractiveSession) {
                        self.releaseGenerationSlot()
                    }
                }
            }
        }
    }

    /// Pure decision: whether `sendInteractiveMessage` would actually start a turn
    /// (vs. bail on a guard). Extracted so the gate logic is unit-testable without a
    /// live process (the full send path needs a spawned claude + stdin).
    ///
    /// A turn may start iff: a process is alive (`isRunning`), it's an interactive
    /// (stdin-backed) session, the text isn't blank, the agent is NOT already
    /// generating a response, and we're NOT already waiting to acquire the gate. The
    /// last condition prevents double-queueing — there can be at most one pending
    /// send task at a time.
    ///
    /// Regression guard: `startInteractiveQuery` must NOT pre-set `isGenerating`
    /// before calling `sendInteractiveMessage(firstMessage)` — the first send runs
    /// with `isGenerating == false`, so it passes this gate and the message lands.
    /// If that ordering regresses, the first message is dropped and claude blocks
    /// on stdin forever (events=0, perpetual spinner).
    static func shouldSendMessage(
        isRunning: Bool,
        isInteractiveSession: Bool,
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool,
        message: String
    ) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return isRunning && isInteractiveSession && !trimmed.isEmpty
            && !isGenerating && !isAwaitingGenerationSlot
    }

    /// Cancel ONLY the pdf2md conversion (standalone or ingest-path extraction
    /// phase). Does NOT touch the agent process — a running claude query/ingest
    /// is left alone. Cancels whichever task owns the extraction, then clears
    /// the extraction-phase flags so the sidebar dismisses the conversion box.
    func stopExtraction() {
        DebugLog.agent(
            "stopExtraction() requested: isExtracting=\(isExtracting) "
            + "extractTask=\(extractTask != nil) ingestTask=\(ingestTask != nil)")
        if extractTask != nil {
            // Standalone "Extract Markdown" — the task's cancellation handler
            // terminates pdf2md via PdfExtractionService.onCancel.
            extractTask?.cancel()
        } else if !isRunning && isExtracting {
            // Ingest-path extraction phase (before agent spawn): cancel the
            // ingest task so AgentOperationRunner.runMultiIngest bails out via
            // its Task.isCancelled check.
            ingestTask?.cancel()
        }
        // If extraction is somehow busy without a task (shouldn't happen), clear
        // flags anyway so the UI doesn't hang.
        if !isExtracting && extractingSourceIDs.isEmpty { return }
        isExtracting = false
        extractionPID = nil
        extractingSourceIDs = []
        extractionLog = ""
    }

    /// Stop ONLY the agent process (claude -p). Does NOT touch a running pdf2md
    /// conversion — a standalone extract running alongside a query continues.
    /// Also cancels any in-flight send task (generation gate wait).
    func stopAgent() {
        DebugLog.agent(
            "stopAgent() requested: isRunning=\(isRunning) "
            + "session=\(sessionHandle != nil) "
            + "pid=\(currentProcessID ?? -1)")
        ingestTask?.cancel()
        // Cancel any pending send (gate wait) so it doesn't fire after the session ends.
        interactiveSendTask?.cancel()
        interactiveSendTask = nil
        isAwaitingGenerationSlot = false
        // Ask the backend to cancel the session (closes stdin + terminates the
        // process). Fire-and-forget: the onExit callback drives finish() — but
        // we also call finish(-1) synchronously below so the UI tears down
        // immediately without waiting for the async cancel to land.
        if let session = sessionHandle {
            let backend = self.backend
            Task { await backend.cancel(session) }
        }
        if isRunning {
            finish(status: -1)  // -1 sentinel = user-cancelled / forced teardown
        }
    }

    /// Terminate EVERYTHING — extraction + agent process. Convenience for the
    /// few surfaces that don't distinguish (e.g. app termination cleanup).
    func stop() {
        stopExtraction()
        stopAgent()
    }

    /// End the interactive query session (if any) and clear the visible
    /// transcript so the page returns to its empty state; the next send spawns a
    /// fresh claude process with a clean context. History is already persisted
    /// incrementally (and stopAgent → finish flushes the tail), so nothing is lost.
    /// Guarded so it can never kill a non-query run (ingest/lint) streaming into
    /// this launcher, and it does NOT touch extractionLog/extractionPID — a
    /// concurrently running pdf2md extraction is untouched.
    func startNewConversation() {
        if isRunning && runningKind != .query { return }
        if isRunning {
            // stopAgent() is a safe no-op when idle (PR #198); here it terminates
            // the live query process and triggers finish() → final flush + sink clear.
            stopAgent()
        }
        events = []
        isStreamingAssistantRow = false
        rawTranscript = ""
        stderr = ""
        exitStatus = nil
        preflightError = nil
        transcriptSink = nil
        persistedEventCount = 0
        // D2: clear the live chat association. The retarget back to the draft
        // state (.ask/.edit) is handled by the caller (QueryConversationView /
        // ConversationView) via store.retargetTab, since the launcher does not
        // know which tab it lives in.
        activeChatID = nil
    }

    // MARK: - Transcript persistence (issue #119)

    /// Pure tail computation: the slice of `events` not yet handed to the sink.
    /// Extracted so the cursor arithmetic is unit-testable without driving a live
    /// launcher. Mirrors the `>=` guard in `flushTranscript()` — returns empty when
    /// nothing new has arrived since `persistedCount`.
    static func unflushedTail(events: [AgentEvent], persistedCount: Int) -> [AgentEvent] {
        guard persistedCount < events.count else { return [] }
        return Array(events[persistedCount...])
    }

    /// Hand the not-yet-persisted tail of `events` to `transcriptSink`, if any, and
    /// advance the cursor. Filtering to persistable events is the model's job
    /// (`WikiStoreModel.appendChatEvents` filters via `AgentEvent.isPersistable`) —
    /// the tail is passed whole. No-op when nothing new has arrived or no sink is
    /// installed.
    private func flushTranscript() {
        guard persistedEventCount < events.count else { return }
        let tail = Self.unflushedTail(events: events, persistedCount: persistedEventCount)
        persistedEventCount = events.count
        transcriptSink?(tail)
    }

    // MARK: - Stream ingestion (main actor)

    /// Mirror a raw stdout chunk to `rawTranscript` + `run.jsonl`. Called from
    /// the backend's `onStdoutChunk` callback (which fires on the pipe's
    /// background queue, hopped to the main actor). The line-splitting, parsing,
    /// and event routing now happen in the backend + the per-turn `for await`
    /// consumer — this method only owns the raw-bytes mirror.
    private func ingestRawStdout(_ chunk: String) {
        lastActivityAt = Date()
        rawTranscript.append(chunk)
        writeLog(chunk, to: logHandle)
    }

    /// Route one parsed event into `events`: either grow the in-progress streamed
    /// assistant row in place, or append a new row (the existing, non-streaming
    /// behavior). This is what lets `AgentTranscriptWebView` patch a live row
    /// instead of only ever appending (issue #121).
    private func mergeOrAppend(_ event: AgentEvent) {
        switch event {
        case .assistantTextDelta(let delta):
            if isStreamingAssistantRow, case .assistantText(let existing) = events.last {
                events[events.count - 1] = .assistantText(existing + delta)
            } else {
                events.append(.assistantText(delta))
                isStreamingAssistantRow = true
            }

        case .assistantText:
            // The complete/final text for a block already being streamed — replace
            // the in-progress row with the authoritative full text rather than
            // appending a duplicate. Any other `.assistantText` (no streaming in
            // flight, e.g. a run without `--include-partial-messages`) appends as
            // it always has.
            if isStreamingAssistantRow, case .assistantText = events.last {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
            isStreamingAssistantRow = false

        default:
            events.append(event)
            isStreamingAssistantRow = false
        }
    }

    /// Append a raw stderr chunk: surface it in `stderr`, mirror to the transcript +
    /// `run.stderr.log`.
    private func ingestStderr(_ chunk: String) {
        lastActivityAt = Date()
        stderr.append(chunk)
        rawTranscript.append(chunk)
        writeLog(chunk, to: stderrLogHandle)
    }

    /// Record the exit status and tear down. Guarded on `isRunning` so it runs
    /// EXACTLY ONCE per run: `stopAgent()` and the `onExit` callback may both
    /// race to call it. The backend drains any trailing partial line before the
    /// stream finishes, so no line-buffer drain is needed here (the old
    /// `stdoutLineBuffer` drain moved to the backend's terminationHandler).
    private func finish(status: Int32) {
        guard isRunning else {
            DebugLog.agent("finish: ignored (already torn down) status=\(status)")
            return
        }
        DebugLog.agent("finish: status=\(status) events=\(events.count)")
        watchdogTask?.cancel()
        watchdogTask = nil
        // Session over: flush any remaining tail (a killed/died session still
        // persists its last events) THEN detach the sink — no further writes.
        flushTranscript()
        transcriptSink = nil
        // D2 flip-timing: clear activeChatID AFTER flushTranscript() has
        // committed the final tail. flushTranscript() is synchronous — it calls
        // transcriptSink?(tail) which runs store.appendChatEvents on the main
        // actor before returning. By the time we reach this line, the persisted
        // chatMessages(chatID:) and the in-memory events[] agree, so flipping the
        // view's source-of-truth from "live" to "persisted" cannot truncate.
        // (If we cleared it before the flush, the view would re-source from the
        // store with the last turn's events still missing → truncated flash.)
        activeChatID = nil
        closeLogFiles()
        exitStatus = status
        // Clear process-alive state.
        isRunning = false
        isInteractiveSession = false
        runningKind = nil
        sessionHandle = nil
        currentProcessID = nil
        ingestingSourceIDs = []
        // Cancel any in-flight send task (gate wait or stream consumer). Clear the
        // awaiting flag so the UI stops showing the "Waiting…" hint.
        interactiveSendTask?.cancel()
        interactiveSendTask = nil
        isAwaitingGenerationSlot = false
        // Clear the per-turn callback before the final state transition: the
        // session is ending, so the lock's final release is the session-level
        // `onUnlock` (via `releaseEditLock`), not a per-turn boundary.
        onTurnBoundaryHandler = nil
        setGenerating(false)
        lastActivityAt = Date()
        // Release the edit lock (`store.isAgentRunning`) from here — NOT from the
        // `onExit` callback — so EVERY completion path releases it.
        releaseEditLock()
        // Release the generation gate if still held. For one-shot runs this is the
        // primary release path (they hold the gate through finish). For interactive
        // sessions this covers the edge case where the process died MID-TURN (the
        // normal per-turn release via the stream's endsGeneration didn't fire). The
        // idempotent `releaseGenerationSlot()` guard makes this safe in all paths.
        releaseGenerationSlot()
    }

    /// Release the run's edit lock exactly once. Idempotent: clearing the stored
    /// handler makes repeated calls (from `finish()`, a spawn-failure teardown, or
    /// the watchdog) a no-op.
    private func releaseEditLock() {
        onUnlockHandler?()
        onUnlockHandler = nil
    }

    /// Clear per-run artifacts (events, transcript, exit status, log handles, etc.)
    /// at the start of a new run. Unlike the old `resetRunState`, this does NOT
    /// touch `isRunning` — process lifetime is managed explicitly. Called right
    /// before staging/preflight at the top of each launch path.
    private func resetRunArtifacts() {
        watchdogTask?.cancel()
        watchdogTask = nil
        events = []
        isStreamingAssistantRow = false
        rawTranscript = ""
        stderr = ""
        exitStatus = nil
        isInteractiveSession = false
        // Clear the per-turn callback first so this reset transition doesn't fire
        // a stale handler; a reset is the start of a new run, not a turn boundary.
        onTurnBoundaryHandler = nil
        setGenerating(false)
        runningKind = nil
        logFileURL = nil
        runStartedAt = nil
        lastActivityAt = nil
        currentProcessID = nil
        sessionHandle = nil
        onUnlockHandler = nil
        // A reset starts a new run: a stale sink must never receive a new
        // session's events (issue #119).
        transcriptSink = nil
        persistedEventCount = 0
        // D2: a stale active chat association must never survive into a new run.
        // (startInteractiveQuery sets the fresh value right after this reset.)
        activeChatID = nil
    }

    // MARK: - Backend log files

    /// Create `run.jsonl` (raw stream-json) and `run.stderr.log` under the run's
    /// scratch dir and open append handles. Best-effort: if a handle can't open, the
    /// in-memory transcript still works.
    private func openLogFiles(in scratch: URL) {
        let jsonl = scratch.appendingPathComponent("run.jsonl", isDirectory: false)
        let stderrLog = scratch.appendingPathComponent("run.stderr.log", isDirectory: false)
        let manager = FileManager.default
        manager.createFile(atPath: jsonl.path, contents: nil)
        manager.createFile(atPath: stderrLog.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: jsonl)
        stderrLogHandle = try? FileHandle(forWritingTo: stderrLog)
        logFileURL = jsonl
    }

    private func writeLog(_ text: String, to handle: FileHandle?) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func closeLogFiles() {
        try? logHandle?.close()
        try? stderrLogHandle?.close()
        logHandle = nil
        stderrLogHandle = nil
    }

    /// Create a fresh per-run writable scratch dir under the app's Caches (decision
    /// #4 — Claude Code needs a writable cwd; the mount is read-only). The dir also
    /// holds the per-run `run.jsonl` / `run.stderr.log` backend logs, so — unlike
    /// the previous version — we do NOT delete it on termination; it persists for
    /// post-hoc debugging via "Reveal log". Returns nil only if it can't be created.
    private func makeScratchDirectory() -> URL? {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let scratch = base
            .appendingPathComponent("Self Driving Wiki-agent", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return scratch
        } catch {
            return nil
        }
    }

    // MARK: - Seatbelt sandbox

    /// Resolve the write-confinement seatbelt sandbox for an Ingest or Edit spawn.
    /// The sandbox is **always on** for these paths — it confines the agent's
    /// filesystem writes to the wiki DB + scratch + `~/.claude`, AND denies exec/read
    /// of the resolved `pdf2md` script so a compromised agent can't run the bundled
    /// extractor (reads, network, and all other exec stay open; see `SandboxProfile`).
    /// Returns `nil` (fail-open, logged) only when a required path can't be resolved,
    /// so a misconfiguration never blocks agent work entirely.
    ///
    /// - Parameter pdf2mdScriptPath: the resolved `pdf2md` script path (or nil if the
    ///   app couldn't resolve one). Threaded into the profile as the `PDF2MD_SCRIPT`
    ///   deny target. When nil, no exec/read deny is emitted (the agent has nothing
    ///   bundled to run; generic `uv`/`python3` is still reachable — issue #116 item 2).
    ///
    /// This does NOT affect the Ask session, which is always forced into the stricter
    /// read-only sandbox by `selectQuerySandbox` regardless of this result.
    ///
    /// This function ONLY resolves the invocation; it does NOT create any directories.
    /// Each spawn site that receives a non-nil result MUST call `createSandboxTmpDir(in:)`
    /// before launching the child so that `TMPDIR` (set by `OperationCommand.applySandbox`)
    /// points at a directory that actually exists.
    private func resolveSandboxInvocation(
        wikiID: String,
        scratch: URL,
        dir: URL,
        pdf2mdScriptPath: String?
    ) -> SandboxProfile.SandboxInvocation? {
        // HOME for the `-D HOME` profile param. Read from the environment the child
        // will inherit (fall back to the process home). Forwarded for forward-compat
        // and debugging; the current whitelist profile does not reference it.
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

        // The active wiki's SQLite DB path mirrors `WikiResolver.databaseURL(for:)`:
        // `<container>/<ulid>.sqlite`. `dir` is the App Group container the DB lives in.
        // Symlink resolution is performed inside `SandboxProfile.invocation` (the
        // tested core layer) so the canonical path reaches the seatbelt profile.
        let dbPath = dir.appendingPathComponent("\(wikiID).sqlite", isDirectory: false).path

        // Fail-open if any required path is empty/relative (misconfiguration).
        guard !scratch.path.isEmpty, scratch.path.hasPrefix("/"),
              !dbPath.isEmpty, dbPath.hasPrefix("/") else {
            DebugLog.agent("sandbox: could not resolve scratch/db path — running UNSANDBOXED")
            return nil
        }

        let invocation = SandboxProfile.invocation(
            homePath: homePath,
            scratchDir: scratch.path,
            wikiDBPath: dbPath,
            pdf2mdScriptPath: pdf2mdScriptPath
        )
        let pdf2mdNote = pdf2mdScriptPath.map { " + denying pdf2md @ \($0)" } ?? ""
        DebugLog.agent("sandbox: confining Ingest/Edit agent writes to scratch + \(dbPath)\(pdf2mdNote)")
        return invocation
    }

    /// Resolve the bundled `pdf2md` script path to deny in the agent seatbelt, or nil
    /// if no script is resolvable. Delegates to `PdfExtractionService.resolveScript()`
    /// (the same canonical resolver the APP process uses to run the script) so the deny
    /// always targets the exact file the agent would otherwise reach. Resolved once per
    /// spawn and handed to BOTH the edit and read-only invocations.
    private func resolvePdf2mdScriptPath() -> String? {
        let path = PdfExtractionService.resolveScript()?.path
        if path == nil {
            DebugLog.agent("sandbox: pdf2md not resolved — no PDF2MD_SCRIPT deny rule emitted")
        }
        return path
    }

    /// Create the `scratch/.tmp` directory that `OperationCommand.applySandbox`
    /// points `TMPDIR` at for sandboxed spawns. Must be called at each spawn site
    /// whenever a non-nil sandbox is applied so the directory exists before the
    /// child process tries to write into it. Best-effort: failure (e.g. scratch
    /// unwritable) is surfaced later by the child's own write errors.
    private func createSandboxTmpDir(in scratch: URL) {
        let tmp = scratch.appendingPathComponent(OperationCommand.tmpRelocationLeaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
}
