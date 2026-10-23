import Foundation

/// Pure, dependency-free fixer for common malformed `[[wiki-link]]` syntax,
/// particularly backslash-escaped closing brackets introduced by LLM hallucinations
/// (e.g. `[[source:X\]]` → `[[source:X]]`).
public enum WikiLinkFixer {

    /// The result of fixing a single raw link target + alias pair.
    public struct FixResult: Equatable {
        public let target: String
        public let alias: String?
        public let wasModified: Bool
    }

    /// Strip a trailing backslash from `target` or `alias` (the LLM escaped-bracket bug).
    public static func fix(target: String, alias: String?) -> FixResult {
        var cleanTarget = target
        var cleanAlias = alias
        var modified = false

        if cleanTarget.hasSuffix("\\") {
            cleanTarget.removeLast()
            modified = true
        }

        if let a = cleanAlias, a.hasSuffix("\\") {
            var newAlias = a
            newAlias.removeLast()
            cleanAlias = newAlias
            modified = true
        }

        return FixResult(target: cleanTarget, alias: cleanAlias, wasModified: modified)
    }

    /// Scan the markdown for `[[wiki-links]]` outside code blocks and rewrite any
    /// that `fix()` corrects. Returns the original string unchanged when no fixes apply.
    public static func applyFixes(to markdown: String) -> String {
        applyFixesWithRanges(to: markdown).text
    }

    /// The result of a bracket-fix pass: the rewritten text plus the UTF-16
    /// ranges in the ORIGINAL text of each rewritten `[[…]]` span.
    public struct AppliedFixes: Equatable, Sendable {
        /// The fixed text (byte-identical to the input when nothing changed).
        public let text: String
        /// UTF-16 ranges in the ORIGINAL text — one per rewritten link span,
        /// in source order. Empty when nothing was rewritten.
        public let fixedRanges: [NSRange]

        /// `true` when at least one link span was rewritten.
        public var didModify: Bool { !fixedRanges.isEmpty }
    }

    /// ``applyFixes(to:)`` with reporting: the same rewrite, plus the original
    /// ranges it replaced so a caller (lint pre-flight) can record where the
    /// repair touched the body.
    public static func applyFixesWithRanges(to markdown: String) -> AppliedFixes {
        let ns = markdown as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: markdown)
        let matches = WikiLinkSpan.matches(in: markdown)

        var out = ""
        var cursor = 0
        var didModify = false
        var fixedRanges: [NSRange] = []
        for match in matches {
            let full = match.range

            if WikiLinkSpan.isProtected(full, by: codeRanges) {
                continue
            }

            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil

            let result = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            if !result.wasModified { continue }

            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            cursor = full.location + full.length

            let aliasPart = result.alias != nil ? "|\(result.alias!)" : ""
            out += "[[\(result.target)\(aliasPart)]]"
            didModify = true
            fixedRanges.append(full)
        }

        if !didModify { return AppliedFixes(text: markdown, fixedRanges: []) }

        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return AppliedFixes(text: out, fixedRanges: fixedRanges)
    }
}
