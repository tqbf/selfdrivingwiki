#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import wikid

@MainActor
struct DaemonChatUsageTests {
    @Test func streamedCumulativeUsageProducesTurnDelta() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 10, output: 2))

        let persisted = accumulator.record(usage(input: 17, output: 5))

        #expect(persisted.inputTokens == 7)
        #expect(persisted.outputTokens == 3)
    }

    @Test func finalOnlyUsagePersists() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))

        let persisted = accumulator.record(usage(input: 7, output: 3, thought: 2))

        #expect(persisted.inputTokens == 7)
        #expect(persisted.outputTokens == 3)
        #expect(persisted.thoughtTokens == 2)
    }

    @Test func mixedStreamAndFinalUsesGreatestCounters() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))
        _ = accumulator.record(usage(input: 5, output: 2, thought: 1))

        let persisted = accumulator.record(usage(input: 4, output: 4, thought: 1))

        #expect(persisted.inputTokens == 5)
        #expect(persisted.outputTokens == 4)
        #expect(persisted.thoughtTokens == 1)
    }

    @Test func missingUsageLeavesColumnsNil() {
        let accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))

        let persisted = accumulator.values

        #expect(persisted.inputTokens == nil)
        #expect(persisted.outputTokens == nil)
        #expect(persisted.cost == nil)
    }

    @Test func counterResetRetainsPriorValue() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))
        _ = accumulator.record(usage(input: 8, output: 3))

        let persisted = accumulator.record(usage(input: 2, output: 4))

        #expect(persisted.inputTokens == 8)
        #expect(persisted.outputTokens == 4)
    }

    @Test func decreasingCounterIsRejected() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 10, output: 4))
        _ = accumulator.record(usage(input: 17, output: 7))

        let persisted = accumulator.record(usage(input: 16, output: 6))

        #expect(persisted.inputTokens == 7)
        #expect(persisted.outputTokens == 3)
    }

    @Test func currencyChangeClearsCostOnly() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))
        _ = accumulator.record(usage(input: 3, output: 2, cost: 1.5, currency: "USD"))

        let persisted = accumulator.record(usage(input: 4, output: 3, cost: 2.0, currency: "EUR"))

        #expect(persisted.inputTokens == 4)
        #expect(persisted.outputTokens == 3)
        #expect(persisted.cost == nil)
        #expect(persisted.currency == nil)
    }

    @Test func currencyConflictStaysUnavailableAfterLaterMatchingCurrency() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))
        _ = accumulator.record(usage(input: 3, output: 2, cost: 1.5, currency: "USD"))
        _ = accumulator.record(usage(input: 4, output: 3, cost: 2.0, currency: "EUR"))

        let persisted = accumulator.record(usage(input: 5, output: 4, cost: 2.5, currency: "USD"))

        #expect(persisted.inputTokens == 5)
        #expect(persisted.outputTokens == 4)
        #expect(persisted.cost == nil)
        #expect(persisted.currency == nil)
    }

    @Test func cacheReadAndWritePersist() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))

        let persisted = accumulator.record(usage(input: 1, output: 2, cacheRead: 5, cacheWrite: 3))

        #expect(persisted.cacheReadTokens == 5)
        #expect(persisted.cacheWriteTokens == 3)
    }

    @Test func thoughtTokensPersist() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 0, output: 0))

        let persisted = accumulator.record(usage(input: 1, output: 2, thought: 3))

        #expect(persisted.thoughtTokens == 3)
    }

    @Test func warmSessionSubtractsBaseline() {
        var accumulator = ChatTurnUsageAccumulator(baseline: usage(input: 100, output: 50, cacheRead: 20, thought: 10, cost: 4, currency: "USD"))

        let persisted = accumulator.record(usage(input: 108, output: 55, cacheRead: 23, thought: 12, cost: 4.75, currency: "USD"))

        #expect(persisted.inputTokens == 8)
        #expect(persisted.outputTokens == 5)
        #expect(persisted.cacheReadTokens == 3)
        #expect(persisted.thoughtTokens == 2)
        #expect(persisted.cost == Decimal(string: "0.75"))
        #expect(persisted.currency == "USD")
    }

    private func usage(
        input: Int,
        output: Int,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil,
        thought: Int? = nil,
        cost: Double? = nil,
        currency: String? = nil
    ) -> SessionUsage {
        SessionUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: input + output,
            cachedReadTokens: cacheRead,
            cachedWriteTokens: cacheWrite,
            thoughtTokens: thought,
            cost: cost,
            currency: currency,
            contextUsed: 0,
            contextSize: 0
        )
    }
}
#endif
