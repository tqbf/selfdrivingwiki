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

        /// Sweep orphaned activities (graph-model §13 / issue #257). Same dry-run
        /// / `--apply` / `--json` semantics as `vacuumBlobs`.
        case vacuumActivities(dryRun: Bool, json: Bool)

        /// Sweep orphaned page versions (Phase 4 — multi-writer hardening):
        /// versions not reachable from any `page-content` ref target or
        /// referenced by any workspace. Same dry-run / `--apply` / `--json`
        /// semantics as `vacuumBlobs`.
        case vacuumPageVersions(dryRun: Bool, json: Bool)

        /// Sweep orphaned blobs, activities, AND page versions in one pass.
        /// The common case — users don't usually care about the distinction.
        case vacuumAll(dryRun: Bool, json: Bool)
    }

    /// Run one action against `store`. Returns a `SourceCommand.Result` so it
    /// threads through `wikictl`'s shared `execute()` dispatch: a `.text`
    /// summary, with `didCommit` true ONLY when a vacuum actually deleted rows
    /// (a dry run commits nothing, so it never wakes the app's change bridge —
    /// and since GC changes no projected `ResourceKind`, an applied vacuum has
    /// nothing for the model to refresh either).
    public static func run(_ action: Action, in store: SQLiteWikiStore) throws -> SourceCommand.Result {
        switch action {
        case .vacuumBlobs(let dryRun, let json):
            let report = try store.vacuumBlobs(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(Self.format(report, json: json)), didCommit: report.applied)
        case .vacuumActivities(let dryRun, let json):
            let report = try store.vacuumActivities(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(Self.format(report, json: json)), didCommit: report.applied)
        case .vacuumPageVersions(let dryRun, let json):
            let report = try store.vacuumPageVersions(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(Self.format(report, json: json)), didCommit: report.applied)
        case .vacuumAll(let dryRun, let json):
            let blobReport = try store.vacuumBlobs(dryRun: dryRun)
            let activityReport = try store.vacuumActivities(dryRun: dryRun)
            let pageVersionReport = try store.vacuumPageVersions(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(Self.formatAll(
                    blobs: blobReport, activities: activityReport,
                    pageVersions: pageVersionReport, json: json)),
                didCommit: blobReport.applied || activityReport.applied || pageVersionReport.applied)
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

    private static func format(_ report: ActivityVacuumReport, json: Bool) -> String {
        if json {
            return """
            {"orphanCount":\(report.orphanCount),"applied":\(report.applied)}
            """
        }
        let verb = report.applied ? "reclaimed" : "reclaimable"
        let hint = report.applied ? "" : " (dry-run; pass --apply to delete)"
        return "\(report.orphanCount) orphaned activit\(report.orphanCount == 1 ? "y" : "ies") \(verb)\(hint)"
    }

    private static func format(_ report: PageVersionVacuumReport, json: Bool) -> String {
        if json {
            return """
            {"deletedCount":\(report.deletedCount),"applied":\(report.applied)}
            """
        }
        let verb = report.applied ? "reclaimed" : "reclaimable"
        let hint = report.applied ? "" : " (dry-run; pass --apply to delete)"
        return "\(report.deletedCount) orphaned page version\(report.deletedCount == 1 ? "" : "s") \(verb)\(hint)"
    }

    private static func formatAll(blobs: BlobVacuumReport, activities: ActivityVacuumReport, pageVersions: PageVersionVacuumReport, json: Bool) -> String {
        if json {
            return """
            {"blobs":{"orphanCount":\(blobs.orphanCount),"bytesReclaimed":\(blobs.bytesReclaimed),"applied":\(blobs.applied)},"activities":{"orphanCount":\(activities.orphanCount),"applied":\(activities.applied)},"pageVersions":{"deletedCount":\(pageVersions.deletedCount),"applied":\(pageVersions.applied)}}
            """
        }
        let lines = [format(blobs, json: false), format(activities, json: false), format(pageVersions, json: false)]
        return lines.joined(separator: "\n")
    }
}
