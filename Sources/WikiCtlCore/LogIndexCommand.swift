import Foundation
import WikiFSCore

/// The `wikictl log append` and `wikictl index set` subcommands (Phase B),
/// executed against an already-opened `WikiStore`. Split from process concerns
/// (arg parsing, stdin, the Darwin post, opening the DB) so the command surface
/// is unit-testable against a temp DB, exactly like `PageCommand`.
public enum LogIndexCommand {

    public enum Action: Equatable {
        /// Append one dated row to the chronological log. `source` (set only on an
        /// ingest) is the ingested-file id to additionally stamp as ingested.
        case logAppend(kind: LogEntry.Kind, title: String, note: String?, source: PageID?)
        /// Replace the singleton wiki-index body wholesale (UPSERT, version + 1).
        /// When `workspace` is set (Phase 7), stage into the workspace instead of
        /// writing to main — the caller provides the current main body as the
        /// three-way-merge base.
        case indexSet(body: String, workspace: String? = nil)
    }

    /// Run one action against `store`. Both actions COMMIT (the caller posts the
    /// change notification). `logAppend` echoes the new entry's id; `indexSet`
    /// produces no output (the body is wholesale-replaced).
    public static func run(_ action: Action, in store: WikiStore) throws -> PageCommand.Result {
        switch action {
        case .logAppend(let kind, let title, let note, let source):
            let entry = try store.appendLog(kind: kind, title: title, note: note)
            // On a successful ingest the agent passes --source <file-id>; stamp it
            // so the UI shows the file as Ingested without guessing from the title.
            if let source { try store.markSourceIngested(id: source) }
            return PageCommand.Result(output: entry.id.rawValue, didCommit: true)
        case .indexSet(let body, let workspace):
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PageCommand.Failure.message(
                    "refusing to set an empty index body — nothing was delivered. "
                    + "Under the sandbox a piped or heredoc'd body can arrive empty; "
                    + "write the body to a file in your cwd and pass --body-file <path>."
                )
            }
            if let workspace {
                // Phase 7: stage index changes into the workspace. The base
                // version is the current main wiki_index body (captured now as
                // the three-way-merge base; on first touch it's the snapshot
                // at staging time, on subsequent touches the workspace keeps
                // the original base via the UPDATE).
                let baseVersion = (try? store.getWikiIndex())?.body ?? WikiIndex.defaultBody
                try store.setWorkspaceIndexBody(
                    workspaceID: workspace, indexBody: body, indexBaseVersion: baseVersion)
                return PageCommand.Result(output: "", didCommit: true)
            }
            try store.updateWikiIndex(body: body)
            return PageCommand.Result(output: "", didCommit: true)
        }
    }
}
