import Foundation

/// Pure, dependency-free helper that converts `[[wiki-link]]` spans pointing at
/// a set of deleted targets into their plain display text (issue #219).
///
/// When a page or source is deleted, every other page that links to it is left
/// with a now-broken `[[…]]` (a "ghost link"). `unlink(in:…)` rewrites those
/// spans to the visible text the link would have rendered (the `|alias` when one
/// was authored, otherwise the bare target name), so the body reads naturally
/// instead of showing dead links.
///
/// Structurally a sibling of `WikiLinkRewriter.canonicalize`: it reuses
/// `WikiLinkSpan` for the regex + code-range detection and `WikiLinkParser` for
/// classification/fragment/pin handling, walks matches right-to-left so byte
/// offsets stay valid across splices, and returns `nil` when nothing changed
/// (so callers skip the re-save). Resolution of a *name* target to an id is
/// injected, keeping the function pure and unit-testable without a store.
public enum LinkUnlinker {

    /// Convert every `[[…]]` / `![[…]]` span whose resolved target is one of
    /// `unlinkPageIDs` / `unlinkSourceIDs` to its plain display text. The
    /// display text is the authored `|alias` when present (and non-empty),
    /// otherwise the bare target name — matching `WikiLinkParser`'s `linkText`
    /// derivation. Embed prefixes (`![[…]]`) are consumed along with the span
    /// so an embed becomes plain text rather than a stray `!`.
    ///
    /// Targets are matched two ways:
    /// 1. **Canonical ULID** (`[[page:<ULID>…]]`): direct membership test
    ///    against the id set — no resolution needed (and stable across renames).
    /// 2. **Name** (`[[Page Title]]`): resolved via the injected closures; the
    ///    returned id is tested for membership. Name matching only fires while
    ///    the target still exists, so callers should unlink BEFORE deleting.
    ///
    /// Chat links are never touched (they are not in either unlink set). Spans
    /// inside a code fence or inline code span are left literal. Returns `nil`
    /// when no span matched, so callers can skip the re-save.
    ///
    /// - Parameters:
    ///   - body: The markdown body to rewrite.
    ///   - unlinkPageIDs: Page ids whose incoming links should become plain text.
    ///   - unlinkSourceIDs: Source ids whose incoming links should become plain text.
    ///   - resolvePageName: Resolves a page *title* to its id (nil if unknown).
    ///   - resolveSourceName: Resolves a source *name* to its id (nil if unknown).
    /// - Returns: The rewritten body, or `nil` when nothing changed.
    public static func unlink(
        in body: String,
        unlinkPageIDs: Set<PageID>,
        unlinkSourceIDs: Set<SourceID>,
        resolvePageName: (String) throws -> PageID?,
        resolveSourceName: (String) throws -> SourceID?
    ) throws -> String? {
        guard !unlinkPageIDs.isEmpty || !unlinkSourceIDs.isEmpty else { return nil }

        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.regex.matches(
            in: body, range: NSRange(location: 0, length: ns.length))

        var result = body
        var changed = false

        // Walk right-to-left so byte offsets stay valid across splices (same
        // discipline as `WikiLinkRewriter.canonicalize`).
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

            // Split on the first "#" before classifying — same as the parser, so
            // `[[source:X#"quote"]]` yields base "source:X" and a same-page
            // anchor (`[[#…]]`, empty base) is skipped.
            let (base, _) = WikiLinkParser.splitFragment(collapsed)
            guard !base.isEmpty else { continue }

            // Strip a trailing `@vN` version pin before classifying so a pinned
            // canonical target (`ULID@v3`) still passes the ULID fast-path.
            let (bareBase, _) = WikiLinkParser.splitVersionPin(base)

            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
            guard !bareTarget.isEmpty, !WikiLinkParser.isEmptyPrefix(bareBase) else { continue }

            // Resolve this span's target to an id, then test membership.
            let matchedID: Bool
            switch kind {
            case .page:
                matchedID = try matchesDeleted(
                    bareTarget: bareTarget, in: unlinkPageIDs,
                    resolveName: resolvePageName)
            case .source:
                matchedID = try matchesDeleted(
                    bareTarget: bareTarget, in: unlinkSourceIDs,
                    resolveName: resolveSourceName)
            case .chat:
                continue // chat links are never unlinked here
            }
            guard matchedID else { continue }

            // Display text: authored alias (if non-empty), else the bare target
            // name — mirroring `WikiLinkParser`'s `linkText` derivation.
            let display: String
            if let alias = fixed.alias {
                let collapsedAlias = WikiText.normalized(alias)
                display = collapsedAlias.isEmpty ? bareTarget : collapsedAlias
            } else {
                display = bareTarget
            }

            // Splice the span. Consume a preceding `!` embed prefix so an embed
            // (`![[source:X]]`) becomes plain text rather than a stray `!`.
            let isEmbed = WikiLinkSpan.isEmbedPrefix(ns, fullRange)
            let spliceRange = isEmbed
                ? NSRange(location: fullRange.location - 1, length: fullRange.length + 1)
                : fullRange
            let mutable = NSMutableString(string: result)
            mutable.replaceCharacters(in: spliceRange, with: display)
            result = mutable as String
            changed = true
        }

        return changed ? result : nil
    }

    /// True when `bareTarget` identifies a member of `deletedIDs` — either
    /// directly (a canonical ULID in the set) or by resolving its name to an id
    /// that is in the set.
    private static func matchesDeleted<ID: RawRepresentable>(
        bareTarget: String,
        in deletedIDs: Set<ID>,
        resolveName: (String) throws -> ID?
    ) throws -> Bool where ID.RawValue == String {
        if WikiLinkParser.isCanonicalULID(bareTarget),
           let id = ID(rawValue: bareTarget) {
            return deletedIDs.contains(id)
        }
        // Name-based link: resolve to an id and test membership. Resolution is
        // only meaningful while the target still exists; callers unlink before
        // deleting, so a name still resolves to the about-to-be-deleted id.
        if let resolved = try resolveName(bareTarget) {
            return deletedIDs.contains(resolved)
        }
        return false
    }
}
