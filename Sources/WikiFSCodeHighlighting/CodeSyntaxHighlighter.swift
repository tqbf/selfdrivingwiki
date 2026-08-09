import CTreeSitterHighlighting
import Foundation

// pattern: Functional Core

/// The closed set of ordinary fenced-code languages supported by the reader.
/// Renderer packages and rich-fence aliases are intentionally absent.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case java
    case scala
    case html
    case swift
    case json

    public static func fromFenceInfo(_ info: String?) -> Self? {
        guard let normalized = info?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch normalized {
        case "java": return CodeLanguage.java
        case "scala": return CodeLanguage.scala
        case "html", "xml": return CodeLanguage.html
        case "swift": return CodeLanguage.swift
        case "json", "jsonc": return CodeLanguage.json
        default: return nil
        }
    }

    fileprivate var cValue: UInt8 {
        switch self {
        case .java: 1
        case .scala: 2
        case .html: 3
        case .swift: 4
        case .json: 5
        }
    }
}

/// Named resource limits for the synchronous, thread-confined highlighter.
public enum CodeHighlightingPolicy {
    public static let maximumHighlightedSourceBytes = 256 * 1024
    public static let maximumHighlightedBlockCount = 100
}

public struct CodeHighlightMeasurement: Sendable {
    public let setupNanoseconds: UInt64
    public let parserNanoseconds: UInt64
    public let queryNanoseconds: UInt64
    public let rangeValidationNanoseconds: UInt64
    public let htmlAssemblyNanoseconds: UInt64
    public let totalNanoseconds: UInt64
    public let captureCount: UInt32
    public let tokenCount: UInt32
}

private enum CodeSyntaxTokenPalette: UInt8 {
    case keyword = 1
    case string = 2
    case comment = 3
    case type = 4
    case function = 5
    case property = 6
    case number = 7
    case `operator` = 8
    case punctuation = 9
    case constant = 10

    private static let keywordOpeningTag = Array(#"<span class="sdw-code-keyword">"#.utf8)
    private static let stringOpeningTag = Array(#"<span class="sdw-code-string">"#.utf8)
    private static let commentOpeningTag = Array(#"<span class="sdw-code-comment">"#.utf8)
    private static let typeOpeningTag = Array(#"<span class="sdw-code-type">"#.utf8)
    private static let functionOpeningTag = Array(#"<span class="sdw-code-function">"#.utf8)
    private static let propertyOpeningTag = Array(#"<span class="sdw-code-property">"#.utf8)
    private static let numberOpeningTag = Array(#"<span class="sdw-code-number">"#.utf8)
    private static let operatorOpeningTag = Array(#"<span class="sdw-code-operator">"#.utf8)
    private static let punctuationOpeningTag = Array(#"<span class="sdw-code-punctuation">"#.utf8)
    private static let constantOpeningTag = Array(#"<span class="sdw-code-constant">"#.utf8)

    var openingTagUTF8: [UInt8] {
        switch self {
        case .keyword: Self.keywordOpeningTag
        case .string: Self.stringOpeningTag
        case .comment: Self.commentOpeningTag
        case .type: Self.typeOpeningTag
        case .function: Self.functionOpeningTag
        case .property: Self.propertyOpeningTag
        case .number: Self.numberOpeningTag
        case .operator: Self.operatorOpeningTag
        case .punctuation: Self.punctuationOpeningTag
        case .constant: Self.constantOpeningTag
        }
    }
}

/// Converts a bounded ordinary-code fence into escaped, allowlisted token spans.
/// Every parser, tree, query, cursor, and C result is allocated and released in
/// the same synchronous call. No mutable Tree-sitter object crosses a task.
public enum CodeSyntaxHighlighter {
    /// Checks the synchronous highlighter's inexpensive, fail-closed entry
    /// conditions. Callers use this before reserving document-wide work.
    public static func isEligibleSource(
        _ source: String,
        language: CodeLanguage?,
        isCancelled: @Sendable () -> Bool
    ) -> Bool {
        language != nil
            && !isCancelled()
            && source.utf8.count <= CodeHighlightingPolicy.maximumHighlightedSourceBytes
            && source.utf8.count <= Int(UInt32.max)
    }

    public static func highlightedHTML(
        source: String,
        language: CodeLanguage?,
        isCancelled: @Sendable () -> Bool,
        measurement: ((CodeHighlightMeasurement) -> Void)? = nil
    ) -> String? {
        guard isEligibleSource(source, language: language, isCancelled: isCancelled),
              let language
        else {
            return nil
        }

        let totalStarted = DispatchTime.now().uptimeNanoseconds
        return source.withCString { input in
            guard let result = wiki_tree_sitter_highlight(language.cValue, input, UInt32(source.utf8.count)) else {
                return nil
            }
            defer { wiki_tree_sitter_highlight_result_delete(result) }
            guard !isCancelled() else { return nil }

            let cTiming = wiki_tree_sitter_highlight_result_timing(result)
            let count = wiki_tree_sitter_highlight_result_count(result)
            let tokenPointer = wiki_tree_sitter_highlight_result_tokens(result)
            guard count == 0 || tokenPointer != nil else { return nil }

            guard let highlighted = source.utf8.withContiguousStorageIfAvailable({ sourceBytes -> String? in
                let rangeStarted = DispatchTime.now().uptimeNanoseconds
                guard let tokens = validatedTokenStream(tokenPointer, count: Int(count), sourceBytes: sourceBytes) else {
                    return nil
                }
                let rangeFinished = DispatchTime.now().uptimeNanoseconds
                guard !isCancelled() else { return nil }

                let htmlStarted = DispatchTime.now().uptimeNanoseconds
                let html = escapedHTML(sourceBytes: sourceBytes, tokens: tokens)
                let htmlFinished = DispatchTime.now().uptimeNanoseconds
                if html != nil {
                    measurement?(CodeHighlightMeasurement(
                        setupNanoseconds: cTiming.setup_nanoseconds,
                        parserNanoseconds: cTiming.parser_nanoseconds,
                        queryNanoseconds: cTiming.query_nanoseconds,
                        rangeValidationNanoseconds: rangeFinished - rangeStarted,
                        htmlAssemblyNanoseconds: htmlFinished - htmlStarted,
                        totalNanoseconds: htmlFinished - totalStarted,
                        captureCount: cTiming.capture_count,
                        tokenCount: cTiming.emitted_token_count))
                }
                return html
            }) else {
                return nil
            }
            return highlighted
        }
    }

    private static func escapedHTML(
        sourceBytes: UnsafeBufferPointer<UInt8>,
        tokens: ValidatedTokenStream
    ) -> String? {
        guard let capacity = plannedOutputCapacity(sourceByteCount: sourceBytes.count, tokenCount: tokens.count) else {
            return nil
        }

        var output: [UInt8] = []
        output.reserveCapacity(capacity)
        var cursor = 0
        if let tokenPointer = tokens.pointer {
            for index in 0..<tokens.count {
                let token = tokenPointer[index]
                guard let palette = CodeSyntaxTokenPalette(rawValue: token.category),
                      let start = Int(exactly: token.start_byte),
                      let end = Int(exactly: token.end_byte)
                else {
                    return nil
                }
                // `ValidatedTokenStream` guarantees palette membership,
                // source-ordered UTF-8 ranges, and in-bounds endpoints.
                guard start >= cursor else { continue }
                appendEscaped(sourceBytes, from: cursor, to: start, into: &output)
                output.append(contentsOf: palette.openingTagUTF8)
                appendEscaped(sourceBytes, from: start, to: end, into: &output)
                output.append(contentsOf: closingSpanTag)
                cursor = end
            }
        }
        appendEscaped(sourceBytes, from: cursor, to: sourceBytes.count, into: &output)
        return String(bytes: output, encoding: .utf8)
    }

    private static let ampersandEntity = Array("&amp;".utf8)
    private static let lessThanEntity = Array("&lt;".utf8)
    private static let greaterThanEntity = Array("&gt;".utf8)
    private static let closingSpanTag = Array("</span>".utf8)
    private static let maximumMarkupBytesPerToken = 48

    /// A token stream whose C ranges have been checked against the active
    /// contiguous UTF-8 source buffer. Its pointer is used only before the C
    /// result is released by `highlightedHTML`'s enclosing `defer`.
    private struct ValidatedTokenStream {
        let pointer: UnsafePointer<WikiTreeSitterToken>?
        let count: Int
    }

    private static func validatedTokenStream(
        _ tokenPointer: UnsafePointer<WikiTreeSitterToken>?,
        count: Int,
        sourceBytes: UnsafeBufferPointer<UInt8>
    ) -> ValidatedTokenStream? {
        guard count == 0 || tokenPointer != nil else { return nil }
        guard let tokenPointer else { return ValidatedTokenStream(pointer: nil, count: count) }

        var previousStart = 0
        // `ts_query_cursor_next_capture` yields source-ordered captures. Reject
        // an unexpected ordering rather than sorting untrusted C ranges; overlap
        // normalization in the builder is therefore linear and deterministic.
        for index in 0..<count {
            let token = tokenPointer[index]
            guard CodeSyntaxTokenPalette(rawValue: token.category) != nil,
                  let start = Int(exactly: token.start_byte),
                  let end = Int(exactly: token.end_byte),
                  isValidUTF8Range(start: start, end: end, in: sourceBytes),
                  start >= previousStart
            else {
                return nil
            }
            previousStart = start
        }
        return ValidatedTokenStream(pointer: tokenPointer, count: count)
    }

    private static func isValidUTF8Range(
        start: Int,
        end: Int,
        in sourceBytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        guard start < end, end <= sourceBytes.count else { return false }
        return isUTF8Boundary(start, in: sourceBytes) && isUTF8Boundary(end, in: sourceBytes)
    }

    private static func isUTF8Boundary(_ offset: Int, in sourceBytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard offset >= 0, offset <= sourceBytes.count else { return false }
        guard offset < sourceBytes.count else { return true }
        return sourceBytes[offset] & 0b1100_0000 != 0b1000_0000
    }

    private static func plannedOutputCapacity(sourceByteCount: Int, tokenCount: Int) -> Int? {
        let escapedSource = sourceByteCount.multipliedReportingOverflow(by: 5)
        let markup = tokenCount.multipliedReportingOverflow(by: maximumMarkupBytesPerToken)
        guard !escapedSource.overflow, !markup.overflow else { return nil }
        let capacity = escapedSource.partialValue.addingReportingOverflow(markup.partialValue)
        return capacity.overflow ? nil : capacity.partialValue
    }

    private static func appendEscaped(
        _ sourceBytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        into output: inout [UInt8]
    ) {
        var index = start
        while index < end {
            switch sourceBytes[index] {
            case 38: output.append(contentsOf: ampersandEntity)
            case 60: output.append(contentsOf: lessThanEntity)
            case 62: output.append(contentsOf: greaterThanEntity)
            default: output.append(sourceBytes[index])
            }
            index += 1
        }
    }
}
