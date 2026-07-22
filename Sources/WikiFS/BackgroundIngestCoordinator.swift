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
            
            if !store.canIngest(source) {
                bytelessSkippedCount += 1
                DebugLog.ingest("BackgroundIngestCoordinator: skipping byteless source \(source.id.rawValue) (no content to ingest)")
                backoffCount[source.id] = maxBackoffCycles
                continue
            }
            
            sourceIDsToEnqueue.append(source.id)
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
        
        skippedCount = backoffSkippedCount + bytelessSkippedCount
        DebugLog.ingest("BackgroundIngestCoordinator: scan complete for wiki \(wikiID) - found \(foundCount), enqueued \(enqueuedCount), skipped \(skippedCount)")
        
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