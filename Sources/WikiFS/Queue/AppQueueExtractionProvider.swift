import Foundation
import WikiFSCore
import WikiFSEngine

/// A mutable, `@MainActor`-isolated box for the session-lookup closure. This
/// breaks the construction-order cycle in `WikiFSApp.init`:
///
/// 1. `QueueStore` (no deps)
/// 2. `SessionLookupBox` (no deps — empty closure)
/// 3. `AppQueueExtractionProvider` (needs coordinator + box)
/// 4. `QueueExtractionWorkerFactory` (needs provider)
/// 5. `QueueEngine` (needs store + factory)
/// 6. `SessionManager` (needs coordinator + engine + provider)
/// 7. Box is pointed at `sessionManager.sessions` lookup
///
/// The box starts with a closure that returns nil (no sessions yet). After the
/// session manager is constructed, the box is updated to look up real sessions.
/// The provider captures the box (a reference type), so it sees the update.

/// A mutable, `@MainActor`-isolated box for a `FileProviderFacade` reference.
/// Used by `AppQueueIngestionProvider` to access the file provider without
/// needing it at construction time (the app's `@State fileProvider` is
/// initialized via its property initializer, not in `init()`).
@MainActor
final class FileProviderBox: @unchecked Sendable {
    var provider: FileProviderFacade?
}

@MainActor
final class SessionLookupBox: @unchecked Sendable {
    /// Returns the live `WikiStoreModel` for a wikiID, or nil if no session is
    /// open. `@MainActor` + `@Sendable` so it can be called from a
    /// `@MainActor`-isolated provider.
    private var lookup: @MainActor @Sendable (WikiID) -> WikiStoreModel?

    /// Returns the live `WikiSession` for a wikiID, or nil if no session is
    /// open. Used by the ingestion provider to access the session's launcher.
    private var sessionLookup: @MainActor @Sendable (WikiID) -> (any WikiSessionProtocol)?

    init() {
        // No sessions exist yet — return nil. Replaced after SessionManager
        // construction.
        self.lookup = { _ in nil }
        self.sessionLookup = { _ in nil }
    }

    /// Synchronous resolution (caller must be on the main actor).
    func resolve(wikiID: WikiID) -> WikiStoreModel? {
        lookup(wikiID)
    }

    /// Synchronous session resolution (caller must be on the main actor).
    func resolveSession(for wikiID: WikiID) -> (any WikiSessionProtocol)? {
        sessionLookup(wikiID)
    }

    /// Wire the box to the real session manager (called after construction).
    func setLookup(_ lookup: @escaping @MainActor @Sendable (WikiID) -> WikiStoreModel?) {
        self.lookup = lookup
    }

    /// Wire the session-lookup closure to the real session manager.
    func setSessionLookup(_ lookup: @escaping @MainActor @Sendable (WikiID) -> (any WikiSessionProtocol)?) {
        self.sessionLookup = lookup
    }
}

/// The app-layer implementation of `QueueExtractionProvider`. Bridges the
/// headless `QueueEngine` (an actor in `WikiFSEngine`) to the `@MainActor`
/// `ExtractionCoordinator` + `WikiStoreModel`.
///
/// The class is `@MainActor` (so it is implicitly `Sendable`). The engine
/// (running off-main) calls the protocol methods via `await`; Swift hops to
/// the main actor for each call. The actual `convert()` runs off-main inside
/// the worker (the `MarkdownExtractor` is `Sendable`).
@MainActor
final class AppQueueExtractionProvider: QueueExtractionProvider {
    private let extractionServices: any ExtractionServices
    private let sessionBox: SessionLookupBox

    init(
        extractionServices: any ExtractionServices,
        sessionBox: SessionLookupBox
    ) {
        self.extractionServices = extractionServices
        self.sessionBox = sessionBox
    }

    // MARK: - QueueExtractionProvider

    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: no session for wikiID=\(wikiID)")
            return nil
        }

        // Transcript sources have no local bytes; the markdown comes from a
        // URL-backed fetch resolved through the extraction services.
        if let origin = store.sourceOrigin(for: sourceID),
           let providerKind = origin.provider {
            switch providerKind {
            case .youtube:
                // YouTube transcripts run through the reviewed/selected
                // extractor package — the same route shape as the podcast
                // siblings. The stored plan URL wins when it validates, so
                // watch, short, Shorts, and embed rows keep their source
                // contract; a legacy row with only a video ID resolves to
                // the canonical watch URL. Invalid data never launches a
                // package.
                guard let sourceURL = YouTubeSourceURL.resolveOperationURL(
                    plan: origin.plan,
                    externalIdentity: origin.externalIdentity) else {
                    return nil
                }
                let adapter = try await extractionServices.prepareYouTubeTranscript()
                let producer = adapter.packageProvenance
                return .transcript(TranscriptExtractionResolution(
                    fetch: { onProgress in
                        let outcome = try await adapter.transcript(
                            for: sourceURL, onProgress: onProgress)
                        return TranscriptFetchOutcome(
                            markdown: outcome.markdown,
                            reportedMetadata: outcome.reportedMetadata)
                    },
                    filename: "transcript",
                    resultMode: .installedPackage(producer)))

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
                    resultMode: .installedPackage(producer)))

            case .applePodcast:
                // Apple transcripts run through the reviewed/selected
                // extractor package — the same route shape as the RSS
                // sibling. The package picks its Apple TTML workflow or its
                // RSS fallback from the host-staged operation support, so a
                // missing helper keeps the route usable. The source URL
                // becomes the typed operation input only after host URL
                // validation.
                guard let planURLString = origin.plan,
                      let validatedURL = ExtractorRemoteSourceURL(rawValue: planURLString) else {
                    return nil
                }
                let adapter = try await extractionServices.prepareApplePodcastTranscript()
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
                    resultMode: .installedPackage(producer)))

            default:
                break
            }
        }

        // Regular bytes-based extraction (PDF, HTML, DOCX).
        guard let source = store.sources.first(where: { $0.id == sourceID }),
              let bytes = store.sourceBytes(id: sourceID)
        else {
            DebugLog.extraction("AppQueueExtractionProvider: no source/bytes for \(sourceID.rawValue)")
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

    @discardableResult
    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: persistBytesExtraction — no session for wikiID=\(wikiID)")
            return nil
        }
        if let packageProducer = resolution.packageProducer {
            do {
                let version = try store.internalStore.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: markdown, package: packageProducer,
                    origin: .extraction, toolVersion: resolution.modelVersion,
                    sourceVersionID: nil, note: nil)
                return QueueExtractionOutputReference(versionID: version.id.rawValue)
            } catch {
                DebugLog.store("AppQueueExtractionProvider: package provenance write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        } else {
            let version = store.seedPdfMarkdown(
                for: sourceID,
                content: markdown,
                backend: resolution.backend,
                modelVersion: resolution.modelVersion
            )
            return version.map { QueueExtractionOutputReference(versionID: $0.id.rawValue) }
        }
    }

    @discardableResult
    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: persistTranscriptExtraction — no session for wikiID=\(wikiID)")
            return nil
        }
        switch resolution.resultMode {
        case .builtInTool(let tool):
            // Built-in tool: keep the existing log-only discipline (the fetch
            // succeeded; a store-write failure leaves a Console.app trace).
            let version = store.appendTranscriptMarkdown(
                for: sourceID, content: outcome.markdown, tool: tool)
            return version.map { QueueExtractionOutputReference(versionID: $0.id.rawValue) }

        case .installedPackage(let baseProducer):
            // Package transcript: resolve the source's immutable initial
            // version FIRST and fail before writing when absent (issue #251).
            guard let initialVersion = store.initialContentVersion(for: sourceID) else {
                DebugLog.store("AppQueueExtractionProvider: package transcript has no initial source version (source=\(sourceID.rawValue))")
                throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
            }
            // Exact provenance: revision, registration, protocol revision,
            // and the redacted package-reported metadata.
            let producer = ExtractionInstalledPackageProducer(
                revision: baseProducer.revision,
                registrationID: baseProducer.registrationID,
                protocolRevision: baseProducer.protocolRevision,
                reportedMetadata: outcome.reportedMetadata)
            do {
                let version = try store.internalStore.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: outcome.markdown, package: producer,
                    origin: .transcript, toolVersion: nil,
                    sourceVersionID: initialVersion.id, note: nil)
                return QueueExtractionOutputReference(versionID: version.id.rawValue)
            } catch {
                DebugLog.store("AppQueueExtractionProvider: package transcript write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        }
    }
}
