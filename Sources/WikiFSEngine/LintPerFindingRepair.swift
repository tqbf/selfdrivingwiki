import Foundation
import WikiFSCore
import WikiFSTypes

/// The pre-launch refusals of a user-triggered per-finding repair. A
/// refusal writes nothing and launches no agent. Recorded on the durable
/// per-page record as `per_finding_outcome=<raw value>`; the Run Details
/// rows render the honest message for each.
public enum LintPerFindingRefusal: String, Sendable, Equatable, CaseIterable {
    /// The page's head moved past the head the person saw, or the pre-run
    /// scan of the current head no longer detects the finding.
    case pageChanged = "page-changed"
    /// The page no longer exists.
    case pageMissing = "page-missing"
    /// The finding's class may not be repaired by a lint run (a report-only
    /// or out-of-scope class, or a class label this build does not know).
    case notRepairable = "not-repairable"
    /// The configured lint model could not start (unconfigured, refused by
    /// the spawn guard, or unavailable) — nothing ran.
    case modelUnavailable = "model-unavailable"

    /// The user-facing sentence for this refusal (the Run Details row and
    /// the record detail carry the same words).
    public var message: String {
        switch self {
        case .pageChanged:
            return "Page changed since this finding — re-run lint."
        case .pageMissing:
            return "The page no longer exists."
        case .notRepairable:
            return "This finding's class is report-only — edit the page manually."
        case .modelUnavailable:
            return "The lint model could not start — check Settings (the lint stage's provider and model)."
        }
    }
}

/// The user-triggered per-finding repair (the amended ladder's per-finding
/// tier): a person clicked **Fix** on ONE finding in Run Details. The click
/// IS the authorization, so the rollout gate (`LintCoordinatorGate`) is not
/// consulted at all — this is not unsupervised repair. The full enforcement
/// net wraps the attempt instead: the per-finding policy (patch that page
/// only, CAS receipt, one finding's patch budget), the shared post-run
/// accounting (coverage, written-head verification + the one-finding scope
/// rule, ONE guarded CAS revert on failure), breaker accumulation under the
/// configuration the launcher actually spawned, and the W2b one-click Undo
/// for a surviving write.
///
/// The host flow (the daemon queue provider): `makePerFindingRepairPlan` →
/// launch the agent with `plan.request` → `perFindingPlanAfterLaunch` →
/// the shared `accountForLintRun`. A refusal skips the launch and records
/// `perFindingRefusalOutcome` instead.
public extension AgentOperationRunner {

    /// The per-finding plan builder's result: a plan ready to launch, or a
    /// pre-launch refusal (nothing written, nothing launched).
    enum PerFindingPlanResult: Sendable {
        case ready(LintPagePlan)
        case refused(LintPerFindingRefusal, title: String, detail: String)
    }

    /// Build the ONE-finding repair plan for a person's Fix click. The plan
    /// is seeded with the target finding as the TRUSTED pre-run scan of the
    /// CURRENT head finds it (id, class, range, evidence, message) — never
    /// with the payload's words — and requests the per-finding policy. The
    /// gate is not consulted; the breaker key is unknown until launch (see
    /// `perFindingPlanAfterLaunch`).
    ///
    /// Refuses, without launching, when the page is gone, the head moved
    /// past the head the person saw, the current scan no longer detects the
    /// finding, or the class may not be repaired.
    static func makePerFindingRepairPlan(
        store: WikiStore,
        pageID: PageID,
        target: LintRepairTarget,
        stateMarkdown: String,
        breaker: LintRepairBreaker
    ) async -> PerFindingPlanResult {
        guard let defectClass = target.defectClass,
              defectClass.repairPolicy == .repairable else {
            return .refused(.notRepairable, title: "",
                detail: "class \(target.classLabel) may not be repaired by a lint run")
        }
        guard let scan = await scanLintPage(store: store, pageID: pageID) else {
            return .refused(.pageMissing, title: "",
                detail: "page does not exist (deleted or renamed before the run)")
        }
        let title = scan.snapshot.title
        let currentHead = scan.snapshot.headVersionID
        guard currentHead == target.expectedHead else {
            return .refused(.pageChanged, title: title,
                detail: "head moved from \(target.expectedHead.rawValue) to "
                    + "\(currentHead?.rawValue ?? "none") since this finding")
        }
        guard let finding = scan.report.sections.flatMap(\.findings).first(where: {
            $0.occurrenceID == target.findingID && $0.defectClass == defectClass
        }) else {
            return .refused(.pageChanged, title: title,
                detail: "the current head's scan no longer detects finding \(target.findingID)")
        }
        let focus = LintRepairFocus(finding)
        let authority = LintRepairAuthority.perFindingRepair(findingID: focus.occurrenceID)
        let request = OperationRequest.lintPage(
            page: LintPageIdentity(scan.snapshot),
            mode: .perFindingRepair(focus),
            gateReason: authority.reason ?? "user-triggered repair",
            preflightReportMarkdown: scan.report.renderedMarkdown(),
            runReportMarkdown: LintRunReportText.render(
                snapshot: scan.snapshot, preflight: scan.report),
            stateMarkdown: stateMarkdown)
        return .ready(LintPagePlan(
            request: request, snapshot: scan.snapshot, preflight: scan.report,
            authority: authority, breakerKey: nil, breaker: breaker,
            requiredChecksAvailable: scan.requiredChecksAvailable,
            repairFocus: focus))
    }

    /// The breaker key for what the launcher ACTUALLY spawned: this build's
    /// live pipeline digest + the launched provider, model, and effort (an
    /// unpinned effort records `agent-default`). `nil` when nothing spawned
    /// or the pipeline cannot be computed — the accounting then records no
    /// breaker outcome rather than inventing a configuration.
    /// Nonisolated: a pure read of this build's pipeline.
    nonisolated static func launchedBreakerKey(
        _ launched: LaunchedAgentConfiguration?
    ) -> LintRepairBreakerKey? {
        guard let launched, let model = launched.model else { return nil }
        do {
            return LintRepairBreakerKey(
                pipeline: try LintAcceptanceManifest.Pipeline.live(),
                provider: launched.provider.rawValue,
                model: model.rawValue,
                effort: launched.effort ?? LintRepairBreakerKey.agentDefaultEffort)
        } catch {
            DebugLog.agent("per-finding repair: pipeline unavailable, no breaker key: \(error)")
            return nil
        }
    }

    /// The plan the post-run accounting reads: the launched configuration's
    /// breaker key recorded onto the per-finding plan. Nonisolated: pure
    /// over its inputs (the daemon host calls it off the main actor).
    nonisolated static func perFindingPlanAfterLaunch(
        _ plan: LintPagePlan,
        launched: LaunchedAgentConfiguration?
    ) -> LintPagePlan {
        LintPagePlan(
            request: plan.request, snapshot: plan.snapshot, preflight: plan.preflight,
            authority: plan.authority, breakerKey: launchedBreakerKey(launched),
            breaker: plan.breaker, requiredChecksAvailable: plan.requiredChecksAvailable,
            repairFocus: plan.repairFocus)
    }

    /// The durable outcome of a refused per-finding repair: `.skipped`, no
    /// write, the refusal label the Run Details rows read, and the target
    /// finding. Also appends the host's `--kind lint` audit record so the
    /// refusal is as traceable as a run.
    static func perFindingRefusalOutcome(
        _ refusal: LintPerFindingRefusal,
        title: String,
        detail reason: String,
        pageID: PageID,
        target: LintRepairTarget,
        store: WikiStore
    ) -> LintPageDispatchOutcome {
        let authority = LintRepairAuthority.perFindingRepair(findingID: target.findingID)
        var detail = "\(refusal.message) No change was written: \(reason)"
            + "; \(LintPageRecordFacts.perFindingLabel)=\(target.findingID)"
            + "; \(LintPageRecordFacts.perFindingOutcomeLabel)=\(refusal.rawValue)"
            + "; \(authority.auditLabels)"
        let token = title.isEmpty ? pageID.rawValue : title
        do {
            try store.appendLog(
                kind: .lint,
                title: "Selected-page lint — \(token)",
                note: "host audit record; \(detail)")
        } catch {
            detail += "; HOST LOG APPEND FAILED: \(error)"
        }
        return LintPageDispatchOutcome(
            pageID: pageID, title: title,
            status: refusal == .modelUnavailable ? .failed : .skipped,
            detail: detail, authority: authority)
    }
}
