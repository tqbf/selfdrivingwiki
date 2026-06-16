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
///   * a target that resolves → `wiki://page?title=<encoded>` (a live link);
///   * a target that does NOT  → `wiki://missing?title=<encoded>` (still a link
///     so the view can style it dimmed, but the click handler no-ops on it).
public enum WikiLinkMarkdown {

    /// The private scheme the in-app `OpenURLAction` intercepts. Real external
    /// links (https, mailto, …) fall through to `.systemDefault`.
    public static let scheme = "wiki"
    /// Host for a link whose target resolves to a real page (navigates).
    public static let resolvedHost = "page"
    /// Host for a link whose target has no page (rendered dimmed, inert).
    public static let unresolvedHost = "missing"

    // Same grammar as WikiLinkParser.pattern: [[ target (no ] or |) (| alias)? ]]
    private static let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// Rewrite all `[[…]]` spans in `body` to Markdown links, EXCEPT those that
    /// fall inside a backtick code span or fenced code block (where `[[…]]` is
    /// literal text the user wants shown verbatim). The display text is the alias
    /// when present (else the target); the URL always carries the URL-encoded
    /// *target* title.
    ///
    /// - Parameters:
    ///   - body: the raw page Markdown (with literal `[[…]]`).
    ///   - isResolved: returns `true` if a target title maps to an existing page.
    ///                 Receives the whitespace-collapsed target (same form
    ///                 `WikiLinkParser` and `resolveTitleToID` use).
    /// - Returns: Markdown safe to hand to `AttributedString(markdown:)`.
    public static func linkified(
        _ body: String,
        isResolved: (String) -> Bool = { _ in true }
    ) -> String {
        let ns = body as NSString
        let codeRanges = protectedCodeRanges(in: body)
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

            let target = collapseWhitespace(ns.substring(with: match.range(at: 1)))
            guard !target.isEmpty else {
                // Empty target (e.g. `[[ ]]`): leave the literal text in place.
                out += ns.substring(with: full)
                continue
            }

            let aliasRange = match.range(at: 2)
            let display: String
            if aliasRange.location != NSNotFound {
                let alias = collapseWhitespace(ns.substring(with: aliasRange))
                display = alias.isEmpty ? target : alias
            } else {
                display = target
            }

            out += markdownLink(display: display, target: target, resolved: isResolved(target))
        }
        // Tail after the last match.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// The `wiki://…` URL for a given target title, or nil if `url` is not one of
    /// ours. Used by the view's `OpenURLAction` to pull the title back out.
    public static func target(from url: URL) -> String? {
        guard url.scheme == scheme,
              let host = url.host,
              host == resolvedHost || host == unresolvedHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let title = components.queryItems?.first(where: { $0.name == "title" })?.value,
              !title.isEmpty
        else { return nil }
        return title
    }

    /// True if `url` points at a page that resolved (i.e. should navigate). An
    /// unresolved (`missing`) link is one of ours but inert.
    public static func isResolvedURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == resolvedHost
    }

    // MARK: - Helpers

    private static func markdownLink(display: String, target: String, resolved: Bool) -> String {
        let host = resolved ? resolvedHost : unresolvedHost
        // Encode the title for the query value, and escape any `]`/`)` in the
        // display text so it can't break the Markdown `[text](url)` grammar.
        let encodedTitle = target.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed)
            ?? target
        let safeDisplay = display
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(safeDisplay)](\(scheme)://\(host)?title=\(encodedTitle))"
    }

    /// Collapse whitespace runs to one space and trim — identical to
    /// `WikiLinkParser` so a target linkifies to the same title it resolves to.
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Allowed characters for the `title=` query value. Start from the URL query
    /// set and remove the sub-delimiters that have query meaning, so a `&`, `=`,
    /// `?`, `#`, `+`, or space in a title is percent-escaped rather than parsed.
    private static let titleQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+ ")
        return set
    }()

    /// Ranges of the body that are inside an inline code span (`` `…` ``) or a
    /// fenced code block (``` ```…``` ```), where `[[…]]` must NOT be linkified.
    /// A deliberately small scanner: it handles the two CommonMark code forms the
    /// preview actually shows; it does not model indented (4-space) code blocks,
    /// which the preview's inline-only parse doesn't render as code anyway.
    private static func protectedCodeRanges(in body: String) -> [NSRange] {
        let ns = body as NSString
        var ranges: [NSRange] = []

        // 1) Fenced blocks: a line starting with ``` opens; the next such line
        //    (or end of text) closes. Whole span (incl. fences) is protected.
        let lines = body.components(separatedBy: "\n")
        var offset = 0
        var fenceStart: Int? = nil
        for line in lines {
            let lineLen = (line as NSString).length
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: (offset + lineLen) - start))
                    fenceStart = nil
                } else {
                    fenceStart = offset
                }
            }
            offset += lineLen + 1 // + the "\n" we split on
        }
        if let start = fenceStart {
            ranges.append(NSRange(location: start, length: ns.length - start))
        }

        // 2) Inline code spans: backtick runs of length N delimit a span that
        //    closes on the next run of exactly N backticks. We skip any region
        //    already covered by a fence.
        var i = 0
        while i < ns.length {
            if isInside(i, ranges) { i += 1; continue }
            if ns.character(at: i) == backtick {
                var runLen = 0
                while i + runLen < ns.length, ns.character(at: i + runLen) == backtick { runLen += 1 }
                let spanOpen = i
                var j = i + runLen
                var closed = false
                while j < ns.length {
                    if ns.character(at: j) == backtick {
                        var closeLen = 0
                        while j + closeLen < ns.length, ns.character(at: j + closeLen) == backtick { closeLen += 1 }
                        if closeLen == runLen {
                            ranges.append(NSRange(location: spanOpen, length: (j + closeLen) - spanOpen))
                            i = j + closeLen
                            closed = true
                            break
                        }
                        j += closeLen
                    } else {
                        j += 1
                    }
                }
                if !closed { i = spanOpen + runLen } // unterminated run: not a span
            } else {
                i += 1
            }
        }
        return ranges
    }

    private static let backtick: unichar = 0x60 // `

    private static func isInside(_ index: Int, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(index, $0) }
    }
}
