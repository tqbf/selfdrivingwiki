import Foundation

/// Pure, view-free transform that rewrites Obsidian-style `[[wiki-links]]` in a
/// Markdown body into ordinary Markdown links pointing at a private `wiki://`
/// scheme — consumed by the WKWebView reader (`WikiReaderView` +
/// `MarkdownHTMLRenderer`), which renders to HTML (CommonMark has no concept of
/// `[[…]]`). Wiki-link cite spans become `<a href="wiki://…">`; embed spans
/// (`![[…]]`) become either inline media HTML (`<img>`/`<video>`/`<audio>`/
/// `<iframe>`/fenced mermaid — unchanged) or a collapsed
/// `<details class="sdw-transclusion">` disclosure (Plan v2: pages + non-media
/// sources) whose body is fetched + rendered lazily on expand through the same
/// `ReaderMarkdown.prepared` + `MarkdownHTMLRenderer.render` pipeline the
/// top-level reader uses (`plans/page-embed-v2.md`).
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
        public let id: PageID
        public let mimeType: String?
        public let target: EmbedTarget?

        public init(id: PageID, mimeType: String?, target: EmbedTarget? = nil) {
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

    // Shared grammar from WikiLinkSpan (same pattern as WikiLinkParser).
    private static let regex = WikiLinkSpan.regex

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
        displayName: (PageID, ParsedLink.LinkType) -> String? = { _, _ in nil },
        pinnedExtractionID: ((PageID, Int) -> PageID?)? = nil
    ) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        // Build the output by walking matches left→right, copying the gaps
        // verbatim and replacing each (non-code) match with a Markdown link.
        var out = ""
        var cursor = 0
        for match in matches {
            let full = match.range

            // Skip — copy verbatim — any match inside a code span/fence.
            if WikiLinkSpan.isProtected(full, by: codeRanges) {
                continue
            }

            // Copy the untouched text between the previous match and this one.
            // If an embed prefix `!` immediately precedes the match, consume it
            // (copy up to location - 1) so the `!` doesn't appear as literal
            // text — CommonMark would otherwise parse `![display](url)` as an
            // `<img>` node with a `wiki://` src.
            let isEmbedPrefix = WikiLinkSpan.isEmbedPrefix(ns, full)
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
                let id = PageID(rawValue: bareTarget)

                // Embed dispatch (Plan v2): page embeds + non-media source
                // transclusions emit a collapsed `<details>`; media sources
                // stay inline via `embedHTML`; missing → broken header. The
                // page/source probe consults both tables so a bare
                // `![[<ULID>]]` resolves correctly regardless of which table
                // owns the id — page wins on collision. An explicit `page:` /
                // `source:` prefix forces the namespace (no cross-namespace
                // probe), matching the cite-link semantics.
                if isEmbedPrefix {
                    let hasPagePrefix = bareBase.lowercased().hasPrefix(ParsedLink.LinkType.page.linkPrefix)
                    let hasSourcePrefix = bareBase.lowercased().hasPrefix(ParsedLink.LinkType.source.linkPrefix)
                    let pageName = hasSourcePrefix ? nil : displayName(id, .page)
                    let sourceName = hasPagePrefix ? nil : displayName(id, .source)
                    let aliasDisplay: String? = fixed.alias.flatMap { collapseWhitespace($0) }.flatMap { $0.isEmpty ? nil : $0 }

                    if let pageName {
                        let display = aliasDisplay ?? pageName
                        out += transclusionEmbedHTML(display: display, kind: .page,
                                                     id: id, target: nil,
                                                     fragment: fragment, name: pageName)
                        continue
                    }
                    if sourceName != nil, let info = embedInfo?(bareTarget),
                       let html = embedHTML(display: aliasDisplay ?? sourceName ?? bareTarget,
                                            id: info.id, mimeType: info.mimeType, target: info.target) {
                        out += html
                        continue
                    }
                    if sourceName != nil,
                       let info = embedInfo?(bareTarget),
                       isNonMediaSource(mimeType: info.mimeType, target: info.target) {
                        let display = aliasDisplay ?? sourceName ?? bareTarget
                        out += transclusionEmbedHTML(display: display, kind: .source,
                                                     id: id, target: nil,
                                                     fragment: fragment, name: display)
                        continue
                    }
                    // Neither table owns this id → broken embed (no fetch).
                    let display = aliasDisplay ?? bareTarget
                    out += brokenEmbedHTML(display: display, kind: hasSourcePrefix ? .source : .page)
                    continue
                }

                let currentName = displayName(id, kind)
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
                let pinID: PageID? = (kind == .source && pin != nil && fragment != nil)
                    ? pin.flatMap { Int($0) }.flatMap { pinnedExtractionID?(id, $0) }
                    : nil
                out += markdownLink(display: display, target: display, kind: kind,
                                    resolved: resolved, fragment: fragment, id: id,
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

            // Embed dispatch (Plan v2): a `!` prefix routes pages + non-media
            // sources to a collapsed `<details>` (lazy fetch+render on expand),
            // media sources stay inline via `embedHTML`, missing targets render
            // a muted broken header, and `chat:` embeds fall through to a
            // normal cite link (chat is not embeddable — `WikiLinkParser.parse`
            // rejects `![[chat:…]]` at L184). Bare `![[Foo]]` falls back to the
            // source namespace when the page doesn't exist (page wins on
            // collision); `page:`/`source:` prefixes force the namespace.
            if isEmbedPrefix && kind != .chat {
                let hasPagePrefix = bareBase.lowercased().hasPrefix(ParsedLink.LinkType.page.linkPrefix)

                if kind == .page {
                    // Explicit `page:` prefix → page only (no source fallback).
                    // Bare name → page first, fall back to source on miss.
                    if isResolved(linkTarget, .page) {
                        out += transclusionEmbedHTML(display: display, kind: .page,
                                                     id: nil, target: linkTarget,
                                                     fragment: linkFragment, name: linkTarget)
                        continue
                    }
                    if !hasPagePrefix, let info = embedInfo?(linkTarget) {
                        if let html = embedHTML(display: display, id: info.id,
                                                mimeType: info.mimeType, target: info.target) {
                            out += html
                            continue
                        }
                        if isNonMediaSource(mimeType: info.mimeType, target: info.target) {
                            out += transclusionEmbedHTML(display: display, kind: .source,
                                                         id: info.id, target: nil,
                                                         fragment: linkFragment, name: linkTarget)
                            continue
                        }
                        // Synthetic provider mime w/o target on a bare-name
                        // fallback → drop to cite link below (the source
                        // resolves, but has nothing to embed).
                    } else {
                        // Page unresolved, no source fallback (explicit prefix
                        // OR bare name with no source either) → broken page
                        // embed (Plan v2 §7.1: muted header, inert).
                        out += brokenEmbedHTML(display: display, kind: .page)
                        continue
                    }
                }

                if kind == .source {
                    if let info = embedInfo?(linkTarget) {
                        if let html = embedHTML(display: display, id: info.id,
                                                mimeType: info.mimeType, target: info.target) {
                            out += html
                            continue
                        }
                        if isNonMediaSource(mimeType: info.mimeType, target: info.target) {
                            out += transclusionEmbedHTML(display: display, kind: .source,
                                                         id: info.id, target: nil,
                                                         fragment: linkFragment, name: linkTarget)
                            continue
                        }
                        // Synthetic provider mime w/o target → cite link below.
                    } else {
                        // Source not in embedInfo → broken source embed.
                        out += brokenEmbedHTML(display: display, kind: .source)
                        continue
                    }
                }
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

    /// The pinned extraction smv id (`pin=<ULID>`) from a `wiki://…` URL, or nil
    /// when absent (a non-quote pinned link, or a legacy URL). Phase 6: the click
    /// router forwards this to `selectSource(pinnedExtractionID:)` so the
    /// destination loads the pinned extraction the quote was written against.
    public static func pin(from url: URL) -> PageID? {
        guard url.scheme == scheme,
              let host = url.host,
              host == sourceHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let pinString = components.queryItems?.first(where: { $0.name == "pin" })?.value,
              !pinString.isEmpty
        else { return nil }
        return PageID(rawValue: pinString)
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
                                     id: PageID? = nil,
                                     pinID: PageID? = nil) -> String {
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
            let encodedID = id.rawValue.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed)
                ?? id.rawValue
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

    /// Inline HTML for an embed source link. Returns `nil` for unrecognized
    /// cases so the caller falls back to a cite link.
    ///
    /// **Load-bearing ordering:** an external `target` (byteless external media)
    /// is checked FIRST — before the byteful `wiki-blob://` MIME dispatch — so a
    /// byteless source carrying a synthetic mime (`video/youtube`, `audio/spotify`)
    /// NEVER reaches the blob branch (which would emit a broken
    /// `<video src="wiki-blob://…">` against empty bytes). The `wiki-blob://` URL
    /// is served by `BlobSchemeHandler` (Phase 4a).
    private static func embedHTML(display: String, id: PageID, mimeType: String?, target: EmbedTarget?) -> String? {
        // 1. Byteless external media or inline diagram: provider iframe,
        // direct-remote native tag, or a fenced ```mermaid code block.
        if let target {
            switch target.kind {
            case .iframe:
                let sizeClass = iframeSizeClass(for: target.url)
                // YouTube-specific: the player initializes a JS runtime that
                // 153-errors under `loading="lazy"` (WebKit suspends the frame,
                // the player inits against a detached/zero-size iframe) and needs
                // the reader's referrer to be forwarded. Eager-load it and set an
                // explicit referrer policy. Other providers (Vimeo/Spotify/…) keep
                // lazy loading unchanged — they render fine as-is (issue #206 non-goal).
                if target.url.contains("youtube-nocookie.com") || target.url.contains("youtube.com") {
                    return "<iframe src=\"\(embedEscape(target.url))\" class=\"wiki-embed \(sizeClass)\" allow=\"encrypted-media; picture-in-picture; fullscreen\" referrerpolicy=\"strict-origin-when-cross-origin\" allowfullscreen></iframe>"
                }
                return "<iframe src=\"\(embedEscape(target.url))\" class=\"wiki-embed \(sizeClass)\" allow=\"encrypted-media; picture-in-picture; fullscreen\" loading=\"lazy\"></iframe>"
            case .audio:
                return "<audio src=\"\(embedEscape(target.url))\" controls class=\"wiki-embed\"></audio>"
            case .video:
                return "<video src=\"\(embedEscape(target.url))\" controls class=\"wiki-embed\"></video>"
            case .diagram:
                // #670 — inline Mermaid diagram. Emit a fenced ```mermaid
                // code block (NOT a raw `<div class="mermaid">…</div>`).
                //
                // Why a fenced code block instead of a raw div: the reader's
                // body is parsed by swift-markdown before reaching the
                // WKWebView. CommonMark's HTML-block rule (type 6, which
                // `<div>` falls under) ends at the first blank line — so a
                // diagram with a blank line inside its source, or an embed
                // placed mid-paragraph / inside a list item, gets re-parsed
                // as markdown: the contents are wrapped in `<p>`s, indent is
                // reinterpreted as a code block, and `>` gets double-escaped
                // to `&amp;gt;` (literal text `&gt;`). The scrambled
                // `div.textContent` then trips `mermaid.parse()` with
                // "Syntax error in text". A fenced code block is a
                // first-class markdown construct that survives ALL of those
                // contexts (paragraphs, lists, blockquotes, blank lines)
                // intact — the same path every other ```mermaid block uses.
                //
                // The reader's `mermaidBootstrapJS` (in WikiReaderView) then
                // scans for `code.language-mermaid`, reads
                // `code.textContent` (which un-escapes the renderer's `&gt;`
                // back to the raw `>`), creates a `<div class="mermaid">`
                // with the un-escaped diagram text, and replaces the parent
                // `<pre>` — then `mermaid.run({querySelector:'.mermaid'})`
                // renders the SVG. Same pipeline as a hand-written fenced
                // ```mermaid block.
                //
                // Escape hatch: pick a fence length strictly longer than any
                // backtick run in the diagram source so a diagram containing
                // ``` (or longer) doesn't prematurely close the fence. Default
                // is 3 (standard GFM).
                let source = target.content ?? ""
                let n = String(repeating: "`", count: mermaidFenceLength(for: source))
                return "\n\(n)mermaid\n\(source)\n\(n)\n"
            }
        }
        // 2. Byteful blob dispatch (Phase 4a) — unchanged.
        let url = "\(blobScheme)://source/\(id.rawValue)"
        guard let mime = mimeType else { return nil }
        // Safety: a synthetic provider mime (video/youtube, audio/spotify, …)
        // that did NOT resolve to a target must NOT reach the blob branch — its
        // `hasPrefix("video/")` / `("audio/")` would otherwise emit a broken
        // `<video src="wiki-blob://…">` against empty bytes. Fall back to a cite
        // link instead (§1.3 / R2 ordering invariant).
        if syntheticProviderMimes.contains(mime) { return nil }
        if mime.hasPrefix("image/") {
            return "<img src=\"\(url)\" alt=\"\(embedEscape(display))\" class=\"wiki-embed\">"
        }
        if mime.hasPrefix("video/") {
            return "<video src=\"\(url)\" controls class=\"wiki-embed\"></video>"
        }
        if mime.hasPrefix("audio/") {
            return "<audio src=\"\(url)\" controls class=\"wiki-embed\"></audio>"
        }
        if MimeType.isPDF(mime) {
            return "<iframe src=\"\(url)\" class=\"wiki-embed-pdf\"></iframe>"
        }
        return nil // unknown MIME → caller falls back to cite link or transclusion
    }

    /// Whether a resolved source is **genuinely non-media** — i.e. eligible for
    /// the Plan v2 `<details>` transclusion fallback when `embedHTML` returned
    /// `nil`. Mirrors the EXACT predicate order `embedHTML` encodes (Plan v2
    /// §15.2): an external `target`, a media MIME (image/video/audio/PDF), a
    /// Mermaid MIME, or a byteless synthetic provider mime MUST NOT reach the
    /// transclusion branch — they stay inline (`embedHTML`) or fall through to
    /// a cite link (synthetic mime with no target).
    ///
    /// Returns `false` for an unknown/`nil` MIME so a source we know nothing
    /// about stays a cite link (the pre-v2 behavior) rather than speculative
    /// transclusion.
    private static func isNonMediaSource(mimeType: String?, target: EmbedTarget?) -> Bool {
        if target != nil { return false }
        guard let mime = mimeType?.lowercased() else { return false }
        if mime.hasPrefix("image/") { return false }
        if mime.hasPrefix("video/")  { return false }
        if mime.hasPrefix("audio/")  { return false }
        if MimeType.isPDF(mime)      { return false }
        if MimeType.isMermaid(mime)  { return false }
        if syntheticProviderMimes.contains(mime) { return false }
        return true
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

    /// Emit the collapsed-transclusion `<details>` for a page or non-media
    /// source embed (Plan v2 §3.1). Pure — no store, no IO. The body stays
    /// empty (a `Loading…` placeholder) and is filled on first expand by the
    /// reader's `embedFetchName` handler.
    ///
    /// - Parameters:
    ///   - display: the `<summary>` header text (alias when provided, else the
    ///     resolved current name for canonical, else the raw target).
    ///   - kind: `"page"` or `"source"` — drives the fetch dispatch.
    ///   - id: the canonical ULID when known at linkify; `nil` for name-based
    ///     page embeds (resolved at expand via `store.pageID(forTitle:)`).
    ///   - target: the raw name for name-based page embeds; `nil` when `id` is
    ///     known.
    ///   - fragment: the optional `#fragment`, verbatim.
    ///   - name: the human-readable name shown in the cycle marker / missing
    ///     placeholder (the raw target / current name).
    /// - Returns: inline HTML starting on its own line (leading `\n` so the
    ///   swift-markdown HTML-block rule reliably opens it; see gotcha §15.9).
    public static func transclusionEmbedHTML(
        display: String,
        kind: ParsedLink.LinkType,
        id: PageID?,
        target: String?,
        fragment: String?,
        name: String
    ) -> String {
        let kindAttr = kind == .page ? pageEmbedKind : kind.rawValue
        let idAttr = id?.rawValue ?? ""
        let targetAttr = target?.addingPercentEncoding(withAllowedCharacters: targetAllowed) ?? ""
        let fragAttr = fragment?.addingPercentEncoding(withAllowedCharacters: fragmentAllowed) ?? ""
        let node = "embed-\(UUID().uuidString)"
        let titleEscaped = embedEscape(display)
        let nameEscaped = embedEscape(name)
        return """
        \n<details class="\(TransclusionAttr.className)" \
        \(TransclusionAttr.kind)="\(kindAttr)" \
        \(TransclusionAttr.id)="\(idAttr)" \
        \(TransclusionAttr.target)="\(targetAttr)" \
        \(TransclusionAttr.fragment)="\(fragAttr)" \
        \(TransclusionAttr.name)="\(nameEscaped)" \
        \(TransclusionAttr.path)="" \
        \(TransclusionAttr.node)="\(node)" \
        \(TransclusionAttr.state)="empty">\
        <summary><span class="sdw-embed-title">\(titleEscaped)</span></summary>\
        <div class="sdw-embed-body">\
        <span class="sdw-embed-placeholder">Loading…</span>\
        </div>\
        </details>\n
        """
    }

    /// Emit a broken/missing transclusion `<details>` (Plan v2 §7.1): collapsed,
    /// inert (no fetch metadata), header muted red via the
    /// `.sdw-transclusion[data-sdw-state="missing"]` CSS rule. Pure.
    public static func brokenEmbedHTML(display: String, kind: ParsedLink.LinkType) -> String {
        let kindAttr = kind == .page ? pageEmbedKind : kind.rawValue
        let label = kind == .page ? "Page not found" : "Source not found"
        let titleEscaped = embedEscape(display)
        return """
        \n<details class="\(TransclusionAttr.className)" \
        \(TransclusionAttr.state)="missing" \
        \(TransclusionAttr.kind)="\(kindAttr)">\
        <summary><span class="sdw-embed-title">\(label): \(titleEscaped)</span></summary>\
        </details>\n
        """
    }

    /// URL-allowed set for the `data-sdw-embed-target` value. Same shape as the
    /// title-query set but tighter (no `=` reserved by attributes).
    private static let targetAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#\"' <>")
        return set
    }()

    /// Pick the reader-CSS sizing class for a provider iframe: audio-player
    /// iframes (Spotify, SoundCloud, Apple Podcasts) get a fixed height; video
    /// iframes (YouTube, Vimeo) get a 16:9 aspect ratio. Derived from the embed
    /// URL host so `EmbedTarget` stays a minimal (kind, url) pair.
    private static func iframeSizeClass(for url: String) -> String {
        if url.contains("open.spotify.com")
            || url.contains("w.soundcloud.com")
            || url.contains("embed.podcasts.apple.com") {
            return "wiki-embed-audio"
        }
        return "wiki-embed-video"
    }

    /// The synthetic MIME types used for byteless provider embeds. A source
    /// carrying one of these MUST render via an `EmbedTarget` (checked first);
    /// if it has no target it falls back to a cite link, never the blob branch.
    private static let syntheticProviderMimes: Set<String> = [
        "video/youtube", "video/vimeo", "audio/spotify", "audio/soundcloud"
    ]

    /// Escape `"` and `<`/`>`/`&` for an HTML attribute value (alt text).
    private static func embedEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Pick a fenced-code-block fence length strictly longer than any backtick
    /// run in `source`, so a diagram containing ``` (or longer) doesn't close
    /// the fence we emit. Default is 3 (standard GFM). CommonMark §4.5 says a
    /// closing fence must be at least as long as the opening fence, so length
    /// `maxRun + 1` is immune to any run inside the diagram body.
    private static func mermaidFenceLength(for source: String) -> Int {
        var maxRun = 0
        var run = 0
        for ch in source {
            if ch == "`" {
                run += 1
                if run > maxRun { maxRun = run }
            } else {
                run = 0
            }
        }
        return max(maxRun + 1, 3)
    }

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
