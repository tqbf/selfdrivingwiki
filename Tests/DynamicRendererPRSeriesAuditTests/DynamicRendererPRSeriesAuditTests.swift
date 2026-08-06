import Foundation
import Testing
@testable import DynamicRendererPRSeriesAudit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DynamicRendererPRSeriesAuditTests {
    @Test func schemaRejectsCheckAndApprovalFromAnotherHead() throws {
        let record = GateRecord(
            schemaVersion: GateRecordSchemaValidator.schemaVersion, auditedHead: "abcdef0", headRefOid: "abcdef0",
            baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: "base-sha",
            cleanCheckout: true, requiredCheckNames: ["swift"], checkRunHeadOIDs: ["old-head"],
            approvalCommitOIDs: ["abcdef0"], commandResults: [AuditCommandResult(command: "make build", exitStatus: 0)],
            inventoryPath: "plans/inventory.json", findingDispositions: [], recordedAt: FixedClock().now()
        )
        #expect(throws: DynamicRendererAuditError.schemaMismatch) {
            try GateRecordSchemaValidator.validate(record)
        }
    }

    @Test func schemaRejectsUnresolvedCriticalAndHighFindings() throws {
        for severity in [GateFindingSeverity.critical, .high] {
            let record = gateRecord(findings: [
                GateFindingDisposition(identifier: "NW-1", severity: severity, status: .unresolved),
            ])
            #expect(throws: DynamicRendererAuditError.unresolvedCriticalOrHighFinding) {
                try GateRecordSchemaValidator.validate(record)
            }
        }
    }

    @Test func schemaAcceptsClosedCriticalAndHighFindings() throws {
        let record = gateRecord(findings: [
            GateFindingDisposition(identifier: "NW-1", severity: .critical, status: .resolved),
            GateFindingDisposition(identifier: "NW-2", severity: .high, status: .rebutted),
        ])
        try GateRecordSchemaValidator.validate(record)
    }

    @Test func gateRecordUsesRFC3339JSONAndRoundTripsThroughFileStore() throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let record = gateRecord()
        let store = FileGateRecordStore()

        try store.writeAtomically(record, evidenceDirectory: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("abcdef0.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["recordedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(try store.record(head: "abcdef0", evidenceDirectory: directory) == record)
    }

    @Test func checkedInGateSchemaRequiresRFC3339RecordedAtAndTypedFindings() throws {
        try GateRecordSchemaValidator.validateSchema(at: repositoryRoot().appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json"))
    }

    @Test func buildSuiteRejectsDirtyCheckoutBeforeCommandsRun() async throws {
        let git = FakeGit(clean: false)
        let auditor = auditor(git: git)
        await #expect(throws: DynamicRendererAuditError.dirtyCheckout) {
            try await auditor.buildSuite(series: strictSeries(), head: "abcdef0", evidenceDirectory: temporaryDirectory(), inventoryPath: "plans/inventory.json")
        }
        #expect(git.commands.isEmpty)
    }

    @Test func verifySucceedsWithFreshEvidenceAndStrictPolicy() async throws {
        let records = FakeRecords(record: gateRecord())
        let auditor = auditor(records: records)

        try await auditor.verify(series: strictSeries(), head: "abcdef0", evidenceDirectory: temporaryDirectory())

        #expect(records.readCount == 1)
    }

    @Test func verifyUsesPolicyFlagsInsteadOfHardCodingAllExactHeadRules() async throws {
        let relaxed = PRSeriesPolicy(requireExactHead: false, requireChecksOnHead: false, requireApprovalsOnHead: false)
        let snapshot = PullRequestSnapshot(
            title: "feat(renderer): audit", headRefName: "feature/dynamic-renderers-05-webview-security",
            headRefOid: "new-head", baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: "base-sha",
            requiredCheckNames: ["swift"], checkRunHeadOIDs: ["old-check"], approvalCommitOIDs: ["old-approval"]
        )
        let auditor = auditor(github: FakeGitHub(snapshot: snapshot), records: FakeRecords(record: gateRecord()))

        try await auditor.verify(series: series(policy: relaxed), head: "abcdef0", evidenceDirectory: temporaryDirectory())
    }

    @Test func buildSuiteWritesAtomicEvidenceAndRechecksHeadAfterWrite() async throws {
        let git = FakeGit()
        let github = FakeGitHub()
        let records = FakeRecords()
        let auditor = auditor(git: git, github: github, records: records)

        try await auditor.buildSuite(series: strictSeries(), head: "abcdef0", evidenceDirectory: temporaryDirectory(), inventoryPath: "plans/inventory.json")

        let written = try #require(records.written)
        #expect(records.writeCount == 1)
        #expect(written.commandResults.map(\.command) == ["make build", "make test", "swift test", "make prompts", "swift build", "swift test"])
        #expect(git.commands == ["make build", "make test", "swift test", "make prompts", "swift build", "swift test"])
        #expect(github.requestCount == 2)
        #expect(git.currentHeadCallCount == 2)
    }

    @Test func buildSuiteFailsClosedWhenPostWriteHeadChanges() async throws {
        let git = FakeGit(heads: ["abcdef0", "changed-head"])
        let records = FakeRecords()
        let auditor = auditor(git: git, records: records)

        await #expect(throws: DynamicRendererAuditError.headChangedDuringWrite) {
            try await auditor.buildSuite(series: strictSeries(), head: "abcdef0", evidenceDirectory: temporaryDirectory(), inventoryPath: "plans/inventory.json")
        }
        #expect(records.writeCount == 1)
    }

    @Test func commandEntryPointReturnsAfterASuccessfulVerify() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let store = FileGateRecordStore()
        try store.writeAtomically(gateRecord(), evidenceDirectory: directory)
        let command = AuditCommand(
            git: FakeGit(), github: FakeGitHub(), store: store, clock: FixedClock(),
            schemaURL: repositoryRoot().appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json"),
            defaultSeriesURL: repositoryRoot().appendingPathComponent("plans/dynamic-renderers-pr-series.json")
        )

        try await command.run(arguments: ["verify", "--evidence", directory.path])
    }
}

private func auditor(
    git: FakeGit = FakeGit(),
    github: FakeGitHub = FakeGitHub(),
    records: FakeRecords = FakeRecords()
) -> DynamicRendererPRSeriesAuditor {
    DynamicRendererPRSeriesAuditor(git: git, github: github, reader: records, writer: records, clock: FixedClock())
}

private final class FakeGit: GitRepositoryQuerying, @unchecked Sendable {
    let clean: Bool
    private var remainingHeads: [String]
    private(set) var commands: [String] = []
    private(set) var currentHeadCallCount = 0

    init(clean: Bool = true, heads: [String] = ["abcdef0"]) {
        self.clean = clean
        remainingHeads = heads
    }

    func currentHead() async throws -> String {
        currentHeadCallCount += 1
        if remainingHeads.count > 1 { return remainingHeads.removeFirst() }
        return remainingHeads[0]
    }
    func currentBranch() async throws -> String { "feature/dynamic-renderers-05-webview-security" }
    func isClean() async throws -> Bool { clean }
    func isAncestor(_ ancestor: String, _ descendant: String) async throws -> Bool { true }
    func run(_ command: String, environment: [String: String]) async throws -> AuditCommandResult {
        commands.append(command)
        return AuditCommandResult(command: command, exitStatus: 0)
    }
}

private final class FakeGitHub: GitHubPullRequestQuerying, @unchecked Sendable {
    private let snapshot: PullRequestSnapshot
    private(set) var requestCount = 0

    init(snapshot: PullRequestSnapshot = defaultSnapshot()) { self.snapshot = snapshot }
    func pullRequest(headRefName: String) async throws -> PullRequestSnapshot {
        requestCount += 1
        return snapshot
    }
}

private final class FakeRecords: GateRecordReading, GateRecordWriting, @unchecked Sendable {
    private let stored: GateRecord?
    private(set) var written: GateRecord?
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(record: GateRecord? = nil) { stored = record }
    func record(head: String, evidenceDirectory: URL) throws -> GateRecord? {
        readCount += 1
        return stored
    }
    func writeAtomically(_ record: GateRecord, evidenceDirectory: URL) throws {
        written = record
        writeCount += 1
    }
}

private struct FixedClock: AuditClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}

private func strictSeries() -> PRSeries {
    series(policy: PRSeriesPolicy(requireExactHead: true, requireChecksOnHead: true, requireApprovalsOnHead: true))
}

private func series(policy: PRSeriesPolicy) -> PRSeries {
    PRSeries(schemaVersion: 1, branches: [
        PRSeriesBranch(branch: "feature/dynamic-renderers-05-webview-security", base: "feature/dynamic-renderers-04-routing", titlePrefix: "feat(renderer):"),
    ], policy: policy)
}

private func defaultSnapshot() -> PullRequestSnapshot {
    PullRequestSnapshot(
        title: "feat(renderer): audit", headRefName: "feature/dynamic-renderers-05-webview-security",
        headRefOid: "abcdef0", baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: "base-sha",
        requiredCheckNames: ["swift"], checkRunHeadOIDs: ["abcdef0"], approvalCommitOIDs: ["abcdef0"]
    )
}

private func gateRecord(base: String = "base-sha", findings: [GateFindingDisposition] = []) -> GateRecord {
    GateRecord(
        schemaVersion: GateRecordSchemaValidator.schemaVersion, auditedHead: "abcdef0", headRefOid: "abcdef0",
        baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: base, cleanCheckout: true,
        requiredCheckNames: ["swift"], checkRunHeadOIDs: ["abcdef0"], approvalCommitOIDs: ["abcdef0"],
        commandResults: [AuditCommandResult(command: "make build", exitStatus: 0)], inventoryPath: "plans/inventory.json",
        findingDispositions: findings, recordedAt: FixedClock().now()
    )
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-renderer-audit-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func remove(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("Audit test fixture cleanup failed: \(error)") }
}
