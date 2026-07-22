#if os(macOS)
import Testing
import Foundation
@testable import WikiFSEngine
import WikiFSCore

/// Pure-logic tests for `SpawnModelGuard.validate(provider:modelId:stageName:)`.
///
/// The guard is the shared contract behind two spawn-refusal sites in
/// `AgentLauncher`:
/// - `runACPIngestPlannerExecutors` (ingest — validates each of the three
///   per-stage models: planner / executor / finalizer, per
///   `plans/per-stage-model-selection.md` §6)
/// - `startInteractiveQuery` (interactive chat)
///
/// These tests do NOT exercise the wiring; they pin the message contract
/// and the nil/empty/allows-non-empty decision. The wiring is exercised by
/// `AgentLauncherSpawnRefusalTests` (chat path) and `AgentProviderModelTests`
/// (the precondition: empty selection → nil modelId).
@Suite("SpawnModelGuard")
struct SpawnModelGuardTests {
    /// Inline fixture: #663 deleted the `.hermesDefault`/`.opencodeDefault`
    /// seed statics (the `.claudeAcpDefault` static remains as the
    /// `selectedProvider()` fallback safety net) and the `acp(from:)` factory
    /// is the generic catalog→provider mapper. Construct inline so the test
    /// is independent of any seed.
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

    // MARK: - Per-stage validation (per-stage-model-selection plan §6)

    @Test func returnsStageNamedRefusalWhenStageProvided() {
        // per-stage-model-selection plan §6: a missing *executor*-stage model
        // (with planner/finalizer set) must produce a phase-named refusal, not
        // a silent spawn — the orchestrator runs the guard three times (once
        // per stage) and the message must name the failing stage so the user
        // knows which picker to fix.
        let msg = SpawnModelGuard.validate(
            provider: claude, modelId: nil, stageName: "Executor")
        #expect(msg != nil)
        #expect(msg?.contains("Executor") == true)
        #expect(msg?.contains("stage") == true)
        // Actionable + provider identification preserved.
        #expect(msg?.contains("No model selected") == true)
        #expect(msg?.contains(claude.label) == true)
        #expect(msg?.contains("Settings → Agents") == true)
    }

    @Test func stageNameIsIgnoredWhenModelIsPresent() {
        // Stage validation passes (nil) when a model IS selected — the
        // per-stage name is only in the error message.
        #expect(SpawnModelGuard.validate(
            provider: claude, modelId: "sonnet", stageName: "Planner") == nil)
    }

    @Test func stageNameNilFallsBackToNonStageMessage() {
        // When stageName is nil OR empty, the message uses the legacy
        // non-stage form. Mirrors `startInteractiveQuery`'s chat-path call
        // (no stageName arg — chat is not a per-stage ingest kind).
        #expect(SpawnModelGuard.validate(provider: claude, modelId: nil)?.contains("stage") == false)
        #expect(SpawnModelGuard.validate(
            provider: claude, modelId: nil, stageName: "")?.contains("stage") == false)
    }
}
#endif // os(macOS)
