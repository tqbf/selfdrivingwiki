import Foundation
import WikiFSCore
import WikiFSEngine

/// Shared enqueue helper for ingestion. Both `ContentView` (single-source
/// ingest) and `SourcesContainerView` (batch ingest) call this to route
/// work through the queue engine. For PDFs without existing extracted
/// markdown, enqueues extraction first, waits for it, then enqueues the
/// ingestion item. For non-PDFs or PDFs with existing markdown, enqueues
/// ingestion directly.
@MainActor
func enqueueIngestion(
    sourceIDs: [PageID],
    store: WikiStoreModel,
    wikiID: String,
    queueEngine: QueueEngine
) async {
    guard !sourceIDs.isEmpty else { return }

    var ingestionSourceIDs: [PageID] = []

    for sourceID in sourceIDs {
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
