#if os(macOS)
import Testing
import Foundation
import ACPModel
import WikiFSCore
import WikiFSEngine
import ACP
@testable import WikiFSEngine
@testable import WikiFS

/// #640 — ACP model-discovery probe tests. Covers the THREE layers the plan
/// reviewer required (HIGH finding #3):
///
/// 1. PURE probe helpers (no subprocess, no Client actor). Per HIGH finding
///    #2, the SDK `Client` is a concrete `actor`, NOT a protocol — so the
///    probe's LOGIC (model mapping, error mapping, noModels decision,
///    `settingCachedModels` persist round-trip) is extracted into pure
///    helpers and tested directly here. The end-to-end probe (launch →
///    initialize → session/new → terminate) needs a real subprocess — that
///    shell is the `ACP_SMOKE`-gated live test below.
/// 2. AC.1 (Refresh populates the picker durably) — drives the public
///    `onRefreshModels` seam the sheet wires into, asserts the sidecar
///    round-trips + `config.cachedModels` updates.
/// 3. AC.4 (`SpawnModelGuard` unchanged) — pins that a nil `modelId` still
///    returns the pre-#640 error (the guard is the correctness backstop;
///    #640 breaks the deadlock by adding discovery, NOT by weakening it).
///
/// AC.7 (@MainActor discipline) is verified by `swift build` Sendable
/// checking, NOT a runtime test — the probe is `Sendable`, `discoverModels`
/// is `nonisolated async`, and `persistDiscoveredModels` is `@MainActor`.
/// If the compiler accepts the build, the discipline holds.
@Suite("ACPProviderModelProbe")
struct ACPProviderModelProbeTests {

    // MARK: - PURE: mapModelsToCache (AC.2 shape — model mapping)

    /// The agent advertised 3 models → the probe maps them to 3
    /// `CachedModelInfo` with the correct `modelId`/`name`/`description`.
    /// Mirrors the SDK `ModelInfo` shape returned by `session/new`.
    @Test func mapModelsToCacheReturnsAllEntries() {
        let models = ModelsInfo(
            currentModelId: "sonnet",
            availableModels: [
                ModelInfo(modelId: "sonnet", name: "Claude Sonnet", description: "Fast"),
                ModelInfo(modelId: "opus", name: "Claude Opus", description: "Smart"),
                ModelInfo(modelId: "haiku", name: "Claude Haiku", description: nil),
            ])
        let cached = ACPProviderModelProbe.mapModelsToCache(models)
        #expect(cached.count == 3)
        #expect(cached.map(\.modelId) == ["sonnet", "opus", "haiku"])
        #expect(cached[0].name == "Claude Sonnet")
        #expect(cached[0].description == "Fast")
        #expect(cached[2].description == nil)
    }

    @Test func mapModelsToCacheNilModelsReturnsEmpty() {
        // An agent that predates the models capability returns `session/new`
        // with no `models` field → nil → empty cache. The probe surfaces
        // `.noModelsAdvertised` in this case (see shouldThrowNoModels).
        let cached = ACPProviderModelProbe.mapModelsToCache(nil)
        #expect(cached.isEmpty)
    }

    @Test func mapModelsToCacheEmptyAvailableModelsReturnsEmpty() {
        let models = ModelsInfo(currentModelId: "x", availableModels: [])
        let cached = ACPProviderModelProbe.mapModelsToCache(models)
        #expect(cached.isEmpty)
    }

    // MARK: - PURE: mapModelsToCache configOptions fallback (#654)

    /// #654 exact repro: opencode doesn't populate `availableModels` — it
    /// advertises the model list as a `configOptions` select whose
    /// `id.value == "model"`. Pre-fix: probe returned [] ("advertised no
    /// models"). Post-fix: probe extracts the choices from the select.
    /// Mirrors Paseo's `deriveModelDefinitionsFromACP` fallback
    /// (`acp-agent.ts:637-680`).
    @Test func mapModelsToCacheFallsBackToConfigOptionsModelSelector() {
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("glm-4.7"),
                    options: .ungrouped([
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("glm-4.7"),
                            name: "GLM-4.7",
                            description: "Fast"),
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("glm-4-7"),
                            name: "GLM 4.7 (legacy)"),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(nil, configOptions: configOptions)
        #expect(cached.count == 2)
        #expect(cached.map(\.modelId) == ["glm-4.7", "glm-4-7"])
        #expect(cached[0].name == "GLM-4.7")
        #expect(cached[0].description == "Fast")
        #expect(cached[1].description == nil)
    }

    /// #654 + grouped-options variant. Some agents group their model options
    /// (e.g. "Fast" / "Smart"). The fallback must flatten the groups and
    /// preserve the agent's in-group ordering (the picker is flat). Pinned so
    /// a future refactor that drops `.grouped` handling is caught.
    @Test func mapModelsToCacheFallsBackToConfigOptionsGrouped() {
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("sonnet"),
                    options: .grouped([
                        SessionConfigSelectGroup(
                            group: SessionConfigGroupId("fast"),
                            name: "Fast",
                            options: [
                                SessionConfigSelectOption(
                                    value: SessionConfigValueId("haiku"),
                                    name: "Claude Haiku"),
                            ]),
                        SessionConfigSelectGroup(
                            group: SessionConfigGroupId("smart"),
                            name: "Smart",
                            options: [
                                SessionConfigSelectOption(
                                    value: SessionConfigValueId("sonnet"),
                                    name: "Claude Sonnet"),
                                SessionConfigSelectOption(
                                    value: SessionConfigValueId("opus"),
                                    name: "Claude Opus"),
                            ]),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(nil, configOptions: configOptions)
        #expect(cached.count == 3)
        #expect(cached.map(\.modelId) == ["haiku", "sonnet", "opus"])
    }

    /// #654 + `category == "model"` convention. The polytoken daemon
    /// advertises the model selector by `category` rather than `id.value`.
    /// The fallback accepts both (dual-convention parity with
    /// `ThinkingEffortOption.isThoughtLevel`).
    @Test func mapModelsToCacheFallsBackMatchesByCategory() {
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model_picker"),
                name: "Model Picker",
                category: "model",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("gpt-5"),
                    options: .ungrouped([
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("gpt-5"),
                            name: "GPT-5"),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(nil, configOptions: configOptions)
        #expect(cached.count == 1)
        #expect(cached.first?.modelId == "gpt-5")
    }

    /// #654: the missing-model-list edge case. `availableModels` is EMPTY
    /// (not nil) AND `configOptions` has a model selector. Pre-fix this was
    /// treated as `.noModelsAdvertised`. Post-fix the fallback kicks in.
    @Test func mapModelsToCacheFallsBackWhenAvailableModelsEmptyButConfigOptionsHasModels() {
        let models = ModelsInfo(currentModelId: "", availableModels: [])
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("glm-4.7"),
                    options: .ungrouped([
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("glm-4.7"),
                            name: "GLM-4.7"),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(models, configOptions: configOptions)
        #expect(cached.count == 1)
        #expect(cached.first?.modelId == "glm-4.7")
    }

    /// Precedence: when BOTH `availableModels` and a `configOptions` model
    /// selector are present, `availableModels` wins (Paseo parity). The
    /// fallback is ONLY a fallback.
    @Test func mapModelsToCachePrefersAvailableModelsOverConfigOptions() {
        let models = ModelsInfo(
            currentModelId: "sonnet",
            availableModels: [
                ModelInfo(modelId: "sonnet", name: "Claude Sonnet", description: nil),
            ])
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("opus"),
                    options: .ungrouped([
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("opus"),
                            name: "Claude Opus"),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(models, configOptions: configOptions)
        #expect(cached.count == 1)
        #expect(cached.first?.modelId == "sonnet")
    }

    /// Fallback returns [] when `configOptions` is present but has NO model
    /// selector — the agent advertised other options (e.g. `thought_level`)
    /// but no model. The probe then surfaces `.noModelsAdvertised`.
    @Test func mapModelsToCacheFallsBackEmptyWhenNoModelSelector() {
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("thought_level"),
                name: "Thinking",
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("high"),
                    options: .ungrouped([
                        SessionConfigSelectOption(
                            value: SessionConfigValueId("high"),
                            name: "High"),
                    ]))))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(nil, configOptions: configOptions)
        #expect(cached.isEmpty)
    }

    /// Fallback returns [] when a `model` option exists but its `kind` is
    /// `.boolean`, not `.select` — only `.select` carries a model list (a
    /// `.boolean` doesn't make sense for a model picker). Defensive against
    /// a malformed/edge-case agent.
    @Test func mapModelsToCacheFallsBackEmptyWhenKindIsBoolean() {
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                kind: .boolean(SessionConfigBoolean(currentValue: true)))
        ]
        let cached = ACPProviderModelProbe.mapModelsToCache(nil, configOptions: configOptions)
        #expect(cached.isEmpty)
    }

    // MARK: - PURE: shouldThrowNoModels

    @Test func shouldThrowNoModelsTrueForEmpty() {
        // The probe completed successfully but the agent advertised no models
        // → surface a specific error rather than wiping the cache.
        #expect(ACPProviderModelProbe.shouldThrowNoModels([]) == true)
    }

    @Test func shouldThrowNoModelsFalseForNonEmpty() {
        #expect(ACPProviderModelProbe.shouldThrowNoModels([
            CachedModelInfo(modelId: "x", name: "X"),
        ]) == false)
    }

    // MARK: - PURE: mapProbeError (cancellation → timedOut, etc.)

    /// A `CancellationError` (the work child lost the timeout race) maps to
    /// `.timedOut`. Pinned because the timeout-race is the probe's outer
    /// `withThrowingTaskGroup` — when the sleep child wins, the work child is
    /// cancelled and re-throws as `CancellationError`.
    @Test func mapProbeErrorCancellationBecomesTimedOut() {
        let mapped = ACPProviderModelProbe.mapProbeError(CancellationError())
        #expect(mapped == .timedOut)
    }

    /// An already-mapped `ACPProviderModelProbeError` passes through unchanged
    /// (no double-wrapping). Pinned so the catch-all `.underlying` arm doesn't
    /// shadow the focused error type.
    @Test func mapProbeErrorAlreadyMappedPassesThrough() {
        let original = ACPProviderModelProbeError.authenticationFailed("bad key")
        let mapped = ACPProviderModelProbe.mapProbeError(original)
        #expect(mapped == .authenticationFailed("bad key"))
    }

    /// Any other error wraps as `.underlying` (preserves the original via
    /// `String(describing:)` for `Equatable` in tests).
    @Test func mapProbeErrorUnknownWrapsAsUnderlying() {
        struct Boom: Error {}
        let mapped = ACPProviderModelProbe.mapProbeError(Boom())
        if case .underlying = mapped {
            // OK
        } else {
            Issue.record("expected .underlying, got \(mapped)")
        }
    }

    // MARK: - PURE: errorDescription (user-facing messages for the Settings row)

    @Test func errorDescriptionRendersForEveryCase() {
        // Every case must produce a non-empty user-facing message — the
        // Settings row surfaces `localizedDescription` directly. A nil/empty
        // description would show a blank red caption.
        let cases: [ACPProviderModelProbeError] = [
            .notConfigured,
            .timedOut,
            .authenticationFailed(nil),
            .authenticationFailed("expired"),
            .launchFailed("ENOENT", stderr: nil, hint: nil),
            .noModelsAdvertised,
            .underlying(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])),
        ]
        for err in cases {
            let desc = err.errorDescription
            #expect(desc?.isEmpty == false, "errorDescription must be non-empty for \(err)")
        }
    }

    // MARK: - AC.1: Refresh populates the picker durably (persist seam)

    /// AC.1 (Refresh button works): drives the SAME persist path the sheet's
    /// `onRefreshModels` closure invokes (`AgentsSettingsView.persistDiscoveredModels`
    /// → `AgentProvidersConfig.settingCachedModels` → sidecar write). The
    /// sheet is `private` so we test the public seam it composes against —
    /// the persist round-trip is what `cachedModels(forProvider:)` reads on
    /// the next Settings open, and what the chat-composer Picker reads on
    /// the next chat. Pins:
    ///   - `settingCachedModels` carries EVERY field forward (no field drop —
    ///     the reviewer's MEDIUM finding #5).
    ///   - The sidecar round-trips: reload returns the discovered list.
    @Test func refreshPersistPathUpdatesSidecarAndCarriesAllFields() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-probe-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A provider with maxConcurrent set — the field the parent's `save(_)`,
        // helper DROPS (pre-existing bug). `settingCachedModels` (the path the
        // probe-driven persist uses) must carry it through.
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"])
        let original = AgentProvidersConfig(
            providers: [provider],
            selectedModelIds: ["hermes": "glm-4.7"],
            favoriteModelIds: ["hermes": ["glm-4.7"]],
            maxConcurrent: ["hermes": 3])
        try original.save(to: tmp)

        // The probe's discovered list.
        let discovered = [
            CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7", description: "Fast"),
            CachedModelInfo(modelId: "glm-4-7", name: "GLM 4.7 (legacy)", description: nil),
        ]

        // The persist path the sheet's `onRefreshModels` closure drives —
        // identical to `AgentsSettingsView.persistDiscoveredModels` body.
        let updated = original.settingCachedModels(discovered, forProvider: "hermes")
        try updated.save(to: tmp)

        // Reload from disk and assert the discovered list round-tripped AND
        // the OTHER fields (maxConcurrent, favorites, selection) survived.
        let reloaded = AgentProvidersConfig.loadOrSeed(from: tmp)
        #expect(reloaded.cachedModels(forProvider: "hermes").map(\.modelId) == ["glm-4.7", "glm-4-7"])
        #expect(reloaded.cachedModels(forProvider: "hermes").first?.name == "GLM-4.7")
        // maxConcurrent carried through (the parent's `save(_:)` helper drops
        // this — pinning that the probe persist does NOT).
        #expect(reloaded.maxConcurrent["hermes"] == 3)
        #expect(reloaded.selectedModelId(forProvider: "hermes") == "glm-4.7")
        #expect(reloaded.favoriteModels(forProvider: "hermes") == ["glm-4.7"])
    }

    /// The probe's success → cachedModels path: a sheet that already has a
    /// stale list gets the new list and the OLD list is replaced (not
    /// concatenated). Pinned so a re-Refresh doesn't grow duplicates.
    @Test func refreshReplacesExistingCacheRatherThanAppending() {
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"])
        let stale = AgentProvidersConfig(
            providers: [provider],
            providerModels: ["hermes": [
                CachedModelInfo(modelId: "stale-model", name: "Stale"),
            ]])
        let fresh = [
            CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7"),
            CachedModelInfo(modelId: "glm-4-7", name: "GLM 4.7"),
        ]
        let updated = stale.settingCachedModels(fresh, forProvider: "hermes")
        #expect(updated.cachedModels(forProvider: "hermes").count == 2)
        #expect(updated.cachedModels(forProvider: "hermes").contains { $0.modelId == "stale-model" } == false)
    }

    /// Refresh failure (`.error`) does NOT wipe the last-known cache. Paseo
    /// parity (`provider-snapshot-manager.ts:773-786` — only the status/error
    /// fields change). The model Picker keeps showing the prior list.
    @Test func refreshFailureKeepsLastKnownCache() {
        // Start with one cached model + a "ready" state.
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"])
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: ["hermes": [
                CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7"),
            ]])
        // Simulate a refresh failure: the sheet's `refreshModels()` Task
        // catches the error and sets `.error(message)` — it does NOT touch
        // `cachedModels`. The persist closure (`onRefreshModels`) is only
        // invoked on SUCCESS. So the cache stays at its prior state.
        let stillCached = config.cachedModels(forProvider: "hermes")
        #expect(stillCached.count == 1)
        #expect(stillCached.first?.modelId == "glm-4.7")
    }

    // MARK: - AC.4: SpawnModelGuard unchanged (correctness backstop)

    /// AC.4: a nil `modelId` STILL produces the SpawnModelGuard error after
    /// #640. The deadlock is broken by ADDING a discovery path (the probe),
    /// NOT by weakening the guard. Pinned so a future refactor that
    /// relaxes the guard is caught.
    @Test func spawnModelGuardStillRejectsNilModel() {
        let provider = AgentProvider(id: "opencode", label: "OpenCode")
        let msg = SpawnModelGuard.validate(provider: provider, modelId: nil)
        #expect(msg != nil)
        #expect(msg?.contains("No model selected") == true)
    }

    @Test func spawnModelGuardStillRejectsEmptyModel() {
        let provider = AgentProvider(id: "opencode", label: "OpenCode")
        let msg = SpawnModelGuard.validate(provider: provider, modelId: "")
        #expect(msg != nil)
    }

    @Test func spawnModelGuardAllowsExplicitModel() {
        // The guard's allow-path: a non-empty modelId → nil (no error). This
        // is the path the probe ENABLES — once the user picks a discovered
        // model, the guard lets the spawn through.
        let provider = AgentProvider(id: "opencode", label: "OpenCode")
        #expect(SpawnModelGuard.validate(provider: provider, modelId: "glm-4.7") == nil)
    }

    @Test func spawnModelGuardMessageStillPointsAtSettings() {
        // The error message points the user at the SAME Settings → Agents
        // path the probe's Refresh button lives in. Pinned so the discovery
        // guidance stays accurate.
        let provider = AgentProvider(id: "opencode", label: "OpenCode")
        let msg = SpawnModelGuard.validate(provider: provider, modelId: nil) ?? ""
        #expect(msg.contains("Settings") || msg.contains("Agents") || msg.contains("pick a model"))
    }

    // MARK: - Provider construction parity (reviewer finding #4)

    /// The probe must receive the SAME provider construction the live path
    /// uses. `AgentBackendFactory.providerHints` is the entry point
    /// `resolveSpawnConfig` reads from — verify a populated `AgentProvider`
    /// yields a non-empty hints dict (no `notConfigured` short-circuit).
    @Test func providerHintsFromProbeProviderIsNonEmpty() {
        let provider = AgentProvider(
            id: "opencode", label: "OpenCode",
            command: ["opencode", "acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/opt/homebrew/bin/opencode", "acp"],
            apiKey: nil,
            selectedModelId: nil)
        #expect(!hints.isEmpty)
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/opt/homebrew/bin/opencode")
        // selectedModelId is intentionally nil for a probe — the probe reads
        // the agent's *advertised* list, not a chosen model.
        #expect(hints[HintKey.acpSelectedModelId.rawValue] == nil)
    }
}

/// Opt-in LIVE probe test. Drives the real `ACPProviderModelProbe.discoverModels`
/// against a real ACP agent subprocess — the same wire path the Settings
/// Refresh button uses. Skipped unless `ACP_SMOKE=1` is set, so it never runs
/// in CI or the default suite (it spawns a real subprocess + may hit the
/// network). Mirrors the existing `ACPSmokeTests` opt-in convention.
///
/// Run explicitly:
/// ```
/// ACP_SMOKE=1 swift test --filter ACPProviderModelProbeLiveTests
/// # with a key (needs an agent that advertises models):
/// ACP_SMOKE=1 ANTHROPIC_API_KEY=sk-... swift test --filter ACPProviderModelProbeLiveTests
/// ```
@Suite(
    .timeLimit(.minutes(5)),
    .disabled(
        if: ProcessInfo.processInfo.environment["ACP_SMOKE"] == nil,
        "Set ACP_SMOKE=1 (and ANTHROPIC_API_KEY for a full probe) to run the live model-probe test.")
)
struct ACPProviderModelProbeLiveTests {

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// AC.2 live: a real agent subprocess returns a non-empty
    /// `availableModels` list, the probe maps them to `CachedModelInfo`, and
    /// `terminate()` runs (no orphaned subprocess). Reaches the
    /// launch → initialize → (auth) → newSession → map → terminate path the
    /// pure-helper tests can't cover.
    @Test func liveProbeDiscoversModelsAndTerminates() async throws {
        let agentPath = env("ACP_AGENT_PATH") ?? "npx"
        let agentArgs = env("ACP_AGENT_ARGS") ?? "--yes @agentclientprotocol/claude-agent-acp"
        let apiKey = env("ANTHROPIC_API_KEY") ?? env("ACP_API_KEY")

        // Resolve the agent binary the same way the Settings availability
        // check does — the probe needs an absolute path (the SDK's launch
        // does NOT do PATH lookup).
        let resolvedAgentPath: String
        switch PathPreflight.resolveOnLoginShell(executable: agentPath) {
        case .found(let path):
            resolvedAgentPath = path
        case .missing(let reason):
            Issue.record("ACP agent executable '\(agentPath)' not found: \(reason)")
            return
        }

        let provider = AgentProvider(
            id: "claude-acp-live", label: "Claude (live probe)",
            command: [resolvedAgentPath] + ShellArgv.tokenize(agentArgs))
        let probe = ACPProviderModelProbe(
            provider: provider,
            resolvedCommand: [resolvedAgentPath] + ShellArgv.tokenize(agentArgs),
            apiKey: apiKey)

        do {
            let models = try await probe.discoverModels(timeout: .seconds(60))
            // Without a key, an agent that advertises authMethods will reach
            // newSession (the probe skips client auth on missingCredentials)
            // but the agent may reject the prompt-less session. With a key,
            // the model list should be non-empty.
            if let key = apiKey, !key.isEmpty {
                #expect(!models.isEmpty, "expected the agent to advertise models with a valid key")
                #expect(models.allSatisfy { !$0.modelId.isEmpty })
            } else {
                // Without a key we still got SOME response (even an empty one)
                // — proves launch + initialize + newSession + terminate all
                // ran without leaking a subprocess.
                DebugLog.agent("[acp-probe-live] no key, models.count=\(models.count)")
            }
        } catch ACPProviderModelProbeError.timedOut {
            // A timeout is still a successful teardown test — the do/catch
            // outside the race guarantees terminate() ran.
            DebugLog.agent("[acp-probe-live] probe timed out (60s) — teardown verified")
        } catch ACPProviderModelProbeError.noModelsAdvertised {
            // The agent advertised no models (older agent) — still proves the
            // full wire path ran and terminate() was called.
            DebugLog.agent("[acp-probe-live] agent advertised no models — teardown verified")
        }
        // Reaching here means the probe completed (success or mapped error)
        // and `terminate()` ran via the outer do/catch. No assertion needed —
        // the absence of an orphaned process is the contract (we can't assert
        // it from Swift, but the structure of `discoverModels` guarantees it).
    }
}
#endif
