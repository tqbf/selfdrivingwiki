#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
@testable import wikid

/// AC.5 narrow-authority policy tests: the four managed-run policies and
/// their operation matrix. A lint run reads its wiki and appends lint logs;
/// EVERY content mutation denies generically — including through raw frames
/// with extra fields, missing kinds, and unreadable payloads. The `page
/// patch` seam joins this matrix with its selected-page identity check in
/// Phase 3.
@Suite("Daemon lint policy", .timeLimit(.minutes(2)))
struct DaemonLintPolicyTests {

    private let wikiID = WikiID(rawValue: "01HZLINTWIKI0000000000000000A")
    private let selectedPage = PageID(rawValue: "01HZLINTPAGE00000000000000001")

    private struct Fixture {
        let registry = DaemonRunRegistry()
        let guardInstance: DaemonScopedRequestGuard
        let runID: DaemonRunID
        let capability: String

        init(policy: ManagedRunPolicy) async throws {
            let registry = self.registry
            let wikiID = Self.wikiIDValue
            self.guardInstance = DaemonScopedRequestGuard(
                registry: registry,
                assignedWiki: { _ in WikiDescriptor.make(displayName: "Lint Wiki") },
                queueItemOwningWiki: { _ in nil })
            let classes: Set<DaemonRunOperationClass> =
                policy.isLint ? [.wikiRead] : DaemonScopedRunLeaseManager.managedRunOperationClasses
            let registration = try await registry.prepareRun(
                scope: DaemonRunScope(wikiID: wikiID),
                operationClasses: classes,
                operationPolicy: policy)
            try await registry.activate(runID: registration.runID)
            self.runID = registration.runID
            self.capability = registration.capability.printable
        }

        static let wikiIDValue = WikiID(rawValue: "01HZLINTWIKI0000000000000000A")

        /// A scoped request shaped exactly like the child's raw frame.
        func request(
            family: DaemonDomainFamily,
            operation: String,
            payloadJSON: String? = nil,
            withAuthorization: Bool = true
        ) -> DaemonDomainRequest {
            DaemonDomainRequest(
                requestID: UUID().uuidString,
                family: family,
                operation: operation,
                payload: payloadJSON.map { Data($0.utf8) },
                authorization: withAuthorization ? DaemonDomainAuthorization(capability: capability) : nil)
        }

        func allowed(_ request: DaemonDomainRequest) async -> Bool {
            (try? await guardInstance.evaluate(request, listenerRunID: runID)) != nil
        }
    }

    private func makeWikiPayload() -> String {
        #"{"wikiID":"\#(Fixture.wikiIDValue.rawValue)"}"#
    }

    private func logPayload(kind: String) -> String {
        #"{"wikiID":"\#(Fixture.wikiIDValue.rawValue)","kind":"\#(kind)","title":"t","note":null,"source":null,"author":null}"#
    }

    private static let allPolicies: [ManagedRunPolicy] = [
        .ordinaryManaged,
        .lintSelectedPageRepair(pageID: PageID(rawValue: "01HZLINTPAGE00000000000000001")),
        .lintSelectedPageReportOnly(pageID: PageID(rawValue: "01HZLINTPAGE00000000000000001")),
        .lintSelectedPageProposal(pageID: PageID(rawValue: "01HZLINTPAGE00000000000000001")),
        .lintWholeWikiReportOnly,
    ]

    /// The policy survives registration → lease → grant, unchanged, and the
    /// grant the dispatcher receives carries it.
    @Test func policyFlowsThroughLeaseAndGrant() async throws {
        for policy in Self.allPolicies {
            let fixture = try await Fixture(policy: policy)
            let grant = try await fixture.guardInstance.evaluate(
                fixture.request(family: .page, operation: DaemonDomainOperation.Page.get, payloadJSON: makeWikiPayload()),
                listenerRunID: fixture.runID)
            #expect(grant.operationPolicy == policy)
            #expect(grant.runID == fixture.runID)

            let lease = try #require(await fixture.registry.lease(for: fixture.runID))
            #expect(lease.operationPolicy == policy)
        }
    }

    /// The number of lint policy kinds — the log-kind test iterates all of
    /// them, so adding a fifth lint shape updates this pin deliberately.
    @Test func lintPolicyKindsArePinned() {
        #expect(Self.allPolicies.filter(\.isLint).count == 4)
    }

    // MARK: - Receipt lifecycle semantics (plan §5.8 wiring)

    /// The wired semantics the dispatcher relies on: a selected-page JSON
    /// read mints a receipt bound to head+fingerprint; the patch validates
    /// the CURRENT token; a commit kills it; two conflicts close the run.
    /// `mintReceipt` is the dispatcher's payload post-processor — same
    /// computation, no daemon needed.
    @Test func receiptLifecycleMintValidateInvalidateClose() async throws {
        let fixture = try await Fixture(
            policy: .lintSelectedPageRepair(pageID: selectedPage))
        let state = DaemonLintRunState()

        // The payload post-processor mints only from a `page get --json`
        // shape and injects the token.
        let payloadJSON = ##"{"body_markdown":"# Body\n","head_version_id":"01HZHEAD00000000000000000001"}"##
        let payload = Data(payloadJSON.utf8)
        let minted = await DaemonDomainSocketDispatcher.mintReceipt(
            into: payload, runID: fixture.runID,
            selectedPage: selectedPage, lintRunState: state)
        let mintedData = try #require(minted)
        let mintedObject = try #require(
            JSONSerialization.jsonObject(with: mintedData) as? [String: Any])
        let token = try #require(mintedObject["lint_receipt"] as? String)

        // The current receipt validates; the minted fingerprint is the body's.
        let current = await state.currentReceipt(runID: fixture.runID)
        #expect(current?.token == token)
        #expect(current?.bodyFingerprint == LintPageSnapshot.fingerprint(of: "# Body\n"))
        await #expect(throws: Never.self) {
            try await state.validateReceipt(
                runID: fixture.runID, token: token,
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000001"))
        }
        // A receipt minted from H1 cannot authorize hunks against H2 (M4).
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.self) {
            try await state.validateReceipt(
                runID: fixture.runID, token: token,
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000002"))
        }
        // A stale/fabricated token throws.
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.self) {
            try await state.validateReceipt(
                runID: fixture.runID, token: "forged",
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000001"))
        }
        // A commit kills the receipt — the old token can never replay.
        await state.invalidateReceipt(runID: fixture.runID)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.self) {
            try await state.validateReceipt(
                runID: fixture.runID, token: token,
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000001"))
        }

        // Review M4: a conflict also kills the receipt — after the head
        // moves, the old body is gone and the recomposition needs a fresh
        // minting read. Exercised on a FRESH state so the budget-closure
        // assertions below stay exact.
        let conflictState = DaemonLintRunState()
        let conflictRun = DaemonRunID(rawValue: "run-m4")
        let reminted = await conflictState.issueReceipt(
            runID: conflictRun,
            head: PageVersionID(rawValue: "01HZHEAD00000000000000000002"),
            bodyFingerprint: "fp2")
        await #expect(throws: Never.self) {
            try await conflictState.validateReceipt(
                runID: conflictRun, token: reminted.token,
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000002"))
        }
        _ = await conflictState.recordConflict(runID: conflictRun)
        await conflictState.invalidateReceipt(runID: conflictRun)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.self) {
            try await conflictState.validateReceipt(
                runID: conflictRun, token: reminted.token,
                expectedHead: PageVersionID(rawValue: "01HZHEAD00000000000000000002"))
        }

        // The conflict budget: one recomposition allowed, the second closes.
        #expect(await state.recordConflict(runID: fixture.runID) == true)
        #expect(await state.recordConflict(runID: fixture.runID) == false)
        #expect(await state.isClosed(runID: fixture.runID))
    }

    // MARK: - The exhaustive operation matrix

    /// All four policy kinds × the operation families that matter: lint runs
    /// read and append lint logs only; ordinary managed keeps the initial
    /// policy. Unknown operations fail closed under every policy.
    @Test func exhaustiveOperationMatrix() async throws {
        let wiki = makeWikiPayload()

        for policy in Self.allPolicies {
            let fixture = try await Fixture(policy: policy)
            let isLint = policy.isLint

            func expect(
                _ allowedExpected: Bool,
                _ family: DaemonDomainFamily,
                _ operation: String,
                _ label: String,
                payloadJSON: String? = wiki
            ) async {
                let allowed = await fixture.allowed(
                    fixture.request(family: family, operation: operation, payloadJSON: payloadJSON))
                #expect(allowed == allowedExpected, "\(policy): \(label)")
            }

            // Reads — allowed under EVERY policy (lint included).
            await expect(true, .page, DaemonDomainOperation.Page.get, "page get must be allowed")
            await expect(true, .page, DaemonDomainOperation.Page.list, "page list must be allowed")
            await expect(true, .page, DaemonDomainOperation.Page.history, "page history must be allowed")
            await expect(true, .source, DaemonDomainOperation.Source.cat, "source cat must be allowed")
            await expect(true, .strategy, DaemonDomainOperation.Strategy.read, "strategy read must be allowed")

            // Content mutations — lint denies generically; ordinary allows.
            await expect(!isLint, .page, DaemonDomainOperation.Page.add, "page add allowance")
            await expect(!isLint, .page, DaemonDomainOperation.Page.delete, "page delete allowance")
            await expect(!isLint, .page, DaemonDomainOperation.Page.revert, "page revert allowance")
            await expect(!isLint, .page, DaemonDomainOperation.Page.okfCorrect, "OKF write allowance")
            await expect(!isLint, .source, DaemonDomainOperation.Source.editMarkdown, "source write allowance")
            await expect(!isLint, .source, DaemonDomainOperation.Source.rename, "source rename allowance")
            await expect(!isLint, .source, DaemonDomainOperation.Source.addURL, "source acquisition allowance")
            await expect(!isLint, .strategy, DaemonDomainOperation.Strategy.save, "strategy write allowance")
            await expect(!isLint, .bookmark, DaemonDomainOperation.Bookmark.createFolder, "bookmark write allowance")
            await expect(!isLint, .workspace, DaemonDomainOperation.Workspace.create, "workspace alternative write path allowance")
            await expect(!isLint, .log, DaemonDomainOperation.Log.indexSet, "index set (shared log family) allowance")
            await expect(!isLint, .queue, DaemonDomainOperation.Queue.enqueueItem, "queue enqueue allowance")

            // Denied under EVERY policy.
            await expect(false, .queue, DaemonDomainOperation.Queue.pauseQueue, "global queue controls deny")
            await expect(false, .wiki, DaemonDomainOperation.Wiki.createWiki, "registry mutation denies")
            await expect(false, .source, DaemonDomainOperation.Source.export, "scoped source export denies")

            // Unknown operation — fails closed under every policy.
            await expect(false, .page, "futureMutation", "unknown operations fail closed")
        }
    }

    /// The patch seam: the selected-page REPAIR policy may patch ONLY its
    /// selected page (identity resolved daemon-side from the payload);
    /// report-only policies never patch; whole-wiki runs never patch; a
    /// patch with an unreadable or missing id denies.
    @Test func patchRequiresSelectedPageIdentity() async throws {
        let selected = PageID(rawValue: "01HZLINTPAGE00000000000000001")
        let other = PageID(rawValue: "01HZLINTPAGE00000000000000002")

        func patchPayload(pageID: PageID?) -> String {
            let id = pageID?.rawValue ?? "01HZLINTPAGE00000000000000009"
            return """
            {"wikiID":"\(Fixture.wikiIDValue.rawValue)","id":"\(id)","expectHead":"01HZHEAD00000000000000000001","hunks":[{"defect":"D25","startByte":0,"endByte":3,"oldText":"```","newText":"","reason":"unwrap"}],"author":"agent:lint"}
            """
        }

        // Repair policy: selected page passes; any other page denies.
        let repair = try await Fixture(policy: .lintSelectedPageRepair(pageID: selected))
        #expect(await repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: selected))),
            "the repair run may patch exactly its selected page")
        #expect(await !repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: other))),
            "a patch against ANY other page must deny")
        #expect(await !repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: nil))),
            "an unreadable patch payload must deny")

        // Report-only policies: the same selected-page patch denies.
        for policy in [
            ManagedRunPolicy.lintSelectedPageReportOnly(pageID: selected),
            .lintWholeWikiReportOnly,
        ] {
            let fixture = try await Fixture(policy: policy)
            #expect(await !fixture.allowed(fixture.request(
                family: .page, operation: DaemonDomainOperation.Page.patch,
                payloadJSON: patchPayload(pageID: selected))),
                "\(policy): report-only runs never patch")
        }

        // Ordinary managed runs may patch (it is a wikiEdit operation).
        let ordinary = try await Fixture(policy: .ordinaryManaged)
        #expect(await ordinary.allowed(ordinary.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: other))),
            "ordinary managed runs keep the edit class for patches")
    }

    /// The proposal seam (W5a tier 2): the selected-page PROPOSAL policy may
    /// stage against ONLY its selected page; `page patch` denies (staging is
    /// not writing); the tier-1 REPAIR policy never proposes; report-only
    /// and whole-wiki runs do neither; an unreadable or other-page payload
    /// denies.
    @Test func proposeRequiresSelectedPageIdentityAndNeverPatches() async throws {
        let selected = PageID(rawValue: "01HZLINTPAGE00000000000000001")
        let other = PageID(rawValue: "01HZLINTPAGE00000000000000002")

        func proposePayload(pageID: PageID?) -> String {
            let id = pageID?.rawValue ?? "01HZLINTPAGE00000000000000009"
            return """
            {"wikiID":"\(Fixture.wikiIDValue.rawValue)","id":"\(id)","expectHead":"01HZHEAD00000000000000000001","hunks":[{"defect":"D25","startByte":0,"endByte":3,"oldText":"```","newText":"","reason":"unwrap"}],"author":"agent:lint"}
            """
        }

        func patchPayload(pageID: PageID?) -> String {
            var payload = proposePayload(pageID: pageID)
            // Same shape; only the operation differs (the guard reads `id`).
            payload.reserveCapacity(payload.count)
            return payload
        }

        // Proposal policy: selected-page propose passes; any other page, an
        // unreadable payload, and a patch attempt all deny.
        let proposal = try await Fixture(policy: .lintSelectedPageProposal(pageID: selected))
        #expect(await proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposePayload(pageID: selected))),
            "the proposal run may stage exactly its selected page")
        #expect(await !proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposePayload(pageID: other))),
            "a proposal against ANY other page must deny")
        #expect(await !proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposePayload(pageID: nil))),
            "an unreadable propose payload must deny")
        #expect(await !proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: selected))),
            "a proposal run never patches — staged hunks are held, not written")

        // Tier-1 repair policy: patches its page, never proposes.
        let repair = try await Fixture(policy: .lintSelectedPageRepair(pageID: selected))
        #expect(await repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: selected))),
            "the repair run keeps its patch seam")
        #expect(await !repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposePayload(pageID: selected))),
            "a tier-1 run cannot propose — the child cannot widen or swap its tier")

        // Report-only and whole-wiki: neither seam.
        for policy in [
            ManagedRunPolicy.lintSelectedPageReportOnly(pageID: selected),
            .lintWholeWikiReportOnly,
        ] {
            let fixture = try await Fixture(policy: policy)
            #expect(await !fixture.allowed(fixture.request(
                family: .page, operation: DaemonDomainOperation.Page.proposePatch,
                payloadJSON: proposePayload(pageID: selected))),
                "\(policy): report-only runs never propose")
            #expect(await !fixture.allowed(fixture.request(
                family: .page, operation: DaemonDomainOperation.Page.patch,
                payloadJSON: patchPayload(pageID: selected))),
                "\(policy): report-only runs never patch")
        }

        // Ordinary managed runs patch (wikiEdit) but never propose (the op
        // has no class-table entry — it is a managed-lint seam only).
        let ordinary = try await Fixture(policy: .ordinaryManaged)
        #expect(await ordinary.allowed(ordinary.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchPayload(pageID: other))),
            "ordinary managed runs keep the edit class for patches")
        #expect(await !ordinary.allowed(ordinary.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposePayload(pageID: other))),
            "propose-patch is not an ordinary-run operation")
    }

    /// The child cannot choose its policy: an argv/env-like marker inside the
    /// payload must not select the proposal policy for a tier-1 run or vice
    /// versa — the policy arrives only through the trusted coordinator's
    /// lease, and the guard consults the LEASE's policy, never the payload.
    @Test func payloadCannotSelectProposalPolicy() async throws {
        let selected = PageID(rawValue: "01HZLINTPAGE00000000000000001")
        // A tier-1 repair lease carrying a tier-2-styled payload ( proposing)
        // still only patches; a tier-2 lease carrying a patch-shaped payload
        // still only proposes.
        let repair = try await Fixture(policy: .lintSelectedPageRepair(pageID: selected))
        let proposal = try await Fixture(policy: .lintSelectedPageProposal(pageID: selected))
        let proposeBody = """
        {"wikiID":"\(Fixture.wikiIDValue.rawValue)","id":"\(selected.rawValue)","expectHead":"01HZHEAD00000000000000000001","hunks":[{"defect":"D25","startByte":0,"endByte":3,"oldText":"```","newText":"","reason":"unwrap"}],"policy":"lintSelectedPageProposal"}
        """
        let patchBody = """
        {"wikiID":"\(Fixture.wikiIDValue.rawValue)","id":"\(selected.rawValue)","expectHead":"01HZHEAD00000000000000000001","hunks":[{"defect":"D25","startByte":0,"endByte":3,"oldText":"```","newText":"","reason":"unwrap"}],"policy":"lintSelectedPageRepair"}
        """
        #expect(await !repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposeBody)),
            "a policy-naming payload cannot give a tier-1 run the proposal seam")
        #expect(await repair.allowed(repair.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchBody)),
            "the tier-1 run's patch seam is unchanged by payload markers")
        #expect(await !proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.patch,
            payloadJSON: patchBody)),
            "a policy-naming payload cannot give a tier-2 run the patch seam")
        #expect(await proposal.allowed(proposal.request(
            family: .page, operation: DaemonDomainOperation.Page.proposePatch,
            payloadJSON: proposeBody)),
            "the tier-2 run's propose seam is unchanged by payload markers")
    }

    // MARK: - Log append kind conditioning

    /// The log allowance is payload-conditioned for EVERY lint policy: kind
    /// `lint` passes; ingest/query, missing kind, and unreadable payloads
    /// get the generic denial. Raw-frame shapes included.
    @Test func logAppendRequiresLintKind() async throws {
        let lintPolicies = Self.allPolicies.filter(\.isLint)
        #expect(lintPolicies.count == 4)
        for policy in lintPolicies {
            let fixture = try await Fixture(policy: policy)

            func logAllowed(payloadJSON: String?) async -> Bool {
                await fixture.allowed(fixture.request(
                    family: .log,
                    operation: DaemonDomainOperation.Log.logAppend,
                    payloadJSON: payloadJSON))
            }

            #expect(await logAllowed(payloadJSON: logPayload(kind: "lint")),
                    "\(policy): a lint-kind log append must pass")
            #expect(await !logAllowed(payloadJSON: logPayload(kind: "ingest")),
                    "\(policy): an ingest-kind log append must deny")
            #expect(await !logAllowed(payloadJSON: logPayload(kind: "query")),
                    "\(policy): a query-kind log append must deny")
            // Raw-frame shapes: extra fields must not sneak a non-lint kind
            // past the minimal decode; a missing or unreadable kind denies.
            #expect(await !logAllowed(payloadJSON:
                #"{"wikiID":"\#(Fixture.wikiIDValue.rawValue)","title":"t","kind":"ingest","padding":1}"#),
                "\(policy): extra payload fields must not widen the log allowance")
            #expect(await !logAllowed(payloadJSON: #"{"wikiID":"\#(Fixture.wikiIDValue.rawValue)","title":"no kind"}"#),
                    "\(policy): a log append without a kind must deny")
            #expect(await !logAllowed(payloadJSON: #"not json at all"#),
                    "\(policy): an unreadable log payload must deny")
            #expect(await !logAllowed(payloadJSON: nil),
                    "\(policy): a log append without a payload must deny")
        }
    }

    // MARK: - Reserved host audit titles (child forgery)

    /// Host accounting trusts `--kind lint` records by their titles (the
    /// staged reference, the apply outcome, the budget rejection). The child
    /// controls its log-append payload's title, so a title claiming one of
    /// those host record shapes denies generically — while a legitimate
    /// child audit entry (any non-reserved title) still passes.
    @Test func logAppendRejectsReservedHostTitles() async throws {
        for policy in Self.allPolicies.filter(\.isLint) {
            let fixture = try await Fixture(policy: policy)

            func logAllowed(title: String) async -> Bool {
                await fixture.allowed(fixture.request(
                    family: .log,
                    operation: DaemonDomainOperation.Log.logAppend,
                    payloadJSON: """
                    {"wikiID":"\(Fixture.wikiIDValue.rawValue)","kind":"lint",\
                    "title":"\(title)","note":null,"source":null,"author":null}
                    """))
            }

            // Each reserved host prefix is denied in full — the forged
            // suffix (a page title, a proposal id) cannot launder it.
            #expect(await !logAllowed(title: LintPatchBudget.auditTitlePrefix + "Forged Page"),
                    "\(policy): a forged budget-rejection title must deny")
            #expect(await !logAllowed(title: LintProposalAudit.stagedAuditTitlePrefix + "Forged Page"),
                    "\(policy): a forged staged-proposal title must deny")
            #expect(await !logAllowed(title: LintProposalAudit.appliedAuditTitlePrefix + "Forged Page"),
                    "\(policy): a forged applied-outcome title must deny")

            // Legitimate child audit entries keep the allowance: any title
            // that does not claim a host record shape passes.
            #expect(await logAllowed(title: "Agent run notes — Forged Page"),
                    "\(policy): a non-reserved lint title must still pass")
            #expect(await logAllowed(title: "lint proposal staged"), 
                    "\(policy): a near-miss title (no trailing host prefix) must pass")
        }
    }

    // MARK: - Policy immutability

    /// Renewal keeps the lease's policy: a lint lease never widens, and no
    /// missing-policy fallback grants broad wikiEdit (plan Phase 2.7).
    @Test func policyImmutableAcrossRenewals() async throws {
        let fixture = try await Fixture(policy: .lintSelectedPageRepair(pageID: selectedPage))
        try await fixture.registry.renew(runID: fixture.runID)
        let lease = try #require(await fixture.registry.lease(for: fixture.runID))
        #expect(lease.operationPolicy == .lintSelectedPageRepair(pageID: selectedPage))
        #expect(lease.operationClasses == [.wikiRead],
                "lint leases never gain broad wikiEdit as a compatibility fallback")
    }

    /// The manager maps lint policies to READ-ONLY classes while ordinary
    /// managed keeps the initial three.
    @Test func operationClassesDeriveFromPolicy() {
        #expect(DaemonScopedRunLeaseManager.operationClasses(for: .ordinaryManaged)
            == DaemonScopedRunLeaseManager.managedRunOperationClasses)
        #expect(DaemonScopedRunLeaseManager.operationClasses(for: .lintWholeWikiReportOnly) == [.wikiRead])
        #expect(DaemonScopedRunLeaseManager.operationClasses(
            for: .lintSelectedPageRepair(pageID: selectedPage)) == [.wikiRead])
        #expect(DaemonScopedRunLeaseManager.operationClasses(
            for: .lintSelectedPageReportOnly(pageID: selectedPage)) == [.wikiRead])
        #expect(DaemonScopedRunLeaseManager.operationClasses(
            for: .lintSelectedPageProposal(pageID: selectedPage)) == [.wikiRead],
            "the proposal lease is read-only too — staging is an allowance, never a class")
    }

    // MARK: - Per-run CAS budget (plan Phase 2.8)

    /// One conflict allows recomposition; a second closes the run; a stale
    /// receipt can never replay an old body after the head moved.
    @Test func casBudgetAndReceipts() async throws {
        let state = DaemonLintRunState()
        let runID = DaemonRunID(rawValue: "run-1")
        let head1 = PageVersionID(rawValue: "01HZHEAD00000000000000000001")
        let head2 = PageVersionID(rawValue: "01HZHEAD00000000000000000002")

        // First conflict → recomposition allowed; second → run closed.
        #expect(await state.recordConflict(runID: runID) == true)
        #expect(await state.recordConflict(runID: runID) == false)
        #expect(await state.isClosed(runID: runID))

        // Fresh state: receipt lifecycle.
        let fresh = DaemonLintRunState()
        let r1 = await fresh.issueReceipt(runID: runID, head: head1, bodyFingerprint: "aa")
        try await fresh.validateReceipt(
            runID: runID, token: r1.token, expectedHead: head1)
        // A fabricated token denies.
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(
                runID: runID, token: "forged", expectedHead: head1)
        }
        // Review M4: a receipt minted from head1 cannot authorize hunks
        // declared against head2 — token AND head must both match.
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(
                runID: runID, token: r1.token, expectedHead: head2)
        }
        // A new read invalidates the old receipt — the old BODY's token can
        // never pass after the head moved (AC.7 staleReceiptCannotReplayBody).
        let r2 = await fresh.issueReceipt(runID: runID, head: head2, bodyFingerprint: "bb")
        #expect(r2.token != r1.token)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(runID: runID, token: r1.token, expectedHead: head2)
        }
        try await fresh.validateReceipt(runID: runID, token: r2.token, expectedHead: head2)
        // A committed patch invalidates the receipt — no replay after a write.
        await fresh.invalidateReceipt(runID: runID)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(runID: runID, token: r2.token, expectedHead: head2)
        }
        // A conflict after a fresh receipt demands a NEW receipt before the
        // next patch (tied to the new head + fingerprint).
        #expect(await fresh.recordConflict(runID: runID) == true)
        let r3 = await fresh.issueReceipt(runID: runID, head: head2, bodyFingerprint: "bb")
        try await fresh.validateReceipt(runID: runID, token: r3.token, expectedHead: head2)
    }
}
#endif
