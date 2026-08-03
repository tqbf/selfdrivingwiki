import Foundation
import Testing

struct Issue1005DocumentationAuditTests {
    @Test func planIndexLinksIssue1005Plan() throws {
        let root = repositoryRoot()
        let index = try String(contentsOf: root.appendingPathComponent("PLAN.md"), encoding: .utf8)
        #expect(index.contains("[`plans/issue-1005-selected-item-metadata.md`](plans/issue-1005-selected-item-metadata.md)"))
    }

    @Test func trackedPlanContainsFinalDecisions() throws {
        let plan = try String(contentsOf: repositoryRoot().appendingPathComponent("plans/issue-1005-selected-item-metadata.md"), encoding: .utf8)
        for marker in ["MetadataMetrics.stackedRowThreshold", "Issue #219 owns deletion-impact analysis", "ChatTurnID"] {
            #expect(plan.contains(marker), "missing plan decision: \(marker)")
        }
    }

    @Test func progressEntryNamesCompletedPhases() throws {
        let progress = try String(contentsOf: repositoryRoot().appendingPathComponent("progress/2026-08-01T004700Z-issue-1005-phase5-inspector-metadata.md"), encoding: .utf8)
        #expect(progress.contains("Phase 5"))
        #expect(progress.contains("status: in-progress") || progress.contains("status: complete"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
