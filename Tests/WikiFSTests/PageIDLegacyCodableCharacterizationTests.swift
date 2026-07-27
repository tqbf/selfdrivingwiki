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
}
