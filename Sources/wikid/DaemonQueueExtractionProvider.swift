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
    private let extractionServices: any ExtractionServices
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?

    init(
        extractionServices: any ExtractionServices,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?
    ) {
        self.extractionServices = extractionServices
        self.storeResolver = storeResolver
    }

    // MARK: - QueueExtractionProvider

    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        guard let store = storeResolver(wikiID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no store for wikiID=\(wikiID.rawValue)")
            return nil
        }

        if let origin = DebugLog.trying("sourceOrigin", operation: { try store.sourceOrigin(sourceID: sourceID) }),
           let providerKind = origin.provider {
            switch providerKind {
            case .youtube:
                let videoID = origin.externalIdentity
                    ?? MediaEmbedURL.youtube(origin.plan ?? "")?.externalIdentity
                guard let videoID else { return nil }
                let svc = YouTubeTranscriptService()
                return .transcript(TranscriptExtractionResolution(
                    fetch: { _ in
                        TranscriptFetchOutcome(
                            markdown: try await svc.transcript(forVideoID: videoID).markdown)
                    },
                    filename: "transcript",
                    resultMode: .builtInTool(.youtubeCaptions)))

            case .podcast:
                // RSS podcast transcripts run through the reviewed/selected
                // extractor package. The source URL becomes the typed
                // operation input only after host URL validation.
                guard let planURLString = origin.plan,
                      let validatedURL = ExtractorRemoteSourceURL(rawValue: planURLString) else {
                    return nil
                }
                let adapter = try await extractionServices.preparePodcastTranscript()
                let producer = adapter.packageProvenance
                return .transcript(TranscriptExtractionResolution(
                    fetch: { onProgress in
                        let outcome = try await adapter.transcript(
                            for: validatedURL.url, onProgress: onProgress)
                        return TranscriptFetchOutcome(
                            markdown: outcome.markdown,
                            reportedMetadata: outcome.reportedMetadata)
                    },
                    filename: "transcript",
                    resultMode: .installedPackage(producer),
                    requiresInitialSourceVersion: true))

            case .applePodcast:
                #if PODCAST_TRANSCRIPTS
                // Apple TTML keeps its built-in materializer and its current
                // RSS fallback (issue #812 no-signing-helper rationale). The
                // fallback sites below are allow-listed for
                // ExtractionCompositionBoundaryTests and removed by the Apple
                // TTML packaging follow-up.
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
                return .transcript(TranscriptExtractionResolution(
                    fetch: { _ in
                        let result = try await materializer.materialize()
                        return TranscriptFetchOutcome(
                            markdown: String(data: result.data, encoding: .utf8) ?? "")
                    },
                    filename: "transcript",
                    resultMode: .builtInTool(.appleTTML)))
                #else
                return nil
                #endif

            default:
                break
            }
        }

        guard let bytes = DebugLog.trying("sourceContent", operation: { try store.sourceContent(id: sourceID) }) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no bytes for \(sourceID.rawValue)")
            return nil
        }
        let sources = (DebugLog.trying("listSources", operation: { try store.listSources() })) ?? []
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no source row for \(sourceID.rawValue)")
            return nil
        }

        let preparation = try await extractionServices.prepare(
            backendOverride: backendOverride)

        return .bytes(BytesExtractionResolution(
            extractor: preparation.extractor,
            sourceBytes: bytes,
            filename: source.filename,
            backend: preparation.backend,
            modelVersion: preparation.modelVersion,
            packageProducer: preparation.packageProvenance))
    }

    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: persistBytesExtraction — no store for wikiID=\(wikiID.rawValue)")
            return
        }
        if let packageProducer = resolution.packageProducer {
            do {
                _ = try store.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: markdown, package: packageProducer,
                    origin: .extraction, toolVersion: resolution.modelVersion,
                    sourceVersionID: nil, note: nil)
            } catch {
                DebugLog.store("DaemonQueueExtractionProvider: package write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        } else {
            _ = DebugLog.trying("recordMarkdownExtraction", operation: {
                try store.recordMarkdownExtraction(
                    sourceID: sourceID, content: markdown,
                    backend: resolution.backend,
                    sourceVersionID: nil, note: nil, modelVersion: resolution.modelVersion)
            })
        }
        DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
    }

    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws {
        guard let store = storeResolver(wikiID) else {
            DebugLog.extraction("DaemonQueueExtractionProvider: persistTranscriptExtraction — no store for wikiID=\(wikiID.rawValue)")
            return
        }
        switch resolution.resultMode {
        case .builtInTool(let tool):
            _ = DebugLog.trying("appendDerivedMarkdown", operation: {
                try store.appendDerivedMarkdown(
                    sourceID: sourceID, content: outcome.markdown, origin: .transcript,
                    producer: .tool(tool), providerID: nil,
                    modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
            })

        case .installedPackage(let baseProducer):
            // Package transcript: resolve the source's immutable initial
            // version FIRST and fail before writing when absent (issue #251).
            guard let initialVersion = try store.initialContentVersion(sourceID: sourceID) else {
                DebugLog.store("DaemonQueueExtractionProvider: package transcript has no initial source version (source=\(sourceID.rawValue))")
                throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
            }
            let producer = ExtractionInstalledPackageProducer(
                revision: baseProducer.revision,
                registrationID: baseProducer.registrationID,
                protocolRevision: baseProducer.protocolRevision,
                reportedMetadata: outcome.reportedMetadata)
            do {
                _ = try store.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: outcome.markdown, package: producer,
                    origin: .transcript, toolVersion: nil,
                    sourceVersionID: initialVersion.id, note: nil)
            } catch {
                DebugLog.store("DaemonQueueExtractionProvider: package transcript write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        }
        DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
    }
}

#endif
