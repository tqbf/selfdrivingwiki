import Foundation

// Runtime validation for declared sync fields and items — the load-time
// halves of the bounds `ExtractorManifest` validates at decode time. Shared
// by the sidecar loader so declaration semantics live beside the
// declaration, not in every caller.

extension ExtractorSyncFieldDeclaration {

    /// The caller-facing failure reason when `value` violates this field's
    /// declared pattern, or `nil` when it conforms. The whole (trimmed)
    /// value must match: the pattern describes the complete value, not a
    /// fragment.
    public func invalidReason(forValue value: String) -> String? {
        guard let pattern else { return nil }
        // Manifest validation compiles every pattern at decode, so a
        // compile failure here is unreachable — and the guard fails closed
        // to a typed reason anyway.
        // swiftlint:disable:next silent_try_optional
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "field \(name) declares a pattern that does not compile"
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.range.location == 0,
              match.range.length == value.utf16.count else {
            return "value of \(name) does not match the declared pattern"
        }
        return nil
    }
}

extension ExtractorSyncItemValidation {

    /// The caller-facing failure reason when `item` violates these bounds,
    /// or `nil` when it conforms. Empty strings never conform (length
    /// bounds start at 1).
    public func invalidReason(forItem item: String) -> String? {
        let length = item.utf8.count
        if length < minimumLength || length > maximumLength {
            if minimumLength == maximumLength {
                return "item \(item) must be exactly \(minimumLength) characters"
            }
            return "item \(item) must be between \(minimumLength) and \(maximumLength) characters"
        }
        if let alphabet, item.contains(where: { alphabet.contains($0) == false }) {
            return "item \(item) may only use characters from the declared alphabet"
        }
        if let pattern {
            // Manifest validation compiles every pattern at decode, so a
            // compile failure here is unreachable — and the guard fails
            // closed to a typed reason anyway.
            // swiftlint:disable:next silent_try_optional
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return "item validation declares a pattern that does not compile"
            }
            let range = NSRange(item.startIndex..., in: item)
            guard let match = regex.firstMatch(in: item, options: [], range: range),
                  match.range.location == 0,
                  match.range.length == item.utf16.count else {
                return "item \(item) does not match the declared pattern"
            }
        }
        return nil
    }
}
