#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

struct ChatXPCRequestCompatibilityTests {

    private func normalizedJSONObjectString(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: normalizedData, encoding: .utf8))
    }

    @Test func legacyStartReplyDecodes() throws {
        let legacyJSON = Data(#"{"chatID":"LEGACY-CHAT-ID"}"#.utf8)

        let decoded = try JSONDecoder().decode(ChatStartReply.self, from: legacyJSON)
        #expect(decoded.chatID == ChatID(rawValue: "LEGACY-CHAT-ID"))
        #expect(decoded.error == nil)

        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try normalizedJSONObjectString(from: reencoded) == normalizedJSONObjectString(from: legacyJSON))
    }

    @Test func legacyStartReplyWithNilChatIDRoundTrips() throws {
        let legacyJSON = Data(#"{"error":"preflight failed"}"#.utf8)

        let decoded = try JSONDecoder().decode(ChatStartReply.self, from: legacyJSON)
        #expect(decoded.chatID == nil)
        #expect(decoded.error == "preflight failed")

        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try normalizedJSONObjectString(from: reencoded) == normalizedJSONObjectString(from: legacyJSON))
    }

    @Test func legacyContinueRequestRoundTrips() throws {
        let legacyJSON = Data(#"{"wikiID":"legacy-wiki","chatID":"LEGACY-CHAT-ID","message":"continue"}"#.utf8)

        let decoded = try JSONDecoder().decode(ChatContinueRequest.self, from: legacyJSON)
        #expect(decoded.wikiID == WikiID(rawValue: "legacy-wiki"))
        #expect(decoded.chatID == ChatID(rawValue: "LEGACY-CHAT-ID"))
        #expect(decoded.message == "continue")

        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try normalizedJSONObjectString(from: reencoded) == normalizedJSONObjectString(from: legacyJSON))
    }

    @Test func legacySessionStateRoundTrips() throws {
        let legacyJSON = Data(
            #"{"chatID":"LEGACY-CHAT-ID","events":[],"isRunning":true,"isGenerating":false,"isAwaitingGenerationSlot":true}"#
                .utf8)

        let decoded = try JSONDecoder().decode(ChatSessionState.self, from: legacyJSON)
        #expect(decoded.chatID == ChatID(rawValue: "LEGACY-CHAT-ID"))
        #expect(decoded.events.isEmpty)
        #expect(decoded.isRunning == true)
        #expect(decoded.isGenerating == false)
        #expect(decoded.isAwaitingGenerationSlot == true)

        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try normalizedJSONObjectString(from: reencoded) == normalizedJSONObjectString(from: legacyJSON))
    }
}
#endif
