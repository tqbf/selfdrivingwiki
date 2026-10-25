import Foundation

/// The factual worklist `WikiStoreModel.preflightLint` computes for a
/// single-page lint, rendered as named sections in the lint task (#1461).
/// Pre-flight lists facts; the lint model decides what to change.
///
/// Conforms to `ExpressibleByArrayLiteral` so call sites that only have broken
/// links — or nothing at all (`brokenLinks: []`) — keep compiling unchanged:
/// a bare array literal fills `brokenLinks` and leaves the content scans empty.
public struct LintPagePreflight: Equatable, Sendable, ExpressibleByArrayLiteral {
  public typealias ArrayLiteralElement = String

  /// Broken `[[…]]` links across the page/source/chat namespaces (namespace
  /// prefixes are added by the caller that combines the three lists).
  public var brokenLinks: [String]
  /// Raw external URLs found in the page body — one `"line <n>: <url>"`
  /// entry per occurrence, no judgment attached.
  public var rawExternalURLs: [String]
  /// Malformed markdown tables — one factual description per malformed table.
  public var malformedTables: [String]

  public init(
    brokenLinks: [String],
    rawExternalURLs: [String],
    malformedTables: [String]
  ) {
    self.brokenLinks = brokenLinks
    self.rawExternalURLs = rawExternalURLs
    self.malformedTables = malformedTables
  }

  /// Array-literal convenience: the elements are broken links. Callers that
  /// only have broken links — or nothing at all — keep writing
  /// `brokenLinks: ["[[X]]"]` / `brokenLinks: []`; the empty literal yields
  /// an all-empty worklist.
  public init(arrayLiteral elements: String...) {
    self.brokenLinks = elements
    self.rawExternalURLs = []
    self.malformedTables = []
  }
}

/// Pure pre-flight text scans over a page body. They LIST facts and never
/// judge or fix anything — deciding what to change is the lint model's job.
/// Both scans skip fenced code blocks and inline code spans (via
/// `WikiLinkSpan.protectedCodeRanges`): code is example text, not page
/// content, and every other pre-flight check skips it for the same reason.
public enum LintPreflightScanner {

  // MARK: - Raw external URLs

  private static let urlRegex = makeRegex(#"https?://[^\s<>")\]]+"#)
  /// `[label](destination)` — a URL behind a proper markdown link is not raw.
  private static let markdownLinkRegex = makeRegex(#"\[[^\]]*\]\([^)\s]*\)"#)
  /// `<https://…>` angle autolinks are already links, not raw text.
  private static let angleAutolinkRegex = makeRegex(#"<https?://[^>\s]*>"#)
  /// Sentence punctuation that glommed onto the end of a matched URL.
  private static let trailingURLPunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?", "\"", "'", "*", "_", "`"
  ]

  /// Every `http(s)` URL that appears as bare text in the body, as
  /// `"line <n>: <url>"` entries in document order. A URL that is already a
  /// link target — the destination of a proper markdown link or an angle
  /// autolink — is not raw and is not listed. Detection is factual: no
  /// opinion on whether the URL should stay a bare external citation.
  public static func rawExternalURLs(in body: String) -> [String] {
    let ns = body as NSString
    let full = NSRange(location: 0, length: ns.length)
    let lines = scanLines(ns)
    let exempted = WikiLinkSpan.protectedCodeRanges(in: body)
      + [markdownLinkRegex, angleAutolinkRegex].flatMap { regex in
        regex.matches(in: body, options: [], range: full).map(\.range)
      }

    var results: [String] = []
    for match in urlRegex.matches(in: body, options: [], range: full) {
      guard !WikiLinkSpan.isProtected(match.range, by: exempted) else { continue }
      var url = ns.substring(with: match.range)
      while let lastCharacter = url.last, trailingURLPunctuation.contains(lastCharacter) {
        url.removeLast()
      }
      guard !url.isEmpty else { continue }
      let line = lines.first { NSLocationInRange(match.range.location, $0.range) }
      let lineNumber = line?.number ?? 0
      results.append("line \(lineNumber): \(url)")
    }
    return results
  }

  // MARK: - Malformed tables

  /// A markdown table is a run of two or more consecutive `|`-prefixed lines.
  /// The run is malformed when no valid separator row (`| --- | --- |`,
  /// required directly under the header row) exists, or when the rows'
  /// column counts disagree. Each finding is one factual description.
  public static func malformedTables(in body: String) -> [String] {
    let ns = body as NSString
    let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
    let lines = scanLines(ns)

    var results: [String] = []
    var index = 0
    while index < lines.count {
      guard isTableRow(lines[index].text) else {
        index += 1
        continue
      }
      let start = index
      while index < lines.count, isTableRow(lines[index].text) {
        index += 1
      }
      let run = Array(lines[start..<index])
      guard run.count >= 2 else { continue }

      // A run fully inside a fenced block / code span is example text.
      let firstLine = run[0]
      let lastLine = run[run.count - 1]
      let runRange = NSRange(
        location: firstLine.range.location,
        length: NSMaxRange(lastLine.range) - firstLine.range.location)
      guard !WikiLinkSpan.isProtected(runRange, by: codeRanges) else { continue }

      // GFM requires the separator row to be the second line of the table.
      let hasSeparator = isSeparatorRow(run[1].text)
      if !hasSeparator {
        results.append(
          "line \(firstLine.number): markdown table has no valid separator row "
            + "(| --- | --- | under the header row)")
      }
      let counts = run.map { columnCount(in: $0.text) }
      if Set(counts).count > 1 {
        let countsText = counts.map(String.init).joined(separator: ", ")
        results.append(
          "line \(firstLine.number): markdown table has inconsistent column counts "
            + "(\(countsText))")
      }
    }
    return results
  }

  // MARK: - Line / row helpers

  private struct Line {
    let text: String
    let range: NSRange
    let number: Int
  }

  private static func scanLines(_ ns: NSString) -> [Line] {
    var lines: [Line] = []
    var location = 0
    var number = 1
    for line in ns.components(separatedBy: "\n") {
      let length = (line as NSString).length
      lines.append(Line(text: line, range: NSRange(location: location, length: length), number: number))
      location += length + 1  // +1 for the newline the split consumed
      number += 1
    }
    return lines
  }

  private static func isTableRow(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
  }

  /// The number of cells in a row: split on unescaped `|` after stripping the
  /// optional leading/trailing pipe. A missing trailing pipe is legal GFM;
  /// an escaped `\|` does not split a cell (GFM requires the escape inside
  /// cells, so the pipe count mirrors the render).
  private static func columnCount(in row: String) -> Int {
    splitCells(row).count
  }

  private static func isSeparatorRow(_ row: String) -> Bool {
    let cells = splitCells(row)
    return !cells.isEmpty && cells.allSatisfy { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespaces)
      return trimmed.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
    }
  }

  private static func splitCells(_ row: String) -> [String] {
    var t = row.trimmingCharacters(in: .whitespaces)
    // Plain-string replacement (not a regex): the two-character sequence `\|`.
    t = t.replacingOccurrences(of: #"\|"#, with: "\u{FFFC}")  // escaped pipe: no split
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") { t.removeLast() }
    return t.components(separatedBy: "|")
  }

  /// The pattern literals above are compile-time constants; an invalid one is
  /// a programmer error, so the failure is loud instead of a force-try.
  private static func makeRegex(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern, options: [])
    } catch {
      fatalError("LintPreflightScanner: invalid regex pattern \(pattern): \(error)")
    }
  }
}
