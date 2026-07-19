import Foundation

/// Pure, AppKit-free detector for an **open** (in-progress) `[[kind:partial`
/// wiki-link trigger at the caret. The autocomplete's per-keystroke entry point:
/// given the full composer text and a caret offset, returns the open-link trigger
/// to query Tantivy for, or `nil` when the caret is not inside an open link.
///
/// Why this exists alongside `WikiLinkParser`: `WikiLinkParser` only matches
/// **closed** `[[…]]` spans (its regex requires the closing `]]`); while the
/// user is typing `[[page:Erl` there is no `]]`, so the parser is blind. This
/// scanner is the caret-based counterpart that fires the autocomplete.
///
/// Lives in `WikiFSLinks` (Foundation-only; depends only on `WikiFSTypes` for
/// `ParsedLink.LinkType.linkPrefix`) so it is trivially unit-testable without
/// AppKit or the store. The composer coordinator calls this from
/// `textDidChange`, then hands the result to the Tantivy autocomplete service.
public enum WikiLinkPrefixScanner {

    /// The maximum length of the `[[…partial` substring the scanner will accept
    /// before bailing. Guards against a long paste (e.g. dropping 200 lines of
    /// markdown that happens to begin with `[[page:`) spuriously firing the
    /// autocomplete. 80 chars comfortably covers realistic page titles while
    /// catching the paste case (issue #638 reviewer correction #4).
    public static let maxPartialSpan: Int = 80

    /// The open-link trigger returned by ``openLink(at:in:)``.
    public struct OpenWikiLink: Equatable, Sendable {
        public let kind: ParsedLink.LinkType   // .page/.source/.chat, from the `kind:` prefix
        public let partial: String             // text after "kind:" up to the caret, trimmed
        /// Span of `[[kind:partial` in the source string to replace on
        /// selection. The caller replaces this exact range with the canonical
        /// `[[kind:ULID|Title]]` form (`DroppedLinkFormatter.link(...)`).
        public let range: Range<String.Index>

        public init(kind: ParsedLink.LinkType, partial: String, range: Range<String.Index>) {
            self.kind = kind
            self.partial = partial
            self.range = range
        }
    }

    /// Detect an open `[[kind:partial` trigger ending at `caret` in `text`.
    ///
    /// Rules (mirror `WikiLinkParser`'s grammar so they can't drift):
    /// 1. Scan backward from the caret for the most recent `[[`.
    /// 2. If a `]]` or `|` appears after that `[[` and before the caret, it's
    ///    a closed/aliased link → return `nil`.
    /// 3. Take the substring between `[[` and the caret.
    ///    - **Reviewer correction #4:** if it contains a newline OR is longer
    ///      than ``maxPartialSpan``, return `nil` (multi-line + paste guard).
    /// 4. Match an optional kind prefix (`page:`/`source:`/`chat:`) using the
    ///    `ParsedLink.LinkType.linkPrefix` strings. If none matches, default
    ///    `kind = .page` (bare `[[Foo` is a page link, per
    ///    `WikiLinkParser.classify` `:52`).
    /// 5. `partial` = the remainder after the prefix, whitespace-trimmed.
    ///    Return `nil` when `partial` is empty (don't fire on bare `[[page:`).
    public static func openLink(at caret: Int, in text: String) -> OpenWikiLink? {
        guard caret >= 0, caret <= text.count else { return nil }
        let characters = Array(text)
        guard caret <= characters.count else { return nil }

        // Scan backward from the caret for the most recent `[[`.
        var openBraceIndex: Int? = nil
        var i = caret - 1
        while i >= 1 {
            if characters[i] == "]" && i >= 1 && characters[i - 1] == "]" {
                // Closed link before the caret — we're outside any open link.
                return nil
            }
            if characters[i] == "[" && characters[i - 1] == "[" {
                openBraceIndex = i - 1
                break
            }
            i -= 1
        }
        guard let openIdx = openBraceIndex else { return nil }

        // Substring between `[[` (exclusive) and caret (exclusive).
        // After this point characters[openIdx] == "[" and characters[openIdx+1] == "[".
        let innerStart = openIdx + 2
        if innerStart > caret { return nil }

        // Reviewer correction #4: bail on newline or over-cap substring (paste /
        // multi-line guard). Use the inner span length first as a cheap reject.
        let innerLength = caret - innerStart
        if innerLength > maxPartialSpan { return nil }
        if innerLength <= 0 { return nil }

        // Build the inner substring; reject newlines and pipe (alias start).
        // `|` would mean we've crossed into the alias of a closed-shaped link.
        var inner = ""
        inner.reserveCapacity(innerLength)
        for j in innerStart..<caret {
            let c = characters[j]
            if c == "\n" || c == "\r" { return nil }
            if c == "|" { return nil }
            inner.append(c)
        }

        // Strip a trailing `]]` (the user may have just closed the link; we
        // don't want to fire autocomplete once the link is complete and the
        // caret is past it). Actually the backward scan already bailed on `]]`
        // before the caret — but a trailing `]` inside `inner` could still
        // exist if the caret sits between two `]`s. Be defensive.
        if inner.hasSuffix("]") { return nil }

        // Match an optional kind prefix.
        var kind: ParsedLink.LinkType = .page
        var remainder = inner
        for candidate in ParsedLink.LinkType.allCases {
            let prefix = candidate.linkPrefix // "page:" / "source:" / "chat:"
            if remainder.hasPrefix(prefix) {
                kind = candidate
                remainder = String(remainder.dropFirst(prefix.count))
                break
            }
        }

        // Trim and require non-empty.
        let partial = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return nil }

        // Convert the open-link span to String.Index range for the caller's
        // range-replace API.
        guard let lower = text.index(text.startIndex,
                                     offsetBy: openIdx,
                                     limitedBy: text.endIndex),
              let upper = text.index(text.startIndex,
                                     offsetBy: caret,
                                     limitedBy: text.endIndex) else {
            return nil
        }
        return OpenWikiLink(
            kind: kind,
            partial: partial,
            range: lower..<upper)
    }
}
