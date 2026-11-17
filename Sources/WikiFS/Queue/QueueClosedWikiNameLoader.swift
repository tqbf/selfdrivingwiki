import Foundation
import WikiCtlCore
import WikiFSCore

/// Display-name resolution for a CLOSED wiki's queue targets — DAEMON-ONLY
/// (plans/daemon-only-access.md P5: the read-only pool left app composition,
/// so this loader reads through the daemon's store family, never a database
/// file).
///
/// The queue workspace resolves a job's target names through the live
/// session index first and the payload's enqueue-time recorded names second;
/// legacy jobs have neither when their wiki's window is closed. The daemon
/// answers each target's `getPage`/`getSource` over the shared store
/// transport, bound to that job's wiki. A daemon-down load THROWS — the
/// caller (``QueueActivityTracker``) marks the wiki unavailable and the rows
/// fall through to the recorded name or the deletion fallback text, the same
/// degradation the local reader had.
///
/// Bounded by construction: exactly the payload's target IDs are fetched
/// (one `getPage`/`getSource` per ID), never a whole-wiki listing. An ID the
/// wiki no longer contains (`WikiStoreError.notFound`) is an expected miss —
/// the ID is skipped. The `databaseURL` parameter stays in the seam
/// signature (the tracker's per-wiki planning passes it) but is UNUSED here:
/// the daemon owns the file and this reader never opens it.
enum QueueClosedWikiNameLoader {
    /// The injectable read seam behind
    /// `QueueActivityTracker.refreshClosedWikiNames`.
    typealias Load = @Sendable (
        _ wikiID: WikiID,
        _ pageIDs: [PageID],
        _ sourceIDs: [SourceID],
        _ databaseURL: URL
    ) async throws -> QueueTargetNameIndex

    /// The production reader factory: one `RemoteWikiStore` per load, bound
    /// to the app's shared store transport and the job's wiki id. The wiki
    /// id is now LOAD-BEARING (it scopes the daemon's wire operations); the
    /// database URL is ignored.
    static func daemonLoader(
        makeRemoteStore: @escaping @Sendable (WikiID) -> any WikiStore
    ) -> Load {
        return { wikiID, pageIDs, sourceIDs, _ in
            let store = makeRemoteStore(wikiID)
            var index = QueueTargetNameIndex()
            for id in pageIDs {
                do {
                    let page = try await store.getPage(id: id)
                    index.recordPage(page.id, title: page.title)
                } catch WikiStoreError.notFound {
                    // Expected miss: the page is gone from the wiki.
                    continue
                }
            }
            // One daemon-served catalog read (the store family has no
            // per-ID source summary op); the ID set bounds what gets
            // recorded, never the listing size.
            let sourceCatalog = try await store.listSources()
            let sourceByID = Dictionary(
                sourceCatalog.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a })
            for id in sourceIDs {
                if let source = sourceByID[id] {
                    index.recordSource(source.id, name: source.effectiveName)
                }
            }
            return index
        }
    }
}
