import Foundation
import Testing
@testable import WikiFSCore

struct ChatTurnMetadataStoreTests {
    @Test func schemaVersionIs48() {
        #expect(GRDBWikiStore.schemaVersion == 48)
    }

    @Test func usageIsKeyedByChatAndTurn() throws {
        let store = try TestStoreFactory.inMemory()
        let first = try store.createChat(kind: .edit, title: "One")
        let second = try store.createChat(kind: .edit, title: "Two")
        let turnID = ChatTurnID(rawValue: "same-turn")
        for chat in [first, second] {
            _ = try store.enqueuePersistedChatTurn(
                chatID: chat.id,
                submission: .init(
                    commandID: ChatCommandID(rawValue: "command-\(chat.id.rawValue)"),
                    turnID: turnID,
                    userText: "question", contextReferences: [], submittedAt: .now
                )
            )
            let claimed = try #require(try store.claimNextPersistedChatTurn(
                chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim-\(chat.id.rawValue)"),
                claimedAt: .now
            ))
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: claimed.submission.turnID,
                claimID: try #require(claimed.claimID),
                usage: .init(inputTokens: chat.id == first.id ? 3 : 7)
            )
        }
        #expect(try store.chatTurnUsage(chatID: first.id, turnID: turnID)?.inputTokens == 3)
        #expect(try store.chatTurnUsage(chatID: second.id, turnID: turnID)?.inputTokens == 7)
    }

    @Test func claimWritesStartedAtProviderAndModelAtomically() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Claim")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: .init(
                commandID: ChatCommandID(rawValue: "command"), turnID: ChatTurnID(rawValue: "turn"),
                userText: "question", contextReferences: [], submittedAt: .now
            )
        )
        let start = Date(timeIntervalSince1970: 123)
        let claimed = try #require(try store.claimNextPersistedChatTurn(
            chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim"), claimedAt: start,
            providerID: ProviderID(rawValue: "anthropic"), modelID: ModelID(rawValue: "claude")
        ))
        #expect(claimed.claimedAt == start)
        #expect(claimed.providerID == ProviderID(rawValue: "anthropic"))
        #expect(claimed.modelID == ModelID(rawValue: "claude"))
        #expect(try store.chatTurnUsage(chatID: chat.id, turnID: claimed.submission.turnID)?.startedAt == start)
    }

    @Test func noChatRunIdentifierExists() throws {
        let store = try TestStoreFactory.inMemory()
        let columns = store.scalarText("SELECT group_concat(name, ',') FROM pragma_table_info('chat_turns')")
        #expect(!columns.contains("run_id"))
        #expect(store.scalarText("SELECT COUNT(*) FROM sqlite_master WHERE name = 'chat_runs'") == "0")
    }
}
