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
            cleanCheckout: true,
            commands: [],
            testInventory: "plans/dynamic-renderers-pr1-test-inventory.json",
            mutationReport: nil,
            findings: [],
            recordedAt: "2026-08-01T00:00:00Z"
        )
        #expect(throws: DynamicRendererAuditError.self) { try record.validate() }
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
