import Foundation

/// Rewrites Obsidian-style `[[wiki-links]]` in a page body to standard
/// relative Markdown links `[display](filename.md)` for the `pages/by-title`
/// filesystem projection. Allows external tools like Obsidian and VS Code
/// to follow links when they point at the `pages/by-title/` folder as a vault.
///
/// Rules:
/// - Only plain page links (`[[Title]]`, `[[Title|alias]]`, `[[Title#anchor]]`)
///   are rewritten — `[[source:…]]`, `[[chat:…]]`, and embeds (`![[…]]`) are
///   left verbatim (no corresponding file exists in `by-title/`).
/// - Unresolvable links (broken, links to deleted pages) are left as
///   `[[wikilink]]` so Obsidian treats them as "new page" stubs.
/// - Links inside code spans and fenced code blocks are left verbatim.
/// - Fragment anchors (`[[Title#Heading]]`) are preserved in the rewritten link.
/// - `#`-in-title disambiguation uses `WikiLinkResolver` (same rule as in-app).
/// - The filename in the output URL is percent-encoded for Markdown compatibility.
///
/// This is a **filesystem projection** concern only — the on-disk by-title body
/// has rewritten links; the SQLite store retains `[[…]]` verbatim. Nothing
/// here writes back to the store.
public enum RelativeLinkRewriter {

    private static let regex = WikiLinkSpan.regex

    /// Rewrite all resolvable page `[[wiki-links]]` in `body` to relative
    /// Markdown links `[display](filename.md)`.
    ///
    /// - Parameters:
    ///   - body: Full page content as produced by `PageMarkdownFormat.fileContent`
    ///           (YAML frontmatter + H1 + body). Frontmatter is passed through
    ///           unchanged since no `[[…]]` occurs in well-formed frontmatter.
    ///   - resolver: Maps a canonical (whitespace-collapsed) page title to its
    ///               by-title filename (e.g. `"Home"` → `"Home--01ABC.md"`).
    ///               Returns `nil` when the title has no matching page.
    /// - Returns: The rewritten body, or `body` unchanged if no resolvable page
    ///            links were found.
    public static func rewrite(_ body: String, resolver: (String) -> String?) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var out = ""
        var cursor = 0

        for match in matches {
            let full = match.range

            // Leave links inside code spans and fenced blocks verbatim.
            if WikiLinkSpan.isProtected(full, by: codeRanges) { continue }

            // Copy the gap before this match. If a `!` embed prefix immediately
            // precedes the match, consume it so we can emit `![[…]]` verbatim
            // (the `!` is already excluded from the match range).
            let isEmbedPrefix = WikiLinkSpan.isEmbedPrefix(ns, full)
            let copyEnd = isEmbedPrefix ? full.location - 1 : full.location
            if copyEnd > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: copyEnd - cursor))
            }
            cursor = full.location + full.length

            // Embeds (`![[source:…]]` etc.) — no relative file exists; leave verbatim.
            if isEmbedPrefix {
                out += "!" + ns.substring(with: full)
                continue
            }

            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound
                ? ns.substring(with: aliasRange) : nil

            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsed = WikiText.normalized(fixed.target)
            guard !collapsed.isEmpty else {
                out += ns.substring(with: full)
                continue
            }

            // Split on "#" and strip version pin — same pipeline as WikiLinkMarkdown.
            let (base, _) = WikiLinkParser.splitFragment(collapsed)
            guard !base.isEmpty else {
                // Same-page anchor (`[[#Heading]]`): no file target; leave as-is.
                out += ns.substring(with: full)
                continue
            }

            let (bareBase, _) = WikiLinkParser.splitVersionPin(base)
            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)

            guard !bareTarget.isEmpty,
                  !WikiLinkParser.isEmptyPrefix(bareBase),
                  kind == .page else {
                // source:, chat:, or empty prefix — no by-title file; leave as-is.
                out += ns.substring(with: full)
                continue
            }

            // Resolve, handling `#`-in-title disambiguation.
            let split = WikiLinkResolver.resolvedSplit(of: collapsed) { resolver($0) != nil }
            let linkTitle = split?.base ?? bareTarget
            let linkFragment = split?.fragment

            guard let filename = resolver(linkTitle) else {
                // Unresolvable (ghost link): leave as [[wikilink]].
                out += ns.substring(with: full)
                continue
            }

            // Display text: alias > link title.
            let rawDisplay: String
            if let alias = fixed.alias {
                let a = WikiText.normalized(alias)
                rawDisplay = a.isEmpty ? linkTitle : a
            } else {
                rawDisplay = linkTitle
            }
            let safeDisplay = rawDisplay
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")

            // Percent-encode the filename for the Markdown URL (spaces → %20 etc.).
            // Remove `()` from allowed set so an unbalanced `)` never ends the link.
            let encodedFilename = filename
                .addingPercentEncoding(withAllowedCharacters: markdownPathAllowed)
                ?? filename

            if let frag = linkFragment, !frag.isEmpty {
                let encodedFrag = frag
                    .addingPercentEncoding(withAllowedCharacters: markdownFragmentAllowed)
                    ?? frag
                out += "[\(safeDisplay)](\(encodedFilename)#\(encodedFrag))"
            } else {
                out += "[\(safeDisplay)](\(encodedFilename))"
            }
        }

        // Tail text after the last match.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Private

    /// URL path characters allowed in the Markdown link destination. Starts from
    /// `urlPathAllowed` and removes `()` (an unbalanced `)` would end the link
    /// destination early in CommonMark parsers).
    private static let markdownPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()")
        return set
    }()

    /// Fragment characters allowed after `#`. Removes `#`, `"`, `%`, and `()`
    /// to match `WikiLinkMarkdown`'s fragment encoding rules.
    private static let markdownFragmentAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.remove(charactersIn: "#\"%()")
        return set
    }()
}
