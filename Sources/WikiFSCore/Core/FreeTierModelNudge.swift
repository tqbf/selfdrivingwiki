import Foundation

/// #612: detects known free-tier models that may not follow ingestion
/// instructions reliably, so the Settings UI can show an **info-tone nudge**
/// (NOT a warning/prohibition) steering the user toward a stronger model.
///
/// PR #605 closed the "no model" hole (`SpawnModelGuard` refuses to spawn
/// without an explicit `selectedModelId`), but it doesn't steer users OFF
/// free-tier models (e.g. `opencode/big-pickle`) that drift from instructions.
/// This helper powers the gentle nudge caption shown in the Agents-settings
/// pickers — it never blocks selection.
///
/// PURE + STATIC + `nonisolated` so it can be unit-tested without rendering
/// and called from any actor. Mirrors the `SpawnModelGuard` shape (pure, no I/O)
/// and the `modelWarning(for:in:)` pattern on `AgentsSettingsView` (static,
/// testable, surfaced as a caption).
public enum FreeTierModelNudge {

    /// Known free-tier model id substrings. A model id is considered free-tier
    /// when it contains any of these (case-insensitive). Extend this set as
    /// new free-tier models are identified. Kept as `public` so tests can pin
    /// the membership and future code can assert coverage.
    public static let freeTierModelPatterns: [String] = [
        "big-pickle",
        "big_pickle",
    ]

    /// The info-tone nudge message shown beneath a picker whose selected model
    /// is a known free-tier model. Surfaced as a `.secondary` (muted) caption —
    /// NOT an orange warning or a red error — so it reads as advice, not alarm.
    public static let nudgeMessage: String = (
        "Free-tier models may not follow ingestion instructions reliably. "
        + "Consider a stronger model."
    )

    /// Returns the nudge message when `modelId` matches a known free-tier
    /// pattern; `nil` otherwise. PURE — no I/O, no actor. Case-insensitive
    /// substring match so `opencode/big-pickle`, `BIG-PICKLE`, and
    /// `big_pickle_v2` all fire.
    ///
    /// - Parameter modelId: The resolved model id (e.g. the stage's
    ///   `config.modelId(forStage:)` result or a provider's
    ///   `selectedModelId`). `nil`/empty → `nil` (no nudge).
    /// - Returns: The nudge message string when the model is free-tier; `nil`
    ///   when the model is unknown or free of free-tier patterns.
    public static func message(for modelId: String?) -> String? {
        guard let modelId, !modelId.isEmpty else { return nil }
        let lower = modelId.lowercased()
        guard freeTierModelPatterns.contains(where: { lower.contains($0) }) else {
            return nil
        }
        return nudgeMessage
    }
}
