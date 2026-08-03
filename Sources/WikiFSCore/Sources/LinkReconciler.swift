import Foundation

/// Startup self-heal for the wiki-link graph (`page_links` / `source_links`).
///
/// Links resolve at SAVE time (`PageUpsert` → `replaceLinks`), so rows written
/// before a resolution improvement (the v18 lookup-driven resolver, the lenient
/// source-name matching) — or before their target page/source existed — stay
/// stale until each page happens to be edited again. This pass re-parses every
/// page and rewrites its links under today's resolution rules. It NEVER
/// touches page bodies; only the derived link tables change. Idempotent — a
/// consistent graph is rewritten to itself.
///
/// Pure orchestration over the `WikiStore` protocol (same pattern as
/// `PageUpsert`), so the app model, tests, and `wikictl` can all run it.
/// Cost is one parse + resolve per page, on the caller's (main) thread —
/// SQLite is never touched off-main (`docs/skills/sqlite-concurrency`).
public enum LinkReconciler {

    /// Re-resolve every page's outgoing links. Returns the number of pages
    /// processed (not the number changed — `replaceLinks` rewrites
    /// unconditionally).
    ///
    /// Cooperative: yields control (`Task.yield()`) before the first page and
    /// every `batchSize` pages so the launch's first paint isn't blocked and the
    /// main actor can service UI events between batches. This was the launch
    /// beachball on large wikis — the loop ran synchronously at first paint
    /// (issue #165). Marked `@MainActor` so all `store` access stays on the main
    /// actor (the SQLite single-threaded invariant; only the yields suspend).
    @discardableResult
    public static func reconcileAll(in store: WikiStore, batchSize: Int = 16) async throws -> Int {
        let summaries = try store.listPages(sortBy: .lastUpdated)
        // Yield up front so the window can paint before the first page is read.
        await Task.yield()
        for (index, summary) in summaries.enumerated() {
            let page = try store.getPage(id: summary.id)
            try store.replaceLinks(
                from: page.id,
                parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            if (index + 1) % batchSize == 0 {
                await Task.yield()
            }
        }
        return summaries.count
    }
}
