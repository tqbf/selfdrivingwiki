#if os(macOS)
import ACPModel
import Foundation
import WikiFSCore

/// #834: config-option model selection for claude-acp.
///
/// claude-acp exposes model selection via a `"model"` config option (a
/// `SessionConfigKind.select` advertised in `NewSessionResponse.configOptions`),
/// NOT via `ModelsInfo.availableModels`. The app's existing model-selection
/// code only knows the `availableModels` → `session/set_model` path, so for
/// claude-acp a pinned model (e.g. `"haiku"`) was silently dropped.
///
/// `resolveConfigOptionModel` is the config-option twin of
/// `ACPModelSelectionResolver.resolve` (the `setModel` path). It is PURE — no
/// subprocess — and unit-tested the same way. `ACPBackend.applyModelIfNeeded`
/// tries this path FIRST (returning non-nil means the agent advertises a
/// `"model"` config option) and falls through to the unchanged `resolve(...)`
/// (`setModel`) path when it returns `nil`.
///
/// Lives in `WikiFSEngine` (NOT `WikiFSCore` alongside `resolve`) because it
/// touches `ACPModel.SessionConfigOption`, and `WikiFSCore` is deliberately
/// ACP-free for Linux portability (#754/#780). The `ACPModelSelectionDecision`
/// enum case it returns (`applyViaModelConfigOption`) IS in `WikiFSCore` because
/// it carries only a `String` (no `ACPModel` types). Mirrors the
/// `ThinkingEffortOption.swift` precedent of ACPModel-touching pure logic living
/// in `WikiFSEngine`.
public extension ACPModelSelectionResolver {

    /// Decides whether to apply the selected model via the `"model"` config
    /// option (`session/set_config_option`) — for agents that advertise model
    /// selection as a config option rather than via `ModelsInfo.availableModels`
    /// (e.g. claude-acp). Returns `nil` when the agent exposes no `"model"`
    /// config option, so the caller falls through to the `setModel` resolver.
    ///
    /// Match heuristic (mirrors `ThinkingEffortOption.isThoughtLevel`): an
    /// option whose `id.value == "model"` OR `category == "model"`. Only
    /// `.select` kinds are surfaced (a boolean "model" doesn't make sense).
    ///
    /// Defensive guarantees (same posture as the `setModel` resolver):
    /// - No/empty selection → `.useAgentDefault` (the select's `currentValue`).
    /// - Selection not in the agent's advertised `options` → `.useAgentDefault`
    ///   (never send a value the agent will reject, reproducing the exact
    ///   "selection ignored" symptom the picker exists to prevent).
    /// - Selection already the select's `currentValue` → `.useAgentDefault`
    ///   (no-op round-trip).
    ///
    /// - Parameters:
    ///   - selectedModelId: the user's per-provider model choice (`nil` =
    ///     "no preference → agent default"; the app's default state).
    ///   - configOptions: the agent's advertised `NewSessionResponse.configOptions`.
    static func resolveConfigOptionModel(
        selectedModelId: String?,
        configOptions: [SessionConfigOption]
    ) -> ACPModelSelectionDecision? {
        // Find the "model" select option. Match by id == "model" (the id the
        // claude-acp adapter advertises) OR category == "model" (forward-compat
        // — mirrors thought_level's id-OR-category heuristic).
        guard let option = configOptions.first(where: {
            $0.id.value == "model" || $0.category == "model"
        }), case .select(let select) = option.kind else {
            return nil   // no "model" config option → caller uses the setModel path
        }
        // No user selection → agent default (the select's currentValue).
        guard let selectedModelId, !selectedModelId.isEmpty else {
            return .useAgentDefault
        }
        // Validate the selection against the agent's advertised option values —
        // same defensive posture as the setModel stale-selection guard.
        let advertisedValues = Self.configOptionValues(from: select.options)
        guard advertisedValues.contains(selectedModelId) else {
            return .useAgentDefault   // stale/unrecognized → don't 404 the agent
        }
        // Already the agent's current model → no-op round-trip.
        if select.currentValue.value == selectedModelId {
            return .useAgentDefault
        }
        return .applyViaModelConfigOption(selectedValue: selectedModelId)
    }

    /// Flatten the SDK's `ungrouped`/`grouped` select options into the raw
    /// value-id strings. PURE. Mirrors `ThinkingEffortOption.flatChoices`.
    static func configOptionValues(
        from options: SessionConfigSelectOptions
    ) -> [String] {
        switch options {
        case .ungrouped(let opts):
            return opts.map { $0.value.value }
        case .grouped(let groups):
            return groups.flatMap { $0.options.map { $0.value.value } }
        }
    }
}
#endif
