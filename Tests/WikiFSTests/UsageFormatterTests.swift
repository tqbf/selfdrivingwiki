import Testing
import Foundation
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for `UsageFormatter` — the pure formatting helpers that turn
/// `SessionUsage` + `QueueItem` timestamps into the Activity window's
/// completion summary line. No UI, no state — just number → string, so the
/// logic is fully testable in isolation.
///
/// Covers: `tokenSummary`, `summary` (backward-compat), `fullSummary`,
/// `duration`, `startTime`, `cost`, `tokens`.
@Suite struct UsageFormatterTests {

    // MARK: - tokens(_:)

    @Test func tokensBelowThousandShowsRawInteger() {
        #expect(UsageFormatter.tokens(0) == "0")
        #expect(UsageFormatter.tokens(1) == "1")
        #expect(UsageFormatter.tokens(999) == "999")
    }

    @Test func tokensAtThousandShowsKSuffix() {
        #expect(UsageFormatter.tokens(1_000) == "1.0K")
        #expect(UsageFormatter.tokens(12_400) == "12.4K")
    }

    @Test func tokensAtMillionShowsMSuffix() {
        #expect(UsageFormatter.tokens(1_000_000) == "1.0M")
        #expect(UsageFormatter.tokens(1_200_000) == "1.2M")
    }

    // MARK: - cost(_:currency:)

    @Test func costNilAmountReturnsNil() {
        #expect(UsageFormatter.cost(nil, currency: nil) == nil)
    }

    @Test func costZeroAmountReturnsNil() {
        #expect(UsageFormatter.cost(0, currency: "USD") == nil)
    }

    @Test func costUSDShowsDollarSign() {
        #expect(UsageFormatter.cost(0.34, currency: "USD") == "$0.34")
        #expect(UsageFormatter.cost(1234.56, currency: "USD") == "$1234.56")
    }

    @Test func costNilCurrencyDefaultsToDollarSign() {
        #expect(UsageFormatter.cost(1.50, currency: nil) == "$1.50")
    }

    @Test func costNonUSDShowsSuffix() {
        #expect(UsageFormatter.cost(2.00, currency: "EUR") == "2.00 EUR")
    }

    // MARK: - duration(ms:)

    @Test func durationNilReturnsNil() {
        #expect(UsageFormatter.duration(ms: nil) == nil)
    }

    @Test func durationZeroReturnsNil() {
        #expect(UsageFormatter.duration(ms: 0) == nil)
    }

    @Test func durationSubSecondShowsLessThan1s() {
        #expect(UsageFormatter.duration(ms: 1) == "<1s")
        #expect(UsageFormatter.duration(ms: 999) == "<1s")
    }

    @Test func durationSeconds() {
        #expect(UsageFormatter.duration(ms: 1_000) == "1s")
        #expect(UsageFormatter.duration(ms: 42_000) == "42s")
    }

    @Test func durationMinutesAndSeconds() {
        #expect(UsageFormatter.duration(ms: 63_000) == "1m 3s")
        #expect(UsageFormatter.duration(ms: 180_000) == "3m 0s")
    }

    @Test func durationHoursAndMinutes() {
        #expect(UsageFormatter.duration(ms: 3_660_000) == "1h 1m")
        #expect(UsageFormatter.duration(ms: 7_200_000) == "2h 0m")
    }

    // MARK: - startTime(ms:)

    @Test func startTimeNilReturnsNil() {
        #expect(UsageFormatter.startTime(ms: nil) == nil)
    }

    @Test func startTimeZeroReturnsNil() {
        #expect(UsageFormatter.startTime(ms: 0) == nil)
    }

    @Test func startTimeProducesNonEmptyString() {
        // Use a fixed epoch (2025-01-01 00:00:00 UTC = 1735689600000 ms).
        // We don't assert the exact string because it's locale-dependent,
        // but it must be non-empty and not nil.
        let result = UsageFormatter.startTime(ms: 1_735_689_600_000)
        #expect(result != nil)
        #expect(result?.isEmpty == false)
    }

    // MARK: - tokenSummary(usage:)

    @Test func tokenSummaryWithInputAndOutput() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.tokenSummary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out")
    }

    @Test func tokenSummaryIncludesThoughtTokensWhenPresent() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: 412,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.tokenSummary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out · 412 thought")
    }

    @Test func tokenSummaryOmitsThoughtTokensWhenZero() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: 0,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.tokenSummary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out")
    }

    @Test func tokenSummaryOmitsThoughtTokensWhenNil() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.tokenSummary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out")
    }

    // MARK: - summary(usage:) — backward-compat

    @Test func summaryWithoutCost() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.summary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out")
    }

    @Test func summaryWithCost() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.34, currency: "USD", contextUsed: 0, contextSize: 0)
        let result = UsageFormatter.summary(usage: usage)
        #expect(result == "797 tokens in · 203 tokens out · $0.34")
    }

    // MARK: - fullSummary(usage:startedAt:finishedAt:)

    @Test func fullSummaryWithAllFields() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: 412,
            cost: 0.34, currency: "USD", contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "sonnet-4")
        // startedAt not nil → start time + duration appear
        let startedAt: Int64 = 1_735_689_600_000  // 2025-01-01 00:00:00 UTC
        let finishedAt: Int64 = startedAt + 63_000 // +63s
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: startedAt, finishedAt: finishedAt)
        // We can't assert the exact start time string (locale-dependent), but
        // we can assert the structural segments.
        #expect(result.contains("1m 3s"))
        #expect(result.contains("Claude"))
        #expect(result.contains("sonnet-4"))
        #expect(result.contains("797 tokens in"))
        #expect(result.contains("203 tokens out"))
        #expect(result.contains("412 thought"))
        #expect(result.contains("$0.34"))
    }

    @Test func fullSummaryWithoutProviderOrModelOmitsThem() {
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: nil, modelId: nil)
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "100 tokens in · 50 tokens out")
    }

    @Test func fullSummaryWithoutTimestampsOmitsTimeAndDuration() {
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.01, currency: "USD", contextUsed: 0, contextSize: 0,
            providerLabel: "Hermes", modelId: nil)
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "Hermes · 100 tokens in · 50 tokens out · $0.01")
    }

    @Test func fullSummaryWithZeroStartedAtOmitsTimeAndDuration() {
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "sonnet-4")
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: 0, finishedAt: 0)
        #expect(result == "Claude · sonnet-4 · 100 tokens in · 50 tokens out")
    }

    @Test func fullSummaryIncludesThinkingLevelBetweenModelAndTokens() {
        // #566: the thinking-effort level surfaces between the model id and the
        // token counts. Regression test for the capturePhaseUsage enrichment
        // path that once dropped `thinkingLevel` when attaching `providerLabel`.
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: 412,
            cost: 0.34, currency: "USD", contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: "high")
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "Claude · sonnet-4 · high · 797 tokens in · 203 tokens out · 412 thought · $0.34")
    }

    @Test func fullSummaryOmitsThinkingLevelWhenNil() {
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "sonnet-4",
            thinkingLevel: nil)
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "Claude · sonnet-4 · 797 tokens in · 203 tokens out")
    }

    // MARK: - modelName preference (#583)

    @Test func fullSummaryPrefersModelNameOverId() {
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "claude-sonnet-4-5-20250929",
            modelName: "Claude Sonnet 4.5",
            thinkingLevel: nil)
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "Claude · Claude Sonnet 4.5 · 100 tokens in · 50 tokens out")
    }

    @Test func fullSummaryFallsBackToModelIdWhenNameIsNil() {
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: nil, modelId: "glm-4-7",
            modelName: nil,
            thinkingLevel: nil)
        let result = UsageFormatter.fullSummary(usage: usage, startedAt: nil, finishedAt: nil)
        #expect(result == "glm-4-7 · 100 tokens in · 50 tokens out")
    }

    // MARK: - Per-model breakdown line (#583)

    @Test func modelBreakdownLineRendersAllSegments() {
        let b = ModelUsageBreakdown(
            inputTokens: 52_000, outputTokens: 8_000, thoughtTokens: 1_200,
            totalTokens: 61_200, cost: 0.89, currency: "USD", runCount: 1)
        let line = UsageFormatter.modelBreakdownLine(
            modelId: "sonnet-4", breakdown: b, displayNameProvider: { _ in "Sonnet 4" })
        #expect(line == "Sonnet 4 · 52.0K in · 8.0K out · 1.2K thought · $0.89")
    }

    @Test func modelBreakdownLineOmitsThoughtWhenZero() {
        let b = ModelUsageBreakdown(
            inputTokens: 12_000, outputTokens: 3_000, thoughtTokens: 0,
            totalTokens: 15_000, cost: 0.34, currency: "USD", runCount: 1)
        let line = UsageFormatter.modelBreakdownLine(
            modelId: "opus-4", breakdown: b, displayNameProvider: nil)
        #expect(line == "opus-4 · 12.0K in · 3.0K out · $0.34")
    }

    @Test func modelBreakdownLineAppendsRunCountWhenGreaterThanOne() {
        let b = ModelUsageBreakdown(
            inputTokens: 100_000, outputTokens: 20_000, thoughtTokens: 0,
            totalTokens: 120_000, cost: 2.50, currency: "USD", runCount: 4)
        let line = UsageFormatter.modelBreakdownLine(
            modelId: "sonnet-4", breakdown: b, displayNameProvider: nil)
        #expect(line == "sonnet-4 · 100.0K in · 20.0K out · $2.50 · 4 runs")
    }

    @Test func modelBreakdownLineRendersUnknownBucket() {
        let b = ModelUsageBreakdown(
            inputTokens: 500, outputTokens: 100, thoughtTokens: 0,
            totalTokens: 600, cost: 0, currency: "USD", runCount: 1)
        let line = UsageFormatter.modelBreakdownLine(
            modelId: ModelUsageBreakdown.unknownModelKey, breakdown: b,
            displayNameProvider: nil)
        #expect(line == "Unknown model · 500 in · 100 out")
    }

    // MARK: - ModelUsageBreakdown accumulation (#583)

    @Test func breakdownSumsTokensAndRunCountAcrossAdds() {
        var b = ModelUsageBreakdown()
        b.add(SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: 10,
            cost: 0.20, currency: "USD", contextUsed: 0, contextSize: 0))
        b.add(SessionUsage(
            inputTokens: 200, outputTokens: 30, totalTokens: 230,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.10, currency: "USD", contextUsed: 0, contextSize: 0))
        #expect(b.inputTokens == 300)
        #expect(b.outputTokens == 80)
        #expect(b.thoughtTokens == 10)
        #expect(b.totalTokens == 380)
        // Floating-point sums of cost values can drift; the break may be
        // 0.30000000000000004 instead of exactly 0.3.
        #expect(abs(b.cost - 0.30) < 0.0001)
        #expect(b.runCount == 2)
        #expect(b.hasData)
    }

    @Test func breakdownHasDataIsFalseWhenAllZero() {
        let b = ModelUsageBreakdown()
        #expect(!b.hasData)
    }

    // MARK: - DailyUsageByModel (#583)

    @Test func dailyByModelAccumulatesPerModelKey() {
        var d = DailyUsageByModel(date: "2026-07-18")
        d.add(SessionUsage(
            inputTokens: 1000, outputTokens: 200, totalTokens: 1200,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.10, currency: "USD", contextUsed: 0, contextSize: 0,
            modelId: "sonnet-4", modelName: "Sonnet 4"))
        d.add(SessionUsage(
            inputTokens: 500, outputTokens: 100, totalTokens: 600,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.05, currency: "USD", contextUsed: 0, contextSize: 0,
            modelId: "opus-4", modelName: "Opus 4"))
        d.add(SessionUsage(
            inputTokens: 50, outputTokens: 10, totalTokens: 60,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            modelId: nil, modelName: nil))
        #expect(d.byModel.count == 3)
        #expect(d.byModel["sonnet-4"]?.inputTokens == 1000)
        #expect(d.byModel["opus-4"]?.inputTokens == 500)
        #expect(d.byModel[ModelUsageBreakdown.unknownModelKey]?.inputTokens == 50)
        #expect(d.hasData)
    }

    @Test func dailyByModelSortedForDisplayPutsHeaviestFirstAndUnknownLast() {
        var d = DailyUsageByModel(date: "2026-07-18")
        d.add(SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            modelId: "light-model", modelName: nil))
        d.add(SessionUsage(
            inputTokens: 5_000, outputTokens: 1_000, totalTokens: 6_000,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            modelId: "heavy-model", modelName: nil))
        d.add(SessionUsage(
            inputTokens: 50, outputTokens: 10, totalTokens: 60,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            modelId: nil, modelName: nil))
        let sorted = d.sortedForDisplay
        #expect(sorted.map(\.modelId) == ["heavy-model", "light-model", ModelUsageBreakdown.unknownModelKey])
    }

    // MARK: - itemModelBreakdownLine (#583)

    @Test func itemModelLinePrefersModelNameFromUsage() {
        let b = ModelUsageBreakdown(
            inputTokens: 100, outputTokens: 50, thoughtTokens: 20,
            totalTokens: 170, cost: 0.10, currency: "USD", runCount: 1)
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 170,
            cachedReadTokens: nil, thoughtTokens: 20,
            cost: 0.10, currency: "USD", contextUsed: 0, contextSize: 0,
            modelId: "claude-sonnet-4", modelName: "Claude Sonnet 4")
        let line = UsageFormatter.itemModelBreakdownLine(
            modelId: "claude-sonnet-4", breakdown: b, usage: usage)
        #expect(line == "Claude Sonnet 4 · 100 in · 50 out · 20 thought · $0.10")
    }
}
