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
/// `@unchecked Sendable`: every stored `let` is immutable and `Sendable`, and
/// the one mutable surface (the per-wiki recovery one-shot set) is
/// NSLock-guarded, which is the invariant that makes the unchecked
/// conformance safe. It hops to the main actor only when reading
/// `ExtractionCoordinator` state.
// swiftlint:disable:next unchecked_sendable
final class DaemonQueueExtractionProvider: QueueExtractionProvider, @unchecked Sendable {
    private let extractionServices: any ExtractionServices
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?
    /// Prepares the wiki's store on demand (`WikiDaemon.openStore`). A fresh
    /// relaunch may not have the store ready when a queued item is claimed;
    /// without this, the item starves between claim and resolution.
    private let openStore: @Sendable (WikiID) async -> Bool
    /// The durable queue store for the attachment drain's follow-on
    /// format-route enqueue (enqueue-only — never a queue engine). Nil
    /// disables the follow-on (tests).
    private let queueStore: QueueStore?
    /// Engine-side enqueue for follow-on format routes. When injected, a
    /// follow-on item is enqueued THROUGH the engine — its dispatch scan
    /// runs immediately, so the follow-on job starts without waiting for an
    /// unrelated engine event to notice the bare store row. The typed dedupe
    /// key makes the insert idempotent (app and daemon share the key shape,
    /// so a race between both hosts converges on one item). When `nil`, the
    /// store-only fallback below applies (construction sites without an
    /// engine; the row is still visible to any later scan).
    private let engineEnqueue: (@Sendable (QueueItemRequest) async throws -> QueueItem.ID)?

    init(
        extractionServices: any ExtractionServices,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
        openStore: @escaping @Sendable (WikiID) async -> Bool = { _ in false },
        queueStore: QueueStore? = nil,
        engineEnqueue: (@Sendable (QueueItemRequest) async throws -> QueueItem.ID)? = nil
    ) {
        self.extractionServices = extractionServices
        self.storeResolver = storeResolver
        self.openStore = openStore
        self.queueStore = queueStore
        self.engineEnqueue = engineEnqueue
    }

    // MARK: - QueueExtractionProvider

    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        var store = storeResolver(wikiID)
        if store == nil {
            // A fresh relaunch may not have this wiki's store prepared yet.
            // Prepare it on demand instead of starving the queued item.
            _ = await openStore(wikiID)
            store = storeResolver(wikiID)
        }
        guard let store else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no store for wikiID=\(wikiID.rawValue)")
            return nil
        }

        // First-dispatch recovery (fetcher packages): converge any stranded
        // `formatJobPending` markers before resolving routes. One-shot per
        // wiki; the dedupe keys match the app's, so a concurrent app scan
        // cannot create a second item.
        await recoverStrandedFormatJobs(wikiID: wikiID, store: store)

        if let origin = DebugLog.trying("sourceOrigin", operation: { try store.sourceOrigin(sourceID: sourceID) }),
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

        // The generic acquisition decision — shared with the app, no
        // origin-provider branch. A byteless source with a validated plan
        // URL whose MIME an active fetcher registration claims resolves as
        // a fetch; a source with acquired bytes falls through to the
        // standard format route below.
        guard let origin = DebugLog.trying("sourceOrigin", operation: {
            try store.sourceOrigin(sourceID: sourceID)
        }) else {
            return nil
        }
        let sources = (DebugLog.trying("listSources", operation: { try store.listSources() })) ?? []
        let source = sources.first(where: { $0.id == sourceID })
        let claimedMIMEs = await activeFetcherClaimedMIMETypes()
        let readBytes = DebugLog.trying("sourceContent", operation: {
            try store.sourceContent(id: sourceID)
        })
        // A FAILED byte read is a typed error, never a silent "not yet
        // acquired": failing the item loudly keeps the queue truthful.
        guard readBytes != nil else {
            DebugLog.extraction("DaemonQueueExtractionProvider: source bytes unreadable for \(sourceID.rawValue)")
            throw DaemonStoreUnavailableError(wikiID: wikiID)
        }
        let route = FetchRouteDecision.resolve(
            hasBytes: !(readBytes ?? Data()).isEmpty,
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
        guard let bytes = readBytes, bytes.isEmpty == false else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no bytes for \(sourceID.rawValue)")
            return nil
        }
        guard let source else {
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

    @discardableResult
    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = storeResolver(wikiID) else {
            // A finished extraction whose store vanished mid-flight is data
            // loss — fail the item loudly instead of silently completing.
            DebugLog.extraction("DaemonQueueExtractionProvider: persistBytesExtraction — no store for wikiID=\(wikiID.rawValue)")
            throw DaemonStoreUnavailableError(wikiID: wikiID)
        }
        if let packageProducer = resolution.packageProducer {
            do {
                let version = try store.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: markdown, package: packageProducer,
                    origin: .extraction, toolVersion: resolution.modelVersion,
                    sourceVersionID: nil, note: nil)
                DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
                return QueueExtractionOutputReference(versionID: version.id.rawValue)
            } catch {
                DebugLog.store("DaemonQueueExtractionProvider: package write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        } else {
            guard let version = DebugLog.trying("recordMarkdownExtraction", operation: {
                try store.recordMarkdownExtraction(
                    sourceID: sourceID, content: markdown,
                    backend: resolution.backend,
                    sourceVersionID: nil, note: nil, modelVersion: resolution.modelVersion)
            }) else {
                return nil
            }
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        }
    }

    @discardableResult
    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = storeResolver(wikiID) else {
            // A finished extraction whose store vanished mid-flight is data
            // loss — fail the item loudly instead of silently completing.
            DebugLog.extraction("DaemonQueueExtractionProvider: persistTranscriptExtraction — no store for wikiID=\(wikiID.rawValue)")
            throw DaemonStoreUnavailableError(wikiID: wikiID)
        }
        switch resolution.resultMode {
        case .builtInTool(let tool):
            guard let version = DebugLog.trying("appendDerivedMarkdown", operation: {
                try store.appendDerivedMarkdown(
                    sourceID: sourceID, content: outcome.markdown, origin: .transcript,
                    producer: .tool(tool), providerID: nil,
                    modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
            }) else {
                return nil
            }
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)

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
                let version = try store.appendInstalledPackageMarkdown(
                    sourceID: sourceID, content: outcome.markdown, package: producer,
                    origin: .transcript, toolVersion: nil,
                    sourceVersionID: initialVersion.id, note: nil)
                DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
                return QueueExtractionOutputReference(versionID: version.id.rawValue)
            } catch {
                DebugLog.store("DaemonQueueExtractionProvider: package transcript write failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
        }
    }

    /// The synthetic input MIME types the ACTIVE fetcher registrations
    /// claim — the decision input for the shared fetch route. Same source of
    /// truth as the app provider, so both hosts decide identically.
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
    private func fetchProducer(
        _ resolution: FetcherResolution,
        _ outcome: FetchOutcome
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

    @discardableResult
    func persistFetch(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: FetcherResolution,
        outcome: FetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = storeResolver(wikiID) else {
            // A finished acquisition whose store vanished mid-flight is data
            // loss — fail the item loudly instead of silently completing.
            DebugLog.extraction("DaemonQueueExtractionProvider: persistFetch — no store for wikiID=\(wikiID.rawValue)")
            throw DaemonStoreUnavailableError(wikiID: wikiID)
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
            guard let initialVersion = try store.initialContentVersion(sourceID: sourceID) else {
                DebugLog.store("DaemonQueueExtractionProvider: fetch markdown has no initial source version (source=\(sourceID.rawValue))")
                throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
            }
            let version = try store.appendInstalledPackageMarkdown(
                sourceID: sourceID, content: markdown.markdown,
                package: fetchProducer(resolution, outcome),
                origin: .extraction, toolVersion: nil,
                sourceVersionID: initialVersion.id, note: nil)
            try store.setAcquisitionProvenance(
                sourceID: sourceID,
                externalItemKey: itemKey,
                externalItemTitle: itemTitle,
                displayName: itemTitle)
            try store.markFetchComplete(sourceID: sourceID)
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)

        case .sourceBytes(let bytes):
            // Bytes result: the output-file bytes ARE the source content. The
            // mutator stores the blob, sets the real MIME/ext/byte size and
            // the validated display filename, and writes the
            // `formatJobPending` marker with its exact producer — in one
            // transaction. The follow-on enqueue happens OUTSIDE this
            // wiki-store transaction (different database); the queue startup
            // recovery scan closes the crash gap between the two.
            let version = try store.attachAcquiredBytes(
                sourceID: sourceID,
                bytes: bytes.bytes,
                mimeType: bytes.mimeType.rawValue,
                originalFilename: bytes.originalFilename,
                externalItemKey: itemKey,
                externalItemTitle: itemTitle,
                producer: fetchProducer(resolution, outcome))
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        }
    }

    func enqueueFollowOnExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        acquiredContentVersionID: SourceVersionID,
        dedupeKey: QueueItemDedupeKey
    ) async throws {
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [sourceID]),
            dedupeKey: dedupeKey)
        // Preferred route: enqueue through the engine so its dispatch scan
        // runs immediately — the follow-on job dispatches with no other
        // trigger required. The dedupe key rides the request, so the XPC
        // surface carries it unchanged.
        if let engineEnqueue {
            do {
                _ = try await engineEnqueue(request)
            } catch {
                DebugLog.store("DaemonQueueExtractionProvider: follow-on format-route engine enqueue failed (source=\(sourceID.rawValue)): \(error)")
                throw error
            }
            return
        }
        // Fallback: no engine available at this construction site. The row
        // still lands in the store and is picked up by any later scan.
        guard let queueStore else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no queue store; follow-on format route not enqueued (source=\(sourceID.rawValue))")
            return
        }
        do {
            _ = try queueStore.enqueue(request)
        } catch {
            DebugLog.store("DaemonQueueExtractionProvider: follow-on format-route enqueue failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
    }

    // MARK: - FetchFormatJobRecovering (daemon)

    /// The queue startup path's recovery for this daemon process: at most
    /// one pass per wiki (first dispatch triggers it; the one-shot guard
    /// makes later dispatches no-ops).
    public func recoverStrandedFormatJobs(wikiID: WikiID, store: any WikiStore) async {
        guard markRecoveryStarted(wikiID) else { return }
        guard let queueStore else {
            unmarkRecovery(wikiID)
            return
        }
        await FetchFormatJobRecovery.run(
            wikiID: wikiID, store: store, queueStore: queueStore)
    }

    /// Wikis this process already recovery-scanned (one-shot per wiki).
    /// Lock-guarded: the class is `@unchecked Sendable` over immutable lets;
    /// this is the one mutable surface.
    private let recoveryLock = NSLock()
    private var recoveredWikis: Set<WikiID> = []

    private func markRecoveryStarted(_ wikiID: WikiID) -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        return recoveredWikis.insert(wikiID).inserted
    }

    private func unmarkRecovery(_ wikiID: WikiID) {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        recoveredWikis.remove(wikiID)
    }
}

/// Thrown when a finished extraction cannot be persisted because the wiki's
/// store disappeared mid-flight. Failing the item loudly (never silently
/// completing) keeps the queue's terminal state truthful.
struct DaemonStoreUnavailableError: Error, LocalizedError {
    let wikiID: WikiID

    var errorDescription: String? {
        "The wiki's store is no longer available; the extraction result could not be saved."
    }
}

#endif
