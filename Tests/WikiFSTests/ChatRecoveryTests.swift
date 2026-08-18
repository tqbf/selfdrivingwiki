import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

struct ChatRecoveryTests {

    @Test func concatenatesFinalChunksAndIgnoresReasoning() throws {
        let data = Data([
            #"{"params":{"update":{"sessionUpdate":"tool_call","content":[{"type":"text","text":"array payload"}]}}}"#,
            #"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"do not use"}}}}"#,
            #"{"params":{"update":{"_meta":{"codex":{"phase":"final_answer"}},"sessionUpdate":"agent_message_chunk","messageId":"wire-1","content":{"text":"Hello "}}}}"#,
            #"{"method":"session/update"}"#,
            #"{"params":{"update":{"_meta":{"codex":{"phase":"final_answer"}},"sessionUpdate":"agent_message_chunk","messageId":"wire-1","content":{"text":"world"}}}}"#
        ].joined(separator: "\n").utf8)

        let recovered = try ChatRecovery.recover(from: data)
        #expect(recovered.text == "Hello world")
        #expect(recovered.wireMessageID == "wire-1")
    }

    @Test func refusesMultipleFinalWireMessageIDs() {
        let data = Data([
            #"{"params":{"update":{"sessionUpdate":"agent_message_chunk","messageId":"wire-1","content":{"text":"one"}}}}"#,
            #"{"params":{"update":{"sessionUpdate":"agent_message_chunk","messageId":"wire-2","content":{"text":"two"}}}}"#
        ].joined(separator: "\n").utf8)

        #expect(throws: ChatRecovery.Failure.ambiguousMessageIDs(["wire-1", "wire-2"])) {
            try ChatRecovery.recover(from: data)
        }
    }

    @Test func repairDryRunDoesNotWriteAndApplyPreservesIdentityAndUsesCAS() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Recovery")
        let original = ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "assistant-turn-1-block-0"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant,
            text: "corrupt",
            createdAt: Date(timeIntervalSince1970: 42))
        _ = try store.appendChatTranscriptItems(chatID: chat.id, items: [.message(original)])

        let updatesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-recovery-\(UUID().uuidString).jsonl")
        defer {
            do {
                try FileManager.default.removeItem(at: updatesURL)
            } catch {
                Issue.record("failed to remove recovery fixture: \(error)")
            }
        }
        let updates = Data(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk","messageId":"wire-1","content":{"text":"recovered"}}}}"#.utf8)
        try updates.write(to: updatesURL)

        let dryRun = try ChatCommand.run(.repair(
            chatID: chat.id,
            updatesFile: updatesURL.path,
            messageID: original.messageID,
            expectedSHA256: nil,
            apply: false), in: store)
        #expect(dryRun.didCommit == false)
        #expect(dryRun.output.contains("dry run; would repair"))
        #expect(try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10).items
            .compactMap { item -> String? in
                guard case .message(let message) = item.item else { return nil }
                return message.text
            } == ["corrupt"])

        let expected = RendererSHA256.digest(Data("corrupt".utf8)).hex
        #expect(throws: ChatCommand.Failure.self) {
            try ChatCommand.run(.repair(
                chatID: chat.id,
                updatesFile: updatesURL.path,
                messageID: original.messageID,
                expectedSHA256: String(repeating: "0", count: 64),
                apply: true), in: store)
        }
        #expect(try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10).items
            .compactMap { item -> String? in
                guard case .message(let message) = item.item else { return nil }
                return message.text
            } == ["corrupt"])

        let applied = try ChatCommand.run(.repair(
            chatID: chat.id,
            updatesFile: updatesURL.path,
            messageID: original.messageID,
            expectedSHA256: expected,
            apply: true), in: store)
        #expect(applied.didCommit)
        let result = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10).items
        guard case .message(let repaired) = result[0].item else {
            Issue.record("expected repaired message")
            return
        }
        #expect(repaired.text == "recovered")
        #expect(repaired.messageID == original.messageID)
        #expect(repaired.turnID == original.turnID)
        #expect(repaired.role == original.role)
        #expect(repaired.createdAt == original.createdAt)
        let compatibility = try store.chatMessages(chatID: chat.id)
        #expect(compatibility.count == 1)
        #expect(compatibility[0].event == .assistantText("recovered"))
    }
}
