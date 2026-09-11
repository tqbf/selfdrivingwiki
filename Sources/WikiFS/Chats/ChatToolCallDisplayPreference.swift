// pattern: Functional Core

import Foundation

/// How the normal chat surface presents tool calls. A persistent secondary
/// preference — no keyboard shortcut, Activity diagnostics stay detailed.
///
/// - `summary`: each contiguous same-turn run of tool calls collapses into one
///   expandable "Tool activity" row. The default.
/// - `detailed`: one expandable row per tool call — the historical display.
/// - `hidden`: no tool-call rows at all — the historical Hide option.
enum ChatToolCallDisplayMode: String, CaseIterable, Sendable {
    case summary
    case detailed
    case hidden

    /// The user-facing label used by Settings → Appearance → Chat.
    var label: String {
        switch self {
        case .summary: "Summary"
        case .detailed: "Detailed"
        case .hidden: "Hidden"
        }
    }

    /// Settings footer text. Summary keeps details reachable through
    /// expansion, which is the fact users most often ask about.
    static let settingsFooterText =
        "Summary groups each run of tool calls into one expandable Tool activity row; "
            + "the individual calls stay available when the row is expanded. "
            + "Detailed shows one row per call. Hidden omits tool calls. "
            + "Show Full Activity and the queue Activity window always stay detailed."

    /// Missing and invalid raw values resolve to `summary`, the default.
    static func resolving(raw: String?) -> ChatToolCallDisplayMode {
        guard let raw else { return .summary }
        return ChatToolCallDisplayMode(rawValue: raw) ?? .summary
    }
}

/// Storage and one-shot migration for `ChatToolCallDisplayMode`.
///
/// The typed mode lives under one shared key. The legacy Boolean
/// `chat.hideToolCalls` key migrates into it once and is then orphaned —
/// never read again — so an old build that still writes the Boolean cannot
/// fight the new preference.
enum ChatToolCallDisplayPreference {
    static let storageKey = "chat.toolCallDisplayMode"
    static let legacyHideToolCallsKey = "chat.hideToolCalls"

    /// Read the stored mode with the documented fallback. Injectable
    /// `UserDefaults` so tests can select a mode, remount a view, and build a
    /// fresh resolver against the same isolated suite.
    static func resolve(in defaults: UserDefaults = .standard) -> ChatToolCallDisplayMode {
        ChatToolCallDisplayMode.resolving(raw: defaults.string(forKey: storageKey))
    }

    /// Idempotent migration from the legacy Boolean key.
    ///
    /// - A stored value under the new key wins and is preserved untouched,
    ///   even on repeated launches.
    /// - Otherwise the legacy key decides: `true` becomes `hidden`; `false`
    ///   or absent becomes `summary`. Writing `summary` eagerly (instead of
    ///   leaving the key absent) makes the migration's decision durable, so a
    ///   later legacy writer cannot flip a migrated install back.
    /// - The legacy key is kept as an orphaned compatibility value and is
    ///   never consulted again after this writes the new key.
    static func migrate(in defaults: UserDefaults) {
        guard defaults.object(forKey: storageKey) == nil else { return }
        let hidden = defaults.object(forKey: legacyHideToolCallsKey) as? Bool
        let mode: ChatToolCallDisplayMode = hidden == true ? .hidden : .summary
        defaults.set(mode.rawValue, forKey: storageKey)
    }
}
