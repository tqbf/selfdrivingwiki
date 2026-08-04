// pattern: Functional Core

import Foundation

/// Pure, side-effect-free progress-message formatting for the repository
/// reader fan-out. The daemon's `runReaderFanout` calls these from the parent
/// task-group completion loop — never from child tasks — and feeds the result
/// to the queue `onProgress` callback so the UI updates as each reader finishes.
public enum ReaderFanoutProgress {
    /// Message emitted before the first reader starts: "(0/total)".
    public static func start(repositoryName: String, total: Int) -> String {
        "Reading \(repositoryName) with \(total) readers (0/\(total))…"
    }

    /// Message emitted after a reader digest completes: "(completed/total)".
    public static func readerCompleted(repositoryName: String, completed: Int, total: Int) -> String {
        "Reading \(repositoryName) with \(total) readers (\(completed)/\(total))…"
    }

    /// Message emitted after all readers finish, just before the curator
    /// handoff.
    public static func curatorHandoff(repositoryName: String, total: Int) -> String {
        "All \(total) readers finished for \(repositoryName), starting curator…"
    }
}
