import Foundation

// pattern: Functional Core

/// A canonical half-open UTF-8 byte interval in authored Markdown.
public struct MarkdownSourceRange: Hashable, Sendable, Comparable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(lowerBound: Int, upperBound: Int) throws {
        guard lowerBound >= 0, upperBound >= lowerBound else {
            throw MarkdownSourceRangeError.invalidBounds(lowerBound: lowerBound, upperBound: upperBound)
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var count: Int { upperBound - lowerBound }

    public func contains(_ other: Self) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }

    public func intersects(_ other: Self) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
        return lhs.upperBound < rhs.upperBound
    }
}

public enum MarkdownSourceRangeError: Error, Equatable, Sendable {
    case invalidBounds(lowerBound: Int, upperBound: Int)
    case invalidUTF16Range
}

/// The namespace selected by authored wiki-link syntax.
public enum WikiMarkdownTargetNamespace: String, Hashable, Sendable {
    case page
    case source
    case chat
}

/// A typed wiki target before page or source resolution.
public struct WikiMarkdownTarget: Hashable, Sendable {
    public let namespace: WikiMarkdownTargetNamespace
    public let literal: String
    public let canonicalID: String?
    public let fragment: String?
    public let sourceVersionPin: Int?

    public init(
        namespace: WikiMarkdownTargetNamespace,
        literal: String,
        canonicalID: String?,
        fragment: String?,
        sourceVersionPin: Int?
    ) {
        self.namespace = namespace
        self.literal = literal
        self.canonicalID = canonicalID
        self.fragment = fragment
        self.sourceVersionPin = sourceVersionPin
    }
}

/// One non-protected wiki expression in authored Markdown.
public enum WikiMarkdownSyntaxNode: Hashable, Sendable {
    case link(Link)
    case embed(Embed)

    public struct Link: Hashable, Sendable {
        public let sourceRange: MarkdownSourceRange
        public let target: WikiMarkdownTarget
        public let displayText: String
        public let alias: String?
        public let authoredLiteral: String
    }

    public struct Embed: Hashable, Sendable {
        public let sourceRange: MarkdownSourceRange
        public let target: WikiMarkdownTarget
        public let displayText: String
        public let alias: String?
        public let authoredLiteral: String
    }

    public var sourceRange: MarkdownSourceRange {
        switch self {
        case .link(let value): value.sourceRange
        case .embed(let value): value.sourceRange
        }
    }

    public var authoredLiteral: String {
        switch self {
        case .link(let value): value.authoredLiteral
        case .embed(let value): value.authoredLiteral
        }
    }
}

public extension WikiLinkParser {
    /// Parse every valid, non-code-protected wiki occurrence in source order.
    /// Unlike ``parse(_:)``, this render overlay never de-duplicates occurrences.
    static func syntaxNodes(in body: String) -> [WikiMarkdownSyntaxNode] {
        let ns = body as NSString
        let protectedRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        var nodes: [WikiMarkdownSyntaxNode] = []

        for match in WikiLinkSpan.matches(in: body) {
            let isEmbed = WikiLinkSpan.isEmbedPrefix(ns, match.range)
            let expressionRange = isEmbed
                ? NSRange(location: match.range.location - 1, length: match.range.length + 1)
                : match.range
            guard !WikiLinkSpan.isProtected(expressionRange, by: protectedRanges),
                  !WikiLinkSpan.isLocallyCodeWrapped(ns, match.range, includesEmbedPrefix: isEmbed) else {
                continue
            }
            // This pure target has no logging dependency. A conversion failure
            // drops only the invalid syntax occurrence and preserves source text.
            // swiftlint:disable:next silent_try_optional
            guard let sourceRange = try? utf8Range(for: expressionRange, in: body) else { continue }

            let rawTarget = ns.substring(with: match.targetRange)
            let rawAlias = match.aliasRange.location == NSNotFound
                ? nil
                : ns.substring(with: match.aliasRange)
            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsed = WikiText.normalized(fixed.target)
            guard !collapsed.isEmpty else { continue }

            let (base, fragment) = splitFragment(collapsed)
            let (bareBase, pinLiteral) = splitVersionPin(base)
            let (linkType, bareTarget) = classify(bareBase)
            guard !bareTarget.isEmpty, !isEmptyPrefix(bareBase) else { continue }

            let namespace: WikiMarkdownTargetNamespace
            switch linkType {
            case .page: namespace = .page
            case .source: namespace = .source
            case .chat: namespace = .chat
            }
            let versionPin = pinLiteral.flatMap(Int.init)
            let target = WikiMarkdownTarget(
                namespace: namespace,
                literal: bareTarget,
                canonicalID: isCanonicalULID(bareTarget) ? bareTarget.uppercased() : nil,
                fragment: fragment,
                sourceVersionPin: namespace == .source ? versionPin : nil)
            let alias = fixed.alias.map(WikiText.normalized).flatMap { $0.isEmpty ? nil : $0 }
            let displayText = alias ?? bareTarget
            let authoredLiteral = ns.substring(with: expressionRange)

            if isEmbed {
                nodes.append(.embed(.init(
                    sourceRange: sourceRange,
                    target: target,
                    displayText: displayText,
                    alias: alias,
                    authoredLiteral: authoredLiteral)))
            } else {
                nodes.append(.link(.init(
                    sourceRange: sourceRange,
                    target: target,
                    displayText: displayText,
                    alias: alias,
                    authoredLiteral: authoredLiteral)))
            }
        }
        return nodes
    }

    private static func utf8Range(for utf16Range: NSRange, in source: String) throws -> MarkdownSourceRange {
        guard let stringRange = Range(utf16Range, in: source),
              let lower = stringRange.lowerBound.samePosition(in: source.utf8),
              let upper = stringRange.upperBound.samePosition(in: source.utf8) else {
            throw MarkdownSourceRangeError.invalidUTF16Range
        }
        return try MarkdownSourceRange(
            lowerBound: source.utf8.distance(from: source.utf8.startIndex, to: lower),
            upperBound: source.utf8.distance(from: source.utf8.startIndex, to: upper))
    }
}
