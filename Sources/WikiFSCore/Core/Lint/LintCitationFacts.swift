import Foundation
import WikiFSTypes
import WikiFSMarkdown

/// Store-derived facts for citation-fragment checks (D09): which version pins
/// exist for a cited source and which quote/anchor text each pinned (or
/// active) version carries. Facts are loaded for the SNAPSHOT's cited sources
/// only — pure scanning never touches the store, so the loader runs before the
/// scan and hands over immutable values.
public struct LintCitationFacts: Equatable, Sendable {

    /// What the scan may check about one cited source.
    public struct SourceCitation: Equatable, Sendable {
        /// The source exists in the wiki (a `false` value leaves the missing
        /// target to the D07 check; D09 stays silent).
        public var exists: Bool = false
        /// The 1-based ordinals a `@vN` pin may name (the source-derived
        /// chain — the reader's own pin authority).
        public var availablePinOrdinals: Set<Int> = []
        /// Whitespace-normalized processed-markdown text per pin ordinal.
        public var normalizedTextByPin: [Int: String] = [:]
        /// Whitespace-normalized active (head) processed-markdown text.
        public var activeNormalizedText: String?

        public init() {}
    }

    /// Facts per canonical (uppercased) SourceID literal.
    public var sources: [String: SourceCitation] = [:]

    public init() {}

    /// `true` when the source has an `@vN` extraction with that ordinal.
    public func pinExists(sourceLiteral: String, ordinal: Int) -> Bool {
        sources[sourceLiteral]?.availablePinOrdinals.contains(ordinal) == true
    }

    /// The whitespace-normalized text authority for the pin (or the active
    /// head when unpinned) — `nil` when that version is unknown.
    public func normalizedText(sourceLiteral: String, pin: Int?) -> String? {
        guard let citation = sources[sourceLiteral] else { return nil }
        if let pin { return citation.normalizedTextByPin[pin] }
        return citation.activeNormalizedText
    }

    /// `true` when the fragment text (already quote-unwrapped) is a
    /// whitespace-normalized, case-sensitive substring of the pinned (or
    /// active) version — the same rule the patch write's citation-integrity
    /// check applies.
    public func fragmentAvailable(sourceLiteral: String, pin: Int?, text: String) -> Bool {
        guard let authority = normalizedText(sourceLiteral: sourceLiteral, pin: pin) else {
            return false
        }
        return authority.contains(Self.normalizedFragment(text))
    }

    /// The whitespace-normalized form fragment matching uses (identical to
    /// the store's quote normalization: whitespace runs collapse, comparison
    /// stays case-sensitive).
    public static func normalizedFragment(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Load facts for every source citation in `body`. In-memory fixtures and
    /// off-main callers pass any `WikiStore`; production routes the read
    /// through `WikiReadService`.
    public static func load(from store: WikiStore, body: String) throws -> LintCitationFacts {
        let parsed = ParsedMarkdownDocument(parsing: body)
        let protected = WikiFootnoteMarkdown.utf16Ranges(of: parsed.codeProtection, in: body)
        let nodes = WikiLinkParser.syntaxNodes(in: body, protectedRanges: protected)

        var citedLiterals: [String] = []
        for node in nodes {
            let target: (namespace: WikiMarkdownTargetNamespace, canonicalID: String?)
            switch node {
            case .link(let link): target = (link.target.namespace, link.target.canonicalID)
            case .embed(let embed): target = (embed.target.namespace, embed.target.canonicalID)
            }
            guard target.namespace == .source, let canonical = target.canonicalID,
                  !citedLiterals.contains(canonical) else { continue }
            citedLiterals.append(canonical)
        }
        guard citedLiterals.isEmpty == false else { return LintCitationFacts() }

        let knownSourceIDs = Set(try store.listSources().map(\.id))
        let chains = try store.sourceDerivedChains()
        var facts = LintCitationFacts()
        for literal in citedLiterals {
            var citation = SourceCitation()
            let id = SourceID(rawValue: literal)
            citation.exists = knownSourceIDs.contains(id)
            let chain = chains[id] ?? []
            // An EMPTY chain (the source is absent, or has no processed
            // markdown) means no pins — `1...0` would trap, and a page
            // citing an unknown source must degrade to facts, never crash
            // the fact load (every lint plan and apply scans through here).
            citation.availablePinOrdinals = chain.isEmpty ? [] : Set(1...chain.count)
            if let head = try store.processedMarkdownHead(sourceID: id) {
                citation.activeNormalizedText = SourceCitation.normalize(head.content)
            }
            for (index, versionID) in chain.enumerated() {
                if let version = try store.processedMarkdownVersion(id: versionID) {
                    citation.normalizedTextByPin[index + 1] = SourceCitation.normalize(version.content)
                }
            }
            facts.sources[literal] = citation
        }
        return facts
    }
}

private extension LintCitationFacts.SourceCitation {
    static func normalize(_ text: String) -> String {
        LintCitationFacts.normalizedFragment(text)
    }
}
