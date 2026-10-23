import Foundation

/// Occurrence-preserving footnote analysis for lint and reader preparation.
///
/// The reader's historical extraction kept a `[id: markdown]` dictionary,
/// which silently DROPPED duplicate definitions and lost authored locations —
/// fine for rendering a preview, insufficient for a validity scan (D22 needs
/// duplicate IDs reported, orphan definitions located, and undefined
/// references evidenced). This analysis keeps EVERY occurrence with its
/// authored range.
///
/// References are body occurrences: matches inside a definition's own range
/// (including another definition's body) are not counted as references — the
/// same semantics the reader's numbering uses, since definitions are removed
/// from the body before references are numbered.
public struct MarkdownFootnoteAnalysis: Equatable, Sendable {

    /// One `[^id]` occurrence in the body, in source order.
    public struct Reference: Equatable, Sendable {
        public let id: String
        /// UTF-16 range of the `[^id]` span.
        public let utf16Range: NSRange
        /// Half-open UTF-8 byte range of the same span in the authored text.
        public let utf8Range: MarkdownSourceRange
    }

    /// One `[^id]: body` definition occurrence, in source order — duplicates
    /// included, each with its authored range.
    public struct Definition: Equatable, Sendable {
        public let id: String
        /// The definition body (continuation lines joined with `\n`,
        /// whitespace-trimmed) — the same string the reader renders.
        public let markdown: String
        /// UTF-16 range from the definition marker through its last
        /// continuation line.
        public let utf16Range: NSRange
        /// Half-open UTF-8 byte range of the same span.
        public let utf8Range: MarkdownSourceRange
    }

    /// Every body reference occurrence, in source order.
    public let references: [Reference]
    /// Every definition occurrence, in source order — duplicates included.
    public let definitions: [Definition]

    /// IDs defined more than once, in first-duplicate order.
    public var duplicateDefinitionIDs: [String] {
        var counts: [String: Int] = [:]
        for definition in definitions { counts[definition.id, default: 0] += 1 }
        var reported = Set<String>()
        var duplicates: [String] = []
        for definition in definitions where (counts[definition.id] ?? 0) > 1 {
            if reported.insert(definition.id).inserted {
                duplicates.append(definition.id)
            }
        }
        return duplicates
    }

    /// Referenced IDs with no definition, in first-reference order.
    public var undefinedReferenceIDs: [String] {
        let defined = Set(definitions.map(\.id))
        var reported = Set<String>()
        var undefined: [String] = []
        for reference in references where !defined.contains(reference.id) {
            if reported.insert(reference.id).inserted {
                undefined.append(reference.id)
            }
        }
        return undefined
    }

    /// Defined IDs never referenced from the body, in definition order.
    public var orphanDefinitionIDs: [String] {
        let referenced = Set(references.map(\.id))
        var reported = Set<String>()
        var orphans: [String] = []
        for definition in definitions where !referenced.contains(definition.id) {
            if reported.insert(definition.id).inserted {
                orphans.append(definition.id)
            }
        }
        return orphans
    }
}

public extension MarkdownFootnoteAnalysis {

    /// Analyze `source`'s footnotes, treating the supplied UTF-16 ranges as
    /// protected code (AST-derived protection keeps this in lockstep with the
    /// reader's parse; see ``MarkdownCodeProtection``).
    static func analyze(
        in source: String,
        protectedRanges: [NSRange]
    ) -> MarkdownFootnoteAnalysis {
        let definitions = extractDefinitions(from: source, protectedRanges: protectedRanges)
        let references = extractReferences(
            in: source,
            protectedRanges: protectedRanges,
            definitionRanges: definitions.map(\.utf16Range))
        return MarkdownFootnoteAnalysis(references: references, definitions: definitions)
    }

    // MARK: - Definitions

    private static let definitionPattern = #"^\s{0,3}\[\^([^\]\s]+)\]:\s?(.*)$"#
    // Compile-time constant patterns — failure is a programmer error.
    private static let definitionRegex = try! NSRegularExpression(pattern: definitionPattern) // swiftlint:disable:this force_try
    private static let referencePattern = #"\[\^([^\]\s]+)\]"#
    private static let referenceRegex = try! NSRegularExpression(pattern: referencePattern) // swiftlint:disable:this force_try

    private static func extractDefinitions(
        from source: String,
        protectedRanges: [NSRange]
    ) -> [Definition] {
        let ns = source as NSString
        var definitions: [Definition] = []
        var index = 0

        while index < ns.length {
            // Find the next line start.
            let lineEnd = (source as NSString).rangeOfCharacter(
                from: CharacterSet.newlines, options: [], range: NSRange(location: index, length: ns.length - index))
            let lineRange = NSRange(
                location: index,
                length: (lineEnd.location == NSNotFound ? ns.length : lineEnd.location) - index)
            let line = ns.substring(with: lineRange)

            if !WikiLinkSpan.isProtected(lineRange, by: protectedRanges),
               let match = definitionRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)) {
                let id = (line as NSString).substring(with: match.range(at: 1))
                var bodyLines = [(line as NSString).substring(with: match.range(at: 2))]
                var end = lineRange.location + lineRange.length

                // Continuation lines: indented, unprotected.
                var cursor = end + 1
                while cursor < ns.length {
                    let nextNewline = (source as NSString).rangeOfCharacter(
                        from: CharacterSet.newlines, options: [],
                        range: NSRange(location: cursor, length: ns.length - cursor))
                    let nextRange = NSRange(
                        location: cursor,
                        length: (nextNewline.location == NSNotFound ? ns.length : nextNewline.location) - cursor)
                    let nextLine = ns.substring(with: nextRange)
                    guard !WikiLinkSpan.isProtected(nextRange, by: protectedRanges),
                          isContinuationLine(nextLine) else { break }
                    bodyLines.append(trimContinuationPrefix(nextLine))
                    end = nextRange.location + nextRange.length
                    cursor = end + 1
                }

                let markdown = bodyLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fullRange = NSRange(location: lineRange.location, length: end - lineRange.location)
                definitions.append(Definition(
                    id: id,
                    markdown: markdown,
                    utf16Range: fullRange,
                    utf8Range: utf8Range(for: fullRange, in: source)))
                // Definitions are removed from the body; resume after them.
                index = end + 1
            } else {
                index = lineRange.location + lineRange.length + 1
            }
        }
        return definitions
    }

    private static func isContinuationLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func trimContinuationPrefix(_ line: String) -> String {
        if line.hasPrefix("    ") {
            return String(line.dropFirst(4))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        return line
    }

    // MARK: - References

    private static func extractReferences(
        in source: String,
        protectedRanges: [NSRange],
        definitionRanges: [NSRange]
    ) -> [Reference] {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        var references: [Reference] = []
        for match in referenceRegex.matches(in: source, range: full) {
            // Definition markers (`[^id]:`) are not references.
            guard !definitionRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            // Code-protected occurrences are literal examples, not live notes.
            guard !WikiLinkSpan.isProtected(match.range, by: protectedRanges) else { continue }
            references.append(Reference(
                id: ns.substring(with: match.range(at: 1)),
                utf16Range: match.range,
                utf8Range: utf8Range(for: match.range, in: source)))
        }
        return references
    }

    /// A half-open UTF-8 range for a UTF-16 span; the zero range when the
    /// span cannot map (a finding with a degraded location beats a crash).
    static func utf8Range(for utf16Range: NSRange, in source: String) -> MarkdownSourceRange {
        guard let stringRange = Range(utf16Range, in: source),
              let lower = stringRange.lowerBound.samePosition(in: source.utf8),
              let upper = stringRange.upperBound.samePosition(in: source.utf8) else {
            return ParsedMarkdownDocument.zeroRange
        }
        let lowerOffset = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let upperOffset = source.utf8.distance(from: source.utf8.startIndex, to: upper)
        do {
            return try MarkdownSourceRange(lowerBound: lowerOffset, upperBound: upperOffset)
        } catch {
            return ParsedMarkdownDocument.zeroRange
        }
    }
}
