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
    @discardableResult
    public static func reconcileAll(in store: WikiStore) throws -> Int {
        let summaries = try store.listPages(sortBy: .lastUpdated)
        for summary in summaries {
            let page = try store.getPage(id: summary.id)
            try store.replaceLinks(
                from: page.id,
                parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
        }
        return summaries.count
    }
}
