import Foundation
import WikiFSCore
import WikiFSTypes

/// One observed page, flattened from the store: everything the deterministic
/// evaluator needs, nothing it does not. Captured AFTER a run completes, so
/// evaluation never runs inside a transaction or against live agent state.
public struct ObservedPage: Sendable, Equatable, Codable {
    public let id: PageID
    public let title: String
    public let body: String
    public let version: Int
    public let updatedAt: Date
    /// `pageVersionHistory(pageID:)` count.
    public let historyDepth: Int
    /// Effective names of the sources recorded on the page's CURRENT HEAD
    /// version's provenance (`pageVersionSources(versionID:)`), resolved
    /// through the observed source list. Kept for canned-result compatibility
    /// and readable diagnostics; identity checks use the typed IDs below when
    /// present.
    public let provenanceSourceNames: [String]
    public let provenanceSourceIDs: [SourceID]
    /// `[[source:…]]` targets parsed from the current body. These are raw
    /// boundary values because live agents cite by source id and legacy
    /// captures used display names.
    public let citationNames: [String]
    /// Effective names of sources the DATABASE's source-link rows connect to
    /// this page. Kept for compatibility and diagnostics.
    public let sourceLinkNames: [String]
    /// Source IDs from the authoritative database source-link rows.
    public let sourceLinkIDs: [SourceID]

    public init(
        id: PageID, title: String, body: String, version: Int, updatedAt: Date,
        historyDepth: Int, provenanceSourceNames: [String], citationNames: [String],
        sourceLinkNames: [String], provenanceSourceIDs: [SourceID] = [],
        sourceLinkIDs: [SourceID] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.version = version
        self.updatedAt = updatedAt
        self.historyDepth = historyDepth
        self.provenanceSourceNames = provenanceSourceNames
        self.provenanceSourceIDs = provenanceSourceIDs
        self.citationNames = citationNames
        self.sourceLinkNames = sourceLinkNames
        self.sourceLinkIDs = sourceLinkIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, version, updatedAt, historyDepth
        case provenanceSourceNames, provenanceSourceIDs, citationNames
        case sourceLinkNames, sourceLinkIDs
    }

    /// Backward-compatible decoding: `provenanceSourceIDs` and
    /// `sourceLinkIDs` were added after live `results.json` files already
    /// existed on disk, so captures encoded before the typed-ID fields must
    /// decode with empty arrays instead of failing with `keyNotFound`.
    /// (The synthesized decoder would require both keys unconditionally —
    /// `init` parameter defaults do NOT apply to `init(from:)`.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PageID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        version = try container.decode(Int.self, forKey: .version)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        historyDepth = try container.decode(Int.self, forKey: .historyDepth)
        provenanceSourceNames = try container.decode([String].self, forKey: .provenanceSourceNames)
        provenanceSourceIDs = try container.decodeIfPresent([SourceID].self, forKey: .provenanceSourceIDs) ?? []
        citationNames = try container.decode([String].self, forKey: .citationNames)
        sourceLinkNames = try container.decode([String].self, forKey: .sourceLinkNames)
        sourceLinkIDs = try container.decodeIfPresent([SourceID].self, forKey: .sourceLinkIDs) ?? []
    }
}

/// One observed source row. (The Ingested stamp is run-level bookkeeping the
/// daemon writes through `markSourceIngested`; it is not observable through
/// `listSources`, so the runner records it per-run instead of per-source.)
public struct ObservedSource: Sendable, Equatable, Codable {
    public let id: SourceID
    public let name: String
    /// Stable fixture/import key when the runner has it; absent in legacy canned captures.
    public let fixtureKey: String?

    public init(id: SourceID, name: String, fixtureKey: String? = nil) {
        self.id = id
        self.name = name
        self.fixtureKey = fixtureKey
    }
}

/// A whole-wiki snapshot captured at one point in time. The evaluator compares
/// consecutive snapshots (`before` / `after`) and, for the strategy scenario,
/// two independent wikis.
public struct WikiObservation: Sendable, Equatable, Codable {
    public let pages: [ObservedPage]
    public let sources: [ObservedSource]

    public init(pages: [ObservedPage], sources: [ObservedSource]) {
        self.pages = pages
        self.sources = sources
    }

    /// Resolve a page by title fragment: exact title first, then a UNIQUE
    /// title containing the fragment. nil (ambiguous or missing) is a check
    /// failure the evaluator reports with the near-miss titles.
    public func page(titled fragment: String) -> PageResolution {
        let lower = fragment.lowercased()
        if let exact = pages.first(where: { $0.title.lowercased() == lower }) {
            return .found(exact)
        }
        let matches = pages.filter { $0.title.lowercased().contains(lower) }
        guard matches.count == 1, let only = matches.first else {
            return .notFound(
                candidates: matches.map(\.title),
                allTitles: pages.map(\.title))
        }
        return .found(only)
    }

    /// Resolve a page by `PageID` across snapshots (identity tracking).
    public func page(id: PageID) -> ObservedPage? {
        pages.first { $0.id == id }
    }
}

/// The outcome of resolving a check's page title against a snapshot.
public enum PageResolution: Sendable, Equatable {
    case found(ObservedPage)
    case notFound(candidates: [String], allTitles: [String])

    public var page: ObservedPage? {
        if case .found(let page) = self { return page }
        return nil
    }
}

/// Deterministic `[[source:…]]` citation extraction from a Markdown body.
/// Accepts embed form (`![[source:…]]`) and strips `#fragment` suffixes.
/// Mirrors the link grammar the write pipeline accepts (`WikiLinkParser`):
/// this scanner is deliberately independent so evaluator bugs cannot hide
/// behind parser changes.
public enum CitationScanner {
    public static func citations(in body: String) -> [String] {
        var results: [String] = []
        var searchRange = body.startIndex..<body.endIndex
        while let open = body.range(of: "[[source:", range: searchRange) {
            let afterOpen = open.upperBound
            guard let close = body.range(of: "]]", range: afterOpen..<body.endIndex) else { break }
            var target = String(body[afterOpen..<close.lowerBound])
            if let hash = target.firstIndex(of: "#") {
                target = String(target[..<hash])
            }
            let trimmed = target.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                results.append(trimmed)
            }
            searchRange = close.upperBound..<body.endIndex
        }
        return results
    }
}

/// Captures a `WikiObservation` from a `WikiStore` using only public read
/// APIs (`listPages`, `getPage`, `pageHeadVersionID`, `pageVersionHistory`,
/// `pageVersionSources`, `listSources`, `pagesCitingSources`). One capture
/// per snapshot point. Stateless value type — safe to hold anywhere,
/// including inside a Sendable harness.
public struct WikiObservationRecorder: Sendable {
    public init() {}

    /// - Parameter fixtureKeysBySourceID: the stable fixture mapping —
    ///   observed `SourceID` → the fixture file's filename stem (e.g.
    ///   `meridian-chapter-03`). The live harness imports each fixture
    ///   through `addSource(filename:data:)` and accumulates this mapping
    ///   across a leg's batches, so checks resolve citations and provenance
    ///   by typed id instead of display-name fragments. Empty (legacy canned
    ///   captures) leaves `fixtureKey` nil.
    public func capture(
        from store: any WikiStore,
        fixtureKeysBySourceID: [SourceID: String] = [:]
    ) throws -> WikiObservation {
        let sourceSummaries = try store.listSources()
        let sourcesByID: [SourceID: SourceSummary] = Dictionary(
            sourceSummaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The authoritative citation edges: per source, which pages carry a
        // database source-link row to it. Queried per source so the result
        // maps page → the specific sources it cites.
        var pageLinkSources: [PageID: [(SourceID, String)]] = [:]
        for summary in sourceSummaries {
            let cited = try store.pagesCitingSources(sourceIDs: [summary.id], limit: 10_000)
            for page in cited {
                pageLinkSources[page.pageID, default: []].append((summary.id, summary.effectiveName))
            }
        }

        var pages: [ObservedPage] = []
        for summary in try store.listPages(sortBy: .lastUpdated) {
            let page = try store.getPage(id: summary.id)
            let history = try store.pageVersionHistory(pageID: summary.id)
            var provenanceNames: [String] = []
            var provenanceIDs: [SourceID] = []
            // The current head is whatever the `page-content` ref points at
            // (`pageHeadVersionID`) — NOT necessarily `history.last`.
            // `pageVersionHistory` is ordered by version id (ascending),
            // which equals write order only while history is linear;
            // `revertPage(pageID:to:)` repoints the head at an older version
            // WITHOUT appending a row, so once branches exist the final row
            // can be a stale tip. Ask the store for the actual head and fall
            // back to the final row only when no ref exists (pre-migration
            // data). Never evaluate provenance from the oldest version.
            let headVersionID = try store.pageHeadVersionID(pageID: summary.id)
            let head = headVersionID
                .flatMap { ref in history.first { $0.id == ref } }
                ?? history.last
            if let latest = head {
                let sources = try store.pageVersionSources(versionID: latest.id)
                var names: [String] = []
                for provenance in sources {
                    provenanceIDs.append(provenance.sourceID)
                    if let summary = sourcesByID[provenance.sourceID] {
                        names.append(summary.effectiveName)
                    }
                }
                provenanceNames = names
            }
            pages.append(ObservedPage(
                id: page.id,
                title: page.title,
                body: page.bodyMarkdown,
                version: page.version,
                updatedAt: page.updatedAt,
                historyDepth: history.count,
                provenanceSourceNames: provenanceNames,
                citationNames: CitationScanner.citations(in: page.bodyMarkdown),
                sourceLinkNames: pageLinkSources[page.id, default: []].map { $0.1 },
                provenanceSourceIDs: provenanceIDs,
                sourceLinkIDs: pageLinkSources[page.id, default: []].map { $0.0 }))
        }

        let observedSources = sourceSummaries.map { summary in
            ObservedSource(
                id: summary.id,
                name: summary.effectiveName,
                fixtureKey: fixtureKeysBySourceID[summary.id])
        }
        return WikiObservation(pages: pages, sources: observedSources)
    }
}
