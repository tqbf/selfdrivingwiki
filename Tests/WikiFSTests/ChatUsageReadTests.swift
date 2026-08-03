import Foundation
import Testing
@testable import WikiFSCore

struct ChatUsageReadTests {
    private func submit(_ store: GRDBWikiStore, chatID: ChatID, ordinal: Int) throws -> PersistedChatTurn {
        try store.enqueuePersistedChatTurn(
            chatID: chatID,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "command-\(ordinal)"),
                turnID: ChatTurnID(rawValue: "turn-\(ordinal)"),
                userText: "turn \(ordinal)",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: TimeInterval(ordinal))
            )
        )
    }

    private func claim(
        _ store: GRDBWikiStore, chatID: ChatID, ordinal: Int
    ) throws -> PersistedChatTurn {
        _ = try submit(store, chatID: chatID, ordinal: ordinal)
        return try #require(try store.claimNextPersistedChatTurn(
            chatID: chatID,
            claimID: ChatTurnClaimID(rawValue: "claim-\(ordinal)"),
            claimedAt: Date(timeIntervalSince1970: TimeInterval(ordinal + 10)),
            providerID: ProviderID(rawValue: "provider-\(ordinal)"),
            modelID: ModelID(rawValue: "model-\(ordinal)")
        ))
    }

    @Test func chatTurnUsageReturnsNilForMissingTurn() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        #expect(try store.chatTurnUsage(chatID: chat.id, turnID: ChatTurnID(rawValue: "missing")) == nil)
    }

    @Test func chatTurnUsageDecodesEveryField() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let claimed = try claim(store, chatID: chat.id, ordinal: 1)
        _ = try store.updatePersistedChatTurnUsage(
            chatID: chat.id,
            turnID: claimed.submission.turnID,
            claimID: try #require(claimed.claimID),
            usage: .init(
                inputTokens: 10, outputTokens: 20, thoughtTokens: 3,
                cacheReadTokens: 4, cacheWriteTokens: 5,
                cost: Decimal(string: "1.25"), currency: "USD"
            )
        )
        _ = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: claimed.submission.turnID,
            claimID: try #require(claimed.claimID),
            state: .completed,
            terminalMessage: "complete",
            finishedAt: Date(timeIntervalSince1970: 12),
            usage: .init(
                inputTokens: 10, outputTokens: 20, thoughtTokens: 3,
                cacheReadTokens: 4, cacheWriteTokens: 5,
                cost: Decimal(string: "1.25"), currency: "USD"
            )
        )
        let usage = try #require(try store.chatTurnUsage(chatID: chat.id, turnID: claimed.submission.turnID))
        #expect(usage.providerID == ProviderID(rawValue: "provider-1"))
        #expect(usage.modelID == ModelID(rawValue: "model-1"))
        #expect(usage.startedAt == Date(timeIntervalSince1970: 11))
        #expect(usage.finishedAt == Date(timeIntervalSince1970: 12))
        #expect(usage.state == .completed)
        #expect(usage.inputTokens == 10)
        #expect(usage.outputTokens == 20)
        #expect(usage.thoughtTokens == 3)
        #expect(usage.cacheReadTokens == 4)
        #expect(usage.cacheWriteTokens == 5)
        #expect(usage.cost == Decimal(string: "1.25"))
        #expect(usage.currency == "USD")
    }

    @Test func latestChatTurnUsageUsesHighestDurableOrdinal() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        _ = try claim(store, chatID: chat.id, ordinal: 2)
        let latest = try claim(store, chatID: chat.id, ordinal: 3)
        #expect(try store.latestChatTurnUsage(chatID: chat.id)?.turnID == latest.submission.turnID)
    }

    @Test func chatTurnUsageDecodesLegacyAllNilRow() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let claimed = try claim(store, chatID: chat.id, ordinal: 1)
        let usage = try #require(try store.chatTurnUsage(chatID: chat.id, turnID: claimed.submission.turnID))
        #expect(usage.inputTokens == nil)
        #expect(usage.cost == nil)
        #expect(usage.currency == nil)
    }

    @Test func latestChatTurnUsageReturnsNilForEmptyChat() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        #expect(try store.latestChatTurnUsage(chatID: chat.id) == nil)
    }

    @Test func latestChatTurnUsageReturnsLatestLegacyAllNilRow() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let turn = try claim(store, chatID: chat.id, ordinal: 8)
        let latest = try #require(try store.latestChatTurnUsage(chatID: chat.id))
        #expect(latest.turnID == turn.submission.turnID)
        #expect(latest.inputTokens == nil)
    }

    @Test func chatUsageSummaryReturnsEmptySummaryForEmptyChat() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        #expect(try store.chatUsageSummary(chatID: chat.id) == .empty)
    }

    @Test func chatUsageSummaryAggregatesInputTokens() throws { try assertOneCounter(\.inputTokens, input: 8) }
    @Test func chatUsageSummaryAggregatesOutputTokens() throws { try assertOneCounter(\.outputTokens, output: 8) }
    @Test func chatUsageSummaryAggregatesThoughtTokens() throws { try assertOneCounter(\.thoughtTokens, thought: 8) }
    @Test func chatUsageSummaryAggregatesCacheReadTokens() throws { try assertOneCounter(\.cacheReadTokens, cacheRead: 8) }
    @Test func chatUsageSummaryAggregatesCacheWriteTokens() throws { try assertOneCounter(\.cacheWriteTokens, cacheWrite: 8) }

    @Test func chatUsageSummaryIgnoresLegacyAllNilRows() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        _ = try claim(store, chatID: chat.id, ordinal: 1)
        let current = try claim(store, chatID: chat.id, ordinal: 2)
        _ = try store.updatePersistedChatTurnUsage(
            chatID: chat.id, turnID: current.submission.turnID, claimID: try #require(current.claimID),
            usage: .init(outputTokens: 12)
        )
        let summary = try store.chatUsageSummary(chatID: chat.id)
        #expect(summary.outputTokens == 12)
        #expect(summary.inputTokens == 0)
    }

    @Test func chatUsageSummaryAggregatesMatchingCurrencyCost() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let first = try claim(store, chatID: chat.id, ordinal: 4)
        let second = try claim(store, chatID: chat.id, ordinal: 5)
        for (turn, tokens, cost) in [(first, 7, "1.10"), (second, 9, "2.20")] {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id,
                turnID: turn.submission.turnID,
                claimID: try #require(turn.claimID),
                usage: .init(inputTokens: tokens, cost: Decimal(string: cost), currency: "USD")
            )
        }
        let summary = try store.chatUsageSummary(chatID: chat.id)
        #expect(summary.inputTokens == 16)
        #expect(summary.cost == Decimal(string: "3.3"))
        #expect(summary.currency == "USD")
        #expect(summary.latestTurn?.turnID == second.submission.turnID)
    }

    @Test func chatUsageSummaryOmitsMixedCurrencyCost() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let first = try claim(store, chatID: chat.id, ordinal: 1)
        let second = try claim(store, chatID: chat.id, ordinal: 2)
        for (turn, currency) in [(first, "USD"), (second, "EUR")] {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: turn.submission.turnID, claimID: try #require(turn.claimID),
                usage: .init(cost: Decimal(string: "1"), currency: currency)
            )
        }
        let summary = try store.chatUsageSummary(chatID: chat.id)
        #expect(summary.cost == nil)
        #expect(summary.currency == nil)
    }

    @Test func chatUsageSummaryOmitsCostWithoutCurrency() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let turn = try claim(store, chatID: chat.id, ordinal: 1)
        do {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: turn.submission.turnID, claimID: try #require(turn.claimID),
                usage: .init(cost: Decimal(string: "1"))
            )
            Issue.record("cost without currency must be rejected")
        } catch let error as MetadataStoreError {
            #expect(error == .invalidUsageValue(field: "cost_decimal"))
        }
    }

    @Test func chatUsageSummaryRejectsCounterOverflow() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "chat-usage-overflow")
        let writable = try GRDBWikiStore(databaseURL: url)
        let chat = try writable.createChat(kind: .edit, title: "Overflow")
        writable.close()
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO chat_turns
          (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at, input_tokens)
        VALUES ('\(chat.id.rawValue)', 'one', 'command-one', 0, 'claimed', 'one', '[]', 1, 9223372036854775807),
               ('\(chat.id.rawValue)', 'two', 'command-two', 1, 'claimed', 'two', '[]', 2, 1);
        """, at: url)
        do {
            _ = try GRDBWikiStore(databaseURL: url).chatUsageSummary(chatID: chat.id)
            Issue.record("expected checked chat usage counter overflow")
        } catch let error as MetadataStoreError {
            #expect(error == .counterOverflow)
        }
    }

    @Test func chatUsageSummaryRejectsMalformedDecimal() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "chat-usage-decimal")
        let writable = try GRDBWikiStore(databaseURL: url)
        let chat = try writable.createChat(kind: .edit, title: "Decimal")
        writable.close()
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO chat_turns
          (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at, cost_decimal, currency)
        VALUES ('\(chat.id.rawValue)', 'turn', 'command', 0, 'claimed', 'text', '[]', 1, 'not-a-decimal', 'USD');
        """, at: url)
        do {
            _ = try GRDBWikiStore(databaseURL: url).chatUsageSummary(chatID: chat.id)
            Issue.record("expected malformed metadata decimal")
        } catch let error as MetadataStoreError {
            #expect(error == .malformedDecimal("not-a-decimal"))
        }
    }

    private func assertOneCounter(
        _ keyPath: KeyPath<ChatUsageSummary, Int>, input: Int? = nil, output: Int? = nil,
        thought: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil
    ) throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Usage")
        let first = try claim(store, chatID: chat.id, ordinal: 1)
        let second = try claim(store, chatID: chat.id, ordinal: 2)
        for turn in [first, second] {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: turn.submission.turnID, claimID: try #require(turn.claimID),
                usage: .init(inputTokens: input, outputTokens: output, thoughtTokens: thought,
                             cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite)
            )
        }
        #expect(try store.chatUsageSummary(chatID: chat.id)[keyPath: keyPath] == 16)
    }
}
