import Foundation

extension HTMLToMarkdown {

    /// Walks the (scoped) token stream and emits Markdown. A streaming renderer with
    /// a tiny explicit stack for list nesting + blockquote depth, rather than a full
    /// tree — tolerant of unbalanced tags (an unmatched `</ul>` just no-ops). Block
    /// elements flush the current line and insert blank-line separation; inline
    /// elements wrap the surrounding text.
    struct Renderer {
        /// Markup we treat as block-level: each forces a paragraph break.
        private static let blockTags: Set<String> = [
            "p", "div", "section", "article", "main", "header", "aside",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "ul", "ol", "li", "blockquote", "pre", "table", "tr",
            "figure", "figcaption", "hr",
        ]

        /// Accumulated output blocks (joined by blank lines at the end).
        private var blocks: [String] = []
        /// The line currently being built (inline content).
        private var line = ""
        /// Whether we're inside a `<pre>` (preserve whitespace, no entity collapse).
        private var preDepth = 0
        /// Whether we're inside inline `<code>` (no entity collapse, no nested md).
        private var codeDepth = 0
        /// List context stack: each entry is (ordered, itemCounter).
        private var listStack: [(ordered: Bool, counter: Int)] = []
        /// Blockquote nesting depth (prefix `> ` per level).
        private var quoteDepth = 0

        mutating func render(_ tokens: [Token]) -> String {
            for token in tokens {
                switch token {
                case let .startTag(name, attributes, selfClosing):
                    handleStart(name, attributes, selfClosing: selfClosing)
                case let .endTag(name):
                    handleEnd(name)
                case let .text(raw):
                    appendText(raw)
                }
            }
            flushLine()
            return assemble()
        }

        // MARK: - Start tags

        private mutating func handleStart(
            _ name: String, _ attributes: [String: String], selfClosing: Bool
        ) {
            switch name {
            case "br":
                line += "\n" + linePrefix()
            case "hr":
                flushLine()
                blocks.append("---")
            case "img":
                let alt = attributes["alt"].map { HTMLEntities.decode($0) } ?? ""
                let src = attributes["src"] ?? ""
                if !src.isEmpty || !alt.isEmpty {
                    line += "![\(escapeInline(alt))](\(src))"
                }
            case "a":
                // Defer: stash the href; the closing tag wraps the accumulated text.
                anchorHrefs.append(attributes["href"] ?? "")
                anchorMarks.append(line.count)
            case "strong", "b":
                line += "**"
            case "em", "i":
                line += "*"
            case "code" where preDepth == 0:
                codeDepth += 1
                line += "`"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushLine()
                let level = Int(String(name.dropFirst())) ?? 1
                line = String(repeating: "#", count: level) + " "
            case "p", "div", "section", "header", "aside", "figure", "figcaption", "table", "tr":
                flushLine()
            case "ul", "ol":
                flushLine()
                listStack.append((ordered: name == "ol", counter: 0))
            case "li":
                flushLine()
                startListItem()
            case "blockquote":
                flushLine()
                quoteDepth += 1
            case "pre":
                flushLine()
                preDepth += 1
                blocks.append("```")
                rawPre = ""
            default:
                break
            }
        }

        // MARK: - End tags

        private mutating func handleEnd(_ name: String) {
            switch name {
            case "a":
                closeAnchor()
            case "strong", "b":
                line += "**"
            case "em", "i":
                line += "*"
            case "code" where codeDepth > 0:
                codeDepth -= 1
                line += "`"
            case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "section",
                 "header", "aside", "figure", "figcaption", "li", "table", "tr":
                flushLine()
            case "ul", "ol":
                flushLine()
                if !listStack.isEmpty { listStack.removeLast() }
            case "blockquote":
                flushLine()
                if quoteDepth > 0 { quoteDepth -= 1 }
            case "pre":
                if preDepth > 0 { preDepth -= 1 }
                // Emit the captured raw block content, then close the fence.
                let body = rawPre.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                if !body.isEmpty { blocks.append(body) }
                blocks.append("```")
                rawPre = ""
                line = ""
            default:
                break
            }
        }

        // MARK: - Text

        private mutating func appendText(_ raw: String) {
            if preDepth > 0 {
                // Inside <pre>: preserve verbatim (entities still decode).
                rawPre += HTMLEntities.decode(raw)
                return
            }
            let decoded = HTMLEntities.decode(raw)
            if codeDepth > 0 {
                // Inline code: keep content literal, just normalize newlines to spaces.
                line += decoded.replacingOccurrences(of: "\n", with: " ")
                return
            }
            let collapsed = HTMLToMarkdown.collapseWhitespace(decoded)
            // Avoid a leading space at the very start of a fresh line.
            if line.isEmpty || line.hasSuffix(" ") || line.hasSuffix("\n") {
                line += collapsed.drop(while: { $0 == " " })
            } else {
                line += collapsed
            }
        }

        // MARK: - Lists

        private mutating func startListItem() {
            guard !listStack.isEmpty else {
                line = "- "
                return
            }
            let depth = listStack.count - 1
            listStack[listStack.count - 1].counter += 1
            let indent = String(repeating: "  ", count: depth)
            if listStack[listStack.count - 1].ordered {
                line = indent + "\(listStack[listStack.count - 1].counter). "
            } else {
                line = indent + "- "
            }
        }

        // MARK: - Anchors (deferred wrapping)

        private var anchorHrefs: [String] = []
        private var anchorMarks: [Int] = []
        private var rawPre = ""

        /// Close the innermost open `<a>`: wrap the text added since the open mark in
        /// `[text](href)`. An empty href or empty text degrades to plain text.
        private mutating func closeAnchor() {
            guard !anchorHrefs.isEmpty else { return }
            let href = anchorHrefs.removeLast()
            let mark = anchorMarks.removeLast()
            // The text typed since the <a> opened (mark is a character offset into
            // `line`, which only grows for inline content — safe because anchors
            // don't span block boundaries in well-formed inline HTML).
            guard mark <= line.count else { return }
            let start = line.index(line.startIndex, offsetBy: mark)
            let text = String(line[start...])
            guard !text.isEmpty else { return }
            if href.isEmpty {
                return  // leave the text as-is
            }
            line = String(line[..<start]) + "[\(text)](\(href))"
        }

        // MARK: - Flushing / assembly

        /// Emit the in-progress line as a block (with the active blockquote prefix),
        /// then reset it. A list item's leading indent (runs of two spaces produced
        /// by `startListItem` for nesting) is preserved; all other leading/trailing
        /// whitespace is trimmed.
        private mutating func flushLine() {
            let leadingSpaces = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let isListItem = trimmed.hasPrefix("- ")
                    || (trimmed.first?.isNumber == true && trimmed.contains(". "))
                let indent = (isListItem && leadingSpaces > 0)
                    ? String(repeating: " ", count: leadingSpaces) : ""
                blocks.append(quotePrefix() + indent + trimmed)
            }
            line = ""
        }

        /// The prefix prepended to continuation lines created by `<br>` — only the
        /// blockquote markers (list bullets are line-leading, not per-wrap).
        private func linePrefix() -> String { quotePrefix() }

        private func quotePrefix() -> String {
            quoteDepth > 0 ? String(repeating: "> ", count: quoteDepth) : ""
        }

        /// Escape Markdown control characters that would corrupt link/image syntax.
        private func escapeInline(_ s: String) -> String {
            s.replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "[", with: "\\[")
        }

        /// Join blocks with blank lines, collapse 3+ consecutive newlines to a
        /// paragraph break, and trim. Fenced code blocks already carry their own
        /// newlines, so we post-process to keep ``` on its own lines.
        private func assemble() -> String {
            var joined = blocks.joined(separator: "\n\n")
            // Fix code fences: an opening "```" then content then closing "```" got
            // joined with blank lines; tighten them so the fence hugs its content.
            joined = joined.replacingOccurrences(of: "```\n\n", with: "```\n")
            joined = joined.replacingOccurrences(of: "\n\n```", with: "\n```")
            // Collapse any run of 3+ newlines to exactly two.
            while joined.contains("\n\n\n") {
                joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
