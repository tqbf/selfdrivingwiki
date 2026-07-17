import Foundation

/// A structural block in rendered markdown — either a heading or a paragraph —
/// with an id that matches the `.id()` applied to its SwiftUI view. Built once
/// per render and used to resolve `#fragment` anchors for scroll-to.
///
/// Lists, tables, code blocks, and thematic breaks are NOT id'd in v1 — a quote
/// inside one resolves to the nearest preceding id'd block (degraded precision).
public struct AnchorBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case heading, paragraph }

    public let id: String
    public let kind: Kind
    public let text: String   // the text content (for slug/quote matching)

    // MARK: - Parse from rendered markdown

    /// Walk `renderedMarkdown` in document order and return an ordered list of
    /// `AnchorBlock`s — headings and paragraphs only. Paragraph ids are sequential
    /// (`p1`, `p2`, …); heading ids are the GFM slug (lowercased, spaces→`-`,
    /// alphanumeric filter, `-1/-2` dedup).
    ///
    /// The order matches Textual's `BlockVStack { ForEach(runs) { Block(…) } }`
    /// render order — both walk the document top-to-bottom. Paragraph numbering
    /// resets at 1 for each call.
    public static func parse(_ renderedMarkdown: String) -> [AnchorBlock] {
        var blocks: [AnchorBlock] = []
        var paragraphIndex = 0
        var slugCounts: [String: Int] = [:]

        // Split into top-level blocks on blank lines.
        let rawBlocks = splitBlocks(renderedMarkdown)

        for raw in rawBlocks {
            if let heading = parseHeading(raw, slugCounts: &slugCounts) {
                blocks.append(heading)
            } else if let para = parseParagraph(raw, index: &paragraphIndex) {
                blocks.append(para)
            }
            // Skip lists, code blocks, tables, thematic breaks, etc.
        }
        return blocks
    }

    // MARK: - Private block parsers

    /// Split markdown into top-level blocks on blank lines. Fenced code blocks
    /// (```…```) are kept as a single block even if they contain blank lines.
    private static func splitBlocks(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                current.append(line)
                if !inFence {
                    // Fence closed — flush as one block.
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else if inFence {
                current.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank line → flush current block.
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    /// Try to parse a heading block. A heading is one or more lines starting with
    /// `#` (ATX heading). Only the first line's heading prefix is used for the
    /// slug; continuation lines (rare) are part of the text.
    private static func parseHeading(
        _ block: String,
        slugCounts: inout [String: Int]
    ) -> AnchorBlock? {
        guard let firstLine = block.components(separatedBy: "\n").first,
              firstLine.hasPrefix("#") else { return nil }

        // Strip leading `#`s and whitespace to get heading text.
        let headingText = firstLine
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        guard !headingText.isEmpty else { return nil }

        let slug = makeSlug(headingText, counts: &slugCounts)
        return AnchorBlock(id: slug, kind: .heading, text: headingText)
    }

    /// Try to parse a paragraph block. Any non-empty block that isn't a heading,
    /// code fence, list item, table, blockquote, or thematic break is a paragraph.
    private static func parseParagraph(
        _ block: String,
        index: inout Int
    ) -> AnchorBlock? {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstLine = block.components(separatedBy: "\n").first ?? ""
        let lt = firstLine.trimmingCharacters(in: .whitespaces)

        // Skip non-paragraph blocks.
        if lt.hasPrefix("#") { return nil }           // heading
        if lt.hasPrefix("```") { return nil }          // code fence
        if lt.hasPrefix("- ") || lt.hasPrefix("* ") { return nil }  // unordered list
        if lt.hasPrefix(">") { return nil }            // blockquote
        if lt.range(of: "^\\d+\\. ", options: .regularExpression) != nil { return nil } // ordered list
        if lt.hasPrefix("|") { return nil }            // table
        if lt == "---" || lt == "***" || lt == "___" { return nil } // thematic break
        if lt.hasPrefix("[^") && lt.contains("]:") { return nil }   // footnote definition

        index += 1
        return AnchorBlock(id: "p\(index)", kind: .paragraph, text: trimmed)
    }

    // MARK: - Slug generation (GFM-style)

    /// GFM-style heading slug: lowercased, spaces→`-`, drop punctuation,
    /// collapse runs, dedup with `-1/-2` suffix.
    public static func makeSlug(_ headingText: String, counts: inout [String: Int]) -> String {
        let base = SlugUtils.slugBase(headingText)
        guard !base.isEmpty else { return "heading" }
        let count = counts[base, default: 0]
        counts[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
    }
}

// MARK: - Fragment resolution

/// Resolve a `#fragment` against an ordered block list. Slug-match first
/// (headings), then quote (substring) match against paragraph text. Returns
/// the block id to scroll to, or nil if nothing matches.
public func resolveAnchor(_ fragment: String, in blocks: [AnchorBlock]) -> String? {
    let f = fragment
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        .wikiNormalized

    // 1) Exact heading-slug match (match the heading's id field directly,
    //    since it was already slugified by parse()).
    if let h = blocks.first(where: { $0.kind == .heading && $0.id == f }) {
        return h.id
    }

    // 2) Quote (substring) match against any block text.
    if let b = blocks.first(where: { $0.text.wikiNormalized.contains(f) }) {
        return b.id
    }

    return nil
}

// MARK: - Find-bar match resolution (occurrence-aware)

/// Resolve a find-bar match to its anchor block, accounting for match order.
/// `occurrence` is 1-based — which match, in document order, to scroll to.
///
/// Unlike the single-match `resolveAnchor`, this walks blocks counting
/// non-overlapping matches so next/previous navigation steps through distinct
/// blocks instead of always landing on the first one that contains the text.
public func resolveAnchor(
    _ fragment: String,
    occurrence: Int,
    in blocks: [AnchorBlock]
) -> String? {
    guard occurrence > 0 else { return nil }
    let needle = fragment.wikiNormalized.lowercased()
    guard !needle.isEmpty else { return nil }

    // A heading slug is unique, so it can only ever be the first match.
    if occurrence == 1 {
        let slug = fragment.wikiNormalized
        if let h = blocks.first(where: { $0.kind == .heading && $0.id == slug }) {
            return h.id
        }
    }

    // Walk blocks in document order, accumulating non-overlapping
    // case-insensitive occurrences until we reach the target one.
    var seen = 0
    var firstMatching: String?
    for block in blocks {
        let c = countOccurrences(of: needle, in: block.text.wikiNormalized.lowercased())
        if c > 0, firstMatching == nil { firstMatching = block.id }
        seen += c
        if seen >= occurrence {
            return block.id
        }
    }
    // Occurrence overshoots the block-level count (match straddles a block
    // boundary, or rendered-text normalization differs from the raw content the
    // find bar searched) — fall back to the first block that held any match.
    return firstMatching
}

/// Count non-overlapping, case-sensitive occurrences of `needle` in `haystack`.
private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex,
          let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

// MARK: - wikiNormalized (shared with WikiText)

extension String {
    /// Collapse whitespace runs to a single space and trim — the same normalization
    /// used by `WikiText.normalized`, available here so `AnchorBlock` stays pure
    /// without importing the module's full normalization enum at the call site.
    public var wikiNormalized: String {
        self.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
