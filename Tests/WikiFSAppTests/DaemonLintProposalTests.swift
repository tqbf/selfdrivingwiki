#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

/// W5a tier 2: `page propose-patch` staging, enforced by the trusted daemon
/// over the REAL scoped socket. The daemon validates the hunks with the SAME
/// rules the store applies to a patch, enforces the SAME per-run budget
/// (a rejection closes the run + writes the audit entry), requires the
/// CURRENT receipt, and then STAGES — never writes. At most one staged
/// proposal per page per run.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// socket round trips carry short timeouts; no sleeps, no blocking waits.
@Suite("Daemon lint staged proposals", .serialized, .timeLimit(.minutes(5)))
struct DaemonLintProposalTests {

    /// One wiki with one selected page, a PROPOSAL-policy run, and the
    /// scoped server serving it.
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

        init(policy: ManagedRunPolicy? = nil) async throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("dwpropose-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var mutable = WikiDescriptor.make(displayName: "Proposal Wiki")
            mutable.lastUsedAt = Date()
            descriptor = mutable
            var diskRegistry = WikiRegistry.load(from: container)
            diskRegistry.add(descriptor)
            try diskRegistry.save(to: container)
            store = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(descriptor.dbFileName, isDirectory: false))
            page = try store.createPage(title: "Proposal Target", body: Self.body)
            head = try #require(try store.readPageCoherent(id: page.id).headVersionID)

            let daemon = WikiDaemon(containerDirectory: container)
            let runRegistry = DaemonRunRegistry()
            daemon.queueHostLintRunState = lintRunState
            let registration = try await runRegistry.prepareRun(
                scope: DaemonRunScope(wikiID: descriptor.id),
                operationClasses: [.wikiRead],
                operationPolicy: policy ?? .lintSelectedPageProposal(pageID: page.id))
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

        /// Propose replacing "old text" (bytes 10..<18) with `newText`.
        func propose(
            receipt: String, newText: String, expectHead: PageVersionID? = nil,
            oldText: String = "old text"
        ) async throws -> DaemonDomainReply {
            try await propose(
                receipt: receipt, expectHead: expectHead,
                hunks: [DaemonPagePatchRequest.WireHunk(
                    defect: "D25", startByte: 10, endByte: 18,
                    oldText: oldText, newText: newText,
                    reason: "repair the defect")])
        }

        /// A proposal whose exact wire hunks the caller controls — the
        /// extreme-offset tests need raw numbers, not the standard
        /// replacement.
        func propose(
            receipt: String, expectHead: PageVersionID? = nil,
            hunks: [DaemonPagePatchRequest.WireHunk]
        ) async throws -> DaemonDomainReply {
            try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.proposePatch,
                payload: try JSONEncoder().encode(DaemonPageProposePatchRequest(
                    wikiID: descriptor.id.rawValue,
                    id: page.id.rawValue,
                    expectHead: (expectHead ?? head).rawValue,
                    hunks: hunks,
                    author: "agent:lint",
                    lintReceipt: receipt)),
                authorization: authorization)
        }

        /// The staged reply's `key\tvalue` lines.
        static func stagedFields(_ reply: DaemonDomainReply) throws -> [String: String] {
            let outcome = try DaemonCommandOutcome.decode(reply.payload)
            var fields: [String: String] = [:]
            for line in (outcome.text ?? "").split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            return fields
        }
    }

    // MARK: - Happy path

    @Test("a valid proposal stages, persists, and writes nothing")
    func validProposalStagesWithoutWriting() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()

        let reply = try await fixture.propose(receipt: receipt, newText: "new text")
        #expect(reply.error == nil, "the proposal must stage: \(reply.error?.message ?? "")")
        let fields = try Fixture.stagedFields(reply)
        #expect(fields["staged"]?.isEmpty == false)
        #expect(fields["page"] == fixture.page.id.rawValue)
        #expect(fields["inspected_head"] == fixture.head.rawValue)
        #expect(fields["hunks"] == "1")
        #expect(fields["note"]?.contains("staged") == true)
        #expect((try DaemonCommandOutcome.decode(reply.payload)).didCommit == false)

        // The page is UNCHANGED — no version, no event, same body.
        let read = try fixture.store.readPageCoherent(id: fixture.page.id)
        #expect(read.headVersionID == fixture.head)
        #expect(read.body == Fixture.body)

        // The staged record persists with its full shape.
        let staged = try #require(
            await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id))
        #expect(staged.id == fields["staged"])
        #expect(staged.status == .staged)
        #expect(staged.inspectedHead == fixture.head)
        #expect(staged.bodyFingerprint == LintPageSnapshot.fingerprint(of: Fixture.body))
        #expect(staged.hunks.count == 1)
        #expect(staged.perHunkClasses == [.wholeBodyFenceWrap])
        #expect(staged.hunks[0].newText == "new text")
        #expect(await fixture.lintRunState.stagedProposals(pageID: fixture.page.id) == [staged])

        // The trusted audit entry carries the record reference.
        let audit = try #require(try fixture.store.recentLogEntries(limit: 20).first {
            $0.title == LintProposalAudit.stagedAuditTitlePrefix + "Proposal Target"
        })
        #expect(audit.kind == .lint)
        let note = try #require(LintProposalAudit.parseStagedNote(audit.note))
        #expect(note.proposalID == staged.id)
        #expect(note.inspectedHead == fixture.head)
        #expect(note.hunkCount == 1)
    }

    // MARK: - One proposal per page per run

    @Test("a second proposal for the same page is refused")
    func secondProposalForSamePageIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let first = try await fixture.mintReceipt()
        let stagedReply = try await fixture.propose(receipt: first, newText: "new text")
        #expect(stagedReply.error == nil)
        let original = try #require(
            await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id))

        // A fresh read mints a new receipt; the staging refusal is about the
        // one-per-page rule, not the receipt.
        let second = try await fixture.mintReceipt()
        do {
            _ = try await fixture.propose(receipt: second, newText: "different text")
            Issue.record("a second proposal for the same page must refuse")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("already staged"))
        }

        // The original record survives untouched.
        let still = try #require(
            await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id))
        #expect(still == original)
        #expect(await fixture.lintRunState.stagedProposals(pageID: fixture.page.id).count == 1)
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).headVersionID == fixture.head)
    }

    // MARK: - Validator parity with page patch

    /// The same rejections the store applies to a patch: exact oldText,
    /// known defect classes, valid ranges. Nothing stages on a rejection.
    @Test("validation rejections mirror the patch rules")
    func validationRejectionsMirrorPatchRules() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()

        // oldText mismatch: the page's bytes do not say "other words".
        do {
            _ = try await fixture.propose(
                receipt: receipt, newText: "new text", oldText: "other words")
            Issue.record("an oldText mismatch must refuse")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("expected text does not match"))
        }

        // Nothing staged, page untouched.
        #expect(await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id) == nil)
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).headVersionID == fixture.head)

        // The receipt SURVIVES a validation rejection (nothing conflicted —
        // the run may recompose and stage a corrected proposal).
        let valid = try await fixture.propose(receipt: receipt, newText: "new text")
        #expect(valid.error == nil, "the same receipt may stage after a validator refusal")
    }

    // MARK: - Extreme offsets (rejected before any arithmetic)

    /// The staging path reads the page BEFORE the budget arithmetic, so the
    /// hunk numbers are validated against the body's real size first:
    /// `Int.min`/`Int.max` offsets and huge spans are `invalidRequest`
    /// rejections — never a subtraction overflow, never a crash — and
    /// nothing stages and no phase closes for garbage input.
    @Test("extreme proposal offsets are rejected, not trapped")
    func extremeProposalOffsetsRejectWithoutTrapping() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()

        let extremes: [(startByte: Int, endByte: Int, label: String)] = [
            (Int.min, 0, "Int.min start"),
            (Int.min, Int.max, "Int.min start, Int.max end"),
            (-1, 5, "negative start"),
            (0, Int.max, "huge span past the body"),
        ]
        for case let (start, end, label) in extremes {
            do {
                _ = try await fixture.propose(
                    receipt: receipt,
                    hunks: [DaemonPagePatchRequest.WireHunk(
                        defect: "D25", startByte: start, endByte: end,
                        oldText: "old text", newText: "new text",
                        reason: "repair the defect")])
                Issue.record("\(label) must be rejected, not staged")
            } catch let error as DaemonDomainError {
                #expect(error.code == .invalidRequest, "\(label): \(error.message)")
            }
        }

        // The daemon survived every hostile payload: nothing staged, the
        // page is untouched, no budget rejection was recorded, and the run's
        // write phase is still open — a valid proposal may still stage.
        #expect(await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id) == nil)
        let read = try fixture.store.readPageCoherent(id: fixture.page.id)
        #expect(read.headVersionID == fixture.head)
        #expect(read.body == Fixture.body)
        #expect(await fixture.lintRunState.budgetRejection(runID: fixture.runID) == nil)
        #expect(await fixture.lintRunState.isClosed(runID: fixture.runID) == false)
        let valid = try await fixture.propose(receipt: receipt, newText: "new text")
        #expect(valid.error == nil, "the same receipt may stage after extreme-offset refusals")
    }

    // MARK: - Receipt discipline

    @Test("propose without the current receipt denies")
    func proposeWithoutCurrentReceiptDenies() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        // No receipt was ever minted.
        do {
            _ = try await fixture.propose(receipt: "forged", newText: "new text")
            Issue.record("a forged receipt must deny")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }

        // A receipt minted from the current head cannot authorize hunks
        // declared against another head (review M4's propose twin).
        let receipt = try await fixture.mintReceipt()
        let otherHead = PageVersionID(rawValue: "01HZHEAD00000000000000000099")
        do {
            _ = try await fixture.propose(
                receipt: receipt, newText: "new text", expectHead: otherHead)
            Issue.record("a head-mismatched proposal must deny")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }
        #expect(await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id) == nil)
    }

    // MARK: - Budget rejection closes the run (patch-path mirror)

    @Test("an over-budget proposal is rejected whole and closes the run")
    func overBudgetProposalClosesRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }
        let receipt = try await fixture.mintReceipt()
        let budget = await fixture.lintRunState.budget(runID: fixture.runID)
        #expect(budget == LintPatchBudget(confirmedRepairableFindings: 0),
                "a clean inspected page gets the floor budget")

        let oversized = String(
            repeating: "x", count: budget.maxChangedBytes - Fixture.body.utf8.count + 1024)
        do {
            _ = try await fixture.propose(receipt: receipt, newText: oversized)
            Issue.record("an over-budget proposal must be rejected")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("budget_exceeded"))
        }

        // Nothing staged, nothing written.
        #expect(await fixture.lintRunState.stagedProposal(runID: fixture.runID, pageID: fixture.page.id) == nil)
        #expect(try fixture.store.readPageCoherent(id: fixture.page.id).headVersionID == fixture.head)

        // The rejection is recorded with its numbers, and the run's staging
        // phase is closed — a fresh receipt does not reopen it.
        let rejection = try #require(await fixture.lintRunState.budgetRejection(runID: fixture.runID))
        #expect(rejection.pageID == fixture.page.id)
        #expect(await fixture.lintRunState.isClosed(runID: fixture.runID))
        let fresh = try await fixture.mintReceipt()
        do {
            _ = try await fixture.propose(receipt: fresh, newText: "new text")
            Issue.record("a closed run must not stage")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }

        // The audit entry mirrors the patch path's rejection record.
        let audit = try #require(try fixture.store.recentLogEntries(limit: 20).first {
            $0.title == LintPatchBudget.auditTitlePrefix + "Proposal Target"
        })
        #expect(audit.note == rejection.rejection.summary)
    }

    // MARK: - Run-state bookkeeping

    /// At most one proposal per page per run (typed refusal), proposals
    /// survive run teardown (approval happens after the run), and the
    /// page-wide lookup sorts newest first.
    @Test func stagedProposalStateBookkeeping() async throws {
        let state = DaemonLintRunState()
        let runA = DaemonRunID(rawValue: "run-a")
        let runB = DaemonRunID(rawValue: "run-b")
        let page = PageID(rawValue: "01HZPAGE00000000000000000P")
        let head = PageVersionID(rawValue: "01HZHEAD00000000000000000001")

        func proposal(_ runID: DaemonRunID, id: String, at: Date) -> DaemonLintStagedProposal {
            DaemonLintStagedProposal(
                id: id, runID: runID, pageID: page, stagedAt: at,
                inspectedHead: head, bodyFingerprint: "fp",
                hunks: [], perHunkClasses: [])
        }
        try await state.stageProposal(proposal(runA, id: "p1", at: Date(timeIntervalSince1970: 100)))
        do {
            try await state.stageProposal(proposal(runA, id: "p2", at: Date(timeIntervalSince1970: 200)))
            Issue.record("a second proposal for the same page/run must refuse")
        } catch let error as DaemonLintRunState.StagingError {
            #expect(error == .alreadyStaged(pageID: page))
        }
        // A DIFFERENT run may stage the same page.
        let newer = proposal(runB, id: "p3", at: Date(timeIntervalSince1970: 300))
        try await state.stageProposal(newer)

        // Newest first across runs.
        let all = await state.stagedProposals(pageID: page)
        #expect(all.map(\.id) == ["p3", "p1"])

        // Teardown keeps staged proposals — the review/apply path reads
        // them after the run's lease is revoked (approval happens after
        // the run ends).
        await state.forget(runID: runA)
        let after = await state.stagedProposals(pageID: page)
        #expect(after.map(\.id) == ["p3", "p1"])
        let kept = try #require(await state.stagedProposal(runID: runA, pageID: page))
        #expect(kept.id == "p1")
    }
}
#endif
