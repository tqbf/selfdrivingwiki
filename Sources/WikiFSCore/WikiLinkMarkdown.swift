import Foundation

/// Pure, view-free transform that rewrites Obsidian-style `[[wiki-links]]` in a
/// Markdown body into ordinary Markdown links pointing at a private `wiki://`
/// scheme, so Foundation's `AttributedString(markdown:)` (CommonMark, which has
/// no concept of `[[…]]`) renders them as real, clickable links.
///
/// This is an **in-app preview/navigation** concern only — the on-disk / mounted
/// body STAYS literal `[[…]]` (that's the canonical wiki format the agents and
/// `indexes/links.jsonl` depend on). Nothing here is ever written back to the
/// store.
///
/// Kept pure (no storage / no SwiftUI) so it is trivially unit-testable. It
/// reuses `WikiLinkParser`'s exact bracket grammar — there is no second parser —
/// but, unlike the parser (which de-dupes by target for the link graph), this
/// transform must rewrite EVERY occurrence in place, so it matches spans
/// directly against the same regex.
///
/// Resolution is injected as a closure (`isResolved`) rather than reaching for a
/// store, so the function stays pure and the caller decides what "exists" means:
///   * a target that resolves → `wiki://page?title=…` or `wiki://source?title=…`
///   * a target that does NOT  → `wiki://missing?title=…` (still a link
///     so the view can style it dimmed, but the click handler no-ops on it).
public enum WikiLinkMarkdown {

    /// The private scheme the in-app `OpenURLAction` intercepts. Real external
    /// links (https, mailto, …) fall through to `.systemDefault`.
    public static let scheme = "wiki"
    /// Host for a link whose target resolves to a real page (navigates).
    public static let resolvedHost = "page"
    /// Host for a link whose target has no page/source (rendered dimmed, inert).
    public static let unresolvedHost = "missing"

    // Shared grammar from WikiLinkSpan (same pattern as WikiLinkParser).
    private static let regex = WikiLinkSpan.regex

    /// Rewrite all `[[…]]` spans in `body` to Markdown links, EXCEPT those that
    /// fall inside a backtick code span or fenced code block (where `[[…]]` is
    /// literal text the user wants shown verbatim). The display text is the alias
    /// when present (else the target); the URL always carries the URL-encoded
    /// *target* title.
    ///
    /// - Parameters:
    ///   - body: the raw page Markdown (with literal `[[…]]`).
    ///   - isResolved: returns `true` if a (target, LinkType) pair maps to an
    ///                 existing page/source. Receives the whitespace-collapsed,
    ///                 prefix-stripped target.
    /// - Returns: Markdown safe to hand to `AttributedString(markdown:)`.
    public static func linkified(
        _ body: String,
        isResolved: (String, WikiLinkParser.ParsedLink.LinkType) -> Bool = { _, _ in true }
    ) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        // Build the output by walking matches left→right, copying the gaps
        // verbatim and replacing each (non-code) match with a Markdown link.
        var out = ""
        var cursor = 0
        for match in matches {
            let full = match.range

            // Skip — copy verbatim — any match inside a code span/fence.
            if codeRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }) {
                continue
            }

            // Copy the untouched text between the previous match and this one.
            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            cursor = full.location + full.length

            let parsedTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let parsedAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            
            let fixed = WikiLinkFixer.fix(target: parsedTarget, alias: parsedAlias)

            let rawTarget = collapseWhitespace(fixed.target)
            guard !rawTarget.isEmpty else {
                // Empty target (e.g. `[[ ]]`): leave the literal text in place.
                out += ns.substring(with: full)
                continue
            }

            // Split on first "#" BEFORE classifying — shared with WikiLinkParser.
            let (base, fragment) = WikiLinkParser.splitFragment(rawTarget)

            // Same-page anchor: empty base → wiki://anchor#fragment.
            if base.isEmpty {
                guard let frag = fragment else {
                    out += ns.substring(with: full)
                    continue
                }
                let display: String
                if let alias = fixed.alias {
                    let collapsedAlias = collapseWhitespace(alias)
                    display = collapsedAlias.isEmpty ? frag : collapsedAlias
                } else {
                    display = frag
                }
                out += markdownAnchorLink(display: display, fragment: frag)
                continue
            }

            let (kind, bareTarget) = WikiLinkParser.classify(base)
            guard !bareTarget.isEmpty else {
                // Empty bare target after prefix strip: literal text.
                out += ns.substring(with: full)
                continue
            }
            // `[[source:]]` / `[[page:]]` — reserved prefix with no meaningful
            // remainder: emit literal text (consistent with the parser's skip).
            if WikiLinkParser.isEmptyPrefix(base) {
                out += ns.substring(with: full)
                continue
            }

            // Try every (name, fragment) reading of the target against the
            // caller's namespace, longest name first — so a `#` INSIDE a
            // page/source name (e.g. "… for C# …", with or without a real
            // anchor after it) links the actual page instead of truncating at
            // the first `#`. Ghost links keep the heuristic split.
            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget
            let split = WikiLinkResolver.resolvedSplit(of: raw) { isResolved($0, kind) }
            let resolved = split != nil
            let linkTarget = split?.base ?? bareTarget
            let linkFragment = split.map(\.fragment) ?? fragment

            let display: String
            if let alias = fixed.alias {
                let collapsedAlias = collapseWhitespace(alias)
                display = collapsedAlias.isEmpty ? linkTarget : collapsedAlias
            } else {
                display = linkTarget
            }

            out += markdownLink(display: display, target: linkTarget, kind: kind,
                                resolved: resolved, fragment: linkFragment)
        }
        // Tail after the last match.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// The `wiki://…` URL for a given target title, or nil if `url` is not one of
    /// ours. Accepts hosts `"page"`, `"source"`, or `"missing"`. Used by the view's
    /// `OpenURLAction` to pull the title back out.
    public static func target(from url: URL) -> String? {
        guard url.scheme == scheme,
              let host = url.host,
              host == resolvedHost || host == "source" || host == unresolvedHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let title = components.queryItems?.first(where: { $0.name == "title" })?.value,
              !title.isEmpty
        else { return nil }
        return title
    }

    /// Return the URL-decoded fragment from a `wiki://` URL, or nil. Used by the
    /// view's `OpenURLAction` to extract the anchor for scroll-to.
    public static func fragment(from url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host,
              host == resolvedHost || host == "source" || host == unresolvedHost || host == "anchor"
        else { return nil }
        return url.fragment?.removingPercentEncoding
    }

    /// `.page` / `.source` for a resolved link; `nil` for unresolved (`missing` or
    /// `anchor`) or non-wiki. Used by the view's `OpenURLAction` to route the click.
    /// Host `"anchor"` is same-page scroll — not a navigation, so returns nil here
    /// (the OpenURLAction handles it separately).
    public static func resolvedKind(from url: URL) -> WikiLinkParser.ParsedLink.LinkType? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        switch host {
        case resolvedHost:   return .page     // "page"
        case "source":       return .source
        default:             return nil       // "missing", "anchor", or anything else → inert
        }
    }

    /// True if `url` points at a page that resolved (i.e. should navigate). An
    /// unresolved (`missing`) link is one of ours but inert.
    public static func isResolvedURL(_ url: URL) -> Bool {
        resolvedKind(from: url) != nil
    }

    /// True if `url` is a same-page anchor (`wiki://anchor#…`).
    public static func isSamePageAnchor(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == "anchor"
    }

    // MARK: - Helpers

    private static func markdownLink(display: String, target: String,
                                     kind: WikiLinkParser.ParsedLink.LinkType,
                                     resolved: Bool,
                                     fragment: String? = nil) -> String {
        let host: String
        if resolved {
            host = kind == .source ? "source" : resolvedHost
        } else {
            host = unresolvedHost
        }
        // Encode the title for the query value, and escape any `]`/`)` in the
        // display text so it can't break the Markdown `[text](url)` grammar.
        let encodedTitle = target.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed)
            ?? target
        let safeDisplay = display
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        var url = "\(scheme)://\(host)?title=\(encodedTitle)"
        if let frag = fragment, !frag.isEmpty {
            let encodedFrag = frag.addingPercentEncoding(withAllowedCharacters: fragmentAllowed)
                ?? frag
            url += "#\(encodedFrag)"
        }
        return "[\(safeDisplay)](\(url))"
    }

    /// Collapse whitespace runs to one space and trim — delegates to the single
    /// shared normalizer.
    private static func collapseWhitespace(_ s: String) -> String {
        WikiText.normalized(s)
    }

    /// Build a same-page anchor link: `[display](wiki://anchor#encodedFragment)`.
    /// No `?title=` query — the host `"anchor"` tells the OpenURLAction to scroll
    /// within the current preview rather than navigate.
    private static func markdownAnchorLink(display: String, fragment: String) -> String {
        let encodedFrag = fragment.addingPercentEncoding(withAllowedCharacters: fragmentAllowed)
            ?? fragment
        let safeDisplay = display
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(safeDisplay)](\(scheme)://anchor#\(encodedFrag))"
    }

    /// Allowed characters for the `title=` query value. Start from the URL query
    /// set and remove the sub-delimiters that have query meaning, so a `&`, `=`,
    /// `?`, `#`, `+`, or space in a title is percent-escaped rather than parsed.
    /// `(` / `)` are also escaped: the whole URL is emitted inside a Markdown
    /// `[text](url)` destination, where an unbalanced `)` terminates the link.
    private static let titleQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+ ()")
        return set
    }()

    /// Allowed characters for the URL fragment (everything after `#`). Keeps
    /// alphanumeric + common punctuation; `#`, `"`, space, and `%` are encoded so
    /// they don't terminate the fragment or confuse URL parsing. `(` / `)` are
    /// also escaped: the URL lands inside a Markdown `[text](url)` destination,
    /// and an unbalanced `)` (e.g. a fragment with `1.) 2.)`) would otherwise end
    /// the link early and dump the rest of the URL as literal text.
    private static let fragmentAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.remove(charactersIn: "#\" %()")
        return set
    }()

    // protectedCodeRanges, isInside, and backtick live in WikiLinkSpan (shared).
}
