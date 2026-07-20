import Testing
import Foundation
@testable import WikiFSEngine
import WikiFSCore
@testable import WikiFS

    /// AC.2 — the interactive chat spawn path (`startInteractiveQuery`) refuses to
    /// spawn a session when the resolved provider has no `selectedModelId`,
    /// setting `preflightError` to the same wording as the ingest path's guard
    /// and returning without spawning.
    ///
    /// Construction pattern mirrors `QueryNewChatTests.makeLauncher()` (line 14-
    /// 18): the launcher is a `@MainActor` plain class with injectable seams
    /// (`resolveSelectedProvider`, `resolveProvidersContainerDirectory`). The
    /// `startInteractiveQuery` early-return site lives in the PREFLIGHT section
    /// (comment at the function's start: "no gate held — early returns here don't
    /// need gate release"), so the observable contract is: `preflightError != nil`
    /// + `isRunning` stays false (only the one-shot `run()` path sets `isRunning =
    /// true` early — the chat path sets it later, past our guard).
    @MainActor
    struct AgentLauncherSpawnRefusalTests {

    /// Build a launcher whose chat path resolves to a provider with NO
    /// `selectedModelId`, so the `SpawnModelGuard` refuses to spawn.
    ///
    /// per-stage-model-selection (#704 removed): the chat path now resolves
    /// its provider via `providersConfig().selectedProvider()` (NOT via the
    /// injected `resolveSelectedProvider` seam, NOT via a per-op
    /// `providerForChat()` — that field is gone). So the no-model scenario is
    /// set up by pre-writing an `agent-providers.json` whose DEFAULT provider
    /// is opencode (no per-op pin → fall-back was the per-op behavior; now
    /// the default IS the resolver), with no selectedModelIds entry for
    /// opencode. The guard fires on that nil-model state.
    private func makeRefusingLauncher() throws -> AgentLauncher {
        let launcher = AgentLauncher()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // NOTE: tmp is intentionally NOT cleaned up here — `loadOrSeed` writes
        // a seed file into it on first read, and we don't want a follow-up
        // `providersConfig()` call to re-seed mid-test. The OS reaps temp.

        // Pre-write a config whose DEFAULT provider is opencode (constructed
        // inline — #663: the `.opencodeDefault` static was deleted alongside
        // the Hermes/OpenCode seeds; the catalog-driven `AddProviderSheet`
        // replaced them, so test fixtures build literals). No selectedModelIds
        // entry for opencode → the guard fires on the nil-model state.
        var opencodeDefault = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: false)
        opencodeDefault.isDefault = true
        let configNoModel = AgentProvidersConfig(
            providers: [opencodeDefault])
        try configNoModel.save(to: tmp)

        launcher.resolveProvidersContainerDirectory = { tmp }
        return launcher
    }

    @Test func startInteractiveQueryRefusesSpawnWithNoModel() async throws {
        let launcher = try makeRefusingLauncher()

        // Sanity: launcher starts idle with no preflightError.
        #expect(launcher.preflightError == nil)
        #expect(launcher.isRunning == false)

        // Drive the chat path. The guard fires before the backend/PATH/
        // scratch-dir work, so the closures stay as no-ops.
        await launcher.startInteractiveQuery(
            firstMessage: "hello",
            stateMarkdown: "",
            wikiID: "wiki-test",
            wikiRoot: "/tmp/wiki-test",
            systemPrompt: "",
            wikictlDirectory: "/tmp/wiki-test",
            onLock: { },
            onUnlock: { }
        )

        // AC.2 contract: preflightError set, isRunning still false. We can't
        // directly observe `sessionHandle` (it's private), but `isRunning ==
        // false` + `preflightError != nil` together pin the preflight-abort
        // contract — `isRunning` is only set `true` LATER in
        // `startInteractiveQuery` (past the guard + scratch-dir creation),
        // so `false` here means the spawn path never advanced.
        #expect(launcher.preflightError != nil)
        #expect(launcher.preflightError?.contains("No model selected") == true)
        #expect(launcher.preflightError?.contains("OpenCode") == true)
        #expect(launcher.preflightError?.contains("Settings → Agents") == true)
        #expect(launcher.isRunning == false)
    }

    @Test func startInteractiveQuerySpawnsWhenModelIsSelected() throws {
        // AC.5 (chat-side): when a model IS selected, the guard returns nil
        // and preflightError stays nil — the launcher proceeds past the guard.
        // We can't drive the rest of `startInteractiveQuery` (it needs a real
        // ACP subprocess + scratch dir), so this test asserts only the
        // observable EARLY contract: that a model-selected config does NOT
        // trip the guard's preflightError.
        //
        // We exercise the contract via the same shared guard (the launcher's
        // call site is just `SpawnModelGuard.validate(...)`); the dedicated
        // `SpawnModelGuardTests.returnsNilWhenModelIdIsNonEmpty` pins the
        // guard itself. This test pins the LAUNCHER wiring: that a
        // model-selected config produces a nil guard result the launcher
        // would use.
        //
        // per-stage-model-selection (#704 removed): the chat path resolves via
        // `providersConfig().selectedProvider()`. We pre-write
        // opencode-as-default with a selected model — `selectedProvider()`
        // returns opencode — and the model resolver returns the seeded model
        // id — and feed both into the guard exactly as
        // `startInteractiveQuery` does.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-allowed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pre-populate with a config whose opencode provider has a model.
        // #663: `.opencodeDefault` was deleted alongside the Hermes/OpenCode
        // seeds — the catalog-driven `AddProviderSheet` replaced them, so test
        // fixtures build literals.
        var opencodeDefault = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: false)
        opencodeDefault.isDefault = true
        let configWithModel = AgentProvidersConfig(
            providers: [opencodeDefault],
            selectedModelIds: ["opencode": "glm-4.7"])
        try configWithModel.save(to: tmp)

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }

        // Read what the chat path resolves via the selectedProvider seam.
        // The default provider is opencode, and its selected model is
        // "glm-4.7" — both fed into the guard.
        let provider = launcher.providersConfig().selectedProvider()
        let modelId = launcher.providersConfig().selectedModelId(forProvider: provider.id)
        // Pin the chat path's guard input contract — what
        // `startInteractiveQuery` actually feeds into `SpawnModelGuard.validate`.
        #expect(provider.id == "opencode")
        #expect(modelId == "glm-4.7")
        #expect(SpawnModelGuard.validate(provider: provider, modelId: modelId) == nil)
    }
}
