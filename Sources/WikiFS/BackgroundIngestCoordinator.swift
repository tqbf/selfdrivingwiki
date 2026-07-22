import Foundation
import WikiFSCore
import WikiFSEngine

/// Continuously scans for un-ingested sources and enqueues them automatically.
/// Phase 1 of the background ingest feature (issue #813).
@MainActor
@Observable
final class BackgroundIngestCoordinator {
    private let sessionManager: SessionManager
    private let queueEngine: any QueueEngineClient
    private let quotaCoordinator: QuotaFallbackCoordinator
    private var scanTask: Task<Void, Never>?

    private var recentlyFailedIDs: Set<PageID> = []
    private let maxBackoffCycles = 3
    private var backoffCount: [PageID: Int] = [:]

    let scanInterval: TimeInterval = 60

    init(sessionManager: SessionManager, queueEngine: any QueueEngineClient, quotaCoordinator: QuotaFallbackCoordinator) {
        self.sessionManager = sessionManager
        self.queueEngine = queueEngine
        self.quotaCoordinator = quotaCoordinator
    }
    
    func start() {
        guard scanTask == nil else { return }
        DebugLog.ingest("BackgroundIngestCoordinator: starting")
        
        scanTask = Task {
            while !Task.isCancelled {
                await scanAllWikis()
                try? await Task.sleep(for: .seconds(scanInterval))
            }
            DebugLog.ingest("BackgroundIngestCoordinator: stopped")
        }
    }
    
    func stop() {
        scanTask?.cancel()
        scanTask = nil
        DebugLog.ingest("BackgroundIngestCoordinator: stop requested")
    }
    
    private func scanAllWikis() async {
        let sessions = sessionManager.allSessions
        
        for session in sessions {
            guard !Task.isCancelled else { break }
            await scanWiki(session: session)
        }
    }

    // MARK: - Per-source ingestion decision (testable seam, §11-C2)

    /// The result of evaluating one un-ingested source against the
    /// auto-ingest gates (the registry's markdown-path check, then the
    /// byteless guard). Used by `scanWiki` to route each source and by
    /// tests to assert per-source behavior without standing up a scan task.
    ///
    /// Marked `internal` so `@testable import WikiFS` can reach it from
    /// `Tests/WikiFSAppTests/BackgroundIngestCoordinatorTests.swift`. The
    /// type itself is `Sendable` so it can cross actor boundaries when
    /// needed (the decision is computed on `@MainActor` since `WikiStoreModel`
    /// is main-actor-isolated).
    enum IngestionDecision: Sendable, Equatable {
        /// Enqueue this source for ingestion — passes both gates.
        case enqueue
        /// The content TYPE has no markdown path (PNG → `.image`, XML →
        /// `.binary`, etc.). Pin backoff so the source is not re-resolved
        /// every scan cycle.
        case skipNonIngestible(kind: ContentKind)
        /// The kind HAS a markdown path (e.g. `.youtubeTranscript`) but
        /// there's no content to stage right now (byteless + no transcript
        /// arrived yet). Stays skipped until something changes (e.g. the
        /// transcript arrives, marking `hasProcessedMarkdown == true`).
        case skipByteless
    }

    /// Per-source decision: given a source that has ALREADY passed the
    /// `isSourceIngested` pre-filter and the backoff guard, should it be
    /// enqueued for auto-ingestion?
    ///
    /// Two gates, in order:
    /// 1. **Registry gate (`shouldAutoIngest`)** — the content-type fix
    ///    for the PR1 bug. A PNG (`image/png` → `.image`) and an XML
    ///    (`application/xml` → `.binary`) return `.skipNonIngestible` here,
    ///    BEFORE the byte gate even runs. Both have bytes, so the previous
    ///    byte-only predicate let them through — wasted agent runs.
    /// 2. **Byteless guard (`canIngest`)** — defense-in-depth kept from
    ///    the original code. A `.youtubeTranscript` source whose transcript
    ///    never arrived has neither bytes nor markdown; `.skipByteless`
    ///    halts enqueue until the transcript lands.
    /// Provider-aware (uses `ContentKind.resolve(mimeType:provider:ext:)`)
    /// so byteless `.youtube` / `.podcast` sources WITH transcripts classify
    /// as `.youtubeTranscript` / `.podcastTranscript` and pass — their
    /// synthetic `video/youtube` MIME alone would classify as `.binary`
    /// (the §11-C1 regression). Passes `source.ext` for the legacy-mime
    /// fallback (§11-C4/C9).
    ///
    /// `@MainActor` because `WikiStoreModel.sourceOrigin(for:)` /
    /// `canIngest(_:)` are main-actor-isolated. Marked `internal` + `static`
    /// so tests can call `BackgroundIngestCoordinator.ingestionDecision(...)`
    /// directly without instantiating a full coordinator (which would
    /// require a `SessionManager` + `QueueEngineClient`).
    @MainActor
    internal static func ingestionDecision(
        for source: SourceSummary,
        store: WikiStoreModel
    ) -> IngestionDecision {
        // 1. Registry gate — PNG/XML/etc. are filtered HERE, before the
        //    byte guard runs.
        let origin = store.sourceOrigin(for: source.id)
        let kind = ContentKind.resolve(
            mimeType: source.mimeType,
            provider: origin?.provider,
            ext: source.ext)
        if !kind.capabilities.shouldAutoIngest {
            return .skipNonIngestible(kind: kind)
        }
        // 2. Byteless guard — a markdown-path kind with no content to stage
        //    (e.g. YouTube before the transcript arrives) stays skipped.
        if !store.canIngest(source) {
            return .skipByteless
        }
        return .enqueue
    }

    /// Convenience batch filter: returns the source IDs to enqueue after
    /// applying both gates to every source. Used by `scanWiki` indirectly
    /// (the loop consults `ingestionDecision` per-source so it can also
    /// update `backoffCount` per-skip-reason) and by tests for compact
    /// batch assertions.
    ///
    /// Pure with respect to external side effects — no enqueue, no backoff
    /// mutation. Callers that need backoff bookkeeping should iterate
    /// `ingestionDecision` themselves; this helper is for "what would be
    /// enqueued" questions.
    @MainActor
    internal static func filterIngestibleSources(
        _ sources: [SourceSummary],
        store: WikiStoreModel
    ) -> [PageID] {
        sources.compactMap { source in
            if ingestionDecision(for: source, store: store) == .enqueue {
                return source.id
            }
            return nil
        }
    }

    // MARK: - Per-wiki scan

    
    private func scanWiki(session: WikiSession) async {
        let wikiID = session.wikiID
        let store = session.store
        let sources = store.sources
        
        DebugLog.ingest("BackgroundIngestCoordinator: starting scan for wiki \(wikiID)")
        
        var foundCount = 0
        var enqueuedCount = 0
        var skippedCount = 0
        var backoffSkippedCount = 0
        var bytelessSkippedCount = 0
        var nonIngestibleSkippedCount = 0
        var sourceIDsToEnqueue: [PageID] = []
        
        for source in sources {
            guard !Task.isCancelled else { break }
            
            if store.isSourceIngested(source) {
                continue
            }
            
            foundCount += 1
            
            if let cycles = backoffCount[source.id], cycles < maxBackoffCycles {
                backoffCount[source.id, default: 0] += 1
                backoffSkippedCount += 1
                DebugLog.ingest("BackgroundIngestCoordinator: skipping failed source \(source.id.rawValue) (backoff cycle \(cycles)/\(maxBackoffCycles))")
                continue
            }
            
            // Per-source decision: content-type registry gate (PNG/XML/etc.
            // have no markdown path) THEN byteless guard (YouTube without
            // transcript). Extracted as `ingestionDecision(for:store:)` so
            // tests can exercise the registry-keyed filter directly without
            // standing up a scan task (§11-C2).
            switch Self.ingestionDecision(for: source, store: store) {
            case .enqueue:
                sourceIDsToEnqueue.append(source.id)
            case .skipNonIngestible(let kind):
                nonIngestibleSkippedCount += 1
                DebugLog.ingest("BackgroundIngestCoordinator: skipping \(source.id.rawValue) — \(kind) has no markdown path")
                backoffCount[source.id] = maxBackoffCycles
            case .skipByteless:
                bytelessSkippedCount += 1
                DebugLog.ingest("BackgroundIngestCoordinator: skipping byteless source \(source.id.rawValue) (no content to ingest)")
                backoffCount[source.id] = maxBackoffCycles
            }
        }
        
        if !sourceIDsToEnqueue.isEmpty && !Task.isCancelled {
            for sourceID in sourceIDsToEnqueue {
                guard !Task.isCancelled else { break }
                
                await enqueueIngestion(
                    sourceIDs: [sourceID],
                    store: store,
                    wikiID: wikiID,
                    queueEngine: queueEngine
                )
                enqueuedCount += 1
                DebugLog.ingest("BackgroundIngestCoordinator: enqueued \(sourceID.rawValue) for wiki \(wikiID)")
                backoffCount.removeValue(forKey: sourceID)
            }
        }
        
        skippedCount = backoffSkippedCount + bytelessSkippedCount + nonIngestibleSkippedCount
        DebugLog.ingest("BackgroundIngestCoordinator: scan complete for wiki \(wikiID) - found \(foundCount), enqueued \(enqueuedCount), skipped \(skippedCount) (backoff \(backoffSkippedCount), byteless \(bytelessSkippedCount), non-ingestible \(nonIngestibleSkippedCount))")
        
        decayBackoffCounts()
    }
    
    private func decayBackoffCounts() {
        for sourceID in backoffCount.keys {
            if backoffCount[sourceID, default: 0] > 0 {
                backoffCount[sourceID, default: 0] -= 1
            }
        }
        backoffCount = backoffCount.filter { $0.value > 0 }
    }
    
    nonisolated deinit {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}