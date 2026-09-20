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
    /// Prepares the wiki's store on demand (`WikiDaemon.openStore`). A fresh
    /// relaunch may not have the store ready when a queued item is claimed;
    /// without this, the item starves between claim and resolution.
    private let openStore: @Sendable (WikiID) async -> Bool
    /// The durable queue store for the attachment drain's follow-on
    /// format-route enqueue (enqueue-only — never a queue engine). Nil
    /// disables the follow-on (tests).
    private let queueStore: QueueStore?

    init(
        extractionServices: any ExtractionServices,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
        openStore: @escaping @Sendable (WikiID) async -> Bool = { _ in false },
        queueStore: QueueStore? = nil
    ) {
        self.extractionServices = extractionServices
        self.storeResolver = storeResolver
        self.openStore = openStore
        self.queueStore = queueStore
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

            case .zotero:
                // Zotero attachment acquisition runs through the
                // reviewed/selected extractor package. The sync command
                // wrote the canonical Zotero file endpoint as the plan URL;
                // it becomes the typed operation input only after host URL
                // validation. The outcome is bytes-shaped: Markdown itself,
                // or source bytes the host routes to its own format path.
                guard let planURLString = origin.plan,
                      let validatedURL = ExtractorRemoteSourceURL(rawValue: planURLString) else {
                    return nil
                }
                let adapter = try await extractionServices.prepareZoteroAttachment()
                let producer = adapter.packageProvenance
                return .attachment(AttachmentExtractionResolution(
                    fetch: { onProgress in
                        let outcome = try await adapter.attachment(
                            for: validatedURL.url, onProgress: onProgress)
                        return AttachmentFetchOutcome(
                            outputBytes: outcome.outputBytes,
                            resultMIMEType: outcome.resultMIMEType,
                            articleMetadata: outcome.articleMetadata,
                            reportedMetadata: outcome.reportedMetadata)
                    },
                    filename: origin.externalIdentity ?? "attachment",
                    producer: producer))

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

    @discardableResult
    func persistAttachmentExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: AttachmentExtractionResolution,
        outcome: AttachmentFetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        guard let store = storeResolver(wikiID) else {
            // A finished acquisition whose store vanished mid-flight is data
            // loss — fail the item loudly instead of silently completing.
            DebugLog.extraction("DaemonQueueExtractionProvider: persistAttachmentExtraction — no store for wikiID=\(wikiID.rawValue)")
            throw DaemonStoreUnavailableError(wikiID: wikiID)
        }
        // Provenance fields the package reported (identifier = the Zotero
        // parent item key; title becomes the display name).
        let itemKey = outcome.articleMetadata?.identifier
        let itemTitle = outcome.articleMetadata?.title

        if outcome.isMarkdownResult {
            // Markdown result: podcast-shaped package provenance write, and
            // the retained Zotero columns ride along.
            guard let initialVersion = try store.initialContentVersion(sourceID: sourceID) else {
                DebugLog.store("DaemonQueueExtractionProvider: attachment markdown has no initial source version (source=\(sourceID.rawValue))")
                throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
            }
            guard let markdown = String(data: outcome.outputBytes, encoding: .utf8) else {
                throw ProcessPackageRunError.invalidOutputEncoding
            }
            let producer = ExtractionInstalledPackageProducer(
                revision: resolution.producer.revision,
                registrationID: resolution.producer.registrationID,
                protocolRevision: resolution.producer.protocolRevision,
                reportedMetadata: outcome.reportedMetadata)
            let version = try store.appendInstalledPackageMarkdown(
                sourceID: sourceID, content: markdown, package: producer,
                origin: .extraction, toolVersion: nil,
                sourceVersionID: initialVersion.id, note: nil)
            try store.setAcquisitionProvenance(
                sourceID: sourceID,
                externalItemKey: itemKey,
                externalItemTitle: itemTitle,
                displayName: itemTitle)
            DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        }

        // Bytes result: the output-file bytes ARE the source content. The
        // mutator stores the blob, sets the real MIME/ext/byte size, and
        // populates the retained columns in one transaction.
        guard let mimeType = outcome.resultMIMEType else {
            throw ProcessPackageRunError.unexpectedBytesResult
        }
        let version = try store.attachAcquiredBytes(
            sourceID: sourceID,
            bytes: outcome.outputBytes,
            mimeType: mimeType.rawValue,
            externalItemKey: itemKey,
            externalItemTitle: itemTitle,
            displayName: itemTitle)
        DarwinNotifier.postChange(forWikiID: wikiID.rawValue)
        return QueueExtractionOutputReference(versionID: version.id.rawValue)
    }

    func enqueueFollowOnExtraction(wikiID: WikiID, sourceID: SourceID) async throws {
        guard let queueStore else {
            DebugLog.extraction("DaemonQueueExtractionProvider: no queue store; follow-on format route not enqueued (source=\(sourceID.rawValue))")
            return
        }
        do {
            _ = try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID])))
        } catch {
            DebugLog.store("DaemonQueueExtractionProvider: follow-on format-route enqueue failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
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
