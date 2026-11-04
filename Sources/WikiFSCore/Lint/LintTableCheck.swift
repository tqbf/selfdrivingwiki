import Foundation
import WikiFSLinks

// MARK: - Table structure check (report-only)
//
// Mirrors the production dialect's cell splitting: GFM (swift-markdown)
// splits a table row into cells at RAW unescaped pipes BEFORE inline
// parsing — a pipe inside a wiki-link alias, or inside an inline code span
// in a table row, still splits the cell. (The reader linkifies wiki links
// first, but a pipe inside the link's alias/quote survives linkification
// and then severs the cell.)
//
// Two findings, both report-only (no repair can be offered without
// inventing table structure or choosing for the author):
// - Declared-column mismatch: an authored row whose unescaped-pipe cell
//   count differs from the delimiter row's declared columns. The parser
//   pads or discards the extra cells — real rendering damage.
// - Wiki-link alias/quote pipes: a `[[…|…]]` span inside a table row whose
//   alias or quote fragment carries an unescaped pipe — the pipe splits
//   the cell and severs the link.
//
// Discipline:
// - Fenced code is never table syntax; protected content is skipped.
// - Escaped pipes (`\|`) are correct encoding and never flagged.
// - Cell counts come from AUTHORED unescaped pipes, never from AST cells —
//   the parser discards extra cells, so the AST cannot report them.

public enum LintTableCheck {

    enum Rule: String {
        case columnMismatch = "table-column-mismatch"
        case aliasPipe = "table-alias-pipe"
    }

    /// One authored GFM table row.
    struct AuthoredRow {
        let lineNumber: Int // 1-based
        let text: String
        /// UTF-8 byte range of the whole line (excluding the newline).
        let range: Range<Int>
    }

    public static func findings(stepID: LintStepID, body: String) -> [LintFinding] {
        let lines = body.components(separatedBy: "\n")
        // Fence tracking shares the reader's protection rules. Line ranges
        // are UTF-8 BYTE offsets (finding ranges address bytes — UTF-16
        // lengths silently drift the anchors across every non-ASCII line).
        var fencedPrefix: [Bool] = [] // line i is inside a fence (or is a fence line)
        var inFence = false
        var cursor = 0
        var lineRanges: [Range<Int>] = []
        for line in lines {
            let length = line.utf8.count
            lineRanges.append(cursor..<(cursor + length))
            let isFenceLine = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            fencedPrefix.append(inFence || isFenceLine)
            if isFenceLine { inFence.toggle() }
            cursor += length + 1
        }
        func byteRange(_ lineIndex: Int) -> Range<Int>? {
            guard lineIndex < lineRanges.count else { return nil }
            return lineRanges[lineIndex]
        }

        var findings: [LintFinding] = []
        var sequence = 0
        func nextID(_ prefix: String) -> LintFindingID {
            sequence += 1
            return LintFindingID(rawValue: "\(prefix)-\(sequence)")
        }
        func passage(_ bounds: Range<Int>, expected: String) -> LintSourceRange? {
            do {
                return try LintSourceRange(
                    lowerBound: bounds.lowerBound, upperBound: bounds.upperBound,
                    expectedText: expected, in: body)
            } catch {
                DebugLog.lint("LintTableCheck: dropping unlocatable row anchor \(bounds): \(error)")
                return nil
            }
        }

        // Walk rows; a table = a header line followed by a delimiter line.
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard !fencedPrefix[index],
                  isTableRow(lines[index]),
                  index + 1 < lines.count,
                  !fencedPrefix[index + 1],
                  let delimiter = delimiterColumns(lines[index + 1]) else { continue }

            let headerIndex = index
            let declared = delimiter
            // Body rows: until a non-table line.
            var rowIndex = headerIndex + 2
            while rowIndex < lines.count,
                  !fencedPrefix[rowIndex],
                  isTableRow(lines[rowIndex]) {
                defer { rowIndex += 1 }
                let rowText = lines[rowIndex]
                let cells = cellCount(rowText)

                // Declared-column mismatch.
                if cells != declared {
                    guard let bounds = byteRange(rowIndex),
                          let expected = slice(bounds, in: body),
                          let anchor = passage(bounds, expected: expected) else { continue }
                    findings.append(LintFinding(
                        id: nextID("tbl-cols"),
                        stepID: stepID,
                        ruleID: LintRuleID(rawValue: Rule.columnMismatch.rawValue),
                        severity: .warning,
                        message: "Table row has \(cells) cell\(cells == 1 ? "" : "s") but the "
                            + "table declares \(declared) column\(declared == 1 ? "" : "s") — "
                            + "the renderer pads or discards the extra cells, so content is "
                            + "not shown as authored.",
                        evidence: rowText.trimmingCharacters(in: .whitespaces).prefix(120).description,
                        scope: .passage([anchor]),
                        repairOptions: []))
                }

                // Wiki-link alias/quote pipes inside the row.
                let spans = WikiLinkSpan.matches(in: rowText)
                let protected = WikiLinkSpan.protectedCodeRanges(in: rowText)
                for span in spans {
                    guard !WikiLinkSpan.isProtected(span.range, by: protected) else { continue }
                    let spanText = (rowText as NSString).substring(with: span.range)
                    // The alias (group 2) is what survives linkification as
                    // visible text; a raw unescaped pipe there splits the
                    // rendered cell.
                    if span.aliasRange.location != NSNotFound {
                        let alias = (rowText as NSString).substring(with: span.aliasRange)
                        guard hasUnescapedPipe(alias) else { continue }
                    } else {
                        continue
                    }
                    // Anchor at the span's position within the document.
                    // The span location is UTF-16 WITHIN the row line; the
                    // finding range is UTF-8 in the document — convert.
                    guard let rowBounds = byteRange(rowIndex) else { continue }
                    let spanUTF8InRow: Int
                    do {
                        spanUTF8InRow = try LintLocationAdapter.utf8Offset(
                            ofUTF16Offset: span.range.location, in: rowText)
                    } catch {
                        DebugLog.lint("LintTableCheck: alias span unlocatable in row: \(error)")
                        continue
                    }
                    let spanStart = rowBounds.lowerBound + spanUTF8InRow
                    let spanLength = spanText.utf8.count
                    let spanBounds = spanStart..<(spanStart + spanLength)
                    guard let expected = slice(spanBounds, in: body),
                          let anchor = passage(spanBounds, expected: expected) else { continue }
                    findings.append(LintFinding(
                        id: nextID("tbl-pipe"),
                        stepID: stepID,
                        ruleID: LintRuleID(rawValue: Rule.aliasPipe.rawValue),
                        severity: .warning,
                        message: "This wiki link's alias contains an unescaped '|' — inside "
                            + "a table the pipe splits the cell and severs the link. Escape "
                            + "it (\\|) to keep the alias intact.",
                        evidence: spanText,
                        scope: .passage([anchor]),
                        repairOptions: []))
                }
            }
            // Jump past the consumed table.
            index = max(index, rowIndex - 1)
        }
        return findings
    }

    // MARK: - GFM row primitives

    /// A candidate table row: contains a pipe outside leading/trailing trim.
    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|")
    }

    /// The declared column count of a GFM delimiter row (`| --- | :---: |`),
    /// or nil when the line is not a delimiter row. Edge pipes do not
    /// create cells (the same trim `cellCount` applies).
    static func delimiterColumns(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        var cells = splitCells(trimmed)
        guard cells.count >= 2 else { return nil }
        // Trim the edge cells a bordered row's pipes create.
        if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), cells.count >= 3 {
            cells.removeFirst()
            cells.removeLast()
        } else if trimmed.hasPrefix("|"), cells.count >= 2 {
            cells.removeFirst()
        } else if trimmed.hasSuffix("|"), cells.count >= 2 {
            cells.removeLast()
        }
        guard !cells.isEmpty else { return nil }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            // Each cell must be a colon-dash run.
            let stripped = c.replacingOccurrences(of: ":", with: "")
            guard !stripped.isEmpty, stripped.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return cells.count
    }

    /// The number of cells a row renders as: unescaped pipes split cells;
    /// a leading and a trailing pipe do not create cells (GFM trims one
    /// empty leading/trailing cell when both edges have pipes).
    static func cellCount(_ row: String) -> Int {
        var cells = splitCells(row)
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), cells.count >= 2 {
            cells.removeFirst()
            cells.removeLast()
        } else if trimmed.hasPrefix("|"), cells.count >= 2 {
            cells.removeFirst()
        } else if trimmed.hasSuffix("|"), cells.count >= 2 {
            cells.removeLast()
        }
        return max(cells.count, 0)
    }

    /// Split on UNESCAPED pipes only. Backslash-escaped pipes (`\|`) do not
    /// split — matching the production parser's cell scan.
    static func splitCells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)
        return cells
    }

    private static func hasUnescapedPipe(_ text: String) -> Bool {
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { return true }
        }
        return false
    }

    private static func slice(_ bounds: Range<Int>, in body: String) -> String? {
        let view = body.utf8
        guard bounds.upperBound <= view.count else { return nil }
        let lower = view.index(view.startIndex, offsetBy: bounds.lowerBound)
        let upper = view.index(lower, offsetBy: bounds.count)
        return String(decoding: view[lower..<upper], as: UTF8.self)
    }
}
