import Foundation
import WikiFSCore

/// Shared daemon-side helper: build the `WIKI_STATE.md` content from a
/// `GRDBWikiStore`. Used by both `DaemonQueueIngestionProvider` (ingestion,
/// lint, page-lint) and `LauncherChatAgentRuntime` (chat session start) so the
/// agent sees the same wiki-state regardless of which daemon path drives it.
enum DaemonWikiState {
    /// Build the state-markdown string from the store's current snapshot.
    /// The committed editorial strategy is captured with the rest of the state
    /// at execution-request construction; `nil` (the Default strategy) captures
    /// as absence, so a Default wiki renders byte-identically to before
    /// strategies existed. A strategy READ failure throws
    /// `WikiStateSnapshotError.strategyReadFailed` instead: callers must fail
    /// visibly and build no request, never launch a run that silently invented
    /// the Default instructions. Warm chat follow-ups do not pass through
    /// here — `LauncherChatAgentRuntime` captures the strategy per turn
    /// instead (and throws on read failure the same way).
    static func stateMarkdown(from store: GRDBWikiStore) throws -> String {
        let titles = (DebugLog.trying("listPages", operation: { try store.listPages(sortBy: .lastUpdated) })) ?? []
        let indexBody = (DebugLog.trying("getWikiIndex", operation: { try store.getWikiIndex() }))?.body ?? WikiIndex.defaultBody
        let logEntries = (DebugLog.trying("recentLogEntries", operation: { try store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries) })) ?? []
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        let bookmarks = (DebugLog.trying("listBookmarkNodes", operation: { try store.listBookmarkNodes() })) ?? []
        // Unlike the inventory reads above, a failure here THROWS:
        // authoritative editorial instructions cannot be invented from a
        // store error, so a failed read fails the request instead of
        // degrading to the Default strategy.
        let strategy: WikiStrategy?
        do {
            strategy = try store.getWikiStrategy()
        } catch {
            throw WikiStateSnapshotError.strategyReadFailed("\(error)")
        }
        let snapshot = WikiStateSnapshot.make(
            allTitles: titles.map(\.title),
            indexBody: indexBody,
            logLines: logLines,
            bookmarkNodes: bookmarks,
            strategy: strategy)
        return snapshot.renderStateFile()
    }
}
