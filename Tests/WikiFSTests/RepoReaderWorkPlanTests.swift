import Testing
@testable import WikiFSCore

/// Locks the deterministic 2...19 reader fan-out contract used by the daemon
/// before the single repository curator is allowed to write wiki pages.
struct RepoReaderWorkPlanTests {
    @Test func normalizesAndBalancesReaderAssignments() {
        let plan = RepoReaderWorkPlan.make(paths: ["z.swift", "a.swift", "z.swift", "", "b.swift"])

        #expect(plan.assignments.count == 3)
        #expect(plan.assignments.map(\.ordinal) == [1, 2, 3])
        #expect(plan.assignments.flatMap(\.paths) == ["a.swift", "b.swift", "z.swift"])
        #expect(plan.assignments.map { $0.paths.count }.max()! - plan.assignments.map { $0.paths.count }.min()! <= 1)
    }

    @Test func capsLargeRepositoriesAtNineteenReadersWithoutDroppingPaths() {
        let paths = (0..<40).map { String(format: "Sources/%02d.swift", $0) }
        let plan = RepoReaderWorkPlan.make(paths: paths)

        #expect(plan.assignments.count == RepoReaderWorkPlan.maximumReaderCount)
        #expect(plan.assignments.flatMap(\.paths).sorted() == paths)
        #expect(plan.assignments.allSatisfy { !$0.paths.isEmpty })
    }

    @Test func emptyRepositoryProducesNoReaders() {
        #expect(RepoReaderWorkPlan.make(paths: []).assignments.isEmpty)
    }

    @Test func singleAllowedFileProducesNoReaderAssignments() {
        let plan = RepoReaderWorkPlan.make(paths: ["README.md"])

        #expect(plan.assignments.isEmpty)
        #expect(!plan.isEligibleForReaderFanout)
    }

    @Test func readerAssignmentsNeverHaveAnEmptyAllowlist() {
        let plans = (0...40).map { count in
            RepoReaderWorkPlan.make(paths: (0..<count).map { "Sources/\($0).swift" })
        }

        #expect(plans.allSatisfy { plan in
            plan.assignments.allSatisfy { !$0.paths.isEmpty }
        })
    }

    @Test func rejectsManuallyConstructedEmptyReaderAllowlist() {
        let invalid = RepoReaderWorkPlan(assignments: [
            .init(ordinal: 1, paths: ["Sources/App.swift"]),
            .init(ordinal: 2, paths: []),
        ])

        #expect(!invalid.isEligibleForReaderFanout)
        #expect(RepoReaderWorkPlan.make(paths: ["a.swift", "b.swift"]).isEligibleForReaderFanout)
    }
}
