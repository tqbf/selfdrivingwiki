import Foundation
import WikiFSCore
import WikiFSEngine

/// The app-layer implementation of `QueueTranscriptionProvider`. Bridges the
/// headless `QueueEngine` (an actor in `WikiFSEngine`) to the `@MainActor`
/// `WikiStoreModel`.
///
/// The class is `@MainActor` (so it is implicitly `Sendable`). The engine
/// (running off-main) calls the protocol methods via `await`; Swift hops to
/// the main actor for each call. The actual transcript fetch runs off-main
/// inside the worker (the `fetch` closure is `@Sendable` and the fetchers are
/// `Sendable`).
///
/// Mirrors `AppQueueExtractionProvider` minus the PDF bytes — resolves the
/// source origin, builds the right `@Sendable` fetch closure per provider
/// (YouTube / RSS podcast / Apple podcast), and persists the result via
/// `WikiStoreModel.appendTranscriptMarkdown`.
@MainActor
final class AppQueueTranscriptionProvider: QueueTranscriptionProvider {
    private let sessionBox: SessionLookupBox

    init(sessionBox: SessionLookupBox) {
        self.sessionBox = sessionBox
    }

    // MARK: - QueueTranscriptionProvider

    func resolveTranscription(
        wikiID: String,
        sourceID: PageID
    ) async throws -> TranscriptionResolution? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueTranscriptionProvider: no session for wikiID=\(wikiID)")
            return nil
        }

        guard let origin = store.sourceOrigin(for: sourceID),
              let providerKind = origin.provider else {
            return nil
        }

        // Build the right detached fetch per provider, mirroring the three
        // private helpers in WikiStoreModel (transcribeYouTube/RSS/Podcast).
        switch providerKind {
        case .youtube:
            // externalIdentity IS the 11-char video ID (stored at ingest).
            // Fall back to re-parsing plan for legacy rows.
            let videoID = origin.externalIdentity
                ?? MediaEmbedURL.youtube(origin.plan ?? "")?.externalIdentity
            guard let videoID else { return nil }
            let svc = YouTubeTranscriptService()
            return TranscriptionResolution(
                fetch: { @Sendable in
                    try await svc.transcript(forVideoID: videoID).markdown
                },
                technique: "youtube-captions")

        case .podcast:
            // Generic RSS-feed podcast: reads origin.plan (the feed URL
            // recorded at ingest), fetches via RSSPodcastTranscriptService.
            guard let planURLString = origin.plan,
                  let sourceURL = URL(string: planURLString) else {
                return nil
            }
            let svc = RSSPodcastTranscriptService()
            return TranscriptionResolution(
                fetch: { @Sendable in
                    try await svc.transcript(forFeedURL: sourceURL).markdown
                },
                technique: "rss-podcast-transcript")

        case .applePodcast:
            #if PODCAST_TRANSCRIPTS
            // Apple Podcasts: reconstruct the episode from origin.plan (the
            // page URL), prefer the FairPlay signing helper, fall back to RSS.
            guard let planURLString = origin.plan,
                  let pageURL = URL(string: planURLString),
                  let episode = PodcastEpisodeURL.parse(planURLString) else {
                return nil
            }
            let fetcher: any PodcastTranscriptFetching =
                ApplePodcastTranscriptService.bundled()
                ?? RSSPodcastTranscriptService(sourceURL: pageURL)
            let materializer = ApplePodcastMaterializer(
                episode: episode, pageURL: pageURL, fetcher: fetcher)
            return TranscriptionResolution(
                fetch: { @Sendable in
                    let result = try await materializer.materialize()
                    return String(data: result.data, encoding: .utf8) ?? ""
                },
                technique: "apple-ttml")
            #else
            // Phase-out build: podcast support isn't compiled (WIKIFS_APP_STORE=1).
            // The View-level `isTranscribable` predicate returns `false` for
            // `.applePodcast` outside this flag, so this path is unreachable
            // in production UI.
            return nil
            #endif

        default:
            return nil
        }
    }

    func persistTranscription(
        wikiID: String,
        sourceID: PageID,
        markdown: String,
        technique: String
    ) async throws {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueTranscriptionProvider: persistTranscription — no session for wikiID=\(wikiID)")
            return
        }
        _ = store.appendTranscriptMarkdown(
            for: sourceID, content: markdown, technique: technique)
    }
}
