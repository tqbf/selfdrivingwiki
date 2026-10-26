#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// The user-triggered per-finding repair (a person's Fix click on ONE lint
/// finding): the plan builder never consults the rollout gate, the lease is
/// repair-capable for the assigned page only, the breaker key comes from
/// what the launcher spawned, and the shared enforcement net (written-head
/// verification + the one-finding scope rule, guarded revert, breaker,
/// undo) wraps every attempt. Scripted-agent pattern: the test plays the
/// agent's write and run report, then runs the REAL accounting.
@MainActor
@Suite(.serialized)
struct LintPerFindingRepairTests {

    @MainActor
    private final class Fixture {
        let root: URL
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let scratch: URL
        let page: WikiPage
        let inspectedHead: PageVersionID

        /// Two independent defects: a malformed wiki-link (D06-1, with its
        /// co-located truncation candidate D23-1) and an escaping-layer
        /// defect (D26-1) in a different paragraph.
        static let originalBody = "# Fix\n\nA &amp;amp; B\n\nSee [[Broken link here.\n"
        /// The correct one-finding repair: the link markup dropped, the
        /// text kept; D26 untouched.
        static let targetOnlyRepair = "# Fix\n\nA &amp;amp; B\n\nSee Broken link here.\n"
        /// Over-reach: the target AND the other finding repaired.
        static let overReachingRepair = "# Fix\n\nA &amp; B\n\nSee Broken link here.\n"
        /// The wrong finding repaired; the target left in place.
        static let wrongFindingRepair = "# Fix\n\nA &amp; B\n\nSee [[Broken link here.\n"

        static let launched = LaunchedAgentConfiguration(
            provider: ProviderID(rawValue: "codex-acp"),
            model: ModelID(rawValue: "gpt-6-luna"),
            effort: "low")

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lint-per-finding-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("WikiFS.sqlite"))
            let appGroup = root.appendingPathComponent("appgroup", isDirectory: true)
            breaker = LintRepairBreaker(containerResolver: { appGroup })
            scratch = root.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            page = try store.createPage(title: "Fix Target")
            try store.updatePage(id: page.id, title: "Fix Target", body: Self.originalBody)
            inspectedHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        deinit {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // Temp cleanup only; each fixture owns a unique directory.
            }
        }

        func target(
            _ findingID: String = "D06-1", classLabel: String = "D06",
            expectedHead: PageVersionID? = nil
        ) -> LintRepairTarget {
            LintRepairTarget(
                findingID: findingID, classLabel: classLabel,
                expectedHead: expectedHead ?? inspectedHead, originItemID: nil)
        }

        func planResult(_ target: LintRepairTarget) async -> AgentOperationRunner.PerFindingPlanResult {
            await AgentOperationRunner.makePerFindingRepairPlan(
                store: store, pageID: page.id, target: target,
                stateMarkdown: "# state\n", breaker: breaker)
        }

        func readyPlan(_ target: LintRepairTarget) async throws -> AgentOperationRunner.LintPagePlan {
            guard case .ready(let plan) = await planResult(target) else {
                Issue.record("expected a ready per-finding plan")
                throw CancellationError()
            }
            return plan
        }

        /// Stage the agent's filled run report: `repaired` for the claimed
        /// findings, `unresolved` for every other finding, and the agent's
        /// own `--kind lint` append.
        func stageAgentArtifacts(
            for plan: AgentOperationRunner.LintPagePlan, repaired: Set<String>
        ) throws {
            let skeleton = LintRunReportText.render(snapshot: plan.snapshot, preflight: plan.preflight)
            let filled = skeleton.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if line == "verification none pending" { return "verification none clean" }
                if line.hasPrefix("finding "), line.hasSuffix(" pending") {
                    let id = line.dropFirst("finding ".count).split(separator: " ").first.map(String.init) ?? ""
                    return line.replacingOccurrences(
                        of: " pending",
                        with: repaired.contains(id) ? " repaired" : " unresolved|not this run's finding")
                }
                if line.hasSuffix(" pending") {
                    return line.replacingOccurrences(of: " pending", with: " valid-as-written|recorded")
                }
                return String(line)
            }.joined(separator: "\n")
            try filled.write(
                to: scratch.appendingPathComponent(AgentStaging.lintRunReportFileName),
                atomically: true, encoding: .utf8)
            _ = try store.appendLog(kind: .lint, title: "Fix Target lint", note: "agent record")
        }

        /// Simulate the run's own write and return the head it produced.
        func agentWrite(_ body: String) throws -> PageVersionID {
            try store.updatePage(id: page.id, title: "Fix Target", body: body)
            return try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        /// The REAL accounting over the launched plan.
        func account(
            _ plan: AgentOperationRunner.LintPagePlan, runStart: Date
        ) -> AgentOperationRunner.LintPageDispatchOutcome {
            AgentOperationRunner.accountForLintRun(
                plan: AgentOperationRunner.perFindingPlanAfterLaunch(plan, launched: Self.launched),
                pageID: page.id, scratchDirectory: scratch,
                store: store, runStart: runStart, producedHead: nil)
        }

        /// The durable per-page record the queue report persists, parsed
        /// back the way Run Details reads it.
        func recordFacts(_ outcome: AgentOperationRunner.LintPageDispatchOutcome) throws -> LintPageRecordFacts {
            let mutation = QueueIngestionReporting.lintPageOutcomesMutation([outcome.queueReportOutcome])
            let record = try #require(mutation.targetUpserts.first)
            return try #require(LintPageRecordFacts.parse(record: record))
        }

        var expectedKey: LintRepairBreakerKey {
            get throws {
                LintRepairBreakerKey(
                    pipeline: try LintAcceptanceManifest.Pipeline.live(),
                    provider: "codex-acp", model: "gpt-6-luna", effort: "low")
            }
        }

        var body: String {
            get throws { try store.readPageCoherent(id: page.id).body }
        }
    }

    // MARK: - The gate is not consulted

    /// Unconfigured gate inputs (production today) select report-only for
    /// autonomous lint — and the SAME page's per-finding plan still earns a
    /// repair-capable lease for exactly its assigned page. The click is the
    /// authorization; the plan builder has no gate input at all.
    @Test func unconfiguredGateStillYieldsARepairCapablePerFindingLease() async throws {
        let fixture = try Fixture()

        // The production gate with today's unconfigured inputs.
        let gate = try LintCoordinatorGate.selection(
            provider: "unconfigured", model: "unconfigured", modelRevision: nil, effort: "unconfigured")
        guard case .reportOnly = gate else {
            Issue.record("unconfigured gate inputs must select report-only")
            return
        }
        let autonomous = try #require(await AgentOperationRunner.makeLintPagePlan(
            store: fixture.store, pageID: fixture.page.id, stateMarkdown: "# state\n"))
        #expect(autonomous.authority.tier == .reportOnly)
        #expect(AgentLauncher.managedRunPolicy(for: autonomous.request)
            == .lintSelectedPageReportOnly(pageID: fixture.page.id))

        // The per-finding plan for the same page and gate state.
        let plan = try await fixture.readyPlan(fixture.target())
        #expect(plan.authority.tier == .perFindingRepair)
        #expect(plan.authority.isRepairCapable)
        #expect(plan.authority.approvalID == nil, "no approval row is involved")
        let policy = AgentLauncher.managedRunPolicy(for: plan.request)
        #expect(policy == .lintPerFindingRepair(pageID: fixture.page.id))

        // The focus is the TRUSTED scan's finding, not the payload's words.
        let focus = try #require(plan.repairFocus)
        let scanned = try #require(plan.preflight.sections.flatMap(\.findings)
            .first { $0.occurrenceID == "D06-1" })
        #expect(focus == LintRepairFocus(scanned))
        guard case .lintPage(_, let mode, _, _, _, _) = plan.request,
              case .perFindingRepair(let requested) = mode else {
            Issue.record("the request must carry the per-finding mode")
            return
        }
        #expect(requested == focus)
        #expect(plan.breakerKey == nil, "the breaker key is unknown until launch")

        // The lease that policy mints: repair-capable for the assigned page
        // only — a patch elsewhere denies.
        let registry = DaemonRunRegistry()
        let wikiID = WikiID(rawValue: "01HZPERFINDINGWIKI00000000A")
        let registration = try await registry.prepareRun(
            scope: DaemonRunScope(wikiID: wikiID),
            operationClasses: DaemonScopedRunLeaseManager.operationClasses(for: policy),
            operationPolicy: policy)
        try await registry.activate(runID: registration.runID)
        let guardInstance = DaemonScopedRequestGuard(
            registry: registry,
            assignedWiki: { _ in WikiDescriptor.make(displayName: "Per-finding Wiki") },
            queueItemOwningWiki: { _ in nil })
        func patch(_ pageID: PageID) -> DaemonDomainRequest {
            DaemonDomainRequest(
                requestID: UUID().uuidString, family: .page,
                operation: DaemonDomainOperation.Page.patch,
                payload: Data("""
                {"wikiID":"\(wikiID.rawValue)","id":"\(pageID.rawValue)","expectHead":"h","hunks":[]}
                """.utf8),
                authorization: DaemonDomainAuthorization(capability: registration.capability.printable))
        }
        let allowed = try? await guardInstance.evaluate(patch(fixture.page.id), listenerRunID: registration.runID)
        #expect(allowed != nil, "the per-finding lease patches its assigned page")
        let denied = try? await guardInstance.evaluate(
            patch(PageID(rawValue: "01HZOTHERPAGE0000000000000A")), listenerRunID: registration.runID)
        #expect(denied == nil, "the per-finding lease cannot patch a page it was not assigned")
    }

    // MARK: - Breaker key at launch

    /// The breaker key is what the launcher SPAWNED: the live pipeline
    /// digest + the launched provider/model/effort. Nothing spawned → no
    /// key; an unpinned effort → `agent-default`.
    @Test func breakerKeyIsRecordedFromTheLaunchedConfiguration() async throws {
        let fixture = try Fixture()
        let plan = try await fixture.readyPlan(fixture.target())

        let launched = AgentOperationRunner.perFindingPlanAfterLaunch(plan, launched: Fixture.launched)
        #expect(launched.breakerKey == (try fixture.expectedKey))
        #expect(launched.repairFocus == plan.repairFocus, "the focus survives the launch")
        #expect(launched.authority == plan.authority)

        #expect(AgentOperationRunner.perFindingPlanAfterLaunch(plan, launched: nil).breakerKey == nil,
                "a run that never spawned names no configuration")
        let unpinned = AgentOperationRunner.launchedBreakerKey(LaunchedAgentConfiguration(
            provider: ProviderID(rawValue: "pi"), model: ModelID(rawValue: "m"), effort: nil))
        #expect(unpinned?.effort == LintRepairBreakerKey.agentDefaultEffort)
        #expect(AgentOperationRunner.launchedBreakerKey(LaunchedAgentConfiguration(
            provider: ProviderID(rawValue: "pi"), model: nil, effort: "low")) == nil,
            "no resolved model — no key is invented")
    }

    /// The recorded key survives the durable record exactly, whatever
    /// characters the configured names carry.
    @Test func breakerKeyRecordLabelRoundTrips() throws {
        let key = LintRepairBreakerKey(
            pipelineDigest: "abc123", provider: "codex acp; x=1",
            model: "6.1 Sol (low),v2", effort: "agent-default")
        let label = key.recordLabel
        #expect(label.hasPrefix("breaker_key="))
        #expect(label.contains("; ") == false, "one record segment")
        let value = String(label.dropFirst("breaker_key=".count))
        #expect(LintRepairBreakerKey(recordLabelValue: value) == key)
        #expect(LintRepairBreakerKey(recordLabelValue: "a,b,c") == nil)
        #expect(LintRepairBreakerKey(recordLabelValue: "a,,c,d") == nil)
    }

    // MARK: - End to end (scripted agent)

    /// (a) The Fix applies a correct ONE-finding patch: verification passes
    /// on the written head, the breaker records a clean outcome under the
    /// launched key, and the durable record carries everything the W2b undo
    /// section needs — the undo then reverts it and records a user undo
    /// under the SAME key.
    @Test func fixAppliesTheOneFindingPatchAndUndoCoversIt() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.readyPlan(fixture.target())
        try fixture.stageAgentArtifacts(for: plan, repaired: ["D06-1"])
        let written = try fixture.agentWrite(Fixture.targetOnlyRepair)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .dispatched, "\(outcome.detail)")
        #expect(outcome.detail.contains("verification verified on the written head"))
        #expect(outcome.revert == nil)
        #expect(try fixture.body == Fixture.targetOnlyRepair, "the repair stays in place")
        #expect(outcome.authority?.tier == .perFindingRepair)
        let key = try fixture.expectedKey
        #expect(fixture.breaker.windowStatus(for: key).verificationFailures == 0)

        let facts = try fixture.recordFacts(outcome)
        #expect(facts.perFindingID == "D06-1")
        #expect(facts.perFindingRefusal == nil)
        #expect(facts.recordedBreakerKey == key)
        #expect(facts.tier == .perFindingRepair)
        #expect(facts.inspectedHead == fixture.inspectedHead)
        #expect(facts.writtenHead == written)
        #expect(facts.wroteSurvivingRepair, "the W2b undo section renders for this run")

        // The W2b interplay: the existing undo batch reverts the surviving
        // repair and records ONE user undo under the run's recorded key.
        let result = LintUndoService.undoRepairedPages(
            store: fixture.store,
            pages: [LintUndoService.PagePlan(
                pageID: fixture.page.id, inspectedHead: fixture.inspectedHead, writtenHead: written)],
            breaker: fixture.breaker, breakerKey: facts.recordedBreakerKey)
        #expect(result.revertedCount == 1)
        #expect(try fixture.body == Fixture.originalBody)
        #expect(fixture.breaker.windowStatus(for: key).userUndos == 1)
    }

    /// (b) Verification failure: the run repaired its target AND another
    /// finding outside the target's bytes. The one-finding scope rule fails
    /// verification, ONE guarded CAS revert restores the inspected head,
    /// the breaker records the failure under the launched key, and the
    /// record retains the disclosure data.
    @Test func overReachingRepairRevertsAndRecordsTheBreakerFailure() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.readyPlan(fixture.target())
        try fixture.stageAgentArtifacts(for: plan, repaired: ["D06-1"])
        let written = try fixture.agentWrite(Fixture.overReachingRepair)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("per-finding repair changed finding D26-1"))
        #expect(outcome.revert == .reverted(to: fixture.inspectedHead, from: written))
        #expect(try fixture.body == Fixture.originalBody, "the guarded revert restored the inspected head")
        #expect(fixture.breaker.windowStatus(for: try fixture.expectedKey).verificationFailures == 1)

        let facts = try fixture.recordFacts(outcome)
        #expect(facts.wasAutoReverted)
        #expect(facts.wroteSurvivingRepair == false, "nothing survives to undo")
        #expect(facts.verificationFailureReasons.contains {
            $0.contains("per-finding repair changed finding D26-1")
        }, "the disclosure shows what verification caught")
        #expect(facts.perFindingID == "D06-1")
    }

    /// (b′) The wrong finding repaired, the target left in place: the
    /// write changed bytes for nothing it was asked to — reverted.
    @Test func wrongFindingRepairFailsVerification() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.readyPlan(fixture.target())
        try fixture.stageAgentArtifacts(for: plan, repaired: [])
        _ = try fixture.agentWrite(Fixture.wrongFindingRepair)

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .failed)
        #expect(outcome.detail.contains("its finding D06-1 persists on the written head"))
        #expect(try fixture.body == Fixture.originalBody)
    }

    /// A careful no-op (the agent could not repair from verified evidence
    /// and wrote nothing) is a valid outcome: verified, nothing to revert,
    /// nothing to undo.
    @Test func carefulNoOpIsNotAFailure() async throws {
        let fixture = try Fixture()
        let runStart = Date()
        let plan = try await fixture.readyPlan(fixture.target())
        try fixture.stageAgentArtifacts(for: plan, repaired: [])

        let outcome = fixture.account(plan, runStart: runStart)

        #expect(outcome.status == .dispatched, "\(outcome.detail)")
        #expect(outcome.revert == nil)
        #expect(try fixture.body == Fixture.originalBody)
        #expect(try fixture.recordFacts(outcome).wroteSurvivingRepair == false)
    }

    /// (c) The head moved since the person saw the finding: refused before
    /// launch, NO write, the honest message, the refusal on the record, and
    /// no breaker outcome (nothing ran).
    @Test func headMovedRefusesWithoutWriting() async throws {
        let fixture = try Fixture()
        let humanEdit = Fixture.originalBody + "\nA human edit.\n"
        _ = try fixture.agentWrite(humanEdit)

        let target = fixture.target()
        guard case .refused(let refusal, let title, let reason) = await fixture.planResult(target) else {
            Issue.record("a moved head must refuse")
            return
        }
        #expect(refusal == .pageChanged)
        #expect(reason.contains("head moved from \(fixture.inspectedHead.rawValue)"))

        let outcome = AgentOperationRunner.perFindingRefusalOutcome(
            refusal, title: title, detail: reason, pageID: fixture.page.id,
            target: target, store: fixture.store)
        #expect(outcome.status == .skipped)
        #expect(outcome.detail.hasPrefix("Page changed since this finding — re-run lint."))
        #expect(try fixture.body == humanEdit, "no write")
        let facts = try fixture.recordFacts(outcome)
        #expect(facts.perFindingRefusal == .pageChanged)
        #expect(facts.perFindingID == "D06-1")
        #expect(facts.wroteSurvivingRepair == false)
        #expect(fixture.breaker.windowStatus(for: try fixture.expectedKey).verificationFailures == 0)
        let audit = try fixture.store.recentLogEntries(limit: 10)
            .first { $0.title == "Selected-page lint — Fix Target" }
        #expect(audit?.note?.contains("per_finding_outcome=page-changed") == true,
                "the refusal is as traceable as a run")
    }

    /// (d) The current head's scan no longer detects the finding (same
    /// head, a finding id this scan does not have): the same honest
    /// page-changed refusal. A report-only or unknown class refuses too.
    @Test func findingGoneOrUnrepairableRefuses() async throws {
        let fixture = try Fixture()

        guard case .refused(let gone, _, let reason) = await fixture.planResult(
            fixture.target("D06-9")) else {
            Issue.record("a finding the scan no longer detects must refuse")
            return
        }
        #expect(gone == .pageChanged)
        #expect(reason.contains("no longer detects finding D06-9"))

        for label in ["D02", "D21", "D99"] {
            guard case .refused(let refusal, _, _) = await fixture.planResult(
                fixture.target("\(label)-1", classLabel: label)) else {
                Issue.record("\(label) must refuse")
                continue
            }
            #expect(refusal == .notRepairable, "\(label)")
        }
        #expect(try fixture.body == Fixture.originalBody)

        let unavailable = AgentOperationRunner.perFindingRefusalOutcome(
            .modelUnavailable, title: "Fix Target", detail: "no model selected",
            pageID: fixture.page.id, target: fixture.target(), store: fixture.store)
        #expect(unavailable.status == .failed)
        #expect(unavailable.detail.contains("check Settings"))
    }
}
#endif
