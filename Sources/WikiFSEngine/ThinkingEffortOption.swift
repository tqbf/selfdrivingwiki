import ACPModel
import Foundation
import WikiFSCore

/// #566: A UI-facing projection of the agent's `thought_level` config option.
///
/// The raw ACP type (`SessionConfigOption`) is SDK-shaped and carries booleans,
/// grouped selects, `_meta`, etc. — more than the toolbar needs. This struct
/// narrows it to exactly what the "Thinking" dropdown binds to:
///
/// - `configId` (the option id, usually `"thought_level"`) — needed to call
///   `session/set_config_option`.
/// - `currentValue` (the active level, e.g. `"high"`) — the dropdown's checkmark.
/// - `choices` (the selectable values + their display names) — the menu items.
///
/// Built via `from(configOptions:)`, which scans the advertised options for a
/// `select` whose `id.value == "thought_level"` (or whose `category == "thought_level"`
/// — the polytoken-acp daemon uses the latter). Returns `nil` when the agent
/// advertises no such option, so the calling UI hides the affordance (capability
/// detection is agent-dependent: Claude, GLM, etc. advertise it; older agents
/// don't).
public struct ThinkingEffortOption: Equatable, Sendable, Codable {
    /// The config option id the toolbar passes back to `setConfigOption`
    /// (usually `"thought_level"`).
    public let configId: String
    /// The currently-selected level value id (e.g. `"high"`, `"medium"`, `"low"`).
    public var currentValue: String
    /// The selectable levels, in the order the agent advertised them. Each
    /// carries the value id (sent on selection) and a display name.
    public let choices: [Choice]

    public struct Choice: Equatable, Sendable, Identifiable, Codable {
        /// The value id to send to `setConfigOption` when this choice is picked.
        public let value: String
        /// A human-readable label for the menu item.
        public let label: String
        public var id: String { value }

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public init(configId: String, currentValue: String, choices: [Choice]) {
        self.configId = configId
        self.currentValue = currentValue
        self.choices = choices
    }

    /// Returns a copy with `currentValue` replaced. Used for the optimistic
    /// local flip in `AgentLauncher.setThinkingEffort` so the dropdown updates
    /// before the `setConfigOption` round-trip completes.
    public func withCurrentValue(_ value: String) -> ThinkingEffortOption {
        ThinkingEffortOption(configId: configId, currentValue: value, choices: choices)
    }

    /// Scan the authoritative session options and project the live current value.
    /// Durable capability is stored separately in each model's catalog; this
    /// value is an optional active-session overlay.
    public static func from(configOptions: [SessionConfigOption]) -> ThinkingEffortOption? {
        guard let extracted = extract(from: configOptions) else { return nil }
        return ThinkingEffortOption(
            configId: extracted.catalog.configOptionID.rawValue,
            currentValue: extracted.currentValueID.rawValue,
            choices: extracted.catalog.choices.map {
                Choice(value: $0.id.rawValue, label: $0.label)
            })
    }

    /// Convert a live projection back to the complete durable core catalog.
    public var catalog: ThinkingOptionCatalog {
        ThinkingOptionCatalog(
            configOptionID: ChatConfigurationOptionID(rawValue: configId),
            choices: choices.map {
                ThinkingOptionCatalogChoice(
                    id: ChatConfigurationValueID(rawValue: $0.value), label: $0.label)
            },
            defaultValueID: choices.contains { $0.value == currentValue }
                ? ChatConfigurationValueID(rawValue: currentValue)
                : nil)
    }

    struct Extracted: Equatable, Sendable {
        let catalog: ThinkingOptionCatalog
        let currentValueID: ChatConfigurationValueID
    }

    /// Shared ACP-shaped extraction used by provider probing and live sessions.
    static func extract(from configOptions: [SessionConfigOption]) -> Extracted? {
        let categoryMatch = configOptions.first {
            $0.category == "thought_level"
        }
        let legacyIDMatch = configOptions.first {
            $0.category == nil && $0.id.value == "thought_level"
        }
        guard let option = categoryMatch ?? legacyIDMatch,
              case .select(let select) = option.kind else {
            return nil
        }
        let choices = flatChoices(from: select.options)
        guard !choices.isEmpty else { return nil }
        let currentValueID = ChatConfigurationValueID(rawValue: select.currentValue.value)
        let defaultValueID = choices.contains { $0.id == currentValueID } ? currentValueID : nil
        return Extracted(
            catalog: ThinkingOptionCatalog(
                configOptionID: ChatConfigurationOptionID(rawValue: option.id.value),
                choices: choices,
                defaultValueID: defaultValueID),
            currentValueID: currentValueID)
    }

    /// Flatten grouped and ungrouped choices in advertised order.
    private static func flatChoices(
        from selectOptions: SessionConfigSelectOptions
    ) -> [ThinkingOptionCatalogChoice] {
        switch selectOptions {
        case .ungrouped(let options):
            return options.map { option in
                ThinkingOptionCatalogChoice(
                    id: ChatConfigurationValueID(rawValue: option.value.value),
                    label: option.name)
            }
        case .grouped(let groups):
            return groups.flatMap { group in
                group.options.map { option in
                    ThinkingOptionCatalogChoice(
                        id: ChatConfigurationValueID(rawValue: option.value.value),
                        label: option.name)
                }
            }
        }
    }
}
