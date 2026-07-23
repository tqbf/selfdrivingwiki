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
/// **Markdown/content gate (chokepoint):** after any extraction step, a
/// source with neither processed markdown nor raw bytes is dropped
/// (`canIngest` check). This is the single enforcement of "don't ingest
/// sources without content" — every entry point funnels through here, so a
/// byteless source (e.g. a YouTube video with no transcript) can never be
/// enqueued no matter which UI path originated the request. The UI predicate
/// (`WikiStoreModel.canIngest`) mirrors this for affordance gating.
///
/// **Content-type gate (PR2 §5.2 / §11-C1):** the chokepoint ALSO consults
/// `WikiStoreModel.shouldAutoIngest(_:)` — the registry-backed
/// "does this content TYPE have any markdown path?" predicate added in PR1.
/// A byte-bearing PNG or XML source (the bug class) passes the byte gate
/// but fails this second gate, so it's dropped here rather than enqueued
/// for a wasted agent run. **Provider-aware** (PR1's wrapper uses
/// `ContentKind.resolve(mimeType:provider:ext:)`, not `fromMIME` alone) so
/// a byteless `.youtube` source WITH a transcript (whose synthetic
/// `video/youtube` mime alone would classify as `.binary`) classifies as
/// `.youtubeTranscript` → `shouldAutoIngest == true` and passes — locking
/// the §11-C1 regression guard.
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
    queueEngine: any QueueEngineClient
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
        guard let source = store.sources.first(where: { $0.id == sourceID }) else {
            DebugLog.ingest("enqueueIngestion: unknown source \(sourceID.rawValue) — skipped")
            continue
        }

        // PDF without extracted markdown → enqueue extraction, wait for it,
        // then include in ingestion batch (extraction produces the markdown).
        // Stays `MimeType.isPDF` rather than `extractionPath == .pdfBackend`
        // because the extraction queue is PDF-only (HTML extraction routes
        // through the inline `runHtmlExtraction` path, not the queue engine —
        // see `SourceDetailView.runExtraction` / `runHtmlExtraction` split).
        // Equivalent under the registry today (`.pdf` kind has
        // `extractionPath == .pdfBackend` and only `application/pdf` MIME
        // resolves to `.pdf`), kept as a direct MIME check because the
        // condition is specifically "PDF extraction queue knows how to handle
        // this" — the content-type decision is below.
        if MimeType.isPDF(source.mimeType),
           store.processedMarkdownHead(for: source) == nil {
            let request = QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))
            do {
                let itemID = try await queueEngine.enqueue(request)
                let result = await queueEngine.waitForCompletion(of: itemID)
                if case .failure(let error) = result {
                    DebugLog.ingest("enqueueIngestion: extraction waitForCompletion failed for \(sourceID.rawValue): \(error.localizedDescription)")
                }
            } catch {
                DebugLog.ingest("enqueueIngestion: extraction failed for \(sourceID.rawValue) — \(error.localizedDescription)")
            }
        }

        // ── Chokepoint ───────────────────────────────────────────────────
        // Two gates, in order:
        // 1. **Byte gate** (`canIngest`): true when the source has processed
        //    markdown (a transcript, extracted PDF) **or** raw bytes
        //    (`byteSize > 0`) the staging path reads directly. A byteless
        //    source with no processed markdown — e.g. a YouTube video whose
        //    transcript never arrived — has neither, so it is dropped here.
        //    Kept from PR1; defense-in-depth: even if the content-type gate
        //    below somehow let a byteless source through (it doesn't, but
        //    future registry edits could), nothing is enqueued without
        //    content. Every UI entry point (detail view, list context menu,
        //    batch ingest) funnels through here, so the rule is *guaranteed*
        //    regardless of origin.
        // 2. **Content-type gate** (PR2 §5.2 / §11-C1, `shouldAutoIngest`):
        //    the registry's markdown-path predicate. A byte-bearing PNG
        //    (`image/png` → `.image`) or XML (`application/xml` → `.binary`)
        //    passes gate #1 (it has bytes) but fails gate #2 (no markdown
        //    path) — dropped rather than enqueued for wasted agent runs.
        //    Provider-aware via PR1's wrapper (`ContentKind.resolve(mime:
        //    provider: ext:)` — NOT `fromMIME` alone) so a byteless YouTube
        //    source WITH a transcript classifies as `.youtubeTranscript` and
        //    passes; fromMIME alone would classify its synthetic
        //    `video/youtube` mime as `.binary` and incorrectly drop it (the
        //    §11-C1 regression the original §5.2 caught).
        guard store.canIngest(source) else {
            DebugLog.ingest("enqueueIngestion: dropped \(sourceID.rawValue) — no markdown or bytes to ingest")
            continue
        }
        guard store.shouldAutoIngest(source) else {
            DebugLog.ingest("enqueueIngestion: dropped \(sourceID.rawValue) — content type has no markdown path")
            continue
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
