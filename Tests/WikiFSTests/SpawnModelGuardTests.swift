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
        id: ProviderID(rawValue: "claude-acp"),
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

    @Test func allowsTheAgentsDefaultWhenModelIdIsNil() {
        #expect(SpawnModelGuard.validate(provider: claude, modelId: nil) == nil)
    }

    @Test func allowsTheAgentsDefaultWhenModelIdIsEmptyString() {
        // An empty string is treated identically to nil (the same shape
        // `AgentProvidersConfig.selectedModelId(forProvider:)` collapses to nil).
        #expect(SpawnModelGuard.validate(provider: claude, modelId: "") == nil)
    }

    // MARK: - Per-stage validation (per-stage-model-selection plan §6)

    @Test func allowsTheAgentsDefaultWhenStageNameIsProvided() {
        // per-stage-model-selection plan §6: a missing *executor*-stage model
        // (with planner/finalizer set) must produce a phase-named refusal, not
        // a silent spawn — the orchestrator runs the guard three times (once
        // per stage) and the message must name the failing stage so the user
        // knows which picker to fix.
        #expect(SpawnModelGuard.validate(
            provider: claude, modelId: nil, stageName: "Executor") == nil)
    }

    @Test func stageNameIsIgnoredWhenModelIsPresent() {
        // Stage validation passes (nil) when a model IS selected — the
        // per-stage name is only in the error message.
        #expect(SpawnModelGuard.validate(
            provider: claude, modelId: "sonnet", stageName: "Planner") == nil)
    }

}
#endif // os(macOS)
