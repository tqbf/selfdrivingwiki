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
    /// The queue database URL for the attachment drain's follow-on
    /// format-route enqueue. Opened lazily (enqueue-only — never a queue
    /// engine); nil disables the follow-on (tests). A second handle on the
    /// same WAL database is safe: the store configures a busy timeout and
    /// GRDB serializes per handle.
    private let queueDatabaseURL: URL?
    private var followOnQueueStore: QueueStore?
    /// Wikis this process already recovery-scanned (one-shot per wiki).
    private var recoveredWikis: Set<WikiID> = []

    init(
        extractionServices: any ExtractionServices,
        sessionBox: SessionLookupBox,
        queueDatabaseURL: URL? = nil
    ) {
        self.extractionServices = extractionServices
        self.sessionBox = sessionBox
        self.queueDatabaseURL = queueDatabaseURL
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

        // The generic acquisition decision — shared with the daemon, no
        // origin-provider branch. A byteless source with a validated plan
        // URL whose MIME an active fetcher registration claims resolves as
        // a fetch; a source with acquired bytes falls through to the
        // standard format route below.
        if let origin = store.sourceOrigin(for: sourceID) {
            let source = store.sources.first(where: { $0.id == sourceID })
            let claimedMIMEs = await activeFetcherClaimedMIMETypes()
            // Parity with the daemon: a FAILED byte read (nil here) must not
            // read as "not yet acquired", which would re-fetch a source
            // whose bytes are already stored. The model read is non-throwing
            // and logs its own failure; resolution fails for this item.
            let probeBytes = store.sourceBytes(id: sourceID)
            guard let readBytes = probeBytes else {
                DebugLog.extraction("AppQueueExtractionProvider: source bytes unreadable for \(sourceID.rawValue)")
                return nil
            }
            let route = FetchRouteDecision.resolve(
                hasBytes: readBytes.isEmpty == false,
                planURL: origin.plan,
                mimeType: source?.mimeType,
                fetcherClaimedMIMETypes: claimedMIMEs)
            if route == .fetch {
                // The plan URL becomes the typed operation input only after
                // host URL validation (the decision already checked it).
                guard let planURLString = origin.plan,
                      let validatedURL = ExtractorRemoteSourceURL(rawValue: planURLString),
                      let sourceMIME = source?.mimeType,
                      let claimedMIME = ExtractorMIMEType(rawValue: sourceMIME.lowercased()) else {
                    return nil
                }
                let adapter = try await extractionServices.prepareFetcher(
                    sourceMIMEType: claimedMIME)
                let producer = adapter.packageProvenance
                return .fetch(FetcherResolution(
                    fetch: { onProgress in
                        let outcome = try await adapter.fetch(
                            for: validatedURL.url,
                            claimedMIMEType: claimedMIME,
                            displayFilename: origin.externalIdentity ?? "source",
                            onProgress: onProgress)
                        switch outcome {
                        case .markdown(let markdown):
                            return .markdown(FetchedMarkdown(
                                markdown: markdown.markdown,
                                reportedMetadata: markdown.reportedMetadata,
                                articleMetadata: markdown.articleMetadata))
                        case .sourceBytes(let bytes):
                            return .sourceBytes(FetchedSourceBytes(
                                bytes: bytes.bytes,
                                mimeType: bytes.mimeType,
                                originalFilename: bytes.originalFilename,
                                reportedMetadata: bytes.reportedMetadata,
                                articleMetadata: bytes.articleMetadata))
                        }
                    },
                    claimedMIMEType: claimedMIME,
                    filename: origin.externalIdentity ?? "source",
                    producer: producer))
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
                // This bytes job may BE the fetch drain's follow-on format
                // route: settle the marker now so fetch_state never goes
                // stale beside a finished product (recovery is the backstop).
                do {
                    if try store.internalStore.fetchState(sourceID: sourceID) == .formatJobPending {
                        try store.internalStore.markFetchComplete(sourceID: sourceID)
                    }
                } catch {
                    // Deliberately non-fatal: the startup recovery scan is the
                    // backstop that settles a stale marker.
                    DebugLog.store("AppQueueExtractionProvider: fetch-state settle skipped (source=\(sourceID.rawValue)): \(error)")
                }
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

    /// The synthetic input MIME types the ACTIVE fetcher registrations
    /// claim — the decision input for the shared fetch route.
    private func activeFetcherClaimedMIMETypes() async -> Set<String> {
        let snapshots = await extractionServices.activeRegistrationSnapshots()
        var claims: Set<String> = []
        for snapshot in snapshots where snapshot.role == .fetcher {
            for mimeType in snapshot.mimeTypes {
                claims.insert(mimeType.rawValue)
            }
        }
        return claims
    }

    @discardableResult
    func persistFetch(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: FetcherResolution,
        outcome: FetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: persistFetch — no session for wikiID=\(wikiID)")
            return nil
        }
        // Provenance fields the package reported (identifier = the returned
        // parent item key; title becomes the display name). Neutral
        // acquisition metadata — never a host identity.
        let itemKey = outcomeReportedIdentifier(outcome)
        let itemTitle = outcomeReportedTitle(outcome)

        switch outcome {
        case .markdown(let markdown):
            // Markdown result: package-provenance write, then the source is
            // complete — no format job exists to wait for.
            guard let initialVersion = store.initialContentVersion(for: sourceID) else {
                DebugLog.store("AppQueueExtractionProvider: fetch markdown has no initial source version (source=\(sourceID.rawValue))")
                throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
            }
            let producer = ExtractionInstalledPackageProducer(
                revision: resolution.producer.revision,
                registrationID: resolution.producer.registrationID,
                protocolRevision: resolution.producer.protocolRevision,
                reportedMetadata: markdown.reportedMetadata)
            // One transaction: the derived Markdown version, the neutral
            // external provenance, and the fetch-state advance to `complete`.
            // A crash can never leave the source `pending` beside a finished
            // product (which would make a retry append a second version).
            let version = try store.internalStore.appendFetchMarkdown(
                sourceID: sourceID, content: markdown.markdown, package: producer,
                externalItemKey: itemKey, externalItemTitle: itemTitle,
                sourceVersionID: initialVersion.id)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)

        case .sourceBytes(let bytes):
            // Bytes result: the output-file bytes ARE the source content. The
            // mutator stores the blob, sets the real MIME/ext/byte size and
            // the validated display filename, and writes the
            // `formatJobPending` marker with its exact producer — in one
            // transaction. The follow-on enqueue happens OUTSIDE this
            // wiki-store transaction (different database), and the queue
            // startup recovery scan closes the crash gap between the two.
            let version = try store.internalStore.attachAcquiredBytes(
                sourceID: sourceID,
                bytes: bytes.bytes,
                mimeType: bytes.mimeType.rawValue,
                originalFilename: bytes.originalFilename,
                externalItemKey: itemKey,
                externalItemTitle: itemTitle,
                producer: producer(resolution: resolution, outcome: outcome))
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        }
    }

    private func outcomeReportedIdentifier(_ outcome: FetchOutcome) -> String? {
        switch outcome {
        case .markdown(let value): return value.articleMetadata?.identifier
        case .sourceBytes(let value): return value.articleMetadata?.identifier
        }
    }

    private func outcomeReportedTitle(_ outcome: FetchOutcome) -> String? {
        switch outcome {
        case .markdown(let value): return value.articleMetadata?.title
        case .sourceBytes(let value): return value.articleMetadata?.title
        }
    }

    /// The exact fetch producer for the outcome's reported metadata.
    private func producer(
        resolution: FetcherResolution,
        outcome: FetchOutcome
    ) -> ExtractionInstalledPackageProducer {
        let reported: ExtractorReportedMetadata
        switch outcome {
        case .markdown(let value): reported = value.reportedMetadata
        case .sourceBytes(let value): reported = value.reportedMetadata
        }
        return ExtractionInstalledPackageProducer(
            revision: resolution.producer.revision,
            registrationID: resolution.producer.registrationID,
            protocolRevision: resolution.producer.protocolRevision,
            reportedMetadata: reported)
    }

    func enqueueFollowOnExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        acquiredContentVersionID: SourceVersionID,
        dedupeKey: QueueItemDedupeKey
    ) async throws {
        let store: QueueStore
        if let followOnQueueStore {
            store = followOnQueueStore
        } else if let queueDatabaseURL {
            store = try QueueStore(databaseURL: queueDatabaseURL)
            followOnQueueStore = store
        } else {
            DebugLog.extraction("AppQueueExtractionProvider: no queue database URL; follow-on format route not enqueued (source=\(sourceID.rawValue))")
            return
        }
        do {
            _ = try store.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]),
                dedupeKey: dedupeKey))
        } catch {
            DebugLog.store("AppQueueExtractionProvider: follow-on format-route enqueue failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
    }
}

// MARK: - FetchFormatJobRecovering (app)

extension AppQueueExtractionProvider: FetchFormatJobRecovering {
    /// The queue startup path's recovery for this app process: at most one
    /// pass per wiki (session open triggers the first; a dispatch re-entry
    /// is a no-op via the one-shot guard).
    public func recoverStrandedFormatJobs(wikiID: WikiID, store: any WikiStore) async {
        guard recoveredWikis.insert(wikiID).inserted else { return }
        guard let queueStore = followOnQueueStoreOrOpened() else {
            recoveredWikis.remove(wikiID)
            return
        }
        await FetchFormatJobRecovery.run(
            wikiID: wikiID, store: store, queueStore: queueStore)
    }

    private func followOnQueueStoreOrOpened() -> QueueStore? {
        if let followOnQueueStore { return followOnQueueStore }
        guard let queueDatabaseURL else { return nil }
        do {
            let store = try QueueStore(databaseURL: queueDatabaseURL)
            followOnQueueStore = store
            return store
        } catch {
            DebugLog.store("AppQueueExtractionProvider: recovery queue store open failed: \(error)")
            return nil
        }
    }
}
