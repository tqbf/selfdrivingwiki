import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Presentation + actions for the `wikictl transcribe` family: enqueue the
/// EXPLICIT on-device speech transcription for one source through the live
/// daemon workload surface. The job resolves through the same speech arm as
/// the app's menu action — YouTube sources only, the reviewed audio-acquire
/// fetcher, the host speech floor — and never falls back to captions.
public enum TranscribeCommand {
    public enum Action: Equatable, Sendable {
        /// On-device speech transcription for one source. The owning wiki
        /// arrives through the global `--wiki` selector; `wait` blocks on
        /// the job's completion (bounded by the daemon's wait policy) and
        /// prints the outcome.
        case onDevice(source: String, json: Bool, wait: Bool)
    }

    public struct Failure: Error, LocalizedError, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
        public var errorDescription: String? { description }
    }

    // MARK: - Rendering

    public static func renderEnqueued(itemID: String, source: String, wait: Bool) -> String {
        if wait {
            return "enqueued \(itemID) for \(source); waiting for completion…"
        }
        return "enqueued \(itemID) for \(source) (not waiting — check `wikictl job list` / queue status)"
    }

    public static func renderOutcome(
        source: String, completed: Bool, errorMessage: String?, elapsedSeconds: Int
    ) -> String {
        if completed {
            return "on-device transcription completed for \(source) (\(elapsedSeconds)s)"
        }
        let reason = errorMessage ?? "unknown failure (see the queue item)"
        return "on-device transcription FAILED for \(source) after \(elapsedSeconds)s: \(reason)"
    }
}
