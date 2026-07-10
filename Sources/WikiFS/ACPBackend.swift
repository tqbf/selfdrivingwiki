import Foundation
import ACP
import ACPModel
import WikiFSCore

/// The ACP (Agent Client Protocol) backend — a second `AgentBackend` conformer
/// (alongside `ClaudeCLIBackend`) per `plans/acp-backend-and-permissions.md`.
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
/// `.messageStop`), mirroring how `ClaudeCLIBackend` keys turn end off the
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
///   sends `session/cancel`, mirroring `ClaudeCLIBackend`'s PID-kill path.
/// - `.unbounded` buffering — the `@MainActor` consumer drains promptly and
///   tokens must never be dropped (same invariant as the CLI backend).
///
/// **Spike scope:** not wired into the launcher/UI yet (a later slice). No
/// live-agent end-to-end testing; the translator + permission policy are
/// unit-tested with no subprocess.
actor ACPBackend: AgentBackend {

    /// How the configured ACP agent subprocess is spawned. Pluggable (NOT locked
    /// to the Zed adapter) — the user points at any ACP agent via the dedicated
    /// `ACPAgentConfig`. Resolved from `BackendProfile` (`providerHints`/`model`)
    /// so the path + the auth key stay backend-internal concerns, matching how
    /// `ClaudeCLIBackend` reads its `CLIProfile`.
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

        init(
            executablePath: String,
            arguments: [String] = [],
            workingDirectory: String? = nil,
            apiKey: String? = nil
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.apiKey = apiKey
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
    }

    private var sessions: [String: ACPSession] = [:]

    /// The injected permission policy (yolo vs alwaysAsk). Defaults to `yolo`
    /// — the safe default per the design doc's caveat (always-ask enforcement
    /// depends on the agent emitting `request_permission`, which not all do).
    private let permissionPolicy: PermissionPolicy

    /// The client capabilities advertised at `initialize`. fs read/write +
    /// terminal (the structural second gate from the design doc).
    private let capabilities: ClientCapabilities

    init(
        permissionPolicy: PermissionPolicy = .yolo,
        capabilities: ClientCapabilities = ACPBackend.defaultCapabilities
    ) {
        self.permissionPolicy = permissionPolicy
        self.capabilities = capabilities
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

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        DebugLog.agent("ACPBackend.start: enter providerHints=\(profile.providerHints)")
        guard let spawn = Self.resolveSpawnConfig(from: profile) else {
            DebugLog.agent("ACPBackend.start: FAIL noAgentConfigured (no acpAgentPath/model in profile)")
            throw ACPBackendError.noAgentConfigured
        }

        let client = Client()
        // The permission delegate owns the always-ask/yolo policy. It is the
        // `ClientDelegate` that the agent's `session/request_permission` lands on.
        let permissionDelegate = ACPPermissionDelegate(policy: permissionPolicy)
        await client.setDelegate(permissionDelegate)

        DebugLog.agent("ACPBackend.start: launching \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))")
        try await client.launch(
            agentPath: spawn.executablePath,
            arguments: spawn.arguments,
            workingDirectory: spawn.workingDirectory
        )

        DebugLog.agent("ACPBackend.start: process launched, sending initialize")
        // Slice 3: initialize, then authenticate if the agent advertises
        // authMethods. The DECISION is a pure helper (`ACPAuthResolver.resolve`)
        // so it's unit-tested directly; here we just execute it. A key is never
        // logged.
        let initResponse = try await client.initialize(
            protocolVersion: 1,
            capabilities: capabilities,
            clientInfo: ClientInfo(name: "SelfDrivingWiki", title: "Self Driving Wiki", version: "1.0.0")
        )
        DebugLog.agent("ACPBackend.start: initialize OK agent=\(initResponse.agentInfo?.name ?? "?") authMethods=\(initResponse.authMethods?.count ?? 0)")

        switch ACPAuthResolver.resolve(authMethods: initResponse.authMethods, apiKey: spawn.apiKey) {
        case .skip:
            // Agent needs no auth — proceed straight to newSession.
            DebugLog.agent("ACPBackend.start: agent advertised no authMethods, skipping authenticate")
        case .authenticate(let methodId, let credentials):
            DebugLog.agent("ACPBackend.start: authenticating method=\(methodId)")
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
            DebugLog.agent("ACPBackend.start: no API key configured — skipping client auth (agent may self-authenticate)")
        }

        let workingDir = profile.scratchDirectory?.path ?? spawn.workingDirectory ?? FileManager.default.currentDirectoryPath
        DebugLog.agent("ACPBackend.start: newSession cwd=\(workingDir)")
        let session = try await client.newSession(workingDirectory: workingDir)
        let sessionId = session.sessionId
        let modelsInfo = session.models
        let discoveredCount = modelsInfo?.availableModels.count ?? 0
        let currentModel = modelsInfo?.currentModelId ?? "(none)"
        DebugLog.agent("ACPBackend.start: discovered \(discoveredCount) model(s), current=\(currentModel)")

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
                DebugLog.agent("ACPBackend.start: setModel \(id)")
                do {
                    _ = try await client.setModel(sessionId: sessionId, modelId: id)
                } catch {
                    // setModel failed — log and proceed to the prompt anyway; the
                    // agent's default may still work, and a clearer error will
                    // surface from the prompt if not. Non-fatal by design.
                    DebugLog.agent("ACPBackend.start: setModel \(id) failed: \(error.localizedDescription)")
                }
            } else {
                DebugLog.agent("ACPBackend.start: keeping agent default model (selected=\(selectedModelId) → \(decision))")
            }
        }

        let sessionID = UUID().uuidString
        sessions[sessionID] = ACPSession(
            client: client,
            sessionId: sessionId,
            permissionDelegate: permissionDelegate,
            modelsInfo: modelsInfo
        )

        // Wire onExit to the agent process termination. `Client.terminate()` is
        // the teardown; there's no direct terminationHandler on the SDK actor,
        // so we rely on `cancel`/`terminate` to fire onExit. (The launcher's
        // watchdog reconciles against this single completion channel.)
        permissionDelegate.bindOnExit(onExit)

        DebugLog.agent("ACPBackend.start: session \(sessionId.value) (handle \(sessionID)) ready")
        return SessionHandle(id: sessionID)
    }

    func send(_ turn: TurnInput, into handle: SessionHandle) async -> AsyncStream<AgentEvent> {
        guard let session = sessions[handle.id] else {
            // Session gone (cancelled/finished) — return an empty, finished stream.
            DebugLog.agent("ACPBackend.send: no session for handle \(handle.id) — empty stream")
            return AsyncStream { $0.finish() }
        }
        DebugLog.agent("ACPBackend.send: turn=\"\(turn.userText.prefix(80))\" handle=\(handle.id)")

        let client = session.client
        let sessionId = session.sessionId
        let translator = ACPEventTranslator()

        // `.unbounded` buffering — the @MainActor consumer drains promptly and
        // no events may be dropped (same invariant as the CLI backend).
        return AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            // The prompt task. It runs concurrently with the notification drain:
            // `sendPrompt` BLOCKS until the whole turn completes (returns
            // SessionPromptResponse with stopReason), while notifications stream
            // in during that time. We capture the handle so cancellation can
            // tear it down.
            let promptTask = Task { [client, sessionId] in
                // Drain notifications for THIS session while the prompt runs.
                // `client.notifications` is an actor-isolated computed property
                // on the `Client` actor (backed by a stored `AsyncStream`), so
                // we `await` it once to obtain the stream, then iterate. (A
                // future multi-session fan-out would need a per-session split —
                // out of scope for this single-session backend.)
                let notifications = await client.notifications
                let drainTask = Task {
                    for await notification in notifications {
                        if Task.isCancelled { return }
                        guard notification.method == "session/update" else { continue }
                        guard let params = notification.params else { continue }
                        // Decode params → SessionUpdateNotification, then translate.
                        let events = ACPBackend.translateNotification(params: params, sessionId: sessionId, translator: translator)
                        DebugLog.agent("ACPBackend: session/update → \(events.count) AgentEvent(s)")
                        for event in events {
                            continuation.yield(event)
                        }
                    }
                }
                defer { drainTask.cancel() }

                do {
                    DebugLog.agent("ACPBackend: sending session/prompt (\(turn.userText.count) chars)")
                    let response = try await client.sendPrompt(
                        sessionId: sessionId,
                        content: [.text(TextContent(text: turn.userText))]
                    )
                    DebugLog.agent("ACPBackend: prompt completed stopReason=\(response.stopReason.rawValue)")
                    // ACP has no explicit turn-end notification; the turn ends
                    // when the prompt REQUEST returns. Synthesize the turn-end
                    // events (always ending in `.messageStop`) to satisfy the
                    // port's turn-boundary contract. The pure helper is
                    // unit-tested directly — see `ACPBackendTests`.
                    for event in Self.turnEndEvents(error: nil) {
                        continuation.yield(event)
                    }
                } catch {
                    DebugLog.agent("ACPBackend: prompt failed: \(error.localizedDescription)")
                    // Error is also a turn boundary — synthesize `.messageStop`
                    // so the consumer's for-await exits and the gate releases.
                    for event in Self.turnEndEvents(error: error) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }

            // Cancellation bridge: if the consumer cancels the for-await loop
            // (stopAgent), cancel the prompt task and send session/cancel.
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    promptTask.cancel()
                    Task { [client, sessionId] in
                        try? await client.cancelSession(sessionId: sessionId)
                    }
                }
                // .finished: natural turn end, nothing to do.
            }
        }
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        // Phase 0 does NOT implement resume — matches the port's default. ACP
        // *can* resume via session/load, but that's a later slice.
        return nil
    }

    func cancel(_ session: SessionHandle) async {
        guard let record = sessions.removeValue(forKey: session.id) else { return }
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
        return await session.permissionDelegate.resolve(optionId: optionId)
    }

    /// The currently-pending permission requests for a session (always-ask
    /// mode). The future UI surfaces these as Approve/Reject affordances.
    func pendingPermissions(sessionHandle: SessionHandle) async -> [PendingPermission] {
        guard let session = sessions[sessionHandle.id] else { return [] }
        return await session.permissionDelegate.pendingSnapshot()
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
    /// `providerHints["acpAgentApiKey"]`. The args string is tokenized with the
    /// SAME shell-aware whitespace tokenizer the rest of the app uses for
    /// `AgentCommandConfig.prefixArguments`.
    ///
    /// Slice 3: these hints are now sourced from the dedicated `ACPAgentConfig`
    /// (NOT the generic `AgentCommandConfig`) by `AgentBackendFactory`, and the
    /// key is the Keychain-backed secret. NOT hardcoded to the Zed adapter — the
    /// user points at any ACP agent. Returns nil if no path is configured
    /// (→ `noAgentConfigured`).
    private static func resolveSpawnConfig(from profile: BackendProfile) -> AgentSpawnConfig? {
        let path = profile.providerHints["acpAgentPath"] ?? profile.model
        guard let path, !path.isEmpty else { return nil }
        let args = AgentCommandConfig.tokenize(profile.providerHints["acpAgentArgs"] ?? "")
            .filter { !$0.isEmpty }
        let cwd = profile.scratchDirectory?.path
        let apiKey = profile.providerHints["acpAgentApiKey"]
        return AgentSpawnConfig(
            executablePath: path, arguments: args, workingDirectory: cwd, apiKey: apiKey)
    }

    /// The events synthesized at `session/prompt` completion (the ACP turn
    /// boundary). ACP has NO turn-end *notification*; the turn ends when the
    /// prompt REQUEST returns. On success → just `.messageStop` (the port's
    /// turn-boundary contract). On error → a `.raw` line carrying the message
    /// THEN `.messageStop` so the consumer's for-await still exits and the
    /// launcher's generation gate releases. PURE + unit-tested directly
    /// (`ACPBackendTests.turnEndSynthesis*`) — the spike left this untested.
    static func turnEndEvents(error: Error?) -> [AgentEvent] {
        if let error {
            return [.raw("ACP agent error: \(error.localizedDescription)"), .messageStop]
        }
        return [.messageStop]
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
            return translator.translate(envelope.update)
        } catch {
            return [.raw("ACP session/update decode error: \(error.localizedDescription)")]
        }
    }
}

// MARK: - Errors

enum ACPBackendError: Error, LocalizedError {
    case noAgentConfigured
    /// The agent advertised `authMethods` but no API key is configured in Settings.
    case missingAPIKey
    /// `Client.authenticate` returned `success: false` (bad/expired key, etc.).
    case authenticationFailed(String?)

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
        }
    }
}
