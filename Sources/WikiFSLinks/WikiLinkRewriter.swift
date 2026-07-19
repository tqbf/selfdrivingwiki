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
        resolveSource: (String) throws -> PageID?,
        resolveChat: (String) throws -> PageID? = { _ in nil }
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

            // Issue #619: try-resolve-whole at the canonicalize seam. When the
            // regex split target|alias but the real display name contains a
            // literal `|` (common with YouTube titles the app itself ingests,
            // e.g. `But what is cross-entropy? | Compression is Intelligence
            // Part 2`), the split target is truncated and never resolves. So
            // BEFORE treating `|` as the alias separator, reconstruct the
            // whole name (`bareTarget` + `|` + normalized alias) and ask the
            // injected resolvers. If it matches (Pass 1: exact case-insensitive
            // `display_name` match), canonicalize as a single target whose
            // auto-alias is the whole reconstructed name — mirroring the
            // no-alias branch so the user's intended display text survives.
            //
            // Scoped to the no-fragment / no-pin case (the issue's repro) to
            // avoid fragment-in-alias ambiguity; `#`-in-name already resolves
            // via `candidateSplits` below. If neither candidate resolves, fall
            // through to today's behavior (`|` was a real alias separator).
            if rawAlias != nil, fragment == nil, pin == nil,
               let rawAliasValue = fixed.alias {
                let normalizedAlias = WikiText.normalized(rawAliasValue)
                if !normalizedAlias.isEmpty {
                    // Try spaced first (the YouTube-title convention), then the
                    // unspaced form — both hit Pass 1's exact match. The first
                    // resolver hit determines which reconstruction we serialize
                    // as the auto-alias, so what the user sees rendered matches
                    // the store's display_name spelling.
                    let candidates = [
                        "\(bareTarget) | \(normalizedAlias)",
                        "\(bareTarget)|\(normalizedAlias)",
                    ]
                    var wholeID: PageID? = nil
                    var wholeName: String? = nil
                    for candidate in candidates {
                        let id: PageID?
                        switch kind {
                        case .source: id = try resolveSource(candidate)
                        case .chat:   id = try resolveChat(candidate)
                        case .page:   id = try resolvePage(candidate)
                        }
                        if let id {
                            wholeID = id
                            wholeName = candidate
                            break
                        }
                    }
                    if let resolvedID = wholeID, let resolvedName = wholeName {
                        let prefix = kind.linkPrefix
                        let canonicalTarget = prefix + resolvedID.rawValue
                        let replacement = "[[\(canonicalTarget)|\(resolvedName)]]"
                        let mutable = NSMutableString(string: result)
                        mutable.replaceCharacters(in: fullRange, with: replacement)
                        result = mutable as String
                        changed = true
                        continue
                    }
                }
            }

            // Resolve (longest-name-wins). Walk candidate splits ourselves so we
            // capture the id in a single pass (resolvedSplit only yields a Split,
            // not the id). Unresolved → forward link, leave byte-identical.
            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget
            var resolved: (id: PageID, fragment: String?)?
            for split in WikiLinkResolver.candidateSplits(of: raw) {
                let id: PageID?
                switch kind {
                case .source: id = try resolveSource(split.base)
                case .chat:   id = try resolveChat(split.base)
                case .page:   id = try resolvePage(split.base)
                }
                if let id {
                    resolved = (id, split.fragment)
                    break
                }
            }
            guard let (resolvedID, resolvedFragment) = resolved else { continue }

            // Canonical target portion: kind:ULID (+ @vN pin + #fragment if any).
            // Phase 6: the pin is preserved verbatim (`@v3`), not resolved here —
            // it stays in the body as the per-occurrence source of truth.
            let prefix = kind.linkPrefix
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
