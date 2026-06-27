import Foundation

/// Pure, dependency-free validator for fixing common malformed `[[wiki-link]]` syntax issues,
/// particularly those introduced by LLM hallucinations (e.g., escaping closing brackets).
public enum WikiLinkValidator {
    
    public struct ValidatedLink: Equatable {
        public let target: String
        public let alias: String?
        public let wasModified: Bool
    }
    
    /// Cleans and validates a raw target and alias extracted from the bracket regex.
    public static func validate(target: String, alias: String?) -> ValidatedLink {
        var cleanTarget = target
        var cleanAlias = alias
        var modified = false
        
        // 1. Fix escaped closing brackets (LLM bug)
        // If the target ends with a backslash, it was likely an escaped \]
        if cleanTarget.hasSuffix("\\") {
            cleanTarget.removeLast()
            modified = true
        }
        
        // If the alias ends with a backslash, it might also be escaped
        if let a = cleanAlias, a.hasSuffix("\\") {
            var newAlias = a
            newAlias.removeLast()
            cleanAlias = newAlias
            modified = true
        }
        
        return ValidatedLink(
            target: cleanTarget,
            alias: cleanAlias,
            wasModified: modified
        )
    }

    /// Scans the markdown text for `[[wiki-links]]` outside code blocks
    /// and auto-fixes any syntax errors found by `validate()`.
    public static func applyFixes(to markdown: String) -> String {
        let ns = markdown as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: markdown)
        let matches = WikiLinkSpan.regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        
        var out = ""
        var cursor = 0
        var didModify = false
        for match in matches {
            let full = match.range
            
            // Skip matches inside code blocks or spans
            if codeRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }) {
                continue
            }
            
            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            
            let validated = WikiLinkValidator.validate(target: rawTarget, alias: rawAlias)
            if !validated.wasModified { continue }
            
            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            cursor = full.location + full.length
            
            let aliasPart = validated.alias != nil ? "|\(validated.alias!)" : ""
            out += "[[\(validated.target)\(aliasPart)]]"
            didModify = true
        }
        
        if !didModify { return markdown }
        
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }
}
