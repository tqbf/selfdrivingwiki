import Testing
import Foundation
@testable import WikiFSEngine
import WikiFSCore

/// Pure-logic tests for `SpawnModelGuard.validate(provider:modelId:)`.
///
/// The guard is the shared contract behind two spawn-refusal sites in
/// `AgentLauncher`:
/// - `runACPIngestPlannerExecutors` (ingest — one choke-point covering
///   planner/executor/finalizer; #604 collapsed the removed per-stage routing)
/// - `startInteractiveQuery` (interactive chat)
///
/// These tests do NOT exercise the wiring; they pin the message contract
/// and the nil/empty/allows-non-empty decision. The wiring is exercised by
/// `AgentLauncherSpawnRefusalTests` (chat path) and `AgentProviderModelTests`
/// (the precondition: empty selection → nil modelId).
@Suite("SpawnModelGuard")
struct SpawnModelGuardTests {
    /// Inline fixture: no `.testDefault` factory exists on `AgentProvider` —
    /// the type defines only `claudeAcpDefault`, `hermesDefault`,
    /// `opencodeDefault`, and the `acp(from:)` factory. Construct inline so
    /// the test is independent of those seeds.
    private let claude = AgentProvider(
        id: "claude-acp",
        label: "Claude",
        command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
        env: [:],
        enabled: true,
        isDefault: true)

    @Test func returnsNilWhenModelIdIsNonEmpty() {
        // Any non-empty model id is acceptable — the guard is provider-agnostic.
        #expect(SpawnModelGuard.validate(provider: claude, modelId: "sonnet") == nil)
        #expect(SpawnModelGuard.validate(provider: claude, modelId: "glm-5.2") == nil)
        #expect(SpawnModelGuard.validate(provider: claude, modelId: "x") == nil)
    }

    @Test func returnsErrorMessageWhenModelIdIsNil() {
        let msg = SpawnModelGuard.validate(provider: claude, modelId: nil)
        #expect(msg != nil)
        // Three required message fragments per AC.1/AC.2 — actionable
        // ("No model selected"), identifies the provider (its label), and
        // points the user where to fix it ("Settings → Agents").
        #expect(msg?.contains("No model selected") == true)
        #expect(msg?.contains(claude.label) == true)
        #expect(msg?.contains("Settings → Agents") == true)
    }

    @Test func returnsErrorMessageWhenModelIdIsEmptyString() {
        // An empty string is treated identically to nil (the same shape
        // `AgentProvidersConfig.selectedModelId(forProvider:)` collapses to nil).
        #expect(SpawnModelGuard.validate(provider: claude, modelId: "") != nil)
        let msg = SpawnModelGuard.validate(provider: claude, modelId: "")
        #expect(msg?.contains(claude.label) == true)
    }

    @Test func errorMessageIncludesProviderLabelForActionability() {
        // The provider label is what the user sees in Settings → Agents, so the
        // error message must use it (not the internal `id`) to be actionable.
        let opencode = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: true)
        let msg = SpawnModelGuard.validate(provider: opencode, modelId: nil)
        #expect(msg?.contains("OpenCode") == true)
        // And the internal id should NOT leak (the user doesn't know it).
        #expect(msg?.contains("provider id") == false)
    }

    @Test func messageIsStableAcrossProvidersForSnapshotStability() {
        // The wording is templated by label only — two providers with the same
        // label produce identical messages, so a snapshot/regression test can
        // pin the format.
        let a = AgentProvider(id: "x", label: "Hermes", command: ["hermes", "acp"])
        let b = AgentProvider(id: "y", label: "Hermes", command: ["hermes2", "acp"])
        #expect(
            SpawnModelGuard.validate(provider: a, modelId: nil)
            == SpawnModelGuard.validate(provider: b, modelId: nil))
    }
}
