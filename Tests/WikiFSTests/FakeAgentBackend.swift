#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFSEngine
@testable import WikiFSCore

/// How a scripted `writePage`/`reconcileWrite` action supplies the CAS
/// expectation — the `--expect-head` value a conforming agent threads from its
/// preceding `page get`, the deliberately-stale literal a conflict fixture
/// needs, or `.blind` (no flag) for the legacy unrestricted write.
enum FakeWriteHead: Sendable, Equatable {
    case blind
    case fromLastRead
    case literal(String)
}

/// One scripted agent action (phase 5.1,
/// `plans/wiki-strategies-and-cumulative-ingestion.md`): what a
/// tool-invoking agent would DO during a turn, executed through the real
/// production boundaries (`ScriptedWikiCtl.dispatch`), never by handing a
/// premerged body to the store.
///
/// These model the agent's observable BEHAVIOR, not its judgment. A
/// conforming script reads before writing, threads `--expect-head`, and
/// recomposes on conflict; `nonconformingScript` deliberately breaks those
/// rules to prove the transport cannot police them.
enum FakeAgentAction: Sendable {
    /// Read the staged `WIKI_STATE.md` from the session's scratch directory
    /// (captures its content for prompt/state-delivery assertions).
    case readStateFile
    /// Read one staged source leaf from scratch (captures content — the
    /// "read the assigned source section" step of the executor contract).
    case readStagedSource(leaf: String)
    /// `page get --title <title> --json` — updates the session's
    /// last-read body/head used by `.fromLastRead` and reconcile closures.
    case getPage(title: String)
    /// `page list --json` — the missing-page probe a creating agent performs.
    case listPages
    /// `page add` with a statically composed body.
    case writePage(
        title: String,
        body: String,
        head: FakeWriteHead,
        /// Phase 4 §4.4 seam: adds `--create-only` (mutually exclusive with
        /// `--expect-head`). The flag is in the production parser; the
        /// create-race scenario probes it at runtime so the harness stays
        /// correct on trees where the phase 4 work is or is not present.
        createOnly: Bool,
        /// Raw `--source` values, e.g. `["01…:primary", "01…:supporting"]`.
        sources: [String])
    /// `page add` whose body is composed from whatever this session last
    /// read via `.getPage` — the conforming reconcile: recompose from the
    /// CURRENT body, then write with the CAS head from that same read.
    /// `compose` receives `nil` when the page did not exist at read time.
    case reconcileWrite(
        title: String,
        compose: @Sendable (_ currentBody: String?) -> String,
        head: FakeWriteHead,
        createOnly: Bool,
        sources: [String])
    /// A DIFFERENT writer winning a race mid-script — also dispatched through
    /// the production `page add` seam (blind write; the racing writer holds
    /// no CAS duty in these fixtures). Injected between an executor's read
    /// and write to create the conflict the retry contract handles.
    case racingWrite(title: String, body: String, sources: [String])
    /// `log append --kind <kind> --title <title> [--source <id>]` — the
    /// finalizer's log action.
    case logAppend(kind: String, title: String, source: String?)
}

/// One executed scripted action and its production-dispatch outcome, in
/// order — the transcript the pipeline scenarios assert against.
struct FakeScriptActionRecord: Sendable, Equatable {
    let sessionID: String
    let label: String
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var hadCASConflict: Bool { exitCode == ScriptedCLIOutcome.Code.casConflict }
}

/// Content captured by a `.readStagedSource` action.
struct FakeStagedSourceCapture: Sendable, Equatable {
    let leaf: String
    let content: String
}

/// Per-session scripted behavior for `FakeAgentBackend`. Each `start()` call
/// pops the next behavior in sequence.
struct FakeSessionBehavior: Sendable {
    /// Events to yield in `send()` (ended implicitly by finishing the stream).
    /// Defaults to just `.messageStop` (the turn-boundary marker).
    var events: [AgentEvent] = [.messageStop]
    /// If true, `start()` throws `FakeBackendError.startFailed`.
    var shouldFailOnStart: Bool = false
    /// If set, write this JSON to `plan.json` in the scratch directory on
    /// `start()`, simulating the planner phase's output.
    var planJSON: Data? = nil
    /// If true, `send()` yields `events` but NEVER finishes the stream —
    /// simulates a stalled `sendPrompt` that never returns (issue #334).
    /// The consumer must cancel the iteration (like `stopAgent` does).
    var neverFinish: Bool = false
    /// Bounded tool actions executed inside `send()` BEFORE the events are
    /// yielded — the agent "doing work" (reads, CAS writes, log appends)
    /// through the production CLI dispatch seam. See `FakeAgentAction`.
    var actions: [FakeAgentAction] = []

    init(
        events: [AgentEvent] = [.messageStop],
        shouldFailOnStart: Bool = false,
        planJSON: Data? = nil,
        neverFinish: Bool = false,
        actions: [FakeAgentAction] = []
    ) {
        self.events = events
        self.shouldFailOnStart = shouldFailOnStart
        self.planJSON = planJSON
        self.neverFinish = neverFinish
        self.actions = actions
    }
}

enum FakeBackendError: Error {
    case startFailed
}

/// Test double conforming to `AgentBackend`. Records all `start`/`send`/`cancel`
/// calls, yields scripted `AgentEvent` sequences per session, and can write a
/// canned `plan.json` to simulate the planner phase.
///
/// Usage: construct with a list of `FakeSessionBehavior` (one per expected
/// `start()` call), inject into `AgentLauncher.backend`, drive the launcher,
/// then assert on the recorded calls.
actor FakeAgentBackend: AgentBackend {

    // MARK: - Records (for assertion)

    private(set) var startCount = 0
    private(set) var sendCount = 0
    private(set) var cancelCount = 0
    /// #1276: process-level shutdown calls, in order (release/dispose ordering).
    private(set) var shutdownCount = 0
    /// Session IDs in start order.
    private(set) var startedSessionIDs: [String] = []
    /// Sent prompt texts in send order.
    private(set) var sentTexts: [String] = []
    /// Cancelled session IDs in cancel order.
    private(set) var cancelledSessionIDs: [String] = []
    /// All events yielded across all sessions (flattened, in order).
    private(set) var allYieldedEvents: [AgentEvent] = []
    /// Model hints seen in start profiles (the `acpSelectedModelId` provider hint).
    private(set) var startModelHints: [String?] = []
    /// #727: provider ids seen in start profiles (the `acpProviderId` hint),
    /// in start order. Used by the integration tests to assert that two
    /// different providers were actually spawned (not just two `start` calls
    /// on the same backend).
    private(set) var startedProviderIds: [String] = []
    /// #727: the full profiles passed to each `start()` call, in order.
    private(set) var recordedProfiles: [BackendProfile] = []
    /// The system prompt passed to each `start()` call, in order — the
    /// per-session capture the cumulative-ingestion harness asserts prompt
    /// delivery against (phase 5.1).
    private(set) var recordedSystemPrompts: [String] = []
    /// Every scripted action executed in `send()`, in order, with its
    /// production-dispatch outcome (phase 5.1).
    private(set) var actionRecords: [FakeScriptActionRecord] = []
    /// `WIKI_STATE.md` contents captured by `.readStateFile` actions, in order.
    private(set) var capturedStateFileContents: [String] = []
    /// Staged-source contents captured by `.readStagedSource` actions, in order.
    private(set) var capturedStagedSources: [FakeStagedSourceCapture] = []

    // MARK: - Scripted behavior

    private var behaviors: [FakeSessionBehavior]
    private var behaviorIndex = 0
    private var sessionCounter = 0
    private var sessionBehaviors: [String: FakeSessionBehavior] = [:]
    /// Scratch directory per session (captured at `start()` from the profile)
    /// — where scripted reads look for `WIKI_STATE.md`/staged sources and
    /// where scripted bodies are written before `--body-file` dispatch.
    private var sessionScratchDirectories: [String: URL?] = [:]
    /// Per-session last `page get --json` body/head — the values a conforming
    /// script threads into `--expect-head` and reconcile composition.
    private var sessionReads: [String: (body: String?, head: String?)] = [:]
    /// The disposable store scripted actions dispatch against. `nil` (the
    /// default for every pre-existing caller) disables action execution —
    /// actions record nothing and `send()` behaves exactly as before.
    private let scriptStore: GRDBWikiStore?

    /// Hard bound on scripted actions per session (phase 5 test-strategy:
    /// "bounded, injected session actions"). A static script cannot loop,
    /// but the bound makes the guarantee structural for future dynamic
    /// scripts and turns a runaway into one recorded truncation instead of
    /// an unbounded turn.
    static let scriptedActionBound = 64

    init(behaviors: [FakeSessionBehavior] = [], scriptStore: GRDBWikiStore? = nil) {
        self.behaviors = behaviors
        self.scriptStore = scriptStore
    }

    // MARK: - AgentBackend conformance

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        startCount += 1
        recordedSystemPrompts.append(systemPrompt)

        let behavior = behaviorIndex < behaviors.count
            ? behaviors[behaviorIndex]
            : FakeSessionBehavior()
        behaviorIndex += 1

        startModelHints.append(profile.providerHints[HintKey.acpSelectedModelId.rawValue])
        startedProviderIds.append(profile.providerHints[HintKey.acpProviderId.rawValue] ?? "unknown")
        recordedProfiles.append(profile)

        if behavior.shouldFailOnStart {
            throw FakeBackendError.startFailed
        }

        sessionCounter += 1
        let sessionId = "fake-\(sessionCounter)"
        startedSessionIDs.append(sessionId)
        sessionBehaviors[sessionId] = behavior
        sessionScratchDirectories[sessionId] = profile.scratchDirectory

        // Write plan.json if configured (simulates the planner writing the plan).
        if let planData = behavior.planJSON, let scratch = profile.scratchDirectory {
            let planURL = scratch.appendingPathComponent("plan.json")
            try? planData.write(to: planURL)
        }

        return SessionHandle(id: sessionId)
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        sendCount += 1
        sentTexts.append(turn.userText)

        let behavior = sessionBehaviors[session.id]
        let events = behavior?.events ?? [.messageStop]
        let neverFinish = behavior?.neverFinish ?? false
        allYieldedEvents.append(contentsOf: events)

        // Execute the session's scripted tool actions BEFORE the turn ends.
        // This is the agent "doing work" mid-turn: every read/write/log goes
        // through the production CLI dispatch seam against the disposable
        // store (phase 5.1). No-op for sessions without actions or when no
        // store was injected.
        if let behavior, !behavior.actions.isEmpty {
            runScriptedActions(behavior, sessionID: session.id)
        }

        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            // When neverFinish is true, DON'T finish — simulates a stalled
            // sendPrompt (issue #334). The consumer must cancel the iteration.
            if !neverFinish {
                continuation.finish()
            }
        }
    }

    // MARK: - Scripted action execution

    /// Execute a session's actions in order, recording each outcome. Bounded
    /// by `scriptedActionBound`; a truncated script records the truncation so
    /// a runaway script surfaces as one diagnostic record, not a hang.
    ///
    /// Read state is the actor's live `sessionReads` (not a local copy), so a
    /// `getPage` earlier in the SAME action list is visible to a later
    /// `.fromLastRead` write / reconcile composition — the intra-turn
    /// read→compose→CAS-thread sequence the conflict scenarios depend on.
    private func runScriptedActions(_ behavior: FakeSessionBehavior, sessionID: String) {
        guard let store = scriptStore else { return }
        if sessionReads[sessionID] == nil {
            sessionReads[sessionID] = (body: nil, head: nil)
        }

        for (index, action) in behavior.actions.enumerated() {
            guard index < Self.scriptedActionBound else {
                actionRecords.append(FakeScriptActionRecord(
                    sessionID: sessionID,
                    label: "script-truncated (bound \(Self.scriptedActionBound))",
                    exitCode: ScriptedCLIOutcome.Code.runtimeFailure,
                    stdout: "",
                    stderr: "scripted action bound exceeded"))
                return
            }
            perform(action, sessionID: sessionID, store: store)
        }
    }

    private func perform(
        _ action: FakeAgentAction,
        sessionID: String,
        store: GRDBWikiStore
    ) {
        let scratch = sessionScratchDirectories[sessionID] ?? nil
        switch action {
        case .readStateFile:
            let url = (scratch ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("WIKI_STATE.md", isDirectory: false)
            if let data = DebugLog.trying("readStateFile", operation: { try Data(contentsOf: url) }),
               let text = String(data: data, encoding: .utf8) {
                capturedStateFileContents.append(text)
                actionRecords.append(FakeScriptActionRecord(
                    sessionID: sessionID, label: "readStateFile",
                    exitCode: ScriptedCLIOutcome.Code.success, stdout: "", stderr: ""))
            } else {
                actionRecords.append(FakeScriptActionRecord(
                    sessionID: sessionID, label: "readStateFile",
                    exitCode: ScriptedCLIOutcome.Code.runtimeFailure, stdout: "",
                    stderr: "staged WIKI_STATE.md not found"))
            }

        case .readStagedSource(let leaf):
            let url = (scratch ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent(leaf, isDirectory: false)
            if let data = DebugLog.trying("readStagedSource", operation: { try Data(contentsOf: url) }),
               let text = String(data: data, encoding: .utf8) {
                capturedStagedSources.append(FakeStagedSourceCapture(leaf: leaf, content: text))
                actionRecords.append(FakeScriptActionRecord(
                    sessionID: sessionID, label: "readStagedSource(\(leaf))",
                    exitCode: ScriptedCLIOutcome.Code.success, stdout: "", stderr: ""))
            } else {
                actionRecords.append(FakeScriptActionRecord(
                    sessionID: sessionID, label: "readStagedSource(\(leaf))",
                    exitCode: ScriptedCLIOutcome.Code.runtimeFailure, stdout: "",
                    stderr: "staged source not found"))
            }

        case .getPage(let title):
            let outcome = ScriptedWikiCtl.dispatch(
                ["--wiki", ScriptedWikiCtl.wikiSelector,
                 "page", "get", "--title", title, "--json"],
                in: store)
            if outcome.exitCode == ScriptedCLIOutcome.Code.success,
               let row = ScriptedPageGetJSON.parse(outcome.stdout) {
                sessionReads[sessionID] = (body: row.body_markdown, head: row.head_version_id)
            }
            actionRecords.append(FakeScriptActionRecord(
                sessionID: sessionID, label: "getPage(\(title))",
                exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr))

        case .listPages:
            let outcome = ScriptedWikiCtl.dispatch(
                ["--wiki", ScriptedWikiCtl.wikiSelector, "page", "list", "--json"],
                in: store)
            actionRecords.append(FakeScriptActionRecord(
                sessionID: sessionID, label: "listPages",
                exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr))

        case .writePage(let title, let body, let head, let createOnly, let sources):
            dispatchAdd(
                title: title, body: body, head: head, createOnly: createOnly,
                sources: sources, label: "writePage(\(title))",
                sessionID: sessionID, scratch: scratch, store: store)

        case .reconcileWrite(let title, let compose, let head, let createOnly, let sources):
            let body = compose(sessionReads[sessionID]?.body)
            dispatchAdd(
                title: title, body: body, head: head, createOnly: createOnly,
                sources: sources, label: "reconcileWrite(\(title))",
                sessionID: sessionID, scratch: scratch, store: store)

        case .racingWrite(let title, let body, let sources):
            dispatchAdd(
                title: title, body: body, head: .blind, createOnly: false,
                sources: sources, label: "racingWrite(\(title))",
                sessionID: sessionID, scratch: scratch, store: store)

        case .logAppend(let kind, let title, let source):
            var argv = ["--wiki", ScriptedWikiCtl.wikiSelector,
                        "log", "append", "--kind", kind, "--title", title]
            if let source {
                argv += ["--source", source]
            }
            let outcome = ScriptedWikiCtl.dispatch(argv, in: store)
            actionRecords.append(FakeScriptActionRecord(
                sessionID: sessionID, label: "logAppend(\(kind), \(title))",
                exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr))
        }
    }

    /// Build and dispatch one `wikictl page add` through the production
    /// parse + run path, writing the composed body to a scratch file first —
    /// exactly the delivery the executor contract mandates (`--body-file`).
    private func dispatchAdd(
        title: String,
        body: String,
        head: FakeWriteHead,
        createOnly: Bool,
        sources: [String],
        label: String,
        sessionID: String,
        scratch: URL?,
        store: GRDBWikiStore
    ) {
        let directory = scratch ?? FileManager.default.temporaryDirectory
        let bodyFile = directory.appendingPathComponent(
            "script-body-\(sessionID)-\(actionRecords.count).md", isDirectory: false)
        do {
            try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        } catch {
            actionRecords.append(FakeScriptActionRecord(
                sessionID: sessionID, label: label,
                exitCode: ScriptedCLIOutcome.Code.runtimeFailure, stdout: "",
                stderr: "scripted body write failed: \(error)"))
            return
        }

        var argv = ["--wiki", ScriptedWikiCtl.wikiSelector,
                    "page", "add", "--title", title,
                    "--body-file", bodyFile.path]
        switch head {
        case .blind:
            break
        case .fromLastRead:
            if let head = sessionReads[sessionID]?.head {
                argv += ["--expect-head", head]
            }
        case .literal(let value):
            argv += ["--expect-head", value]
        }
        if createOnly {
            argv += ["--create-only"]
        }
        for source in sources {
            argv += ["--source", source]
        }
        let outcome = ScriptedWikiCtl.dispatch(argv, in: store)
        actionRecords.append(FakeScriptActionRecord(
            sessionID: sessionID, label: label,
            exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr))
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        return nil
    }

    func cancel(_ session: SessionHandle) async {
        cancelCount += 1
        cancelledSessionIDs.append(session.id)
    }

    /// No subprocess behind a fake — record the call so lifetime tests can
    /// assert the release ordering (lease drain → shutdown → scratch removal).
    func shutdown() async {
        shutdownCount += 1
    }
}
#endif // os(macOS)
