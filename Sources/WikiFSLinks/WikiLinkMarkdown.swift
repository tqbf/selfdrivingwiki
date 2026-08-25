import Foundation
import WikiFSTypes

/// A pure compatibility transform for non-render callers. It rewrites
/// `[[wiki-links]]` as private `wiki://` Markdown links. It preserves every
/// `![[embed]]` occurrence exactly. The production reader uses typed syntax,
/// resolution, and HTML lowering instead of this string bridge.
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
///   * a target that resolves → `wiki://page?title=…` or `wiki://source?title=…` or `wiki://chat?title=…`
///   * a target that does NOT  → `wiki://missing?title=…` (still a link
///     so the view can style it dimmed, but the click handler no-ops on it).
public enum WikiLinkMarkdown {

    /// The render decision for one `![[source:…]]` embed: the source id + its
    /// MIME type (for the byteful `wiki-blob://` dispatch) and an optional
    /// external `EmbedTarget` (for byteless external media — provider iframes,
    /// direct-remote `<audio>`/`<video>`, Apple Podcasts player — or an inline
    /// Mermaid diagram, #670). When `target` is non-nil the renderer emits the
    /// element for the target's `kind`; otherwise it falls back to the byteful
    /// blob dispatch (Phase 4a), then to a cite link.
    public struct SourceEmbedInfo: Sendable, Equatable {
        /// Source entity identity. Rendering crosses to raw text only when it
        /// constructs a `wiki-blob` or wiki-link representation.
        public let id: SourceID
        public let mimeType: String?
        public let target: EmbedTarget?

        public init(id: SourceID, mimeType: String?, target: EmbedTarget? = nil) {
            self.id = id
            self.mimeType = mimeType
            self.target = target
        }
    }

    /// The private scheme the in-app `OpenURLAction` intercepts. Real external
    /// links (https, mailto, …) fall through to `.systemDefault`.
    public static let scheme = "wiki"
    /// The custom WKURL scheme that serves source blob bytes from SQLite to the
    /// web view. `![[source:…]]` embeds emit `<img src="wiki-blob://source/<id>">`.
    /// The `BlobSchemeHandler` (in `WikiFS`) registers for this scheme.
    public static let blobScheme = "wiki-blob"
    /// Host for a link whose target resolves to a real page (navigates).
    public static let resolvedHost = "page"
    /// Host for a link whose target resolves to a real source (navigates).
    public static let sourceHost = "source"
    /// Host for a link whose target resolves to a real chat (navigates).
    public static let chatHost = "chat"
    /// Host for a same-page anchor link (scroll, no navigation).
    public static let anchorHost = "anchor"
    /// Host for a link whose target has no page/source (rendered dimmed, inert).
    public static let unresolvedHost = "missing"

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
    ///   - embedInfo: when non-nil, called for each `![[source:…]]` embed to
    ///                resolve the source name to a `SourceEmbedInfo` (id + MIME
    ///                + optional external `EmbedTarget`). Returns the embed HTML
    ///                (`<img>`, `<video>`, `<audio>`, `<iframe>`) if the source
    ///                resolves and is renderable; falls back to a cite link
    ///                otherwise. A non-nil `target` (byteless external media)
    ///                takes precedence over the byteful `wiki-blob://` dispatch.
    /// - Returns: Markdown safe to hand to `AttributedString(markdown:)`.
    public static func linkified(
        _ body: String,
        isResolved: (String, ParsedLink.LinkType) -> Bool = { _, _ in true },
        embedInfo: ((String) -> SourceEmbedInfo?)? = nil,
        displayName: (String, ParsedLink.LinkType) -> String? = { _, _ in nil },
        pinnedExtractionID: ((SourceID, Int) -> SourceMarkdownVersionID?)? = nil
    ) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.matches(in: body)

        // Build the output by walking matches left→right, copying the gaps
        // verbatim and replacing each (non-code) match with a Markdown link.
        var out = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            let isEmbedPrefix = WikiLinkSpan.isEmbedPrefix(ns, full)

            // Skip — copy verbatim — any match inside a code span/fence.
            if WikiLinkSpan.isProtected(full, by: codeRanges)
                || WikiLinkSpan.isLocallyCodeWrapped(
                    ns, full, includesEmbedPrefix: isEmbedPrefix
                ) {
                continue
            }

            // Copy the untouched text between the previous match and this one.
            // If an embed prefix `!` immediately precedes the match, consume it
            // (copy up to location - 1) so the `!` doesn't appear as literal
            // text — CommonMark would otherwise parse `![display](url)` as an
            // `<img>` node with a `wiki://` src.
            let copyEnd = isEmbedPrefix ? full.location - 1 : full.location
            if copyEnd > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: copyEnd - cursor))
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

            // Phase 6: strip a trailing `@vN` pin AFTER the fragment split (so a
            // quote containing `@vN` isn't mis-read as a pin, and a `ULID@v3`
            // passes the 26-char ULID fast-path). The pin is emitted only for
            // pinned source quote links (below).
            let (bareBase, pin) = WikiLinkParser.splitVersionPin(base)

            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
            guard !bareTarget.isEmpty else {
                // Empty bare target after prefix strip: literal text.
                out += ns.substring(with: full)
                continue
            }
            // `[[source:]]` / `[[page:]]` — reserved prefix with no meaningful
            // remainder: emit literal text (consistent with the parser's skip).
            if WikiLinkParser.isEmptyPrefix(bareBase) {
                out += ns.substring(with: full)
                continue
            }

            // Canonical ULID target (Phase 5): resolve by id and display the
            // CURRENT name so a stale alias self-heals at render without touching
            // any bytes. `displayName` returns the live title/name (nil when the
            // target was deleted → ghost, or when the caller didn't supply it →
            // fall back to the stored alias). Non-canonical links keep the
            // name-resolution path below.
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                let sourceID = SourceID(rawValue: bareTarget)

                // The compatibility adapter converts cite links only. Typed
                // preparation owns all embed syntax and its presentation role.
                if isEmbedPrefix {
                    out += "!" + ns.substring(with: full)
                    continue
                }

                let currentName = displayName(bareTarget, kind)
                let resolved = currentName != nil || isResolved(bareTarget, kind)
                let display: String
                if let currentName {
                    display = currentName
                } else if let alias = fixed.alias {
                    let collapsedAlias = collapseWhitespace(alias)
                    display = collapsedAlias.isEmpty ? bareTarget : collapsedAlias
                } else {
                    display = bareTarget
                }
                // Phase 6: a pinned source link WITH a fragment (quote) emits
                // `&pin=<smvID>` so the destination loads the pinned extraction
                // — the quote is then present in the rendered DOM and the
                // highlighter finds it. A pinned link WITHOUT a fragment opens
                // HEAD (the chosen scope): no `&pin=`. Embeds are excluded above.
                let pinID: SourceMarkdownVersionID? = (kind == .source && pin != nil && fragment != nil)
                    ? pin.flatMap { Int($0) }.flatMap { pinnedExtractionID?(sourceID, $0) }
                    : nil
                out += markdownLink(display: display, target: display, kind: kind,
                                    resolved: resolved, fragment: fragment, id: bareTarget,
                                    pinID: pinID)
                continue
            }

            // Try every (name, fragment) reading of the target against the
            // caller's namespace, longest name first — so a `#` INSIDE a
            // page/source name (e.g. "… for C# …", with or without a real
            // anchor after it) links the actual page instead of truncating at
            // the first `#`. Ghost links keep the heuristic split.
            //
            // Phase 6 note: `&pin=` is NOT emitted here. This branch handles
            // name-based links (forward links, pre-Phase-5 bodies) — a forward
            // link to a source that doesn't exist yet has no extraction chain
            // to pin. Once the page is re-saved, `canonicalize` promotes the
            // link to ULID form and the canonical branch above emits the pin.
            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget
            let split = WikiLinkResolver.resolvedSplit(of: raw) { isResolved($0, kind) }

            // Issue #619 (render path): when the bare target didn't resolve
            // AND the regex found a `|` (alias present), the `|` may have
            // been part of the real display name (common with YouTube titles
            // the app ingests, or doc-set names like "Flex Tier - Documentation
            // | Neuralwatt Cloud") rather than a true alias separator.
            // Reconstruct `bareTarget | alias` (plus any `#`-fragment that
            // landed in the alias portion) and run THAT through resolvedSplit.
            // Mirrors the canonicalize-seam fix in WikiLinkRewriter (lines
            // 71–126), so uncanonicalized bodies — chat transcripts in
            // particular — render pipe-containing source links as resolvable
            // `wiki://source` links instead of inert `wiki://missing`.
            //
            // Only runs as a FALLBACK when the bare target failed, so a
            // genuine alias link (`[[Foo|bar]]` where Foo exists) already
            // resolved via `split` above and is unaffected.
            var resolvedViaReconstruction = false
            let reconSplit: WikiLinkResolver.Split?
            if split == nil, let alias = fixed.alias {
                let normalizedAlias = collapseWhitespace(alias)
                if normalizedAlias.isEmpty {
                    reconSplit = nil
                } else {
                    let reconstructedRaw = fragment.map { "\(bareTarget) | \(normalizedAlias)#\($0)" }
                        ?? "\(bareTarget) | \(normalizedAlias)"
                    reconSplit = WikiLinkResolver.resolvedSplit(
                        of: reconstructedRaw,
                        isKnown: { isResolved($0, kind) }
                    )
                    resolvedViaReconstruction = reconSplit != nil
                }
            } else {
                reconSplit = nil
            }

            let resolved = split != nil || reconSplit != nil
            // Resolve (target, fragment) explicitly: `split?.fragment ?? ...`
            // would conflate "split hit but fragment nil" (the whole-target
            // case, e.g. "C# Guide" resolving whole) with "split missed", so
            // branch on which source of truth won.
            let linkTarget: String
            let linkFragment: String?
            if let split {
                linkTarget = split.base
                linkFragment = split.fragment
            } else if let reconSplit {
                linkTarget = reconSplit.base
                linkFragment = reconSplit.fragment
            } else {
                linkTarget = bareTarget
                linkFragment = fragment
            }

            let display: String
            if resolvedViaReconstruction, let recon = reconSplit {
                // The `|` was part of the name, not a real alias separator:
                // display the FULL resolved name (e.g. "Flex Tier -
                // Documentation | Neuralwatt Cloud"), NOT the alias fragment
                // ("Neuralwatt Cloud#"quote""). Mirrors WikiLinkRewriter's
                // `resolvedName` auto-alias at the canonicalize seam.
                display = recon.base
            } else if let alias = fixed.alias {
                let collapsedAlias = collapseWhitespace(alias)
                display = collapsedAlias.isEmpty ? linkTarget : collapsedAlias
            } else {
                display = linkTarget
            }

            // The compatibility adapter never lowers embeds. Preserve the exact
            // authored syntax for the typed render pipeline.
            if isEmbedPrefix {
                out += "!" + ns.substring(with: full)
                continue
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
              host == resolvedHost || host == sourceHost || host == chatHost || host == unresolvedHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let title = components.queryItems?.first(where: { $0.name == "title" })?.value,
              !title.isEmpty
        else { return nil }
        return title
    }

    /// The canonical `id` query item from a `wiki://…?id=<ULID>&title=…` URL, or
    /// nil when absent (legacy `?title=`-only links). Used by the view's click
    /// router to resolve a canonical link by id — a direct row fetch — instead of
    /// by display name (Phase 5 §6.5). Returns nil for non-wiki or unresolved
    /// (`missing`) URLs so only resolvable links route by id.
    public static func id(from url: URL) -> PageID? {
        guard url.scheme == scheme,
              let host = url.host,
              host == resolvedHost || host == sourceHost || host == chatHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !idString.isEmpty
        else { return nil }
        return PageID(rawValue: idString)
    }

    /// The canonical source `id` query item from a `wiki://source?...` URL.
    /// The URL itself stays raw text; this parser is the source navigation
    /// boundary that restores its source-entity namespace.
    public static func sourceID(from url: URL) -> SourceID? {
        guard url.scheme == scheme,
              url.host == sourceHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !idString.isEmpty
        else { return nil }
        return SourceID(rawValue: idString)
    }

    /// The pinned extraction smv id (`pin=<ULID>`) from a `wiki://…` URL, or nil
    /// when absent (a non-quote pinned link, or a legacy URL). Phase 6: the click
    /// router forwards this to `selectSource(pinnedExtractionID:)` so the
    /// destination loads the pinned extraction the quote was written against.
    public static func pin(from url: URL) -> SourceMarkdownVersionID? {
        guard url.scheme == scheme,
              let host = url.host,
              host == sourceHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let pinString = components.queryItems?.first(where: { $0.name == "pin" })?.value,
              !pinString.isEmpty
        else { return nil }
        return SourceMarkdownVersionID(rawValue: pinString)
    }

    /// Return the URL-decoded fragment from a `wiki://` URL, or nil. Used by the
    /// view's `OpenURLAction` to extract the anchor for scroll-to.
    public static func fragment(from url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host,
              host == resolvedHost || host == sourceHost || host == chatHost || host == unresolvedHost || host == anchorHost
        else { return nil }
        return url.fragment?.removingPercentEncoding
    }

    /// `.page` / `.source` for a resolved link; `nil` for unresolved (`missing` or
    /// `anchor`) or non-wiki. Used by the view's `OpenURLAction` to route the click.
    /// Host `"anchor"` is same-page scroll — not a navigation, so returns nil here
    /// (the OpenURLAction handles it separately).
    public static func resolvedKind(from url: URL) -> ParsedLink.LinkType? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        switch host {
        case resolvedHost:   return .page     // "page"
        case sourceHost:     return .source   // "source"
        case chatHost:       return .chat     // "chat"
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
        url.scheme == scheme && url.host == anchorHost
    }

    // MARK: - Helpers

    private static func markdownLink(display: String, target: String,
                                     kind: ParsedLink.LinkType,
                                     resolved: Bool,
                                     fragment: String? = nil,
                                     id: String? = nil,
                                     pinID: SourceMarkdownVersionID? = nil) -> String {
        let host: String
        if resolved {
            host = kind == .source ? sourceHost : (kind == .chat ? chatHost : resolvedHost)
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
        // Canonical links carry `id=<ULID>` so click routing resolves by id
        // (a direct row fetch) instead of display name; `title=` is retained as
        // a transition fallback for any unconverted consumer (Phase 5 §6.5).
        // Phase 6: a pinned quote link also carries `pin=<smvID>` so the
        // destination source view loads the pinned extraction.
        var url: String
        if let id {
            let encodedID = id.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed)
                ?? id
            url = "\(scheme)://\(host)?id=\(encodedID)&title=\(encodedTitle)"
            if let pinID {
                let encodedPin = pinID.rawValue.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed)
                    ?? pinID.rawValue
                url += "&pin=\(encodedPin)"
            }
        } else {
            url = "\(scheme)://\(host)?title=\(encodedTitle)"
        }
        if let frag = fragment, !frag.isEmpty {
            let encodedFrag = frag.addingPercentEncoding(withAllowedCharacters: fragmentAllowed)
                ?? frag
            url += "#\(encodedFrag)"
        }
        return "[\(safeDisplay)](\(url))"
    }

    // MARK: - Transclusion (<details> disclosure) — Plan v2

    /// HTML attribute namespace for the lazy transclusion seam. The web view's
    /// `embedFetchName` script-message handler reads these to resolve + fetch +
    /// render the body on first expand. `sdw-transclusion` is the disclosure's
    /// own class; the others are read at fetch time only.
    public enum TransclusionAttr {
        /// `<details>` class — also the CSS hook for the disclosure styling.
        public static let className = "sdw-transclusion"
        /// `data-sdw-embed-kind` — `"page"` or `"source"`. Dispatches the fetch.
        public static let kind = "data-sdw-embed-kind"
        /// `data-sdw-embed-id` — the canonical ULID when known at linkify time,
        /// empty for name-based page embeds (resolved at expand on the main
        /// actor via `store.pageID(forTitle:)`).
        public static let id = "data-sdw-embed-id"
        /// `data-sdw-embed-target` — URL-encoded name for name-based page
        /// embeds; empty when the id is known.
        public static let target = "data-sdw-embed-target"
        /// `data-sdw-embed-fragment` — the optional `#fragment`, URL-encoded.
        public static let fragment = "data-sdw-embed-fragment"
        /// `data-sdw-embed-name` — the raw human-readable name used in the
        /// cycle marker and the missing-target placeholder.
        public static let name = "data-sdw-embed-name"
        /// `data-sdw-embed-path` — space-separated ancestor id chain for the
        /// cycle check. Empty at linkify; populated by `sdwInjectEmbed` for
        /// every nested `<details>` it injects (parent path + parent id).
        public static let path = "data-sdw-embed-path"
        /// `data-sdw-node` — per-node unique selector (UUID) so
        /// `sdwInjectEmbed` finds the right body when multiple expands race.
        public static let node = "data-sdw-node"
        /// `data-sdw-state` — `empty` (initial), `loaded` (body injected),
        /// `missing` (no target), `cycle` (cycle marker injected).
        public static let state = "data-sdw-state"
    }

    /// The kind value carried on `data-sdw-embed-kind` for pages. Sources use
    /// `ParsedLink.LinkType.source.rawValue` ("source").
    public static let pageEmbedKind = "page"

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
