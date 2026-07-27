import Foundation
import Testing
@testable import WikiFSCore

struct PageIDLegacyCodableCharacterizationTests {
    private func normalizedJSONString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    /// A local copy of the payload shape that existed before `SourceID` was
    /// introduced. Keeping this type local prevents the characterization from
    /// accidentally proving only the new `QueueItemPayload` implementation.
    private struct LegacyQueueItemPayload: Codable {
        let sourceIDs: [PageID]
    }

    /// Local legacy shapes copied from the pre-`ChatID` daemon payloads.
    /// Keeping them local ensures the characterization does not prove only the
    /// new implementation's round-trip behavior.
    private struct LegacyChatStartReply: Codable {
        let chatID: PageID?
        let error: String?
    }

    private struct LegacyChatContinueRequest: Codable {
        let wikiID: WikiID
        let chatID: PageID
        let message: String
    }

    private struct LegacyChatSessionState: Codable {
        let chatID: PageID
        let events: [String]
        let isRunning: Bool
        let isGenerating: Bool
        let isAwaitingGenerationSlot: Bool
        let preflightError: String?
    }

    @Test func pageIDTopLevelShape() throws {
        let data = try JSONEncoder().encode(PageID(rawValue: "LEGACY-SOURCE-ID"))
        let value = try JSONDecoder().decode(String.self, from: data)

        #expect(
            value == "LEGACY-SOURCE-ID",
            "PageID encodes as a primitive JSON string."
        )
    }

    @Test func queuePayloadSourceIDShape() throws {
        let payload = LegacyQueueItemPayload(
            sourceIDs: [PageID(rawValue: "LEGACY-SOURCE-ID")]
        )
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{"sourceIDs":["LEGACY-SOURCE-ID"]}"#.utf8)
        )

        #expect(try normalizedJSONString(from: object) == normalizedJSONString(from: expected))
    }

    @Test func chatValueTopLevelShape() throws {
        let data = try JSONEncoder().encode(PageID(rawValue: "LEGACY-CHAT-ID"))
        let value = try JSONDecoder().decode(String.self, from: data)

        #expect(
            value == "LEGACY-CHAT-ID",
            "Legacy chat-valued PageID encodes as a primitive JSON string."
        )
    }

    @Test func chatStartReplyShape() throws {
        let payload = LegacyChatStartReply(
            chatID: PageID(rawValue: "LEGACY-CHAT-ID"),
            error: nil
        )
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{"chatID":"LEGACY-CHAT-ID"}"#.utf8)
        )

        #expect(try normalizedJSONString(from: object) == normalizedJSONString(from: expected))
    }

    @Test func chatContinueRequestShape() throws {
        let payload = LegacyChatContinueRequest(
            wikiID: WikiID(rawValue: "legacy-wiki"),
            chatID: PageID(rawValue: "LEGACY-CHAT-ID"),
            message: "continue"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{"wikiID":"legacy-wiki","chatID":"LEGACY-CHAT-ID","message":"continue"}"#.utf8)
        )

        #expect(try normalizedJSONString(from: object) == normalizedJSONString(from: expected))
    }

    @Test func chatSessionStateShape() throws {
        let payload = LegacyChatSessionState(
            chatID: PageID(rawValue: "LEGACY-CHAT-ID"),
            events: ["assistantText"],
            isRunning: true,
            isGenerating: true,
            isAwaitingGenerationSlot: false,
            preflightError: nil
        )
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{"chatID":"LEGACY-CHAT-ID","events":["assistantText"],"isRunning":true,"isGenerating":true,"isAwaitingGenerationSlot":false}"#.utf8)
        )

        #expect(try normalizedJSONString(from: object) == normalizedJSONString(from: expected))
    }
}
