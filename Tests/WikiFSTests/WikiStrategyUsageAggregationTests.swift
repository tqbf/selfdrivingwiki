import Testing
@testable import WikiStrategyEval

struct WikiStrategyUsageAggregationTests {
    @Test("completed runs are summed into one usage snapshot")
    func completedRunsAreSummed() async throws {
        let tracker = UsageBudgetTracker(budget: EvaluationBudget(
            maxDuration: .seconds(30), maxTotalTokens: 10_000, maxCost: 10))

        try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 120, cost: 0.40))
        try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 80, cost: 0.25))

        #expect(await tracker.current() == UsageSnapshot(totalTokens: 200, cost: 0.65))
    }

    @Test("an unknown completed-run cost keeps aggregate cost unknown")
    func unknownCostIsNotUnderCounted() async throws {
        let tracker = UsageBudgetTracker(budget: EvaluationBudget(
            maxDuration: .seconds(30), maxTotalTokens: 10_000, maxCost: 0.5))

        try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 120, cost: 0.40))
        try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 80))

        #expect(await tracker.current() == UsageSnapshot(totalTokens: 200, cost: nil))
    }

    @Test("aggregate budget failure retains the observed aggregate totals")
    func aggregateFailureStoresObservedTotals() async throws {
        let tracker = UsageBudgetTracker(budget: EvaluationBudget(
            maxDuration: .seconds(30), maxTotalTokens: 150, maxCost: nil))
        try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 100, cost: 1))

        do {
            try await tracker.recordCompletedRun(UsageSnapshot(totalTokens: 75, cost: 2))
            Issue.record("expected the aggregate token budget to be exceeded")
        } catch let limit as EvaluationRunLimit {
            #expect(limit == .tokenBudgetExceeded(limit: 150, observed: 175))
        }

        #expect(await tracker.current() == UsageSnapshot(totalTokens: 175, cost: 3))
    }
}
