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
}
