import Foundation
import Testing
@testable import WikiFSTypes

struct SourceVersionIDTests {
    @Test func sourceVersionIDEncodesAsLegacyRawString() throws {
        let versionID = SourceVersionID(rawValue: "LEGACY-SOURCE-VERSION-ID")
        let encoded = try JSONEncoder().encode(versionID)
        let decodedRaw = try JSONDecoder().decode(String.self, from: encoded)
        #expect(decodedRaw == versionID.rawValue)
    }

    @Test func sourceVersionIDPreservesRawValueAndIdentity() throws {
        let versionID = SourceVersionID(rawValue: "01J-SOURCE-VERSION")
        let encoded = try JSONEncoder().encode(versionID)
        let decoded = try JSONDecoder().decode(SourceVersionID.self, from: encoded)

        #expect(decoded.rawValue == "01J-SOURCE-VERSION")
        #expect(decoded.id == "01J-SOURCE-VERSION")
    }

    @Test func sourceVersionIDHashAndEqualityUseRawValue() {
        let first = SourceVersionID(rawValue: "01JVERSION0001")
        let duplicate = SourceVersionID(rawValue: "01JVERSION0001")
        let second = SourceVersionID(rawValue: "01JVERSION0002")

        #expect(first == duplicate)
        #expect(first != second)
        #expect(Set([first, duplicate, second]).count == 2)
    }
}
