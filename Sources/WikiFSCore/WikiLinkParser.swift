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
///
/// Rules:
///   * the target has its internal whitespace collapsed and ends trimmed;
///   * empty targets (e.g. `[[ ]]`) are skipped;
///   * duplicate targets are de-duplicated, FIRST occurrence wins (so the first
///     alias seen for a target is the one kept);
///   * unmatched / malformed brackets are ignored.
public enum WikiLinkParser {

    /// A single parsed link reference: the raw target *title* (not yet resolved
    /// to a page id) and the display text to record in `page_links.link_text`.
    public struct ParsedLink: Equatable, Sendable {
        public let target: String
        public let linkText: String

        public init(target: String, linkText: String) {
            self.target = target
            self.linkText = linkText
        }
    }

    // [[ target (no ] or |) ( | alias (no ]) )? ]]
    private static let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// Parse all wiki links from `body`, in document order, de-duplicated by
    /// target (first alias wins).
    public static func parse(_ body: String) -> [ParsedLink] {
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var seenTargets = Set<String>()
        var out: [ParsedLink] = []

        for match in matches {
            let rawTarget = ns.substring(with: match.range(at: 1))
            let target = collapseWhitespace(rawTarget)
            guard !target.isEmpty else { continue }
            guard seenTargets.insert(target).inserted else { continue }

            let aliasRange = match.range(at: 2)
            let linkText: String
            if aliasRange.location != NSNotFound {
                let alias = collapseWhitespace(ns.substring(with: aliasRange))
                linkText = alias.isEmpty ? target : alias
            } else {
                linkText = target
            }
            out.append(ParsedLink(target: target, linkText: linkText))
        }
        return out
    }

    /// Collapse runs of whitespace to a single space and trim the ends — the
    /// same normalization the title escaping uses, so `[[ Home ]]` resolves to
    /// the `Home` page.
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
