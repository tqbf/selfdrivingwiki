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

    @Test func parserRecognizesQueueFamilyVerbs() throws {
        let status = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "queue", "status", "--json"], env: { _ in nil })
        #expect(status.command == .queue(.status(json: true)))

        let pause = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "queue", "pause", "--lane", "ingestion"],
            env: { _ in nil })
        #expect(pause.command == .queue(.pause(.ingestion)))

        let resume = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "queue", "resume", "--lane", "extraction"],
            env: { _ in nil })
        #expect(resume.command == .queue(.resume(.extraction)))

        let halt = try ArgumentParser.parse(
            ["--wiki", wikiID.rawValue, "queue", "halt", "--lane", "ingestion"],
            env: { _ in nil })
        #expect(halt.command == .queue(.halt(.ingestion)))

        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["queue", "pause"], env: { _ in nil })
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["queue", "pause", "--lane", "lint"], env: { _ in nil })
        }
    }

    @Test func jobRowsCarryTheAdmissionColumn() throws {
        let sourceID = SourceID(rawValue: "01JSOURCE00000000000000000")
        let waiting = QueueItem(
            id: QueueItemID(rawValue: "01JJOB00000000000000000000"),
            queue: .extraction,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [sourceID]),
            state: .queued,
            orderingKey: 1_000,
            attempt: 0,
            createdAt: 0,
            admissionReason: QueueAdmissionReason.noExtractorRoute,
            admissionCheckedAt: 42)

        let text = try JobCommand.renderList(
            items: [waiting], completedSourceIDs: [], json: false)
        #expect(text.contains("admission"))
        #expect(text.contains(QueueAdmissionReason.noExtractorRoute))

        let json = try JobCommand.renderList(
            items: [waiting], completedSourceIDs: [], json: true)
        #expect(json.contains("no-extractor-route"))

        // A plain item renders an empty admission column and JSON nil.
        let plain = QueueItem(
            id: QueueItemID(rawValue: "01JJOB00000000000000000001"),
            queue: .extraction,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [sourceID]),
            state: .queued,
            orderingKey: 2_000,
            attempt: 0,
            createdAt: 0)
        let plainText = try JobCommand.renderList(
            items: [plain], completedSourceIDs: [], json: false)
        #expect(!plainText.contains("no-extractor-route"))
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
