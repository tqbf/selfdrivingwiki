import Foundation
import Testing
import WikiCtlCore
import WikiFSCore
import WikiFSTypes

@Suite("wikictl job command")
struct JobCommandTests {
    private let wikiID = WikiID(rawValue: "01JTESTWIKI000000000000000")

    @Test func parserRecognizesListAndGet() throws {
        let list = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "job", "list", "--json"],
            env: { _ in nil })
        #expect(list.command == .job(.list(json: true)))

        let get = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "job", "get", "--id", "01JJOB00000000000000000000", "--json"],
            env: { _ in nil })
        #expect(get.command == .job(.get(
            id: QueueItemID(rawValue: "01JJOB00000000000000000000"), json: true)))
    }

    @Test func emptyJSONListUsesStableArrayShape() throws {
        let output = try JobCommand.renderList(items: [], completedSourceIDs: [], json: true)
        #expect(output == "[]")
    }

    @Test func failedJobJSONIncludesStableFields() throws {
        let sourceID = SourceID(rawValue: "01JSOURCE00000000000000000")
        let item = QueueItem(
            id: QueueItemID(rawValue: "01JJOB00000000000000000000"),
            queue: .extraction,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [sourceID]),
            state: .failed,
            orderingKey: 1_000,
            providerID: nil,
            attempt: 2,
            error: "download failed",
            createdAt: 1,
            startedAt: 2,
            finishedAt: 3)

        let output = try JobCommand.renderList(
            items: [item], completedSourceIDs: [], json: true)
        let data = try #require(output.data(using: .utf8))
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let row = try #require(rows.first)

        #expect(row["id"] as? String == item.id.rawValue)
        #expect(row["queue"] as? String == "extraction")
        #expect(row["state"] as? String == "failed")
        #expect(row["sourceIDs"] as? [String] == [sourceID.rawValue])
        #expect(row["attempt"] as? Int == 2)
        #expect(row["failureReason"] as? String == "download failed")
        #expect(row["extractionCompleted"] as? Bool == false)
    }
}
