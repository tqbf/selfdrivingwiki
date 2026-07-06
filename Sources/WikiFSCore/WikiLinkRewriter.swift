import Foundation

/// Pure, dependency-free helper that canonicalizes `[[wiki-link]]` targets to
/// ULID-stable form at save time (Phase 5). Reuses `WikiLinkSpan` for the regex
/// and code-range detection, and `WikiLinkParser`/`WikiLinkResolver` for
/// classification and resolution.
public enum WikiLinkRewriter {

    private static let hashChar: unichar = 0x23 // #

    // MARK: - Canonicalization (Phase 5)

    /// Rewrite each resolvable `[[…]]` span in `body` to canonical
    /// `[[page:<ULID>|alias]]` / `[[source:<ULID>|alias]]` form, preserving the
    /// `|alias`, the `#fragment`, and the `!` embed prefix. Unresolvable
    /// (forward) links are left byte-identical. Code-fence-safe (spans inside a
    /// backtick code span or fenced block are skipped). Idempotent:
    /// canonicalizing an already-canonical body is a no-op. Returns `nil` when
    /// nothing changed (so callers can skip the re-save).
    ///
    /// Resolution mirrors `WikiLinkMarkdown.linkified` exactly: longest-name-wins
    /// via `WikiLinkResolver.candidateSplits`, so a name containing `#` resolves
    /// whole. When a span has an existing `|alias`, ONLY the target slice is
    /// rewritten (the alias is left byte-for-byte). When there is no alias, the
    /// human text is preserved by inserting `|<bareTarget>` so the author's
    /// display text survives (it self-heals to the current title at render).
    public static func canonicalize(
        in body: String,
        resolvePage: (String) throws -> PageID?,
        resolveSource: (String) throws -> PageID?
    ) throws -> String? {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.regex.matches(
            in: body, range: NSRange(location: 0, length: ns.length))

        var result = body
        var changed = false

        // Walk right-to-left so byte offsets stay valid across splices.
        for match in matches.reversed() {
            let fullRange = match.range
            guard !WikiLinkSpan.isProtected(fullRange, by: codeRanges) else { continue }

            let targetRange = match.range(at: 1)
            let aliasRange = match.range(at: 2)
            let rawTarget = ns.substring(with: targetRange)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil

            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsed = WikiText.normalized(fixed.target)
            guard !collapsed.isEmpty else { continue }

            // Split on first "#" BEFORE classifying — shared with the parser.
            let (base, fragment) = WikiLinkParser.splitFragment(collapsed)
            guard !base.isEmpty else { continue } // same-page anchor → skip

            // Phase 6: strip the trailing `@vN` pin BEFORE classifying so a
            // `ULID@v3` (29 chars) passes the 26-char ULID fast-path instead of
            // being mis-classified as an unresolved name. The pin is preserved
            // verbatim and re-attached to the canonical target below.
            let (bareBase, pin) = WikiLinkParser.splitVersionPin(base)

            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
            guard !bareTarget.isEmpty, !WikiLinkParser.isEmptyPrefix(bareBase) else { continue }

            // Idempotency fast path: already canonical → leave untouched.
            if WikiLinkParser.isCanonicalULID(bareTarget) { continue }

            // Resolve (longest-name-wins). Walk candidate splits ourselves so we
            // capture the id in a single pass (resolvedSplit only yields a Split,
            // not the id). Unresolved → forward link, leave byte-identical.
            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget
            var resolved: (id: PageID, fragment: String?)?
            for split in WikiLinkResolver.candidateSplits(of: raw) {
                if let id = try kind == .source
                    ? resolveSource(split.base)
                    : resolvePage(split.base) {
                    resolved = (id, split.fragment)
                    break
                }
            }
            guard let (resolvedID, resolvedFragment) = resolved else { continue }

            // Canonical target portion: kind:ULID (+ @vN pin + #fragment if any).
            // Phase 6: the pin is preserved verbatim (`@v3`), not resolved here —
            // it stays in the body as the per-occurrence source of truth.
            let prefix = kind == .source ? "source:" : "page:"
            let canonicalTarget = prefix + resolvedID.rawValue
                + (pin.map { "@v\($0)" } ?? "")
                + (resolvedFragment.map { "#\($0)" } ?? "")

            if rawAlias != nil {
                // Alias exists: surgical — replace ONLY the target slice, leaving
                // the `|alias` byte-for-byte where it is.
                let mutable = NSMutableString(string: result)
                mutable.replaceCharacters(in: targetRange, with: canonicalTarget)
                result = mutable as String
            } else {
                // No alias: insert `|<bareTarget>` so the human text survives.
                let replacement = "[[\(canonicalTarget)|\(bareTarget)]]"
                let mutable = NSMutableString(string: result)
                mutable.replaceCharacters(in: fullRange, with: replacement)
                result = mutable as String
            }
            changed = true
        }

        return changed ? result : nil
    }
}
