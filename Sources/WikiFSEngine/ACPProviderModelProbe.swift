import Foundation
import ACPModel
import ACP
import WikiFSCore

/// A throwaway ACP probe that discovers the models an agent advertises,
/// WITHOUT a chat/ingest session. Mirrors Paseo's
/// `ACPAgentClient.fetchCatalog`
/// (`packages/server/src/server/agent/providers/acp-agent.ts:840-886`):
///
/// 1. spawn a fresh subprocess via the SDK `Client`,
/// 2. `initialize` + (conditionally) `authenticate`,
/// 3. open a one-shot `session/new` with `mcpServers: []`,
/// 4. read `availableModels` + `currentModelId`,
/// 5. **terminate the subprocess unconditionally** — Paseo parity
///    (`closeProbe` in `finally`, `acp-agent.ts:881-885`).
///
/// This breaks the `SpawnModelGuard` deadlock from issue #640: the user can
/// now discover + select a model from Settings → Agents → Edit → Refresh
/// Models, WITHOUT first starting a chat (which the guard refuses until a
/// model is picked).
///
/// **Concurrency.** The probe is a `struct` (value type), `Sendable`, holding
/// only `Sendable` config. `discoverModels` is `nonisolated async` — the
/// subprocess spawn + all SDK I/O run OFF the main actor. The Settings call
/// site crosses back to `@MainActor` to persist via
/// `AgentProvidersConfig.settingCachedModels`. The SDK `Client` is itself the
/// concurrency boundary (a `public actor`); the probe struct just orchestrates
/// it. The teardown (`client.terminate()`) is OUTSIDE the `withTimeout` race
/// so it ALWAYS runs, mirroring Paseo's `finally { closeProbe }` — never inside
/// the racing operation (which would orphan the subprocess on timeout).
///
/// **No `defer` for `terminate`.** Swift `defer` is synchronous and CANNOT
/// contain `await`; the SDK `Client.terminate()` is `async`. The teardown uses
/// an explicit do/catch (house rule — never bare `try?`).
public struct ACPProviderModelProbe: Sendable {

    /// The provider whose agent subprocess the probe spawns. Captured by value
    /// (`AgentProvider` is `Sendable`).
    public let provider: AgentProvider
    /// The PATH-resolved argv for the agent executable (first element MUST
    /// be an absolute path; the rest are args). `AgentBackendFactory.
    /// providerHints` consumes this verbatim as `acpAgentPath`/
    /// `acpAgentArgs`. The swift-acp SDK's `Process.launch()` does NOT do
    /// PATH lookup, so the caller MUST resolve against the login-shell PATH
    /// before constructing the probe (mirror `AgentLauncher.
    /// resolveACPProviderSpawn`). This is NOT the same shape
    /// `ProviderEditorView.save()` stores — `save()` stores the BARE argv
    /// (`AgentProvider.command`) and defers resolution to spawn time
    /// (#640: passing bare here reproduces "file <exe> doesn't exist").
    public let resolvedCommand: [String]
    /// The Keychain-backed API key (nil when none is configured — many agents
    /// self-authenticate, e.g. Claude via OAuth, Hermes via ~/.hermes).
    public let apiKey: String?

    public init(provider: AgentProvider, resolvedCommand: [String], apiKey: String?) {
        self.provider = provider
        self.resolvedCommand = resolvedCommand
        self.apiKey = apiKey
    }

    /// Discover the models the provider's agent advertises, WITHOUT a
    /// chat/ingest session. NONISOLATED async — runs OFF the main actor.
    /// Teardown (`client.terminate()`) is unconditional on every exit path
    /// (success / error / timeout) via do/catch (NEVER `defer { try? await }`,
    /// which is illegal Swift).
    ///
    /// - Parameter timeout: race the probe against `Task.sleep(for: timeout)`;
    ///   whichever finishes first wins. The losing side is cancelled. Default
    ///   60s — matches Paseo's `ACP_CATALOG_TIMEOUT_MS`
    ///   (`acp-agent.ts:256`).
    /// - Returns: the agent's advertised `availableModels` mapped to
    ///   `[CachedModelInfo]`. Empty list → `.noModelsAdvertised`.
    public func discoverModels(timeout: Duration = .seconds(60)) async throws -> [CachedModelInfo] {
        DebugLog.agent("ACPProviderModelProbe.discoverModels: enter provider=\(provider.id) timeout=\(timeout)")

        // Build the spawn profile via the SAME construction ACPBackend uses —
        // `resolveSpawnConfig` handles PATH resolution, env.* hints, and the
        // Keychain key. We pass NO selectedModelId: the probe reads the agent's
        // *advertised* list, not a chosen model.
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: nil)
        guard !hints.isEmpty else {
            // An empty resolved command → no `acpAgentPath` → no spawn possible.
            // Same condition `ACPBackend.startProcess` checks at :331-333.
            DebugLog.agent("ACPProviderModelProbe: FAIL notConfigured provider=\(provider.id)")
            throw ACPProviderModelProbeError.notConfigured
        }
        let profile = BackendProfile(providerHints: hints)
        guard let spawn = ACPBackend.resolveSpawnConfig(from: profile) else {
            DebugLog.agent("ACPProviderModelProbe: FAIL resolveSpawnConfig nil provider=\(provider.id)")
            throw ACPProviderModelProbeError.notConfigured
        }

        // The probe CWD is a throwaway temp dir — the probe must NOT call
        // `ACPBackend.deliverSystemPrompt` (that writes CLAUDE.md/AGENTS.md
        // into the cwd and would let a probe read an unrelated project's
        // context). A temp dir guarantees a clean cwd. Paseo parity: PROBE_ENV.
        let probeCWD = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: probeCWD, withIntermediateDirectories: true)
        } catch {
            DebugLog.agent("ACPProviderModelProbe: FAIL could not create probe CWD: \(error.localizedDescription)")
            throw ACPProviderModelProbeError.launchFailed(error.localizedDescription, stderr: nil, hint: nil)
        }
        // Sweep the probe CWD on every exit path (success / failure / cancel).
        // `defer` is fine here — synchronous file I/O.
        defer { try? FileManager.default.removeItem(at: probeCWD) }

        // Minimal env: process env merged with the provider's spawn env (the
        // `env.`-prefixed hints `resolveSpawnConfig` extracts). NO WIKI_DB /
        // WIKICTL / wikictl-PATH (the probe has no wiki context — same as
        // Paseo's PROBE_ENV, `acp-agent.ts:255`).
        let env = ProcessInfo.processInfo.environment.merging(spawn.environment) { _, new in new }

        // The SDK Client is the concurrency boundary. Local to this call —
        // there is no shared transport (Paseo parity: spawnProcess(PROBE_ENV)).
        let client = Client()

        do {
            let result: [CachedModelInfo] = try await withThrowingTaskGroup(of: [CachedModelInfo].self) { group in
                // The probe work child: launch → initialize → (auth) →
                // newSession → map to CachedModelInfo. Teardown happens
                // OUTSIDE this group (never inside the racing operation).
                group.addTask {
                    try await self.runProbe(
                        on: client,
                        spawn: spawn,
                        probeCWD: probeCWD.path,
                        env: env)
                }
                // The timeout child: wins the race if the probe takes too long.
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ACPProviderModelProbeError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ACPProviderModelProbeError.timedOut
                }
                // Cancel the loser (whichever child didn't finish first).
                group.cancelAll()
                return first
            }
            // SUCCESS path: terminate the subprocess outside the race, then
            // return the discovered list. Paseo's `finally { closeProbe }`
            // parity (acp-agent.ts:881-884).
            await Self.terminateAndLog(client, reason: "success", providerID: provider.id)
            return result
        } catch {
            // ERROR / TIMEOUT path: terminate the subprocess outside the race
            // so it ALWAYS runs even if the work child was cancelled mid-flight
            // (avoids the orphan-on-timeout race — the explicit do/catch is
            // the legal-Swift equivalent of `defer { try? await terminate() }`,
            // which the plan specified but is illegal: `defer` is synchronous).
            await Self.terminateAndLog(client, reason: "error/timeout", providerID: provider.id)
            // Map ACP/SDK errors to the probe error type before rethrowing so
            // the Settings row sees a focused message.
            throw Self.mapProbeError(error)
        }
    }

    /// The racing probe operation: launch → initialize → (auth) → newSession →
    /// map to `[CachedModelInfo]`. NEVER tears down the client — the caller's
    /// do/catch does that OUTSIDE the race (mirrors Paseo's
    /// `finally { closeProbe }` at acp-agent.ts:881-884). If this throws, the
    /// outer `withThrowingTaskGroup` cancels the timeout child; if the timeout
    /// wins, the group cancels this child.
    private func runProbe(
        on client: Client,
        spawn: ACPBackend.AgentSpawnConfig,
        probeCWD: String,
        env: [String: String]
    ) async throws -> [CachedModelInfo] {
        // A minimal delegate so the SDK has someone to ask (the probe never
        // sends a prompt, so no permission will actually arrive — but the
        // SDK's `setDelegate` is required before `initialize`). `.bypass`
        // auto-approves anything that does arrive (defensive — a misbehaving
        // agent that fires a permission on session/new should not hang the
        // probe on a 60s timeout).
        let delegate = ACPPermissionDelegate(policy: .bypass)
        await client.setDelegate(delegate)

        DebugLog.agent("ACPProviderModelProbe.runProbe: launching \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))")

        // #733 + #737: buffer stderr during launch/initialize so that a
        // launch-failure (bun starts but claude/codex not on PATH) surfaces
        // the subprocess's stderr + an env-var hint. The stderr stream is
        // single-consumer, so this ONE task both buffers and discards on
        // success.
        let earlyStderrBuffer = EarlyStderrBuffer()
        let initResponse: InitializeResponse
        do {
            try await client.launch(
                agentPath: spawn.executablePath,
                arguments: spawn.arguments,
                workingDirectory: probeCWD,
                environment: env)

            // Start buffering stderr (stream exists post-launch, pre-init).
            let stderrTask = Task { [client] in
                guard let stream = await client.stderrLines() else { return }
                for await line in stream {
                    earlyStderrBuffer.append(line)
                }
            }

            DebugLog.agent("ACPProviderModelProbe.runProbe: process launched, sending initialize")
            initResponse = try await client.initialize(
                protocolVersion: 1,
                capabilities: ACPBackend.defaultCapabilities,
                clientInfo: ClientInfo(
                    name: "SelfDrivingWikiProbe",
                    title: "Self Driving Wiki (model probe)",
                    version: GeneratedVersion.appVersion))
            // Success — discard buffered stderr; the process will be
            // terminated by the caller.
            stderrTask.cancel()
            _ = earlyStderrBuffer.flush()
        } catch {
            DebugLog.agent("ACPProviderModelProbe.runProbe: launch/initialize failed: \(error.localizedDescription)")
            let stderr = earlyStderrBuffer.flush()
            let hint = ACPBackend.launchHint(for: spawn)
            throw ACPProviderModelProbeError.launchFailed(
                error.localizedDescription,
                stderr: stderr,
                hint: hint)
        }
        DebugLog.agent("ACPProviderModelProbe.runProbe: initialize OK agent=\(initResponse.agentInfo?.name ?? "?") authMethods=\(initResponse.authMethods?.count ?? 0)")

        // Auth decision is PURE (ACPAuthResolver.resolve) — mirrors the live
        // path at ACPBackend.swift:382-403. .missingCredentials does NOT block
        // (many agents self-auth); only a REJECTED authenticate is an error.
        switch ACPAuthResolver.resolve(authMethods: initResponse.authMethods, apiKey: spawn.apiKey) {
        case .skip:
            DebugLog.agent("ACPProviderModelProbe.runProbe: skipping authenticate (no authMethods advertised)")
        case .missingCredentials:
            // Agent advertised authMethods but no API key is configured. Do NOT
            // hard-block — proceed to newSession. If the agent truly needs
            // client creds, newSession will surface that error (clearer than
            // blocking at the probe gate). Same behavior as ACPBackend:395-403.
            DebugLog.agent("ACPProviderModelProbe.runProbe: no API key configured — skipping client auth (agent may self-authenticate)")
        case .authenticate(let methodId, let credentials):
            DebugLog.agent("ACPProviderModelProbe.runProbe: authenticating method=\(methodId)")
            do {
                let authResponse = try await client.authenticate(
                    authMethodId: methodId,
                    credentials: credentials)
                guard authResponse.success else {
                    throw ACPProviderModelProbeError.authenticationFailed(authResponse.error)
                }
            } catch let err as ACPProviderModelProbeError {
                throw err
            } catch {
                DebugLog.agent("ACPProviderModelProbe.runProbe: authenticate failed: \(error.localizedDescription)")
                throw ACPProviderModelProbeError.underlying(error)
            }
        }

        // The throwaway probe session — mcpServers: [] (Paseo parity). The
        // agent's advertised model list is piggy-backed on session/new.
        DebugLog.agent("ACPProviderModelProbe.runProbe: newSession cwd=\(probeCWD)")
        let session: NewSessionResponse
        do {
            session = try await client.newSession(workingDirectory: probeCWD)
        } catch {
            DebugLog.agent("ACPProviderModelProbe.runProbe: newSession failed: \(error.localizedDescription)")
            throw ACPProviderModelProbeError.underlying(error)
        }

        let models = Self.mapModelsToCache(session.models, configOptions: session.configOptions)
        DebugLog.agent("ACPProviderModelProbe.runProbe: discovered \(models.count) model(s) for provider=\(provider.id) ids=\(models.map(\.modelId))")
        return models
    }

    // MARK: - PURE helpers (testable without a live Client actor)

    /// PURE. Map the SDK's `ModelsInfo?` (from `session/new`) to the app's
    /// secrets-free `[CachedModelInfo]`. Falls back to scanning
    /// `configOptions` for a `model` select option when `availableModels` is
    /// empty/nil — mirrors Paseo's `deriveModelDefinitionsFromACP` fallback
    /// (`packages/server/src/server/agent/providers/acp-agent.ts:637-680`).
    /// opencode (and possibly other agents) don't populate `availableModels`;
    /// they advertise the model list as a `SessionConfigOption` select with
    /// `category == "model"` (or `id.value == "model"`). Without this
    /// fallback, the probe returns "The provider advertised no models" even
    /// though the models ARE available (#654). Extracted so the mapping is
    /// unit-tested without a subprocess.
    ///
    /// `configOptions` defaults to `nil` so the prior callers (which only
    /// pass `session.models`) keep their existing behavior.
    public static func mapModelsToCache(
        _ models: ModelsInfo?,
        configOptions: [SessionConfigOption]? = nil
    ) -> [CachedModelInfo] {
        // Primary path: the agent advertised `availableModels`. Paseo parity.
        if let models, !models.availableModels.isEmpty {
            return models.availableModels.map {
                CachedModelInfo(modelId: $0.modelId, name: $0.name, description: $0.description)
            }
        }
        // Fallback: derive from the configOptions model selector — the path
        // opencode and other agents take when they don't populate
        // `availableModels`.
        guard let configOptions else { return [] }
        return deriveModelsFromConfigOptions(configOptions)
    }

    /// PURE. Scan `configOptions` for a `model` select option (matched by
    /// `id.value == "model"` OR `category == "model"` — the spec and the
    /// daemon use different conventions, so accept both) and flatten its
    /// choices to `[CachedModelInfo]`. Mirrors Paseo's
    /// `deriveSelectorOptions(configOptions, "model")`. Returns `[]` when no
    /// such option exists or it isn't a `.select`.
    private static func deriveModelsFromConfigOptions(
        _ configOptions: [SessionConfigOption]
    ) -> [CachedModelInfo] {
        guard let option = configOptions.first(where: { isModelSelector($0) }),
              case .select(let select) = option.kind else {
            return []
        }
        return flattenSelectOptions(select.options).map { choice in
            // `choice.value` is `SessionConfigValueId` (a wrapped String) —
            // `.value` is the model id sent to `session/set_model`. Matches
            // the same unwrapping in `ThinkingEffortOption.flatChoices`.
            CachedModelInfo(
                modelId: choice.value.value,
                name: choice.name,
                description: choice.description)
        }
    }

    /// Match heuristic: a model selector by id (opencode advertises
    /// `id.value == "model"`) or by category (other agents use
    /// `category == "model"`). Same dual-convention approach as
    /// `ThinkingEffortOption.isThoughtLevel`.
    private static func isModelSelector(_ option: SessionConfigOption) -> Bool {
        option.id.value == "model" || option.category == "model"
    }

    /// PURE. Flatten the SDK's `ungrouped`/`grouped` select options into a
    /// single `[SessionConfigSelectOption]` list. Grouped options preserve
    /// the agent's ordering within each group but drop the group headings
    /// (the model picker is a flat list). Mirrors
    /// `ThinkingEffortOption.flatChoices`.
    private static func flattenSelectOptions(
        _ options: SessionConfigSelectOptions
    ) -> [SessionConfigSelectOption] {
        switch options {
        case .ungrouped(let opts):
            return opts
        case .grouped(let groups):
            return groups.flatMap { $0.options }
        }
    }

    /// PURE. Decide whether a discovered list should be treated as
    /// `.noModelsAdvertised`. The probe throws this when an agent that DID
    /// return a `session/new` response advertised no models — older agents that
    /// predate the models capability. Distinct from a nil `ModelsInfo` (also
    /// empty) and from a never-resolved probe (timeout). Extracted so the
    /// decision is unit-tested without a subprocess.
    public static func shouldThrowNoModels(_ models: [CachedModelInfo]) -> Bool {
        models.isEmpty
    }

    /// PURE. Map any error thrown by `withThrowingTaskGroup` (or by the probe
    /// child) to a focused `ACPProviderModelProbeError`. A `CancellationError`
    /// means the work child lost the timeout race — surface as `.timedOut`.
    /// Already-mapped errors pass through. Anything else is wrapped as
    /// `.underlying`. Extracted so the mapping is unit-tested without a
    /// subprocess.
    public static func mapProbeError(_ error: Error) -> ACPProviderModelProbeError {
        if let probeErr = error as? ACPProviderModelProbeError {
            return probeErr
        }
        if error is CancellationError {
            return .timedOut
        }
        return .underlying(error)
    }

    /// Terminate the client actor and log any failure (never throws — this is
    /// teardown). Paseo parity: `closeProbe`
    /// (`acp-agent.ts:1095-1103`) always `terminateChildProcess` regardless
    /// of `session/close`. The SDK `Client.terminate()` is the equivalent: it
    /// kills the subprocess itself.
    private static func terminateAndLog(_ client: Client, reason: String, providerID: String) async {
        await client.terminate()
        DebugLog.agent("ACPProviderModelProbe.terminate(\(reason)): provider=\(providerID)")
    }
}

/// Focused error enum for the model-discovery probe. Surfaced in the Settings
/// row as a short user-facing message (`.localizedDescription`). Never silently
/// `try?`-swallowed (house rule) — every probe failure routes through here.
public enum ACPProviderModelProbeError: Error, LocalizedError, Equatable {
    /// `resolveSpawnConfig` returned nil — no `acpAgentPath` was configured.
    case notConfigured
    /// The probe exceeded the 60s timeout (the work child lost the race
    /// against `Task.sleep`). The subprocess is still terminated (the outer
    /// do/catch guarantees it).
    case timedOut
    /// `Client.authenticate` returned `success == false`. Only a REJECTED
    /// authenticate surfaces this — a missing API key is NOT an error (many
    /// agents self-auth).
    case authenticationFailed(String?)
    /// `Client.launch` or `Client.initialize` threw — the binary is missing /
    /// not executable / spawn failed for some OS reason, OR the process started
    /// but died before the ACP handshake completed (e.g. `bun` started but
    /// `claude`/`codex` wasn't on PATH). `detail` is the error's
    /// `localizedDescription`; `stderr` carries any subprocess stderr captured
    /// before death; `hint` carries the env-var workaround when the command
    /// matches a known provider (#733 + #737).
    case launchFailed(String, stderr: String?, hint: ProviderEnvHint?)
    /// `availableModels` is empty/nil but the probe completed successfully —
    /// older agents that predate the models capability. The probe throws this
    /// so the Settings row shows a specific message rather than an empty list.
    case noModelsAdvertised
    /// Any other error from `initialize` / `newSession` / `authenticate` (e.g.
    /// transport closed, JSON-RPC error). Surfaced with its `localizedDescription`.
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No agent executable configured. Set a command for this provider."
        case .timedOut:
            return "Model discovery timed out after 60s."
        case .authenticationFailed(let detail):
            let suffix = detail.map { " (\($0))" } ?? ""
            return "Authentication failed.\(suffix)"
        case .launchFailed(let detail, let stderr, let hint):
            var msg = "Could not launch the agent process: \(detail)"
            if let stderr, !stderr.isEmpty {
                msg += "\n\n\(stderr)"
            }
            if let hint {
                msg += "\n\nHint: set \(hint.envVar) to the full path of your \(hint.description) binary, or edit the provider's command/env in agent-providers.json."
            }
            return msg
        case .noModelsAdvertised:
            return "The provider advertised no models."
        case .underlying(let error):
            return error.localizedDescription
        }
    }

    /// `Equatable` conformance — `underlying` carries an `Error`, which isn't
    /// `Equatable`, so compare by `String(describing:)` (test-only). The other
    /// cases compare structurally.
    public static func == (lhs: ACPProviderModelProbeError, rhs: ACPProviderModelProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.timedOut, .timedOut),
             (.noModelsAdvertised, .noModelsAdvertised):
            return true
        case (.authenticationFailed(let l), .authenticationFailed(let r)):
            return l == r
        case (.launchFailed(let l, _, _), .launchFailed(let r, _, _)):
            return l == r
        case (.underlying(let l), .underlying(let r)):
            return String(describing: l) == String(describing: r)
        default:
            return false
        }
    }
}
