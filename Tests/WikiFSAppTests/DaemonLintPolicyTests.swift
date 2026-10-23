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

    // MARK: - Log append kind conditioning

    /// The log allowance is payload-conditioned for EVERY lint policy: kind
    /// `lint` passes; ingest/query, missing kind, and unreadable payloads
    /// get the generic denial. Raw-frame shapes included.
    @Test func logAppendRequiresLintKind() async throws {
        let lintPolicies = Self.allPolicies.filter(\.isLint)
        #expect(lintPolicies.count == 3)
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
        try await fresh.validateReceipt(runID: runID, token: r1.token)
        // A fabricated token denies.
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(runID: runID, token: "forged")
        }
        // A new read invalidates the old receipt — the old BODY's token can
        // never pass after the head moved (AC.7 staleReceiptCannotReplayBody).
        let r2 = await fresh.issueReceipt(runID: runID, head: head2, bodyFingerprint: "bb")
        #expect(r2.token != r1.token)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(runID: runID, token: r1.token)
        }
        try await fresh.validateReceipt(runID: runID, token: r2.token)
        // A committed patch invalidates the receipt — no replay after a write.
        await fresh.invalidateReceipt(runID: runID)
        await #expect(throws: DaemonLintRunState.LintCASBudgetError.staleReceipt.self) {
            try await fresh.validateReceipt(runID: runID, token: r2.token)
        }
        // A conflict after a fresh receipt demands a NEW receipt before the
        // next patch (tied to the new head + fingerprint).
        #expect(await fresh.recordConflict(runID: runID) == true)
        let r3 = await fresh.issueReceipt(runID: runID, head: head2, bodyFingerprint: "bb")
        try await fresh.validateReceipt(runID: runID, token: r3.token)
    }
}
#endif
