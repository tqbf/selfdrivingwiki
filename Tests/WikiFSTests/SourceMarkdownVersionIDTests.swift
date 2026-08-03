import Foundation
import Testing
@testable import WikiFSTypes

struct SourceMarkdownVersionIDTests {
    @Test func rawValueAndIdentityAreStable() throws {
        let versionID = SourceMarkdownVersionID(rawValue: "01J-SOURCE-MARKDOWN-VERSION")
        let encoded = try JSONEncoder().encode(versionID)
        let decoded = try JSONDecoder().decode(SourceMarkdownVersionID.self, from: encoded)

        #expect(decoded.rawValue == "01J-SOURCE-MARKDOWN-VERSION")
        #expect(decoded.id == "01J-SOURCE-MARKDOWN-VERSION")
    }

    @Test func codableShapeMatchesLegacyPageID() throws {
        let versionID = SourceMarkdownVersionID(rawValue: "LEGACY-MARKDOWN-VERSION-ID")
        let encoded = try JSONEncoder().encode(versionID)
        let legacyPageIDEncoding = try JSONEncoder().encode(
            PageID(rawValue: versionID.rawValue)
        )
        let value = try JSONDecoder().decode(String.self, from: encoded)
        let legacyValue = try JSONDecoder().decode(String.self, from: legacyPageIDEncoding)

        #expect(value == legacyValue)
    }

    @Test func hashAndEqualityUseRawValue() {
        let first = SourceMarkdownVersionID(rawValue: "01JSMV0001")
        let duplicate = SourceMarkdownVersionID(rawValue: "01JSMV0001")
        let second = SourceMarkdownVersionID(rawValue: "01JSMV0002")

        #expect(first == duplicate)
        #expect(first != second)
        #expect(Set([first, duplicate, second]).count == 2)
    }
}
