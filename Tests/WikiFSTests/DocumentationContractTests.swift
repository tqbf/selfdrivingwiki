import Foundation
import Testing

/// Guards the durable documentation claims for the PageID and SourceID boundary.
struct DocumentationContractTests {
    private static let planPath = "plans/page-source-id-separation.md"
    private static let progressHeading = "## 2026-07-27 — PageID and SourceID type separation"
    private static let requiredPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Deferred identifier work:",
    ]

    @Test func pageSourceIDPlanIsIndexedAndComplete() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let plan = try String(
            contentsOf: root.appendingPathComponent(Self.planPath),
            encoding: .utf8
        )
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8
        )
        let progress = try String(
            contentsOf: root.appendingPathComponent("PROGRESS.md"),
            encoding: .utf8
        )

        #expect(index.contains("[`\(Self.planPath)`](\(Self.planPath))"))
        #expect(progress.contains(Self.progressHeading))
        for marker in Self.requiredPlanMarkers {
            #expect(plan.contains(marker), "missing documentation marker: \(marker)")
        }
    }

    private static func locateRepositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
