import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

#if canImport(WikiFSEngine)

/// The daemon-layer implementation of `QueueExtractionProvider`. Bridges the
/// headless `QueueEngine` to the `@MainActor` `ExtractionCoordinator` +
/// `GRDBWikiStore` directly — no `WikiStoreModel`, no `FileProviderFacade`,
/// no `SessionLookupBox`.
///
/// Unlike the app's `@MainActor AppQueueExtractionProvider`, this type is
/// `@unchecked Sendable` (all stored properties are immutable `let`s of
/// `Sendable` types). It hops to the main actor only when reading
/// `ExtractionCoordinator` state.
final class DaemonQueueExtractionProvider: QueueExtractionProvider {
    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let storeResolver: @Sendable (String) -> GRDBWikiStore?

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        storeResolver: @escaping @Sendable (String) -> GRDBWikiStore?
    ) {
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.storeResolver = storeResolver
    }

    // MARK: - QueueExtractionProvider

    func resolveExtraction(
        wikiID: String,
        sourceID: PageID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        guard let store = storeResolver(wikiID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no store for wikiID=\(wikiID)")
            return nil
        }

        if let origin = try? store.sourceOrigin(sourceID: sourceID),
           let providerKind = origin.provider {
            switch providerKind {
            case .youtube:
                let videoID = origin.externalIdentity
                    ?? MediaEmbedURL.youtube(origin.plan ?? "")?.externalIdentity
                guard let videoID else { return nil }
                let svc = YouTubeTranscriptService()
                return ExtractionResolution(
                    transcriptFetch: { @Sendable in
                        try await svc.transcript(forVideoID: videoID).markdown
                    },
                    technique: "youtube-captions",
                    filename: "transcript")

            case .podcast:
                guard let planURLString = origin.plan,
                      let sourceURL = URL(string: planURLString) else {
                    return nil
                }
                let svc = RSSPodcastTranscriptService()
                return ExtractionResolution(
                    transcriptFetch: { @Sendable in
                        try await svc.transcript(forFeedURL: sourceURL).markdown
                    },
                    technique: "rss-podcast-transcript",
                    filename: "transcript")

            case .applePodcast:
                #if PODCAST_TRANSCRIPTS
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
                return ExtractionResolution(
                    transcriptFetch: { @Sendable in
                        let result = try await materializer.materialize()
                        return String(data: result.data, encoding: .utf8) ?? ""
                    },
                    technique: "apple-ttml",
                    filename: "transcript")
                #else
                return nil
                #endif

            default:
                break
            }
        }

        guard let bytes = try? store.sourceContent(id: sourceID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no bytes for \(sourceID.rawValue)")
            return nil
        }
        let sources = (try? store.listSources()) ?? []
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no source row for \(sourceID.rawValue)")
            return nil
        }

        let (extractor, cfg): (any MarkdownExtractor, ExtractionConfig) = await MainActor.run {
            (self.extractionCoordinator.current(), self.extractionCoordinator.config)
        }

        return ExtractionResolution(
            extractor: extractor,
            pdfData: bytes,
            filename: source.filename,
            backend: backendOverride ?? cfg.backend,
            modelVersion: cfg.currentModelVersion
        )
    }

    func persistExtraction(
        wikiID: String,
        sourceID: PageID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?,
        technique: String?
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: persistExtraction — no store for wikiID=\(wikiID)")
            return
        }
        if let technique {
            _ = try? store.appendProcessedMarkdown(
                sourceID: sourceID, content: markdown,
                origin: .transcript, note: nil, technique: technique)
        } else {
            _ = try? store.recordMarkdownExtraction(
                sourceID: sourceID, content: markdown,
                backend: backend,
                sourceVersionID: nil, note: nil, modelVersion: modelVersion)
        }
        DarwinNotifier.postChange(forWikiID: wikiID)
    }
}

#endif
