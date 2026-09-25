import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Deterministic presentation for read-only queue job inspection.
public enum JobCommand {
    public enum Action: Equatable, Sendable {
        case list(json: Bool)
        case get(id: QueueItem.ID, json: Bool)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notFound(QueueItem.ID)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id):
                "No job with ID \(id.rawValue) exists for this wiki. Run `wikictl job list --json` to list known jobs."
            }
        }
    }

    private struct Record: Encodable {
        let id: String
        let queue: String
        let state: String
        let sourceIDs: [String]
        let attempt: Int
        let failureReason: String?
        let extractionCompleted: Bool
        /// Durable admission blocker for a queued item (e.g.
        /// `no-extractor-route`); nil when none is recorded.
        let admission: String?

        enum CodingKeys: String, CodingKey {
            case id, queue, state, sourceIDs, attempt, failureReason, extractionCompleted, admission
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(queue, forKey: .queue)
            try values.encode(state, forKey: .state)
            try values.encode(sourceIDs, forKey: .sourceIDs)
            try values.encode(attempt, forKey: .attempt)
            if let failureReason {
                try values.encode(failureReason, forKey: .failureReason)
            } else {
                try values.encodeNil(forKey: .failureReason)
            }
            try values.encode(extractionCompleted, forKey: .extractionCompleted)
            if let admission {
                try values.encode(admission, forKey: .admission)
            } else {
                try values.encodeNil(forKey: .admission)
            }
        }
    }

    public static func renderList(
        items: [QueueItem],
        completedSourceIDs: Set<SourceID>,
        json: Bool
    ) throws -> String {
        try render(records: items.map { record(for: $0, completedSourceIDs: completedSourceIDs) }, json: json)
    }

    public static func renderGet(
        item: QueueItem,
        completedSourceIDs: Set<SourceID>,
        json: Bool
    ) throws -> String {
        let value = record(for: item, completedSourceIDs: completedSourceIDs)
        if json {
            return try jsonString(value)
        }
        return text(records: [value])
    }

    private static func record(
        for item: QueueItem,
        completedSourceIDs: Set<SourceID>
    ) -> Record {
        Record(
            id: item.id.rawValue,
            queue: item.queue.canonical.rawValue,
            state: item.state.rawValue,
            sourceIDs: item.payload.sourceIDs.map(\.rawValue),
            attempt: item.attempt,
            failureReason: item.error,
            extractionCompleted: item.queue.canonical == .extraction
                && !item.payload.sourceIDs.isEmpty
                && item.payload.sourceIDs.allSatisfy { completedSourceIDs.contains($0) },
            admission: item.admissionReason)
    }

    private static func render(records: [Record], json: Bool) throws -> String {
        json ? try jsonString(records) : text(records: records)
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let output = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: [], debugDescription: "JSON is not UTF-8"))
        }
        return output
    }

    private static func text(records: [Record]) -> String {
        var lines = ["id\tqueue\tstate\tsource_ids\tattempt\tfailure_reason\textraction_completed\tadmission"]
        lines.append(contentsOf: records.map {
            [
                $0.id, $0.queue, $0.state, $0.sourceIDs.joined(separator: ","),
                String($0.attempt), $0.failureReason ?? "", String($0.extractionCompleted),
                $0.admission ?? "",
            ].joined(separator: "\t")
        })
        return lines.joined(separator: "\n")
    }
}
