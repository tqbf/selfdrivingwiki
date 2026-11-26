import Foundation
import Testing

/// AC.12 (plans/daemon-only-access.md documentation strategy):
/// `PLAN.md` indexes the daemon-only access plan, and the plans it partially
/// supersedes carry their superseded markers — machine-checked so a doc
/// reorganization cannot silently orphan the record.
struct DocumentationIndexContractTests {
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    @Test("PLAN.md indexes the daemon-only access plan")
    func planMdIndexesDaemonOnlyAccess() throws {
        let planIndex = try Self.read("PLAN.md")
        #expect(
            planIndex.contains("plans/daemon-only-access.md"),
            "PLAN.md must index plans/daemon-only-access.md")
        #expect(
            planIndex.contains("daemon-only"),
            "PLAN.md's index entry must name the daemon-only migration")
    }

    @Test("superseded plans carry their markers")
    func supersededPlansCarryMarkers() throws {
        let multiWiki = try Self.read("plans/multi-wiki-daemon.md")
        #expect(
            multiWiki.contains("Superseded in part (sole-writer milestone)"),
            "plans/multi-wiki-daemon.md must carry the sole-writer superseded note pointing at plans/daemon-only-access.md")
        #expect(
            multiWiki.contains("plans/daemon-only-access.md"),
            "the superseded note must reference the superseding plan")

        let cordis = try Self.read("plans/cordis-swift-components.md")
        #expect(
            cordis.contains("superseded") || cordis.contains("Superseded"),
            "plans/cordis-swift-components.md section 15 must carry its superseded marker (the app queue handoff machine is gone)")
    }

    @Test("the daemon-only plan records its final waiver and verification state")
    func daemonOnlyPlanRecordsFinalState() throws {
        let plan = try Self.read("plans/daemon-only-access.md")
        #expect(
            plan.contains("## Waiver history"),
            "the plan must keep its waiver-history section")
        #expect(
            plan.contains("P7"),
            "the verification record must reference the P7 close-out")
    }
}
