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
    /// Once provider snapshots disagree about currency, a single turn has no
    /// meaningful cost unit. Keep that fact latched so a later snapshot cannot
    /// make an ambiguous cost appear valid again.
    private var isCostUnavailableAfterCurrencyConflict = false
    private(set) var values = ChatTurnUsageValues()

    init(baseline: SessionUsage) {
        self.baseline = baseline
    }

    /// Accepts a provider's cumulative session snapshot and retains only
    /// monotonic, nonnegative per-turn evidence. Missing values never erase a
    /// prior value; a changed currency makes the cost unavailable.
    @discardableResult
    mutating func record(_ snapshot: SessionUsage) -> ChatTurnUsageValues {
        let cost = mergedCost(snapshot: snapshot)

        values = ChatTurnUsageValues(
            inputTokens: greatestValid(previous: values.inputTokens, baseline: baseline.inputTokens, snapshot: snapshot.inputTokens),
            outputTokens: greatestValid(previous: values.outputTokens, baseline: baseline.outputTokens, snapshot: snapshot.outputTokens),
            thoughtTokens: greatestValid(previous: values.thoughtTokens, baseline: baseline.thoughtTokens, snapshot: snapshot.thoughtTokens),
            cacheReadTokens: greatestValid(previous: values.cacheReadTokens, baseline: baseline.cachedReadTokens, snapshot: snapshot.cachedReadTokens),
            cacheWriteTokens: greatestValid(previous: values.cacheWriteTokens, baseline: baseline.cachedWriteTokens, snapshot: snapshot.cachedWriteTokens),
            cost: cost.cost,
            currency: cost.currency
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

    private mutating func mergedCost(snapshot: SessionUsage) -> (cost: Decimal?, currency: String?) {
        guard isCostUnavailableAfterCurrencyConflict == false else { return (nil, nil) }
        guard let currency = snapshot.currency else { return (values.cost, values.currency) }

        let expectedCurrency = values.currency ?? baseline.currency
        if let expectedCurrency, expectedCurrency != currency {
            isCostUnavailableAfterCurrencyConflict = true
            DebugLog.agent("DaemonChatController rejected usage cost after currency changed from \(expectedCurrency) to \(currency).")
            return (nil, nil)
        }

        guard let cost = snapshot.cost, cost >= 0 else {
            return (values.cost, values.cost == nil ? nil : expectedCurrency ?? currency)
        }
        let delta = max(0, cost - (baseline.cost ?? 0))
        return (Decimal(string: String(delta)), currency)
    }
}
#endif
