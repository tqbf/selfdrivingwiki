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
/// - `"podcast"` (generic RSS) → `.podcastQueueRequired`: RSS podcast
///   transcripts run through the app's extraction queue (the extractor-package
///   route). There is no direct re-fetch path; the app's Transcribe and
///   refresh actions enqueue the same durable extraction job.
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
        /// RSS podcast transcripts run through the app's extraction queue
        /// (the extractor-package route). A feed source DOES have a URL —
        /// the direct re-fetch path just no longer exists here.
        case podcastQueueRequired

        public var errorDescription: String? {
            switch self {
            case .notRefreshable(let agent):
                return "Sources from \"\(agent)\" can't be refreshed (no URL to re-fetch)."
            case .missingPlan:
                return "This source has no recorded URL to re-fetch."
            case .snapshotWithImages:
                return "This snapshot source includes images; re-snapshotting on refresh is coming soon."
            case .podcastQueueRequired:
                return "RSS podcast transcripts run through the app's extraction queue. Use the app's Transcribe or refresh action to enqueue the job."
            }
        }
    }

    /// The result of a refresh materialize: what to append and how. The caller
    /// (on the main actor) switches on this to pick the right store primitive.
    public enum RefreshMaterial: Sendable {
        /// Append a new content version (website refresh). Carries the fresh
        /// bytes, typed detection hints, and the provider's provenance.
        case contentVersion(
            data: Data,
            detectionHints: ContentTypeDetectionHints,
            provenance: SourceProvenance
        )
        /// Append a new derived markdown version (podcast byteless refresh).
        /// Provenance is intentionally omitted — `appendProcessedMarkdown` has
        /// no PROV parameter; the source-level `apple-podcast` agent (recorded
        /// at v1 creation) remains authoritative. Transcript-level PROV (agent
        /// `apple-ttml`) is deferred to Phase 4.
        case derivedMarkdown(content: String)
    }

    public let fetcher: any URLFetchService.URLResourceFetcher

    public init(fetcher: any URLFetchService.URLResourceFetcher) {
        self.fetcher = fetcher
    }

    /// Read the origin → reconstruct the provider → materialize OFF-main.
    /// Returns the material the caller should append. Throws `.notRefreshable`
    /// for import-only sources and `.missingPlan` when a refreshable source's
    /// origin has no URL.
    public func materialize(origin: SourceOrigin) async throws -> RefreshMaterial {
        // nil/unknown provider (forward-compat: a newer build wrote an unknown
        // `agents.name`) → not refreshable. The known-provider arms mirror the
        // `provider.supportsRefresh` baseline, but stay explicit so the refresh
        // path's branching is self-documenting (and the compiler's
        // exhaustiveness check fails if a new provider is added).
        switch origin.provider {
        case .website:
            return try await materializeWebsite(origin: origin)
        case .applePodcast, .podcast:
            // Both podcast arms run through the app's extraction queue (the
            // extractor-package routes). The app's Transcribe and refresh
            // actions enqueue that job instead of calling a materializer.
            throw RefreshError.podcastQueueRequired
        case .localFile, .zotero, .markdownFolder, .youtube, .vimeo, .spotify,
             .soundcloud, .remoteMedia, .legacyImport, nil:
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
        return .contentVersion(
            data: source.data,
            detectionHints: source.detectionHints,
            provenance: prov)
    }
}
