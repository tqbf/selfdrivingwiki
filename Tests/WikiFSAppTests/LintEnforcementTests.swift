#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// W2a: enforcement for on-by-default lint repairs — the host accounting's
/// CAS-guarded auto-revert, approval traceability on receipts, the patch
/// budget's "write phase not performed" record, the breaker feedback loop,
/// and the sandbox precondition for a repair lease.
@MainActor
@Suite(.serialized)
struct LintEnforcementTests {

    /// A clean page, a breaker over a temp App Group, and a run scratch.
    @MainActor
    private final class Fixture {
        let root: URL
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let scratch: URL
        let page: WikiPage
        let inspectedHead: PageVersionID
        static let originalBody = "# Enforcement\n\nPlain text the lint run inspected.\n"
        /// Conflict markers are a deterministic, confirmed finding — a
        /// write that adds them introduces a NEW defect.
        static let defectiveBody = "# Enforcement\n\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n"

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lint-enforce-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("WikiFS.sqlite"))
            let appGroup = root.appendingPathComponent("appgroup", isDirectory: true)
            breaker = LintRepairBreaker(containerResolver: { appGroup })
            scratch = root.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            page = try store.createPage(title: "Enforcement")
            try store.updatePage(id: page.id, title: "Enforcement", body: Self.originalBody)
            inspectedHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        deinit {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // Temp cleanup only; each fixture owns a unique directory.
            }
        }

        /// A plan whose gate matched approval `row-1` (the injected seam).
        func authorizedPlan() async throws -> AgentOperationRunner.LintPagePlan {
            try #require(await AgentOperationRunner.makeLintPagePlan(
                store: store, pageID: page.id, stateMarkdown: "# state\n",
                gateInputs: .init(provider: "anthropic", model: "claude-opus", modelRevision: "rev-1", effort: "high"),
                selection: { _ in .repairAuthorized(approvalID: "row-1") },
                breaker: breaker))
        }

        /// Stage a fully filled run report (every pending line answered) and
        /// the agent's own `--kind lint` append.
        func stageAgentArtifacts(for plan: AgentOperationRunner.LintPagePlan) throws {
            let skeleton = LintRunReportText.render(snapshot: plan.snapshot, preflight: plan.preflight)
            let filled = skeleton.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if line == "verification none pending" { return "verification none clean" }
                if line.hasSuffix(" pending") {
                    return line.replacingOccurrences(of: " pending", with: " valid-as-written|recorded")
                }
                return String(line)
            }.joined(separator: "\n")
            try filled.write(
                to: scratch.appendingPathComponent(AgentStaging.lintRunReportFileName),
                atomically: true, encoding: .utf8)
            _ = try store.appendLog(kind: .lint, title: "Lint — \(plan.snapshot.title)", note: "agent record")
        }

        /// Simulate the run's own write and return the head it produced.
        func agentWrite(_ body: String) throws -> PageVersionID {
            try store.updatePage(id: page.id, title: "Enforcement", body: body)
            return try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        func account(
            _ plan: AgentOperationRunner.LintPagePlan, runStart: Date, producedHead: PageVersionID? = nil
        ) -> AgentOperationRunner.LintPageDispatchOutcome {
            AgentOperationRunner.accountForLintRun(
                plan: plan, pageID: page.id, scratchDirectory: scratch,
                store: store, runStart: runStart, producedHead: producedHead)
        }

        func hostAuditNote() throws -> String {
            try #require(try store.recentLogEntries(limit: 50).first { entry in
                entry.title == "Selected-page lint — Enforcement"
            }?.note)
        }

        var breakerKey: LintRepairBreakerKey {
            get throws {
                LintRepairBreakerKey(
                    pipeline: try LintAcceptanceManifest.Pipeline.live(),
                    provider: "anthropic", model: "claude-opus", effort: "high")
            }
        }
    }

    // MARK: - Auto-revert (W2a §2)

    @Test func verificationFailureRevertsToTheInspectedHead() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        #expect(plan.authority == .shippedApproval(LintApprovalID(rawValue: "row-1")))
        try fixture.stageAgentArtifacts(for: plan)
        let written = try fixture.agentWrite(Fixture.defectiveBody)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed, "the run stays a verification failure")
        #expect(outcome.detail.contains("verification failed"))
        #expect(outcome.revert == .reverted(to: fixture.inspectedHead, from: written))
        #expect(outcome.isFlagged == false)
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == fixture.inspectedHead)
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).body == Fixture.originalBody)
        let note = try fixture.hostAuditNote()
        #expect(note.contains("revert=reverted to \(fixture.inspectedHead.rawValue) from \(written.rawValue)"))
        #expect(note.contains("authority_tier=shippedApproval"))
        #expect(note.contains("approval_id=row-1"))
    }

    @Test func concurrentWriteAfterThePatchIsNeverReverted() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        try fixture.stageAgentArtifacts(for: plan)
        let written = try fixture.agentWrite(Fixture.defectiveBody)
        // A concurrent writer advances the page after the run's patch.
        let concurrentBody = Fixture.defectiveBody + "\nA human kept editing.\n"
        let concurrent = try fixture.agentWrite(concurrentBody)

        let outcome = fixture.account(plan, runStart: runStart, producedHead: written)

        #expect(outcome.status == .failed)
        #expect(outcome.revert == .refusedHeadDiverged(written: written, current: concurrent))
        #expect(outcome.isFlagged)
        #expect(outcome.detail.contains("diverges from written \(written.rawValue)"),
                "the written-vs-current divergence is recorded")
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == concurrent,
                "the concurrent edit survives")
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).body == concurrentBody)
        #expect(try fixture.hostAuditNote().contains("FLAGGED for review"))

        // The queue report's per-page record carries the revert outcome.
        let mutation = QueueIngestionReporting.lintPageOutcomesMutation([outcome.queueReportOutcome])
        let record = try #require(mutation.targetUpserts.first)
        #expect(record.target == .page(fixture.page.id))
        #expect(record.state == .failed(reason: "lint verification failed; FLAGGED — the write could not be reverted"))
        #expect(record.detail?.contains("revert=refused") == true)
        #expect(record.detail?.contains("approval_id=row-1") == true)
    }

    /// Two failing repair runs trip the breaker; the next plan for the same
    /// configuration is demoted to report-only.
    @Test func repeatedVerificationFailuresDemoteTheNextPlan() async throws {
        let fixture = try Fixture()
        for _ in 0..<LintRepairBreaker.verificationFailureTripCount {
            let runStart = Date()
            let plan = try await fixture.authorizedPlan()
            try fixture.stageAgentArtifacts(for: plan)
            _ = try fixture.agentWrite(Fixture.defectiveBody)
            _ = fixture.account(plan, runStart: runStart)
        }
        guard case .tripped = fixture.breaker.consult(try fixture.breakerKey) else {
            Issue.record("two verification failures must trip the breaker")
            return
        }
        let next = try await fixture.authorizedPlan()
        #expect(next.authority.tier == .breakerDemoted)
        #expect(next.authority.approvalID == LintApprovalID(rawValue: "row-1"))
        #expect(next.repairAuthorized == false)
        #expect(AgentLauncher.managedRunPolicy(for: next.request)
            == .lintSelectedPageReportOnly(pageID: fixture.page.id),
            "a demoted plan requests a report-only lease")
        #expect(next.gateReason.hasPrefix("circuit breaker tripped: "))
    }

    // MARK: - Receipts (W2a §4)

    @Test func repairRunReceiptCarriesApprovalAndTier() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        try fixture.stageAgentArtifacts(for: plan)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.authority == .shippedApproval(LintApprovalID(rawValue: "row-1")))
        #expect(outcome.detail.contains("authority_tier=shippedApproval; approval_id=row-1"))
        let record = try #require(QueueIngestionReporting
            .lintPageOutcomesMutation([outcome.queueReportOutcome]).targetUpserts.first)
        #expect(record.detail?.hasPrefix("authority_tier=shippedApproval; approval_id=row-1") == true)
        // A run that wrote nothing and verified records a clean outcome.
        #expect(fixture.breaker.consult(try fixture.breakerKey) == .clean)
    }

    @Test func reportOnlyRunCarriesTierAndReason() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        // The production gate: unconfigured components select report-only.
        let plan = try #require(await AgentOperationRunner.makeLintPagePlan(
            store: fixture.store, pageID: fixture.page.id, stateMarkdown: "# state\n"))
        #expect(plan.authority.tier == .reportOnly)
        #expect(plan.authority.approvalID == nil)
        let reason = try #require(plan.authority.reason)
        #expect(reason.contains("gate components not fully resolved"))
        try fixture.stageAgentArtifacts(for: plan)

        let outcome = fixture.account(plan, runStart: runStart)

        let note = try fixture.hostAuditNote()
        #expect(note.contains("authority_tier=reportOnly"))
        #expect(note.contains("authority_reason=\(reason)"))
        #expect(note.contains("approval_id=") == false)
        let record = try #require(QueueIngestionReporting
            .lintPageOutcomesMutation([outcome.queueReportOutcome]).targetUpserts.first)
        #expect(record.detail?.contains("authority_tier=reportOnly; authority_reason=") == true)
    }

    // MARK: - Patch budget record (W2a §3)

    /// The trusted daemon's budget rejection record moves the run to
    /// `.budgetExceeded`: write phase not performed, no breaker outcome.
    @Test func budgetRejectionMarksTheWritePhaseNotPerformed() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        try fixture.stageAgentArtifacts(for: plan)
        let numbers = "budget_exceeded: patch requested 9 hunks / 20 changed bytes; run already spent 0 hunks / 0 bytes; run cap 8 hunks / 8192 bytes"
        _ = try fixture.store.appendLog(
            kind: .lint, title: LintPatchBudget.auditTitlePrefix + "Enforcement", note: numbers)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.authority?.tier == .budgetExceeded)
        #expect(outcome.authority?.approvalID == LintApprovalID(rawValue: "row-1"))
        #expect(outcome.detail.contains("write phase not performed"))
        #expect(outcome.detail.contains("run cap 8 hunks / 8192 bytes"))
        #expect(try fixture.hostAuditNote().contains("authority_tier=budgetExceeded"))
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == fixture.inspectedHead)
    }

    /// The daemon's budget record names the page, but it is not the agent's
    /// log: a run whose agent never logged still fails accounting.
    @Test func budgetRecordDoesNotStandInForTheAgentLog() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        _ = try fixture.store.appendLog(
            kind: .lint, title: LintPatchBudget.auditTitlePrefix + "Enforcement", note: "budget_exceeded")

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("AGENT LOG MISSING"))
    }

    // MARK: - Sandbox precondition (W2a §5)

    /// An unsandboxed lint child cannot receive a repair-capable lease:
    /// (1) with no trusted lease manager the lint launch is REFUSED before
    /// any spawn — there is no unscoped fallback; (2) a repair lease always
    /// resolves the SCOPED seatbelt profile, never the fail-open nil path.
    @Test func unsandboxedLintChildCannotReceiveRepairLease() async throws {
        let wikiID = WikiID(rawValue: "01HZWIKI0000000000000000001")
        let pageID = PageID(rawValue: "01HZPAGE00000000000000000C")
        let launcher = AgentLauncher()
        launcher.scopedRunLeaseManager = nil
        for policy: ManagedRunPolicy in [
            .lintSelectedPageRepair(pageID: pageID),
            .lintSelectedPageReportOnly(pageID: pageID),
            .lintWholeWikiReportOnly,
        ] {
            await #expect(throws: AgentScopedRunError.self, "\(policy) must refuse without a lease manager") {
                _ = try await launcher.issueScopedRunIfConfigured(wikiID: wikiID, policy: policy)
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // Temp cleanup only.
            }
        }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let lease = AgentScopedRunLease(
            credentials: AgentScopedRunCredentials(
                endpointPath: root.appendingPathComponent("runs/r.sock").path,
                capability: "cap"),
            seatbeltInputs: AgentScopedRunSeatbeltInputs(
                appGroupContainerPath: root.path,
                daemonEndpointPath: root.appendingPathComponent("d.sock").path,
                runsDirectoryPath: root.appendingPathComponent("runs").path),
            leaseLifetime: .seconds(60),
            policy: .lintSelectedPageRepair(pageID: pageID))
        let invocation = try #require(try launcher.resolveSandboxInvocation(
            scratch: scratch, pdf2mdScriptPath: nil, scopedRunLease: lease),
            "a repair lease must never resolve to an unsandboxed spawn")
        let defines = Dictionary(uniqueKeysWithValues: invocation.defines.map { ($0.0, $0.1) })
        #expect(defines["RUN_ENDPOINT"] == lease.credentials.endpointPath,
                "the repair lease runs under the SCOPED profile")

        // A scoped profile that cannot be built fails the launch — it never
        // falls back to the unscoped (or no) profile.
        let overlong = AgentScopedRunLease(
            credentials: AgentScopedRunCredentials(
                endpointPath: root.appendingPathComponent(
                    "runs/" + String(repeating: "a", count: 120) + ".sock").path,
                capability: "cap"),
            seatbeltInputs: lease.seatbeltInputs,
            leaseLifetime: .seconds(60),
            policy: .lintSelectedPageRepair(pageID: pageID))
        #expect(throws: SandboxProfile.ProfileError.self) {
            _ = try launcher.resolveSandboxInvocation(
                scratch: scratch, pdf2mdScriptPath: nil, scopedRunLease: overlong)
        }
    }
}
#endif
