import Foundation
import Testing
@testable import WikiFSTypes

struct ChatIdentifierCodableCompatibilityTests {
    private func assertPrimitiveStringEncoding<Value: Codable & Equatable>(
        _ name: String,
        value: Value,
        expectedJSON: String
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json == expectedJSON, "\(name) must encode as an exact primitive JSON string.")
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        #expect(decoded == value, "\(name) must decode from the same primitive JSON string.")
    }

    @Test func stringBackedIdentifiersEncodeAsExactPrimitiveStrings() throws {
        try assertPrimitiveStringEncoding("ChatTurnID", value: ChatTurnID(rawValue: "turn-1"), expectedJSON: "\"turn-1\"")
        try assertPrimitiveStringEncoding("ChatMessageID", value: ChatMessageID(rawValue: "message-1"), expectedJSON: "\"message-1\"")
        try assertPrimitiveStringEncoding("ChatCommandID", value: ChatCommandID(rawValue: "command-1"), expectedJSON: "\"command-1\"")
        try assertPrimitiveStringEncoding("ChatSessionGenerationID", value: ChatSessionGenerationID(rawValue: "generation-1"), expectedJSON: "\"generation-1\"")
        try assertPrimitiveStringEncoding("PermissionRequestID", value: PermissionRequestID(rawValue: "permission-1"), expectedJSON: "\"permission-1\"")
        try assertPrimitiveStringEncoding("PermissionOptionID", value: PermissionOptionID(rawValue: "option-1"), expectedJSON: "\"option-1\"")
        try assertPrimitiveStringEncoding("ToolCallID", value: ToolCallID(rawValue: "tool-1"), expectedJSON: "\"tool-1\"")
        try assertPrimitiveStringEncoding("ChatModeID", value: ChatModeID(rawValue: "mode-1"), expectedJSON: "\"mode-1\"")
        try assertPrimitiveStringEncoding("ChatConfigurationOptionID", value: ChatConfigurationOptionID(rawValue: "option-1"), expectedJSON: "\"option-1\"")
        try assertPrimitiveStringEncoding("ChatConfigurationValueID", value: ChatConfigurationValueID(rawValue: "value-1"), expectedJSON: "\"value-1\"")
    }

    @Test func chatUpdateSequenceEncodesAsPrimitiveInteger() throws {
        let encoded = try JSONEncoder().encode(ChatUpdateSequence(rawValue: 42))
        let decoded = try JSONDecoder().decode(Int64.self, from: encoded)
        #expect(decoded == 42)
    }

    @Test(arguments: [
        (ChatContextReference.page(PageID(rawValue: "page-1")), "page", "page-1"),
        (ChatContextReference.source(SourceID(rawValue: "source-1")), "source", "source-1"),
        (ChatContextReference.chat(ChatID(rawValue: "chat-1")), "chat", "chat-1"),
    ])
    func contextReferenceUsesTaggedJSONShape(
        reference: ChatContextReference,
        expectedKind: String,
        expectedID: String
    ) throws {
        let data = try JSONEncoder().encode(reference)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""kind":"\#(expectedKind)""#))
        #expect(json.contains(#""id":"\#(expectedID)""#))

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
