import Foundation
import WikiFSCore

/// Read-only display-name resolution for a CLOSED wiki's queue targets.
///
/// The queue workspace resolves a job's target names through the live
/// session index first and the payload's enqueue-time recorded names second;
/// legacy jobs have neither when their wiki's window is closed, so this
/// loader reads the titles straight from that wiki's database. The read goes
/// through `WikiReadService` — the same read-only-pool seam production
/// sessions use — so a closed wiki is touched only through one bounded,
/// query-only connection per load.
///
/// Bounded by construction: exactly the payload's target IDs are fetched
/// (one `getPage`/`getSource` per ID), never a whole-wiki listing. An ID the
/// database no longer contains (`WikiStoreError.notFound`) is an expected
/// miss — the ID is skipped so the row falls through to the recorded name
/// or, ultimately, the deletion fallback text. Any other error fails the
/// whole load; the caller logs it and marks the wiki unavailable.
enum QueueClosedWikiNameLoader {
    /// The injectable read seam behind
    /// `QueueActivityTracker.refreshClosedWikiNames`.
    ///
    /// `wikiID` is seam-only (review F6): the production reader opens
    /// `databaseURL` directly and never consults it. The parameter stays so
    /// the seam mirrors the caller's per-wiki planning — test spies and
    /// alternate readers can key their behavior (logs, per-wiki fakes) by
    /// wiki without threading an extra channel.
    typealias Load = @Sendable (
        _ wikiID: WikiID,
        _ pageIDs: [PageID],
        _ sourceIDs: [SourceID],
        _ databaseURL: URL
    ) async throws -> QueueTargetNameIndex

    /// Resolve `pageIDs`' titles and `sourceIDs`' effective names from the
    /// wiki database at `databaseURL`. Throws when the database cannot be
    /// opened or a non-miss read fails.
    ///
    /// `wikiID` is seam-only here (see ``Load``): the database URL fully
    /// determines the store this function reads.
    static func load(
        wikiID: WikiID,
        pageIDs: [PageID],
        sourceIDs: [SourceID],
        databaseURL: URL
    ) async throws -> QueueTargetNameIndex {
        let service = WikiReadService(databaseURL: databaseURL)
        do {
            let resolved = try await service.asyncRead { access in
                var pages: [(id: PageID, title: String)] = []
                var sources: [(id: SourceID, name: String)] = []
                for id in pageIDs {
                    do {
                        let page = try access.getPage(id: id)
                        pages.append((id: page.id, title: page.title))
                    } catch WikiStoreError.notFound {
                        // Expected miss: the page is gone from the database.
                        continue
                    }
                }
                for id in sourceIDs {
                    do {
                        let source = try access.getSource(id: id)
                        sources.append((id: source.id, name: source.effectiveName))
                    } catch WikiStoreError.notFound {
                        continue
                    }
                }
                return ResolvedNames(pages: pages, sources: sources)
            }
            await service.shutdown()
            var index = QueueTargetNameIndex()
            for entry in resolved.pages {
                index.recordPage(entry.id, title: entry.title)
            }
            for entry in resolved.sources {
                index.recordSource(entry.id, name: entry.name)
            }
            return index
        } catch {
            await service.shutdown()
            throw error
        }
    }

    /// The Sendable carrier across the `asyncRead` boundary (mutable locals
    /// cannot be captured by a `@Sendable` closure, so the reads collect
    /// plain arrays).
    private struct ResolvedNames: Sendable {
        var pages: [(id: PageID, title: String)]
        var sources: [(id: SourceID, name: String)]
    }
}
