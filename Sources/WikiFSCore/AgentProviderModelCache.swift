import Foundation

/// A secrets-free snapshot of one model an ACP agent advertised in its
/// `session/new` response (`ModelsInfo.availableModels`). This is the
/// "ModelInfo-lite" the chat-composer model picker reads to populate a
/// provider's model list — decoupled from the ACP SDK's `ModelInfo` (which
/// lives in the `ACPModel` module and is not part of `WikiFSCore`).
///
/// Persisted in `AgentProvidersConfig.providerModels`, keyed by provider id.
/// **Never** contains credentials, keys, or auth data — only display/model
/// routing metadata the agent itself advertises publicly.
public struct CachedModelInfo: Codable, Hashable, Sendable, Identifiable {
    /// The model id passed back to the agent via `session/set_model` — the same
    /// value the ACP SDK's `ModelInfo.modelId` advertises.
    public let modelId: String
    /// Human label (e.g. "GLM-4.7", "Claude Sonnet 4.5"). Falls back to
    /// `modelId` at the display seam when the agent omits a friendly name.
    public let name: String
    /// Optional one-line description the agent advertised.
    public let description: String?

    /// `Identifiable` over `modelId` so SwiftUI `ForEach`/`List` can drive the
    /// model picker without an extra `.id()`.
    public var id: String { modelId }

    public init(modelId: String, name: String, description: String? = nil) {
        self.modelId = modelId
        self.name = name
        self.description = description
    }

    /// The display label the picker trigger uses: the agent's friendly name when
    /// present, else the raw `modelId` (so a bad-default model like `glm-4-7`
    /// is still visible/recognizable — the whole point of the picker). PURE.
    public var displayLabel: String {
        name.isEmpty ? modelId : name
    }
}

/// Pure model-selection decision: given the agent's advertised `currentModelId`
/// + `availableModels`, and the user's per-provider selected model id, decide
/// whether `session/set_model` should be sent and with which id.
///
/// Extracted as a pure enum-returning helper so the selection logic is unit-
/// tested WITHOUT a live agent subprocess (the spike forbids end-to-end
/// testing). `ACPBackend.start` consumes this to drive `client.setModel`.
///
/// - `useAgentDefault`: no selection (or the selection matches the agent's
///   current model) → do nothing; today's behavior is unchanged (default).
/// - `apply(selectedId:)`: the user picked a model that differs from the agent's
///   current one AND is in the advertised list → call `setModel` with it.
/// - `useAgentDefaultUnadvertised`: the user has a stale selection (the agent
///   no longer advertises it) → fall back to the agent default rather than
///   sending an id the agent will 404 on.
public enum ACPModelSelectionDecision: Equatable, Sendable {
    case useAgentDefault
    case apply(selectedId: String)
}

public enum ACPModelSelectionResolver {

    /// PURE. Decides whether to call `session/set_model` for a newly-started
    /// ACP session.
    ///
    /// - Parameters:
    ///   - selectedModelId: the user's per-provider model choice (`nil` =
    ///     "no preference → agent default"; the app's default state).
    ///   - currentModelId: the agent's advertised `ModelsInfo.currentModelId`.
    ///   - advertisedModelIds: the model ids the agent advertised
    ///     (`ModelsInfo.availableModels.map(\.modelId)`). Empty/nil = the agent
    ///     did not advertise a list (older agents) → we never override.
    public static func resolve(
        selectedModelId: String?,
        currentModelId: String?,
        advertisedModelIds: [String]
    ) -> ACPModelSelectionDecision {
        guard let selectedModelId, !selectedModelId.isEmpty else {
            return .useAgentDefault
        }
        // If the agent didn't advertise a list, we can't validate the selection
        // — and we don't know its "current" model, so don't guess. Fall back to
        // the agent default (no behavior change for agents that predate models).
        guard !advertisedModelIds.isEmpty else { return .useAgentDefault }
        // Stale selection: the agent no longer offers this model. Sending it
        // would reproduce the exact 404 the picker exists to prevent.
        guard advertisedModelIds.contains(selectedModelId) else {
            return .useAgentDefault
        }
        // Already the agent's current model → a no-op setModel round-trip.
        if let currentModelId, currentModelId == selectedModelId {
            return .useAgentDefault
        }
        return .apply(selectedId: selectedModelId)
    }
}
