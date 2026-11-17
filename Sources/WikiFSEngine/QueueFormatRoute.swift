import Foundation
import WikiFSCore
import WikiFSMarkdown

/// The daemon queue's package format-route conversion: the durable
/// format-job path's HTML and DOCX arms.
///
/// Route RECOGNITION is registration data, never a host branch: the active
/// registrations' declared inputs (`RegisteredExtractionInputs`) claim the
/// source's stored MIME type or filename extension, exactly like the
/// import gate's client-side derivation. The claimed kind then dispatches
/// through the single typed adapter seam below — the per-kind extractor
/// protocols have genuinely different operation shapes, so the switch maps
/// the claimed kind to its `prepare…` function and nothing else.
///
/// Route PERSISTENCE lives beside the resolution (`persistHtml`,
/// `persistDocx`, `persistRefresh`) so the surviving queue host — the
/// daemon's `DaemonQueueExtractionProvider` — delegates with no local
/// pipeline of its own. The write semantics mirror the app model's inline
/// pipelines verbatim: `.extraction`-origin derived markdown, the package
/// producer (or `.tool(.html)` for the built-in tag-based floor), and the
/// backend-named note.
public enum QueueFormatRoute {
    // MARK: - Technique tags (compatibility contract of the version rows)

    /// The HTML tag-based conversion's technique column value.
    public static let htmlToMarkdownTechnique = "html-to-markdown"
    /// The Defuddle package conversion's technique column value.
    public static let defuddleTechnique = "defuddle"
    /// The docx2md package conversion's technique column value (the app
    /// model's inline pipeline stamped this exact string).
    public static let docxTechnique = "docx-to-markdown"

    // MARK: - Recognition

    /// The active registration claim for one stored source — MIME first,
    /// then the filename extension, exactly like the import gate's
    /// client-side derivation. `nil` when no active claim recognizes the
    /// source (it falls through to the generic arms).
    public static func claimedKind(
        summary: SourceSummary,
        registeredInputs: RegisteredExtractionInputs
    ) -> ExtractorKind? {
        registeredInputs
            .registeredMIME(forNormalizedMIME: summary.mimeType ?? "")?.kind
            ?? registeredInputs
                .registeredInput(forNormalizedExtension: summary.ext)?.kind
    }

    // MARK: - Resolution

    /// Resolves the package format route for one source, or `nil` when no
    /// active claim recognizes it. The source's bytes are read HERE and
    /// captured immutably in the resolution's closure — the conversion then
    /// needs no store access. A claimed kind whose package preparation fails
    /// or whose DOCX runtime is not ready THROWS: the queue worker fails the
    /// item with the message, never a silent PDF fallback.
    public static func resolve(
        store: GRDBWikiStore,
        sourceID: SourceID,
        summary: SourceSummary,
        services: any ExtractionServices,
        htmlBackendOverride: HtmlExtractionBackend?
    ) async throws -> ExtractionResolution? {
        let registeredInputs = await services.registeredExtractionInputs()
        guard let kind = claimedKind(summary: summary, registeredInputs: registeredInputs) else {
            return nil
        }
        // The bytes are the conversion input for both arms; a FAILED read is
        // a typed error, never a silent skip (parity with the fetch arm).
        guard let bytes = DebugLog.trying("sourceContent", operation: {
            try store.sourceContent(id: sourceID)
        }), bytes.isEmpty == false else {
            throw ExtractionServicesError.unavailable
        }

        // (typed-kind-dispatch: format-route adapter — the single typed
        // dispatch over the claimed kind; policy never reaches this switch.)
        switch kind {
        case .html:
            let extractor = try await services.prepareHTML(
                backendOverride: htmlBackendOverride)
            let producer = Self.packageProducer(of: extractor)
            // The note's backend label names what the ROUTE RESOLVED: a
            // package adapter is the defuddle route, the built-in floor is
            // tag-based — derived from the resolution, never a guess from
            // the request.
            let backend: HtmlExtractionBackend = producer == nil ? .tagBased : .defuddle
            let technique = backend == .defuddle
                ? Self.defuddleTechnique
                : Self.htmlToMarkdownTechnique
            let filename = summary.filename
            return .html(HtmlExtractionResolution(
                extract: {
                    let html = String(data: bytes, encoding: .utf8)
                        ?? String(decoding: bytes, as: UTF8.self)
                    guard let result = await extractor.extract(html: html),
                          !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw QueueExtractionError.notReady(
                            "the HTML conversion returned no markdown")
                    }
                    return result.markdown
                },
                filename: filename,
                backend: backend,
                producer: producer,
                technique: technique))

        case .docx:
            let extractor = try await services.prepareDOCX()
            // A cheap probe before the conversion (parity with the inline
            // pipeline): a not-ready runtime is user-facing setup guidance,
            // never a managed-spawn failure.
            let readiness = await extractor.readiness()
            guard readiness.isReady else {
                let message: String
                switch readiness {
                case .needsSetup(let msg): message = msg
                case .notInstalled(let msg): message = msg
                case .ready: message = ""  // unreachable
                }
                throw QueueExtractionError.notReady(message)
            }
            let producer = ExtractionInstalledPackageProducer(
                revision: extractor.packageProvenance.revision,
                registrationID: extractor.packageProvenance.registrationID,
                protocolRevision: extractor.packageProvenance.protocolRevision,
                reportedMetadata: extractor.packageProvenance.reportedMetadata)
            let filename = summary.filename
            return .docx(DocxExtractionResolution(
                extract: {
                    guard let result = await extractor.extract(docx: bytes),
                          !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw QueueExtractionError.notReady(
                            "the DOCX conversion returned no markdown")
                    }
                    return result.markdown
                },
                filename: filename,
                producer: producer,
                technique: Self.docxTechnique))

        default:
            return nil
        }
    }

    /// The exact installed-package producer for a prepared HTML adapter;
    /// `nil` for the built-in tag-based floor (its write carries
    /// `.tool(.html)` provenance instead).
    private static func packageProducer(
        of extractor: any HtmlMarkdownExtractor
    ) -> ExtractionInstalledPackageProducer? {
        guard let processExtractor = extractor as? any ProcessPackageProvenanceProviding else {
            return nil
        }
        return ExtractionInstalledPackageProducer(
            revision: processExtractor.packageProvenance.revision,
            registrationID: processExtractor.packageProvenance.registrationID,
            protocolRevision: processExtractor.packageProvenance.protocolRevision,
            reportedMetadata: processExtractor.packageProvenance.reportedMetadata)
    }

    // MARK: - Persistence

    /// Persists one HTML format-route conversion with the app model's inline
    /// write semantics. `nominateActive` flips the active pointer to the new
    /// version when a head already exists — the import conversion contract
    /// (issue #1380: the route selection, not the snapshot sidecar, is the
    /// readable text). Manual runs append coexisting alternatives only.
    public static func persistHtml(
        store: GRDBWikiStore,
        sourceID: SourceID,
        resolution: HtmlExtractionResolution,
        markdown: String,
        nominateActive: Bool
    ) throws -> QueueExtractionOutputReference? {
        do {
            let version = try store.appendDerivedMarkdown(
                sourceID: sourceID, content: markdown, origin: .extraction,
                producer: resolution.producer.map(ExtractionProducer.installedPackage) ?? .tool(.html),
                providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil,
                note: "extract via \(resolution.backend.displayName): \(resolution.technique)")
            // This job may BE the fetch drain's follow-on format route:
            // settle a pending marker so fetch_state never goes stale beside
            // a finished product (the startup recovery is the backstop).
            Self.settleFetchStateIfPending(store: store, sourceID: sourceID)
            if nominateActive {
                try store.setActiveMarkdown(sourceID: sourceID, to: version.id)
            }
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        } catch {
            DebugLog.store("QueueFormatRoute.persistHtml failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
    }

    /// Persists one DOCX format-route conversion — the `.extraction`-origin
    /// derived-markdown version with the exact installed-package producer
    /// and the docx technique note (the app model's inline contract).
    public static func persistDocx(
        store: GRDBWikiStore,
        sourceID: SourceID,
        resolution: DocxExtractionResolution,
        markdown: String
    ) throws -> QueueExtractionOutputReference? {
        do {
            let version = try store.appendDerivedMarkdown(
                sourceID: sourceID, content: markdown, origin: .extraction,
                producer: .installedPackage(resolution.producer),
                providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil,
                note: "extract via \(Self.docxTechnique)")
            Self.settleFetchStateIfPending(store: store, sourceID: sourceID)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        } catch {
            DebugLog.store("QueueFormatRoute.persistDocx failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
    }

    /// Persists one source refresh: a new content version with the fresh
    /// bytes, detection hints, and the provider's provenance — the write the
    /// app model's inline refresh performed.
    public static func persistRefresh(
        store: GRDBWikiStore,
        sourceID: SourceID,
        outcome: SourceRefreshResolution.Outcome
    ) throws -> QueueExtractionOutputReference? {
        do {
            let version = try store.appendContentVersion(
                sourceID: sourceID,
                data: outcome.data,
                detectionHints: outcome.detectionHints,
                provenance: outcome.provenance)
            return QueueExtractionOutputReference(versionID: version.id.rawValue)
        } catch {
            DebugLog.store("QueueFormatRoute.persistRefresh failed (source=\(sourceID.rawValue)): \(error)")
            throw error
        }
    }

    /// Settles a `formatJobPending` marker after a finished conversion.
    /// Deliberately non-fatal: the startup recovery scan is the backstop
    /// that settles a stale marker (parity with the bytes arm's settle).
    private static func settleFetchStateIfPending(store: GRDBWikiStore, sourceID: SourceID) {
        do {
            if try store.fetchState(sourceID: sourceID) == .formatJobPending {
                try store.markFetchComplete(sourceID: sourceID)
            }
        } catch {
            DebugLog.store("QueueFormatRoute: fetch-state settle skipped (source=\(sourceID.rawValue)): \(error)")
        }
    }
}
