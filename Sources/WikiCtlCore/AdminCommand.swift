import Foundation
import WikiFSCore

/// The `wikictl admin …` subcommand family — maintenance operations that don't
/// fit the read/write page/source/log verbs. Split from process concerns (arg
/// parsing, opening the DB, the Darwin post) so the command surface is
/// unit-testable against a temp DB, exactly like `PageCommand` /
/// `LogIndexCommand`.
public enum AdminCommand {

    public enum Action: Equatable {
        /// Sweep orphaned blobs (graph-model §13 / issue #253). `dryRun == true`
        /// (the CLI default) reports reclaimable storage WITHOUT deleting;
        /// `dryRun == false` (`--apply`) deletes them. `json` selects
        /// machine-readable output.
        case vacuumBlobs(dryRun: Bool, json: Bool)
    }

    /// Run one action against `store`. Returns a `SourceCommand.Result` so it
    /// threads through `wikictl`'s shared `execute()` dispatch: a `.text`
    /// summary, with `didCommit` true ONLY when a vacuum actually deleted rows
    /// (a dry run commits nothing, so it never wakes the app's change bridge —
    /// and since blob GC changes no projected `ResourceKind`, an applied vacuum
    /// has nothing for the model to refresh either).
    public static func run(_ action: Action, in store: SQLiteWikiStore) throws -> SourceCommand.Result {
        switch action {
        case .vacuumBlobs(let dryRun, let json):
            let report = try store.vacuumBlobs(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(Self.format(report, json: json)), didCommit: report.applied)
        }
    }

    private static func format(_ report: BlobVacuumReport, json: Bool) -> String {
        if json {
            return """
            {"orphanCount":\(report.orphanCount),"bytesReclaimed":\(report.bytesReclaimed),"applied":\(report.applied)}
            """
        }
        let verb = report.applied ? "reclaimed" : "reclaimable"
        let hint = report.applied ? "" : " (dry-run; pass --apply to delete)"
        return "\(report.orphanCount) orphan blob(s), \(report.bytesReclaimed) byte(s) \(verb)\(hint)"
    }
}
