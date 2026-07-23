import Foundation
import WikiFSCore

/// Shared daemon-side helper: build the `WIKI_STATE.md` content from a
/// `GRDBWikiStore`. Used by both `DaemonQueueIngestionProvider` (ingestion)
/// and `DaemonChatHost` (chat) so the agent sees the same wiki-state
/// regardless of which daemon path drives it.
enum DaemonWikiState {
    /// Build the state-markdown string from the store's current snapshot.
    static func stateMarkdown(from store: GRDBWikiStore) -> String {
        let titles = (try? store.listPages(sortBy: .lastUpdated)) ?? []
        let indexBody = (try? store.getWikiIndex())?.body ?? WikiIndex.defaultBody
        let logEntries = (try? store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries)) ?? []
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        let bookmarks = (try? store.listBookmarkNodes()) ?? []
        let snapshot = WikiStateSnapshot.make(
            allTitles: titles.map(\.title),
            indexBody: indexBody,
            logLines: logLines,
            bookmarkNodes: bookmarks)
        return snapshot.renderStateFile()
    }
}
