import Foundation
import SQLite3
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// W5a §4: the apply-on-approve service. An approved proposal applies its
/// EXACT hunks through the existing `patchPage` CAS path (one page event,
/// provenance preserved); a stale proposal refuses without writing and
/// without touching the breaker; the budget is re-checked; a post-apply
/// verification failure auto-reverts and records `verificationFailure` with
/// the tier-2 breaker key; a human rejection records `userRejected`.
@MainActor
@Suite("Lint proposal apply service")
struct LintProposalApplyServiceTests {

    // MARK: - Fixtures

    struct Fixture {
        let root: URL
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let key = LintRepairBreakerKey(
            pipelineDigest: "tier2-digest", provider: "deepseek", model: "r1", effort: "low")
        let page: WikiPage
        let inspectedHead: PageVersionID
        /// The original body the hunks are composed against.
        static let body = "# Target\n\nold text\n"

        /// The tier-2 proposal input for one hunk replacing "old text".
        func proposal(newText: String, id: String = "prop-1") -> LintProposalApplyService.Proposal {
            let start = Self.body.utf8.count - "old text\n".utf8.count
            let end = start + "old text".utf8.count
            return LintProposalApplyService.Proposal(
                id: id, pageID: page.id, inspectedHead: inspectedHead,
                bodyFingerprint: LintPageSnapshot.fingerprint(of: Self.body),
                hunks: [PagePatchHunk(
                    startByte: start, endByte: end,
                    oldText: "old text", newText: newText, reason: "repair")],
                perHunkClasses: [.wholeBodyFenceWrap])
        }

        init(body: String = Self.body) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("propose-apply-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("WikiFS.sqlite"))
            let appGroup = root.appendingPathComponent("appgroup")
            breaker = LintRepairBreaker(containerResolver: { appGroup })
            page = try store.createPage(title: "Proposal Target", body: body)
            inspectedHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        func cleanUp() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // Temp cleanup only; each fixture owns a unique directory.
            }
        }
    }

    // MARK: - Happy path

    @Test func approvedHunksApplyExactlyWithOnePageEvent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store

        var events: [ResourceChangeEvent] = []
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "01HZBUS0000000000000000002"))
        bus.subscribe(nil) { event in events.append(event) }
        store.eventBus = bus

        let outcome = LintProposalApplyService.apply(
            proposal: fixture.proposal(newText: "new text"),
            store: store, breaker: fixture.breaker, breakerKey: fixture.key)

        guard case .applied(let writtenHead) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        // The exact hunks applied: the head moved, the text is the composed one.
        #expect(writtenHead != fixture.inspectedHead)
        #expect(try store.getPage(id: fixture.page.id).bodyMarkdown == "# Target\n\nnew text\n")
        #expect(try store.pageHeadVersionID(pageID: fixture.page.id) == writtenHead)
        // Exactly ONE page event, from the patchPage seam (the audit log
        // append emits its own log event — filtered out here).
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.filter { $0.change == .updated }.count == 1)
        // Provenance survived the write: the version chain is intact and
        // the written version names the proposal as its writer.
        #expect(try store.pageVersionHistory(pageID: fixture.page.id).count == 2)
        let origin = try #require(try store.pageOrigin(pageID: fixture.page.id))
        #expect(origin.agentName.rawValue == "lint-proposal:prop-1")

        // The durable audit record carries the outcome.
        let audit = try #require(try store.recentLogEntries(limit: 20).first {
            $0.title == LintProposalAudit.appliedAuditTitlePrefix + "Proposal Target"
        })
        #expect(audit.kind == .lint)
        #expect(audit.note?.contains("proposal_id=prop-1") == true)
        #expect(audit.note?.contains("outcome=applied") == true)
    }

    /// A SUBSET applies: only the approved indices' hunks reach the store.
    @Test func approvedSubsetAppliesOnlyThoseHunks() throws {
        let fixture = try Fixture(body: "# T\n\nkeep me\nold text\nsecond text\n")
        defer { fixture.cleanUp() }
        let body = Fixture.body
        _ = body
        let start = "# T\n\nkeep me\n".utf8.count
        let oldText = "old text"
        let second = "second text"
        let proposal = LintProposalApplyService.Proposal(
            id: "prop-2", pageID: fixture.page.id, inspectedHead: fixture.inspectedHead,
            bodyFingerprint: "fp",
            hunks: [
                PagePatchHunk(
                    startByte: start, endByte: start + oldText.utf8.count,
                    oldText: oldText, newText: "fixed text", reason: "one"),
                PagePatchHunk(
                    startByte: start + oldText.utf8.count + 1,
                    endByte: start + oldText.utf8.count + 1 + second.utf8.count,
                    oldText: second, newText: "changed", reason: "two"),
            ],
            perHunkClasses: [.wholeBodyFenceWrap, .wholeBodyFenceWrap])

        // Approve ONLY the second hunk (index 1).
        let outcome = LintProposalApplyService.apply(
            proposal: proposal, approvedIndices: IndexSet([1]),
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .applied = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(try fixture.store.getPage(id: fixture.page.id).bodyMarkdown
            == "# T\n\nkeep me\nold text\nchanged\n")
    }

    // MARK: - Stale refusal

    @Test func staleProposalRefusesWithoutWritingOrBreakerEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // The page moved after the proposal was staged.
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Proposal Target", body: "# Target\n\nchanged by user\n")

        let outcome = LintProposalApplyService.apply(
            proposal: fixture.proposal(newText: "new text"),
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .stale(let currentHead) = outcome else {
            Issue.record("expected .stale, got \(outcome)")
            return
        }
        #expect(currentHead != fixture.inspectedHead)
        // The concurrent edit survives untouched.
        #expect(try fixture.store.getPage(id: fixture.page.id).bodyMarkdown
            == "# Target\n\nchanged by user\n")
        // Breaker untouched.
        #expect(fixture.breaker.windowStatus(for: fixture.key).verificationFailures == 0)
        #expect(fixture.breaker.consult(fixture.key) == .clean)
    }

    // MARK: - Concurrent write between commit and verification

    /// A concurrent writer that moves the head between the commit and the
    /// verification scan gets its content neither labeled as this write nor
    /// verified as repaired: the scan reads the IMMUTABLE written version
    /// (pinned by fingerprint), and the diverged current head is reported
    /// as its own fact. The pre-fix code scanned the current head here — a
    /// saboteur's fresh defect was attributed to the proposal and failed
    /// (and reverted) a write that was never scanned.
    @Test func concurrentWriteBetweenCommitAndVerificationIsNotScanned() throws {
        // The D25 defect body: the whole page wrapped in a code fence (no
        // wiki links — a link would trip D07 on any body in this fixture
        // store, which resolves none).
        let body = "```markdown\n# Wrapped\nSome wrapped text\n```\n"
        let fixture = try Fixture(body: body)
        defer { fixture.cleanUp() }
        let store = fixture.store
        // Length-neutral repair: a much shorter body would trip the
        // truncation detector (D27) on our own written version.
        let repaired = "# Fine\n\nSome plain repaired text here\n"

        let proposal = LintProposalApplyService.Proposal(
            id: "prop-race", pageID: fixture.page.id, inspectedHead: fixture.inspectedHead,
            bodyFingerprint: LintPageSnapshot.fingerprint(of: body),
            hunks: [PagePatchHunk(
                startByte: 0, endByte: body.utf8.count,
                oldText: body, newText: repaired, reason: "unwrap the page")],
            perHunkClasses: [.wholeBodyFenceWrap])

        // The commit: the exact write `apply` performs.
        let preRead = try store.readPageCoherent(id: fixture.page.id)
        let outcome = try store.patchPage(
            PagePatch(
                pageID: fixture.page.id, expectHead: fixture.inspectedHead,
                hunks: proposal.hunks, defectClasses: proposal.perHunkClasses),
            author: "lint-proposal:prop-race")

        // A concurrent writer replaces the head BEFORE verification runs,
        // with a body carrying its own fresh defect (a ghost footnote).
        let concurrentBody = "A ref.[^ghost]\n"
        try store.updatePage(
            id: fixture.page.id, title: "Proposal Target", body: concurrentBody)

        // Verification with the same inputs `apply` assembles.
        let preScan = LintProposalApplyService.scan(store: store, read: preRead)
        let verification = try LintProposalApplyService.verifyWrittenVersion(
            proposal: proposal, preRead: preRead, preScan: preScan,
            writtenHead: outcome.writtenHead, store: store)

        // The scan read the WRITTEN version's bytes — never the saboteur's.
        #expect(verification.scannedFingerprint == LintPageSnapshot.fingerprint(of: repaired))
        // Our write verified; the diverged head is reported separately and
        // the saboteur's fresh defect is NOT attributed to the proposal.
        guard case .verifiedWrittenHeadDiverged(let currentHead) = verification.status else {
            Issue.record("expected verifiedWrittenHeadDiverged, got \(verification.status)")
            return
        }
        #expect(currentHead != outcome.writtenHead)
        let liveHead = try store.pageHeadVersionID(pageID: fixture.page.id)
        #expect(currentHead == liveHead)
        // The concurrent edit survives — verification never reverts it.
        #expect(try store.getPage(id: fixture.page.id).bodyMarkdown == concurrentBody)
    }

    // MARK: - Unavailable required checks

    /// Unavailable REQUIRED verification checks are a verification FAILURE —
    /// never a silent verified verdict over degraded facts. The caller's
    /// failure path (one CAS-guarded revert + breaker evidence) then runs.
    @Test func unavailableRequiredChecksFailVerification() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let preRead = try store.readPageCoherent(id: fixture.page.id)
        // The pre-apply scan ran without the identity facts (the required
        // set): the caller passes that availability through unchanged.
        let preScan = LintProposalApplyService.ScanOutcome(
            report: LintProposalApplyService.scan(store: store, read: preRead).report,
            requiredChecksAvailable: false)

        // Commit the write the verification is about to check.
        let proposal = fixture.proposal(newText: "new text")
        let outcome = try store.patchPage(
            PagePatch(
                pageID: fixture.page.id, expectHead: fixture.inspectedHead,
                hunks: proposal.hunks, defectClasses: proposal.perHunkClasses),
            author: "lint-proposal:prop-avail")

        let verification = try LintProposalApplyService.verifyWrittenVersion(
            proposal: proposal, preRead: preRead, preScan: preScan,
            writtenHead: outcome.writtenHead, store: store)
        guard case .failed(let reasons) = verification.status else {
            Issue.record("expected .failed, got \(verification.status)")
            return
        }
        #expect(reasons.contains { $0.contains("unavailable") },
                "the unavailable required check is named: \(reasons)")
    }

    /// A healthy scan reports every required check available — the gate
    /// only ever narrows, never fails a healthy verification.
    @Test func healthyScanReportsRequiredChecksAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scan = LintProposalApplyService.scan(
            store: fixture.store,
            read: try fixture.store.readPageCoherent(id: fixture.page.id))
        #expect(scan.requiredChecksAvailable)
    }

    // MARK: - Fault-injected fact loads (R-E: availability tracking)

    /// A citation to a canonical source with NO markdown chain (absent
    /// from the store, or present without processed markdown) resolves to
    /// a pin set of NONE — the fact load degrades to facts, never traps.
    /// (`Set(1...max(count, 0))` built `1...0` for an empty chain and
    /// crashed every lint plan and apply that scanned such a page.)
    @Test func citationToAChainlessSourceResolvesToNoPinsInsteadOfTrapping() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let facts = try LintCitationFacts.load(
            from: fixture.store, body: "[[source:01HZSRC0000000000000000001]]\n")
        #expect(facts.sources["01HZSRC0000000000000000001"] != nil,
                "the canonical literal lands in the facts (the pin path runs)")
        #expect(facts.pinExists(sourceLiteral: "01HZSRC0000000000000000001", ordinal: 1) == false)
        #expect(facts.normalizedText(sourceLiteral: "01HZSRC0000000000000000001", pin: nil) == nil,
                "no chain resolves no authority text")
        #expect(facts.fragmentAvailable(
            sourceLiteral: "01HZSRC0000000000000000001", pin: 1, text: "anything") == false)
    }


    /// A fact-LOAD failure (D11 here: with a real source row whose origin
    /// history table is gone, the load throws) marks the required checks
    /// unavailable, and apply fails closed through the recovery path
    /// instead of verifying over a facts-less scan. The resolution and
    /// citation fact loads mark availability the same way in ``scan`` —
    /// every load failure gates the verdict; a failed load must never read
    /// as a clean scan.
    @Test func originFactsLoadFailureFailsApplyClosedThroughTheRecoveryPath() throws {
        // The body carries a raw URL, so the origin facts load resolves
        // every source's origin history.
        let body = "Fetch https://example.com/one here.\n"
        let fixture = try Fixture(body: body)
        defer { fixture.cleanUp() }
        // A real source row: the origin load enumerates sources and reads
        // each one's origin history (the source_versions join).
        _ = try fixture.store.addSource(filename: "origin.txt", data: Data("x".utf8))
        try Self.executeRaw("DROP TABLE source_versions", fixture: fixture)

        let proposal = LintProposalApplyService.Proposal(
            id: "prop-url", pageID: fixture.page.id, inspectedHead: fixture.inspectedHead,
            bodyFingerprint: LintPageSnapshot.fingerprint(of: body),
            hunks: [PagePatchHunk(
                startByte: 0, endByte: 5, oldText: "Fetch", newText: "Read",
                reason: "reword the lead")],
            perHunkClasses: [.tableDamage])

        let outcome = LintProposalApplyService.apply(
            proposal: proposal,
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .appliedThenReverted(_, let revert, let reasons) = outcome else {
            Issue.record("expected appliedThenReverted over unavailable facts, got \(outcome)")
            return
        }
        #expect(reasons.contains { $0.contains("unavailable") },
                "the unavailable required check is named: \(reasons)")
        guard case .reverted = revert else {
            Issue.record("the promised recovery path reverts the write, got \(revert)")
            return
        }
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id)
            == fixture.inspectedHead, "the bad write did not survive")
    }

    /// A D27 HISTORY-read failure (the parent version's body is gone —
    /// carried as `.readFailed`, never thrown) marks the required checks
    /// unavailable, so the apply fails closed through the promised
    /// recovery path — one CAS-guarded revert + breaker evidence — instead
    /// of verifying over a blocked history check (round-three R-E).
    @Test func historyReadFailureFailsApplyClosedThroughTheRecoveryPath() throws {
        // A second, byte-DIFFERENT body (a distinct author defeats the
        // amend-coalescing window; different bytes keep the two versions on
        // distinct content-addressed blob rows), so the inspected head HAS
        // a parent whose body the D27 history read fetches — while the
        // head's own body stays readable.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let chainBody = Fixture.body + "A trailing line for the history chain.\n"
        try store.updatePage(
            id: fixture.page.id, title: "Proposal Target", body: chainBody,
            lastEditedBy: "history-fault-test")
        let inspectedHead = try #require(try store.pageHeadVersionID(pageID: fixture.page.id))
        #expect(inspectedHead != fixture.inspectedHead,
                "the second save appended a version (no amend coalescing)")

        // Sabotage the PARENT version's blob: the history load reads the
        // parent body through the page_versions→blobs join and reports
        // `.readFailed` instead of throwing.
        try Self.executeRaw("""
        DELETE FROM blobs WHERE hash = (
            SELECT blob_hash FROM page_versions
            WHERE page_id = '\(fixture.page.id.rawValue)'
            ORDER BY id ASC LIMIT 1)
        """, fixture: fixture)

        let preRead = try store.readPageCoherent(id: fixture.page.id)
        let preScan = LintProposalApplyService.scan(store: store, read: preRead)
        #expect(preScan.requiredChecksAvailable == false,
                "the failed history read makes the required D27 check unavailable")

        // The proposal is composed against the current body and head; the
        // hunk replaces "old text" (its offsets are unchanged — the appended
        // line trails it).
        let start = "# Target\n\n".utf8.count
        let end = start + "old text".utf8.count
        let proposal = LintProposalApplyService.Proposal(
            id: "prop-history", pageID: fixture.page.id, inspectedHead: inspectedHead,
            bodyFingerprint: LintPageSnapshot.fingerprint(of: chainBody),
            hunks: [PagePatchHunk(
                startByte: start, endByte: end, oldText: "old text",
                newText: "new text", reason: "repair")],
            perHunkClasses: [.wholeBodyFenceWrap])

        let outcome = LintProposalApplyService.apply(
            proposal: proposal,
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .appliedThenReverted(_, let revert, let reasons) = outcome else {
            Issue.record("expected appliedThenReverted over the blocked history check, got \(outcome)")
            return
        }
        #expect(reasons.contains { $0.contains("unavailable") },
                "the unavailable history check is named: \(reasons)")
        guard case .reverted = revert else {
            Issue.record("the guarded recovery path reverts the write, got \(revert)")
            return
        }
        #expect(try store.pageHeadVersionID(pageID: fixture.page.id)
            == inspectedHead, "the bad write did not survive")
        // Breaker accounting: the failed verification is evidence for this
        // configuration.
        #expect(fixture.breaker.windowStatus(for: fixture.key).verificationFailures == 1)
    }

    /// The PLAN derivation gates on the same read: a blocked D27 history
    /// check marks the plan's required checks unavailable and the history
    /// section stays visibly blocked — a staging run cannot even start
    /// from a plan whose facts were degraded silently.
    @Test func planDerivationMarksBlockedHistoryCheckUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Proposal Target", body: Fixture.body,
            lastEditedBy: "history-fault-test")
        try Self.executeRaw("""
        DELETE FROM blobs WHERE hash = (
            SELECT blob_hash FROM page_versions
            WHERE page_id = '\(fixture.page.id.rawValue)'
            ORDER BY id ASC LIMIT 1)
        """, fixture: fixture)

        let plan = try #require(await AgentOperationRunner.makeLintPagePlan(
            store: fixture.store, pageID: fixture.page.id, stateMarkdown: "# state\n",
            gateInputs: .init(
                provider: "anthropic", model: "claude-opus",
                modelRevision: "rev-1", effort: "high"),
            selection: { _ in .stagedProposal(reason: "test") },
            breaker: fixture.breaker))
        #expect(plan.requiredChecksAvailable == false,
                "the plan carries the blocked history check as unavailable")
        let historySection = plan.preflight.sections.first {
            $0.section == .integrityAndHistory
        }
        guard case .blocked = historySection?.status else {
            Issue.record(
                "expected a blocked history section, got \(String(describing: historySection?.status))")
            return
        }
    }

    /// The post-write read failure path: when the written version cannot be
    /// read back (the immutable-history violation the written-version seam
    /// guards), verification throws instead of verifying — the caller keeps
    /// the failed-write posture (guarded revert + breaker evidence).
    @Test func unreadableWrittenVersionFailsVerificationInsteadOfVerifying() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let preRead = try store.readPageCoherent(id: fixture.page.id)
        let preScan = LintProposalApplyService.scan(store: store, read: preRead)
        let proposal = fixture.proposal(newText: "new text")
        let written = try store.patchPage(
            PagePatch(
                pageID: fixture.page.id, expectHead: fixture.inspectedHead,
                hunks: proposal.hunks, defectClasses: proposal.perHunkClasses),
            author: "lint-proposal:prop-ghost")

        // A written head whose version row does not exist (26-char ULID
        // shape, no row behind it).
        let ghost = PageVersionID(rawValue: "01HZXXXXXXXXXXXXXXXXXXXX01")
        #expect(try store.pageVersionBody(versionID: ghost) == nil,
                "the fixture's ghost head reads as missing")
        _ = written
        #expect(throws: LintProposalApplyService.WrittenVersionUnavailable.self) {
            _ = try LintProposalApplyService.verifyWrittenVersion(
                proposal: proposal, preRead: preRead, preScan: preScan,
                writtenHead: ghost, store: store)
        }
    }

    /// Run one raw SQL statement through a second connection (the same
    /// fault-injection shape the strategy read-failure fixture uses): the
    /// store keeps serving everything the statement does not break.
    private static func executeRaw(
        _ sql: String, fixture: Fixture, expectChangedRows: Int? = nil
    ) throws {
        var db: OpaquePointer?
        let path = fixture.root.appendingPathComponent("WikiFS.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Issue.record("could not open the fixture database for fault injection")
            return
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            Issue.record("fault-injection statement failed: \(sql)")
            return
        }
        if let expectChangedRows, sqlite3_changes(db) != expectChangedRows {
            Issue.record(
                "fault-injection statement changed \(sqlite3_changes(db)) row(s), expected \(expectChangedRows): \(sql)")
        }
    }

    // MARK: - Budget at apply

    @Test func overBudgetApplyIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A floor budget (0 confirmed findings) caps changed bytes at 8192;
        // ask for more.
        let oversized = String(repeating: "x", count: 9_000)
        let outcome = LintProposalApplyService.apply(
            proposal: fixture.proposal(newText: oversized),
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("budget rejected at apply"))
        #expect(try fixture.store.getPage(id: fixture.page.id).bodyMarkdown == Fixture.body)
        #expect(fixture.breaker.consult(fixture.key) == .clean)
    }

    // MARK: - Verification failure → auto-revert + breaker

    /// The applied hunks introduce a NEW mechanical finding (a U+FFFD
    /// replacement character, D17 confirmed) — verification fails, the write
    /// is auto-reverted to the inspected head, and the breaker records the
    /// verification failure for the tier-2 key.
    @Test func verificationFailureAutoRevertsAndRecordsBreaker() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Recompose the hunk against THIS body.
        let body = Fixture.body
        let start = body.utf8.count - "old text\n".utf8.count
        let proposal = LintProposalApplyService.Proposal(
            id: "prop-bad", pageID: fixture.page.id, inspectedHead: fixture.inspectedHead,
            bodyFingerprint: LintPageSnapshot.fingerprint(of: body),
            hunks: [PagePatchHunk(
                startByte: start, endByte: start + "old text".utf8.count,
                oldText: "old text",
                newText: "corrupted \u{FFFD} bytes",
                reason: "introduces encoding damage the detector must catch")],
            perHunkClasses: [.encodingDamage])

        let outcome = LintProposalApplyService.apply(
            proposal: proposal,
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        guard case .appliedThenReverted(_, let revert, let reasons) = outcome else {
            Issue.record("expected .appliedThenReverted, got \(outcome)")
            return
        }
        // The bad write did not survive: the page is back at the inspected head.
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id)
            == fixture.inspectedHead)
        #expect(try fixture.store.getPage(id: fixture.page.id).bodyMarkdown == Fixture.body)
        guard case .reverted = revert else {
            Issue.record("expected a completed revert, got \(revert)")
            return
        }
        #expect(reasons.isEmpty == false, "the disclosure keeps the verification reasons")
        // Tier-2 recording is ACTIVE: the failure is breaker evidence for
        // this configuration — resolvable with NO approval row.
        let status = fixture.breaker.windowStatus(for: fixture.key)
        #expect(status.verificationFailures == 1)
        // A second failure trips it.
        let outcome2 = LintProposalApplyService.apply(
            proposal: proposal,
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key)
        if case .appliedThenReverted = outcome2 {} else {
            Issue.record("expected a second appliedThenReverted, got \(outcome2)")
        }
        guard case .tripped(let reason) = fixture.breaker.consult(fixture.key) else {
            Issue.record("two verification failures must trip the tier-2 breaker")
            return
        }
        #expect(reason.contains("2 verification failures"))
    }

    // MARK: - Rejection → userRejected

    @Test func rejectionRecordsUserRejectedAndTripsOnRepeat() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(LintProposalApplyService.recordRejection(
            breaker: fixture.breaker, breakerKey: fixture.key) == .clean)
        #expect(fixture.breaker.windowStatus(for: fixture.key).userRejections == 1)
        guard case .tripped(let reason) = LintProposalApplyService.recordRejection(
            breaker: fixture.breaker, breakerKey: fixture.key) else {
            Issue.record("a second rejection must trip the breaker")
            return
        }
        #expect(reason.contains("2 staged proposals rejected"))
        // An unresolved configuration records nothing.
        #expect(LintProposalApplyService.recordRejection(
            breaker: fixture.breaker, breakerKey: nil) == nil)
        #expect(LintProposalApplyService.recordRejection(
            breaker: nil, breakerKey: fixture.key) == nil)
    }

    // MARK: - Degenerate inputs

    @Test func missingPageAndEmptyApprovalsRefuse() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Missing page.
        let ghost = LintProposalApplyService.Proposal(
            id: "ghost", pageID: PageID(rawValue: "01HZGHOST0000000000000000001"),
            inspectedHead: fixture.inspectedHead, bodyFingerprint: "fp",
            hunks: [], perHunkClasses: [])
        if case .failed = LintProposalApplyService.apply(
            proposal: ghost, store: fixture.store,
            breaker: fixture.breaker, breakerKey: fixture.key) {} else {
            Issue.record("a missing page must fail, not crash")
        }
        // Nothing approved.
        if case .failed(let reason) = LintProposalApplyService.apply(
            proposal: fixture.proposal(newText: "x"), approvedIndices: IndexSet(),
            store: fixture.store, breaker: fixture.breaker, breakerKey: fixture.key),
           reason.contains("no hunks approved") {} else {
            Issue.record("an empty approval must refuse")
        }
    }
}
