import Foundation
import Testing
@testable import DynamicRendererPRSeriesAudit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DynamicRendererPRSeriesAuditTests {
    @Test func schemaRejectsCheckAndApprovalFromAnotherHead() throws {
        var record = gateRecord()
        record = GateRecord(schemaVersion: record.schemaVersion, auditedHead: record.auditedHead, headRefOid: record.headRefOid, baseRefName: record.baseRefName, baseRefOid: record.baseRefOid, cleanCheckout: record.cleanCheckout, requiredCheckNames: record.requiredCheckNames, checkRunHeadOIDs: ["old-head"], approvalCommitOIDs: record.approvalCommitOIDs, commandResults: record.commandResults, inventoryPath: record.inventoryPath, findingDispositions: record.findingDispositions, recordedAt: record.recordedAt)
        #expect(throws: DynamicRendererAuditError.schemaMismatch) { try GateRecordSchemaValidator.validate(record) }
    }

    @Test func buildSuiteRejectsDirtyCheckoutBeforeCommandsRun() async throws {
        let git = FakeGit(clean: false)
        let auditor = DynamicRendererPRSeriesAuditor(git: git, github: FakeGitHub(), reader: FakeRecords(), writer: FakeRecords(), clock: FixedClock())
        await #expect(throws: DynamicRendererAuditError.dirtyCheckout) { try await auditor.buildSuite(head: "abcdef0", evidenceDirectory: URL(fileURLWithPath: "tmp/test"), inventoryPath: "plans/inventory.json") }
        #expect(git.commands.isEmpty)
    }

    @Test func verifyRejectsStaleEvidenceWithWrongBase() async throws {
        let record = gateRecord(base: "old-base")
        let auditor = DynamicRendererPRSeriesAuditor(git: FakeGit(), github: FakeGitHub(), reader: FakeRecords(record: record), writer: FakeRecords(), clock: FixedClock())
        let series = PRSeries(schemaVersion: 1, branches: [PRSeriesBranch(branch: "feature/dynamic-renderers-05-webview-security", base: "feature/dynamic-renderers-04-routing", titlePrefix: "feat(renderer):")], policy: PRSeriesPolicy(requireExactHead: true, requireChecksOnHead: true, requireApprovalsOnHead: true))
        await #expect(throws: DynamicRendererAuditError.staleEvidence) { try await auditor.verify(series: series, head: "abcdef0", evidenceDirectory: URL(fileURLWithPath: "tmp/test")) }
    }
}

private final class FakeGit: GitRepositoryQuerying, @unchecked Sendable {
    let clean: Bool; var commands: [String] = []
    init(clean: Bool = true) { self.clean = clean }
    func currentHead() async throws -> String { "abcdef0" }
    func currentBranch() async throws -> String { "feature/dynamic-renderers-05-webview-security" }
    func isClean() async throws -> Bool { clean }
    func isAncestor(_ ancestor: String, _ descendant: String) async throws -> Bool { true }
    func run(_ command: String, environment: [String: String]) async throws -> AuditCommandResult { commands.append(command); return AuditCommandResult(command: command, exitStatus: 0) }
}
private struct FakeGitHub: GitHubPullRequestQuerying { func pullRequest(headRefName: String) async throws -> PullRequestSnapshot { PullRequestSnapshot(title: "feat(renderer): audit", headRefName: "feature/dynamic-renderers-05-webview-security", headRefOid: "abcdef0", baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: "base-sha", requiredCheckNames: ["swift"], checkRunHeadOIDs: ["abcdef0"], approvalCommitOIDs: ["abcdef0"]) } }
private struct FakeRecords: GateRecordReading, GateRecordWriting { let stored: GateRecord?; init(record: GateRecord? = nil) { stored = record }; func record(head: String, evidenceDirectory: URL) throws -> GateRecord? { stored }; func writeAtomically(_ record: GateRecord, evidenceDirectory: URL) throws {} }
private struct FixedClock: AuditClock { func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) } }
private func gateRecord(base: String = "base-sha") -> GateRecord { GateRecord(schemaVersion: 1, auditedHead: "abcdef0", headRefOid: "abcdef0", baseRefName: "feature/dynamic-renderers-04-routing", baseRefOid: base, cleanCheckout: true, requiredCheckNames: ["swift"], checkRunHeadOIDs: ["abcdef0"], approvalCommitOIDs: ["abcdef0"], commandResults: [AuditCommandResult(command: "make build", exitStatus: 0)], inventoryPath: "plans/inventory.json", findingDispositions: [], recordedAt: FixedClock().now()) }
