import Foundation
import Testing
@testable import WikiFSTypes

struct ChatIdentifierCodableCompatibilityTests {
    @Test(arguments: [
        ("ChatTurnID", try! JSONEncoder().encode(ChatTurnID(rawValue: "turn-1"))),
        ("ChatMessageID", try! JSONEncoder().encode(ChatMessageID(rawValue: "message-1"))),
        ("ChatCommandID", try! JSONEncoder().encode(ChatCommandID(rawValue: "command-1"))),
        ("ChatSessionGenerationID", try! JSONEncoder().encode(ChatSessionGenerationID(rawValue: "generation-1"))),
        ("PermissionRequestID", try! JSONEncoder().encode(PermissionRequestID(rawValue: "permission-1"))),
        ("PermissionOptionID", try! JSONEncoder().encode(PermissionOptionID(rawValue: "option-1"))),
        ("ToolCallID", try! JSONEncoder().encode(ToolCallID(rawValue: "tool-1"))),
    ])
    func stringBackedIdentifiersEncodeAsPrimitiveStrings(name: String, encoded: Data) throws {
        let decoded = try JSONDecoder().decode(String.self, from: encoded)
        #expect(decoded.contains("-1"), "\(name) must encode as a primitive JSON string.")
    }

    @Test func chatUpdateSequenceEncodesAsPrimitiveInteger() throws {
        let encoded = try JSONEncoder().encode(ChatUpdateSequence(rawValue: 42))
        let decoded = try JSONDecoder().decode(Int64.self, from: encoded)
        #expect(decoded == 42)
    }

    @Test func contextReferenceUsesTaggedJSONShape() throws {
        let reference = ChatContextReference.source(SourceID(rawValue: "source-1"))
        let data = try JSONEncoder().encode(reference)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""kind":"source""#))
        #expect(json.contains(#""id":"source-1""#))

        let decoded = try JSONDecoder().decode(ChatContextReference.self, from: data)
        #expect(decoded == reference)
    }

    @Test func transcriptItemsRoundTripWithoutEngineTypes() throws {
        let item = ChatTranscriptItem.toolCall(ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: "tool-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Edit file",
            status: .running,
            detail: "Sources/WikiFSEngine/ChatAgentRuntime.swift",
            permissionRequestID: PermissionRequestID(rawValue: "permission-1"),
            updatedAt: Date(timeIntervalSince1970: 100)
        ))

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ChatTranscriptItem.self, from: encoded)

        #expect(decoded == item)
    }
}
