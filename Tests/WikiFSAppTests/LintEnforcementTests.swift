#if os(macOS)
import Foundation
import SQLite3
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

        /// A plan under the tier-2 staged-proposal selection (the default
        /// repair path for an unevaluated configuration).
        func stagedProposalPlan() async throws -> AgentOperationRunner.LintPagePlan {
            try #require(await AgentOperationRunner.makeLintPagePlan(
                store: store, pageID: page.id, stateMarkdown: "# state\n",
                gateInputs: .init(provider: "anthropic", model: "claude-opus", modelRevision: "rev-1", effort: "high"),
                selection: { _ in .stagedProposal(reason: "unevaluated configuration") },
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

        /// Stage a filled run report claiming `repaired` for every finding
        /// (the fabricated-success shape: repair claims with nothing staged
        /// and nothing written).
        func stageFabricatedSuccessReport(for plan: AgentOperationRunner.LintPagePlan) throws {
            let skeleton = LintRunReportText.render(snapshot: plan.snapshot, preflight: plan.preflight)
            let filled = skeleton.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if line == "verification none pending" { return "verification none clean" }
                if line.hasPrefix("finding ") && line.hasSuffix(" pending") {
                    return line.replacingOccurrences(of: " pending", with: " repaired|repaired the defect")
                }
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
        // A clean page's report-only record carries the honest zero — the
        // section it feeds renders "none detected", not absence.
        #expect(record.detail?.contains("findings=0") == true)
        let facts = try #require(LintPageRecordFacts.parse(record: record))
        #expect(facts.findingCount == 0)
        #expect(facts.findings.isEmpty)
    }

    /// The report-only run's findings data (plan §5.13/§5.14): a page with
    /// defects, a run the gate refused to let write — the record carries
    /// every detection with its class label, evidence, and the outcome the
    /// validated report assigned. This is the data the Run Details findings
    /// section renders for the operator.
    @Test func reportOnlyRunCarriesDetectedFindings() async throws {
        let fixture = try Fixture()
        // The defect exists BEFORE the plan scans the page.
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Enforcement", body: Fixture.defectiveBody)
        let runStart = Date()
        // The production gate: unconfigured components select report-only.
        let plan = try #require(await AgentOperationRunner.makeLintPagePlan(
            store: fixture.store, pageID: fixture.page.id, stateMarkdown: "# state\n"))
        #expect(plan.authority.tier == .reportOnly)
        let inspectedHead = try #require(
            try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        let detected = plan.preflight.sections.flatMap(\.findings)
        try #require(detected.isEmpty == false, "the fixture body must produce a finding")
        // Stage the agent's artifacts: findings honestly unresolved (the
        // run may not repair), items and checks valid.
        let skeleton = LintRunReportText.render(snapshot: plan.snapshot, preflight: plan.preflight)
        let filled = skeleton.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line == "verification none pending" { return "verification none clean" }
            if line.hasPrefix("finding ") && line.hasSuffix(" pending") {
                return line.replacingOccurrences(of: " pending", with: " unresolved|the run may not repair")
            }
            if line.hasSuffix(" pending") {
                return line.replacingOccurrences(of: " pending", with: " valid-as-written|recorded")
            }
            return String(line)
        }.joined(separator: "\n")
        try filled.write(
            to: fixture.scratch.appendingPathComponent(AgentStaging.lintRunReportFileName),
            atomically: true, encoding: .utf8)
        _ = try fixture.store.appendLog(
            kind: .lint, title: "Lint — \(plan.snapshot.title)", note: "agent record")

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.detail.contains("findings=\(detected.count)"))
        #expect(outcome.detail.contains(
            "finding=\(detected[0].occurrenceID) \(detected[0].defectClass.rawValue) unresolved"))
        // Nothing was written: the page stays at its inspected head.
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == inspectedHead,
                "a report-only run writes nothing")
        let record = try #require(QueueIngestionReporting
            .lintPageOutcomesMutation([outcome.queueReportOutcome]).targetUpserts.first)
        let facts = try #require(LintPageRecordFacts.parse(record: record))
        #expect(facts.tier == .reportOnly)
        #expect(facts.findingCount == detected.count)
        #expect(facts.findings.count == detected.count)
        #expect(facts.findings[0].classLabel == detected[0].defectClass.rawValue)
        #expect(facts.findings[0].outcomeToken == "unresolved")
        #expect(facts.findings[0].evidence.isEmpty == false)
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

    // MARK: - Tier-2 report semantics (fabricated success)

    /// Round-three R-E: a D27 history-read failure AT ACCOUNTING time —
    /// the written scan's history check reads the parent of the written
    /// head (the inspected head) — fails verification. The guarded
    /// recovery path still runs and discloses honestly: the blocked check
    /// and a successful revert are mutually exclusive by construction (the
    /// revert restores exactly the body the history read could not fetch),
    /// so the posture is failed verification + a failed revert attempt +
    /// breaker evidence — never a clean verdict over a check that could
    /// not run.
    @Test func historyReadFailureAtAccountingFailsVerificationAndRecordsBreaker() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.authorizedPlan()
        try fixture.stageAgentArtifacts(for: plan)
        // The run writes a CLEAN body: the ONLY verification failure is
        // the blocked history check.
        let written = try fixture.agentWrite(
            Fixture.originalBody + "\nOne more clean paragraph.\n")
        // Sabotage the inspected head's body blob — the written scan's D27
        // history read (parent of the written head = the inspected head).
        try Self.deleteBlob(ofVersion: fixture.inspectedHead, in: fixture)

        let outcome = fixture.account(plan, runStart: runStart, producedHead: written)

        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("verification failed"))
        #expect(outcome.detail.contains("unavailable"),
                "the blocked history check is named")
        if case .failed = outcome.revert {
            // The guarded revert attempted and disclosed the failure —
            // never a fake success over unreadable state.
        } else {
            Issue.record("expected an honest failed revert attempt, got \(outcome.revert)")
        }
        #expect(
            fixture.breaker.windowStatus(for: try fixture.breakerKey).verificationFailures == 1,
            "the failed verification is breaker evidence for this configuration")
    }

    /// Delete one version's blob row — the D27 history-read fault: the
    /// history load reads the parent body through the page_versions→blobs
    /// join and reports `.readFailed` instead of throwing.
    private static func deleteBlob(ofVersion versionID: PageVersionID, in fixture: Fixture) throws {
        var db: OpaquePointer?
        let path = fixture.root.appendingPathComponent("WikiFS.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Issue.record("could not open the fixture database for fault injection")
            return
        }
        defer { sqlite3_close(db) }
        // ULIDs are alphanumeric — safe to interpolate.
        let sql = """
        DELETE FROM blobs WHERE hash = (
            SELECT blob_hash FROM page_versions WHERE id = '\(versionID.rawValue)');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            Issue.record("fault-injection statement failed: \(sql)")
            return
        }
    }

    /// A tier-2 run's `.repaired` claims are the CHILD's words: a staging
    /// run may not claim repairs AT ALL — the report is a fabricated
    /// success, coverage FAILS, and the claimed findings stay on the
    /// unresolved list.
    @Test func tier2RepairClaimsWithoutAppliedStagedProposalFailCoverage() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        // The page carries a confirmed finding so the report has a finding
        // line the child can claim repaired.
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Enforcement", body: Fixture.defectiveBody)
        let plan = try await fixture.stagedProposalPlan()
        #expect(plan.authority.tier == .stagedProposal)
        try fixture.stageFabricatedSuccessReport(for: plan)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed, "a fabricated success is a coverage failure")
        #expect(outcome.detail.contains("tier-2 report rejected"))
        #expect(outcome.detail.contains("a staging run may not claim repairs"))
        #expect(outcome.detail.contains("unresolved:"),
                "the claimed findings stay named on the unresolved list")
        // Nothing was written: the page is still at the head the plan
        // inspected.
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id)
            == plan.snapshot.headVersionID)
    }

    /// R-B: even TRUSTED-looking applied records never validate a tier-2
    /// repair claim. A reverted application (`outcome=applied-then-
    /// reverted` — the substring the old predicate matched), ANOTHER
    /// proposal's successful application, and a title-prefix collision
    /// (a different page whose title extends the selected title) each
    /// leave the claims rejected: the claims' truth is the apply path's
    /// own exact records joined by proposal id, not a title-prefix
    /// substring over the audit trail — so the gate rejects the claims
    /// outright instead of consulting them.
    @Test func tier2RepairClaimsStayRejectedWithAnyAppliedRecordPresent() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Enforcement", body: Fixture.defectiveBody)
        let plan = try await fixture.stagedProposalPlan()

        // The adversarial record set: (1) a REVERTED application of this
        // page's proposal; (2) a SUCCESSFUL application of ANOTHER
        // proposal (prop-other); (3) a successful application recorded
        // under a TITLE-PREFIX-COLLIDING page ("Enforcement Two" — the
        // prefix `Lint proposal applied — Enforcement` matches it too).
        // All three titles are reserved to the host, so each looks as
        // trusted as the old predicate required.
        _ = try fixture.store.appendLog(
            kind: .lint,
            title: LintProposalAudit.stagedAuditTitlePrefix + "Enforcement",
            note: LintProposalAudit.stagedNote(
                proposalID: "prop-1", inspectedHead: fixture.inspectedHead,
                bodyFingerprint: "fp", hunkCount: 1))
        _ = try fixture.store.appendLog(
            kind: .lint,
            title: LintProposalAudit.appliedAuditTitlePrefix + "Enforcement",
            note: "proposal_id=prop-1; outcome=applied-then-reverted; "
                + "written_head=x; revert=reverted; verification failed")
        _ = try fixture.store.appendLog(
            kind: .lint,
            title: LintProposalAudit.appliedAuditTitlePrefix + "Enforcement",
            note: "proposal_id=prop-other; outcome=applied; written_head=y")
        _ = try fixture.store.appendLog(
            kind: .lint,
            title: LintProposalAudit.appliedAuditTitlePrefix + "Enforcement Two",
            note: "proposal_id=prop-1; outcome=applied; written_head=z")

        try fixture.stageFabricatedSuccessReport(for: plan)
        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed,
                "no applied record — reverted, unrelated, or colliding — validates the claims")
        #expect(outcome.detail.contains("tier-2 report rejected"))
        #expect(outcome.detail.contains("a staging run may not claim repairs"))
        #expect(outcome.detail.contains("unresolved:"),
                "the claimed findings stay named on the unresolved list")
    }

    /// Round-three R-B: the same fabricated success with every finding ID
    /// RENAMED onto an `item` row (`item D08-1 repaired`). The parser
    /// accepts those rows, and the old combined-set coverage counted the
    /// findings covered while the finding-only rejection missed them —
    /// so tier 2 rejects repair claims through ANY row kind and the
    /// renamed rows no longer cover the findings either.
    @Test func tier2RepairClaimsOnItemRowsStayRejected() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Enforcement", body: Fixture.defectiveBody)
        let plan = try await fixture.stagedProposalPlan()
        #expect(plan.authority.tier == .stagedProposal)

        // The rename: `finding <id> pending` becomes `item <id> repaired`.
        let skeleton = LintRunReportText.render(
            snapshot: plan.snapshot, preflight: plan.preflight)
        let filled = skeleton.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { line -> String in
            if line == "verification none pending" { return "verification none clean" }
            if line.hasPrefix("finding ") && line.hasSuffix(" pending") {
                let id = line.split(separator: " ")[1]
                return "item \(id) repaired|repaired the defect"
            }
            if line.hasSuffix(" pending") {
                return line.replacingOccurrences(of: " pending", with: " valid-as-written|recorded")
            }
            return String(line)
        }.joined(separator: "\n")
        try filled.write(
            to: fixture.scratch.appendingPathComponent(AgentStaging.lintRunReportFileName),
            atomically: true, encoding: .utf8)
        _ = try fixture.store.appendLog(
            kind: .lint, title: "Lint — \(plan.snapshot.title)", note: "agent record")

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed,
                "a repair claim through an item row is still a fabricated success")
        #expect(outcome.detail.contains("tier-2 report rejected"))
        #expect(outcome.detail.contains("a staging run may not claim repairs"))
        #expect(outcome.detail.contains("unresolved:"),
                "the claimed findings stay named on the unresolved list")
        // Nothing was written: the page is still at the head the plan
        // inspected.
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id)
            == plan.snapshot.headVersionID)
    }

    /// The honest tier-2 shape: findings stay `unresolved` (a staging run
    /// repairs nothing), inventory rows are accounted in their own kind,
    /// and nothing claims a repair or a written head. Coverage completes
    /// and the tier-2 gate stays silent.
    @Test func tier2HonestUnresolvedReportIsAccepted() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Enforcement", body: Fixture.defectiveBody)
        let plan = try await fixture.stagedProposalPlan()
        let skeleton = LintRunReportText.render(
            snapshot: plan.snapshot, preflight: plan.preflight)
        let filled = skeleton.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { line -> String in
            if line == "verification none pending" { return "verification none clean" }
            if line.hasPrefix("check ") && line.hasSuffix(" pending") {
                return line.replacingOccurrences(of: " pending", with: " valid-as-written|recorded")
            }
            if line.hasSuffix(" pending") {
                return line.replacingOccurrences(of: " pending", with: " unresolved|staged for review")
            }
            return String(line)
        }.joined(separator: "\n")
        try filled.write(
            to: fixture.scratch.appendingPathComponent(AgentStaging.lintRunReportFileName),
            atomically: true, encoding: .utf8)
        _ = try fixture.store.appendLog(
            kind: .lint, title: "Lint — \(plan.snapshot.title)", note: "agent record")

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .dispatched,
                "an honest staging report is not a failure")
        #expect(outcome.detail.contains("run-report coverage complete"))
        #expect(outcome.detail.contains("tier-2 report rejected") == false)
        // §5.12: the unresolved findings stay named in the host record.
        #expect(outcome.detail.contains("unresolved:"))
    }
}
#endif
