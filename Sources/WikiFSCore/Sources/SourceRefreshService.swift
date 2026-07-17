import Foundation

/// Phase 3b — reconstructs the provider for a source from its provenance origin
/// and re-materializes it **off the main actor**. Does NOT write the store — it
/// returns the materialized bytes/provenance so the `@MainActor` caller
/// (`WikiStoreModel` in the app) performs the store write, exactly like
/// `addURL`'s pattern: materialize off-main, store on-main (the Phase-0
/// single-writer-discipline invariant).
///
/// Provider reconstruction keys off `SourceOrigin.agentName`:
/// - `"website"` → `WebsiteMaterializer` (refresh appends a content version).
/// - `"apple-podcast"` → `ApplePodcastMaterializer` (refresh appends a derived
///   markdown version — byteless sources have no content to refresh).
/// - Everything else (`local-file`, `zotero`, `markdown-folder`,
///   `legacy-import`, `unknown`) → `.notRefreshable` (import-only).
///
/// See `plans/graph-model-and-versioning.md` §11–§12.
public struct SourceRefreshService: Sendable {

    public enum RefreshError: Error, LocalizedError, Equatable {
        /// The source's provider is import-only (local-file, Zotero, folder) or
        /// unknown — it carries no URL to re-fetch. Carries the agent name for a
        /// clear message.
        case notRefreshable(String)
        /// The origin has no `plan` (URL) to re-fetch — a data-integrity edge
        /// case (website sources always record the URL at ingest).
        case missingPlan
        /// Phase 4 (D3): the source is a website snapshot with image siblings.
        /// Single-source refresh would move the active version to a new activity
        /// and orphan the images (the resolver joins on the active activity).
        /// Snapshot-aware refresh (re-snapshotting images) is a named follow-on.
        case snapshotWithImages

        public var errorDescription: String? {
            switch self {
            case .notRefreshable(let agent):
                return "Sources from \"\(agent)\" can't be refreshed (no URL to re-fetch)."
            case .missingPlan:
                return "This source has no recorded URL to re-fetch."
            case .snapshotWithImages:
                return "This snapshot source includes images; re-snapshotting on refresh is coming soon."
            }
        }
    }

    /// The result of a refresh materialize: what to append and how. The caller
    /// (on the main actor) switches on this to pick the right store primitive.
    public enum RefreshMaterial: Sendable {
        /// Append a new content version (website refresh). Carries the fresh
        /// bytes + the provider's own provenance.
        case contentVersion(data: Data, provenance: SourceProvenance)
        /// Append a new derived markdown version (podcast byteless refresh).
        /// Provenance is intentionally omitted — `appendProcessedMarkdown` has
        /// no PROV parameter; the source-level `apple-podcast` agent (recorded
        /// at v1 creation) remains authoritative. Transcript-level PROV (agent
        /// `apple-ttml`) is deferred to Phase 4.
        case derivedMarkdown(content: String)
    }

    public let fetcher: any URLFetchService.URLResourceFetcher
    #if PODCAST_TRANSCRIPTS
    public let podcastFetcher: (any PodcastTranscriptFetching)?
    #endif

    #if PODCAST_TRANSCRIPTS
    public init(
        fetcher: any URLFetchService.URLResourceFetcher,
        podcastFetcher: (any PodcastTranscriptFetching)? = nil
    ) {
        self.fetcher = fetcher
        self.podcastFetcher = podcastFetcher
    }
    #else
    public init(fetcher: any URLFetchService.URLResourceFetcher) {
        self.fetcher = fetcher
    }
    #endif

    /// Read the origin → reconstruct the provider → materialize OFF-main.
    /// Returns the material the caller should append. Throws `.notRefreshable`
    /// for import-only sources and `.missingPlan` when a refreshable source's
    /// origin has no URL.
    public func materialize(origin: SourceOrigin) async throws -> RefreshMaterial {
        switch origin.agentName {
        case "website":
            return try await materializeWebsite(origin: origin)
        case "apple-podcast":
            return try await materializePodcast(origin: origin)
        default:
            throw RefreshError.notRefreshable(origin.agentName)
        }
    }

    // MARK: - Website

    private func materializeWebsite(origin: SourceOrigin) async throws -> RefreshMaterial {
        guard let urlString = origin.plan, let url = URL(string: urlString) else {
            throw RefreshError.missingPlan
        }
        let provider = WebsiteMaterializer(rawInput: urlString, fetcher: fetcher)
        let source = try await provider.materialize()
        guard let prov = source.provenance else {
            // WebsiteMaterializer always records provenance — defensive.
            throw RefreshError.missingPlan
        }
        _ = url // validated above; the provider re-normalizes from the raw string
        return .contentVersion(data: source.data, provenance: prov)
    }

    // MARK: - Apple Podcast

    #if PODCAST_TRANSCRIPTS
    private func materializePodcast(origin: SourceOrigin) async throws -> RefreshMaterial {
        guard let urlString = origin.plan else {
            throw RefreshError.missingPlan
        }
        guard let episode = PodcastEpisodeURL.parse(urlString) else {
            throw RefreshError.missingPlan
        }
        guard let svc = podcastFetcher else {
            throw PodcastTranscriptError.signatureUnavailable(
                "Apple Podcasts transcripts need the signing helper, which isn't available in this build.")
        }
        guard let pageURL = URL(string: urlString) else {
            throw RefreshError.missingPlan
        }
        // The provider's materialize() runs the transcript fetch off-main
        // (Task.detached inside). Byteless source → only the derived markdown
        // (transcript) changes on refresh; the content version never does.
        let provider = ApplePodcastMaterializer(episode: episode, pageURL: pageURL, fetcher: svc)
        let transcript = try await provider.materialize()
        let markdown = String(data: transcript.data, encoding: .utf8) ?? ""
        return .derivedMarkdown(content: markdown)
    }
    #else
    private func materializePodcast(origin: SourceOrigin) async throws -> RefreshMaterial {
        throw RefreshError.notRefreshable(origin.agentName)
    }
    #endif
}
