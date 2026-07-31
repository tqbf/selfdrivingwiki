// pattern: Functional Core

#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

/// Computes one turn's durable usage from cumulative snapshots emitted by one
/// provider session. The controller owns one accumulator for its current
/// claim, so no runtime or provider can author durable lifecycle state.
struct ChatTurnUsageAccumulator: Sendable {
    private let baseline: SessionUsage
    private var latestSessionSnapshot: SessionUsage?
    private(set) var values = ChatTurnUsageValues()

    init(baseline: SessionUsage) {
        self.baseline = baseline
    }

    /// Accepts a provider's cumulative session snapshot and retains only
    /// monotonic, nonnegative per-turn evidence. Missing values never erase a
    /// prior value; a changed currency makes the cost unavailable.
    @discardableResult
    mutating func record(_ snapshot: SessionUsage) -> ChatTurnUsageValues {
        let priorSession = latestSessionSnapshot
        latestSessionSnapshot = monotonicSessionSnapshot(previous: priorSession, next: snapshot)

        values = ChatTurnUsageValues(
            inputTokens: greatestValid(previous: values.inputTokens, baseline: baseline.inputTokens, snapshot: snapshot.inputTokens),
            outputTokens: greatestValid(previous: values.outputTokens, baseline: baseline.outputTokens, snapshot: snapshot.outputTokens),
            thoughtTokens: greatestValid(previous: values.thoughtTokens, baseline: baseline.thoughtTokens, snapshot: snapshot.thoughtTokens),
            cacheReadTokens: greatestValid(previous: values.cacheReadTokens, baseline: baseline.cachedReadTokens, snapshot: snapshot.cachedReadTokens),
            cacheWriteTokens: greatestValid(previous: values.cacheWriteTokens, baseline: baseline.cachedWriteTokens, snapshot: snapshot.cachedWriteTokens),
            cost: mergedCost(snapshot: snapshot),
            currency: mergedCurrency(snapshot: snapshot)
        )
        return values
    }

    private func greatestValid(
        previous: Int?,
        baseline: Int?,
        snapshot: Int?
    ) -> Int? {
        guard let snapshot, snapshot >= 0 else { return previous }
        let baseline = baseline ?? 0
        guard snapshot >= baseline else { return previous }
        let candidate = max(0, snapshot - baseline)
        return max(previous ?? 0, candidate)
    }

    private func mergedCost(snapshot: SessionUsage) -> Decimal? {
        guard let cost = snapshot.cost, cost >= 0 else { return values.cost }
        guard let currency = snapshot.currency else { return values.cost }
        if let persistedCurrency = values.currency, persistedCurrency != currency {
            DebugLog.agent("DaemonChatController rejected usage cost after currency changed from \(persistedCurrency) to \(currency).")
            return nil
        }
        if let baselineCurrency = baseline.currency, baselineCurrency != currency {
            DebugLog.agent("DaemonChatController rejected usage cost after baseline currency changed from \(baselineCurrency) to \(currency).")
            return nil
        }
        let delta = max(0, cost - (baseline.cost ?? 0))
        return Decimal(string: String(delta))
    }

    private func mergedCurrency(snapshot: SessionUsage) -> String? {
        guard let currency = snapshot.currency else { return values.currency }
        if let persistedCurrency = values.currency, persistedCurrency != currency { return nil }
        if let baselineCurrency = baseline.currency, baselineCurrency != currency { return nil }
        return currency
    }

    private func monotonicSessionSnapshot(previous: SessionUsage?, next: SessionUsage) -> SessionUsage {
        guard let previous else { return next }
        return SessionUsage(
            inputTokens: max(previous.inputTokens, next.inputTokens),
            outputTokens: max(previous.outputTokens, next.outputTokens),
            totalTokens: max(previous.totalTokens, next.totalTokens),
            cachedReadTokens: maximum(previous.cachedReadTokens, next.cachedReadTokens),
            cachedWriteTokens: maximum(previous.cachedWriteTokens, next.cachedWriteTokens),
            thoughtTokens: maximum(previous.thoughtTokens, next.thoughtTokens),
            cost: next.cost,
            currency: next.currency,
            contextUsed: next.contextUsed,
            contextSize: next.contextSize,
            providerLabel: next.providerLabel ?? previous.providerLabel,
            modelId: next.modelId ?? previous.modelId,
            modelName: next.modelName ?? previous.modelName,
            thinkingLevel: next.thinkingLevel ?? previous.thinkingLevel
        )
    }

    private func maximum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): max(lhs, rhs)
        case let (.some(value), .none), let (.none, .some(value)): value
        case (.none, .none): nil
        }
    }
}
#endif
