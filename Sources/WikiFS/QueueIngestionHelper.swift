import Foundation
import WikiFSCore
import WikiFSEngine

/// Shared enqueue helper for ingestion. Both `ContentView` (single-source
/// ingest) and `SourcesContainerView` (batch ingest) call this to route
/// work through the queue engine. For PDFs without existing extracted
/// markdown, enqueues extraction first, waits for it, then enqueues the
/// ingestion item. For non-PDFs or PDFs with existing markdown, enqueues
/// ingestion directly.
///
/// **Deduplication:** before enqueuing, checks the engine's active items
/// (`.queued` or `.running`) for this wiki. Sources already active in either
/// the extraction or ingestion queue are skipped — a user tapping Ingest
/// multiple times on the same source won't create duplicate queue entries.
@MainActor
func enqueueIngestion(
    sourceIDs: [PageID],
    store: WikiStoreModel,
    wikiID: String,
    queueEngine: QueueEngine
) async {
    guard !sourceIDs.isEmpty else { return }

    // Deduplicate: collect sourceIDs already active (queued or running)
    // for this wiki in either queue, and skip them.
    let snapshot = await queueEngine.snapshot()
    let activeSourceIDs = Set(
        snapshot.activeItems
            .filter { $0.wikiID == wikiID }
            .flatMap { $0.payload.sourceIDs }
    )
    let newSourceIDs = sourceIDs.filter { !activeSourceIDs.contains($0) }

    let skipped = sourceIDs.count - newSourceIDs.count
    if skipped > 0 {
        DebugLog.ingest("enqueueIngestion: skipped \(skipped) source(s) already in queue")
    }
    guard !newSourceIDs.isEmpty else {
        DebugLog.ingest("enqueueIngestion: all source(s) already in queue — nothing to do")
        return
    }

    var ingestionSourceIDs: [PageID] = []

    for sourceID in newSourceIDs {
        // Check if this source needs extraction first.
        if let source = store.sources.first(where: { $0.id == sourceID }),
           source.mimeType == "application/pdf",
           store.processedMarkdownHead(for: source) == nil {
            // PDF without extracted markdown → enqueue extraction, wait
            // for it, then include in ingestion batch.
            let request = QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))
            do {
                let itemID = try await queueEngine.enqueue(request)
                _ = await queueEngine.waitForCompletion(of: itemID)
            } catch {
                DebugLog.ingest("enqueueIngestion: extraction failed for \(sourceID.rawValue) — \(error.localizedDescription)")
            }
        }
        ingestionSourceIDs.append(sourceID)
    }

    guard !ingestionSourceIDs.isEmpty else { return }

    do {
        let request = QueueItemRequest(
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: ingestionSourceIDs))
        _ = try await queueEngine.enqueue(request)
    } catch {
        DebugLog.ingest("enqueueIngestion: enqueue failed — \(error.localizedDescription)")
    }
}
