import Foundation

/// Pure, dependency-free parser for `[[wiki-link]]` syntax (INITIAL §4 v1).
///
/// Kept deliberately free of any storage / File Provider knowledge so it is
/// trivially unit-testable: it turns a Markdown body into the list of links it
/// mentions. Resolution of a target *title* to a concrete page id, and writing
/// the `page_links` rows, happens in `SQLiteWikiStore` — parsing is pure, the
/// write is the store's job.
///
/// Supported forms:
///   * `[[Title]]`            → target = "Title",  linkText = "Title"
///   * `[[Target|alias]]`     → target = "Target", linkText = "alias"
///   * `[[source:Name]]`      → linkType = .source, target = "Name"
///   * `[[page:Title]]`       → linkType = .page (explicit; escape hatch)
///
/// Rules:
///   * the target has its internal whitespace collapsed and ends trimmed;
///   * empty targets (e.g. `[[ ]]`) are skipped;
///   * the `source:` / `page:` prefix is stripped from the target *only* (never
///     the alias); the remainder is re-normalized;
///   * duplicate targets are de-duplicated per `(kind, target)`, FIRST occurrence
///     wins (so the first alias seen for a target is the one kept);
///   * unmatched / malformed brackets are ignored.
public enum WikiLinkParser {

    /// A single parsed link reference: the kind + the bare target (prefix-stripped)
    /// and the display text to record in the link tables.
    public struct ParsedLink: Equatable, Sendable {
        public enum LinkType: String, Equatable, Sendable { case page, source }

        public let linkType: LinkType
        public let target: String       // prefix-stripped, whitespace-collapsed (BASE only)
        public let fragment: String?    // everything after the first "#", verbatim; nil if none
        public let linkText: String     // alias verbatim (never prefix-stripped)

        /// `linkType` defaults to `.page` so every existing `ParsedLink(target:linkText:)`
        /// call site compiles unchanged and equality holds (both sides default to `.page`).
        public init(linkType: LinkType = .page, target: String,
                    fragment: String? = nil, linkText: String) {
            self.linkType = linkType
            self.target = target
            self.fragment = fragment
            self.linkText = linkText
        }
    }

    // [[ target (no ] or |) ( | alias (no ]) )? ]]
    private static let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    // MARK: - Prefix classification

    /// Split a whitespace-collapsed target into its (kind, bare-target). Reserved
    /// prefixes: `page:` (explicit page link / escape) takes precedence over `source:`,
    /// so a page literally titled "source:foo" is linkable as `[[page:source:foo]]`.
    /// The remainder is re-normalized so `[[source: X]]` → ("X"), not (" X").
    public static func classify(_ target: String) -> (ParsedLink.LinkType, String) {
        if let rest = peel(prefix: "page:", off: target)   { return (.page,   WikiText.normalized(rest)) }
        if let rest = peel(prefix: "source:", off: target) { return (.source, WikiText.normalized(rest)) }
        return (.page, target) // target already normalized by the caller
    }

    /// True when `target` starts with a reserved prefix (`source:` or `page:`) but
    /// the remainder is empty/whitespace (e.g. `[[source:]]`, `[[page:   ]]`). Both
    /// parse() and WikiLinkMarkdown.linkified() use this to emit literal text.
    public static func isEmptyPrefix(_ target: String) -> Bool {
        for prefix in ["page:", "source:"] {
            guard target.hasPrefix(prefix) else { continue }
            let rest = String(target.dropFirst(prefix.count))
            return rest.allSatisfy(\.isWhitespace)
        }
        return false
    }

    /// Split a raw target on the **first** `#` only. Everything before → `base`
    /// (may be empty for `[[#Section]]`), everything after → `fragment` (kept
    /// verbatim; inner `#` characters — e.g. `"C# is a language"` — are preserved
    /// for substring matching). Returns `(base: "", fragment: "Section")` for a
    /// same-page anchor `[[#Section]]`. Returns `(base: rawTarget, nil)` when there
    /// is no `#`.
    public static func splitFragment(_ rawTarget: String) -> (base: String, fragment: String?) {
        guard let hashIndex = rawTarget.firstIndex(of: "#") else {
            return (rawTarget, nil)
        }
        let base = String(rawTarget[..<hashIndex])
        let frag = String(rawTarget[rawTarget.index(after: hashIndex)...])
        // Never normalize the fragment — it's kept verbatim so inner `#` and
        // whitespace survive for quote matching. The caller trims surrounding `"`
        // at resolution time (§4).
        return (base, frag.isEmpty ? nil : frag)
    }

    private static func peel(prefix: String, off s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = String(s.dropFirst(prefix.count))
        return rest.allSatisfy(\.isWhitespace) ? nil : rest // `[[source:]]` → not a source link
    }

    // MARK: - Parse

    /// Parse all wiki links from `body`, in document order, de-duplicated by
    /// `(kind, target)` (first alias wins). Same-page anchors (`[[#…]]`, empty
    /// base) are skipped — they don't name a page or source, so they don't belong
    /// in the link graph.
    public static func parse(_ body: String) -> [ParsedLink] {
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [ParsedLink] = []

        for match in matches {
            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            
            let validated = WikiLinkValidator.validate(target: rawTarget, alias: rawAlias)
            
            let collapsed = collapseWhitespace(validated.target)
            guard !collapsed.isEmpty else { continue }

            // Split on first "#" BEFORE classifying — so `[[#Section]]` yields
            // empty base (same-page, skipped here; handled in linkified) and
            // `[[source:X#"quote"]]` yields base:"source:X" + fragment:""quote"".
            let (base, fragment) = splitFragment(collapsed)
            guard !base.isEmpty else { continue } // same-page anchor → skip

            let (kind, bareTarget) = classify(base)
            guard !bareTarget.isEmpty else { continue } // empty target → skip
            if isEmptyPrefix(base) { continue } // `[[source:]]` → literal

            let dedupKey = "\(kind.rawValue):\(bareTarget)"
            guard seen.insert(dedupKey).inserted else { continue }

            let linkText: String
            if let alias = validated.alias {
                let collapsedAlias = collapseWhitespace(alias)
                linkText = collapsedAlias.isEmpty ? bareTarget : collapsedAlias
            } else {
                linkText = bareTarget
            }
            out.append(ParsedLink(linkType: kind, target: bareTarget,
                                  fragment: fragment, linkText: linkText))
        }
        return out
    }

    /// Collapse runs of whitespace to a single space and trim the ends — delegates
    /// to the single shared normalizer.
    private static func collapseWhitespace(_ s: String) -> String {
        WikiText.normalized(s)
    }
}
