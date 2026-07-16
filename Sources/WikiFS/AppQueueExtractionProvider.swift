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

/// A mutable, `@MainActor`-isolated box for a `FileProviderSpike` reference.
/// Used by `AppQueueIngestionProvider` to access the file provider without
/// needing it at construction time (the app's `@State fileProvider` is
/// initialized via its property initializer, not in `init()`).
@MainActor
final class FileProviderBox: @unchecked Sendable {
    var provider: FileProviderSpike?
}

@MainActor
final class SessionLookupBox: @unchecked Sendable {
    /// Returns the live `WikiStoreModel` for a wikiID, or nil if no session is
    /// open. `@MainActor` + `@Sendable` so it can be called from a
    /// `@MainActor`-isolated provider.
    private var lookup: @MainActor @Sendable (String) -> WikiStoreModel?

    /// Returns the live `WikiSession` for a wikiID, or nil if no session is
    /// open. Used by the ingestion provider to access the session's launcher.
    private var sessionLookup: @MainActor @Sendable (String) -> WikiSession?

    init() {
        // No sessions exist yet — return nil. Replaced after SessionManager
        // construction.
        self.lookup = { _ in nil }
        self.sessionLookup = { _ in nil }
    }

    /// Synchronous resolution (caller must be on the main actor).
    func resolve(wikiID: String) -> WikiStoreModel? {
        lookup(wikiID)
    }

    /// Synchronous session resolution (caller must be on the main actor).
    func resolveSession(for wikiID: String) -> WikiSession? {
        sessionLookup(wikiID)
    }

    /// Wire the box to the real session manager (called after construction).
    func setLookup(_ lookup: @escaping @MainActor @Sendable (String) -> WikiStoreModel?) {
        self.lookup = lookup
    }

    /// Wire the session-lookup closure to the real session manager.
    func setSessionLookup(_ lookup: @escaping @MainActor @Sendable (String) -> WikiSession?) {
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
    private let extractionCoordinator: ExtractionCoordinator
    private let sessionBox: SessionLookupBox

    init(
        extractionCoordinator: ExtractionCoordinator,
        sessionBox: SessionLookupBox
    ) {
        self.extractionCoordinator = extractionCoordinator
        self.sessionBox = sessionBox
    }

    // MARK: - QueueExtractionProvider

    func resolveExtraction(
        wikiID: String,
        sourceID: PageID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: no session for wikiID=\(wikiID)")
            return nil
        }

        guard let source = store.sources.first(where: { $0.id == sourceID }),
              let bytes = store.sourceBytes(id: sourceID)
        else {
            DebugLog.extraction("AppQueueExtractionProvider: no source/bytes for \(sourceID.rawValue)")
            return nil
        }

        // Resolve the extractor. ExtractionCoordinator.current() re-reads
        // config each call so a Settings Save is picked up immediately.
        let extractor = extractionCoordinator.current()
        let cfg = extractionCoordinator.config

        return ExtractionResolution(
            extractor: extractor,
            pdfData: bytes,
            filename: source.filename,
            backend: cfg.backend,
            modelVersion: cfg.currentModelVersion
        )
    }

    func persistExtraction(
        wikiID: String,
        sourceID: PageID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?
    ) async throws {
        guard let store = sessionBox.resolve(wikiID: wikiID) else {
            DebugLog.extraction("AppQueueExtractionProvider: persistExtraction — no session for wikiID=\(wikiID)")
            return
        }
        store.seedPdfMarkdown(
            for: sourceID,
            content: markdown,
            backend: backend,
            modelVersion: modelVersion
        )
    }
}
