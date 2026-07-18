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
        // Only the default claude-acp gets a seed model — Hermes/OpenCode stay
        // nil so the actual diagnosed-bug state (default provider with no
        // model) is still reachable for them (the user opts in explicitly).
        let config = AgentProvidersConfig.seed(discovered: [])
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-no-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var opencodeDefault = AgentProvider.opencodeDefault
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
}
