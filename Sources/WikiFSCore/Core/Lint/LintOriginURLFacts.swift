import Foundation
import WikiFSTypes

/// Store-derived facts for the raw-URL check (D11): for every URL identity
/// the established rules produce, EVERY source whose origin matches. The
/// complete set is kept — ambiguity is reported, never resolved to a winner
/// (REQ-40), so a candidate repair exists only when exactly one verified
/// resource matches.
public struct LintOriginURLFacts: Equatable, Sendable {

    /// URL identity (``URLFetchService.urlIdentity``) → every matching
    /// source ID.
    public var sourcesByIdentity: [String: Set<SourceID>] = [:]

    public init() {}

    /// The unique source for an identity, or `nil` when zero or several
    /// sources match (several is ambiguity, not a match).
    public func uniqueMatch(identity: String) -> SourceID? {
        guard let matches = sourcesByIdentity[identity], matches.count == 1 else {
            return nil
        }
        return matches.first
    }

    /// The number of matching sources for an identity.
    public func matchCount(identity: String) -> Int {
        sourcesByIdentity[identity]?.count ?? 0
    }

    /// Load origin facts for every raw URL in `body`: resolve each URL to its
    /// established identity, then enumerate the sources whose origin history
    /// carries that identity. Off-main callers route the store through
    /// `WikiReadService`; in-memory fixtures pass any `WikiStore`.
    public static func load(from store: WikiStore, body: String) throws -> LintOriginURLFacts {
        let parsed = ParsedMarkdownDocument(parsing: body)
        let protected = WikiFootnoteMarkdown.utf16Ranges(of: parsed.codeProtection, in: body)
        var identities: Set<String> = []
        for (_, url) in LintPagePreflight.rawURLOccurrences(in: body, protectedUTF16: protected) {
            if let identity = URLFetchService.urlIdentity(url) {
                identities.insert(identity)
            }
        }
        guard identities.isEmpty == false else { return LintOriginURLFacts() }

        var facts = LintOriginURLFacts()
        for source in try store.listSources() {
            let originIdentities = try Self.originIdentities(sourceID: source.id, store: store)
            let overlap = originIdentities.intersection(identities)
            for identity in overlap {
                facts.sourcesByIdentity[identity, default: []].insert(source.id)
            }
        }
        return facts
    }

    /// Every URL identity in a source's origin history (plan, external ref,
    /// and external identity candidates across all recorded origins) — the
    /// same candidate set `sourceMatchingURLIdentity` matches against.
    static func originIdentities(sourceID: SourceID, store: WikiStore) throws -> Set<String> {
        var identities: Set<String> = []
        for origin in try store.sourceEditHistory(sourceID: sourceID) {
            for candidate in [origin.plan, origin.externalRef, origin.externalIdentity] {
                if let identity = URLFetchService.urlIdentity(candidate ?? "") {
                    identities.insert(identity)
                }
            }
        }
        return identities
    }
}
