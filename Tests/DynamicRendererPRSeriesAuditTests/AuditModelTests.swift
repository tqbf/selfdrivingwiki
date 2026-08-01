import Foundation
import Testing
@testable import DynamicRendererPRSeriesAudit
import WikiFSTypes

struct DynamicRendererPRSeriesAuditModelTests {
    @Test func rejectsRecordWithMismatchedHeads() throws {
        let record = DynamicRendererGateRecord(
            schemaVersion: 1,
            auditedSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            headRefOID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            localHeadOID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
        let valid = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "success"), review: .approved(author: "reviewer", commitSHA: sha), commands: auditCommands(), testInventory: "plans/x.json", mutationReport: "tmp/report.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        try valid.validate()
        let wrongCheck = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: base, conclusion: "success")], review: .noReview, commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try wrongCheck.validate() }
        let oldReview = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: sha, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: base), commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try oldReview.validate() }
    }

    @Test func rejectsUnresolvedGateFindingsAndRequiresLowerSeverityDisposition() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let critical = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "success"), review: .approved(author: "reviewer", commitSHA: sha), commands: auditCommands(), testInventory: "plans/x.json", mutationReport: "tmp/report.json", findings: [.init(identifier: "C-1", severity: .critical, disposition: .unresolved, rationale: "open")], recordedAt: "2026-08-01T00:00:00+00:00")
        let medium = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "success"), review: .approved(author: "reviewer", commitSHA: sha), commands: auditCommands(), testInventory: "plans/x.json", mutationReport: "tmp/report.json", findings: [.init(identifier: "M-1", severity: .medium, disposition: .unresolved, rationale: "open")], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try critical.validate() }
        #expect(throws: DynamicRendererAuditError.self) { try medium.validate() }
    }

    @Test func buildSuiteUsesRequiredCommandOrder() {
        #expect(DynamicRendererBuildAndSuiteGate.requiredCommands == [
            ["make", "build"],
            ["make", "test"],
            ["WIKIFS_APP_TESTS=1", "swift", "test"],
            ["swift", "test", "--filter", "WikiFSTypesRendererTests"],
            ["swift", "test", "--filter", "DynamicRendererPRSeriesAuditTests"],
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
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: sha, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: sha), commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"schemaVersion\":1}".utf8).write(to: directory.appendingPathComponent("series.json"))
        let good = GitHubAuditPullRequest(headRefName: "feature", headRefOID: sha, baseRefName: "main", baseRefOID: base, title: "feat(audit): verify", reviewDecision: "APPROVED", checks: [.init(name: "swift", headSHA: sha, conclusion: "success")], reviews: [.init(author: "reviewer", commitSHA: sha, state: "APPROVED", submittedAt: "2026-08-01T00:00:00+00:00")])
        let git = AuditFakeGit(head: "feature")
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good.copy(checkSHA: base)]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good.copy(reviewSHA: base)]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature", dirty: true), github: AuditFakeGitHub([good]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: git, github: AuditFakeGitHub([good, good.copy(head: base)]), records: AuditFakeRecords([record])) }
    }

    @Test func verifierRejectsSchemaAndStaleEvidence() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = GitHubAuditPullRequest(headRefName: "feature", headRefOID: sha, baseRefName: "main", baseRefOID: base, title: "feat(audit): verify", reviewDecision: "APPROVED", checks: [.init(name: "swift", headSHA: sha, conclusion: "success")], reviews: [.init(author: "reviewer", commitSHA: sha, state: "APPROVED", submittedAt: "2026-08-01T00:00:00+00:00")])
        try Data("{}".utf8).write(to: directory.appendingPathComponent("bad.json"))
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("bad.json").path, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature"), github: AuditFakeGitHub([metadata]), records: AuditFakeRecords([])) }
        try Data("{\"schemaVersion\":1}".utf8).write(to: directory.appendingPathComponent("series.json"))
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature"), github: AuditFakeGitHub([metadata, metadata]), records: AuditFakeRecords([])) }
        let stale = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: base, headRefOID: base, localHeadOID: base, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: [.init(name: "swift", headSHA: base, conclusion: "success")], review: .approved(author: "reviewer", commitSHA: base), commands: [], testInventory: "plans/x.json", mutationReport: nil, findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: directory.appendingPathComponent("series.json").path, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature"), github: AuditFakeGitHub([metadata]), records: AuditFakeRecords([stale])) }
    }

    @Test func fileGateRecordsAtomicallyReplacesSHARecord() throws {
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "pending"), review: .noReview, commands: auditCommands(), testInventory: "plans/x.json", mutationReport: "tmp/report.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        let records = FileGateRecords()
        try records.write(record, to: directory)
        #expect(try records.records(at: directory) == [record])
    }

    @Test func rejectsMissingNamedChecksAndIncompleteBuildEvidence() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let valid = auditRecord(sha: sha, base: base)
        try valid.validate()

        let missingCheck = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: Array(auditChecks(sha: sha, conclusion: "pending").dropLast()), review: .noReview, commands: auditCommands(), testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: "tmp/dynamic-renderer-pr1-mutation-evidence.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try missingCheck.validate() }

        let failedCommand = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "pending"), review: .noReview, commands: auditCommands(exitCode: 1), testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: "tmp/dynamic-renderer-pr1-mutation-evidence.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
        #expect(throws: DynamicRendererAuditError.self) { try failedCommand.validate() }
    }

    @Test func verifierPromotesOnlyACompleteCurrentHeadRecord() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seriesPath = try writeAuditFixture(in: directory, base: base)
        let record = AuditFakeRecords([auditRecord(sha: sha, base: base)])
        let metadata = auditPullRequest(sha: sha, base: base)

        try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([metadata, metadata]), records: record, writer: record)

        #expect(record.written?.requiredCheckRuns == auditChecks(sha: sha, conclusion: "success"))
        #expect(record.written?.review == .approved(author: "reviewer", commitSHA: sha))
    }

    @Test func verifierRejectsGitHubHeadThatIsNotTheLocalExactHead() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seriesPath = try writeAuditFixture(in: directory, base: base)
        #expect(throws: Error.self) {
            try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base, localHeadOID: base), github: AuditFakeGitHub([auditPullRequest(sha: sha, base: base)]), records: AuditFakeRecords([auditRecord(sha: sha, base: base)]))
        }
    }

    @Test func verifierRejectsNoExactHeadRecord() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seriesPath = try writeAuditFixture(in: directory, base: base)
        let metadata = auditPullRequest(sha: sha, base: base)

        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([metadata]), records: AuditFakeRecords([])) }
    }

    @Test func verifierRejectsMissingWrongSHAAndIncompleteLiveChecks() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seriesPath = try writeAuditFixture(in: directory, base: base)
        let record = auditRecord(sha: sha, base: base)
        let good = auditPullRequest(sha: sha, base: base)

        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([good.copy(checks: Array(good.checks.dropLast()))]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([good.copy(checkSHA: base)]), records: AuditFakeRecords([record])) }
        #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([good.copy(reviewSHA: base)]), records: AuditFakeRecords([record])) }
    }

    @Test func verifierRejectsMissingMalformedAndWrongBaseEvidence() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let good = auditPullRequest(sha: sha, base: base)
        let scenarios: [(String, (URL) throws -> Void)] = [
            ("missing inventory", { root in try FileManager.default.removeItem(at: root.appendingPathComponent("plans/dynamic-renderers-pr1-test-inventory.json")) }),
            ("malformed inventory", { root in try Data("{}".utf8).write(to: root.appendingPathComponent("plans/dynamic-renderers-pr1-test-inventory.json")) }),
            ("wrong inventory base", { root in try Data("{\"schemaVersion\":1,\"issue\":1026,\"pr\":1,\"baseCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"mutationEvidence\":{\"report\":\"tmp/dynamic-renderer-pr1-mutation-evidence.json\"}}".utf8).write(to: root.appendingPathComponent("plans/dynamic-renderers-pr1-test-inventory.json")) }),
            ("missing mutation report", { root in try FileManager.default.removeItem(at: root.appendingPathComponent("tmp/dynamic-renderer-pr1-mutation-evidence.json")) }),
            ("malformed mutation report", { root in try Data("{}".utf8).write(to: root.appendingPathComponent("tmp/dynamic-renderer-pr1-mutation-evidence.json")) }),
            ("missing schema", { root in try FileManager.default.removeItem(at: root.appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")) }),
            ("malformed schema", { root in try Data("{}".utf8).write(to: root.appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")) }),
        ]

        for (_, modify) in scenarios {
            let directory = try temporarySeriesDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let seriesPath = try writeAuditFixture(in: directory, base: base)
            try modify(directory)
            #expect(throws: Error.self) { try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([good, good]), records: AuditFakeRecords([auditRecord(sha: sha, base: base)])) }
        }
    }

    @Test func processGitHubQueryUsesSupportedPositionalBranchAndPropagatesCLIError() {
        let runner = AuditFakeGitHubCommandRunner(status: 1, output: "unknown flag: --head")
        #expect(throws: Error.self) { try ProcessGitHubPullRequestQuery(commandRunner: runner).pullRequest(head: "feature/dynamic-renderers-01-model") }
        #expect(runner.arguments == ["gh", "pr", "view", "feature/dynamic-renderers-01-model", "--json", "headRefName,headRefOid,baseRefName,baseRefOid,title,reviewDecision,reviews"])
    }

    @Test func processGitHubQueryBindsAllRequiredChecksToThePRHead() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pullRequest = """
        {"headRefName":"feature/dynamic-renderers-01-model","headRefOid":"\(sha)","baseRefName":"main","baseRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"feat(renderers): model","reviewDecision":"APPROVED","reviews":[{"author":{"login":"reviewer"},"commit":{"oid":"\(sha)"},"state":"APPROVED","submittedAt":"2026-08-01T00:00:00+00:00"}]}
        """
        let checks = """
        {"check_runs":[{"name":"lint","head_sha":"\(sha)","status":"COMPLETED","conclusion":"success","started_at":"2026-08-01T00:00:00Z","completed_at":"2026-08-01T00:01:00Z","id":1},{"name":"skills","head_sha":"\(sha)","status":"COMPLETED","conclusion":"success","started_at":"2026-08-01T00:00:00Z","completed_at":"2026-08-01T00:01:00Z","id":2},{"name":"swift","head_sha":"\(sha)","status":"COMPLETED","conclusion":"success","started_at":"2026-08-01T00:00:00Z","completed_at":"2026-08-01T00:01:00Z","id":3},{"name":"linux-swift","head_sha":"\(sha)","status":"COMPLETED","conclusion":"success","started_at":"2026-08-01T00:00:00Z","completed_at":"2026-08-01T00:01:00Z","id":4},{"name":"python","head_sha":"\(sha)","status":"COMPLETED","conclusion":"success","started_at":"2026-08-01T00:00:00Z","completed_at":"2026-08-01T00:01:00Z","id":5}]}
        """
        let runner = AuditSequencedGitHubCommandRunner(responses: [(0, pullRequest), (0, checks)])
        let result = try ProcessGitHubPullRequestQuery(commandRunner: runner).pullRequest(head: "feature/dynamic-renderers-01-model")

        #expect(result.checks.map(\.name) == DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames)
        #expect(result.checks.allSatisfy { $0.headSHA == sha })
        #expect(runner.arguments == [
            ["gh", "pr", "view", "feature/dynamic-renderers-01-model", "--json", "headRefName,headRefOid,baseRefName,baseRefOid,title,reviewDecision,reviews"],
            ["gh", "api", "repos/{owner}/{repo}/commits/\(sha)/check-runs?per_page=100"],
        ])
    }

    @Test func processGitHubQueryRejectsMissingOrWrongCheckSHA() {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pullRequest = """
        {"headRefName":"feature/dynamic-renderers-01-model","headRefOid":"\(sha)","baseRefName":"main","baseRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"feat(renderers): model","reviewDecision":"APPROVED","reviews":[]}
        """
        let missing = """
        {"check_runs":[{"name":"lint","head_sha":"\(sha)","conclusion":"success"},{"name":"skills","head_sha":"\(sha)","conclusion":"success"},{"name":"swift","head_sha":"\(sha)","conclusion":"success"},{"name":"linux-swift","head_sha":"\(sha)","conclusion":"success"}]}
        """
        let wrong = """
        {"check_runs":[{"name":"lint","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","conclusion":"success"},{"name":"skills","head_sha":"\(sha)","conclusion":"success"},{"name":"swift","head_sha":"\(sha)","conclusion":"success"},{"name":"linux-swift","head_sha":"\(sha)","conclusion":"success"},{"name":"python","head_sha":"\(sha)","conclusion":"success"}]}
        """

        for checks in [missing, wrong] {
            let runner = AuditSequencedGitHubCommandRunner(responses: [(0, pullRequest), (0, checks)])
            #expect(throws: Error.self) { try ProcessGitHubPullRequestQuery(commandRunner: runner).pullRequest(head: "feature/dynamic-renderers-01-model") }
        }
    }

    @Test func processGitHubQueryRejectsLatestFailedOrInProgressDuplicateCheckRuns() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pullRequest = """
        {"headRefName":"feature/dynamic-renderers-01-model","headRefOid":"\(sha)","baseRefName":"main","baseRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"feat(renderers): model","reviewDecision":"APPROVED","reviews":[]}
        """
        let names = DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames
        for latest in ["failure", "in_progress"] {
            let checks = names.enumerated().flatMap { index, name -> [[String: Any]] in
                [["name": name, "head_sha": sha, "status": "COMPLETED", "conclusion": "success", "started_at": "2026-08-01T00:00:00Z", "completed_at": "2026-08-01T00:01:00Z", "id": index + 1], ["name": name, "head_sha": sha, "status": latest == "in_progress" ? "IN_PROGRESS" : "COMPLETED", "conclusion": latest, "started_at": "2026-08-01T00:02:00Z", "completed_at": latest == "in_progress" ? NSNull() : "2026-08-01T00:03:00Z", "id": index + 101]]
            }
            let data = try JSONSerialization.data(withJSONObject: ["check_runs": checks])
            let runner = AuditSequencedGitHubCommandRunner(responses: [(0, pullRequest), (0, String(decoding: data, as: UTF8.self))])
            #expect(throws: Error.self) { try ProcessGitHubPullRequestQuery(commandRunner: runner).pullRequest(head: "feature/dynamic-renderers-01-model") }
        }
    }

    @Test func processRunnerDrainsVerboseOutputAndTerminatesTimedOutCommand() throws {
        let verbose = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["sh", "-c", "i=0; while [ $i -lt 20000 ]; do echo stdout-$i; echo stderr-$i >&2; i=$((i+1)); done"], policy: .init(timeout: 5))
        #expect(verbose.status == 0)
        #expect(verbose.output.contains("stdout-19999"))
        #expect(verbose.output.contains("stderr-19999"))
        #expect(throws: ProcessRunnerError.timedOut) {
            _ = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["sh", "-c", "sleep 30"], policy: .init(timeout: 0.05, terminationGrace: 0.5))
        }
    }

    @Test func verifierRejectsChangesRequestedAfterApproval() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seriesPath = try writeAuditFixture(in: directory, base: base)
        let approved = auditPullRequest(sha: sha, base: base)
        let changed = approved.copy(
            reviewDecision: "CHANGES_REQUESTED",
            reviews: approved.reviews + [.init(author: "reviewer", commitSHA: sha, state: "CHANGES_REQUESTED", submittedAt: "2026-08-01T01:00:00+00:00")]
        )

        #expect(throws: Error.self) {
            try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([changed]), records: AuditFakeRecords([auditRecord(sha: sha, base: base)]))
        }
    }

    @Test func schemaValidatorRejectsWrongTypesMissingFieldsAndUnknownEnumValues() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let schema = try Data(contentsOf: URL(fileURLWithPath: "plans/dynamic-renderer-gate-record.schema.json"))
        let record = auditRecord(sha: sha, base: base)
        let cases = [
            try encodedGateRecord(record) { $0["cleanCheckout"] = "true" },
            try encodedGateRecord(record) { $0.removeValue(forKey: "recordedAt") },
            try encodedGateRecord(record) { $0.removeValue(forKey: "localHeadOID") },
            try encodedGateRecord(record) { $0["findings"] = ["unstructured finding"] },
            try encodedGateRecord(record) { document in
                var checks = document["requiredCheckRuns"] as? [[String: Any]] ?? []
                checks[0]["conclusion"] = "neutral"
                document["requiredCheckRuns"] = checks
            },
        ]

        for data in cases {
            #expect(throws: Error.self) { try GateRecordSchemaValidator.validate(instanceData: data, schemaData: schema) }
        }
    }

    @Test func verifierRejectsMutationReportForAnotherHeadOrScope() throws {
        try expectMutationEvidenceRejection { document in
            document["auditedSHA"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        try expectMutationEvidenceRejection { document in
            document["scope"] = "Sources/WikiFS"
        }
    }

    @Test func verifierRejectsFailureOnlyAndThresholdBreakingMutationReports() throws {
        try expectMutationEvidenceRejection { document in
            document["passed"] = false
        }
        try expectMutationEvidenceRejection { document in
            document["result"] = ["killed": 0, "survived": 1, "unviable": 0]
            document["dispositions"] = [["outcome": "survived", "severity": "medium", "count": 1, "disposition": "accepted", "rationale": "not allowed by threshold"]]
        }
    }

    @Test func verifierRejectsUnresolvedCriticalAndUndispositionedLowerMutationFindings() throws {
        try expectMutationEvidenceRejection { document in
            document["result"] = ["killed": 0, "survived": 0, "unviable": 1]
            document["dispositions"] = [["outcome": "unviable", "severity": "critical", "count": 1, "disposition": "accepted", "rationale": "critical finding"]]
        }
        try expectMutationEvidenceRejection { document in
            document["result"] = ["killed": 0, "survived": 0, "unviable": 1]
            document["dispositions"] = [["outcome": "unviable", "severity": "low", "count": 1, "disposition": "unresolved", "rationale": "missing policy disposition"]]
        }
    }

    @Test func fileGateRecordsRejectsSchemaMismatchAndWrongSHAFilename() throws {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directory = try temporarySeriesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = auditRecord(sha: sha, base: base)
        let encoded = try JSONEncoder().encode(record)
        let malformed = String(decoding: encoded, as: UTF8.self).dropLast() + ",\"unexpected\":true}"
        try Data(malformed.utf8).write(to: directory.appendingPathComponent("\(sha).json"))
        #expect(throws: Error.self) { try FileGateRecords().records(at: directory) }

        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(sha).json"))
        try encoded.write(to: directory.appendingPathComponent("\(base).json"))
        #expect(throws: Error.self) { try FileGateRecords().records(at: directory) }
    }
}

private final class AuditFakeGit: GitRepositoryQuerying {
    let head: String; let dirty: Bool; let base: String; let localHeadOID: String
    init(head: String, dirty: Bool = false, base: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", localHeadOID: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") { self.head = head; self.dirty = dirty; self.base = base; self.localHeadOID = localHeadOID }
    func output(arguments: [String]) throws -> String {
        if arguments == ["status", "--porcelain"] { return dirty ? "M file" : "" }
        if arguments == ["branch", "--show-current"] { return head }
        if arguments == ["rev-parse", "HEAD"] { return localHeadOID }
        if arguments == ["rev-parse", "origin/main"] { return base }
        return ""
    }
    func status(arguments: [String]) throws -> Int32 { 0 }
}

private final class AuditFakeGitHub: GitHubPullRequestQuerying {
    var values: [GitHubAuditPullRequest]
    init(_ values: [GitHubAuditPullRequest]) { self.values = values }
    func pullRequest(head: String) throws -> GitHubAuditPullRequest { values.removeFirst() }
}

private final class AuditFakeRecords: GateRecordReading, GateRecordWriting {
    let values: [DynamicRendererGateRecord]
    var written: DynamicRendererGateRecord?
    init(_ values: [DynamicRendererGateRecord]) { self.values = values }
    func records(at directory: URL) throws -> [DynamicRendererGateRecord] { values }
    func write(_ record: DynamicRendererGateRecord, to directory: URL) throws { written = record }
}

private extension GitHubAuditPullRequest {
    func copy(checkSHA: String? = nil, reviewSHA: String? = nil, head: String? = nil, checks: [Check]? = nil, reviewDecision: String? = nil, reviews: [Review]? = nil) -> Self {
        .init(headRefName: headRefName, headRefOID: head ?? headRefOID, baseRefName: baseRefName, baseRefOID: baseRefOID, title: title, reviewDecision: reviewDecision ?? self.reviewDecision, checks: checks ?? self.checks.map { .init(name: $0.name, headSHA: checkSHA ?? $0.headSHA, conclusion: $0.conclusion) }, reviews: reviews ?? self.reviews.map { .init(author: $0.author, commitSHA: reviewSHA ?? $0.commitSHA, state: $0.state, submittedAt: $0.submittedAt) })
    }
}

private func temporarySeriesDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "tmp", isDirectory: true).appendingPathComponent("audit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func auditChecks(sha: String, conclusion: String) -> [DynamicRendererAuditCheckRun] {
    DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames.map { .init(name: $0, headSHA: sha, conclusion: conclusion) }
}

private func auditCommands() -> [DynamicRendererAuditCommandResult] {
    DynamicRendererBuildAndSuiteGate.requiredCommands.map { .init(command: $0.joined(separator: " "), exitCode: 0) }
}

private func auditCommands(exitCode: Int) -> [DynamicRendererAuditCommandResult] {
    DynamicRendererBuildAndSuiteGate.requiredCommands.map { .init(command: $0.joined(separator: " "), exitCode: exitCode) }
}

private func auditRecord(sha: String, base: String) -> DynamicRendererGateRecord {
    .init(schemaVersion: 1, auditedSHA: sha, headRefOID: sha, localHeadOID: sha, baseRefName: "main", baseRefOID: base, cleanCheckout: true, requiredCheckRuns: auditChecks(sha: sha, conclusion: "pending"), review: .noReview, commands: auditCommands(), testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: "tmp/dynamic-renderer-pr1-mutation-evidence.json", findings: [], recordedAt: "2026-08-01T00:00:00+00:00")
}

private func auditPullRequest(sha: String, base: String) -> GitHubAuditPullRequest {
    .init(headRefName: "feature/dynamic-renderers-01-model", headRefOID: sha, baseRefName: "main", baseRefOID: base, title: "feat(renderers): model", reviewDecision: "APPROVED", checks: auditChecks(sha: sha, conclusion: "success").map { .init(name: $0.name, headSHA: $0.headSHA, conclusion: $0.conclusion) }, reviews: [.init(author: "reviewer", commitSHA: sha, state: "APPROVED", submittedAt: "2026-08-01T00:00:00+00:00")])
}

private func writeAuditFixture(in directory: URL, base: String) throws -> String {
    let plans = directory.appendingPathComponent("plans", isDirectory: true)
    let temporary = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("{\"schemaVersion\":1,\"issue\":1026,\"phases\":[{\"number\":1,\"branch\":\"feature/dynamic-renderers-01-model\",\"base\":\"main\",\"inventory\":\"plans/dynamic-renderers-pr1-test-inventory.json\"}]}".utf8).write(to: plans.appendingPathComponent("series.json"))
    try Data("{\"schemaVersion\":1,\"issue\":1026,\"pr\":1,\"baseCommit\":\"\(base)\",\"mutationEvidence\":{\"report\":\"tmp/dynamic-renderer-pr1-mutation-evidence.json\",\"scope\":\"Sources/WikiFSTypes/Renderer\",\"coveredSymbols\":[\"RendererRelativePath\"],\"threshold\":{\"maximumSurvivors\":0,\"maximumUnviable\":0},\"phasePolicy\":{\"allowedUnviableSeverities\":[\"medium\",\"low\"]}}}".utf8).write(to: plans.appendingPathComponent("dynamic-renderers-pr1-test-inventory.json"))
    let schema = try Data(contentsOf: URL(fileURLWithPath: "plans/dynamic-renderer-gate-record.schema.json"))
    try schema.write(to: plans.appendingPathComponent("dynamic-renderer-gate-record.schema.json"))
    let native = Data("{\"files\":{\"/Sources/WikiFSTypes/Renderer/RendererConstraints.swift\":{\"mutants\":[{\"id\":\"m1\",\"status\":\"Crash\"}]}}}".utf8)
    try native.write(to: temporary.appendingPathComponent("dynamic-renderer-pr1-native-mutation-report.json"))
    let digest = RendererSHA256.digest(native).hex
    try Data("{\"schemaVersion\":2,\"auditedSHA\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"baseOID\":\"\(base)\",\"generatedAt\":\"2026-08-01T00:00:00+00:00\",\"command\":\"make mutate-scope SOURCES_PATH=Sources/WikiFSTypes/Renderer\",\"toolVersion\":\"1.3.0\",\"nativeReport\":\"tmp/dynamic-renderer-pr1-native-mutation-report.json\",\"nativeReportSHA256\":\"\(digest)\",\"scope\":\"Sources/WikiFSTypes/Renderer\",\"coveredSymbols\":[\"RendererRelativePath\"],\"result\":{\"killed\":1,\"survived\":0,\"unviable\":0},\"threshold\":{\"maximumSurvivors\":0,\"maximumUnviable\":0},\"mutants\":[{\"id\":\"m1\",\"outcome\":\"killed\",\"severity\":\"low\",\"disposition\":\"fixed\",\"rationale\":\"native test crash killed mutant\"}],\"passed\":true}".utf8).write(to: temporary.appendingPathComponent("dynamic-renderer-pr1-mutation-evidence.json"))
    return plans.appendingPathComponent("series.json").path
}

private func encodedGateRecord(_ record: DynamicRendererGateRecord, mutate: (inout [String: Any]) -> Void) throws -> Data {
    var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] ?? [:]
    mutate(&document)
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func expectMutationEvidenceRejection(mutate: (inout [String: Any]) -> Void) throws {
    let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let directory = try temporarySeriesDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seriesPath = try writeAuditFixture(in: directory, base: base)
    let mutationURL = directory.appendingPathComponent("tmp/dynamic-renderer-pr1-mutation-evidence.json")
    var document = try JSONSerialization.jsonObject(with: Data(contentsOf: mutationURL)) as? [String: Any] ?? [:]
    mutate(&document)
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: mutationURL)
    let metadata = auditPullRequest(sha: sha, base: base)

    #expect(throws: Error.self) {
        try DynamicRendererPRSeriesAuditMain.verify(seriesPath: seriesPath, evidenceDirectory: directory.path, git: AuditFakeGit(head: "feature/dynamic-renderers-01-model", base: base), github: AuditFakeGitHub([metadata]), records: AuditFakeRecords([auditRecord(sha: sha, base: base)]))
    }
}

private final class AuditFakeGitHubCommandRunner: GitHubCommandRunning {
    let status: Int32
    let output: String
    var arguments: [String] = []

    init(status: Int32, output: String) { self.status = status; self.output = output }
    func run(arguments: [String]) throws -> (status: Int32, output: String) {
        self.arguments = arguments
        return (status, output)
    }
}

private final class AuditSequencedGitHubCommandRunner: GitHubCommandRunning {
    var responses: [(status: Int32, output: String)]
    var arguments: [[String]] = []

    init(responses: [(Int32, String)]) { self.responses = responses }
    func run(arguments: [String]) throws -> (status: Int32, output: String) {
        self.arguments.append(arguments)
        return responses.removeFirst()
    }
}
