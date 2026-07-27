import Foundation
import Testing
@testable import WikiFSTypes

struct ChatIDTests {
    @Test func chatIDMatchesLegacyPageIDJSONShape() throws {
        let chatID = ChatID(rawValue: "LEGACY-CHAT-ID")
        let encoded = try JSONEncoder().encode(chatID)
        let legacyPageIDEncoding = try JSONEncoder().encode(
            PageID(rawValue: chatID.rawValue)
        )
        let chatValue = try JSONDecoder().decode(String.self, from: encoded)
        let legacyValue = try JSONDecoder().decode(String.self, from: legacyPageIDEncoding)

        #expect(chatValue == legacyValue)
    }

    @Test func rawValueAndIdentityArePreserved() throws {
        let chatID = ChatID(rawValue: "01J-CHAT")
        let encoded = try JSONEncoder().encode(chatID)
        let decoded = try JSONDecoder().decode(ChatID.self, from: encoded)

        #expect(decoded.rawValue == "01J-CHAT")
        #expect(decoded.id == "01J-CHAT")
    }

    @Test func hashAndEqualityFollowRawValue() {
        let ids: Set<ChatID> = [
            ChatID(rawValue: "same-chat"),
            ChatID(rawValue: "same-chat"),
            ChatID(rawValue: "other-chat"),
        ]

        #expect(ids.count == 2)
        #expect(ChatID(rawValue: "same-chat") == ChatID(rawValue: "same-chat"))
        #expect(ChatID(rawValue: "same-chat") != ChatID(rawValue: "other-chat"))
    }
}
