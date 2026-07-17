import Foundation

/// Rewrites Obsidian-style `[[wiki-links]]` in a projected document to standard
/// relative Markdown links `[display](relative/path.md)` so external tools like
/// Obsidian (vault rooted at the mount) and VS Code can follow them.
///
/// Handles all three linkable namespaces, each resolving to a file elsewhere in
/// the projection tree:
///   * `[[Title]]` / `[[page:<ULID>|alias]]`   → `pages/by-title/<file>.md`
///   * `[[source:Name]]` / `[[source:<ULID>]]` → `sources/by-name/<file>`
///   * `[[chat:Title]]` / `[[chat:<ULID>]]`    → `chats/by-name/<file>.md`
///
/// The link destination is computed **relative to the directory of the document
/// being rewritten** (`Resolver.baseDir`), so a page→page link stays a sibling
/// (`Other--01AB.md`) while a page→source link climbs out (`../../sources/…`).
///
/// Rules:
/// - Unresolvable targets (deleted / unknown) are left `[[…]]` verbatim so
///   Obsidian treats them as "new page" stubs.
/// - Embeds (`![[source:…]]`) are left verbatim — they're media, not links.
/// - Links inside code spans / fenced blocks are left verbatim.
/// - Heading fragments (`#Section`) are preserved; quote fragments (`#"quote"`,
///   used by source cites) are dropped — they aren't resolvable anchors.
/// - Canonical ULID targets resolve by id and self-heal the display text to the
///   target's CURRENT title (unless an explicit alias is present).
/// - `#`-in-name disambiguation reuses `WikiLinkResolver` (same rule as in-app).
///
/// This is a **filesystem projection** concern only — the SQLite store retains
/// `[[…]]` verbatim; nothing here writes back.
public enum RelativeLinkRewriter {

    /// A resolved link target: its root-relative path components (last component
    /// is the filename) and the CURRENT display title (for the alias fallback).
    public struct Target: Equatable, Sendable {
        public let path: [String]
        public let title: String
        public init(path: [String], title: String) {
            self.path = path
            self.title = title
        }
    }

    /// Namespace resolution injected by the caller. Each closure takes the
    /// prefix-stripped target and whether it is a canonical ULID, returning the
    /// resolved `Target` or `nil` (unknown → link left verbatim).
    public struct Resolver {
        /// Root-relative path components of the directory holding the document
        /// being rewritten — e.g. `["pages", "by-title"]`.
        public let baseDir: [String]
        public let page:   (_ target: String, _ isCanonicalID: Bool) -> Target?
        public let source: (_ target: String, _ isCanonicalID: Bool) -> Target?
        public let chat:   (_ target: String, _ isCanonicalID: Bool) -> Target?

        public init(
            baseDir: [String],
            page: @escaping (String, Bool) -> Target?,
            source: @escaping (String, Bool) -> Target?,
            chat: @escaping (String, Bool) -> Target?
        ) {
            self.baseDir = baseDir
            self.page = page
            self.source = source
            self.chat = chat
        }

        func namespace(for kind: ParsedLink.LinkType) -> (String, Bool) -> Target? {
            switch kind {
            case .page:   return page
            case .source: return source
            case .chat:   return chat
            }
        }
    }

    private static let regex = WikiLinkSpan.regex

    /// Rewrite all resolvable `[[wiki-links]]` in `body` to relative Markdown links.
    ///
    /// - Parameters:
    ///   - body: Full projected document (frontmatter + content). Frontmatter is
    ///           passed through since no `[[…]]` occurs in well-formed frontmatter.
    ///   - resolver: Namespace resolution + the document's `baseDir`.
    /// - Returns: The rewritten body, or `body` unchanged if nothing resolved.
    public static func rewrite(_ body: String, resolver: Resolver) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var out = ""
        var cursor = 0

        for match in matches {
            let full = match.range

            // Leave links inside code spans and fenced blocks verbatim.
            if WikiLinkSpan.isProtected(full, by: codeRanges) { continue }

            // Copy the gap before this match. If a `!` embed prefix immediately
            // precedes the match, consume it so we can emit `![[…]]` verbatim.
            let isEmbedPrefix = WikiLinkSpan.isEmbedPrefix(ns, full)
            let copyEnd = isEmbedPrefix ? full.location - 1 : full.location
            if copyEnd > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: copyEnd - cursor))
            }
            cursor = full.location + full.length

            // Embeds (`![[source:…]]` etc.) — media, not links; leave verbatim.
            if isEmbedPrefix {
                out += "!" + ns.substring(with: full)
                continue
            }

            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound
                ? ns.substring(with: aliasRange) : nil

            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsed = WikiText.normalized(fixed.target)
            guard !collapsed.isEmpty else {
                out += ns.substring(with: full)
                continue
            }
            let alias = fixed.alias.map { WikiText.normalized($0) }.flatMap { $0.isEmpty ? nil : $0 }

            // Split on "#"/"#\"" and strip version pin — same pipeline as the
            // in-app renderer, so on-disk and in-app resolve the same set.
            let (base, baseFragment) = WikiLinkParser.splitFragment(collapsed)
            guard !base.isEmpty else {
                // Same-page anchor (`[[#Heading]]`): no file target; leave as-is.
                out += ns.substring(with: full)
                continue
            }

            let (bareBase, _) = WikiLinkParser.splitVersionPin(base)
            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)

            guard !bareTarget.isEmpty, !WikiLinkParser.isEmptyPrefix(bareBase) else {
                out += ns.substring(with: full)
                continue
            }

            let resolve = resolver.namespace(for: kind)

            // Canonical ULID target: resolve by id, self-heal display to current title.
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                guard let target = resolve(bareTarget, true) else {
                    out += ns.substring(with: full)   // deleted → ghost
                    continue
                }
                out += markdownLink(display: alias ?? target.title,
                                    path: relativePath(from: resolver.baseDir, to: target.path),
                                    fragment: baseFragment)
                continue
            }

            // Name-based target: strip the `kind:` prefix (if present) BEFORE
            // `#`-in-name disambiguation, else the split keys carry the prefix and
            // never resolve. Page links usually have no prefix; source/chat do.
            let nameSearch = stripPrefix(kind, from: collapsed)
            let split = WikiLinkResolver.resolvedSplit(of: nameSearch) {
                resolve($0, false) != nil
            }
            // When a split resolved, take ITS (base, fragment) — even a nil
            // fragment (the whole name matched). Only fall back to the heuristic
            // `splitFragment` result when nothing resolved (ghost link).
            let linkName: String
            let linkFragment: String?
            if let split {
                linkName = split.base
                linkFragment = split.fragment
            } else {
                linkName = bareTarget
                linkFragment = baseFragment
            }

            guard let target = resolve(linkName, false) else {
                out += ns.substring(with: full)   // ghost link
                continue
            }
            out += markdownLink(display: alias ?? target.title,
                                path: relativePath(from: resolver.baseDir, to: target.path),
                                fragment: linkFragment)
        }

        // Tail text after the last match.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Relative path

    /// Root-relative path from `baseDir` (a directory) to `target` (whose last
    /// component is a filename), percent-encoded per component. Same directory →
    /// bare filename; different subtree → `../…/…`.
    // Kept `public` (not `internal`) because `SourceImageRewriter` in WikiFSCore
    // calls it cross-module after the WikiFSLinks extraction (Phase 1, #532).
    public static func relativePath(from baseDir: [String], to target: [String]) -> String {
        let targetDir = target.dropLast()
        var common = 0
        while common < baseDir.count && common < targetDir.count
                && baseDir[common] == targetDir[common] {
            common += 1
        }
        let ups = baseDir.count - common
        var comps = Array(repeating: "..", count: ups)
        comps += target[common...]
        return comps
            .map { $0.addingPercentEncoding(withAllowedCharacters: markdownPathAllowed) ?? $0 }
            .joined(separator: "/")
    }

    // MARK: - Private

    /// Strip a leading `page:` / `source:` / `chat:` prefix matching `kind` from
    /// `collapsed`, preserving any inner `#` (so `#`-in-name disambiguation works).
    private static func stripPrefix(_ kind: ParsedLink.LinkType,
                                    from collapsed: String) -> String {
        let token = "\(kind.rawValue):"
        return collapsed.hasPrefix(token) ? String(collapsed.dropFirst(token.count)) : collapsed
    }

    /// Build one `[display](path#fragment)` Markdown link. Escapes `[`/`]`/`\` in
    /// the display text; drops quote-style fragments (`"…"`) that aren't
    /// resolvable anchors; percent-encodes a kept heading fragment. `path` is
    /// already percent-encoded by `relativePath`.
    private static func markdownLink(display: String, path: String,
                                     fragment: String?) -> String {
        let safeDisplay = display
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        // A quote fragment (source cite, `#"…"`) is not a heading anchor — drop it.
        if let frag = fragment, !frag.isEmpty, !frag.hasPrefix("\"") {
            let encodedFrag = frag
                .addingPercentEncoding(withAllowedCharacters: markdownFragmentAllowed)
                ?? frag
            return "[\(safeDisplay)](\(path)#\(encodedFrag))"
        }
        return "[\(safeDisplay)](\(path))"
    }

    /// URL path characters allowed in a Markdown link destination component.
    /// Removes `()` (an unbalanced `)` ends the destination early in CommonMark)
    /// and `/` (we join components ourselves, so a `/` inside a component would
    /// forge a false path separator).
    private static let markdownPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()/")
        return set
    }()

    /// Fragment characters allowed after `#`. Removes `#`, `"`, `%`, and `()` to
    /// match `WikiLinkMarkdown`'s fragment encoding rules.
    private static let markdownFragmentAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.remove(charactersIn: "#\"%()")
        return set
    }()
}
