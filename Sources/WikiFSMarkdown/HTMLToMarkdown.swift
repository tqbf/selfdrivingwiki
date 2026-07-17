import Foundation

/// A pure, dependency-free HTML → Markdown converter.
///
/// Hand-rolled on purpose. We deliberately do NOT use `NSAttributedString(html:)`:
/// that path is WebKit-backed, main-thread-only, non-deterministic, and impossible
/// to unit-test offline. This tolerant tag walker is synchronous, deterministic, and
/// has no dependency on AppKit/WebKit — so the whole conversion is covered by plain
/// value-in/value-out unit tests with no view and no network.
///
/// Scope: the converted Markdown is consumed by the ACP agent that summarizes
/// it later, so it needn't be a perfect round-trip — it must be *clean and readable*
/// and it must NEVER crash on malformed / unclosed / weird input. Every loop here is
/// bounded by the input length; an unterminated tag or entity degrades to literal
/// text rather than spinning.
///
/// Handles the common document shapes:
/// - strips `<script>`, `<style>`, `<head>`, `<nav>`, `<footer>` noise;
/// - prefers `<article>` / `<main>` / `<body>` content when present;
/// - `<h1>`–`<h6>` → `#`…`######`; `<p>` → blank-line-separated paragraphs; `<br>` → newline;
/// - `<a href>` → `[text](href)`; `<strong>`/`<b>` → `**…**`; `<em>`/`<i>` → `*…*`;
/// - `<code>` → `` `…` ``; `<pre>` → fenced block; `<ul>`/`<ol>`/`<li>` → lists;
/// - `<blockquote>` → `> `; `<img>` → `![alt](src)`;
/// - decodes named + numeric HTML entities; collapses whitespace; trims.
public enum HTMLToMarkdown {

    /// The result of a conversion: the rendered Markdown plus the document `<title>`
    /// (used by the URL-ingest service to name the stored file). `title` is `nil`
    /// when the document has no usable `<title>`.
    public struct Result: Equatable, Sendable {
        public let markdown: String
        public let title: String?

        public init(markdown: String, title: String?) {
            self.markdown = markdown
            self.title = title
        }
    }

    /// Convert an HTML string to Markdown + extract the document title.
    public static func convert(_ html: String) -> Result {
        let tokens = Tokenizer.tokenize(html)
        let title = extractTitle(from: tokens)
        let scoped = scopeToMainContent(tokens)
        var renderer = Renderer()
        let markdown = renderer.render(scoped)
        return Result(markdown: markdown, title: title)
    }

    /// Tokenize + scope to main content, returning the scoped tokens. Internal
    /// so the website snapshot extractor can extract/rewrite `<img src>` at the
    /// token level before render — sharing the same tokenizer + scoper the
    /// normal `convert` path uses.
    public static func scopedTokens(for html: String) -> [Token] {
        scopeToMainContent(Tokenizer.tokenize(html))
    }

    /// Render pre-scoped tokens to Markdown (the render step only, no re-tokenize).
    /// Internal counterpart to `scopedTokens(for:)`.
    public static func markdown(fromScopedTokens tokens: [Token]) -> String {
        var renderer = Renderer()
        return renderer.render(tokens)
    }

    /// Extract the document title from raw HTML (tokenize + scan), without
    /// converting the body. Internal so the snapshot path can name the page from
    /// `<title>` before it rewrites image srcs.
    public static func titleOnly(from html: String) -> String? {
        extractTitle(from: Tokenizer.tokenize(html))
    }

    /// Convenience: just the Markdown body.
    public static func markdown(from html: String) -> String {
        convert(html).markdown
    }

    // MARK: - Title extraction

    /// First `<title>…</title>` text content, entity-decoded + whitespace-collapsed.
    private static func extractTitle(from tokens: [Token]) -> String? {
        var i = 0
        while i < tokens.count {
            if case let .startTag(name, _, _) = tokens[i], name == "title" {
                var text = ""
                var j = i + 1
                while j < tokens.count {
                    if case let .text(raw) = tokens[j] { text += raw }
                    if case let .endTag(end) = tokens[j], end == "title" { break }
                    j += 1
                }
                let decoded = HTMLEntities.decode(text)
                let collapsed = collapseWhitespace(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
                return collapsed.isEmpty ? nil : collapsed
            }
            i += 1
        }
        return nil
    }

    // MARK: - Content scoping

    /// Drop tokens belonging to noise containers (`script`/`style`/`head`/`nav`/
    /// `footer`), then — if the document has a `<article>` or `<main>` or `<body>` —
    /// keep only that subtree's tokens (first match wins, in that priority order).
    /// Falls back to the whole (de-noised) token stream when none is present, so a
    /// fragment with no `<body>` still converts.
    private static func scopeToMainContent(_ tokens: [Token]) -> [Token] {
        let denoised = stripContainers(tokens, names: ["script", "style", "head", "nav", "footer"])
        for container in ["article", "main", "body"] {
            if let inner = subtree(of: container, in: denoised) {
                return inner
            }
        }
        return denoised
    }

    /// Metadata elements allowed inside `<head>`. Per HTML5 the `</head>` end tag is
    /// optional: the head is implicitly closed by the first start tag that is NOT one
    /// of these (in practice `<body>`). We use this to terminate the head-skip below.
    private static let headMetadata: Set<String> = [
        "base", "link", "meta", "noscript", "script", "style", "template", "title",
    ]

    /// Remove every token inside (and including) any element whose name is in
    /// `names`. Nesting-aware: tracks a depth counter per opened noise container so
    /// a `<nav>` inside a `<nav>` is fully removed. Void/self-closing noise tags are
    /// dropped without a depth bump.
    private static func stripContainers(_ tokens: [Token], names: Set<String>) -> [Token] {
        var out: [Token] = []
        var skipDepth = 0
        var skipName: String?
        for token in tokens {
            if skipDepth > 0 {
                // `<head>` has an OPTIONAL end tag: HTML5 implicitly closes it at the
                // first non-metadata start tag (normally `<body>`). Bikeshed/W3C pages
                // omit `</head>` entirely, so a literal "skip until </head>" swallows
                // the whole document. Detect the implicit close, end the skip, and fall
                // through so the terminating token (the body) is processed normally.
                if skipName == "head",
                   case let .startTag(name, _, _) = token,
                   !headMetadata.contains(name) {
                    skipDepth = 0
                    skipName = nil
                } else {
                    switch token {
                    case let .startTag(name, _, selfClosing) where name == skipName && !selfClosing:
                        skipDepth += 1
                    case let .endTag(name) where name == skipName:
                        skipDepth -= 1
                        if skipDepth == 0 { skipName = nil }
                    default:
                        break
                    }
                    continue
                }
            }
            if case let .startTag(name, _, selfClosing) = token, names.contains(name) {
                if !selfClosing {
                    skipDepth = 1
                    skipName = name
                }
                continue
            }
            // A stray end tag for a noise container with no matching open: drop it.
            if case let .endTag(name) = token, names.contains(name) { continue }
            out.append(token)
        }
        return out
    }

    /// The inner tokens of the FIRST element named `name` (excluding its own start
    /// and matching end tag). Depth-tracked so nested same-name elements close
    /// correctly. Returns `nil` if the element is absent.
    private static func subtree(of name: String, in tokens: [Token]) -> [Token]? {
        var i = 0
        while i < tokens.count {
            if case let .startTag(tag, _, selfClosing) = tokens[i], tag == name, !selfClosing {
                var depth = 1
                var inner: [Token] = []
                var j = i + 1
                while j < tokens.count {
                    switch tokens[j] {
                    case let .startTag(t, _, sc) where t == name && !sc:
                        depth += 1
                    case let .endTag(t) where t == name:
                        depth -= 1
                        if depth == 0 { return inner }
                    default:
                        break
                    }
                    inner.append(tokens[j])
                    j += 1
                }
                // Unclosed: return everything after the open tag (tolerant).
                return inner
            }
            i += 1
        }
        return nil
    }

    // MARK: - Whitespace

    /// Collapse every run of ASCII/Unicode whitespace (incl. newlines, tabs) to a
    /// single space. Used for inline text where layout whitespace is insignificant.
    static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in s {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{0C}" || ch == "\u{A0}" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }
}
