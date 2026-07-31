import Foundation
import Testing
@testable import WikiFSCore

struct ChatTurnMetadataStoreTransitionTests {
    private func claimedStore(submitted: Bool = false) throws -> (GRDBWikiStore, ChatID, PersistedChatTurn) {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Transition")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: .init(commandID: ChatCommandID(rawValue: "command"), turnID: ChatTurnID(rawValue: "turn"),
                              userText: "text", contextReferences: [], submittedAt: .now)
        )
        let claimed = try #require(try store.claimNextPersistedChatTurn(
            chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim"), claimedAt: Date(timeIntervalSince1970: 10),
            providerID: ProviderID(rawValue: "provider"), modelID: ModelID(rawValue: "model")
        ))
        if submitted {
            return (store, chat.id, try store.markPersistedChatTurnProviderSubmitted(
                chatID: chat.id, turnID: claimed.submission.turnID, claimID: ChatTurnClaimID(rawValue: "claim"),
                providerSessionID: nil, submittedAt: Date(timeIntervalSince1970: 11)
            ))
        }
        return (store, chat.id, claimed)
    }

    @Test func usageUpdateAcceptsClaimedTurnWithMatchingClaim() throws {
        let (store, chatID, turn) = try claimedStore()
        let updated = try store.updatePersistedChatTurnUsage(
            chatID: chatID, turnID: turn.submission.turnID, claimID: ChatTurnClaimID(rawValue: "claim"),
            usage: .init(inputTokens: 1)
        )
        #expect(updated.usage.inputTokens == 1)
    }

    @Test func usageUpdateAcceptsProviderSubmittedTurnWithMatchingClaim() throws {
        let (store, chatID, turn) = try claimedStore(submitted: true)
        #expect(try store.updatePersistedChatTurnUsage(
            chatID: chatID, turnID: turn.submission.turnID, claimID: ChatTurnClaimID(rawValue: "claim"),
            usage: .init(outputTokens: 2)
        ).usage.outputTokens == 2)
    }

    @Test func usageUpdateRejectsCompletedTurn() throws { try assertTerminalUsageRejected(.completed) }
    @Test func usageUpdateRejectsFailedTurn() throws { try assertTerminalUsageRejected(.failed) }
    @Test func usageUpdateRejectsCancelledTurn() throws { try assertTerminalUsageRejected(.cancelled) }

    @Test func usageUpdateRejectsStaleClaim() throws {
        let (store, chatID, turn) = try claimedStore()
        do {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chatID, turnID: turn.submission.turnID, claimID: ChatTurnClaimID(rawValue: "stale"),
                usage: .init(inputTokens: 1)
            )
            Issue.record("stale claim must not update usage")
        } catch let error as MetadataStoreError {
            #expect(error == .staleChatTurnClaim)
        }
    }

    @Test func finishClaimedTurnPersistsTerminalOutcomeAndFinalUsageAtomically() throws { try assertFinish(submitted: false) }
    @Test func finishProviderSubmittedTurnPersistsTerminalOutcomeAndFinalUsageAtomically() throws { try assertFinish(submitted: true) }

    @Test func laterDifferentTerminalOutcomePreservesWinnerState() throws {
        let (store, chatID, turn) = try claimedStore()
        let winner = try finish(store, chatID: chatID, turn: turn, state: .completed, finishedAt: 12)
        let later = try finish(store, chatID: chatID, turn: turn, state: .failed, finishedAt: 13)
        #expect(later.state == winner.state)
        #expect(later.finishedAt == winner.finishedAt)
        #expect(later.terminalMessage == winner.terminalMessage)
        #expect(later.providerID == winner.providerID)
        #expect(later.usage == winner.usage)
    }

    private func assertTerminalUsageRejected(_ state: ChatTurnPersistenceState) throws {
        let (store, chatID, turn) = try claimedStore()
        _ = try finish(store, chatID: chatID, turn: turn, state: state, finishedAt: 12)
        do {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chatID, turnID: turn.submission.turnID, claimID: ChatTurnClaimID(rawValue: "claim"),
                usage: .init(inputTokens: 4)
            )
            Issue.record("terminal usage update must be rejected")
        } catch let error as MetadataStoreError {
            #expect(error == .nonActiveChatTurnState(state))
        }
    }

    private func assertFinish(submitted: Bool) throws {
        let (store, chatID, turn) = try claimedStore(submitted: submitted)
        let finished = try finish(store, chatID: chatID, turn: turn, state: .completed, finishedAt: 12)
        #expect(finished.state == .completed)
        #expect(finished.finishedAt == Date(timeIntervalSince1970: 12))
        #expect(finished.usage.inputTokens == 4)
    }

    private func finish(
        _ store: GRDBWikiStore, chatID: ChatID, turn: PersistedChatTurn,
        state: ChatTurnPersistenceState, finishedAt: TimeInterval
    ) throws -> PersistedChatTurn {
        try store.finishPersistedChatTurn(
            chatID: chatID, turnID: turn.submission.turnID, claimID: ChatTurnClaimID(rawValue: "claim"),
            state: state, terminalMessage: "winner", finishedAt: Date(timeIntervalSince1970: finishedAt),
            usage: .init(inputTokens: 4, outputTokens: 5, thoughtTokens: 6, cacheReadTokens: 7,
                         cacheWriteTokens: 8, cost: Decimal(string: "1.50"), currency: "USD")
        )
    }
}
