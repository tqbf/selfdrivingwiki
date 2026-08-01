import Foundation
import Testing
@testable import DynamicRendererPRSeriesAudit

struct DynamicRendererPRSeriesAuditModelTests {
    @Test func rejectsRecordWithMismatchedHeads() throws {
        let record = DynamicRendererGateRecord(
            schemaVersion: 1,
            auditedSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            headRefOID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            baseRefName: "main",
            baseRefOID: "cccccccccccccccccccccccccccccccccccccccc",
            cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", conclusion: "success")], review: .noReview,
            commands: [],
            testInventory: "plans/dynamic-renderers-pr1-test-inventory.json",
            mutationReport: nil,
            findings: [],
            recordedAt: "2026-08-01T00:00:00+00:00"
        )
        #expect(throws: DynamicRendererAuditError.self) { try record.validate() }
    }

    @Test func rejectsCheckRunAndReviewBindings() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let valid = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: sha, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: sha), commands: [], testInventory: "plans/x.json", mutationReport: "tmp/report.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        try valid.validate()
        let wrongCheck = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: base, conclusion: "success")], review: .noReview, commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try wrongCheck.validate() }
        let oldReview = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: sha, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: base), commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try oldReview.validate() }
    }

    @Test func buildSuiteUsesRequiredCommandOrder() {
        #expect(DynamicRendererBuildAndSuiteGate.requiredCommands == [
            ["make", "build"],
            ["make", "test"],
            ["WIKIFS_APP_TESTS=1", "swift", "test"],
            ["make", "prompts"],
            ["swift", "build"],
            ["swift", "test"],
        ])
    }

    @Test func reviewStatesRoundTripUsingSchemaShape() throws {
        let approved = DynamicRendererAuditReview.approved(author: "reviewer", commitSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let approvedData = try JSONEncoder().encode(approved)
        #expect(String(decoding: approvedData, as: UTF8.self).contains("\"approved\":true"))
        #expect(try JSONDecoder().decode(DynamicRendererAuditReview.self, from: approvedData) == approved)
        let noReview = DynamicRendererAuditReview.noReview
        let noReviewData = try JSONEncoder().encode(noReview)
        #expect(String(decoding: noReviewData, as: UTF8.self) == "{\"approved\":false}")
        #expect(try JSONDecoder().decode(DynamicRendererAuditReview.self, from: noReviewData) == noReview)
    }

    @Test func verifierRejectsForeignChecksOldApprovalDirtyAndRaces() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: sha, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: sha), commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"schemaVersion\":1}".utf8).write(to: directory.appendingPathComponent("series.json"))
        let good = GitHubAuditPullRequest(headRefName: "feature", headRefOID: sha, baseRefName: "main", baseRefOID: base, title: "feat(audit): verify", checks: [.init(name: "swift", headSHA: sha, conclusion: "success")], reviews: [.init(author: "reviewer", commitSHA: sha, state: "APPROVED")])
        let git = AuditFakeGit(head: "feature")
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good.copy(checkSHA: base)]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good.copy(reviewSHA: base)]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature", dirty: true), github: AuditFakeGitHub([good]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good, good.copy(head: base)]), records: AuditFakeRecords([record])) }
    }
}

private final class AuditFakeGit: GitRepositoryQuerying {
    let head: String; let dirty: Bool
    init(head: String, dirty: Bool = false) { self.head = head; self.dirty = dirty }
    func output(arguments: [String]) throws -> String {
        if arguments == ["status", "--porcelain"] { return dirty ? "M file" : "" }
        if arguments == ["branch", "--show-current"] { return head }
        return ""
    }
    func status(arguments: [String]) throws -> Int32 { 0 }
}

private final class AuditFakeGitHub: GitHubPullRequestQuerying {
    var values: [GitHubAuditPullRequest]
    init(_ values: [GitHubAuditPullRequest]) { self.values = values }
    func pullRequest(head: String) throws -> GitHubAuditPullRequest { values.removeFirst() }
}

private struct AuditFakeRecords: GateRecordReading {
    let values: [DynamicRendererGateRecord]
    init(_ values: [DynamicRendererGateRecord]) { self.values = values }
    func records(at directory: URL) throws -> [DynamicRendererGateRecord] { values }
}

private extension GitHubAuditPullRequest {
    func copy(checkSHA: String? = nil, reviewSHA: String? = nil, head: String? = nil) -> Self {
        .init(headRefName: headRefName, headRefOID: head ?? headRefOID, baseRefName: baseRefName, baseRefOID: baseRefOID, title: title, checks: checks.map { .init(name: $0.name, headSHA: checkSHA ?? $0.headSHA, conclusion: $0.conclusion) }, reviews: reviews.map { .init(author: $0.author, commitSHA: reviewSHA ?? $0.commitSHA, state: $0.state) })
    }
}

private func temporarySeriesDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "tmp", isDirectory: true).appendingPathComponent("audit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
