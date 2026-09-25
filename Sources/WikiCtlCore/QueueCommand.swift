import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Presentation + actions for the `wikictl queue` family: per-lane run-state
/// truth (`status`) and the lane controls (`pause`/`resume`/`halt`) over the
/// live daemon workload surface.
public enum QueueCommand {
    public enum Action: Equatable, Sendable {
        case status(json: Bool)
        case pause(QueueKind)
        case resume(QueueKind)
        case halt(QueueKind)
    }

    // MARK: - Status rendering

    /// One lane's queue truth. Neutral values (not `QueueSnapshot`, which
    /// lives in WikiFSEngine, a module above this one) — the caller maps.
    public struct LaneStatus: Equatable, Sendable {
        public let queue: String
        public let runState: String
        public let running: Int
        public let queued: Int
        /// Queued items carrying a durable admission blocker (e.g.
        /// `no-extractor-route`) — the forever-queued hole made visible.
        public let waitingForRoute: Int

        public init(
            queue: String, runState: String,
            running: Int, queued: Int, waitingForRoute: Int
        ) {
            self.queue = queue
            self.runState = runState
            self.running = running
            self.queued = queued
            self.waitingForRoute = waitingForRoute
        }
    }

    private struct LaneRecord: Encodable {
        let queue: String
        let runState: String
        let running: Int
        let queued: Int
        let waitingForRoute: Int

        enum CodingKeys: String, CodingKey {
            case queue, runState, running, queued, waitingForRoute
        }
    }

    /// Render per-lane queue truth. Counting is the caller's job; this is
    /// presentation only, so the TSV and JSON shapes cannot disagree.
    public static func renderStatus(lanes: [LaneStatus], json: Bool) throws -> String {
        let records: [LaneRecord] = lanes.map {
            LaneRecord(
                queue: $0.queue,
                runState: $0.runState,
                running: $0.running,
                queued: $0.queued,
                waitingForRoute: $0.waitingForRoute)
        }
        if json {
            return try jsonString(records)
        }
        var lines = ["queue\trun_state\trunning\tqueued\twaiting_for_route"]
        lines.append(contentsOf: records.map {
            [
                $0.queue, $0.runState, String($0.running),
                String($0.queued), String($0.waitingForRoute),
            ].joined(separator: "\t")
        })
        return lines.joined(separator: "\n")
    }

    /// One-line confirmation for a lane control verb.
    public static func renderLaneChanged(queue: QueueKind, state: String) -> String {
        "\(queue.canonical.rawValue)\t\(state)"
    }

    // MARK: - JSON helper

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
}
