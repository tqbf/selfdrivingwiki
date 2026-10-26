import Foundation
import Observation
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

/// The one foreground page-lint run. Owned by the wiki session; one active
/// dialog/run per wiki. Owns the lifecycle FSM, the run generation that
/// rejects late results, and the exact Apply handoff. Neither pipeline can
/// save wiki content — only `apply` does, and only through the app model's
/// composed write with the previewed candidate pinned.
@MainActor
@Observable
final class ForegroundLintSession {

    // MARK: - Lifecycle FSM

    enum Phase: Equatable {
        /// Capturing the snapshot.
        case preparing
        /// Check steps running.
        case checking
        /// Findings present, awaiting repair selection.
        case reviewing
        /// A repair recipe is running for the named finding/option.
        case proposing(finding: LintFindingID, option: LintOptionID)
        /// A candidate diff is on screen (proposal held).
        case previewing
        /// Apply is committing.
        case applying
        /// The page changed since capture (or the draft went dirty) —
        /// findings and the proposal are invalid until Rerun.
        case stale
        /// Cancellation in flight (in-flight steps tearing down).
        case cancelling
        /// The run failed before any review (config, capture, all-steps).
        case failed(String)
    }

    /// One check/validator step failure, surfaced distinctly from findings.
    struct StepFailure: Equatable, Identifiable {
        let id: LintStepID
        let message: String
    }

    // MARK: - Dependencies (injected; test seams)

    struct Dependencies: Sendable {
        /// The coherent capture read (off-main via WikiReadService in the app).
        var capture: @MainActor @Sendable (PageID) async throws -> LintCapture?
        /// Model-check preparation. `nil` bridges = the model step is
        /// reported as not run (never as a clean result).
        var prepareCheck: (@Sendable (ProviderID?, ModelID?) async throws -> AgentOperationPreparation)?
        var prepareRepair: (@Sendable (ProviderID?, ModelID?) async throws -> AgentOperationPreparation)?
        /// One model turn. Bound to the lint stages' tokens internally.
        var lintTurn: (@Sendable (String, String, AgentOperationPreparation) async throws -> String?)?
        var releaseToken: (@Sendable (AgentProviderAttemptToken) async -> Void)?
        /// The wiki database path + daemon socket path for script sandbox
        /// denies (nil when unknown — the denies are simply not emitted).
        var wikiDBPath: @Sendable () -> String?
        var daemonSocketPath: @Sendable () -> String?

        static let none = Dependencies(
            capture: { _ in nil },
            prepareCheck: nil, prepareRepair: nil, lintTurn: nil, releaseToken: nil,
            wikiDBPath: { nil }, daemonSocketPath: { nil })
    }

    // MARK: - State

    private(set) var phase: Phase = .preparing
    private(set) var findings: [LintFinding] = []
    private(set) var stepFailures: [StepFailure] = []
    private(set) var disabledStepIDs: [LintStepID] = []
    /// False when a model step could not run (no provider / no bridge) — the
    /// sheet shows the notice instead of a fake clean result.
    private(set) var didRunModelStep = true
    private(set) var modelNotice: String = ""
    private(set) var selectedFindingID: LintFindingID?
    private(set) var validatorFailures: [String] = []
    private(set) var proposal: LintRepairProposal?
    /// The exact candidate whose diff is on screen (post-canonicalization).
    private(set) var candidate: String?
    private(set) var appliedVersionID: PageVersionID?
    private(set) var lastError: String?

    private(set) var snapshot: LintPageSnapshot?
    private var generation = 0
    private var activeToken: AgentProviderAttemptToken?
    private let dependencies: Dependencies
    private let pipeline: LintPipelineDocument
    private let wikiID: WikiID

    /// The run identity every step binds to.
    private(set) var runID = LintRunID()


    init(wikiID: WikiID, pipeline: LintPipelineDocument, dependencies: Dependencies) {
        self.wikiID = wikiID
        self.pipeline = pipeline
        self.dependencies = dependencies
    }

    // MARK: - Configuration diagnostics

    var configProblems: [LintConfigProblem] = []

    // MARK: - Derived control state

    var canCancel: Bool {
        switch phase {
        case .preparing, .checking, .proposing, .applying: true
        default: false
        }
    }

    var canStartRepair: Bool {
        if case .reviewing = phase { return true }
        return false
    }

    var canApply: Bool {
        if case .previewing = phase { return proposal != nil && candidate != nil }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .checking, .proposing, .applying, .cancelling: true
        default: false
        }
    }

    /// Findings grouped for the sheet: page-scope first, then passages.
    var pageFindings: [LintFinding] {
        findings.filter {
            if case .page = $0.scope { return true }
            return false
        }
    }

    var passageFindings: [LintFinding] {
        findings.filter {
            if case .passage = $0.scope { return true }
            return false
        }
    }

    /// The result is present but one or more steps failed — never presented
    /// as clean.
    var isIncomplete: Bool { !stepFailures.isEmpty }

    // MARK: - Run

    /// Start (or restart) the run. Bumps the generation, invalidating every
    /// late result from earlier runs.
    func start(pageID: PageID, strategyRevision: Int?, strategyContext: String) {
        generation += 1
        runID = LintRunID()
        findings = []
        stepFailures = []
        disabledStepIDs = []
        selectedFindingID = nil
        validatorFailures = []
        proposal = nil
        candidate = nil
        appliedVersionID = nil
        lastError = nil
        didRunModelStep = true
        modelNotice = ""
        phase = .preparing
        let currentGeneration = generation
        Task {
            await runChecks(pageID: pageID, strategyRevision: strategyRevision,
                            strategyContext: strategyContext, generation: currentGeneration)
        }
    }

    /// Cancel in-flight work. Closing the sheet calls this; the run
    /// generation moves forward so late completions are rejected.
    func cancel() {
        guard canCancel else { return }
        generation += 1
        phase = .cancelling
        let token = activeToken
        let deps = dependencies
        Task {
            if let token { await deps.releaseToken?(token) }
            await MainActor.run {
                if case .cancelling = self.phase { self.phase = .failed("Cancelled.") }
            }
        }
    }

    // MARK: - Check pipeline

    private func runChecks(
        pageID: PageID, strategyRevision: Int?, strategyContext: String,
        generation currentGeneration: Int
    ) async {
        // 1. Capture the coherent snapshot.
        let capture: LintCapture?
        do {
            capture = try await dependencies.capture(pageID)
        } catch {
            failIfCurrent(
                currentGeneration, "Could not read the page: \(error)")
            return
        }
        guard let capture else {
            failIfCurrent(currentGeneration, "The page no longer exists.")
            return
        }
        let snapshot = LintPageSnapshot(
            wikiID: wikiID,
            pageID: capture.pageID,
            title: capture.title,
            body: capture.body,
            headVersionID: capture.headVersionID,
            strategyRevision: strategyRevision,
            strategyContext: strategyContext,
            relatedResources: LintRelatedResourceFacts(
                pageTitleMap: capture.facts.knownPageTitles
                    .reduce(into: [:]) { $0[$1] = $1 },
                sourceNames: Set(capture.facts.sourceEffectiveNames),
                chatTitles: capture.facts.knownChatTitles))
        guard currentGeneration == generation else { return }
        self.snapshot = snapshot
        phase = .checking

        // 2. Recipe lookup: built-in producer name → configured recipe id.
        let lookup = recipeLookup()
        let configuredRecipes = Set(pipeline.repairRecipes.map(\.id))
        let enabledRecipes = pipeline.repairRecipes.map(\.id)

        var collected: [LintFinding] = []
        var failures: [StepFailure] = []
        var disabled: [LintStepID] = []
        var modelRan = true
        var modelNoticeText = ""

        for step in pipeline.checkSteps {
            guard currentGeneration == generation else { return }
            guard step.enabled else {
                disabled.append(LintStepID(rawValue: step.id))
                continue
            }
            let stepID = LintStepID(rawValue: step.id)
            do {
                switch step.execution.kind {
                case .builtin:
                    guard let builtin = LintAnalyzer.BuiltinCheck.named(step.execution.builtin ?? "") else {
                        throw LintConfigProblem.unknownBuiltinProducer(step.execution.builtin ?? "")
                    }
                    collected += LintAnalyzer.run(
                        builtin, stepID: stepID, snapshot: snapshot,
                        facts: capture.facts, recipes: lookup)
                case .script:
                    let output = try await runScriptCheckStep(
                        step, stepID: stepID, snapshot: snapshot,
                        availableRecipes: enabledRecipes)
                    collected += try decodedCheckFindings(
                        output, stepID: stepID, snapshot: snapshot,
                        configuredRecipes: configuredRecipes,
                        limits: step.execution)
                case .acp:
                    let availability = modelAvailability()
                    guard availability == .available,
                          let prepare = dependencies.prepareCheck,
                          let turn = dependencies.lintTurn else {
                        modelRan = false
                        modelNoticeText = availability.notice
                        continue
                    }
                    let preparation = try await prepare(
                        step.execution.providerId, step.execution.modelId)
                    guard currentGeneration == generation else {
                        await dependencies.releaseToken?(preparation.selection.token)
                        return
                    }
                    activeToken = preparation.selection.token
                    defer { activeToken = nil }
                    let prompt = LintTaskPrompt.check(
                        runID: runID, snapshot: snapshot,
                        availableRecipes: enabledRecipes)
                    let raw = try await turn(
                        prompt, PublicPrompts.lintCheck, preparation)
                    await dependencies.releaseToken?(preparation.selection.token)
                    guard currentGeneration == generation else { return }
                    guard let raw else {
                        throw LintEnvelopeError.notOneJSONObject
                    }
                    collected += try decodedCheckFindings(
                        raw, stepID: stepID, snapshot: snapshot,
                        configuredRecipes: configuredRecipes,
                        limits: step.execution)
                case .decision:
                    throw LintConfigProblem.decisionModelsNotSupported(step: step.id)
                }
            } catch {
                DebugLog.lint("ForegroundLintSession: step '\(step.id)' failed: \(error)")
                failures.append(StepFailure(
                    id: stepID, message: String(describing: error)))
            }
        }
        guard currentGeneration == generation else { return }
        findings = collected
        stepFailures = failures
        disabledStepIDs = disabled
        didRunModelStep = modelRan
        modelNotice = modelNoticeText
        phase = .reviewing
    }

    /// Built-in producer → configured recipe resolution for the analyzer.
    private func recipeLookup() -> LintAnalyzer.RecipeLookup {
        let recipes = pipeline.repairRecipes
        return LintAnalyzer.RecipeLookup { producer in
            recipes.first {
                $0.execution.kind == .builtin && $0.execution.builtin == producer.rawValue
            }.map { LintRecipeID(rawValue: $0.id) }
        }
    }

    private func modelAvailability() -> LintModelAvailability {
        if dependencies.prepareCheck == nil || dependencies.lintTurn == nil {
            return .unavailable
        }
        return .available
    }

    /// Decode a check envelope into typed findings bound to THIS run/snapshot.
    private func decodedCheckFindings(
        _ raw: String, stepID: LintStepID, snapshot: LintPageSnapshot,
        configuredRecipes: Set<String>, limits: LintStepExecution
    ) throws -> [LintFinding] {
        let outputLimit = try LintExecutionLimits.validatedOutputBytes(limits.maxOutputBytes)
        let envelope = try LintEnvelopeDecoder.decodeCheck(
            raw, outputLimit: outputLimit, runID: runID, snapshot: snapshot,
            configuredRecipes: configuredRecipes)
        var findings: [LintFinding] = []
        for wire in envelope.findings {
            let severity = LintSeverity(rawValue: wire.severity) ?? .warning
            let scope: LintFindingScope
            if wire.scope == "page" {
                scope = .page
            } else {
                var ranges: [LintSourceRange] = []
                var allValid = true
                for range in wire.ranges {
                    do {
                        ranges.append(try LintSourceRange(
                            lowerBound: range.start, upperBound: range.end,
                            expectedText: range.expected, in: snapshot.body))
                    } catch {
                        DebugLog.lint("ForegroundLintSession: invalid location in finding '\(wire.id)': \(error)")
                        allValid = false
                        break
                    }
                }
                guard allValid else {
                    // An invalid passage location is an invalid RESULT — the
                    // whole step failed; surface as a step failure, never a
                    // page finding invented by the host.
                    throw LintEnvelopeError.invalidLocation(
                        finding: wire.id, detail: "range does not match the snapshot body")
                }
                scope = .passage(ranges)
            }
            findings.append(LintFinding(
                id: LintFindingID(rawValue: "\(stepID.rawValue)-\(wire.id)"),
                stepID: stepID,
                ruleID: wire.rule.map { LintRuleID(rawValue: $0) },
                severity: severity,
                message: wire.message,
                evidence: wire.evidence,
                scope: scope,
                repairOptions: wire.recipes.map { recipe in
                    LintRepairOption(
                        id: LintOptionID(rawValue: "\(wire.id)-\(recipe)"),
                        recipeID: LintRecipeID(rawValue: recipe),
                        label: pipeline.repairRecipes.first { $0.id == recipe }?.label ?? recipe)
                }))
        }
        return findings
    }

    // MARK: - Repair

    /// Select a finding (focuses highlights; no repair runs).
    func select(findingID: LintFindingID) {
        selectedFindingID = findingID
    }

    /// Run ONLY the selected option's recipe. Everything else stays put.
    func choose(option: LintRepairOption, for finding: LintFinding) {
        guard canStartRepair, let snapshot else { return }
        guard let recipe = pipeline.repairRecipes.first(where: { $0.id == option.recipeID.rawValue }) else {
            lastError = "The selected repair recipe is no longer configured. Rerun lint."
            return
        }
        generation += 1
        let currentGeneration = generation
        phase = .proposing(finding: finding.id, option: option.id)
        validatorFailures = []
        proposal = nil
        candidate = nil
        Task {
            await runRepair(
                option: option, finding: finding, recipe: recipe,
                snapshot: snapshot, generation: currentGeneration)
        }
    }

    private func runRepair(
        option: LintRepairOption, finding: LintFinding,
        recipe: LintRecipeConfig, snapshot: LintPageSnapshot,
        generation currentGeneration: Int
    ) async {
        var replacements: [LintSourceReplacement]
        do {
            switch recipe.execution.kind {
            case .builtin:
                replacements = try builtinReplacements(
                    recipe: recipe, finding: finding, snapshot: snapshot)
            case .script:
                let raw = try await runScriptRepairStep(
                    recipe, option: option, finding: finding, snapshot: snapshot)
                replacements = try decodedRepairReplacements(
                    raw, option: option, finding: finding, snapshot: snapshot,
                    limits: recipe.execution)
            case .acp:
                guard let prepare = dependencies.prepareRepair,
                      let turn = dependencies.lintTurn else {
                    throw AgentProviderRuntimeError.unavailable
                }
                let preparation = try await prepare(
                    recipe.execution.providerId, recipe.execution.modelId)
                guard currentGeneration == generation else {
                    await dependencies.releaseToken?(preparation.selection.token)
                    return
                }
                activeToken = preparation.selection.token
                defer { activeToken = nil }
                let prompt = LintTaskPrompt.repair(
                    runID: runID, snapshot: snapshot, finding: finding,
                    option: option, instruction: recipe.instruction)
                let raw = try await turn(prompt, PublicPrompts.lintRepair, preparation)
                await dependencies.releaseToken?(preparation.selection.token)
                guard currentGeneration == generation else { return }
                guard let raw else { throw LintEnvelopeError.notOneJSONObject }
                replacements = try decodedRepairReplacements(
                    raw, option: option, finding: finding, snapshot: snapshot,
                    limits: recipe.execution)
            case .decision:
                throw LintConfigProblem.decisionModelsNotSupported(step: recipe.id)
            }
        } catch {
            failIfCurrent(currentGeneration, "Repair failed: \(error)")
            return
        }
        guard currentGeneration == generation else { return }

        // Validators, in configured order. A required failure blocks the
        // preview (the proposal is dropped); optional failures are recorded.
        var failures: [String] = []
        for validator in recipe.validators {
            let outcome = runValidator(
                validator, replacements: replacements, finding: finding,
                snapshot: snapshot)
            switch outcome {
            case .approved:
                continue
            case .rejected(let message):
                if validator.required {
                    failIfCurrent(
                        currentGeneration,
                        "Validator '\(validator.id)' rejected the repair: \(message)")
                    return
                }
                failures.append("Optional validator '\(validator.id)': \(message)")
            case .unavailable(let message):
                if validator.required {
                    failIfCurrent(
                        currentGeneration,
                        "Required validator '\(validator.id)' could not run: \(message)")
                    return
                }
                failures.append("Optional validator '\(validator.id)' unavailable: \(message)")
            }
        }
        guard currentGeneration == generation else { return }

        // Build + preview the candidate: replacements applied, then the SAME
        // canonicalization the composed upsert performs (public resolvers) —
        // the diff shows exactly what Apply would persist.
        do {
            let patched = try LintProposalBuilder.build(
                replacements: replacements, snapshot: snapshot,
                finding: finding, option: option,
                candidateLimitBytes: LintExecutionLimits.maxOutputBytes)
            let canonicalCandidate = try canonicalized(patched.applying(to: snapshot.body) ?? "")
            guard let currentSnapshot = self.snapshot,
                  currentSnapshot.bodyDigest == snapshot.bodyDigest else {
                failIfCurrent(currentGeneration, "The page changed during repair — rerun lint.")
                return
            }
            let proposal = LintRepairProposal(
                snapshotDigest: currentSnapshot.bodyDigest,
                pageID: currentSnapshot.pageID,
                findingID: finding.id,
                optionID: option.id,
                recipeID: option.recipeID,
                replacements: patched.replacements)
            validatorFailures = failures
            self.proposal = proposal
            candidate = canonicalCandidate
            phase = .previewing
        } catch {
            failIfCurrent(currentGeneration, "Repair could not be previewed: \(error)")
        }
    }

    /// Discard the previewed proposal; back to reviewing.
    func discardProposal() {
        proposal = nil
        candidate = nil
        validatorFailures = []
        if case .previewing = phase { phase = .reviewing }
    }

    // MARK: - Builtin producers

    private func builtinReplacements(
        recipe: LintRecipeConfig, finding: LintFinding, snapshot: LintPageSnapshot
    ) throws -> [LintSourceReplacement] {
        guard let fix = finding.builtinFix else {
            throw LintProposalError.identityMismatch
        }
        switch recipe.execution.builtin {
        case LintBuiltinProducer.bracketCorrection.rawValue,
             LintBuiltinProducer.removeBrokenLink.rawValue:
            return [fix.replacement]
        case LintBuiltinProducer.cosmeticIndividualFix.rawValue:
            return [fix.replacement]
        case LintBuiltinProducer.verifiedReplacement.rawValue:
            // The verified target rides the fix's insert text (the option is
            // only offered when a verified target exists).
            return [fix.replacement]
        default:
            throw LintConfigProblem.unknownBuiltinProducer(recipe.execution.builtin ?? "")
        }
    }

    // MARK: - Validators

    enum ValidatorOutcome {
        case approved
        case rejected(String)
        case unavailable(String)
    }

    private func runValidator(
        _ validator: LintValidatorConfig,
        replacements: [LintSourceReplacement],
        finding: LintFinding,
        snapshot: LintPageSnapshot
    ) -> ValidatorOutcome {
        guard validator.execution.kind == .builtin,
              let name = validator.execution.builtin,
              let builtin = LintBuiltinValidator(rawValue: name) else {
            // Script/ACP validators echo-approve: zero replacements in the
            // response approves; anything else is a rejection. Unavailable
            // bridges report uncertainty rather than passing.
            return .unavailable("only built-in validators run in this version")
        }
        switch builtin {
        case .replacementBounds:
            do {
                _ = try LintProposalBuilder.applyOrThrow(replacements, to: snapshot.body)
                return .approved
            } catch {
                return .rejected(String(describing: error))
            }
        case .passageScope:
            guard case .passage(let approved) = finding.scope else { return .approved }
            for replacement in replacements {
                let contained = approved.contains {
                    $0.lowerBound <= replacement.range.lowerBound
                        && replacement.range.upperBound <= $0.upperBound
                }
                guard contained else {
                    return .rejected("a replacement escapes the finding's passage ranges")
                }
            }
            return .approved
        case .fenceIntegrity:
            let protected = WikiLinkSpan.protectedCodeRanges(in: snapshot.body)
            for replacement in replacements where replacement.newText != replacement.range.expectedText {
                let nsRange: NSRange
                do {
                    nsRange = try LintLocationAdapter.nsRange(
                        forUTF8Range: replacement.range.bounds, in: snapshot.body)
                } catch {
                    return .rejected("replacement range is not locatable: \(error)")
                }
                let intersects = protected.contains {
                    NSIntersectionRange($0, nsRange).length > 0
                }
                if intersects {
                    return .rejected("a replacement would modify fenced code")
                }
            }
            return .approved
        }
    }

    // MARK: - Canonicalization (preview parity with the store)

    private func canonicalized(_ body: String) throws -> String {
        guard let store = canonicalizationResolvers else { return body }
        return (try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: store.page,
            resolveSource: store.source,
            resolveChat: store.chat)) ?? body
    }

    /// The public resolver triple, captured once. Invoked on the main actor
    /// only (the preview seam); deliberately not `@Sendable`.
    struct CanonicalizationResolvers {
        var page: (String) throws -> PageID?
        var source: (String) throws -> SourceID?
        var chat: (String) throws -> ChatID?
    }

    var canonicalizationResolvers: CanonicalizationResolvers?

    // MARK: - Script steps

    private func runScriptCheckStep(
        _ step: LintCheckStepConfig, stepID: LintStepID,
        snapshot: LintPageSnapshot, availableRecipes: [String]
    ) async throws -> String {
        guard let executable = step.execution.executable else {
            throw LintConfigProblem.missingExecutable(path: "(empty)")
        }
        let timeout = try LintExecutionLimits.validatedTimeout(step.execution.timeoutSeconds)
        let outputLimit = try LintExecutionLimits.validatedOutputBytes(step.execution.maxOutputBytes)
        let runner = LintScriptRunner()
        let outcome = try await runner.run(.init(
            scriptURL: LintPipelineStore.resolvePath(executable, from: nil),
            arguments: step.execution.arguments ?? [],
            request: .check(runID: runID, snapshot: snapshot, availableRecipes: availableRecipes),
            timeoutSeconds: timeout, maxOutputBytes: outputLimit,
            wikiDBPath: dependencies.wikiDBPath(),
            daemonSocketPath: dependencies.daemonSocketPath()))
        outcome.scratch.remove()
        return outcome.stdout
    }

    private func runScriptRepairStep(
        _ recipe: LintRecipeConfig, option: LintRepairOption,
        finding: LintFinding, snapshot: LintPageSnapshot
    ) async throws -> String {
        guard let executable = recipe.execution.executable else {
            throw LintConfigProblem.missingExecutable(path: "(empty)")
        }
        let timeout = try LintExecutionLimits.validatedTimeout(recipe.execution.timeoutSeconds)
        let outputLimit = try LintExecutionLimits.validatedOutputBytes(recipe.execution.maxOutputBytes)
        let runner = LintScriptRunner()
        let outcome = try await runner.run(.init(
            scriptURL: LintPipelineStore.resolvePath(executable, from: nil),
            arguments: recipe.execution.arguments ?? [],
            request: .repair(
                runID: runID, snapshot: snapshot, finding: finding,
                option: option, instruction: recipe.instruction),
            timeoutSeconds: timeout, maxOutputBytes: outputLimit,
            wikiDBPath: dependencies.wikiDBPath(),
            daemonSocketPath: dependencies.daemonSocketPath()))
        outcome.scratch.remove()
        return outcome.stdout
    }

    private func decodedRepairReplacements(
        _ raw: String, option: LintRepairOption, finding: LintFinding,
        snapshot: LintPageSnapshot, limits: LintStepExecution
    ) throws -> [LintSourceReplacement] {
        let outputLimit = try LintExecutionLimits.validatedOutputBytes(limits.maxOutputBytes)
        let envelope = try LintEnvelopeDecoder.decodeRepair(
            raw, outputLimit: outputLimit, runID: runID, snapshot: snapshot,
            selectedFinding: finding, selectedOption: option)
        var replacements: [LintSourceReplacement] = []
        for wire in envelope.replacements {
            let range = try LintSourceRange(
                lowerBound: wire.start, upperBound: wire.end,
                expectedText: wire.expected, in: snapshot.body)
            replacements.append(LintSourceReplacement(range: range, newText: wire.text))
        }
        return replacements
    }

    // MARK: - Apply

    /// The exact Apply handoff. `apply` is provided by the app model wiring:
    /// it performs the composed write with the previewed candidate pinned.
    /// The session guards against double-Apply and stale state.
    func commitApplied(versionID: PageVersionID) {
        appliedVersionID = versionID
        // Invalidate snapshot-bound findings/proposals; offer Rerun.
        findings = []
        proposal = nil
        candidate = nil
        phase = .reviewing
    }

    func markStale() {
        proposal = nil
        candidate = nil
        phase = .stale
    }

    /// The coordinator's config-invalid entry: the run fails before any
    /// step with the typed problem summary (nothing to check).
    func fail(_ message: String) {
        generation += 1
        lastError = message
        phase = .failed(message)
        DebugLog.lint("ForegroundLintSession: \(message)")
    }

    private func failIfCurrent(_ currentGeneration: Int, _ message: String) {
        guard currentGeneration == generation else { return }
        lastError = message
        phase = .failed(message)
        DebugLog.lint("ForegroundLintSession: \(message)")
    }
}
