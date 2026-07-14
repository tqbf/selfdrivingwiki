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
        /// `WIKI_DB`/`WIKI_ROOT`/`WIKICTL`/`PATH` vars `start()` sets from
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

    init(
        permissionPolicy: PermissionPolicy = .bypass,
        capabilities: ClientCapabilities = ACPBackend.defaultCapabilities,
        turnIdleTimeout: TimeInterval = TurnLivenessPolicy.defaultIdleTimeout,
        turnCeilingTimeout: TimeInterval = TurnLivenessPolicy.defaultCeilingTimeout,
        watchdogPollInterval: TimeInterval = TurnLivenessPolicy.defaultPollInterval
    ) {
        self.permissionPolicy = permissionPolicy
        self.capabilities = capabilities
        self.turnIdleTimeout = turnIdleTimeout
        self.turnCeilingTimeout = turnCeilingTimeout
        self.watchdogPollInterval = watchdogPollInterval
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
        guard let spawn = Self.resolveSpawnConfig(from: profile) else {
            DebugLog.agent("ACPBackend.start: FAIL noAgentConfigured (no acpAgentPath/model in profile)") // TEMP DEBUG (existed; re-tagged)
            throw ACPBackendError.noAgentConfigured
        }

        let client = Client()
        // The permission delegate owns the always-ask/yolo policy. It is the
        // `ClientDelegate` that the agent's `session/request_permission` lands on.
        let permissionDelegate = ACPPermissionDelegate(policy: permissionPolicy)
        await client.setDelegate(permissionDelegate)

        DebugLog.agent("ACPBackend.start: launching \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))") // TEMP DEBUG (existed; re-tagged)
        // Build the environment so the agent can find wikictl + the wiki DB.
        // Exports WIKI_DB/WIKI_ROOT/WIKICTL/PATH for the agent's wikictl calls.
        var env = ProcessInfo.processInfo.environment
        if let cli = profile.cli {
            env["WIKI_DB"] = cli.wikiID
            env["WIKI_ROOT"] = cli.wikiRoot
            env["WIKICTL"] = cli.wikictlDirectory + "/wikictl"
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = cli.wikictlDirectory + ":" + existingPath
        }
        // Also add any extra env from the provider config (Phase 2: sourced from
        // `AgentSpawnConfig.environment`, resolved once in `resolveSpawnConfig`
        // rather than re-scanning `providerHints` here).
        for (key, value) in spawn.environment {
            env[key] = value
        }

        try await client.launch(
            agentPath: spawn.executablePath,
            arguments: spawn.arguments,
            workingDirectory: spawn.workingDirectory,
            environment: env
        )

        DebugLog.agent("ACPBackend.start: process launched, sending initialize") // TEMP DEBUG (existed; re-tagged)
        // Slice 3: initialize, then authenticate if the agent advertises
        // authMethods. The DECISION is a pure helper (`ACPAuthResolver.resolve`)
        // so it's unit-tested directly; here we just execute it. A key is never
        // logged.
        let initResponse = try await client.initialize(
            protocolVersion: 1,
            capabilities: capabilities,
            clientInfo: ClientInfo(name: "SelfDrivingWiki", title: "Self Driving Wiki", version: GeneratedVersion.appVersion)
        )
        DebugLog.agent("ACPBackend.start: initialize OK agent=\(initResponse.agentInfo?.name ?? "?") authMethods=\(initResponse.authMethods?.count ?? 0)") // TEMP DEBUG (existed; re-tagged)

        switch ACPAuthResolver.resolve(authMethods: initResponse.authMethods, apiKey: spawn.apiKey) {
        case .skip:
            // Agent needs no auth — proceed straight to newSession.
            DebugLog.agent("ACPBackend.start: agent advertised no authMethods, skipping authenticate") // TEMP DEBUG (existed; re-tagged)
        case .authenticate(let methodId, let credentials):
            DebugLog.agent("ACPBackend.start: authenticating method=\(methodId)") // TEMP DEBUG (existed; re-tagged)
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
            DebugLog.agent("ACPBackend.start: no API key configured — skipping client auth (agent may self-authenticate)") // TEMP DEBUG (existed; re-tagged)
        }

        let workingDir = profile.scratchDirectory?.path ?? spawn.workingDirectory ?? FileManager.default.currentDirectoryPath
        // Deliver the system prompt via the spec-compliant on-disk mechanism
        // (issue #427). ACP's NewSessionRequest has no systemPrompt field — the
        // spec models system context as CLAUDE.md/AGENTS.md in the cwd. The File
        // Provider projection is the production default but is OPTIONAL for
        // unsigned dev builds; this makes delivery reliable regardless. Both
        // files match the projection (same `currentSystemPromptBody()` source).
        Self.deliverSystemPrompt(systemPrompt, to: workingDir)
        DebugLog.agent("ACPBackend.start: newSession cwd=\(workingDir)") // TEMP DEBUG (existed; re-tagged)
        let session = try await client.newSession(workingDirectory: workingDir)
        let sessionId = session.sessionId
        let modelsInfo = session.models
        let discoveredCount = modelsInfo?.availableModels.count ?? 0
        let currentModel = modelsInfo?.currentModelId ?? "(none)"
        DebugLog.agent("ACPBackend.start: discovered \(discoveredCount) model(s), current=\(currentModel)") // TEMP DEBUG (existed; re-tagged)

        // #329: if the user picked a model for this provider, apply it right
        // after newSession — BEFORE the first prompt — so the agent uses a
        // valid model instead of its (possibly broken) default. The selection
        // is threaded in via providerHints by the launcher. The DECISION is a
        // pure helper (`ACPModelSelectionResolver.resolve`) so it's unit-tested
        // without a subprocess; here we just execute it. A bad/stale selection
        // falls back to the agent default (no setModel) — never reproduces the
        // 404 the picker exists to prevent.
        if let selectedModelId = profile.providerHints["acpSelectedModelId"],
           !selectedModelId.isEmpty {
            let advertisedIds = modelsInfo?.availableModels.map(\.modelId) ?? []
            let decision = ACPModelSelectionResolver.resolve(
                selectedModelId: selectedModelId,
                currentModelId: modelsInfo?.currentModelId,
                advertisedModelIds: advertisedIds)
            if case .apply(let id) = decision {
                DebugLog.agent("ACPBackend.start: setModel \(id)") // TEMP DEBUG (existed; re-tagged)
                do {
                    _ = try await client.setModel(sessionId: sessionId, modelId: id)
                } catch {
                    // setModel failed — log and proceed to the prompt anyway; the
                    // agent's default may still work, and a clearer error will
                    // surface from the prompt if not. Non-fatal by design.
                    DebugLog.agent("ACPBackend.start: setModel \(id) failed: \(error.localizedDescription)") // TEMP DEBUG (existed; re-tagged)
                }
            } else {
                DebugLog.agent("ACPBackend.start: keeping agent default model (selected=\(selectedModelId) → \(decision))") // TEMP DEBUG (existed; re-tagged)
            }
        }

        // Capture the CLI profile's log callbacks so ACP stderr and notifications
        // flow into run.stderr.log / run.jsonl (same hooks the old CLI backend used
        // via onStdoutChunk/onStderrChunk). Without this the log files stay empty
        // and "Reveal Log" opens a blank file.
        let onStdoutChunk = profile.cli?.onStdoutChunk
        let onStderrChunk = profile.cli?.onStderrChunk

        // Session-lifetime notification drain (cause 6 fix,
        // `plans/acp-stall-recovery.md` §1b). Acquire `client.notifications`
        // ONCE here and fan events into a per-session `NotificationFanout`.
        // Each turn subscribes to the fanout instead of re-acquiring the SDK
        // stream (AsyncStream is single-consumer — two concurrent iterators
        // split elements, silently dropping notifications).
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
        DebugLog.agent("ACPBackend.start: session-lifetime notification drain started") // TEMP DEBUG (existed; re-tagged)

        // Forward agent stderr to DebugLog.agent + run.stderr.log (via the CLI
        // profile's onStderrChunk callback). Best-effort: the stream finishes
        // on terminate, so this task exits naturally.
        Task { [client, onStderrChunk] in
            guard let stderrStream = await client.stderrLines() else { return }
            for await line in stderrStream {
                if Task.isCancelled { break }
                DebugLog.agent("ACP stderr: \(line)")
                onStderrChunk?(line + "\n")
            }
        }

        let sessionID = UUID().uuidString
        sessions[sessionID] = ACPSession(
            client: client,
            sessionId: sessionId,
            permissionDelegate: permissionDelegate,
            modelsInfo: modelsInfo,
            notificationFanout: fanout,
            drainTask: drainTask,
            systemPrompt: systemPrompt,
            systemPromptInjected: false
        )

        // Wire onExit to the agent process termination. `Client.terminate()` is
        // the teardown; there's no direct terminationHandler on the SDK actor,
        // so we rely on `cancel`/`terminate` to fire onExit. (The launcher's
        // watchdog reconciles against this single completion channel.)
        permissionDelegate.bindOnExit(onExit)

        DebugLog.agent("ACPBackend.start: session \(sessionId.value) (handle \(sessionID)) ready") // TEMP DEBUG (existed; re-tagged)
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

        // `.unbounded` buffering — the @MainActor consumer drains promptly and
        // no events may be dropped (same invariant as the CLI backend).
        return AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            // Shared flag: once either the prompt task or the watchdog resolves
            // the turn, the other short-circuits (yield/finish to an already-
            // finished continuation are safe no-ops, but this avoids redundant
            // cancelSession calls and confusing duplicate log lines).
            let completionFlag = TurnCompletionFlag()
            let turnStartedAt = fanout.activityTimestamp

            // --- Watchdog task (cause 5 fix, plans/acp-stall-recovery.md §1a) ---
            // Polls every `pollInterval`; if the prompt hasn't completed AND no
            // notification has arrived for `idleTimeout`, or the total duration
            // exceeds `ceilingTimeout`, fail the turn: cancelSession best-effort,
            // synthesize turn-end events, finish the continuation.
            let watchdogTask = Task { [client, sessionId, fanout, completionFlag] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(pollInterval))
                    if Task.isCancelled { return }
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
            let promptTask = Task { [client, sessionId, fanout, completionFlag, promptText] in
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
                        let events = ACPBackend.translateNotification(params: params, sessionId: sessionId, translator: translator)
                        DebugLog.agent("ACPBackend: session/update → \(events.count) AgentEvent(s)") // TEMP DEBUG (existed; re-tagged)
                        for event in events {
                            continuation.yield(event)
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

    public func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        // Phase 0 does NOT implement resume — matches the port's default. ACP
        // *can* resume via session/load, but that's a later slice.
        return nil
    }

    public func cancel(_ session: SessionHandle) async {
        guard let record = sessions.removeValue(forKey: session.id) else {
            DebugLog.agent("ACPBackend.cancel: no session for handle \(session.id) — no-op") // TEMP DEBUG
            return
        }
        DebugLog.agent("ACPBackend.cancel: cancelling session=\(record.sessionId.value) handle=\(session.id)") // TEMP DEBUG
        // Tear down the session-lifetime notification drain (cause 6 fix) BEFORE
        // terminating — so no notifications arrive after the fanout is finished.
        record.drainTask?.cancel()
        record.notificationFanout.finish()
        // Drain any in-flight always-ask continuations BEFORE tearing down, so a
        // pending `request_permission` never leaks its `CheckedContinuation`
        // (leaked continuations warn/trap at task end). The agent receives a
        // `cancelled` outcome for each, which it treats as denied.
        record.permissionDelegate.cancelAllPending()
        // Cancel any in-flight prompt, then terminate the agent subprocess.
        // `terminate()` resumes pending requests with an error and finishes the
        // notification stream. The permission delegate's onExit binding fires.
        try? await record.client.cancelSession(sessionId: record.sessionId)
        await record.client.terminate()
        record.permissionDelegate.fireOnExit(status: 0)
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
        let path = profile.providerHints["acpAgentPath"] ?? profile.model
        guard let path, !path.isEmpty else { return nil }
        let args = ShellArgv.tokenize(profile.providerHints["acpAgentArgs"] ?? "")
            .filter { !$0.isEmpty }
        let cwd = profile.scratchDirectory?.path
        let apiKey = profile.providerHints["acpAgentApiKey"]
        var environment: [String: String] = [:]
        for (key, value) in profile.providerHints where key.hasPrefix("env.") {
            environment[String(key.dropFirst(4))] = value
        }
        return AgentSpawnConfig(
            executablePath: path, arguments: args, workingDirectory: cwd, apiKey: apiKey,
            environment: environment)
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
    private static func translateNotification(
        params: AnyCodable,
        sessionId: SessionId,
        translator: ACPEventTranslator
    ) -> [AgentEvent] {
        do {
            let data = try JSONEncoder().encode(params)
            let envelope = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)
            // Scope to our session (the shared notification stream is global).
            guard envelope.sessionId.value == sessionId.value else { return [] }
            let events = translator.translate(envelope.update)
            return events
        } catch {
            return [.raw("ACP session/update decode error: \(error.localizedDescription)")]
        }
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

    var errorDescription: String? {
        switch self {
        case .noAgentConfigured:
            return """
            ACPBackend requires an agent path. Set BackendProfile.providerHints\
            ["acpAgentPath"] (or `model`) to an ACP agent executable, \
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
        }
    }
}
