import Foundation
import ACP
import ACPModel
import WikiFSCore

/// The ACP (Agent Client Protocol) backend — a second `AgentBackend` conformer
/// per `plans/acp-backend-and-permissions.md`. The app is ACP-only.
///
/// The app is the ACP **client**; it launches any ACP agent subprocess over
/// JSON-RPC/stdio (`wiedymi/swift-acp`) and consumes per-turn `session/update`
/// notifications, translating them into backend-neutral `AgentEvent`s. Writes
/// are mediated structurally by `session/request_permission` — the
/// always-ask/yolo lever — implemented here behind a `PermissionPolicy` + the
/// `ACPPermissionDelegate` `ClientDelegate`.
///
/// **Turn-boundary contract** (the port's hard requirement, see
/// `AgentBackend.swift`): every turn MUST end with `.messageStop`. ACP does NOT
/// send an explicit turn-end *notification*; the turn ends when the
/// `session/prompt` **request** returns (carrying `stopReason`). So `send`
/// synthesizes `.messageStop` from the prompt's completion / `stopReason`
/// (`.endTurn`/`.maxTokens`/`.refusal`/`.cancelled`/`.maxTurnRequests` →
/// `.messageStop`), keying turn end off the
/// `message_stop` wire line. The launcher releases the generation gate / edit
/// lock / transcript flush off `AgentEvent.endsGeneration`.
///
/// **Concurrency shape** (validated against `swift-concurrency-pro`):
/// - `ACPBackend` is an `actor`; it owns a map of `ACPSession` records. The
///   `Client` (itself an actor, hence `Sendable`) and `SessionId` are `Sendable`
///   and may cross isolation boundaries — so the per-turn drain Task can hold
///   them without `@unchecked Sendable`.
/// - `send` returns an `AsyncStream` whose `onStart` spawns a detached
///   `Task` that runs `client.sendPrompt` (which **blocks until the whole turn
///   is done**) and, in the same Task, drains `client.notifications` for this
///   session's `session/update`s. The stream finishes when the prompt task
///   completes — synthesizing `.messageStop` — or errors. We do NOT await
///   `sendPrompt` inline (that would deadlock the consumer: notifications can't
///   be delivered until the consumer drains, and the consumer can't drain until
///   `send` returns the stream).
/// - The cancellation bridge (`onTermination`) cancels the prompt task and
///   sends `session/cancel`.
/// - `.unbounded` buffering — the `@MainActor` consumer drains promptly and
///   tokens must never be dropped (same invariant as the CLI backend).
///
/// **Spike scope:** not wired into the launcher/UI yet (a later slice). No
/// live-agent end-to-end testing; the translator + permission policy are
/// unit-tested with no subprocess.
public actor ACPBackend: AgentBackend {

    /// How the configured ACP agent subprocess is spawned. Pluggable (NOT locked
    /// to the Zed adapter) — the user points at any ACP agent via `AgentProvider`.
    /// Resolved from `BackendProfile` (`providerHints`/`model`)
    /// so the path + the auth key stay backend-internal concerns, matching how
    /// the launcher's `CLIProfile` carries.
    ///
    /// Slice 3: now also carries the configured API key (for agents that require
    /// auth), threaded in via `providerHints["acpAgentApiKey"]`.
    struct AgentSpawnConfig: Sendable {
        let executablePath: String
        let arguments: [String]
        let workingDirectory: String?
        /// The Keychain-backed API key for agents that require auth. nil when no
        /// key is configured (→ a `missingCredentials` preflight error IF the
        /// agent advertises `authMethods`).
        let apiKey: String?
        /// Extra environment merged over the inherited process environment (+ the
        /// `WIKI_DB`/`WIKICTL`/`PATH` vars `start()` sets from
        /// `profile.cli`) when spawning the subprocess. Sourced from
        /// `providerHints`' `env.`-prefixed entries — the same convention
        /// `AgentProvider.env` is threaded through by
        /// `AgentBackendFactory.providerHints` (Phase 2,
        /// `plans/acp-multi-provider.md`). Empty for providers with no extra env.
        let environment: [String: String]

        init(
            executablePath: String,
            arguments: [String] = [],
            workingDirectory: String? = nil,
            apiKey: String? = nil,
            environment: [String: String] = [:]
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.apiKey = apiKey
            self.environment = environment
        }
    }

    /// One live ACP session: the client (actor), the ACP session id, the
    /// permission delegate (which holds the pending-permissions map + policy),
    /// and the models the agent advertised at `session/new`. All fields are
    /// `Sendable`, so this record can be read off-actor by the per-turn drain
    /// Task and by the launcher's model-cache capture.
    private struct ACPSession: Sendable {
        let client: Client
        let sessionId: SessionId
        let permissionDelegate: ACPPermissionDelegate
        /// The models the agent advertised (`session/new` →
        /// `NewSessionResponse.models`). nil when the agent didn't advertise a
        /// list (older agents). Captured at start so the launcher can cache them
        /// per-provider for the model picker (#329).
        let modelsInfo: ModelsInfo?
        /// Session-lifetime notification fanout (cause 6 fix,
        /// `plans/acp-stall-recovery.md` §1b). Replaces the per-turn
        /// re-acquisition of `client.notifications`.
        let notificationFanout: NotificationFanout
        /// The session-lifetime drain task (owns the single `client.notifications`
        /// iterator). Cancelled in `cancel`.
        let drainTask: Task<Void, Never>?
        /// The system prompt, injected into the first turn's user message so it
        /// reaches the agent regardless of whether it reads CLAUDE.md/AGENTS.md
        /// from cwd (Claude Code does; OpenCode, Hermes, Pi may not). The file
        /// writes in `deliverSystemPrompt` are the complementary delivery path.
        let systemPrompt: String
        /// Flipped after the first `send` injects `systemPrompt`. ACP sessions
        /// carry context across turns, so one injection suffices.
        var systemPromptInjected: Bool
    }

    private var sessions: [String: ACPSession] = [:]

    /// A launched + initialized + authenticated subprocess with no active session,
    /// or one that has sessions opened on it. This is the warm-process state from
    /// `plans/acp-session-efficiency.md` Phase 1: the process lifecycle (launch +
    /// initialize + authenticate) is separated from the session lifecycle
    /// (newSession + setModel), so multiple sessions can be created and closed on
    /// one subprocess without killing it. Cleared in `cancel()`.
    ///
    /// The notification drain + stderr forwarding are process-lifetime tasks owned
    /// here — started in `startProcess()`, cancelled in `cancel()`. Each
    /// `createSession()` creates an `ACPSession` that subscribes to the same
    /// `NotificationFanout`. `closeSession()` does NOT finish the fanout (only
    /// `cancel()` does) — safe because the generation gate serializes turns, so at
    /// most one session is actively prompting at a time.
    private struct WarmProcess: Sendable {
        let client: Client
        let permissionDelegate: ACPPermissionDelegate
        let initResponse: InitializeResponse
        let notificationFanout: NotificationFanout
        let drainTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>?
        /// Whether the agent advertised `sessionCapabilities.close` at `initialize`
        /// time. If not supported, `closeSession()` degrades to a no-op (the
        /// session context is freed when the process eventually terminates).
        let canCloseSession: Bool
        /// Phase 2: whether the agent advertised `sessionCapabilities.resume`
        /// (fastest crash recovery — restores the session without history replay).
        let canResume: Bool
        /// Phase 2: whether the agent advertised `loadSession: true`
        /// (slower fallback — replays history as notifications).
        let canLoadSession: Bool
        /// Phase 2: whether the agent advertised `sessionCapabilities.list`
        /// (used for the optional health-check ping in death detection).
        let canListSessions: Bool
        /// Phase 2: set to false when the subprocess dies (sendPrompt error or
        /// `kill(pid, 0) != 0`). When false, `resume()` spawns a new process.
        var processIsAlive: Bool
        /// Whether the agent advertised `sessionCapabilities.fork` at `initialize`
        /// time (Phase 3, `plans/acp-session-efficiency.md` §4). If not supported,
        /// `forkSession()` returns `nil` and the caller falls back to a fresh
        /// `createSession()` (current behavior — no context inheritance but no
        /// correctness risk).
        let canForkSession: Bool
    }

    private var warmProcess: WarmProcess?

    /// Phase 2: the ACP `SessionId` of the last active session, tracked for
    /// crash recovery. Set in `createSession()`, cleared in `closeSession()`
    /// (intentional close — not a crash) and `cancel()` (full teardown).
    /// `resume()` also sets this to the resumed session's ID.
    private var resumableSessionId: SessionId?

    /// Phase 2: the last `onExit` callback from `start()`/`createSession()`,
    /// saved so `resume()` can re-bind it on a new subprocess.
    private var savedOnExit: (@Sendable (Int) -> Void)?

    /// Phase 4: per-session usage trackers (cumulative token/cost from
    /// `UsageUpdate` + `SessionPromptResponse.usage`). Keyed by
    /// `SessionHandle.id`. Created in `createSession()` /
    /// `registerResumedSession()`; cleaned up in `closeSession()` / `cancel()`.
    /// Read by `sessionUsage(for:)` / `contextUsage(for:)` after a turn drains.
    private var usageStates: [String: SessionUsageState] = [:]

    /// The injected permission policy (yolo vs alwaysAsk). Defaults to `yolo`
    /// — the safe default per the design doc's caveat (always-ask enforcement
    /// depends on the agent emitting `request_permission`, which not all do).
    private let permissionPolicy: PermissionPolicy

    /// The client capabilities advertised at `initialize`. fs read/write +
    /// terminal (the structural second gate from the design doc).
    private let capabilities: ClientCapabilities

    /// Turn inactivity watchdog: how long without a `session/update`
    /// notification before declaring a stall (`plans/acp-stall-recovery.md` §1a).
    private let turnIdleTimeout: TimeInterval

    /// Hard ceiling on total turn duration — backstop against a chatty agent
    /// that streams forever without finishing.
    private let turnCeilingTimeout: TimeInterval

    /// Watchdog poll interval (seconds).
    private let watchdogPollInterval: TimeInterval

    /// Phase 4: whether to run executor sessions in parallel via
    /// `withTaskGroup`. Defaults to `false` (serial executors — current
    /// behavior). This requires the agent to handle concurrent `session/prompt`
    /// calls on different sessions of the same subprocess, plus Phase 3's
    /// `forkSession` for the parallel-fork pattern. A probe test (Phase 4
    /// prerequisite) confirms whether the agent supports this. Until then, the
    /// conservative serial default is safe.
    private let parallelExecutors: Bool

    init(
        permissionPolicy: PermissionPolicy = .bypass,
        capabilities: ClientCapabilities = ACPBackend.defaultCapabilities,
        turnIdleTimeout: TimeInterval = TurnLivenessPolicy.defaultIdleTimeout,
        turnCeilingTimeout: TimeInterval = TurnLivenessPolicy.defaultCeilingTimeout,
        watchdogPollInterval: TimeInterval = TurnLivenessPolicy.defaultPollInterval,
        parallelExecutors: Bool = false
    ) {
        self.permissionPolicy = permissionPolicy
        self.capabilities = capabilities
        self.turnIdleTimeout = turnIdleTimeout
        self.turnCeilingTimeout = turnCeilingTimeout
        self.watchdogPollInterval = watchdogPollInterval
        self.parallelExecutors = parallelExecutors
    }

    /// `fs` read/write + `terminal` — mirrors paseo's `BASE_ACP_CLIENT_CAPABILITIES`
    /// (acp-agent.ts:232). The client performs file writes / terminal commands
    /// on the agent's behalf, which is a second structural gate on top of
    /// `request_permission`.
    static let defaultCapabilities = ClientCapabilities(
        fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
        terminal: true
    )

// MARK: - AgentBackend
// TEMP DEBUG: ACPBackend.start/send/cancel carry verbose lifecycle logging
// TEMP DEBUG: (launch, initialize, auth, model discovery, setModel, per-turn
// TEMP DEBUG: prompt). Each DebugLog.agent line is tagged TEMP DEBUG for a
// TEMP DEBUG: later `grep -n "TEMP DEBUG"` strip.

    public func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        DebugLog.agent("ACPBackend.start: enter providerHints=\(profile.providerHints)") // TEMP DEBUG (existed; re-tagged)
        // Warm-subprocess reuse (Phase 1, plans/acp-session-efficiency.md): if a
        // warm process already exists (spawned by a prior `start()` call on this
        // backend), skip the expensive launch+initialize+authenticate and just
        // create a new session on it. This is how the multi-phase ingest
        // orchestrator achieves one subprocess across all phases.
        if warmProcess == nil {
            try await startProcess(profile: profile, onExit: onExit)
        }
        return try await createSession(profile: profile, systemPrompt: systemPrompt, onExit: onExit)
    }

    /// Launch + initialize + authenticate the agent subprocess and start the
    /// process-lifetime notification drain + stderr forwarding. Returns nothing
    /// — call `createSession()` to open an ACP session on the warm process.
    ///
    /// This is the process-lifecycle half of the split `start()` (Phase 1,
    /// `plans/acp-session-efficiency.md` §2.1). The session-lifecycle half is
    /// `createSession()`. The drain + fanout started here are process-lifetime
    /// (cancelled in `cancel()`, NOT in `closeSession()`), because the
    /// generation gate serializes turns so at most one session is actively
    /// prompting at a time.
    private func startProcess(
        profile: BackendProfile,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws {
        guard let spawn = Self.resolveSpawnConfig(from: profile) else {
            DebugLog.agent("ACPBackend.startProcess: FAIL noAgentConfigured") // TEMP DEBUG
            throw ACPBackendError.noAgentConfigured
        }

        let client = Client()
        // The permission delegate owns the always-ask/yolo policy. It is the
        // `ClientDelegate` that the agent's `session/request_permission` lands on.
        let permissionDelegate = ACPPermissionDelegate(policy: permissionPolicy)
        await client.setDelegate(permissionDelegate)

        DebugLog.agent("ACPBackend.startProcess: launching \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))") // TEMP DEBUG
        // Build the environment so the agent can find wikictl + the wiki DB.
        // Exports WIKI_DB/WIKICTL/PATH (NOT WIKI_ROOT — mount is optional;
        // wikictl is the primary read surface, issue #441).
        let env: [String: String]
        if let cli = profile.cli {
            env = Self.buildAgentEnv(
                from: cli,
                baseEnv: ProcessInfo.processInfo.environment,
                spawnEnvironment: spawn.environment)
        } else {
            env = ProcessInfo.processInfo.environment.merging(spawn.environment) { _, new in new }
        }

        try await client.launch(
            agentPath: spawn.executablePath,
            arguments: spawn.arguments,
            workingDirectory: spawn.workingDirectory,
            environment: env
        )

        DebugLog.agent("ACPBackend.startProcess: process launched, sending initialize") // TEMP DEBUG
        // Slice 3: initialize, then authenticate if the agent advertises
        // authMethods. The DECISION is a pure helper (`ACPAuthResolver.resolve`)
        // so it's unit-tested directly; here we just execute it. A key is never
        // logged.
        let initResponse = try await client.initialize(
            protocolVersion: 1,
            capabilities: capabilities,
            clientInfo: ClientInfo(name: "SelfDrivingWiki", title: "Self Driving Wiki", version: GeneratedVersion.appVersion)
        )
        DebugLog.agent("ACPBackend.startProcess: initialize OK agent=\(initResponse.agentInfo?.name ?? "?") authMethods=\(initResponse.authMethods?.count ?? 0)") // TEMP DEBUG

        switch ACPAuthResolver.resolve(authMethods: initResponse.authMethods, apiKey: spawn.apiKey) {
        case .skip:
            // Agent needs no auth — proceed straight to newSession.
            DebugLog.agent("ACPBackend.startProcess: agent advertised no authMethods, skipping authenticate") // TEMP DEBUG
        case .authenticate(let methodId, let credentials):
            DebugLog.agent("ACPBackend.startProcess: authenticating method=\(methodId)") // TEMP DEBUG
            let authResponse = try await client.authenticate(
                authMethodId: methodId,
                credentials: credentials
            )
            guard authResponse.success else {
                throw ACPBackendError.authenticationFailed(authResponse.error)
            }
        case .missingCredentials:
            // The agent advertised authMethods but no API key is configured. Do NOT
            // hard-block: many agents (Hermes via ~/.hermes, Claude via OAuth)
            // authenticate themselves with their own credentials and don't need a
            // client-provided key. Skip client-side `authenticate` and proceed to
            // newSession; if the agent truly requires client creds, the prompt will
            // surface that error (clearer than blocking at start).
            DebugLog.agent("ACPBackend.startProcess: no API key configured — skipping client auth (agent may self-authenticate)") // TEMP DEBUG
        }

        // Capture the CLI profile's log callbacks so ACP stderr and notifications
        // flow into run.stderr.log / run.jsonl (same hooks the old CLI backend used
        // via onStdoutChunk/onStderrChunk). Without this the log files stay empty
        // and "Reveal Log" opens a blank file.
        let onStdoutChunk = profile.cli?.onStdoutChunk
        let onStderrChunk = profile.cli?.onStderrChunk

        // Process-lifetime notification drain (cause 6 fix,
        // `plans/acp-stall-recovery.md` §1b + Phase 1 warm-subprocess change).
        // Acquire `client.notifications` ONCE here and fan events into a
        // process-lifetime `NotificationFanout`. Each turn subscribes to the
        // fanout instead of re-acquiring the SDK stream (AsyncStream is
        // single-consumer — two concurrent iterators split elements, silently
        // dropping notifications). The drain is cancelled in `cancel()`, NOT in
        // `closeSession()` — safe because the generation gate serializes turns.
        let fanout = NotificationFanout()
        let drainTask = Task { [client, fanout, onStdoutChunk] in
            let notifications = await client.notifications
            for await notification in notifications {
                if Task.isCancelled { break }
                // Mirror raw JSON-RPC notification to run.jsonl for debugging.
                if let onStdoutChunk {
                    let line = "{\"method\":\"\(notification.method)\"}\n"
                    onStdoutChunk(line)
                }
                fanout.yield(notification)
            }
            fanout.finish()
        }
        DebugLog.agent("ACPBackend.startProcess: process-lifetime notification drain started") // TEMP DEBUG

        // Forward agent stderr to DebugLog.agent + run.stderr.log (via the CLI
        // profile's onStderrChunk callback). Best-effort: the stream finishes
        // on terminate, so this task exits naturally.
        let stderrTask = Task { [client, onStderrChunk] in
            guard let stderrStream = await client.stderrLines() else { return }
            for await line in stderrStream {
                if Task.isCancelled { break }
                DebugLog.agent("ACP stderr: \(line)")
                onStderrChunk?(line + "\n")
            }
        }

        // Check capabilities for session/close support (Phase 1). If the agent
        // doesn't advertise sessionCapabilities.close, closeSession() degrades
        // to a no-op — the session context is freed when the process terminates.
        // Phase 2: also capture resume / loadSession / list for crash recovery.
        let sessionCaps = initResponse.agentCapabilities.sessionCapabilities
        let canCloseSession = sessionCaps?.close != nil
        let canResume = sessionCaps?.resume != nil
        let canLoadSession = initResponse.agentCapabilities.loadSession == true
        let canListSessions = sessionCaps?.list != nil
        // Check session/fork support (Phase 3, plans/acp-session-efficiency.md §4).
        // If not supported, forkSession() returns nil and the caller falls back
        // to a fresh createSession() (no context inheritance, no correctness risk).
        let canForkSession = sessionCaps?.fork != nil

        warmProcess = WarmProcess(
            client: client,
            permissionDelegate: permissionDelegate,
            initResponse: initResponse,
            notificationFanout: fanout,
            drainTask: drainTask,
            stderrTask: stderrTask,
            canCloseSession: canCloseSession,
            canResume: canResume,
            canLoadSession: canLoadSession,
            canListSessions: canListSessions,
            processIsAlive: true,
            canForkSession: canForkSession)

        // Wire onExit to the agent process termination. `Client.terminate()` is
        // the teardown; there's no direct terminationHandler on the SDK actor,
        // so we rely on `cancel`/`terminate` to fire onExit. (The launcher's
        // watchdog reconciles against this single completion channel.)
        // Note: with a warm subprocess, `createSession()` may rebind this per
        // session — the last binding wins.
        permissionDelegate.bindOnExit(onExit)

        DebugLog.agent("ACPBackend.startProcess: warm process ready canCloseSession=\(canCloseSession) canResume=\(canResume) canLoadSession=\(canLoadSession) canForkSession=\(canForkSession)") // TEMP DEBUG
    }

    /// Create a new ACP session on an already-started (warm) subprocess.
    /// Returns a new `SessionHandle` for the session. The subprocess must
    /// already be launched + initialized + authenticated (via `start()` or
    /// `startProcess()`).
    ///
    /// This is the session-lifecycle half of the split `start()` (Phase 1,
    /// `plans/acp-session-efficiency.md` §2.1). The process-lifecycle half is
    /// `startProcess()`. The orchestrator calls `createSession()` per phase
    /// and `closeSession()` at phase boundaries, keeping the subprocess alive
    /// across phases.
    func createSession(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        guard let warm = warmProcess else {
            // No warm process — caller forgot to call start()/startProcess() first.
            // This is a programming error, not a runtime condition.
            throw ACPBackendError.noAgentConfigured
        }

        let client = warm.client
        let permissionDelegate = warm.permissionDelegate
        let fanout = warm.notificationFanout
        let spawn = Self.resolveSpawnConfig(from: profile)

        let workingDir = profile.scratchDirectory?.path ?? spawn?.workingDirectory ?? FileManager.default.currentDirectoryPath
        // Deliver the system prompt via the spec-compliant on-disk mechanism
        // (issue #427). ACP's NewSessionRequest has no systemPrompt field — the
        // spec models system context as CLAUDE.md/AGENTS.md in the cwd. The File
        // Provider projection is the production default but is OPTIONAL for
        // unsigned dev builds; this makes delivery reliable regardless. Both
        // files match the projection (same `currentSystemPromptBody()` source).
        Self.deliverSystemPrompt(systemPrompt, to: workingDir)
        DebugLog.agent("ACPBackend.createSession: newSession cwd=\(workingDir)") // TEMP DEBUG
        let session = try await client.newSession(workingDirectory: workingDir)
        let sessionId = session.sessionId
        let modelsInfo = session.models
        let discoveredCount = modelsInfo?.availableModels.count ?? 0
        let currentModel = modelsInfo?.currentModelId ?? "(none)"
        DebugLog.agent("ACPBackend.createSession: discovered \(discoveredCount) model(s), current=\(currentModel)") // TEMP DEBUG

        // #329: if the user picked a model for this provider, apply it right
        // after newSession — BEFORE the first prompt — so the agent uses a
        // valid model instead of its (possibly broken) default. The selection
        // is threaded in via providerHints by the launcher. The DECISION is a
        // pure helper (`ACPModelSelectionResolver.resolve`) so it's unit-tested
        // without a subprocess; here we just execute it. A bad/stale selection
        // falls back to the agent default (no setModel) — never reproduces the
        // 404 the picker exists to prevent.
        if let selectedModelId = profile.providerHints[HintKey.acpSelectedModelId.rawValue],
           !selectedModelId.isEmpty {
            let advertisedIds = modelsInfo?.availableModels.map(\.modelId) ?? []
            let decision = ACPModelSelectionResolver.resolve(
                selectedModelId: selectedModelId,
                currentModelId: modelsInfo?.currentModelId,
                advertisedModelIds: advertisedIds)
            if case .apply(let id) = decision {
                DebugLog.agent("ACPBackend.createSession: setModel \(id)") // TEMP DEBUG
                do {
                    _ = try await client.setModel(sessionId: sessionId, modelId: id)
                } catch {
                    // setModel failed — log and proceed to the prompt anyway; the
                    // agent's default may still work, and a clearer error will
                    // surface from the prompt if not. Non-fatal by design.
                    DebugLog.agent("ACPBackend.createSession: setModel \(id) failed: \(error.localizedDescription)") // TEMP DEBUG
                }
            } else {
                DebugLog.agent("ACPBackend.createSession: keeping agent default model (selected=\(selectedModelId) → \(decision))") // TEMP DEBUG
            }
        }

        let sessionID = UUID().uuidString
        sessions[sessionID] = ACPSession(
            client: client,
            sessionId: sessionId,
            permissionDelegate: permissionDelegate,
            modelsInfo: modelsInfo,
            notificationFanout: fanout,
            drainTask: nil,
            systemPrompt: systemPrompt,
            systemPromptInjected: false
        )

        // Phase 4: create a usage tracker for this session.
        usageStates[sessionID] = SessionUsageState()

        // Rebind onExit so the latest caller's callback fires on process exit.
        // With a warm subprocess, multiple sessions share one permission delegate;
        // the last binding wins (each phase's onExit is phase-tracking telemetry
        // that does NOT call finish() — the orchestrator owns finish()).
        permissionDelegate.bindOnExit(onExit)

        // Phase 2: track the ACP session ID for crash recovery + save the
        // onExit callback so resume() can re-bind it on a new subprocess.
        resumableSessionId = sessionId
        savedOnExit = onExit

        DebugLog.agent("ACPBackend.createSession: session \(sessionId.value) (handle \(sessionID)) ready") // TEMP DEBUG
        return SessionHandle(id: sessionID)
    }

    public func send(_ turn: TurnInput, into handle: SessionHandle) async -> AsyncStream<AgentEvent> {
        guard var session = sessions[handle.id] else {
            // Session gone (cancelled/finished) — return an empty, finished stream.
            DebugLog.agent("ACPBackend.send: no session for handle \(handle.id) — empty stream") // TEMP DEBUG (existed; re-tagged)
            return AsyncStream { $0.finish() }
        }
        // Inject the system prompt into the first turn's user text — agent-agnostic
        // delivery (issue #427). The file writes (CLAUDE.md/AGENTS.md in cwd) are
        // the complementary path for agents that read them (Claude Code); this
        // injection guarantees delivery for agents that don't (OpenCode, Hermes,
        // Pi). ACP sessions carry context across turns, so one injection suffices.
        var promptText = turn.userText
        if !session.systemPromptInjected && !session.systemPrompt.isEmpty {
            promptText = Self.injectSystemPrompt(session.systemPrompt, into: turn.userText)
            session.systemPromptInjected = true
            sessions[handle.id] = session
            DebugLog.agent("ACPBackend.send: injected system prompt (\(session.systemPrompt.count) chars) into first turn")
        }
        DebugLog.agent("ACPBackend.send: turn=\"\(turn.userText.prefix(80))\" handle=\(handle.id)") // TEMP DEBUG (existed; re-tagged)

        let client = session.client
        let sessionId = session.sessionId
        let translator = ACPEventTranslator()
        let fanout = session.notificationFanout
        let idleTimeout = turnIdleTimeout
        let ceilingTimeout = turnCeilingTimeout
        let pollInterval = watchdogPollInterval
        // Phase 4: per-session usage tracker. Captured by reference into the
        // drain task (UsageUpdate) and prompt task (Usage). Same
        // @unchecked Sendable pattern as TurnCompletionFlag / ProcessHealthFlag.
        let usageState = usageStates[handle.id]

        // `.unbounded` buffering — the @MainActor consumer drains promptly and
        // no events may be dropped (same invariant as the CLI backend).
        return AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            // Shared flag: once either the prompt task or the watchdog resolves
            // the turn, the other short-circuits (yield/finish to an already-
            // finished continuation are safe no-ops, but this avoids redundant
            // cancelSession calls and confusing duplicate log lines).
            let completionFlag = TurnCompletionFlag()
            // Phase 2: liveness flag — set when sendPrompt throws or the process
            // is detected as dead via `kill(pid, 0)`. Read by the actor after
            // the turn stream finishes to update `warmProcess.processIsAlive`.
            let processHealth = ProcessHealthFlag()
            let turnStartedAt = fanout.activityTimestamp

            // --- Watchdog task (cause 5 fix, plans/acp-stall-recovery.md §1a) ---
            // Polls every `pollInterval`; if the prompt hasn't completed AND no
            // notification has arrived for `idleTimeout`, or the total duration
            // exceeds `ceilingTimeout`, fail the turn: cancelSession best-effort,
            // synthesize turn-end events, finish the continuation.
            let watchdogTask = Task { [client, sessionId, fanout, completionFlag, processHealth] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(pollInterval))
                    if Task.isCancelled { return }
                    // Phase 2: if the prompt task already detected process death
                    // (sendPrompt threw), short-circuit — no need to evaluate
                    // liveness or send cancelSession to a dead process.
                    if processHealth.died {
                        return
                    }
                    let decision = TurnLivenessPolicy.evaluate(
                        now: Date(),
                        promptDone: completionFlag.isDone,
                        turnStartedAt: turnStartedAt,
                        lastActivityAt: fanout.activityTimestamp,
                        idleTimeout: idleTimeout,
                        ceilingTimeout: ceilingTimeout
                    )
                    switch decision {
                    case .healthy:
                        continue
                    case .stalled(let idle):
                        // Phase 2: before declaring a stall, check if the
                        // subprocess actually died (issue #338 — silent death
                        // looks like a stall because no notifications arrive).
                        // `kill(pid, 0)` is a zero-signal liveness probe.
                        if let pid = await client.processIdentifier(), pid > 0 {
                            if kill(pid, 0) != 0 {
                                DebugLog.agent("ACPBackend: process dead (kill(\(pid), 0) != 0) — marking for resume") // TEMP DEBUG
                                processHealth.markDied()
                                completionFlag.markDone()
                                for event in Self.turnEndEvents(error: ACPBackendError.processDied) {
                                    continuation.yield(event)
                                }
                                continuation.finish()
                                return
                            }
                        }
                        DebugLog.agent("ACPBackend: TURN STALLED — idle \(Int(idle))s, recovering (cancelSession + turnEnd)") // TEMP DEBUG (existed; re-tagged)
                        completionFlag.markDone()
                        for event in Self.turnEndEvents(error: ACPBackendError.turnStalled(idleSeconds: idle)) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        try? await client.cancelSession(sessionId: sessionId)
                        return
                    case .ceilingExceeded(let total):
                        DebugLog.agent("ACPBackend: TURN CEILING exceeded (\(Int(total))s), recovering") // TEMP DEBUG (existed; re-tagged)
                        completionFlag.markDone()
                        for event in Self.turnEndEvents(error: ACPBackendError.turnCeilingExceeded(totalSeconds: total)) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        try? await client.cancelSession(sessionId: sessionId)
                        return
                    }
                }
            }

            // --- Prompt task ---
            // Runs concurrently with the watchdog. `sendPrompt` BLOCKS until the
            // whole turn completes (returns SessionPromptResponse with
            // stopReason), while notifications stream in via the fanout
            // subscription. The prompt task and watchdog are both cancelled on
            // consumer termination.
            let promptTask = Task { [client, sessionId, fanout, completionFlag, processHealth, promptText, usageState] in
                // Subscribe to the session-lifetime fanout (NOT the SDK's
                // `client.notifications` — that's single-consumer; re-acquiring
                // it per turn was cause 6). Turns are serialized by the
                // generation gate, so at most one subscriber is active.
                let updates = fanout.subscribe()
                let drainTask = Task {
                    for await notification in updates {
                        if Task.isCancelled { return }
                        guard notification.method == "session/update" else { continue }
                        guard let params = notification.params else { continue }
                        let result = ACPBackend.translateNotification(params: params, sessionId: sessionId, translator: translator)
                        DebugLog.agent("ACPBackend: session/update → \(result.events.count) AgentEvent(s)") // TEMP DEBUG (existed; re-tagged)
                        for event in result.events {
                            continuation.yield(event)
                        }
                        // Phase 4: capture usage_update (context window + cost).
                        // Consumed internally — not surfaced as an AgentEvent.
                        if let usageUpdate = result.usageUpdate {
                            usageState?.captureUsageUpdate(
                                used: usageUpdate.used,
                                size: usageUpdate.size,
                                cost: usageUpdate.cost?.amount,
                                currency: usageUpdate.cost?.currency)
                        }
                    }
                }
                defer { drainTask.cancel() }

                do {
                    DebugLog.agent("ACPBackend: sending session/prompt (\(promptText.count) chars)") // TEMP DEBUG (existed; re-tagged)
                    let response = try await client.sendPrompt(
                        sessionId: sessionId,
                        content: [.text(TextContent(text: promptText))]
                    )
                    // Phase 4: capture per-turn final usage (token totals from
                    // SessionPromptResponse.usage). Previously discarded — now
                    // accumulated for budget tracking (#528).
                    if let turnUsage = response.usage {
                        usageState?.captureTurnUsage(
                            inputTokens: turnUsage.inputTokens,
                            outputTokens: turnUsage.outputTokens,
                            totalTokens: turnUsage.totalTokens,
                            cachedReadTokens: turnUsage.cachedReadTokens,
                            thoughtTokens: turnUsage.thoughtTokens)
                    }
                    // If the watchdog already resolved the turn (e.g. it fired
                    // just as sendPrompt returned), skip — continuation is done.
                    guard !completionFlag.isDone else { return }
                    completionFlag.markDone()
                    DebugLog.agent("ACPBackend: prompt completed stopReason=\(response.stopReason.rawValue)") // TEMP DEBUG (existed; re-tagged)
                    for event in Self.turnEndEvents(error: nil) {
                        continuation.yield(event)
                    }
                } catch {
                    // If the watchdog already resolved the turn, the error here
                    // is just the fallout from cancelSession — skip it.
                    guard !completionFlag.isDone else { return }
                    completionFlag.markDone()
                    // Phase 2: a sendPrompt error often means the subprocess
                    // died (issue #338 — pipe broken / transport closed). Mark
                    // the process health flag so the watchdog short-circuits,
                    // and surface a .processDied error so the caller knows to
                    // attempt resume().
                    processHealth.markDied()
                    DebugLog.agent("ACPBackend: prompt failed: \(error.localizedDescription)") // TEMP DEBUG (existed; re-tagged)
                    for event in Self.turnEndEvents(error: error) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }

            // Cancellation bridge: if the consumer cancels the for-await loop
            // (stopAgent), cancel both tasks and send session/cancel.
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    promptTask.cancel()
                    watchdogTask.cancel()
                    Task { [client, sessionId] in
                        try? await client.cancelSession(sessionId: sessionId)
                    }
                }
                // .finished: natural turn end, nothing to do.
            }
        }
    }

    /// Phase 2: Resume a session after subprocess death (issue #338). The
    /// caller passes the ACP `SessionId.value` (a String, NOT our internal
    /// `SessionHandle` UUID). Implementation:
    ///
    /// 1. If the warm process is still alive and has this session, return nil
    ///    (no resume needed — the session is still active).
    /// 2. Spawn a new subprocess via `startProcess()` (the old one died).
    /// 3. If the agent supports `sessionCapabilities.resume`: call
    ///    `client.resumeSession(sessionId:cwd:)` — restores the session without
    ///    history replay (fastest).
    /// 4. If resume is not supported but `loadSession` is: call
    ///    `client.loadSession(sessionId:cwd:)` — replays history (slower but
    ///    preserves context).
    /// 5. If neither is supported: return nil — the caller falls back to
    ///    `start()` (fresh session, no context, logged as context lost).
    ///
    /// On success, a new `ACPSession` record is created for the resumed
    /// session (same ACP `SessionId`, new `SessionHandle`).
    public func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        DebugLog.agent("ACPBackend.resume: sessionID=\(sessionID)") // TEMP DEBUG

        // 1. If the warm process is alive and has this session, no resume needed.
        if let warm = warmProcess, warm.processIsAlive {
            // Check if this session is still active on the live process.
            // If the process is alive and we have a session record, the session
            // is still usable — no resume.
            if sessions.values.contains(where: { $0.sessionId.value == sessionID }) {
                DebugLog.agent("ACPBackend.resume: process alive + session active — no resume needed") // TEMP DEBUG
                return nil
            }
        }

        // 2. Mark the old warm process as dead (if not already) and clean it up.
        // The old process's drain/fanout are dead; we need a fresh subprocess.
        if let oldWarm = warmProcess {
            DebugLog.agent("ACPBackend.resume: tearing down dead warm process") // TEMP DEBUG
            oldWarm.drainTask.cancel()
            oldWarm.stderrTask?.cancel()
            oldWarm.notificationFanout.finish()
            // Best-effort: try to terminate the old client (may already be dead).
            await oldWarm.client.terminate()
            warmProcess = nil
        }

        // 3. Spawn a new subprocess. startProcess() re-initializes +
        //    re-authenticates. Re-bind the saved onExit callback if we have one.
        let onExit: @Sendable (Int) -> Void = savedOnExit ?? { _ in }
        try await startProcess(profile: profile, onExit: onExit)

        guard let newWarm = warmProcess else {
            DebugLog.agent("ACPBackend.resume: startProcess failed to create warm process") // TEMP DEBUG
            return nil
        }

        let client = newWarm.client
        let cwd = profile.scratchDirectory?.path
            ?? Self.resolveSpawnConfig(from: profile)?.workingDirectory
            ?? FileManager.default.currentDirectoryPath
        let acpSessionId = SessionId(sessionID)

        // 4. Attempt resume → load → give up (fallback chain).
        if newWarm.canResume {
            // Fastest path: resumeSession restores context without replay.
            do {
                DebugLog.agent("ACPBackend.resume: attempting resumeSession sessionId=\(sessionID) cwd=\(cwd)") // TEMP DEBUG
                let response = try await client.resumeSession(
                    sessionId: acpSessionId,
                    cwd: cwd
                )
                DebugLog.agent("ACPBackend.resume: resumeSession succeeded models=\(response.models?.availableModels.count ?? 0)") // TEMP DEBUG
                return registerResumedSession(
                    acpSessionId: acpSessionId,
                    warm: newWarm,
                    modelsInfo: response.models
                )
            } catch {
                // Resume failed (session GC'd, protocol error). Fall through to
                // loadSession if supported.
                DebugLog.agent("ACPBackend.resume: resumeSession failed: \(error.localizedDescription) — trying fallback") // TEMP DEBUG
            }
        }

        if newWarm.canLoadSession {
            // Slower path: loadSession replays history as notifications.
            do {
                DebugLog.agent("ACPBackend.resume: attempting loadSession sessionId=\(sessionID) cwd=\(cwd)") // TEMP DEBUG
                let response = try await client.loadSession(
                    sessionId: acpSessionId,
                    cwd: cwd
                )
                DebugLog.agent("ACPBackend.resume: loadSession succeeded models=\(response.models?.availableModels.count ?? 0)") // TEMP DEBUG
                // loadSession may return a new sessionId (some agents), or nil.
                let resumedId = response.sessionId ?? acpSessionId
                return registerResumedSession(
                    acpSessionId: resumedId,
                    warm: newWarm,
                    modelsInfo: response.models
                )
            } catch {
                DebugLog.agent("ACPBackend.resume: loadSession failed: \(error.localizedDescription) — giving up") // TEMP DEBUG
            }
        }

        // 5. Neither resume nor load is supported (or both failed).
        // Return nil — the caller falls back to start() (fresh session, no
        // context). Log that context was lost so it's visible in Console.
        DebugLog.agent("ACPBackend.resume: agent does not support resume or load — context lost, caller should use fresh start") // TEMP DEBUG
        return nil
    }

    /// Phase 2: Helper to register a resumed session in the `sessions` map.
    /// Creates a new `SessionHandle` for an existing ACP session (resumed or
    /// loaded), stores the `resumableSessionId`, and returns the handle.
    /// The resumed session inherits the warm process's client, fanout, and
    /// permission delegate.
    private func registerResumedSession(
        acpSessionId: SessionId,
        warm: WarmProcess,
        modelsInfo: ModelsInfo?
    ) -> SessionHandle {
        let sessionID = UUID().uuidString
        sessions[sessionID] = ACPSession(
            client: warm.client,
            sessionId: acpSessionId,
            permissionDelegate: warm.permissionDelegate,
            modelsInfo: modelsInfo,
            notificationFanout: warm.notificationFanout,
            drainTask: nil,
            systemPrompt: "",
            systemPromptInjected: false  // resumed session already has context
        )
        // Phase 4: create a usage tracker for this resumed session.
        usageStates[sessionID] = SessionUsageState()
        resumableSessionId = acpSessionId
        DebugLog.agent("ACPBackend.resume: resumed session \(acpSessionId.value) (handle \(sessionID)) ready") // TEMP DEBUG
        return SessionHandle(id: sessionID)
    }

    /// Phase 2: Check if the subprocess is alive. Used by the orchestrator to
    /// decide whether to call `resume()` or proceed normally. Returns false if
    /// there's no warm process, or if `kill(pid, 0)` returns non-zero.
    func isProcessAlive() async -> Bool {
        guard let warm = warmProcess, warm.processIsAlive else { return false }
        guard let pid = await warm.client.processIdentifier(), pid > 0 else {
            return false
        }
        // `kill(pid, 0)` sends signal 0 — a liveness probe that returns 0 if
        // the process exists, or sets errno if it doesn't.
        return kill(pid, 0) == 0
    }

    /// Phase 2: The ACP session ID of the last active session, for crash
    /// recovery. nil if no session was created or the last session was
    /// intentionally closed (`closeSession`) or cancelled.
    func currentResumableSessionId() -> SessionId? {
        return resumableSessionId
    }

    public func cancel(_ session: SessionHandle) async {
        let record = sessions.removeValue(forKey: session.id)
        // Phase 4: clean up the usage tracker.
        usageStates.removeValue(forKey: session.id)
        // Phase 2: clear crash-recovery state — this is a full teardown, not
        // a crash. No session should be resumed from a cancelled run.
        resumableSessionId = nil
        savedOnExit = nil
        // No session record? Could be a warm-subprocess cancel where the session
        // was already closed via closeSession but the process is still alive.
        // Tear down the warm process if present.
        if record == nil {
            DebugLog.agent("ACPBackend.cancel: no session for handle \(session.id)") // TEMP DEBUG
        }
        DebugLog.agent("ACPBackend.cancel: cancelling session=\(record?.sessionId.value ?? "(none)") handle=\(session.id)") // TEMP DEBUG
        // Drain any in-flight always-ask continuations BEFORE tearing down, so a
        // pending `request_permission` never leaks its `CheckedContinuation`
        // (leaked continuations warn/trap at task end). The agent receives a
        // `cancelled` outcome for each, which it treats as denied.
        record?.permissionDelegate.cancelAllPending()

        // Tear down the warm process (drain + stderr + fanout + terminate).
        // This is the full teardown — the warm subprocess is killed.
        if let warm = warmProcess {
            DebugLog.agent("ACPBackend.cancel: tearing down warm process") // TEMP DEBUG
            warm.drainTask.cancel()
            warm.stderrTask?.cancel()
            warm.notificationFanout.finish()
            // Cancel any in-flight prompt for the session being torn down.
            if let record {
                try? await warm.client.cancelSession(sessionId: record.sessionId)
            }
            await warm.client.terminate()
            warm.permissionDelegate.fireOnExit(status: 0)
            warmProcess = nil
        } else if let record {
            // No warm process (pre-Phase-1 path or process already gone) —
            // cancel + terminate via the session's own client reference.
            try? await record.client.cancelSession(sessionId: record.sessionId)
            await record.client.terminate()
            record.permissionDelegate.fireOnExit(status: 0)
        }
    }

    /// Close a session WITHOUT terminating the subprocess. Frees the session's
    /// context and resources but keeps the agent process alive for the next
    /// `start()` / `createSession()` to create a new session on the same
    /// subprocess.
    ///
    /// This is the Phase 1 change from `plans/acp-session-efficiency.md`:
    /// separate the session lifecycle (per-phase) from the process lifecycle
    /// (per-run). The orchestrator calls `closeSession` at phase boundaries
    /// and `cancel` only at run end.
    ///
    /// Checks `sessionCapabilities.close` (captured at `initialize` time). If
    /// not supported, falls back to cancelling the session via `cancelSession`
    /// without closing — the session context will be freed when the process
    /// eventually terminates (leaked memory, not correctness). The session is
    /// removed from the sessions map either way so subsequent `send` calls
    /// return an empty stream (the turn is done).
    func closeSession(_ handle: SessionHandle) async {
        guard let record = sessions.removeValue(forKey: handle.id) else {
            DebugLog.agent("ACPBackend.closeSession: no session for handle \(handle.id) — no-op") // TEMP DEBUG
            return
        }
        // Phase 4: clean up the usage tracker for this session.
        usageStates.removeValue(forKey: handle.id)
        // Phase 2: clear the resumable session ID — this was an intentional
        // close (phase boundary), not a crash. We should NOT resume a closed
        // session on a new subprocess.
        if resumableSessionId?.value == record.sessionId.value {
            resumableSessionId = nil
        }
        DebugLog.agent("ACPBackend.closeSession: closing session=\(record.sessionId.value) handle=\(handle.id)") // TEMP DEBUG
        // Drain any in-flight always-ask continuations so a pending
        // `request_permission` never leaks its `CheckedContinuation`.
        record.permissionDelegate.cancelAllPending()
        // Cancel any in-flight prompt best-effort.
        try? await record.client.cancelSession(sessionId: record.sessionId)
        // If the agent supports session/close, free the session context.
        // Otherwise degrade gracefully — the session context is leaked until
        // the process terminates (fine for Phase 1: one process per run).
        if warmProcess?.canCloseSession ?? false {
            DebugLog.agent("ACPBackend.closeSession: sending session/close") // TEMP DEBUG
            do {
                _ = try await record.client.closeSession(sessionId: record.sessionId)
            } catch {
                // closeSession failed — log and proceed; the session is already
                // removed from the map, so no further sends will use it. The
                // context will be freed on process termination.
                DebugLog.agent("ACPBackend.closeSession: session/close failed: \(error.localizedDescription)") // TEMP DEBUG
            }
        } else {
            DebugLog.agent("ACPBackend.closeSession: agent does not support session/close — skipping (context freed at terminate)") // TEMP DEBUG
        }
        DebugLog.agent("ACPBackend.closeSession: session closed, subprocess stays alive") // TEMP DEBUG
    }

    /// Fork a session: creates a new session that inherits the parent's
    /// conversation context but diverges from that point. The parent session
    /// stays unchanged. Used by executors to get the planner's understanding
    /// of the source layout without the reasoning noise (Phase 3,
    /// `plans/acp-session-efficiency.md` §4).
    ///
    /// Checks `sessionCapabilities.fork` (captured at `initialize` time from
    /// the `WarmProcess`). If fork is not supported, returns `nil` — the caller
    /// must fall back to `createSession()` (a fresh session with no inherited
    /// context, which is the current pre-Phase-3 behavior).
    ///
    /// The forked session:
    /// - Shares the same `Client` (subprocess) and `NotificationFanout` as the
    ///   parent — it's the same process, just a new session id.
    /// - Inherits the parent's `systemPrompt` but sets `systemPromptInjected = true`
    ///   because the forked context already contains the injected system prompt.
    /// - Gets its own entry in the `sessions` map under a new `SessionHandle.id`.
    ///
    /// The parent session remains active and must be separately closed via
    /// `closeSession()` when all forks are done.
    ///
    /// - Parameters:
    ///   - parentHandle: The session to fork from (typically the planner session).
    ///   - cwd: The working directory for the forked session. If nil, uses the
    ///     warm process's working directory.
    /// - Returns: A new `SessionHandle` for the forked session, or `nil` if fork
    ///   is not supported.
    func forkSession(
        from parentHandle: SessionHandle,
        cwd: String? = nil
    ) async throws -> SessionHandle? {
        guard let warm = warmProcess else {
            DebugLog.agent("ACPBackend.forkSession: no warm process — cannot fork") // TEMP DEBUG
            return nil
        }
        guard warm.canForkSession else {
            DebugLog.agent("ACPBackend.forkSession: agent does not support session/fork — returning nil (caller falls back to createSession)") // TEMP DEBUG
            return nil
        }
        guard let parent = sessions[parentHandle.id] else {
            DebugLog.agent("ACPBackend.forkSession: no parent session for handle \(parentHandle.id) — returning nil") // TEMP DEBUG
            return nil
        }

        let workingDir = cwd ?? FileManager.default.currentDirectoryPath

        DebugLog.agent("ACPBackend.forkSession: forking session=\(parent.sessionId.value) cwd=\(workingDir)") // TEMP DEBUG
        let response = try await warm.client.forkSession(
            sessionId: parent.sessionId,
            cwd: workingDir
        )
        let forkedSessionId = response.sessionId
        DebugLog.agent("ACPBackend.forkSession: forked → session=\(forkedSessionId.value)") // TEMP DEBUG

        // The forked session inherits the parent's conversation context —
        // including the already-injected system prompt. Mark it as injected so
        // `send()` doesn't re-inject it on the first turn.
        let sessionID = UUID().uuidString
        sessions[sessionID] = ACPSession(
            client: warm.client,
            sessionId: forkedSessionId,
            permissionDelegate: warm.permissionDelegate,
            modelsInfo: parent.modelsInfo,
            notificationFanout: warm.notificationFanout,
            drainTask: nil,
            systemPrompt: parent.systemPrompt,
            systemPromptInjected: true
        )

        DebugLog.agent("ACPBackend.forkSession: forked session \(forkedSessionId.value) (handle \(sessionID)) ready") // TEMP DEBUG
        return SessionHandle(id: sessionID)
    }

    // MARK: - Usage tracking (Phase 4)

    /// Cumulative token usage and cost for a session. Returns nil if the
    /// session is gone (closed/cancelled) or never existed. Read after each
    /// phase's stream drains — the orchestrator accumulates this into a
    /// per-run total for budget-aware ingestion (#528).
    ///
    /// The returned struct is a snapshot: it reflects all `usage_update`
    /// notifications and `SessionPromptResponse.usage` values captured so far.
    func sessionUsage(for sessionHandle: SessionHandle) async -> SessionUsage? {
        usageStates[sessionHandle.id]?.snapshot()
    }

    /// The current context window usage for a session — `used` tokens consumed
    /// out of `size` total. Returns nil if the session is gone or no
    /// `usage_update` has been received yet. The orchestrator checks this to
    /// proactively manage context windows (64% → artifact write; 80% → close +
    /// fresh session).
    func contextUsage(for sessionHandle: SessionHandle) async -> (used: Int, size: Int)? {
        usageStates[sessionHandle.id]?.contextUsage()
    }

    /// Whether the context window has exceeded 80% — the orchestrator checks
    /// this after each turn to decide whether to close + restart the session
    /// (context rot pollutes quality at high usage ratios).
    func isContextCritical(for sessionHandle: SessionHandle) async -> Bool {
        usageStates[sessionHandle.id]?.contextCritical ?? false
    }

    // MARK: - Parallel executors config (Phase 4, deferred)

    /// Phase 4: whether parallel executor sessions are enabled. Defaults to
    /// `false`. Requires Phase 3 (`forkSession`) + a concurrent-session probe
    /// test. When `true`, the orchestrator runs executors via `withTaskGroup`;
    /// when `false` (current), executors run serially.
    func isParallelExecutorsEnabled() -> Bool {
        parallelExecutors
    }

    // MARK: - Model discovery (#329)

    /// The models the agent advertised for a session (`session/new` →
    /// `ModelsInfo.availableModels`), captured at start. The launcher reads this
    /// right after `backend.start` to cache them per-provider for the model
    /// picker. Empty when the agent didn't advertise a list (older agents) or
    /// the handle is gone (cancelled/finished).
    func availableModels(for sessionHandle: SessionHandle) async -> [ModelInfo] {
        guard let session = sessions[sessionHandle.id] else { return [] }
        return session.modelsInfo?.availableModels ?? []
    }

    /// The agent process identifier for a session (SDK fork Fix 4). nil when
    /// the session is gone or the process hasn't launched. The launcher reads
    /// this to populate `currentProcessID` so the watchdog can eventually
    /// `kill(pgid)` a stuck agent.
    func processIdentifier(for sessionHandle: SessionHandle) async -> Int32? {
        guard let session = sessions[sessionHandle.id] else { return nil }
        return await session.client.processIdentifier()
    }

    /// The agent's current model id for a session (`ModelsInfo.currentModelId`),
    /// or nil when the agent didn't advertise one. Read by the launcher to log
    /// the effective model alongside the discovered list.
    func currentModelId(for sessionHandle: SessionHandle) async -> String? {
        guard let session = sessions[sessionHandle.id] else { return nil }
        return session.modelsInfo?.currentModelId
    }

    // MARK: - Permission resolution seam (PermissionResolving)

    /// Resolve a pending permission request (always-ask). The future chat UI
    /// calls this with the user's chosen option id. For the spike this seam is
    /// exercised by tests, not wired to UI. Returns true if a pending request
    /// was resolved, false if no such pending id exists.
    func resolvePermission(sessionHandle: SessionHandle, optionId: String) async -> Bool {
        guard let session = sessions[sessionHandle.id] else { return false }
        return session.permissionDelegate.resolve(optionId: optionId)
    }

    /// The currently-pending permission requests for a session (always-ask
    /// mode). The future UI surfaces these as Approve/Reject affordances.
    func pendingPermissions(sessionHandle: SessionHandle) async -> [PendingPermission] {
        guard let session = sessions[sessionHandle.id] else { return [] }
        return session.permissionDelegate.pendingSnapshot()
    }

    /// Drain all pending always-ask requests for a session (resume each as
    /// cancelled). The launcher calls this on teardown/cancel so no
    /// `CheckedContinuation` leaks. Returns the count drained (for tests).
    @discardableResult
    func cancelAllPending(sessionHandle: SessionHandle) async -> Int {
        guard let session = sessions[sessionHandle.id] else { return 0 }
        return session.permissionDelegate.cancelAllPending()
    }

    // MARK: - Internal

    /// Resolve the agent spawn config from the profile. The executable path comes
    /// from `providerHints["acpAgentPath"]` (or falls back to `profile.model`),
    /// extra args from `providerHints["acpAgentArgs"]`, and the auth API key from
    /// `providerHints["acpAgentApiKey"]`. The args string is tokenized with
    /// `ShellArgv.tokenize`, the shell-aware whitespace tokenizer shared with the
    /// launcher's provider-spawn resolution.
    ///
    /// These hints are sourced from `AgentProvidersConfig` by
    /// `AgentBackendFactory`, and the key is the Keychain-backed secret. NOT
    /// hardcoded to the Zed adapter — the user points at any ACP agent. Returns
    /// nil if no path is configured (→ `noAgentConfigured`).
    /// Internal (not `private`) so `resolveSpawnConfig` — including the Phase 2
    /// `environment` merge from `env.`-prefixed `providerHints` — is directly
    /// unit-testable from `@testable import WikiFSEngine` without spawning a
    /// subprocess (`ACPWiringTests`).
    static func resolveSpawnConfig(from profile: BackendProfile) -> AgentSpawnConfig? {
        let path = profile.providerHints[HintKey.acpAgentPath.rawValue] ?? profile.model
        guard let path, !path.isEmpty else { return nil }
        let args = ShellArgv.tokenize(profile.providerHints[HintKey.acpAgentArgs.rawValue] ?? "")
            .filter { !$0.isEmpty }
        let cwd = profile.scratchDirectory?.path
        let apiKey = profile.providerHints[HintKey.acpAgentApiKey.rawValue]
        var environment: [String: String] = [:]
        for (key, value) in profile.providerHints {
            if let envKey = HintKey.envKey(from: key) {
                environment[envKey] = value
            }
        }
        return AgentSpawnConfig(
            executablePath: path, arguments: args, workingDirectory: cwd, apiKey: apiKey,
            environment: environment)
    }

    /// Builds the environment dict for the agent subprocess. Exports `WIKI_DB`,
    /// `WIKICTL`, and prepends the wikictl directory to `PATH`. `WIKI_ROOT` is
    /// intentionally NOT exported — the mount is optional; wikictl is the primary
    /// read surface (issue #441). The task-prompt path (`WikiOperation.wikiRootLine`)
    /// still gives the agent the resolved mount path inline when available.
    /// Extracted from `start()` so it is unit-testable without a subprocess.
    static func buildAgentEnv(
        from cli: CLIProfile,
        baseEnv: [String: String],
        spawnEnvironment: [String: String]
    ) -> [String: String] {
        var env = baseEnv
        env["WIKI_DB"] = cli.wikiID
        // WIKI_ROOT is intentionally NOT exported — mount is optional; wikictl is the primary read surface (#441).
        env["WIKICTL"] = cli.wikictlDirectory + "/wikictl"
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = cli.wikictlDirectory + ":" + existingPath
        for (key, value) in spawnEnvironment {
            env[key] = value
        }
        return env
    }

    /// Writes the system prompt to the agent's working directory as both
    /// `CLAUDE.md` and `AGENTS.md` — the spec-compliant delivery mechanism.
    ///
    /// ACP's `NewSessionRequest` has no `systemPrompt` field; the spec models
    /// system context as a `CLAUDE.md` in the cwd (the same path the File
    /// Provider projection uses at the wiki root, but the projection is
    /// optional for unsigned dev builds). Both filenames are written because
    /// the maintainability schema (`plans/llm-wiki.md` Phase D) projects both;
    /// reading from either works.
    ///
    /// No-op when `systemPrompt` is empty (preserves the caller-relying-on-
    /// projection-alone behavior). Internal so it is directly unit-testable
    /// from `@testable import WikiFSEngine` without spawning a subprocess.
    static func deliverSystemPrompt(_ systemPrompt: String, to workingDir: String) {
        guard !systemPrompt.isEmpty else { return }
        let dirURL = URL(fileURLWithPath: workingDir)
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let url = dirURL.appendingPathComponent(filename)
            do {
                try systemPrompt.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DebugLog.agent("ACPBackend.deliverSystemPrompt: failed to write \(filename) to scratch dir: \(error.localizedDescription)")
            }
        }
    }

    /// Injects the system prompt into the first user message text — agent-agnostic
    /// delivery (issue #427). Unlike the file writes (`deliverSystemPrompt`),
    /// which require the agent to read `CLAUDE.md`/`AGENTS.md` from cwd (Claude
    /// Code does; OpenCode, Hermes, Pi may not), every ACP agent processes the
    /// `session/prompt` user text, so this is deterministic.
    ///
    /// The system prompt is prepended with a clear delimiter so the agent can
    /// distinguish the steering from the actual user request. Internal so it is
    /// directly unit-testable.
    static func injectSystemPrompt(_ systemPrompt: String, into userText: String) -> String {
        guard !systemPrompt.isEmpty else { return userText }
        return """
        \(systemPrompt)

        ---
        # YOUR TASK
        \(userText)
        """
    }

    /// The events synthesized at `session/prompt` completion (the ACP turn
    /// boundary). ACP has NO turn-end *notification*; the turn ends when the
    /// prompt REQUEST returns. On success → just `.messageStop` (the port's
    /// turn-boundary contract). On error → a `.raw` line carrying the message
    /// THEN `.messageStop` so the consumer's for-await still exits and the
    /// launcher's generation gate releases. PURE + unit-tested directly
    /// (`ACPBackendTests.turnEndSynthesis*`) — the spike left this untested.
    static func turnEndEvents(error: Error?) -> [AgentEvent] {
        guard let error else { return [.messageStop] }
        let reason: TurnFailureReason
        if let acpError = error as? ACPBackendError {
            switch acpError {
            case .turnStalled(let idle):
                reason = .stalled(idleSeconds: idle)
            case .turnCeilingExceeded(let total):
                reason = .ceilingExceeded(totalSeconds: total)
            case .processDied:
                reason = .agentError(error.localizedDescription)
            default:
                reason = .agentError(error.localizedDescription)
            }
        } else {
            reason = .agentError(error.localizedDescription)
        }
        return [.turnFailed(reason: reason), .messageStop]
    }

    /// Decode a `session/update` notification's `params` (`AnyCodable`) into a
    /// `SessionUpdateNotification` scoped to `sessionId`, then translate via the
    /// pure translator. Tolerant: a decode failure yields a `.raw` event rather
    /// than throwing (a malformed update must never crash a turn — same
    /// invariant as `AgentEventParser`).
    ///
    /// Phase 4: also extracts the `UsageUpdate` (if the notification is a
    /// `usage_update`) so the backend can capture context window + cost data.
    /// The translator still returns `[]` for `.usageUpdate` (no AgentEvent —
    /// the data is consumed internally, not displayed in the transcript).
    private static func translateNotification(
        params: AnyCodable,
        sessionId: SessionId,
        translator: ACPEventTranslator
    ) -> (events: [AgentEvent], usageUpdate: UsageUpdate?) {
        do {
            let data = try JSONEncoder().encode(params)
            let envelope = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)
            // Scope to our session (the shared notification stream is global).
            guard envelope.sessionId.value == sessionId.value else { return ([], nil) }
            let events = translator.translate(envelope.update)
            // Phase 4: extract the UsageUpdate for context/cost monitoring.
            let usageUpdate = envelope.update.usage
            return (events, usageUpdate)
        } catch {
            return ([.raw("ACP session/update decode error: \(error.localizedDescription)")], nil)
        }
    }
}

// MARK: - Session usage tracking (Phase 4)

/// Cumulative token usage and cost for a session. This is the data surface for
/// #528 (budget-aware ingestion) — the orchestrator reads it after each phase
/// to enforce spend/token caps. Both the streamed `UsageUpdate` (context
/// window size + used + per-turn cost) and the final `Usage` (per-turn token
/// totals from `SessionPromptResponse.usage`) are captured and merged here.
///
/// Created in `createSession()` / `registerResumedSession()` — one per
/// `SessionHandle`. The thread-safe `SessionUsageState` (internal) is the
/// live accumulator; this snapshot struct is what callers read.
public struct SessionUsage: Sendable {
    /// Cumulative input tokens across all turns (from `Usage.inputTokens`).
    public let inputTokens: Int
    /// Cumulative output tokens across all turns (from `Usage.outputTokens`).
    public let outputTokens: Int
    /// Cumulative total tokens (from `Usage.totalTokens`).
    public let totalTokens: Int
    /// Cumulative cached-read tokens (from `Usage.cachedReadTokens`), if reported.
    public let cachedReadTokens: Int?
    /// Cumulative thought/reasoning tokens (from `Usage.thoughtTokens`), if reported.
    public let thoughtTokens: Int?
    /// The last reported cost amount (from `UsageUpdate.cost.amount`), if any.
    public let cost: Double?
    /// The cost currency (e.g. "USD"), if cost was reported.
    public let currency: String?
    /// Tokens used in the context window (from `UsageUpdate.used`).
    public let contextUsed: Int
    /// Total context window size (from `UsageUpdate.size`).
    public let contextSize: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cachedReadTokens: Int?,
        thoughtTokens: Int?,
        cost: Double?,
        currency: String?,
        contextUsed: Int,
        contextSize: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedReadTokens = cachedReadTokens
        self.thoughtTokens = thoughtTokens
        self.cost = cost
        self.currency = currency
        self.contextUsed = contextUsed
        self.contextSize = contextSize
    }
}

/// Thread-safe accumulator for per-session usage data. Captured in the
/// `ACPBackend.send()` continuation closure alongside `TurnCompletionFlag` and
/// `ProcessHealthFlag` — the off-actor drain Task + prompt Task write to it,
/// and the actor reads it via `sessionUsage(for:)` / `contextUsage(for:)` after
/// the turn stream finishes.
///
/// `@unchecked Sendable` with an internal lock — same pattern as
/// `TurnCompletionFlag` and `ProcessHealthFlag`.
private final class SessionUsageState: @unchecked Sendable {
    private let lock = NSLock()

    // Cumulative per-turn token totals (from SessionPromptResponse.usage)
    private var _cumulativeInputTokens = 0
    private var _cumulativeOutputTokens = 0
    private var _cumulativeTotalTokens = 0
    private var _cumulativeCachedReadTokens = 0
    private var _cumulativeThoughtTokens = 0

    // Last streamed usage_update (context window + cost)
    private var _lastContextUsed = 0
    private var _lastContextSize = 0
    private var _lastCost: Double?
    private var _lastCurrency: String?

    // Phase 4 context monitoring thresholds
    private var _contextCritical = false  // >= 80%

    /// Capture a streamed `UsageUpdate` (context window + cost). Called from
    /// the notification drain Task.
    func captureUsageUpdate(
        used: Int,
        size: Int,
        cost: Double?,
        currency: String?
    ) {
        lock.lock()
        _lastContextUsed = used
        _lastContextSize = size
        _lastCost = cost
        _lastCurrency = currency
        // Check context monitoring thresholds
        if size > 0 {
            let ratio = Double(used) / Double(size)
            if ratio >= 0.64 && ratio < 0.80 {
                DebugLog.agent("ACPBackend: context window at \(Int(ratio * 100))% — proactive artifact write recommended")
            } else if ratio >= 0.80 {
                DebugLog.agent("ACPBackend: context window at \(Int(ratio * 100))% — cycling session recommended")
                _contextCritical = true
            }
        }
        lock.unlock()
    }

    /// Capture per-turn final `Usage` (token totals). Called from the prompt
    /// Task after `sendPrompt` returns.
    func captureTurnUsage(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cachedReadTokens: Int?,
        thoughtTokens: Int?
    ) {
        lock.lock()
        _cumulativeInputTokens += inputTokens
        _cumulativeOutputTokens += outputTokens
        _cumulativeTotalTokens += totalTokens
        if let cached = cachedReadTokens { _cumulativeCachedReadTokens += cached }
        if let thought = thoughtTokens { _cumulativeThoughtTokens += thought }
        lock.unlock()
    }

    /// Read a snapshot of the current cumulative usage. Called from the actor.
    func snapshot() -> SessionUsage {
        lock.lock(); defer { lock.unlock() }
        return SessionUsage(
            inputTokens: _cumulativeInputTokens,
            outputTokens: _cumulativeOutputTokens,
            totalTokens: _cumulativeTotalTokens,
            cachedReadTokens: _cumulativeCachedReadTokens > 0 ? _cumulativeCachedReadTokens : nil,
            thoughtTokens: _cumulativeThoughtTokens > 0 ? _cumulativeThoughtTokens : nil,
            cost: _lastCost,
            currency: _lastCurrency,
            contextUsed: _lastContextUsed,
            contextSize: _lastContextSize
        )
    }

    /// Read the current context window usage ratio. Called from the actor.
    func contextUsage() -> (used: Int, size: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_lastContextUsed, _lastContextSize)
    }

    /// Whether the context window has exceeded 80% — the orchestrator checks
    /// this after each turn to decide whether to close + restart the session.
    var contextCritical: Bool {
        lock.lock(); defer { lock.unlock() }
        return _contextCritical
    }
}

// MARK: - Turn completion flag

/// Mutable flag shared between the prompt task and the watchdog inside a single
/// `ACPBackend.send` turn. Once either marks the turn resolved, the other
/// short-circuits to avoid redundant `cancelSession` calls and confusing log
/// lines. `@unchecked Sendable` with an internal lock — accessed from multiple
/// Tasks inside the `@Sendable` continuation closure.
private final class TurnCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = false

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return _done
    }

    func markDone() {
        lock.lock(); _done = true; lock.unlock()
    }
}

/// Phase 2: process-liveness flag shared between the prompt task and the
/// watchdog. Set when `sendPrompt` throws or `kill(pid, 0)` returns non-zero —
/// the process died silently (issue #338). The backend actor reads this after
/// the turn stream finishes (via `markProcessDeadIfNeeded`) to update
/// `warmProcess.processIsAlive` and enable `resume()`.
/// `@unchecked Sendable` with an internal lock.
private final class ProcessHealthFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _died = false

    var died: Bool {
        lock.lock(); defer { lock.unlock() }
        return _died
    }

    func markDied() {
        lock.lock(); _died = true; lock.unlock()
    }
}

// MARK: - Errors

enum ACPBackendError: Error, LocalizedError {
    case noAgentConfigured
    /// The agent advertised `authMethods` but no API key is configured in Settings.
    case missingAPIKey
    /// `Client.authenticate` returned `success: false` (bad/expired key, etc.).
    case authenticationFailed(String?)
    /// The turn went silent — no `session/update` notification arrived for
    /// `idleSeconds`. The turn was cancelled; the user can retry.
    /// (`plans/acp-stall-recovery.md` §1a.)
    case turnStalled(idleSeconds: TimeInterval)
    /// The turn exceeded the hard ceiling duration — the agent was still
    /// streaming but took too long. The turn was cancelled.
    case turnCeilingExceeded(totalSeconds: TimeInterval)
    /// Phase 2: the agent subprocess died unexpectedly (issue #338 —
    /// `claude-agent-acp` stays alive but sessions break / the pipe closes).
    /// The turn failed because `sendPrompt` threw. The caller can attempt
    /// `resume()` to recover.
    case processDied

    var errorDescription: String? {
        switch self {
        case .noAgentConfigured:
            return """
            ACPBackend requires an agent path. Set BackendProfile.providerHints\
            ["\(HintKey.acpAgentPath.rawValue)"] (or `model`) to an ACP agent executable, \
            e.g. /path/to/claude-agent-acp.
            """
        case .missingAPIKey:
            return """
            The ACP agent requires authentication but no API key is configured. \
            Add one in Settings → Agent → ACP Agent.
            """
        case .authenticationFailed(let detail):
            let suffix = detail.map { " (\($0))" } ?? ""
            return "ACP agent authentication failed.\(suffix)"
        case .turnStalled(let idle):
            return """
            ACP agent stalled — no activity for \(Int(idle))s. \
            The turn was cancelled; try sending again.
            """
        case .turnCeilingExceeded(let total):
            return """
            ACP agent exceeded the maximum turn duration (\(Int(total))s). \
            The turn was cancelled; try sending again.
            """
        case .processDied:
            return """
            ACP agent subprocess died unexpectedly. The turn was cancelled; \
            session resume is available if the agent supports it.
            """
        }
    }
}
