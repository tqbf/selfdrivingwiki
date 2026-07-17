import Foundation

/// Single-pass `{{token}}` substitution for prompt templates loaded from
/// `GeneratedPrompts`.
///
/// The templated prompt builders (`WikiOperation` per-op task bodies,
/// `WikiTreeRenderer.render`, the static first paragraph of
/// `IngestWriteRule.dontRediscover`) keep their static PROSE in `.md` files and
/// their control flow (loops, conditionals, singular/plural) in Swift. Leaf
/// values are threaded in via `{{token}}` placeholders filled here.
///
/// Semantics:
/// - Token names match `[A-Za-z0-9_]+`.
/// - Values are inserted LITERALLY; a value containing `{{x}}` is NOT
///   re-substituted. This single-pass design avoids the recursive-expansion
///   footgun and lets a value safely mention placeholder syntax.
/// - Unknown tokens are left intact so a typo is visible in the rendered prompt
///   rather than silently dropping content.
enum PromptTemplate {
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"\{\{([A-Za-z0-9_]+)\}\}"#, options: [])

    /// Replace every `{{name}}` in `template` with `vars[name]`. Unknown names
    /// are left as-is. Single pass — inserted values are not re-scanned.
    static func fill(_ template: String, _ vars: [String: String]) -> String {
        let ns = template as NSString
        let matches = tokenRegex.matches(
            in: template, options: [],
            range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let name = ns.substring(with: match.range(at: 1))
            if let value = vars[name] {
                result += value
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}
