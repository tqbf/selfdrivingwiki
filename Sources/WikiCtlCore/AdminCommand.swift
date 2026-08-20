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
        case repairMIME(dryRun: Bool, json: Bool)
    }

    /// Run one action against `store`. Returns a `SourceCommand.Result` so it
    /// threads through `wikictl`'s shared `execute()` dispatch: a `.text`
    /// summary, with `didCommit` true ONLY when a vacuum actually deleted rows
    /// (a dry run commits nothing, so it never wakes the app's change bridge —
    /// and since GC changes no projected `ResourceKind`, an applied vacuum has
    /// nothing for the model to refresh either).
    public static func run(_ action: Action, in store: GRDBWikiStore) throws -> SourceCommand.Result {
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
        case .repairMIME(let dryRun, let json):
            let report = try store.repairMIME(dryRun: dryRun)
            return SourceCommand.Result(
                payload: .text(try Self.format(report, json: json)),
                didCommit: report.updatedCount > 0)
        }
    }

    private static func format(_ report: MIMERepairReport, json: Bool) throws -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(report), as: UTF8.self)
        }
        let mode = report.applied ? "apply" : "dry-run; no data changed"
        var lines = [
            "MIME repair \(mode)",
            "scanned=\(report.scannedCount) repairable=\(report.repairableCount) updated=\(report.updatedCount) skipped-byteless=\(report.skippedBytelessCount) skipped-inconclusive=\(report.skippedInconclusiveCount)",
        ]
        for item in report.items {
            let confidence = item.detection.confidence.map { String($0.rawValue) } ?? "none"
            let evidence = item.detection.evidence.map { $0.origin.rawValue }.joined(separator: ",")
            let conflicts = item.detection.conflicts.map { $0.conflictingEvidence.origin.rawValue }.joined(separator: ",")
            let chosenMIME = item.newMIMEType ?? "inconclusive"
            lines.append(
                "\(item.sourceID.rawValue)\t\(item.nullState.rawValue)\t\(chosenMIME)\tconfidence=\(confidence)\tevidence=\(evidence)\tconflicts=\(conflicts)")
        }
        return lines.joined(separator: "\n")
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
