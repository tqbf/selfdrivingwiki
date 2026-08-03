import Foundation

/// Rewrites plain CommonMark image srcs (`![alt](src)`) in source-markdown
/// content that were downloaded during website-snapshot ingestion
/// (`WebsiteSnapshotExtractor`) and stored as flat sibling `sources` rows
/// (`GRDBWikiStore.addSnapshotImage`). The extractor rewrites `<img src>` to
/// a relative path like `potluck/diagram.png` as if a nested folder existed
/// next to the markdown, but the FileProvider projection places every source
/// flat under `sources/by-name/` — so that relative path never resolves on
/// disk (or in the in-app WKWebView reader, without this same lookup).
///
/// Mirrors `MarkdownHTMLRenderer.resolvedImageSrc` (`Sources/WikiFS/MarkdownHTMLRenderer.swift`),
/// the in-app renderer's EXACT-STRING resolution of the same `original_path`
/// data (`GRDBWikiStore.siblingImageResolvers()`) — but implemented as a
/// regex pass here (no `swift-markdown`/`import Markdown`, which is an
/// app-target-only dependency not linked into `WikiFSCore`/`WikiFSFileProvider` —
/// see `Package.swift`). Filtering rule is IDENTICAL: absolute (`http`/`https`),
/// `data:`, `wiki-blob:`, `wiki:` srcs pass through untouched; any other src is
/// looked up EXACTLY (no fuzzy/basename matching) in the resolver; an
/// unresolved relative src is left verbatim — same "don't guess" discipline
/// the in-app renderer uses.
///
/// This is a filesystem-projection concern only — SQLite retains the raw
/// extracted markdown verbatim; nothing here writes back.
public enum SourceImageRewriter {

    /// Namespace resolution for one document being rewritten.
    public struct Resolver {
        /// Root-relative directory of the document being rewritten — e.g.
        /// `["sources", "by-name"]`.
        public let baseDir: [String]
        /// EXACT `original_path` (as it appears in the markdown `![](src)`) →
        /// the resolved target, or `nil` if unresolved.
        public let resolve: (String) -> RelativeLinkRewriter.Target?

        public init(baseDir: [String], resolve: @escaping (String) -> RelativeLinkRewriter.Target?) {
            self.baseDir = baseDir
            self.resolve = resolve
        }
    }

    /// `![alt](src)` — alt has no unescaped `]`; src runs to the first
    /// unescaped `)` or whitespace (an optional `"title"` after whitespace is
    /// tolerated but not captured/preserved — none of today's snapshot images
    /// carry one, and dropping it if present is an acceptable, documented
    /// simplification). Capture groups: 1 = alt, 2 = src.
    private static let regex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)

    public static func rewrite(_ body: String, resolver: Resolver) -> String {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))

        var out = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            if WikiLinkSpan.isProtected(full, by: codeRanges) { continue }

            let src = ns.substring(with: match.range(at: 2))
            guard let target = resolvedTarget(for: src, resolver: resolver) else { continue }

            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let alt = ns.substring(with: match.range(at: 1))
            let path = RelativeLinkRewriter.relativePath(from: resolver.baseDir, to: target.path)
            out += "![\(alt)](\(path))"
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// `nil` for absolute/data/wiki-scheme srcs (leave verbatim, pass copies
    /// through untouched by the caller's cursor logic) OR an unresolved
    /// relative src (also leave verbatim). Mirrors
    /// `MarkdownHTMLRenderer.resolvedImageSrc`'s filter list exactly.
    private static func resolvedTarget(for src: String, resolver: Resolver) -> RelativeLinkRewriter.Target? {
        guard !src.isEmpty else { return nil }
        let lower = src.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("data:")
            || lower.hasPrefix("wiki-blob:") || lower.hasPrefix("wiki:") {
            return nil
        }
        return resolver.resolve(src)
    }
}
