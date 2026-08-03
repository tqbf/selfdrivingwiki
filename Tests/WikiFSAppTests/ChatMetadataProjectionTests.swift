import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct ChatMetadataProjectionTests {
    @Test func chatProjectionLegacyRowOmitsUnavailableUsageRows() { #expect(usageFields(nil).isEmpty) }
    @Test func chatProjectionMissingStartOmitsDuration() { #expect(!usageFields(usage(start: nil, finish: .distantPast)).contains(.duration)) }
    @Test func chatProjectionMissingFinishOmitsDuration() { #expect(!usageFields(usage(start: .distantPast, finish: nil)).contains(.duration)) }
    @Test func chatProjectionCompleteTimesShowsDuration() { #expect(usageFields(usage(start: .distantPast, finish: Date(timeIntervalSince1970: 1))).contains(.duration)) }
    @Test func chatProjectionShowsInputTokensWhenPresent() { #expect(usageFields(usage(input: 1)).contains(.inputTokens)) }
    @Test func chatProjectionShowsOutputTokensWhenPresent() { #expect(usageFields(usage(output: 1)).contains(.outputTokens)) }
    @Test func chatProjectionShowsComputedTotalWhenInputAndOutputPresent() { #expect(usageFields(usage(input: 1, output: 2)).contains(.totalTokens)) }
    @Test func chatProjectionOmitsTotalWhenInputMissing() { #expect(!usageFields(usage(output: 2)).contains(.totalTokens)) }
    @Test func chatProjectionOmitsTotalWhenOutputMissing() { #expect(!usageFields(usage(input: 1)).contains(.totalTokens)) }
    @Test func chatProjectionShowsCacheReadWhenPresent() { #expect(usageFields(usage(cacheRead: 1)).contains(.cacheReadTokens)) }
    @Test func chatProjectionShowsCacheWriteWhenPresent() { #expect(usageFields(usage(cacheWrite: 1)).contains(.cacheWriteTokens)) }
    @Test func chatProjectionShowsCostForMatchingCurrency() { #expect(usageFields(usage(cost: 1, currency: "USD")).contains(.cost)) }
    @Test func chatProjectionOmitsCostForMixedCurrency() { #expect(!usageFields(usage(cost: 1, currency: nil)).contains(.cost)) }
    @Test func chatProjectionShowsStatusWhenPresent() { #expect(usageFields(usage()).contains(.status)) }
    @Test func chatProjectionOmitsStatusWhenUnavailable() { #expect(!usageFields(nil).contains(.status)) }
    @Test func metadataProjectionUsesStableEmptyStateWhenNoRows() {
        let model = MetadataPanelModel(subject: .chat(.init(rawValue: "chat")), sections: [], emptyState: .unavailable)
        #expect(model.emptyState == .unavailable)
    }
    @Test func technicalSectionContainsOnlyTechnicalFields() {
        let technical = model(nil).sections.first { $0.id == .technical }!.rows
        #expect(technical.map(\.id) == [.source])
    }

    @Test func chatProjectionShowsConversationAggregateValuesDistinctFromLatestTurn() {
        let latest = usage(input: 2, output: 3)
        let summary = ChatUsageSummary(
            latestTurn: latest,
            inputTokens: 20,
            outputTokens: 30,
            thoughtTokens: 4,
            cacheReadTokens: 5,
            cacheWriteTokens: 6,
            cost: Decimal(7),
            currency: "USD")
        let projection = model(latest, usageSummary: summary)

        let latestInput = projection.sections.first { $0.id == .usage }?.rows.first { $0.id == .inputTokens }
        let aggregateInput = projection.sections.first { $0.id == .conversationTotals }?.rows.first { $0.id == .conversationInputTokens }
        #expect(latestInput?.value == .tokenCount(2))
        #expect(aggregateInput?.value == .tokenCount(20))
        #expect(projection.sections.first { $0.id == .conversationTotals }?.title == "Persisted conversation totals")
        #expect(projection.sections.first { $0.id == .conversationTotals }?.rows.first { $0.id == .conversationCost }?.value == .text("USD 7"))
    }

    @Test func chatProjectionShowsUpdatedAndMessageCount() {
        let updatedAt = Date(timeIntervalSince1970: 42)
        let chat = ChatSummary(id: .init(rawValue: "chat"), kind: .edit, title: "Chat", createdAt: .distantPast, updatedAt: updatedAt, messageCount: 7)
        let projection = ChatMetadataProjection.make(input: .init(chat: chat, usageSummary: .empty))
        let summary = projection.sections.first { $0.id == .summary }!.rows
        #expect(summary.first { $0.id == .updated }?.value == .date(updatedAt))
        #expect(summary.first { $0.id == .messageCount }?.value == .integer(7))
    }

    private func model(_ usage: ChatTurnUsage?, usageSummary: ChatUsageSummary? = nil) -> MetadataPanelModel {
        ChatMetadataProjection.make(input: .init(
            chat: .init(id: .init(rawValue: "chat"), kind: .edit, title: "Chat", createdAt: .distantPast, updatedAt: .distantPast, messageCount: 0),
            usageSummary: usageSummary ?? .init(latestTurn: usage, inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: nil, currency: nil)))
    }
    private func usageFields(_ usage: ChatTurnUsage?) -> [MetadataFieldID] { model(usage).sections.first(where: { $0.id == .usage })?.rows.map(\.id) ?? [] }
    private func usage(start: Date? = nil, finish: Date? = nil, input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil, cost: Decimal? = nil, currency: String? = nil) -> ChatTurnUsage {
        .init(turnID: .init(rawValue: "turn"), providerID: nil, modelID: nil, startedAt: start, finishedAt: finish, state: .completed, inputTokens: input, outputTokens: output, thoughtTokens: nil, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, cost: cost, currency: currency)
    }
}
