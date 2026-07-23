import ACPModel
import Foundation

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

    /// Scan an agent's advertised `configOptions` for the `thought_level`
    /// select and project it. Returns `nil` when the agent advertises no such
    /// option (capability detection → the toolbar hides the dropdown).
    ///
    /// Matches by `id.value == "thought_level"` OR `category == "thought_level"`
    /// — the daemon and the spec use different conventions, so we accept both.
    /// Only `.select` kinds are surfaced (a `thought_level` boolean doesn't
    /// make sense; if an agent advertises one, we ignore it).
    public static func from(configOptions: [SessionConfigOption]) -> ThinkingEffortOption? {
        guard let option = configOptions.first(where: { isThoughtLevel($0) }),
              case .select(let select) = option.kind else {
            return nil
        }
        let choices = flatChoices(from: select.options)
        guard !choices.isEmpty else { return nil }
        return ThinkingEffortOption(
            configId: option.id.value,
            currentValue: select.currentValue.value,
            choices: choices)
    }

    /// Match heuristic: `thought_level` by id or by category.
    private static func isThoughtLevel(_ option: SessionConfigOption) -> Bool {
        option.id.value == "thought_level" || option.category == "thought_level"
    }

    /// Flatten the SDK's `ungrouped`/`grouped` select options into a single
    /// `[Choice]` list. Grouped options preserve the agent's ordering within
    /// each group but drop the group headings (the toolbar is a flat Menu).
    private static func flatChoices(
        from options: SessionConfigSelectOptions
    ) -> [Choice] {
        switch options {
        case .ungrouped(let opts):
            return opts.map { Choice(value: $0.value.value, label: $0.name) }
        case .grouped(let groups):
            return groups.flatMap { group in
                group.options.map { Choice(value: $0.value.value, label: $0.name) }
            }
        }
    }
}
