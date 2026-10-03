import Foundation

/// How a result set was produced. Only the live runner executing real
/// ingestion against the configured provider may say `.live` — a canned or
/// dry-run result that labels itself live is exactly the false claim this type
/// exists to prevent (plan Phase 5.4: "A fake pass is not a live semantic
/// pass").
public enum EvaluationRunKind: String, Sendable, Codable {
    /// Real configured provider, real launcher, real ingestion into a
    /// disposable fixture database, captured from the store after the run.
    case live
    /// Canned observations fed through the same evaluator (harness tests,
    /// negative controls). Never a release-evidence pass.
    case canned
    /// Fixture/plan validation only; no provider was contacted.
    case dryRun
}

/// Traversal evidence for ONE agent turn through the production agent loop
/// (turn-started → pre-step waterfall → request waterfall → backend stream →
/// step-completed → turn-completed). Produced only by the live runner's
/// observation-only loop listener; the loop itself is the real
/// `AgentLoopPlugin` activation.
public struct EvaluationAgentLoopTurn: Sendable, Equatable, Codable {
    public var turnID: String
    public var chatID: String
    /// Characters of the prompt DELIVERED to the backend (measured after the
    /// pre-step and request waterfalls ran). Equal to the entered prompt's
    /// length unless a listener transformed it.
    public var deliveredPromptCharacters: Int
    /// Events the completed step streamed (a short-circuited step carries its
    /// canned events instead).
    public var streamedEventCount: Int
    /// True when the loop emitted turn-completed for this turn.
    public var completed: Bool

    public init(
        turnID: String,
        chatID: String,
        deliveredPromptCharacters: Int,
        streamedEventCount: Int,
        completed: Bool
    ) {
        self.turnID = turnID
        self.chatID = chatID
        self.deliveredPromptCharacters = deliveredPromptCharacters
        self.streamedEventCount = streamedEventCount
        self.completed = completed
    }
}

/// One ingestion batch's COMPLETE run evidence: the prompt context rendered
/// before the run, the loop traversal of every agent turn the run sent, and
/// the run artifacts (agent log, wire trace, usage). Retained per batch —
/// earlier batches are no longer overwritten by later ones.
public struct EvaluationBatchRecord: Sendable, Equatable, Codable {
    /// Zero-based position of the batch inside its leg.
    public var index: Int
    /// The leg this batch ran in ("run", "leg1", "leg2").
    public var legLabel: String
    public var sourceFilenames: [String]
    /// The state markdown rendered from the leg's wiki just before this
    /// batch's agent run — the wiki-state half of the prompt.
    public var stateMarkdown: String
    public var startedAt: Date
    public var finishedAt: Date
    public var usage: UsageSnapshot?
    public var logFileURL: String?
    public var debugFolderURL: String?
    public var agentLoopTurns: [EvaluationAgentLoopTurn]
    public var error: String?

    public init(
        index: Int,
        legLabel: String,
        sourceFilenames: [String],
        stateMarkdown: String,
        startedAt: Date,
        finishedAt: Date,
        usage: UsageSnapshot? = nil,
        logFileURL: String? = nil,
        debugFolderURL: String? = nil,
        agentLoopTurns: [EvaluationAgentLoopTurn] = [],
        error: String? = nil
    ) {
        self.index = index
        self.legLabel = legLabel
        self.sourceFilenames = sourceFilenames
        self.stateMarkdown = stateMarkdown
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.usage = usage
        self.logFileURL = logFileURL
        self.debugFolderURL = debugFolderURL
        self.agentLoopTurns = agentLoopTurns
        self.error = error
    }
}

/// One leg (one fresh wiki) of a scenario: its strategy, its disposable
/// database, and every batch's evidence. Two-source scenarios have one leg;
/// the documentation-strategy scenario has two.
public struct EvaluationLegRecord: Sendable, Equatable, Codable {
    public var label: String
    public var strategyName: String
    public var wikiID: String
    public var databasePath: String
    public var batches: [EvaluationBatchRecord]

    public init(
        label: String,
        strategyName: String,
        wikiID: String,
        databasePath: String,
        batches: [EvaluationBatchRecord] = []
    ) {
        self.label = label
        self.strategyName = strategyName
        self.wikiID = wikiID
        self.databasePath = databasePath
        self.batches = batches
    }
}

/// Metadata about one scenario's live run: what ran, against what, and what
/// it cost. Non-secret: provider id/label/model only, never credentials.
public struct ScenarioRunMetadata: Sendable, Equatable, Codable {
    public var runKind: EvaluationRunKind
    public var scenarioID: EvaluationScenarioID
    public var startedAt: Date
    public var finishedAt: Date
    public var wikiID: String
    public var databasePath: String
    public var providerID: String?
    public var providerLabel: String?
    public var modelID: String?
    public var usage: UsageSnapshot?
    public var logFileURL: String?
    public var debugFolderURL: String?
    public var stateMarkdown: String
    public var error: String?
    /// Whether the scenario's wiki strategy document was actually delivered
    /// to the wiki before the run. When false, the strategy-dependent checks
    /// measure only default behavior, and the report says so — never a silent
    /// strategy claim.
    public var strategyDelivered: Bool
    public var strategyDeliveryNote: String?
    /// Per-leg, per-batch run evidence: every leg's strategy and disposable
    /// database, every batch's prompt context (state markdown), agent-loop
    /// traversal, and run artifacts. nil on legacy records; the scalar fields
    /// above (`stateMarkdown`, `logFileURL`, `debugFolderURL`) remain the
    /// FINAL batch's values for report-API compatibility.
    public var legs: [EvaluationLegRecord]?

    public init(
        runKind: EvaluationRunKind,
        scenarioID: EvaluationScenarioID,
        startedAt: Date,
        finishedAt: Date,
        wikiID: String,
        databasePath: String,
        providerID: String? = nil,
        providerLabel: String? = nil,
        modelID: String? = nil,
        usage: UsageSnapshot? = nil,
        logFileURL: String? = nil,
        debugFolderURL: String? = nil,
        stateMarkdown: String = "",
        error: String? = nil,
        strategyDelivered: Bool = false,
        strategyDeliveryNote: String? = nil,
        legs: [EvaluationLegRecord]? = nil
    ) {
        self.runKind = runKind
        self.scenarioID = scenarioID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wikiID = wikiID
        self.databasePath = databasePath
        self.providerID = providerID
        self.providerLabel = providerLabel
        self.modelID = modelID
        self.usage = usage
        self.logFileURL = logFileURL
        self.debugFolderURL = debugFolderURL
        self.stateMarkdown = stateMarkdown
        self.error = error
        self.strategyDelivered = strategyDelivered
        self.strategyDeliveryNote = strategyDeliveryNote
        self.legs = legs
    }
}

/// One scenario's machine-readable result: metadata + structural evaluation.
public struct ScenarioResultRecord: Sendable, Codable {
    public var metadata: ScenarioRunMetadata
    public var evaluation: ScenarioEvaluation

    public init(metadata: ScenarioRunMetadata, evaluation: ScenarioEvaluation) {
        self.metadata = metadata
        self.evaluation = evaluation
    }
}

/// The whole run's machine-readable output (`results.json`).
public struct EvaluationResultsFile: Sendable, Codable {
    public var runKind: EvaluationRunKind
    public var generatedAt: Date
    public var results: [ScenarioResultRecord]
    /// True only for a LIVE run whose every scenario completed with its
    /// strategy delivered and every structural evaluation passing. Canned and
    /// dry-run files can NEVER claim this verdict — a scripted pass is not a
    /// live semantic pass.
    public var allPassed: Bool

    public init(runKind: EvaluationRunKind, generatedAt: Date, results: [ScenarioResultRecord]) {
        self.runKind = runKind
        self.generatedAt = generatedAt
        self.results = results
        self.allPassed = runKind == .live
            && !results.isEmpty
            && results.allSatisfy { record in
                record.evaluation.passed
                    && record.metadata.error == nil
                    && record.metadata.strategyDelivered
            }
    }
}

/// Writes the machine-readable and human-readable reports. Stateless value
/// type — safe to hold anywhere, including inside a Sendable harness.
public struct EvaluationReportWriter: Sendable {
    public init() {}

    // MARK: - Machine-readable

    public func writeResultsJSON(_ results: EvaluationResultsFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(results)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Human-readable

    /// Markdown report: per-scenario check tables, run metadata, and the
    /// human rubric section the operator fills in. The rubric has NO
    /// machine answer — the report leaves the decision cells empty.
    public func markdownReport(scenario: EvaluationScenario, record: ScenarioResultRecord) -> String {
        var lines: [String] = []
        let meta = record.metadata
        lines.append("# \(scenario.id.displayName)")
        lines.append("")
        lines.append("- Run kind: **\(meta.runKind.rawValue)**")
        lines.append("- Verdict (structural): **\(record.evaluation.passed ? "PASS" : "FAIL")**")
        if !meta.strategyDelivered {
            lines.append("- Strategy delivered to the wiki: **NO** — strategy-dependent checks below measured DEFAULT behavior only.")
            if let note = meta.strategyDeliveryNote {
                lines.append("  - \(note)")
            }
        } else {
            lines.append("- Strategy delivered to the wiki: yes (\(scenario.strategy.name))")
        }
        if let error = meta.error {
            lines.append("- Run error: \(error)")
        }
        lines.append("- Wiki: \(meta.wikiID) at `\(meta.databasePath)`")
        if let provider = meta.providerLabel, let model = meta.modelID {
            lines.append("- Provider: \(provider) — model \(model)")
        } else if let provider = meta.providerLabel {
            lines.append("- Provider: \(provider)")
        }
        if let usage = meta.usage {
            var usageLine = "- Usage: \(usage.totalTokens) tokens"
            if let cost = usage.cost {
                usageLine += String(format: ", cost %.4f", cost)
            }
            lines.append(usageLine)
        }
        if let log = meta.logFileURL { lines.append("- Agent log: `\(log)`") }
        if let debug = meta.debugFolderURL { lines.append("- Wire trace: `\(debug)`") }
        lines.append("")

        lines.append("## Structural checks")
        lines.append("")
        lines.append("| Check | Result | Detail |")
        lines.append("| --- | --- | --- |")
        for outcome in record.evaluation.outcomes {
            lines.append("| `\(outcome.id)` | \(outcome.passed ? "PASS" : "FAIL") | \(outcome.detail.replacingOccurrences(of: "|", with: "\\|")) |")
        }
        lines.append("")

        appendRunEvidence(meta.legs, to: &lines)

        lines.append("## Human rubric (decide by hand — no evaluator model answers these)")
        lines.append("")
        for (index, question) in scenario.rubric.enumerated() {
            lines.append("### Q\(index + 1). \(question.question)")
            lines.append("")
            lines.append("Look for: \(question.lookFor)")
            lines.append("")
            lines.append("- Decision: PASS / FAIL / UNCLEAR (fill in after reading the page)")
            lines.append("- Evidence (quote the page): ")
            lines.append("")
        }

        lines.append("## State markdown sent to the agent")
        lines.append("")
        lines.append("```markdown")
        lines.append(meta.stateMarkdown.isEmpty ? "(not captured)" : meta.stateMarkdown)
        lines.append("```")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Per-leg, per-batch run evidence: every leg's strategy and disposable
    /// database, then one block per batch — sources, window, agent-loop
    /// traversal (turn ids + delivered prompt sizes), usage, and artifacts.
    /// Skipped entirely on legacy records with no `legs`.
    private func appendRunEvidence(_ legs: [EvaluationLegRecord]?, to lines: inout [String]) {
        guard let legs, !legs.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        lines.append("## Run evidence (per leg, per batch)")
        lines.append("")
        for leg in legs {
            lines.append("### Leg `\(leg.label)` — strategy \"\(leg.strategyName)\" — wiki \(leg.wikiID) at `\(leg.databasePath)`")
            lines.append("")
            guard !leg.batches.isEmpty else {
                lines.append("(no batch completed on this leg)")
                lines.append("")
                continue
            }
            for batch in leg.batches {
                lines.append("#### Batch \(batch.index) — sources: \(batch.sourceFilenames.joined(separator: ", "))")
                lines.append("")
                lines.append("- Window: \(formatter.string(from: batch.startedAt)) → \(formatter.string(from: batch.finishedAt))")
                let completedTurns = batch.agentLoopTurns.filter(\.completed).count
                lines.append("- Agent loop turns: \(batch.agentLoopTurns.count) (\(completedTurns) completed)")
                if !batch.agentLoopTurns.isEmpty {
                    let prompts = batch.agentLoopTurns
                        .map { "\($0.turnID.prefix(8))→\($0.deliveredPromptCharacters) chars/\($0.streamedEventCount) events" }
                        .joined(separator: "; ")
                    lines.append("- Turn traversal (turn→delivered prompt/events): \(prompts)")
                }
                if let usage = batch.usage {
                    var usageLine = "- Usage: \(usage.totalTokens) tokens"
                    if let cost = usage.cost {
                        usageLine += String(format: ", cost %.4f", cost)
                    }
                    lines.append(usageLine)
                }
                if let log = batch.logFileURL { lines.append("- Agent log: `\(log)`") }
                if let debug = batch.debugFolderURL { lines.append("- Wire trace: `\(debug)`") }
                if let error = batch.error {
                    lines.append("- Batch error: \(error)")
                }
                lines.append("")
                lines.append("State markdown before this batch:")
                lines.append("")
                lines.append("```markdown")
                lines.append(batch.stateMarkdown.isEmpty ? "(not captured)" : batch.stateMarkdown)
                lines.append("```")
                lines.append("")
            }
        }
    }

    public func writeMarkdownReport(scenario: EvaluationScenario, record: ScenarioResultRecord, to url: URL) throws {
        let markdown = markdownReport(scenario: scenario, record: record)
        guard let data = markdown.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: [.atomic])
    }
}
