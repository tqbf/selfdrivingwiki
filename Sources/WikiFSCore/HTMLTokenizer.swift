import Foundation

extension HTMLToMarkdown {

    /// One lexical token from the HTML stream. A deliberately tiny model — enough to
    /// drive the Markdown renderer, not a full DOM. `text` carries raw (still
    /// entity-encoded) character data; the renderer decodes entities so it can do so
    /// AFTER deciding code-vs-prose context.
    enum Token: Equatable {
        /// `<name attrs…>` — `selfClosing` is true for `<br/>` / `<img …/>` form.
        case startTag(name: String, attributes: [String: String], selfClosing: Bool)
        /// `</name>`
        case endTag(String)
        /// Character data between tags (raw, not entity-decoded).
        case text(String)
    }

    /// A tolerant HTML tokenizer. Single linear pass, bounded by input length; never
    /// throws and never loops on malformed input. Comments (`<!-- … -->`), the
    /// doctype, and CDATA-ish `<? … ?>` are skipped. An unterminated `<` (no closing
    /// `>`) is emitted as literal text so nothing is lost.
    enum Tokenizer {

        /// The HTML void elements — they never have an end tag, so the renderer must
        /// treat them as self-closing even when written without a trailing slash.
        static let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr",
        ]

        static func tokenize(_ html: String) -> [Token] {
            var tokens: [Token] = []
            let chars = Array(html)
            let n = chars.count
            var i = 0
            var textRun = ""

            func flushText() {
                if !textRun.isEmpty {
                    tokens.append(.text(textRun))
                    textRun = ""
                }
            }

            while i < n {
                let c = chars[i]
                guard c == "<" else {
                    textRun.append(c)
                    i += 1
                    continue
                }

                // Comment / doctype / processing instruction.
                if matches(chars, at: i, "<!--") {
                    flushText()
                    i = skipUntil(chars, from: i + 4, terminator: "-->") ?? n
                    continue
                }
                if i + 1 < n, chars[i + 1] == "!" || chars[i + 1] == "?" {
                    flushText()
                    i = (indexAfter(chars, from: i + 1, char: ">") ?? n)
                    continue
                }

                // A '<' not followed by a tag-name-ish char is literal text
                // (e.g. "a < b"). Tag names start with a letter or '/'.
                guard i + 1 < n, chars[i + 1] == "/" || chars[i + 1].isLetter else {
                    textRun.append(c)
                    i += 1
                    continue
                }

                // Find the matching '>'. Quotes inside attributes may contain '>',
                // so track quote state.
                guard let close = tagClose(chars, from: i + 1, limit: n) else {
                    // Unterminated tag — emit the rest as literal text, tolerantly.
                    textRun.append(contentsOf: chars[i..<n])
                    i = n
                    continue
                }

                flushText()
                let inner = String(chars[(i + 1)..<close])
                if let token = parseTag(inner) {
                    tokens.append(token)
                    // <script>/<style> raw-text content: consume verbatim until the
                    // matching end tag so '<' inside JS/CSS isn't mis-tokenized. The
                    // content is dropped later by scoping, but we must not choke on it.
                    if case let .startTag(name, _, selfClosing) = token,
                       (name == "script" || name == "style"), !selfClosing {
                        i = consumeRawText(chars, from: close + 1, endTag: name, into: &tokens)
                        continue
                    }
                }
                i = close + 1
            }
            flushText()
            return tokens
        }

        // MARK: - Tag parsing

        /// Parse the inside of a tag (between `<` and `>`). Returns `nil` for an
        /// empty/garbage tag body.
        private static func parseTag(_ inner: String) -> Token? {
            var body = inner
            if body.hasPrefix("/") {
                let name = body.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let clean = name.prefix { $0.isLetter || $0.isNumber }
                return clean.isEmpty ? nil : .endTag(String(clean))
            }
            var selfClosing = false
            if body.hasSuffix("/") {
                selfClosing = true
                body = String(body.dropLast())
            }
            let (name, attributes) = parseNameAndAttributes(body)
            guard !name.isEmpty else { return nil }
            if voidElements.contains(name) { selfClosing = true }
            return .startTag(name: name, attributes: attributes, selfClosing: selfClosing)
        }

        /// Split a start-tag body into a lowercased element name + an attribute map.
        /// A small state machine: read the name, then repeatedly read `key`,
        /// optional `=value` (quoted or bare). Robust to extra whitespace and
        /// valueless attributes.
        private static func parseNameAndAttributes(_ body: String) -> (String, [String: String]) {
            let chars = Array(body)
            let n = chars.count
            var i = 0

            func skipSpaces() { while i < n, chars[i].isWhitespace { i += 1 } }

            skipSpaces()
            var name = ""
            while i < n, !chars[i].isWhitespace { name.append(chars[i]); i += 1 }
            name = name.lowercased()

            var attributes: [String: String] = [:]
            while i < n {
                skipSpaces()
                guard i < n else { break }
                var key = ""
                while i < n, !chars[i].isWhitespace, chars[i] != "=" {
                    key.append(chars[i]); i += 1
                }
                let lowerKey = key.lowercased()
                skipSpaces()
                guard i < n, chars[i] == "=" else {
                    if !lowerKey.isEmpty { attributes[lowerKey] = "" }
                    continue
                }
                i += 1  // consume '='
                skipSpaces()
                guard i < n else {
                    if !lowerKey.isEmpty { attributes[lowerKey] = "" }
                    break
                }
                var value = ""
                if chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    while i < n, chars[i] != quote { value.append(chars[i]); i += 1 }
                    if i < n { i += 1 }  // consume closing quote
                } else {
                    while i < n, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
                if !lowerKey.isEmpty { attributes[lowerKey] = HTMLEntities.decode(value) }
            }
            return (name, attributes)
        }

        // MARK: - Scanning helpers

        /// The index of the `>` that closes a tag opened at `from`, honoring quoted
        /// attribute values (so `<a title="a>b">` closes at the second `>`). `nil`
        /// if none before `limit`.
        private static func tagClose(_ chars: [Character], from: Int, limit: Int) -> Int? {
            var i = from
            var quote: Character?
            while i < limit {
                let c = chars[i]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    return i
                }
                i += 1
            }
            return nil
        }

        /// Consume raw text after a `<script>`/`<style>` open tag up to (and
        /// including) the matching `</name>`. Appends a single `.text` token with the
        /// raw content and the matching `.endTag`. Returns the index just past the
        /// end tag (or `count` if unterminated).
        private static func consumeRawText(
            _ chars: [Character], from: Int, endTag name: String, into tokens: inout [Token]
        ) -> Int {
            let needle = Array("</\(name)")
            var i = from
            let n = chars.count
            var content = ""
            while i < n {
                if matches(chars, at: i, String(needle)) {
                    tokens.append(.text(content))
                    // Skip to the '>' that closes the end tag.
                    let close = indexAfter(chars, from: i, char: ">") ?? n
                    tokens.append(.endTag(name))
                    return close
                }
                content.append(chars[i])
                i += 1
            }
            tokens.append(.text(content))
            return n
        }

        /// True if `needle` (lowercased compare) starts at `chars[at]`.
        private static func matches(_ chars: [Character], at: Int, _ needle: String) -> Bool {
            let needleChars = Array(needle)
            guard at + needleChars.count <= chars.count else { return false }
            for k in 0..<needleChars.count {
                if Character(chars[at + k].lowercased()) != Character(needleChars[k].lowercased()) {
                    return false
                }
            }
            return true
        }

        /// Index just past the next occurrence of `terminator` starting at `from`.
        private static func skipUntil(_ chars: [Character], from: Int, terminator: String) -> Int? {
            var i = from
            while i < chars.count {
                if matches(chars, at: i, terminator) { return i + terminator.count }
                i += 1
            }
            return nil
        }

        /// Index just past the next `char` at/after `from`.
        private static func indexAfter(_ chars: [Character], from: Int, char: Character) -> Int? {
            var i = from
            while i < chars.count {
                if chars[i] == char { return i + 1 }
                i += 1
            }
            return nil
        }
    }
}
