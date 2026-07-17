import Foundation

/// Pure text transforms shared across the wiki subsystem. Home of the single
/// whitespace normalizer (replaces the three private `collapseWhitespace` copies
/// that previously lived in WikiLinkParser, WikiLinkMarkdown, and HTMLToMarkdown).
public enum WikiText {

    /// Collapse whitespace runs to one space and trim ends. The same
    /// normalization the title escaping and link resolution use, so
    /// `[[ Home ]]` resolves to the `Home` page.
    public static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
