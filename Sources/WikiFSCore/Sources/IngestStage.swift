import Foundation

/// The three stages of ACP-driven ingestion, each independently routable to a
/// provider/model (Phase 1 — core model only; the engine wiring that actually
/// spawns per-stage backends lands in Phase 2). Mirrors paseo's planner/
/// executor/finalizer split.
public enum IngestStage: String, Codable, CaseIterable, Sendable {
    case planner
    case executor
    case finalizer
}

/// A user's provider/model pick for one `IngestStage`. `modelId == nil` means
/// "use that provider's `selectedModelIds` entry / agent default" — the same
/// fallback semantics `AgentProvidersConfig.selectedModelId(forProvider:)`
/// already uses elsewhere, so an unset model is never a silent downgrade.
public struct StageAssignment: Codable, Equatable, Sendable {
    public var providerId: String
    public var modelId: String?

    public init(providerId: String, modelId: String? = nil) {
        self.providerId = providerId
        self.modelId = modelId
    }
}
