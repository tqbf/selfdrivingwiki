#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

/// W2a §3: the per-run patch budget, enforced by the trusted daemon BEFORE a
/// repair-policy lint patch reaches the store — over the REAL scoped socket.
/// Above the cap the whole patch is rejected (no version lands), the
/// rejection is recorded with its numbers in the run state and the
/// `--kind lint` audit log, and the run's write phase closes. A patch that
/// lands exactly on the cap commits.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// socket round trips carry short timeouts; no sleeps, no blocking waits.
@Suite("Daemon lint patch budget", .serialized, .timeLimit(.minutes(5)))
struct DaemonLintBudgetTests {

    /// One wiki with one clean selected page (floor budget), a repair-policy
    /// run, and the scoped server serving it.
    final class Fixture {
        let container: URL
        let store: GRDBWikiStore
        let descriptor: WikiDescriptor
        let page: WikiPage
        let head: PageVersionID
        let lintRunState = DaemonLintRunState()
        let runID: DaemonRunID
        let client: DaemonDomainSocketClient
        let authorization: DaemonDomainAuthorization
        private let server: DaemonSearchSocketServer

        static let body = "# Target\n\nold text\n"

        init() async throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("dwbudget-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var mutable = WikiDescriptor.make(displayName: "Budget Wiki")
            mutable.lastUsedAt = Date()
            descriptor = mutable
            var diskRegistry = WikiRegistry.load(from: container)
            diskRegistry.add(descriptor)
            try diskRegistry.save(to: container)
            store = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(descriptor.dbFileName, isDirectory: false))
            page = try store.createPage(title: "Budget Target", body: Self.body)
            head = try #require(try store.readPageCoherent(id: page.id).headVersionID)

            let daemon = WikiDaemon(containerDirectory: container)
            let runRegistry = DaemonRunRegistry()
            daemon.queueHostLintRunState = lintRunState
            let registration = try await runRegistry.prepareRun(
                scope: DaemonRunScope(wikiID: descriptor.id),
                operationClasses: [.wikiRead],
                operationPolicy: .lintSelectedPageRepair(pageID: page.id))
            try await runRegistry.activate(runID: registration.runID)
            runID = registration.runID
            let dispatcher = DaemonDomainSocketDispatcher(
                daemon: daemon, runRegistry: runRegistry, lintRunState: lintRunState)
            let listenerRunID = registration.runID
            server = try DaemonSearchSocketServer(containerDirectory: container) { request in
                await dispatcher.handle(request, context: .scopedRun(listenerRunID))
            }
            try server.start()
            client = try DaemonDomainSocketClient(containerDirectory: container, timeout: 10)
            authorization = DaemonDomainAuthorization(capability: registration.capability.printable)
        }

        func stop() {
            server.stop()
            do {
                try FileManager.default.removeItem(at: container)
            } catch {
                // Temp cleanup only; each fixture owns a unique directory.
            }
        }

        /// A fresh selected-page JSON read: mints the receipt (and, the
        /// first time, fixes the run's patch budget).
        func mintReceipt() async throws -> String {
            let reply = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.get,
                payload: try JSONEncoder().encode(DaemonPageGetRequest(
                    wikiID: descriptor.id.rawValue,
                    selector: DaemonCommandSelector(id: page.id.rawValue),
                    json: true,
                    workspace: nil)),
                authorization: authorization)
            let outcome = try DaemonCommandOutcome.decode(reply.payload)
            let pageJSON = try #require(
                JSONSerialization.jsonObject(with: Data((outcome.text ?? "").utf8)) as? [String: Any])
            return try #require(pageJSON["lint_receipt"] as? String)
        }

        /// Replace "old text" (bytes 10..<18) with `newText`.
        func patch(receipt: String, newText: String) async throws -> DaemonDomainReply {
            try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.patch,
                payload: try JSONEncoder().encode(DaemonPagePatchRequest(
                    wikiID: descriptor.id.rawValue,
                    id: page.id.rawValue,
                    expectHead: head.rawValue,
                    hunks: [DaemonPagePatchRequest.WireHunk(
                        defect: "D25", startByte: 10, endByte: 18,
                        oldText: "old text", newText: newText,
                        reason: "repair the defect")],
                    author: "agent:lint",
                    lintReceipt: receipt)),
                authorization: authorization)
        }
    }

    /// The replaced span ("old text") counts toward changed bytes.
    static let replacedSpanBytes = 8

    @Test("an oversized patch is rejected whole and recorded")
    func oversizedPatchRejectedWhole() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()
        let budget = await fixture.lintRunState.budget(runID: fixture.runID)
        #expect(budget == LintPatchBudget(confirmedRepairableFindings: 0),
                "a clean inspected page gets the floor budget")

        let oversized = String(
            repeating: "x", count: budget.maxChangedBytes - Self.replacedSpanBytes + 1)
        do {
            _ = try await fixture.patch(receipt: receipt, newText: oversized)
            Issue.record("a patch over the run's budget must be rejected")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("budget_exceeded"))
            #expect(error.message.contains("run cap \(budget.maxHunks) hunks / \(budget.maxChangedBytes) bytes"))
        }

        // No page version was created; the body is untouched.
        let read = try fixture.store.readPageCoherent(id: fixture.page.id)
        #expect(read.headVersionID == fixture.head)
        #expect(read.body == Fixture.body)
        #expect(await fixture.lintRunState.latestVerificationRecord(pageID: fixture.page.id) == nil)

        // The rejection is recorded with its numbers in the run state…
        let rejection = try #require(await fixture.lintRunState.budgetRejection(runID: fixture.runID))
        #expect(rejection.pageID == fixture.page.id)
        #expect(rejection.rejection.requested == LintPatchBudget.Usage(
            hunks: 1, changedBytes: budget.maxChangedBytes + 1))
        #expect(await fixture.lintRunState.latestBudgetRejection(pageID: fixture.page.id) == rejection)
        // …and in the trusted `--kind lint` audit log.
        let audit = try #require(try fixture.store.recentLogEntries(limit: 20).first {
            $0.title == LintPatchBudget.auditTitlePrefix + "Budget Target"
        })
        #expect(audit.kind == .lint)
        #expect(audit.note == rejection.rejection.summary)

        // The write phase is closed: even a small patch with a fresh receipt
        // denies, so splitting the change cannot get around the cap.
        #expect(await fixture.lintRunState.isClosed(runID: fixture.runID))
        let fresh = try await fixture.mintReceipt()
        do {
            _ = try await fixture.patch(receipt: fresh, newText: "new text")
            Issue.record("a closed run must not commit another patch")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).headVersionID == fixture.head)
    }

    @Test("a patch exactly at the cap commits")
    func patchExactlyAtTheCapCommits() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()
        let budget = await fixture.lintRunState.budget(runID: fixture.runID)
        let atCap = String(repeating: "x", count: budget.maxChangedBytes - Self.replacedSpanBytes)

        let reply = try await fixture.patch(receipt: receipt, newText: atCap)

        #expect(reply.error == nil, "the at-cap patch must commit: \(reply.error?.message ?? "")")
        let read = try fixture.store.readPageCoherent(id: fixture.page.id)
        #expect(read.headVersionID != fixture.head)
        #expect(read.body.contains(atCap))
        #expect(await fixture.lintRunState.spent(runID: fixture.runID)
            == LintPatchBudget.Usage(hunks: 1, changedBytes: budget.maxChangedBytes))
        #expect(await fixture.lintRunState.budgetRejection(runID: fixture.runID) == nil)
    }

    // MARK: - Run-state bookkeeping

    /// The budget is fixed at the first mint, spend accumulates, a rejection
    /// closes the run, and teardown keeps the rejection + accounted outcome
    /// for the queue host's after-the-run lookup.
    @Test func runStateBudgetBookkeeping() async throws {
        let state = DaemonLintRunState()
        let runID = DaemonRunID(rawValue: "run-budget")
        let pageID = PageID(rawValue: "01HZPAGE00000000000000000D")
        #expect(await state.budget(runID: runID) == LintPatchBudget(confirmedRepairableFindings: 0))
        await state.setBudgetIfAbsent(runID: runID, budget: LintPatchBudget(maxHunks: 2, maxChangedBytes: 10))
        await state.setBudgetIfAbsent(runID: runID, budget: LintPatchBudget(maxHunks: 99, maxChangedBytes: 999))
        #expect(await state.budget(runID: runID) == LintPatchBudget(maxHunks: 2, maxChangedBytes: 10))

        await state.recordSpend(runID: runID, usage: .init(hunks: 1, changedBytes: 6))
        #expect(await state.checkBudget(runID: runID, request: .init(hunks: 1, changedBytes: 4)) == .withinBudget)
        guard case .exceeded(let rejection) = await state.checkBudget(
            runID: runID, request: .init(hunks: 1, changedBytes: 5)) else {
            Issue.record("6 + 5 bytes must exceed a 10-byte cap")
            return
        }
        await state.recordBudgetRejection(runID: runID, pageID: pageID, rejection: rejection)
        #expect(await state.isClosed(runID: runID))

        let authority = LintRepairAuthority.shippedApproval(LintApprovalID(rawValue: "row-1"))
            .demoted(to: .budgetExceeded, reason: rejection.summary)
        await state.recordAccountedOutcome(DaemonLintAccountedOutcome(
            pageID: pageID, authority: authority, revert: nil, recordedAt: Date()))

        await state.forget(runID: runID)
        #expect(await state.latestBudgetRejection(pageID: pageID)?.rejection == rejection)
        let accounted = try #require(await state.latestAccountedOutcome(pageID: pageID))
        #expect(accounted.authority.tier == .budgetExceeded)
        #expect(accounted.authority.approvalID == LintApprovalID(rawValue: "row-1"))
        #expect(await state.spent(runID: runID) == .zero)
    }
}
#endif
