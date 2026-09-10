import Foundation
import WikiFSCore

/// Shared builder for ingestion/lint report mutations. Both the daemon and
/// app `QueueIngestionProvider` implementations feed their observed staging
/// facts through this one type, so the two hosts report identical facts from
/// identical code (the plan's parity requirement) and tests can pin the
/// facts directly.
///
/// Truth rules enforced here:
/// - Per-source ingestion completion is NEVER inferred from agent exit or
///   merge success — staged sources stay `.submitted`.
/// - Agent lint completion reports availability `.notReported`; the current
///   agent has no typed page-findings contract and none is invented.
/// - Missing sources/pages are recorded `.skipped` with the observed reason.
public enum QueueIngestionReporting {

    /// The observed outcome of staging one requested source.
    public enum StagingOutcome: Sendable, Hashable {
        /// The source resolved, its bytes were available, and it was staged
        /// for the agent under `name`.
        case staged(name: String)
        /// The source row or its bytes were unavailable at staging time.
        case bytesUnavailable
    }

    /// The staging mutation for one ingestion run: exact per-requested-source
    /// outcomes from the actual staging pass, plus the `.staging` phase.
    public static func stagingMutation(
        requested: [(id: SourceID, outcome: StagingOutcome)]
    ) -> QueueReportMutation {
        QueueReportMutation(
            phase: .staging,
            targetUpserts: requested.map { request in
                switch request.outcome {
                case .staged(let name):
                    return QueueReportTargetRecord(
                        target: .source(request.id),
                        displayName: name,
                        state: .submitted)
                case .bytesUnavailable:
                    return QueueReportTargetRecord(
                        target: .source(request.id),
                        state: .skipped(reason: "Source bytes unavailable"))
                }
            })
    }

    /// The launch mutation: the ACTUAL selected provider at launch. The
    /// scheduler's capacity bucket (e.g. `default-ingest`) is never reported
    /// as the provider.
    public static func launchMutation(providerID: ProviderID) -> QueueReportMutation {
        QueueReportMutation(phase: .launching, provider: providerID)
    }

    /// The agent-run phase mutation, emitted immediately before the launcher
    /// takes over.
    public static func runningMutation() -> QueueReportMutation {
        QueueReportMutation(phase: .running)
    }

    /// The completion mutation for a successful AGENT run whose per-target
    /// outcomes the runner cannot prove. Staged sources stay `.submitted`;
    /// lint pages stay `.processing`; availability is `.notReported`.
    /// The launcher's accumulated run-total usage rides along as the durable
    /// report-header `usage` — the same values the navigator showed live —
    /// so Run Details keeps final totals after completion/reload.
    public static func agentCompletionMutation(
        operation: QueueReportOperation,
        usage: SessionUsage?,
        outputs: [QueueRecordedOutputPage]? = nil
    ) -> QueueReportMutation {
        let summary: String
        switch operation {
        case .ingest:
            summary = "Agent run completed; per-source ingestion outcomes are not reported"
        case .lint:
            summary = "Agent run completed; page-level results not reported"
        case .extract:
            summary = "Agent run completed"
        }
        return QueueReportMutation(
            phase: .finished,
            model: usage?.modelId.map { QueueReportModelName(rawValue: $0) },
            availability: .notReported,
            resultSummary: summary,
            usage: usage.map(QueueReportUsage.init(sessionUsage:)),
            outputs: outputs)
    }

    /// The lint-page staging mutation: resolved pages are recorded by their
    /// actual titles; requested pages that could not be resolved are recorded
    /// `.skipped` (never silently dropped from the inventory).
    public static func lintPagesStagingMutation(
        resolved: [(id: PageID, title: String)],
        requested: [PageID]
    ) -> QueueReportMutation {
        let resolvedByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.title) })
        var records: [QueueReportTargetRecord] = []
        records.reserveCapacity(requested.count)
        for pageID in requested {
            if let title = resolvedByID[pageID] {
                records.append(QueueReportTargetRecord(
                    target: .page(pageID),
                    displayName: title,
                    state: .processing))
            } else {
                records.append(QueueReportTargetRecord(
                    target: .page(pageID),
                    state: .skipped(reason: "Requested page not found")))
            }
        }
        return QueueReportMutation(phase: .staging, targetUpserts: records)
    }
}

// MARK: - SessionUsage ↔ durable report usage

extension QueueReportUsage {
    /// Map the launcher's live run-total usage onto the durable report-header
    /// value the queue store persists. The token/cost/currency fields carry
    /// over 1:1; SessionUsage-only fields (context window, per-model labels)
    /// are not part of the durable header — the report's own provider/model
    /// columns already carry the labels.
    public init(sessionUsage usage: SessionUsage) {
        self.init(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cachedReadTokens: usage.cachedReadTokens,
            thoughtTokens: usage.thoughtTokens,
            cost: usage.cost,
            currency: usage.currency)
    }
}

extension SessionUsage {
    /// Map a durable report-header usage back onto the snapshot vocabulary
    /// the Run Details panel renders. Context-window fields have no durable
    /// counterpart and are zeroed — the panel never renders them.
    public init(reportUsage: QueueReportUsage) {
        self.init(
            inputTokens: reportUsage.inputTokens,
            outputTokens: reportUsage.outputTokens,
            totalTokens: reportUsage.inputTokens + reportUsage.outputTokens,
            cachedReadTokens: reportUsage.cachedReadTokens,
            thoughtTokens: reportUsage.thoughtTokens,
            cost: reportUsage.cost,
            currency: reportUsage.currency,
            contextUsed: 0,
            contextSize: 0)
    }
}
