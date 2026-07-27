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
        let sourceValue = try JSONDecoder().decode(String.self, from: encoded)
        let legacyValue = try JSONDecoder().decode(String.self, from: legacyPageIDEncoding)
        #expect(sourceValue == legacyValue)
    }

    @Test func sourceIDPreservesRawValue() throws {
        let sourceID = SourceID(rawValue: "01J-SOURCE")
        let encoded = try JSONEncoder().encode(sourceID)
        let decoded = try JSONDecoder().decode(SourceID.self, from: encoded)

        #expect(decoded.rawValue == "01J-SOURCE")
        #expect(decoded.id == "01J-SOURCE")
    }
}
