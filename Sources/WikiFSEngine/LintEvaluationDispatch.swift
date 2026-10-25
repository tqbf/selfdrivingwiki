import Foundation
import WikiFSCore
import WikiFSTypes

/// The harness-only EVALUATION admission dispatch (plan §6.3): the live gate
/// driver runs repair-capable selected-page lint through the REAL coordinator
/// path — the same plan builder, launcher, scoped-run lease, and post-run
/// accounting production uses — but the authority comes from the evaluation
/// admission (`LintAcceptanceGate.evaluationAdmission`), never from the
/// shipped approval manifest and never from the breaker state.
///
/// Hard bounds, enforced here and nowhere else:
/// - Only wiki ids the harness JUST created (and passes as
///   `admittedWikiIDs`) can receive the repair-capable lease. An operator
///   wiki is report-only, no matter what the caller supplies.
/// - Only the exact evaluated configuration (`LintAcceptanceKey.Components`
///   the driver resolved from the operator's provider configuration) is
///   admitted; any drift inside the plan builder consults report-only.
/// - The circuit breaker still has its say (it can only demote), and its
///   outcomes are recorded under the evaluated configuration's key.
public extension AgentOperationRunner {

    /// The approval-id label the evaluation admission's repair-capable
    /// authority carries. Not a shipped approval row: audit records and
    /// reports name the admission so evaluation evidence can never be
    /// mistaken for a shipped approval.
    static let evaluationAdmissionApprovalID = "evaluation-admission"

    /// One trial's admission: the evaluated configuration plus the disposable
    /// wiki ids the harness created for THIS run.
    struct LintEvaluationAdmission: Sendable {
        /// The configuration under evaluation (provider, model, advertised
        /// revision when available, effective effort, and this build's
        /// pipeline digests).
        public let evaluated: LintAcceptanceKey.Components
        /// The disposable wiki ids the harness created. A requested wiki
        /// outside this set is refused (report-only).
        public let admittedWikiIDs: Set<WikiID>

        public init(evaluated: LintAcceptanceKey.Components, admittedWikiIDs: Set<WikiID>) {
            self.evaluated = evaluated
            self.admittedWikiIDs = admittedWikiIDs
        }
    }

    /// Build one page's lint plan under the evaluation admission. Returns
    /// `nil` when the page does not exist (the caller records a skipped
    /// outcome) — the same contract as `makeLintPagePlan`.
    static func makeEvaluationLintPagePlan(
        store: WikiStore,
        pageID: PageID,
        stateMarkdown: String,
        admission: LintEvaluationAdmission,
        requestedWikiID: WikiID,
        breaker: LintRepairBreaker
    ) async -> LintPagePlan? {
        let plan = await makeLintPagePlan(
            store: store,
            pageID: pageID,
            stateMarkdown: stateMarkdown,
            gateInputs: LintGateInputs(
                provider: admission.evaluated.provider,
                model: admission.evaluated.model,
                modelRevision: admission.evaluated.modelRevision,
                effort: admission.evaluated.effort),
            selection: { inputs in
                // 1. Wiki scope FIRST and absolute: only a disposable harness
                //    wiki is admissible, whatever the configuration says.
                guard LintAcceptanceGate.evaluationAdmission(
                    admittedWikiIDs: admission.admittedWikiIDs,
                    requestedWikiID: requestedWikiID) else {
                    return .reportOnly(reason:
                        "evaluation admission refused: the requested wiki is not a disposable harness wiki")
                }
                // 2. Configuration identity: the components this plan would
                //    consult must equal the declared evaluated configuration.
                //    A drift (provider reconfigured mid-run, effort changed)
                //    is a refusal, never a silent re-target.
                let consulted: LintAcceptanceKey.Components
                do {
                    consulted = try LintCoordinatorGate.components(
                        provider: inputs.provider, model: inputs.model,
                        modelRevision: inputs.modelRevision, effort: inputs.effort)
                } catch {
                    return .reportOnly(reason: "evaluation admission refused: this build's pipeline could not be computed (\(error))")
                }
                guard consulted == admission.evaluated else {
                    return .reportOnly(reason:
                        "evaluation admission refused: the consulted configuration differs from the declared evaluated configuration")
                }
                // 3. Both bounds hold: the same selected-page PATCH policy
                //    tier 1 uses, labeled as the evaluation admission.
                return .repairAuthorized(approvalID: Self.evaluationAdmissionApprovalID)
            },
            breaker: breaker)
        // Relabel the breaker-clean path: the shared plan builder maps a
        // `.repairAuthorized` selection onto `.shippedApproval` (production's
        // only repair-capable tier at the time it was written). Under the
        // evaluation admission that label is wrong — the authority IS the
        // admission (`LintAuthorityTier.evaluationAdmission`), and eval
        // evidence must never read as a shipped approval. Demotions
        // (breakerDemoted / reportOnly / budgetExceeded) pass through.
        return await relabelEvaluationAuthority(plan: plan)
    }

    /// Dispatch ONE selected-page lint run under the evaluation admission and
    /// return its outcome — the evaluation twin of `runOneLintPage`, with the
    /// SAME post-run accounting (coverage validation, written-bytes
    /// verification, breaker recording, host audit line).
    static func runOneEvaluationLintPage(
        pageID: PageID,
        launcher: AgentLauncher,
        store: WikiStoreModel,
        wikiID: WikiID,
        changeSignaler: any ChangeSignaler,
        wikictlDirectory: String,
        admission: LintEvaluationAdmission
    ) async -> LintPageDispatchOutcome {
        let runStart = Date()
        guard let stateMarkdown = stateMarkdownForRequest(store: store, launcher: launcher),
              let plan = await makeEvaluationLintPagePlan(
                store: store.internalStore,
                pageID: pageID,
                stateMarkdown: stateMarkdown,
                admission: admission,
                requestedWikiID: wikiID,
                breaker: LintRepairBreaker.production()) else {
            return LintPageDispatchOutcome(
                pageID: pageID, title: "", status: .skipped,
                detail: "page does not exist (deleted or renamed before the run)")
        }
        await run(
            request: plan.request,
            launcher: launcher,
            store: store,
            wikiID: wikiID,
            changeSignaler: changeSignaler,
            wikictlDirectory: wikictlDirectory)
        return await MainActor.run {
            accountForLintRun(
                plan: plan, pageID: pageID, launcher: launcher,
                store: store.internalStore, runStart: runStart)
        }
    }

    /// Remap a `.shippedApproval` authority onto `.evaluationAdmission`,
    /// preserving the approval-id label and the reason. Demoted tiers are
    /// returned unchanged.
    static func relabelEvaluationAuthority(
        _ authority: LintRepairAuthority
    ) -> LintRepairAuthority {
        guard authority.tier == .shippedApproval else { return authority }
        return LintRepairAuthority(
            tier: .evaluationAdmission,
            approvalID: LintApprovalID(rawValue: evaluationAdmissionApprovalID),
            reason: authority.reason)
    }

    private static func relabelEvaluationAuthority(
        plan: LintPagePlan?
    ) async -> LintPagePlan? {
        guard let plan else { return nil }
        let relabeled = relabelEvaluationAuthority(plan.authority)
        guard relabeled != plan.authority else { return plan }
        return LintPagePlan(
            request: plan.request,
            snapshot: plan.snapshot,
            preflight: plan.preflight,
            authority: relabeled,
            breakerKey: plan.breakerKey,
            breaker: plan.breaker,
            requiredChecksAvailable: plan.requiredChecksAvailable)
    }
}
