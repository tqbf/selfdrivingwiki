import Foundation
import Markdown
import WikiFSTypes
import WikiFSLinks
import WikiFSMarkdown

/// The pure v1 detector helpers behind ``LintPagePreflight`` (plan phase 4).
/// Every detector reports FACTS and CANDIDATES — it never authorizes a repair
/// by itself, never writes, and never executes page content. All ranges are
/// authored UTF-8 byte offsets (half-open). Protected code is byte-masked to
/// spaces before textual scans, so a match's range is valid in the original
/// body and literal examples inside code are never findings (REQ-42).
extension LintPagePreflight {

    /// A detector's raw output before occurrence numbering.
    struct DetectedFinding {
        let defectClass: LintDefectClass
        let range: MarkdownSourceRange?
        let evidence: String
        let message: String
        let severity: LintSeverity
        let confidence: LintConfidence
        var candidateRepair: LintCandidateRepair?

        init(
            _ defectClass: LintDefectClass,
            _ range: MarkdownSourceRange?,
            _ evidence: String,
            _ message: String,
            _ severity: LintSeverity,
            _ confidence: LintConfidence,
            candidateRepair: LintCandidateRepair? = nil
        ) {
            self.defectClass = defectClass
            self.range = range
            self.evidence = evidence
            self.message = message
            self.severity = severity
            self.confidence = confidence
            self.candidateRepair = candidateRepair
        }
    }

    /// Named detector thresholds and reviewed word lists (v1). Changing a
    /// value changes detector behavior — the detector revision moves with it.
    enum DetectorConstants {
        /// D27: a body shrank to less than this fraction of its parent's byte
        /// size becomes a regression candidate (plan: 30-percent threshold).
        static let shrinkageThreshold = 0.70
        /// D15: an exact-duplicate block must carry at least this many
        /// non-whitespace characters before it is a candidate.
        static let duplicateBlockMinimumCharacters = 80
        /// D14: reviewed placeholder markers (case-sensitive set).
        static let placeholderMarkers = ["TODO", "FIXME", "TBD", "XXX"]
        /// D14: reviewed placeholder shapes (case-insensitive).
        static let placeholderPatterns = [
            #"(?i)\blorem ipsum\b"#,
            #"(?i)\[(placeholder|insert[^\]]{0,60})\]"#,
        ]
        /// D24: reviewed meta-text phrases (case-insensitive, word-bounded).
        static let metaTextPhrases = [
            "as an ai", "i'm an ai", "i am an ai", "i cannot comply",
            "i can't comply", "system prompt", "language model", "knowledge cutoff",
        ]
        /// D24: reviewed tool-output markers (case-sensitive, structural).
        static let toolOutputMarkers = [
            "<tool_use", "</tool", "tool_use_id", "<system>", "</system>",
            "<function", "<result>", "[TOOL]", "antml:",
        ]
        /// D17: bounded mojibake sequences (UTF-8 decoded as Latin-1 style).
        static let mojibakeSequences = ["Ã¢â‚¬", "â€œ", "â€\u{9D}", "â€™"]
        /// D18: active-content tag names (case-insensitive).
        static let activeContentTags = "script|iframe|object|embed|form"
    }

    // MARK: - Shared text helpers

    /// Evidence excerpt for a substring slice (byte-offset text).
    static func excerpt(
        of text: Substring,
        limit: Int = LintPreflightReport.Limits.evidenceCharacters
    ) -> String {
        excerpt(of: String(text), limit: limit)
    }

    /// The body with every protected-code byte replaced by a space. Byte
    /// offsets are preserved exactly, so ranges computed on the masked text
    /// are valid in the original body.
    static func byteMasked(_ source: String, protectedUTF8: [MarkdownSourceRange]) -> String {
        var bytes = Array(source.utf8)
        for range in protectedUTF8 where range.upperBound <= bytes.count {
            for index in range.lowerBound..<max(range.lowerBound, range.upperBound) {
                bytes[index] = 0x20
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Flattened plain text of a markup subtree (headings, link labels).
    static func flattenedText(_ markup: Markup) -> String {
        if let text = markup as? Text { return text.string }
        return markup.children.map { flattenedText($0) }.joined()
    }

    /// Compile a constant regex — failure is a programmer error, so the force
    /// try is confined to literal patterns defined above.
    private static func constantRegex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Matches of `regexes` over masked text, in pattern then position order.
    private static func regexMatches(
        _ regexes: [NSRegularExpression],
        in masked: String
    ) -> [(NSTextCheckingResult, NSRegularExpression)] {
        let ns = masked as NSString
        var matches: [(NSTextCheckingResult, NSRegularExpression)] = []
        for regex in regexes {
            regex.enumerateMatches(in: masked, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                if let match { matches.append((match, regex)) }
            }
        }
        return matches.sorted { $0.0.range.location < $1.0.range.location }
    }

    // MARK: - D01 fence boundary candidates

    /// Inner lines of a fenced block that resemble a closing delimiter but
    /// cannot close the block: a shorter marker run than the opening, or a
    /// valid-length run carrying trailing text. Candidates only — literal
    /// examples of fences inside code blocks also match. A legal EOF closure
    /// is never reported.
    static func fenceBoundaryCandidates(
        body: String,
        fenceFacts: [MarkdownFenceFact]
    ) -> [DetectedFinding] {
        guard fenceFacts.isEmpty == false else { return [] }
        let lines = ParsedMarkdownDocument.authoredLines(of: body)
        var findings: [DetectedFinding] = []
        for fence in fenceFacts {
            let innerStart = fence.openingRange.upperBound
            let innerEnd = fence.closingRange?.lowerBound ?? fence.blockRange.upperBound
            for line in lines where line.utf8Range.lowerBound >= innerStart
                && line.utf8Range.upperBound <= innerEnd
                && line.utf8Range.count > 0 {
                let inspection = Self.inspectSuspiciousClosure(line.text, fence: fence)
                guard let inspection else { continue }
                let markerRange = ParsedMarkdownDocument.safeRange(
                    line.utf8Range.lowerBound + inspection.markerStart,
                    line.utf8Range.lowerBound + inspection.markerEnd)
                findings.append(DetectedFinding(
                    .fenceBoundaryDamage,
                    markerRange,
                    excerpt(of: line.text),
                    "This line resembles a \(fence.marker.rawValue) delimiter but cannot close the block (\(inspection.reason)) — the block continues past it. Confirm whether it is fence-example content or boundary damage.",
                    .major,
                    .candidate))
            }
        }
        return findings
    }

    /// Why an inner line fails to close `fence`, plus the marker run's bounds.
    private static func inspectSuspiciousClosure(
        _ line: Substring,
        fence: MarkdownFenceFact
    ) -> (reason: String, markerStart: Int, markerEnd: Int)? {
        let bytes = Array(line.utf8)
        var index = 0
        var indent = 0
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
            indent += 1
        }
        guard indent <= 3 else { return nil }
        let markerByte: UInt8 = fence.marker == .backtick ? 0x60 : 0x7E
        guard index < bytes.count, bytes[index] == markerByte else { return nil }
        let markerStart = index
        while index < bytes.count, bytes[index] == markerByte {
            index += 1
        }
        let runLength = index - markerStart
        let rest = bytes[index...]
        let trailing = String(decoding: rest, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if runLength < fence.length, trailing.isEmpty {
            return ("the run is shorter than the opening fence's \(fence.length)", markerStart, index)
        }
        if runLength >= fence.length, trailing.isEmpty == false {
            return ("a closing delimiter may not carry trailing text", markerStart, index)
        }
        return nil
    }

    // MARK: - D03 table candidates

    /// Table-shape damage: (a) pipe/delimiter line pairs with the GFM shape
    /// that did not parse as a table, and (b) parsed tables whose body rows
    /// declare a different cell count than the header. Missing cells are
    /// never reconstructed mechanically.
    static func tableCandidates(parsed: ParsedMarkdownDocument) -> [DetectedFinding] {
        let source = parsed.sourceMarkdown
        let lines = ParsedMarkdownDocument.authoredLines(of: source)
        var tableRanges: [MarkdownSourceRange] = []
        collectTables(from: parsed.document, parsed: parsed) { range in
            if let range { tableRanges.append(range) }
        }
        func insideParsedTable(_ range: MarkdownSourceRange) -> Bool {
            tableRanges.contains { $0.intersects(range) }
        }

        var findings: [DetectedFinding] = []
        guard lines.count > 1 else { return findings }
        for index in 0..<(lines.count - 1) {
            let headerLine = lines[index]
            let delimiterLine = lines[index + 1]
            guard insideParsedTable(headerLine.utf8Range) == false,
                  insideParsedTable(delimiterLine.utf8Range) == false,
                  Self.containsUnescapedPipe(headerLine.text),
                  let delimiterCells = Self.delimiterRowCells(delimiterLine.text) else {
                continue
            }
            let headerCells = Self.pipeCells(headerLine.text)
            let shapeNote = headerCells == delimiterCells.count
                ? "the row shapes agree, so another detail prevented the parse"
                : "the header declares \(headerCells) cell(s) but the separator row declares \(delimiterCells.count)"
            findings.append(DetectedFinding(
                .tableDamage,
                ParsedMarkdownDocument.safeRange(
                    headerLine.utf8Range.lowerBound, delimiterLine.utf8Range.upperBound),
                excerpt(of: headerLine.text + "\n" + delimiterLine.text),
                "These lines have the shape of a table header and separator row, but the reader's parser did not produce a table (\(shapeNote)).",
                .major,
                .confirmed))
        }

        // Parsed tables: body rows whose SOURCE pipe count differs from the
        // header's. The AST cannot report this — cmark truncates over-long
        // rows to the header's width — so the row lines are counted from the
        // source itself. Missing cells are never reconstructed mechanically.
        for table in collectTableNodes(from: parsed.document) {
            guard let tableRange = table.range, let range = parsed.utf8Range(of: tableRange) else {
                continue
            }
            let headerCellCount = table.head.range.flatMap { headRange in
                parsed.utf8Range(of: headRange)
            }.map { Self.pipeCells(sourceLine(containing: $0.lowerBound, lines: lines)) }
                ?? table.head.childCount
            for row in table.body.rows {
                guard let rowRange = row.range, let rowSourceRange = parsed.utf8Range(of: rowRange) else {
                    continue
                }
                let rowCellCount = Self.pipeCells(sourceLine(containing: rowSourceRange.lowerBound, lines: lines))
                guard rowCellCount != headerCellCount else { continue }
                findings.append(DetectedFinding(
                    .tableDamage,
                    rowSourceRange,
                    excerpt(of: slice(source, range)),
                    "Table row declares \(rowCellCount) cell(s); the header declares \(headerCellCount). The reader renders the difference as empty or overflowing cells — fill or trim cells deliberately; they are never reconstructed mechanically.",
                    .minor,
                    .candidate))
            }
        }
        return findings
    }

    /// The authored line containing a byte offset.
    private static func sourceLine(
        containing offset: Int,
        lines: [ParsedMarkdownDocument.AuthoredLine]
    ) -> Substring {
        lines.first { $0.utf8Range.lowerBound <= offset && offset < $0.utf8Range.upperBound }?.text ?? ""
    }

    private static func collectTableNodes(from markup: Markup) -> [Table] {
        var tables: [Table] = []
        if let table = markup as? Table { tables.append(table) }
        for child in markup.children {
            tables.append(contentsOf: collectTableNodes(from: child))
        }
        return tables
    }

    /// Cells of a GFM delimiter row (`| --- | :---: |`), or `nil` when the
    /// line is not one. Respects container prefixes, up to 3 indent spaces,
    /// optional outer pipes, and alignment colons.
    static func delimiterRowCells(_ line: Substring) -> [String]? {
        var text = Substring(line)
        // Strip container prefixes and indentation.
        while text.hasPrefix(">") || text.hasPrefix(" ") || text.hasPrefix("\t") {
            text = text.dropFirst()
            if text.hasPrefix(" ") || text.hasPrefix("\t") { continue }
        }
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        guard trimmed.contains("-") else { return nil }
        let cells = trimmed.components(separatedBy: "|")
        guard cells.contains(where: { !$0.isEmpty }) else { return nil }
        for cell in cells {
            let compact = cell.trimmingCharacters(in: .whitespaces)
            guard Self.isDelimiterCell(compact) else { return nil }
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        guard cell.isEmpty == false else { return true } // outer-pipe artifact
        var index = cell.startIndex
        if cell[index] == ":" { index = cell.index(after: index) }
        var dashes = 0
        while index < cell.endIndex, cell[index] == "-" {
            index = cell.index(after: index)
            dashes += 1
        }
        if index < cell.endIndex, cell[index] == ":" { index = cell.index(after: index) }
        return dashes >= 1 && index == cell.endIndex
    }

    /// Cell count of a pipe row, dropping the optional outer-pipe artifacts.
    static func pipeCells(_ line: Substring) -> Int {
        var cells = line.components(separatedBy: "|")
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return max(cells.count, 0)
    }

    /// `true` when the line carries a pipe that is neither escaped nor inside
    /// an inline-code span (backtick-run parity approximation).
    static func containsUnescapedPipe(_ line: Substring) -> Bool {
        var inCode = false
        var previous: Character?
        for character in line {
            if character == "`" { inCode.toggle() }
            if character == "|", inCode == false, previous != "\\" {
                return true
            }
            previous = character
        }
        return false
    }

    // MARK: - D02 delimiter damage (report-only)

    /// Suspicious recognized inline constructs: an odd count of bare
    /// backticks (an unclosed inline-code run makes the rest literal) or an
    /// odd count of bold markers per paragraph. Report-only in v1.
    static func inlineDelimiterCandidates(
        parsed: ParsedMarkdownDocument,
        protectedUTF8: [MarkdownSourceRange]
    ) -> [DetectedFinding] {
        let masked = byteMasked(parsed.sourceMarkdown, protectedUTF8: protectedUTF8)
        var findings: [DetectedFinding] = []
        forEachNode(parsed.document, of: Paragraph.self) { paragraph in
            guard let nodeRange = paragraph.range, let range = parsed.utf8Range(of: nodeRange) else {
                return
            }
            guard let lower = masked.utf8.index(masked.utf8.startIndex, offsetBy: range.lowerBound, limitedBy: masked.utf8.endIndex),
                  let upper = masked.utf8.index(masked.utf8.startIndex, offsetBy: range.upperBound, limitedBy: masked.utf8.endIndex) else {
                return
            }
            let text = String(decoding: masked.utf8[lower..<upper], as: UTF8.self)
            let backticks = text.filter { $0 == "`" }.count
            if backticks % 2 == 1 {
                findings.append(DetectedFinding(
                    .delimiterDamage,
                    range,
                    excerpt(of: slice(parsed.sourceMarkdown, range)),
                    "An odd number of bare backticks leaves an inline-code run unclosed, so the rest of the paragraph renders as literal code (report-only in v1).",
                    .minor,
                    .candidate))
                return
            }
            let bold = text.occurrenceCount(of: "**") + text.occurrenceCount(of: "__")
            if bold % 2 == 1 {
                findings.append(DetectedFinding(
                    .delimiterDamage,
                    range,
                    excerpt(of: slice(parsed.sourceMarkdown, range)),
                    "An odd number of bold delimiters (**/__) leaves one unmatched (report-only in v1).",
                    .minor,
                    .candidate))
            }
        }
        return findings
    }

    // MARK: - D04 list nesting damage (report-only)

    /// Suspicious indentation transitions between list items, and indented
    /// code blocks that start right after prose (a possible accidental code
    /// block). Report-only in v1.
    static func indentationCandidates(
        parsed: ParsedMarkdownDocument,
        fenceFacts: [MarkdownFenceFact],
        protectedUTF8: [MarkdownSourceRange]
    ) -> [DetectedFinding] {
        let source = parsed.sourceMarkdown
        let masked = byteMasked(source, protectedUTF8: protectedUTF8)
        let itemPattern = constantRegex(#"^[ \t]*([-*+]|\d{1,9}[.)])(?:[ \t]+|$)"#)

        var findings: [DetectedFinding] = []

        // Part 1 — item indentation jumps (list items are never code-
        // protected, so masked lines carry exactly the real items).
        var previous: (indent: Int, markerWidth: Int)?
        for line in ParsedMarkdownDocument.authoredLines(of: masked) {
            let ns = line.text as NSString
            guard let item = itemPattern.firstMatch(
                in: String(line.text),
                range: NSRange(location: 0, length: ns.length)) else {
                previous = nil
                continue
            }
            let indent = leadingIndent(of: line.text)
            let markerWidth = item.range.length - indent
            if let previous, indent > previous.indent + previous.markerWidth + 1 {
                findings.append(DetectedFinding(
                    .listNestingDamage,
                    line.utf8Range,
                    excerpt(of: line.text),
                    "This item indents \(indent - previous.indent) spaces deeper than the previous item's nesting column — confirm the nesting is intentional (report-only in v1).",
                    .minor,
                    .candidate))
            }
            previous = (indent, markerWidth)
        }

        // Part 2 — unfenced (indented) code blocks that directly follow
        // prose: a classic accidental code block. Fenced blocks are exempt.
        let fencedRanges = fenceFacts.map(\.blockRange)
        forEachNode(parsed.document, of: CodeBlock.self) { block in
            guard let nodeRange = block.range, let blockRange = parsed.utf8Range(of: nodeRange),
                  fencedRanges.contains(where: { $0.intersects(blockRange) }) == false else {
                return
            }
            let lines = ParsedMarkdownDocument.authoredLines(of: source)
            // The converted block range starts at the CONTENT (after the
            // indent), so match the first line that overlaps it.
            guard let firstLine = lines.first(where: {
                $0.utf8Range.upperBound > blockRange.lowerBound
                    && $0.utf8Range.lowerBound < blockRange.upperBound
            }) else { return }
            let index = lines.firstIndex { $0.utf8Range.lowerBound == firstLine.utf8Range.lowerBound }
            guard let index, index > 0 else { return }
            // Walk back to the nearest non-blank line: a blank separator is
            // required before an indented code block, so the question is
            // whether the nearest CONTENT above is prose.
            var cursor = lines.index(before: index)
            while cursor >= lines.startIndex,
                  lines[cursor].text.trimmingCharacters(in: .whitespaces).isEmpty {
                cursor = lines.index(before: cursor)
            }
            guard cursor >= lines.startIndex else { return }
            let previousLine = lines[cursor]
            guard itemPattern.firstMatch(
                in: String(previousLine.text),
                range: NSRange(location: 0, length: (previousLine.text as NSString).length)) == nil
            else { return }
            findings.append(DetectedFinding(
                .listNestingDamage,
                firstLine.utf8Range,
                excerpt(of: firstLine.text),
                "This line indents 4+ spaces directly after prose, so the reader renders it as an indented code block — confirm that is intended (report-only in v1).",
                .minor,
                .candidate))
        }
        return findings
    }

    private static func leadingIndent(of line: Substring) -> Int {
        var indent = 0
        for character in line {
            if character == "\t" { indent += 4 }
            else if character == " " { indent += 1 }
            else { break }
        }
        return indent
    }

    // MARK: - D05 heading damage (report-only)

    /// Repeated headings and heading-level jumps. Report-only in v1: style
    /// conventions never become confirmed defects.
    static func headingCandidates(parsed: ParsedMarkdownDocument) -> [DetectedFinding] {
        var findings: [DetectedFinding] = []
        var seenHeadings: [String: MarkdownSourceRange] = [:]
        var previousLevel: Int?
        forEachNode(parsed.document, of: Heading.self) { heading in
            guard let nodeRange = heading.range, let range = parsed.utf8Range(of: nodeRange) else {
                return
            }
            let text = LintCitationFacts.normalizedFragment(flattenedText(heading))
            if let previousLevel, heading.level > previousLevel + 1 {
                findings.append(DetectedFinding(
                    .headingDamage,
                    range,
                    excerpt(of: slice(parsed.sourceMarkdown, range)),
                    "This heading jumps from level \(previousLevel) to level \(heading.level), skipping a level (report-only in v1).",
                    .minor,
                    .candidate))
            }
            if let firstRange = seenHeadings[text] {
                findings.append(DetectedFinding(
                    .headingDamage,
                    range,
                    excerpt(of: slice(parsed.sourceMarkdown, range)),
                    "This heading text repeats the heading at byte \(firstRange.lowerBound) (report-only in v1).",
                    .minor,
                    .candidate))
            } else {
                seenHeadings[text] = range
            }
            previousLevel = heading.level
        }
        return findings
    }

    // MARK: - D14 placeholder residue (report-only)

    /// Reviewed placeholder markers outside code. Report-only in v1.
    static func placeholderCandidates(
        maskedBody: String,
        source: String
    ) -> [DetectedFinding] {
        let wordPattern = constantRegex(
            "\\b(" + DetectorConstants.placeholderMarkers.joined(separator: "|") + ")\\b")
        let regexes = [wordPattern]
            + DetectorConstants.placeholderPatterns.map { constantRegex($0) }
        return regexMatches(regexes, in: maskedBody).map { match, _ in
            DetectedFinding(
                .placeholderResidue,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Placeholder marker present — content may be unfinished (report-only in v1).",
                .minor,
                .candidate)
        }
    }

    // MARK: - D15 merge markers and duplicate blocks

    /// One duplicate-block occurrence (paragraph or heading).
    private struct BlockOccurrence {
        let normalized: String
        let range: MarkdownSourceRange
    }

    /// Exact duplicate leaf blocks (paragraphs and headings).
    /// Loss alone never authorizes restoration, so no repair is proposed.
    static func mergeMarkerAndDuplicateCandidates(
        parsed: ParsedMarkdownDocument,
        protectedUTF8: [MarkdownSourceRange]
    ) -> [DetectedFinding] {
        let source = parsed.sourceMarkdown
        let masked = byteMasked(source, protectedUTF8: protectedUTF8)
        var findings: [DetectedFinding] = []

        let markerPattern = constantRegex(#"^[ ]{0,3}(<{7}( |$)|\|{7}( |$)|={7}$|>{7}( |$))"#)
        for line in ParsedMarkdownDocument.authoredLines(of: masked) {
            let ns = line.text as NSString
            guard markerPattern.firstMatch(
                in: String(line.text),
                range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            findings.append(DetectedFinding(
                .duplicateBlocksOrMergeResidue,
                line.utf8Range,
                excerpt(of: line.text),
                "Version-control conflict marker present — the surrounding content needs a deliberate resolution.",
                .major,
                .confirmed))
        }

        var occurrences: [BlockOccurrence] = []
        forEachNode(parsed.document, of: Paragraph.self) { node in
            appendBlock(node, parsed: parsed, into: &occurrences)
        }
        forEachNode(parsed.document, of: Heading.self) { node in
            appendBlock(node, parsed: parsed, into: &occurrences)
        }
        var byText: [String: [MarkdownSourceRange]] = [:]
        for occurrence in occurrences {
            byText[occurrence.normalized, default: []].append(occurrence.range)
        }
        for (text, ranges) in byText where ranges.count > 1 {
            for range in ranges.dropFirst() {
                let nonWhitespace = text.replacingOccurrences(of: " ", with: "").count
                guard nonWhitespace >= DetectorConstants.duplicateBlockMinimumCharacters else {
                    continue
                }
                findings.append(DetectedFinding(
                    .duplicateBlocksOrMergeResidue,
                    range,
                    excerpt(of: slice(source, range)),
                    "This block duplicates the block at byte \(ranges[0].lowerBound) exactly (\(nonWhitespace) non-whitespace characters). Intentional repetition is possible — confirm before treating it as paste damage.",
                    .major,
                    .candidate))
            }
        }
        return findings
    }

    private static func appendBlock(
        _ node: some Markup,
        parsed: ParsedMarkdownDocument,
        into occurrences: inout [BlockOccurrence]
    ) {
        guard let nodeRange = node.range, let range = parsed.utf8Range(of: nodeRange) else {
            return
        }
        let text = LintCitationFacts.normalizedFragment(slice(parsed.sourceMarkdown, range))
        guard text.isEmpty == false else { return }
        occurrences.append(BlockOccurrence(normalized: text, range: range))
    }

    // MARK: - D17 / D26 encoding and escaping damage

    /// Replacement characters, prohibited control characters, and bounded
    /// mojibake sequences (D17); bidi controls, double HTML entities, and
    /// escaped wiki syntax (D26). Replacement characters are never guessed.
    static func encodingAndEscapingCandidates(
        source: String,
        maskedBody: String,
        wikiNodes: [WikiMarkdownSyntaxNode]
    ) -> [DetectedFinding] {
        var findings: [DetectedFinding] = []
        var offset = 0
        for scalar in maskedBody.unicodeScalars {
            let width = UTF8.width(scalar)
            defer { offset += width }
            let range = ParsedMarkdownDocument.safeRange(offset, offset + width)
            if scalar.value == 0xFFFD {
                findings.append(DetectedFinding(
                    .encodingDamage,
                    range,
                    "U+FFFD",
                    "Unicode replacement character present — the intended text is unknown and is never guessed.",
                    .minor,
                    .confirmed))
                continue
            }
            let isProhibitedControl =
                (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
            if isProhibitedControl {
                findings.append(DetectedFinding(
                    .encodingDamage,
                    range,
                    "U+\(String(scalar.value, radix: 16, uppercase: true))",
                    "Prohibited control character present.",
                    .minor,
                    .confirmed))
                continue
            }
            let isBidiControl =
                (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
            if isBidiControl {
                let insideTarget = wikiNodes.contains { $0.sourceRange.intersects(range) }
                findings.append(DetectedFinding(
                    .escapingLayerDamage,
                    range,
                    "U+\(String(scalar.value, radix: 16, uppercase: true))",
                    insideTarget
                        ? "Bidirectional control character inside a wiki-link target — the target cannot resolve while it is present."
                        : "Bidirectional control character outside code — text may render in a misleading direction.",
                    insideTarget ? .major : .minor,
                    .candidate))
            }
        }

        let mojibakeRegexes = DetectorConstants.mojibakeSequences.map {
            constantRegex(NSRegularExpression.escapedPattern(for: $0))
        }
        for (match, _) in regexMatches(mojibakeRegexes, in: maskedBody) {
            findings.append(DetectedFinding(
                .encodingDamage,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Mojibake candidate — text that looks like UTF-8 bytes decoded as Latin-1. Confirm the intended characters; they are never guessed.",
                .minor,
                .candidate))
        }

        let doubleEntityPattern = constantRegex(#"&amp;[a-zA-Z]{2,8};"#)
        for (match, _) in regexMatches([doubleEntityPattern], in: maskedBody) {
            let matched = (source as NSString).substring(with: match.range)
            let decoded = "&" + matched.dropFirst("&amp;".count)
            findings.append(DetectedFinding(
                .escapingLayerDamage,
                utf8Range(match.range, in: source),
                excerpt(of: matched),
                "Double-escaped HTML entity — the entity was escaped twice, so it renders as literal entity text.",
                .minor,
                .candidate,
                candidateRepair: LintCandidateRepair(
                    change: .replacement(text: decoded),
                    reason: "decode the double-escaped entity to its single-escaped form")))
        }

        let escapedWikiPattern = constantRegex(#"\\(!?\[\[|\]\])"#)
        for (match, _) in regexMatches([escapedWikiPattern], in: maskedBody) {
            findings.append(DetectedFinding(
                .escapingLayerDamage,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Escaped wiki-link syntax outside code — confirm whether the brackets were meant to render literally or the escape is layer damage.",
                .minor,
                .candidate))
        }
        return findings
    }

    // MARK: - D18 pasted active content (report-only)

    /// Active constructs and dangerous schemes outside literal examples.
    /// Report-only: pre-flight never executes or sanitizes content.
    static func activeContentCandidates(
        source: String,
        maskedBody: String
    ) -> [DetectedFinding] {
        let regexes = [
            constantRegex("(?i)<\\s*(?:" + DetectorConstants.activeContentTags + ")\\b"),
            constantRegex(#"(?i)\son[a-z]+\s*="#),
            constantRegex(#"(?i)\b(javascript|vbscript)\s*:"#),
            constantRegex(#"(?i)\bdata:text/html\b"#),
        ]
        return regexMatches(regexes, in: maskedBody).map { match, _ in
            DetectedFinding(
                .pastedActiveContent,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Active content construct present (report-only): the lint never executes or sanitizes content — confirm this is intended literal text.",
                .major,
                .confirmed)
        }
    }

    // MARK: - D23 truncated output

    /// Incomplete final constructs as candidates — never a truth verdict
    /// about whether the page was actually cut off.
    static func truncationCandidates(
        source: String,
        maskedBody: String
    ) -> [DetectedFinding] {
        guard let lastLine = ParsedMarkdownDocument.authoredLines(of: maskedBody)
            .last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return []
        }
        var findings: [DetectedFinding] = []
        let backticks = lastLine.text.filter { $0 == "`" }.count
        if backticks % 2 == 1 {
            findings.append(DetectedFinding(
                .truncatedOutput,
                lastLine.utf8Range,
                excerpt(of: lastLine.text),
                "The final line opens an inline-code run that never closes — the page may end mid-construct.",
                .major,
                .candidate))
        }
        var opens = 0
        var previous: Character?
        for character in lastLine.text {
            if character == "`" { break } // the rest is an (unclosed) code span
            if character == "(" || character == "[", previous != "\\" { opens += 1 }
            if character == ")" || character == "]", previous != "\\" { opens -= 1 }
            previous = character
        }
        if opens > 0 {
            findings.append(DetectedFinding(
                .truncatedOutput,
                lastLine.utf8Range,
                excerpt(of: lastLine.text),
                "The final line opens \(opens) bracket(s) that never close — the page may end mid-construct.",
                .major,
                .candidate))
        }
        return findings
    }

    // MARK: - D24 meta-text leakage

    /// Reviewed meta-text phrases and tool-output markers outside literals.
    /// Phrase matches are candidates; structural tool markers are confirmed
    /// facts of presence.
    static func metaTextLeakageCandidates(
        source: String,
        maskedBody: String
    ) -> [DetectedFinding] {
        var findings: [DetectedFinding] = []
        let phraseRegexes = DetectorConstants.metaTextPhrases.map {
            constantRegex("(?i)\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b")
        }
        for (match, _) in regexMatches(phraseRegexes, in: maskedBody) {
            findings.append(DetectedFinding(
                .metaTextLeakage,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Meta-text phrase candidate — confirm whether this is page content or pasted assistant output.",
                .minor,
                .candidate))
        }
        let markerRegexes = DetectorConstants.toolOutputMarkers.map {
            constantRegex(NSRegularExpression.escapedPattern(for: $0))
        }
        for (match, _) in regexMatches(markerRegexes, in: maskedBody) {
            findings.append(DetectedFinding(
                .metaTextLeakage,
                utf8Range(match.range, in: source),
                excerpt(of: (source as NSString).substring(with: match.range)),
                "Tool-output marker present — this looks like pasted tool traffic rather than page content.",
                .major,
                .confirmed))
        }
        return findings
    }

    // MARK: - D20 missing references and media

    /// Markdown reference-label usages without a definition, and image/link
    /// destinations that cannot resolve in this wiki (relative paths carry no
    /// scheme and no anchor). Remote network failure is never evidence.
    static func referenceAndMediaCandidates(
        parsed: ParsedMarkdownDocument,
        maskedBody: String
    ) -> [DetectedFinding] {
        let source = parsed.sourceMarkdown
        var findings: [DetectedFinding] = []

        // Defined reference labels: `[label]: destination` lines outside code.
        let definitionPattern = constantRegex(#"^[ ]{0,3}\[([^\]\[]+)\]:[ \t]*\S"#)
        var definedLabels: Set<String> = []
        for line in ParsedMarkdownDocument.authoredLines(of: maskedBody) {
            let ns = line.text as NSString
            guard let match = definitionPattern.firstMatch(
                in: String(line.text),
                range: NSRange(location: 0, length: ns.length)),
                match.numberOfRanges > 1 else { continue }
            definedLabels.insert(
                LintCitationFacts.normalizedFragment(ns.substring(with: match.range(at: 1))))
        }

        // Usages: `[text][label]`, `![alt][label]`, and collapsed `[text][]`.
        let fullUsagePattern = constantRegex(#"!?\[[^\]\[]+\]\[([^\]\[]+)\]"#)
        let collapsedUsagePattern = constantRegex(#"(!?\[[^\]\[]+)\]\[\]"#)
        for (match, regex) in regexMatches([fullUsagePattern, collapsedUsagePattern], in: maskedBody) {
            let ns = maskedBody as NSString
            let label: String
            if regex == fullUsagePattern {
                label = ns.substring(with: match.range(at: 1))
            } else {
                // Collapsed form: the label is the link text itself.
                let text = ns.substring(with: match.range(at: 1))
                label = String(text.dropFirst().dropLast())
            }
            let key = LintCitationFacts.normalizedFragment(label)
            guard definedLabels.contains(key) == false else { continue }
            findings.append(DetectedFinding(
                .missingMediaReference,
                utf8Range(match.range, in: source),
                excerpt(of: ns.substring(with: match.range)),
                "Reference-style usage names label “\(label)”, which has no `[\(label)]: …` definition — it renders as literal text.",
                .major,
                .confirmed))
        }

        // Local media destinations: non-empty destinations with no scheme and
        // no anchor cannot resolve inside the wiki.
        for node in collectInlineDestinations(parsed.document) {
            let destination = node.destination
            guard destination.isEmpty == false,
                  destination.hasPrefix("#") == false,
                  hasScheme(destination) == false else { continue }
            let role = node.isImage ? "image" : "link"
            findings.append(DetectedFinding(
                .missingMediaReference,
                node.range.flatMap { parsed.utf8Range(of: $0) },
                excerpt(of: destination),
                "The \(role) destination “\(destination)” is a relative path with no scheme — it cannot resolve inside the wiki.",
                .major,
                .confirmed))
        }
        return findings
    }

    /// Every link/image destination with its node range, in source order.
    struct DestinationOccurrence {
        let destination: String
        let range: Range<SourceLocation>?
        let isImage: Bool
    }

    private static func collectInlineDestinations(_ markup: Markup) -> [DestinationOccurrence] {
        var nodes: [DestinationOccurrence] = []
        if let link = markup as? Link, let destination = link.destination {
            nodes.append(DestinationOccurrence(
                destination: destination, range: link.range, isImage: false))
        }
        // swift-markdown names the image destination `source`.
        if let image = markup as? Image, let destination = image.source {
            nodes.append(DestinationOccurrence(
                destination: destination, range: image.range, isImage: true))
        }
        for child in markup.children {
            nodes.append(contentsOf: collectInlineDestinations(child))
        }
        return nodes
    }

    /// `true` when the destination starts with a URI scheme (`http:`,
    /// `mailto:`, …).
    static func hasScheme(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return false }
        let scheme = destination[destination.startIndex..<colon]
        guard scheme.count > 1 else { return false } // a single char is not a scheme
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    // MARK: - D27 history regression

    /// Removals between the inspected head's ACTUAL parent version and this
    /// head, plus the named byte-shrinkage threshold. Loss alone does not
    /// authorize restoration — findings carry no repair.
    static func historyRegressionCandidates(
        parentBody: String,
        headByteCount: Int,
        headTableTexts: Set<String>,
        headCitationKeys: Set<String>,
        headHeadingTexts: Set<String>,
        headFootnoteDefinitionIDs: Set<String>
    ) -> [DetectedFinding] {
        let parent = ParsedMarkdownDocument(parsing: parentBody)
        let parentProtected = WikiFootnoteMarkdown.utf16Ranges(of: parent.codeProtection, in: parentBody)
        let parentNodes = WikiLinkParser.syntaxNodes(
            in: parentBody, protectedRanges: parentProtected)
        let parentFootnotes = MarkdownFootnoteAnalysis.analyze(
            in: parentBody, protectedRanges: parentProtected)

        var findings: [DetectedFinding] = []

        // Removed tables.
        var parentTables: Set<String> = []
        collectTables(from: parent.document, parsed: parent) { range in
            guard let range else { return }
            parentTables.insert(LintCitationFacts.normalizedFragment(slice(parentBody, range)))
        }
        for removed in parentTables.subtracting(headTableTexts).sorted() {
            findings.append(DetectedFinding(
                .regressionAgainstPreviousHead,
                nil,
                excerpt(of: removed),
                "A table present in the parent version is absent from this head — confirm the removal was intentional; loss alone does not restore it.",
                .major,
                .candidate))
        }

        // Removed source citations.
        var parentCitations: Set<String> = []
        for node in parentNodes {
            let target: WikiMarkdownTarget
            switch node {
            case .link(let link): target = link.target
            case .embed(let embed): target = embed.target
            }
            guard target.namespace == .source else { continue }
            parentCitations.insert(citationKey(for: target))
        }
        for removed in parentCitations.subtracting(headCitationKeys).sorted() {
            findings.append(DetectedFinding(
                .regressionAgainstPreviousHead,
                nil,
                excerpt(of: removed),
                "A source citation present in the parent version is absent from this head — confirm the removal was intentional.",
                .major,
                .candidate))
        }

        // Removed headings.
        var parentHeadings: Set<String> = []
        forEachNode(parent.document, of: Heading.self) { heading in
            parentHeadings.insert(
                LintCitationFacts.normalizedFragment(flattenedText(heading)))
        }
        for removed in parentHeadings.subtracting(headHeadingTexts).sorted() {
            findings.append(DetectedFinding(
                .regressionAgainstPreviousHead,
                nil,
                excerpt(of: removed),
                "A heading present in the parent version is absent from this head — a section may have been lost.",
                .major,
                .candidate))
        }

        // Removed footnote definitions.
        let parentDefinitionIDs = Set(parentFootnotes.definitions.map(\.id))
        for removed in parentDefinitionIDs.subtracting(headFootnoteDefinitionIDs).sorted() {
            findings.append(DetectedFinding(
                .regressionAgainstPreviousHead,
                nil,
                "[^\(removed)]",
                "A footnote definition present in the parent version is absent from this head.",
                .major,
                .candidate))
        }

        // Byte shrinkage beyond the named threshold.
        let parentByteCount = parentBody.utf8.count
        if parentByteCount > 0,
           Double(headByteCount) < Double(parentByteCount) * DetectorConstants.shrinkageThreshold {
            let percent = Int((1 - Double(headByteCount) / Double(parentByteCount)) * 100)
            findings.append(DetectedFinding(
                .regressionAgainstPreviousHead,
                nil,
                "\(headByteCount) bytes vs parent's \(parentByteCount)",
                "The body shrank \(percent)% against the parent version (threshold: 30%) — content may have been lost.",
                .major,
                .candidate))
        }
        return findings
    }

    /// The comparable identity of a source-citation target (canonical ID or
    /// normalized literal — pins and fragments do not change identity).
    static func citationKey(for target: WikiMarkdownTarget) -> String {
        "source:" + (target.canonicalID ?? WikiText.normalized(target.literal))
    }

    // MARK: - AST traversal helpers

    /// Depth-first source-order visit of every node of `nodeType`.
    static func forEachNode<Node: Markup>(
        _ markup: Markup,
        of nodeType: Node.Type,
        _ visit: (Node) -> Void
    ) {
        if let node = markup as? Node { visit(node) }
        for child in markup.children {
            forEachNode(child, of: nodeType, visit)
        }
    }
}

private extension String {
    /// Non-overlapping occurrence count of a substring.
    func occurrenceCount(of substring: String) -> Int {
        guard substring.isEmpty == false else { return 0 }
        var count = 0
        var searchStart = startIndex
        while let range = range(of: substring, range: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
