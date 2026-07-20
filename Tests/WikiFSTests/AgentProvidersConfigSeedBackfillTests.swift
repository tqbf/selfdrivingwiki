import Testing
import Foundation
@testable import WikiFSCore

/// Pure-logic tests for the seed + `loadOrSeed` backfill that guarantees a
/// fresh install (or a freshly-loaded-but-empty-config install) has an
/// explicit `selectedModelId` for the default `claude-acp` provider — the
/// contract that lets `SpawnModelGuard.validate` refuse spawn without making
/// a fresh install unspawnable on day one.
///
/// These tests run in the fast CI tier (no live agent subprocess, no ACP).
@Suite("AgentProvidersConfig seed/backfill")
struct AgentProvidersConfigSeedBackfillTests {

    // MARK: - AC.6a — fresh-install seed includes the default model

    @Test func seedIncludesDefaultModelForDefaultProvider() {
        // A fresh install seeds "sonnet" for the claude-acp default provider
        // so the launcher doesn't immediately refuse spawn on day one.
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
    }

    @Test func seedDoesNotSeedModelsForNonDefaultProviders() {
        // Only the default claude-acp gets a seed model — any other provider
        // (e.g. one built from the catalog via `AddProviderSheet`) stays nil so
        // the actual diagnosed-bug state (default provider with no model) is
        // still reachable for them (the user opts in explicitly).
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
        // Providers other than claude-acp don't exist in the seed at all
        // (#663: the seed was reduced to `[claudeAcpDefault]`), so their
        // `selectedModelId` is nil by definition — pin it for the contract.
        #expect(config.selectedModelId(forProvider: "hermes") == nil)
        #expect(config.selectedModelId(forProvider: "opencode") == nil)
    }

    // MARK: - AC.6b — `loadOrSeed` backfills empty claude-acp-default configs

    @Test func loadOrSeedBackfillsEmptyClaudeAcpDefaultButPreservesExisting() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Case 1: a claude-acp-default config with empty selectedModelIds.
        // This is what a pre-guard install looks like. Backfill should inject
        // "claude-acp": "sonnet".
        let preGuard = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            selectedModelIds: [:])
        try preGuard.save(to: tmp)
        let backfilled = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(backfilled.selectedModelId(forProvider: "claude-acp") == "sonnet")

        // Case 2: a claude-acp-default config with a user-chosen model. The
        // backfill MUST NOT overwrite the user's explicit pick.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent(AgentProvidersConfig.fileName))
        let withPick = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            selectedModelIds: ["claude-acp": "opus"])
        try withPick.save(to: tmp)
        let preserved = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(preserved.selectedModelId(forProvider: "claude-acp") == "opus")
    }

    @Test func loadOrSeedDoesNotBackfillWhenDefaultIsNotClaudeAcp() throws {
        // The backfill is scoped to `claude-acp`-default installs. A
        // non-claude-acp default (e.g. opencode) with no model must NOT be
        // injected — that's exactly the diagnosed-bug state, and the guard
        // should refuse spawn there. The backfill is upgrade-safety only, not
        // a "fix every config" pass.
        //
        // Fixture note: `.claudeAcpDefault` ships with `isDefault: true`, and
        // `normalized()` keeps the FIRST default provider — so an
        // `[.claudeAcpDefault, opencodeAsDefault]` list would leave
        // claude-acp as default and trigger the backfill. We demote
        // claude-acp explicitly so opencode is the sole default.
        // #663: `.opencodeDefault` was deleted with the Hermes/OpenCode
        // seeds — fixtures build the literal inline (the catalog-driven
        // `AddProviderSheet` constructs the same shape at runtime).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-no-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var opencodeDefault = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: false)
        opencodeDefault.isDefault = true
        var claudeNonDefault = AgentProvider.claudeAcpDefault
        claudeNonDefault.isDefault = false
        let configWithOpencodeDefault = AgentProvidersConfig(
            providers: [claudeNonDefault, opencodeDefault],
            selectedModelIds: [:])
        try configWithOpencodeDefault.save(to: tmp)
        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.selectedModelId(forProvider: "opencode") == nil)
        // claude-acp is NOT default here → its selection is left untouched
        // (empty as written). The guard will refuse spawn on opencode here.
        #expect(loaded.selectedModelId(forProvider: "claude-acp") == nil)
    }

    // MARK: - stageProviderIds (agent-settings-tabs HIGH #1)

    @Test func oldConfigWithoutStageProviderIdsDecodesToEmpty() throws {
        // A pre-agent-settings-tabs `agent-providers.json` (no
        // `stageProviderIds` key) decodes to `[:]` → every stage uses the
        // global default provider (no migration, no behavior change).
        let json = """
        {
          "providers": [
            { "id": "claude-acp", "label": "Claude", "command": ["bun"], "env": {}, "enabled": true, "isDefault": true }
          ],
          "providerModels": {},
          "selectedModelIds": { "claude-acp": "sonnet" },
          "favoriteModelIds": {},
          "maxConcurrent": {},
          "ingestStageModelIds": {}
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(config.stageProviderIds == [:])
        #expect(config.provider(forStage: "chat").id == "claude-acp")
    }

    @Test func loadOrSeedRoundTripsStageProviderIds() throws {
        // HIGH #1: `loadOrSeed` reconstructs the config via an explicit field
        // list (its own comments warn it silently drops unlisted fields).
        // `stageProviderIds` MUST be carried through that reconstruction or
        // per-stage provider pins vanish on restart. This test writes pins,
        // reloads via `loadOrSeed`, and asserts the pins SURVIVE.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-stage-pin-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: "claude-acp", label: "Claude",
                    command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
                    env: [:], enabled: true, isDefault: true),
                AgentProvider(
                    id: "acme", label: "Acme",
                    command: ["acme", "acp"], env: [:],
                    enabled: true, isDefault: false),
            ],
            selectedModelIds: ["claude-acp": "sonnet", "acme": "acme-1"],
            stageProviderIds: [
                "chat": "acme",
                "lint": "claude-acp",
                "planner": "acme",
            ])
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        // The pins survive the loadOrSeed reconstruction.
        #expect(loaded.stageProviderIds["chat"] == "acme")
        #expect(loaded.stageProviderIds["lint"] == "claude-acp")
        #expect(loaded.stageProviderIds["planner"] == "acme")
        // And they resolve correctly.
        #expect(loaded.provider(forStage: "chat").id == "acme")
        #expect(loaded.provider(forStage: "lint").id == "claude-acp")
    }

    @Test func stageProviderIdsEncodeAndDecodeThroughJSON() throws {
        // The new field round-trips through Codable (encode → decode).
        let original = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            selectedModelIds: ["claude-acp": "sonnet"],
            stageProviderIds: ["chat": "claude-acp", "lint": "custom"])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentProvidersConfig.self, from: encoded)
        #expect(decoded.stageProviderIds == ["chat": "claude-acp", "lint": "custom"])
    }
}
