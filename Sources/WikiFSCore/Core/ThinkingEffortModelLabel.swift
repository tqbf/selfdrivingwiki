import Foundation

/// Pure presentation logic for model names that include a trailing thinking-effort variant.
///
/// Some agents advertise one model per effort level, with names such as
/// `GPT-5.6 (High)` or `GPT-5.6 [High]`. The chat toolbar has a separate effort
/// control, so model pickers should display the shared base name. Idle and
/// Catalog aliases are authoritative. The minimal built-in vocabulary is used
/// only for legacy cached entries that predate durable thinking metadata.
public enum ThinkingEffortModelLabel {
    // Compatibility fallback: remove after legacy model caches have naturally
    // refreshed to include ThinkingOptionCatalog metadata.
    private static let legacyRecognizedSuffixes: Set<String> = [
        "none",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "x-high",
        "extra high",
    ]

    public struct Variant: Equatable, Sendable {
        public let baseName: String
        public let effort: String

        public init(baseName: String, effort: String) {
            self.baseName = baseName
            self.effort = effort
        }
    }

    /// Returns the base model name when its final qualifier is a recognized
    /// thinking effort. Unrelated qualifiers remain part of the label.
    public static func displayName(
        for modelName: String,
        advertisedEfforts: [String] = []
    ) -> String {
        variant(in: modelName, advertisedEfforts: advertisedEfforts)?.baseName ?? modelName
    }

    /// Splits a recognized thinking-effort suffix from a model name.
    public static func variant(
        in modelName: String,
        advertisedEfforts: [String] = []
    ) -> Variant? {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let closingDelimiter = trimmedName.last,
              let openingDelimiter = openingDelimiter(for: closingDelimiter),
              let openingIndex = trimmedName.lastIndex(of: openingDelimiter) else {
            return nil
        }

        let suffixStart = trimmedName.index(after: openingIndex)
        let suffixEnd = trimmedName.index(before: trimmedName.endIndex)
        let suffix = String(trimmedName[suffixStart..<suffixEnd])
        guard let effort = normalizedEffort(suffix, advertisedEfforts: advertisedEfforts) else {
            return nil
        }

        let baseName = trimmedName[..<openingIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return nil }
        return Variant(baseName: String(baseName), effort: effort)
    }

    /// Resolves an effort value or label against the built-in and advertised vocabulary.
    public static func normalizedEffort(
        _ value: String?,
        advertisedEfforts: [String] = []
    ) -> String? {
        guard let value else { return nil }
        let normalizedValue = normalize(value)
        guard !normalizedValue.isEmpty else { return nil }

        let advertised = Set(advertisedEfforts.map(normalize).filter { !$0.isEmpty })
        let recognized = advertised.isEmpty
            ? legacyRecognizedSuffixes.contains(normalizedValue)
            : advertised.contains(normalizedValue)
        guard recognized else { return nil }
        return normalizedValue
    }

    private static func openingDelimiter(for closingDelimiter: Character) -> Character? {
        switch closingDelimiter {
        case ")": "("
        case "]": "["
        default: nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
