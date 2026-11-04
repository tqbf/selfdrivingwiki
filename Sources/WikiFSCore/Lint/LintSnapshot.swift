import Foundation
import Crypto
import WikiFSTypes

// MARK: - Digest

/// The body digest binding findings and proposals to one captured snapshot.
public enum LintSnapshotDigest {
    /// Lowercase hex SHA-256 over the body's UTF-8 bytes.
    public static func digest(of body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Captured page snapshot

/// Bounded related-resource facts captured with the page: the resolution
/// context a check or repair may cite. Capped per namespace — these facts
/// feed prompts and link resolution, never full-resource enumeration.
public struct LintRelatedResourceFacts: Hashable, Sendable {
    /// Cap per namespace. Large wikis truncate (sorted, so the cap is stable).
    public static let maxNamesPerNamespace = 500

    public var pageTitleMap: [String: String]
    public var sourceNames: Set<String>
    public var chatTitles: Set<String>

    public init(
        pageTitleMap: [String: String],
        sourceNames: Set<String>,
        chatTitles: Set<String>
    ) {
        self.pageTitleMap = Self.capped(pageTitleMap)
        self.sourceNames = Self.capped(sourceNames)
        self.chatTitles = Self.capped(chatTitles)
    }

    public static func capped(_ names: some Collection<String>) -> Set<String> {
        guard names.count > maxNamesPerNamespace else { return Set(names) }
        return Set(names.sorted().prefix(maxNamesPerNamespace))
    }

    public static func capped(_ map: [String: String]) -> [String: String] {
        guard map.count > maxNamesPerNamespace else { return map }
        return Dictionary(
            uniqueKeysWithValues: map
                .sorted { $0.key < $1.key }
                .prefix(maxNamesPerNamespace)
                .map { ($0.key, $0.value) })
    }

    public static let empty = LintRelatedResourceFacts(
        pageTitleMap: [:], sourceNames: [], chatTitles: [])
}

/// The coherent page state one lint run inspects. Everything detection and
/// repair reads lives here; neither pipeline may re-read the store mid-run.
/// Captured with one store read transaction (or the in-memory store in tests).
public struct LintPageSnapshot: Sendable, Equatable {
    public let wikiID: WikiID
    public let pageID: PageID
    public let title: String
    /// The committed body markdown the run inspects (raw stored bytes).
    public let body: String
    /// The page's head version at capture — the Apply expectation.
    public let headVersionID: PageVersionID
    /// SHA-256 over `body`'s UTF-8 bytes. Findings and proposals bind to it.
    public let bodyDigest: String
    /// The strategy revision captured with the run (nil when the wiki has no
    /// committed strategy row).
    public let strategyRevision: Int?
    /// The rendered strategy context (via `WikiStrategyRenderer`) supplied to
    /// model steps as evidence — never copied into a system prompt.
    public let strategyContext: String
    public let relatedResources: LintRelatedResourceFacts
    /// Version-aware citation evidence captured with the run. Checks and
    /// repair read this same evidence; retry/repair never reloads newer
    /// sources silently.
    public let citations: LintCitationEvidence
    /// The captured parent version of the head (history facts).
    public let parent: LintCapturedParentVersion?

    public init(
        wikiID: WikiID,
        pageID: PageID,
        title: String,
        body: String,
        headVersionID: PageVersionID,
        strategyRevision: Int?,
        strategyContext: String,
        relatedResources: LintRelatedResourceFacts,
        citations: LintCitationEvidence = .empty,
        parent: LintCapturedParentVersion? = nil
    ) {
        self.wikiID = wikiID
        self.pageID = pageID
        self.title = title
        self.body = body
        self.headVersionID = headVersionID
        self.bodyDigest = LintSnapshotDigest.digest(of: body)
        self.strategyRevision = strategyRevision
        self.strategyContext = strategyContext
        self.relatedResources = relatedResources
        self.citations = citations
        self.parent = parent
    }

    /// True when `other` captured the exact same body bytes this snapshot
    /// holds (digest equality — the snapshot-staleness gate).
    public func matchesBody(of other: LintPageSnapshot) -> Bool {
        bodyDigest == other.bodyDigest
    }
}

// MARK: - Repair proposals

/// One exact source replacement: replace the validated range's bytes with
/// `newText`. The range carries its expected old text, so stale or fabricated
/// replacements fail validation instead of silently moving text.
public struct LintSourceReplacement: Sendable, Equatable {
    public let range: LintSourceRange
    public let newText: String

    public init(range: LintSourceRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// The output of one repair recipe: a bounded array of exact replacements
/// against one captured snapshot, bound to the finding and option the user
/// selected. No identity, no bytes — nothing else about the page may change.
public struct LintRepairProposal: Sendable, Equatable {
    public let snapshotDigest: String
    public let pageID: PageID
    public let findingID: LintFindingID
    public let optionID: LintOptionID
    public let recipeID: LintRecipeID
    public let replacements: [LintSourceReplacement]

    public init(
        snapshotDigest: String,
        pageID: PageID,
        findingID: LintFindingID,
        optionID: LintOptionID,
        recipeID: LintRecipeID,
        replacements: [LintSourceReplacement]
    ) {
        self.snapshotDigest = snapshotDigest
        self.pageID = pageID
        self.findingID = findingID
        self.optionID = optionID
        self.recipeID = recipeID
        self.replacements = replacements
    }

    /// Apply the replacements to a copy of the snapshot body in descending
    /// byte order. Returns nil when any replacement fails validation against
    /// the body (stale range, boundary, expected-text mismatch) — never a
    /// partial application.
    public func applying(to body: String) -> String? {
        var sorted = replacements
        // Descending order so earlier (higher-offset) splices cannot shift
        // the coordinates of later ones.
        sorted.sort { $0.range.lowerBound > $1.range.lowerBound }
        var bytes = Array(body.utf8)
        for replacement in sorted {
            let bounds = replacement.range.bounds
            guard bounds.upperBound <= bytes.count else { return nil }
            let actual = String(decoding: bytes[bounds.lowerBound..<bounds.upperBound], as: UTF8.self)
            guard actual == replacement.range.expectedText else { return nil }
            bytes.replaceSubrange(bounds, with: Array(replacement.newText.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Proposal errors

/// Raised when a proposal builder receives output it cannot bind to the
/// selected finding, option, and snapshot.
public enum LintProposalError: Error, Equatable, Sendable {
    /// The producer addressed a different snapshot (digest mismatch).
    case snapshotMismatch
    /// The producer echoed a different page/run/finding/option identity.
    case identityMismatch
    /// A replacement range was out of bounds, split a scalar, or did not
    /// carry the expected old text.
    case invalidReplacement(offset: Int)
    /// Two replacements overlap; no descending splice can apply both.
    case overlappingReplacements
    /// The candidate exceeds the configured output cap.
    case candidateTooLarge(bytes: Int, limit: Int)
    /// The producer changed nothing (a no-op proposal cannot be previewed).
    case unchangedCandidate
    /// A passage-scoped repair touched text outside the finding's approved
    /// passage ranges (plus the ranges' own interior).
    case passageScopeEscape
    /// The recipe id in the proposal is not the selected option's recipe.
    case unknownRecipe
}
