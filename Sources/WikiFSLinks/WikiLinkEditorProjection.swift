import Foundation

/// Pure presentation transform for the raw page editor.
///
/// Canonical links keep their stable ULID in stored Markdown, while the editor
/// presents the alias as the readable target: `[[page:<ULID>|Title]]` becomes
/// `[[Title]]`. Links without a safe alias stay canonical so the projection
/// never changes their meaning.
public enum WikiLinkEditorProjection {

    /// Hide canonical ULIDs in wiki links that have a safe display alias.
    ///
    /// Source and chat links retain their namespace (`[[source:Title]]`), while
    /// page links use the shorter `[[Title]]` form. Links inside code, unresolved
    /// links, and aliases that would become ambiguous remain byte-identical.
    public static func displayed(_ body: String) -> String {
        let text = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.matches(in: body)

        var output = ""
        var cursor = 0
        var changed = false

        for match in matches {
            let fullRange = match.range
            let isEmbed = WikiLinkSpan.isEmbedPrefix(text, fullRange)

            if WikiLinkSpan.isProtected(fullRange, by: codeRanges)
                || WikiLinkSpan.isLocallyCodeWrapped(
                    text, fullRange, includesEmbedPrefix: isEmbed
                ) {
                continue
            }

            let rawTarget = text.substring(with: match.targetRange)
            let aliasRange = match.aliasRange
            guard aliasRange.location != NSNotFound else { continue }

            let rawAlias = text.substring(with: aliasRange)
            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsedTarget = WikiText.normalized(fixed.target)
            let (base, fragment) = WikiLinkParser.splitFragment(collapsedTarget)
            guard !base.isEmpty else { continue }

            let (bareBase, versionPin) = WikiLinkParser.splitVersionPin(base)
            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
            guard !bareTarget.isEmpty,
                  !WikiLinkParser.isEmptyPrefix(bareBase),
                  WikiLinkParser.isCanonicalULID(bareTarget) else {
                continue
            }

            guard let alias = fixed.alias.map(WikiText.normalized),
                  !alias.isEmpty,
                  alias != bareTarget,
                  isSafeAlias(alias) else {
                continue
            }

            let displayPrefix = kind == .page ? "" : kind.linkPrefix
            let pinSuffix = versionPin.map { "@v\($0)" } ?? ""
            let fragmentSuffix = fragment.map { "#\($0)" } ?? ""
            let replacement = "\(isEmbed ? "!" : "")[[\(displayPrefix)\(alias)\(pinSuffix)\(fragmentSuffix)]]"

            let copyEnd = isEmbed ? fullRange.location - 1 : fullRange.location
            if copyEnd > cursor {
                output += text.substring(
                    with: NSRange(location: cursor, length: copyEnd - cursor))
            }
            output += replacement
            cursor = fullRange.location + fullRange.length
            changed = true
        }

        guard changed else { return body }
        if cursor < text.length {
            output += text.substring(
                with: NSRange(location: cursor, length: text.length - cursor))
        }
        return output
    }

    private static func isSafeAlias(_ alias: String) -> Bool {
        // These characters carry wiki-link structure. Keeping the canonical
        // form is safer than presenting a link that parses differently.
        guard !alias.contains("[["),
              !alias.contains("]]"),
              !alias.contains("|"),
              !alias.contains("#") else {
            return false
        }

        // A page title that starts with a reserved namespace would change link
        // kind when the `page:` prefix is removed.
        return !ParsedLink.LinkType.allCases.contains {
            alias.hasPrefix($0.linkPrefix)
        }
    }
}
