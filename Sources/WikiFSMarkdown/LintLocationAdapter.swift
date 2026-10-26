import Foundation

// MARK: - Lint location transforms

/// Errors raised when a lint finding's byte range cannot be located in the
/// captured page body.
public enum LintLocationError: Error, Equatable, Sendable {
    /// The offset is negative or past the end of the text.
    case outOfBounds(offset: Int, utf8Count: Int)
    /// The offset lands inside a multi-byte scalar (not on a Unicode
    /// scalar boundary), so the range cannot address editable text.
    case notOnUnicodeBoundary(offset: Int)
    /// The range's bytes do not decode to the finding's expected text — the
    /// location points somewhere else (stale finding, fabricated offset).
    case expectedTextMismatch(offset: Int, actual: String, expected: String)
}

/// The single adapter between lint finding locations (UTF-8 byte offsets, the
/// external JSON/persistence contract) and text-facing coordinates (Swift
/// `String` indices, AppKit UTF-16 `NSRange`s).
///
/// Every conversion validates UTF-8 boundary alignment before converting, so a
/// fabricated or stale offset fails loudly here instead of slicing a character
/// in half downstream. All lint ranges in the app flow through this type.
public enum LintLocationAdapter {

    /// Convert a UTF-16 code-unit offset (an NSString/NSRange coordinate) to a
    /// UTF-8 byte offset. Throws when the offset is out of bounds or lands
    /// inside a surrogate pair.
    public static func utf8Offset(ofUTF16Offset offset: Int, in text: String) throws -> Int {
        let utf16 = text.utf16
        guard offset >= 0, offset <= utf16.count else {
            throw LintLocationError.outOfBounds(offset: offset, utf8Count: text.utf8.count)
        }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
        guard let stringIndex = String.Index(utf16Index, within: text) else {
            throw LintLocationError.notOnUnicodeBoundary(offset: offset)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: stringIndex)
    }

    /// Convert an NSString half-open range to a UTF-8 byte range.
    public static func utf8Range(forNSRange range: NSRange, in text: String) throws -> Range<Int> {
        let lower = try utf8Offset(ofUTF16Offset: range.location, in: text)
        let upper = try utf8Offset(ofUTF16Offset: range.location + range.length, in: text)
        return lower..<upper
    }

    /// Validate that `offset` addresses a UTF-8 boundary in `text`.
    public static func validateBoundary(_ offset: Int, in text: String) throws {
        let count = text.utf8.count
        guard offset >= 0, offset <= count else {
            throw LintLocationError.outOfBounds(offset: offset, utf8Count: count)
        }
        // `String.Index(_:within:)` returns nil exactly when the byte offset
        // does not land on a scalar boundary (or is out of bounds, already
        // rejected above).
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        guard String.Index(utf8Index, within: text) != nil else {
            throw LintLocationError.notOnUnicodeBoundary(offset: offset)
        }
    }

    /// Convert a UTF-8 byte offset to a UTF-16 code-unit offset (the AppKit
    /// text coordinate). Throws when the offset is out of bounds or splits a
    /// multi-byte scalar.
    public static func utf16Offset(ofUTF8Offset offset: Int, in text: String) throws -> Int {
        try validateBoundary(offset, in: text)
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        // The boundary check above guarantees the index is also valid in the
        // UTF-16 view (String views share positions at scalar boundaries).
        return text.utf16.distance(from: text.utf16.startIndex, to: utf8Index)
    }

    /// Convert a half-open UTF-8 byte range to an `NSRange` over UTF-16 code
    /// units, validating both endpoints. A zero-width range (insertion point)
    /// converts to a zero-length `NSRange` at the mapped location.
    public static func nsRange(forUTF8Range range: Range<Int>, in text: String) throws -> NSRange {
        let lower = try utf16Offset(ofUTF8Offset: range.lowerBound, in: text)
        let upper = try utf16Offset(ofUTF8Offset: range.upperBound, in: text)
        return NSRange(location: lower, length: upper - lower)
    }

    /// Validate that `range` lies inside `text` on UTF-8 boundaries and that
    /// its bytes decode to exactly `expectedText` (when provided). This is the
    /// gate every persisted/model-supplied passage range passes before it can
    /// become a finding.
    public static func validateRange(
        _ range: Range<Int>, expectedText: String?, in text: String
    ) throws {
        try validateBoundary(range.lowerBound, in: text)
        try validateBoundary(range.upperBound, in: text)
        guard range.lowerBound <= range.upperBound else {
            throw LintLocationError.outOfBounds(offset: range.upperBound, utf8Count: text.utf8.count)
        }
        guard let expectedText else { return }
        let bytes = Array(text.utf8)
        let actual = String(decoding: bytes[range.lowerBound..<range.upperBound], as: UTF8.self)
        guard actual == expectedText else {
            throw LintLocationError.expectedTextMismatch(
                offset: range.lowerBound, actual: actual, expected: expectedText)
        }
    }

    // MARK: - markdownlint coordinate mapping

    /// Convert 1-based markdownlint line/column coordinates (UTF-8 columns,
    /// matching Swift Markdown's source locations) into a half-open UTF-8
    /// byte range. `column` and `endColumn` are 1-based. Returns nil when the
    /// coordinates fall outside the text (markdownlint can report one line
    /// past the end for file-end rules).
    public static func utf8Range(
        line: Int, column: Int, endLine: Int, endColumn: Int, in text: String
    ) -> Range<Int>? {
        let table = ByteLineTable(source: text)
        guard let lower = table.offset(line: line, column: column),
              let upper = table.offset(line: endLine, column: endColumn),
              lower <= upper else { return nil }
        return lower..<upper
    }
}

/// Line-start byte-offset table over UTF-8 content — the same conversion the
/// reader's `MarkdownSourceLineTable` performs, kept here so lint findings map
/// markdownlint's line/column coordinates onto the authored byte offsets the
/// rest of the app uses.
struct ByteLineTable {
    private let lineStarts: [Int]
    private let utf8Count: Int

    init(source: String) {
        let bytes = Array(source.utf8)
        var starts = [0]
        for index in bytes.indices where bytes[index] == 0x0A {
            starts.append(index + 1)
        }
        lineStarts = starts
        utf8Count = bytes.count
    }

    /// Byte offset of a 1-based line/column pair (column counted in UTF-8
    /// bytes). Accepts exactly ONE past-end line (the phantom line after the
    /// final line break, e.g. markdownlint's file-end rules) with column 1,
    /// mapping it to end-of-file. Returns nil for out-of-range coordinates.
    func offset(line: Int, column: Int) -> Int? {
        guard line > 0, column > 0 else { return nil }
        if line == lineStarts.count + 1 {
            // The one past-end line: its "start" is EOF.
            return column == 1 ? utf8Count : nil
        }
        guard line <= lineStarts.count else { return nil }
        let lineEnd = line < lineStarts.count ? lineStarts[line] : utf8Count
        let value = lineStarts[line - 1] + column - 1
        guard value >= lineStarts[line - 1], value <= lineEnd else { return nil }
        return value
    }
}
