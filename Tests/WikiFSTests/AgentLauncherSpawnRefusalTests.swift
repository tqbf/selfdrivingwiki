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

    /// Build a launcher whose `providersConfig()` returns the freshly-seeded
    /// config from a throwaway tmp dir (so claude-acp has "sonnet", but the
    /// test's chosen provider — opencode — has NO selected model). The guard
    /// therefore refuses spawn on opencode.
    private func makeRefusingLauncher() throws -> AgentLauncher {
        let launcher = AgentLauncher()
        // Point `providersConfig()` at a fresh tmp dir so the seeded default
        // ("claude-acp": "sonnet") is loaded — but nothing is set for opencode.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // NOTE: tmp is intentionally NOT cleaned up here — `loadOrSeed` writes
        // a seed file into it on first read, and we don't want a follow-up
        // `providersConfig()` call to re-seed mid-test. The OS reaps temp.
        launcher.resolveProvidersContainerDirectory = { tmp }
        // Override the provider so we exercise opencode's nil-modelId state,
        // independent of whatever the user happens to have configured as
        // default in the real App Group container.
        launcher.resolveSelectedProvider = { .opencodeDefault }
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-allowed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pre-populate with a config whose opencode provider has a model.
        var opencodeDefault = AgentProvider.opencodeDefault
        opencodeDefault.isDefault = true
        let configWithModel = AgentProvidersConfig(
            providers: [opencodeDefault],
            selectedModelIds: ["opencode": "glm-4.7"])
        try configWithModel.save(to: tmp)

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }
        launcher.resolveSelectedProvider = { opencodeDefault }

        // Read what the chat path would resolve: provider + its modelId.
        let provider = launcher.resolveSelectedProvider()
        let modelId = launcher.providersConfig().selectedModelId(forProvider: provider.id)
        // Pin the chat path's guard input contract — what
        // `startInteractiveQuery` actually feeds into `SpawnModelGuard.validate`.
        #expect(provider.id == "opencode")
        #expect(modelId == "glm-4.7")
        #expect(SpawnModelGuard.validate(provider: provider, modelId: modelId) == nil)
    }
}
