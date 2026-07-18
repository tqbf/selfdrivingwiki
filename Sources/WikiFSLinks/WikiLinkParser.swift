import Foundation

/// Pure, dependency-free parser for `[[wiki-link]]` syntax (INITIAL §4 v1).
///
/// Kept deliberately free of any storage / File Provider knowledge so it is
/// trivially unit-testable: it turns a Markdown body into the list of links it
/// mentions. Resolution of a target *title* to a concrete page id, and writing
/// the `page_links` rows, happens in `GRDBWikiStore` — parsing is pure, the
/// write is the store's job.
///
/// Supported forms:
///   * `[[Title]]`            → target = "Title",  linkText = "Title"
///   * `[[Target|alias]]`     → target = "Target", linkText = "alias"
///   * `[[source:Name]]`      → linkType = .source, target = "Name"
///   * `[[chat:Title]]`       → linkType = .chat, target = "Title"
///   * `[[page:Title]]`       → linkType = .page (explicit; escape hatch)
///
/// Rules:
///   * the target has its internal whitespace collapsed and ends trimmed;
///   * empty targets (e.g. `[[ ]]`) are skipped;
///   * the `source:` / `page:` prefix is stripped from the target *only* (never
///     the alias); the remainder is re-normalized;
///   * duplicate targets are de-duplicated per `(kind, raw target)` — base plus
///     fragment — FIRST occurrence wins (so the first alias seen is kept);
///   * unmatched / malformed brackets are ignored.
public enum WikiLinkParser {

    /// The role of a source-link edge (`source_links.role`): a citation
    /// (`[[source:…]]`) or an embed (`![[source:…]]`). Typed (not a raw
    /// string) so the SQL read/write seam can't silently mis-bind (issue #501).
    public enum LinkRole: String, Sendable, CaseIterable {
        case cite
        case embed
    }

    // [[ target (no ] or | outside a "quoted" run) ( | alias (no ]) )? ]]
    // Kept in sync with WikiLinkSpan.pattern (shared grammar, two copies so
    // WikiLinkSpan doesn't need to depend on this parser).
    private static let pattern = #"\[\[((?:[^\]\|"]|"[^"]*")+)(?:\|([^\]]+))?\]\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    // MARK: - Prefix classification

    /// Split a whitespace-collapsed target into its (kind, bare-target). Reserved
    /// prefixes: `page:` (explicit page link / escape) takes precedence over `source:`,
    /// so a page literally titled "source:foo" is linkable as `[[page:source:foo]]`.
    /// The remainder is re-normalized so `[[source: X]]` → ("X"), not (" X").
    public static func classify(_ target: String) -> (ParsedLink.LinkType, String) {
        if let rest = peel(prefix: ParsedLink.LinkType.page.linkPrefix, off: target)   { return (.page,   WikiText.normalized(rest)) }
        if let rest = peel(prefix: ParsedLink.LinkType.source.linkPrefix, off: target) { return (.source, WikiText.normalized(rest)) }
        if let rest = peel(prefix: ParsedLink.LinkType.chat.linkPrefix, off: target)   { return (.chat,   WikiText.normalized(rest)) }
        return (.page, target) // target already normalized by the caller
    }

    /// True when `target` starts with a reserved prefix (`source:` or `page:`) but
    /// the remainder is empty/whitespace (e.g. `[[source:]]`, `[[page:   ]]`). Both
    /// parse() and WikiLinkMarkdown.linkified() use this to emit literal text.
    public static func isEmptyPrefix(_ target: String) -> Bool {
        for kind in ParsedLink.LinkType.allCases {
            let prefix = kind.linkPrefix
            guard target.hasPrefix(prefix) else { continue }
            let rest = String(target.dropFirst(prefix.count))
            return rest.allSatisfy { $0.isWhitespace }
        }
        return false
    }

    /// Split a raw target into `base` + `fragment`. The delimiter is the first
    /// `#"` (the start of a quote anchor, `[[source:Name#"quote"]]`) when one is
    /// present — so a bare `#` inside the NAME (e.g. "Agentic Static Analysis
    /// for C# Security Auditing") stays part of the base instead of truncating
    /// it. With no `#"`, the first `#` splits (`[[Page#Section]]`). The base may
    /// be empty for a same-page anchor `[[#Section]]`; the fragment is kept
    /// verbatim (inner `#` characters — e.g. `"C# is a language"` — are
    /// preserved for substring matching). Returns `(base: rawTarget, nil)` when
    /// there is no `#`.
    public static func splitFragment(_ rawTarget: String) -> (base: String, fragment: String?) {
        guard let hashIndex = rawTarget.range(of: "#\"")?.lowerBound
                ?? rawTarget.firstIndex(of: "#") else {
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

    /// Strip a trailing `@v<digits>` version pin from `base`, returning the
    /// pin-free base and the captured digits (or `nil` when there is no pin).
    /// Phase 6: `@vN` pins the Nth derived-markdown extraction (oldest = `v1`) so
    /// a `[[source:X@v3#"quote"]]` highlight survives re-extraction. The `v` is
    /// case-insensitive (`@V3` works); the digits are returned as a string.
    ///
    /// Invalid forms yield `nil` (left literal): `@v` (no digits), `@x3` (not
    /// `v`), `@v3x` (trailing junk). A base that literally ends in `@v3` is
    /// ambiguous and treated as a pin — rare; documented.
    public static func splitVersionPin(_ base: String) -> (bare: String, pin: String?) {
        guard let m = versionPinRegex.firstMatch(in: base, range: NSRange(location: 0, length: base.utf16.count)) else {
            return (base, nil)
        }
        let bare = NSString(string: base).substring(with: m.range(at: 1))
        let pin = NSString(string: base).substring(with: m.range(at: 2))
        return (bare, pin)
    }

    /// `^(.*?)@[vV](\d+)$` — non-greedy so a trailing pin is the LAST `@vN`. The
    /// `.*?` keeps the leading `@` (if the name itself contains one) intact; only
    /// the final `@v<digits>` is peeled.
    private static let versionPinRegex = try! NSRegularExpression(
        pattern: #"^(.*?)@[vV](\d+)$"#)

    /// True when `target` is a canonical ULID link target — a 26-character
    /// Crockford base32 string (the exact shape `ULID.generate` emits), case-
    /// insensitively. Phase 5 stores resolvable links as
    /// `[[page:<ULID>|alias]]` / `[[source:<ULID>|alias]]`, and this predicate
    /// is the single load-bearing test that distinguishes a canonical target
    /// (validate by id) from a human title (resolve by name). It is evaluated
    /// on the prefix-stripped, fragment-removed bare target — `classify` peels
    /// the `page:`/`source:` prefix and the caller passes the base — so a
    /// `ULID#"quote"` form still passes the 26-char check.
    ///
    /// `01H…`/`01J…` time-prefixed ids are the norm; the confusable letters
    /// `I`/`L`/`O`/`U` are absent from Crockford base32, so their presence
    /// rejects a string that is merely ULID-shaped.
    public static func isCanonicalULID(_ target: String) -> Bool {
        target.count == 26
            && target.unicodeScalars.allSatisfy { ULID.allowedCharacters.contains($0) }
    }

    // MARK: - Parse

    /// Parse all wiki links from `body`, in document order, de-duplicated by
    /// `(kind, raw target, embed/cite role)` (first alias wins). Same-page anchors
    /// (`[[#…]]`, empty base) are skipped — they don't name a page or source, so
    /// they don't belong in the link graph. Page links with a `!` embed prefix
    /// (`![[Page]]`) are invalid embeds and are skipped entirely — only source
    /// links can be embeds (`![[source:…]]`).
    public static func parse(_ body: String) -> [ParsedLink] {
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [ParsedLink] = []

        for match in matches {
            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            
            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)

            let collapsed = collapseWhitespace(fixed.target)
            guard !collapsed.isEmpty else { continue }

            // Split on first "#" BEFORE classifying — so `[[#Section]]` yields
            // empty base (same-page, skipped here; handled in linkified) and
            // `[[source:X#"quote"]]` yields base:"source:X" + fragment:""quote"".
            let (base, fragment) = splitFragment(collapsed)
            guard !base.isEmpty else { continue } // same-page anchor → skip

            // Phase 6: strip a trailing `@vN` version pin AFTER the fragment split
            // (so a quote containing `@vN` isn't mis-read as a pin). The bare base
            // is what resolves by id/name; the pin is carried separately.
            let (bareBase, pin) = splitVersionPin(base)

            let (kind, bareTarget) = classify(bareBase)
            guard !bareTarget.isEmpty else { continue } // empty target → skip
            if isEmptyPrefix(bareBase) { continue } // `[[source:]]` → literal

            // Detect the `!` embed prefix. Embeds are source-only: a `![[Page]]`
            // is not a valid embed, so skip it entirely (AC.2). A `![[source:X]]`
            // sets isEmbed=true and uses a distinct dedup key so the cite and
            // embed edges coexist in `source_links_edge` (AC.3). Chat links are
            // also never embeds — `![[chat:…]]` is invalid and skipped.
            let isEmbed = WikiLinkSpan.isEmbedPrefix(ns, match.range)
            if isEmbed && kind != .source { continue }

            // De-dupe by the RAW target (base + fragment), not the base alone:
            // two `#`-containing titles (e.g. `[[C# Guide]]` / `[[C# Notes]]`)
            // share the mis-split base "C" but are different links. Plain
            // duplicates (`[[Home]]` twice) still collapse; `[[Page#A]]` +
            // `[[Page#B]]` both survive and the store's (from,to) primary key
            // collapses them if they resolve to one page. The embed/cite role
            // is part of the key so a cite + embed to the same source are both
            // kept (distinct rows under `source_links_edge`).
            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget
            // Phase 6: the pin is part of the dedup key so `[[source:X@v3]]` and
            // `[[source:X@v5]]` are distinct occurrences (matches the
            // `source_links_edge` pin-distinct semantics, §4.4).
            let role = isEmbed ? WikiLinkParser.LinkRole.embed : .cite
            let dedupKey = "\(kind.rawValue):\(raw):\(role.rawValue):\(pin ?? "")"
            guard seen.insert(dedupKey).inserted else { continue }

            let linkText: String
            if let alias = fixed.alias {
                let collapsedAlias = collapseWhitespace(alias)
                linkText = collapsedAlias.isEmpty ? bareTarget : collapsedAlias
            } else {
                linkText = bareTarget
            }
            out.append(ParsedLink(linkType: kind, target: bareTarget,
                                  fragment: fragment, linkText: linkText,
                                  isEmbed: isEmbed, versionPin: pin))
        }
        return out
    }

    /// Collapse runs of whitespace to a single space and trim the ends — delegates
    /// to the single shared normalizer.
    private static func collapseWhitespace(_ s: String) -> String {
        WikiText.normalized(s)
    }
}
