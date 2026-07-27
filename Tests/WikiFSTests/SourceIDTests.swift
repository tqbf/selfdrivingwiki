import Foundation
import Testing
@testable import WikiFSTypes

struct SourceIDTests {
    @Test func sourceIDMatchesLegacySourceValueShape() throws {
        let sourceID = SourceID(rawValue: "LEGACY-SOURCE-ID")
        let encoded = try JSONEncoder().encode(sourceID)
        let legacyPageIDEncoding = try JSONEncoder().encode(
            PageID(rawValue: sourceID.rawValue)
        )

        let sourceObject = try JSONSerialization.jsonObject(
            with: encoded,
            options: .fragmentsAllowed
        )
        let legacyObject = try JSONSerialization.jsonObject(
            with: legacyPageIDEncoding,
            options: .fragmentsAllowed
        )
        #expect((sourceObject as AnyObject).isEqual(legacyObject))
    }

    @Test func sourceIDPreservesRawValue() throws {
        let sourceID = SourceID(rawValue: "01J-SOURCE")
        let encoded = try JSONEncoder().encode(sourceID)
        let decoded = try JSONDecoder().decode(SourceID.self, from: encoded)

        #expect(decoded.rawValue == "01J-SOURCE")
        #expect(decoded.id == "01J-SOURCE")
    }
}
