import Foundation
import Testing
@testable import WikiFSTypes

struct PageVersionIDTests {
    @Test func pageVersionIDPreservesLegacyRawString() throws {
        let id = PageVersionID(rawValue: "01J-PAGE-VERSION")
        let encoded = try JSONEncoder().encode(id)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"01J-PAGE-VERSION\"")
        let decoded = try JSONDecoder().decode(PageVersionID.self, from: Data("\"01J-PAGE-VERSION\"".utf8))
        #expect(decoded == id)
        #expect(decoded.rawValue == "01J-PAGE-VERSION")
        #expect(decoded.id == id.rawValue)
    }

    @Test func pageVersionIDsRemainNominallyDistinctFromPageIDs() {
        let pageID = PageID(rawValue: "01J-SAME-RAW")
        let versionID = PageVersionID(rawValue: pageID.rawValue)
        #expect(pageID.rawValue == versionID.rawValue)
    }
}
