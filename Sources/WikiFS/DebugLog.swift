import Foundation
import os

/// Lightweight structured logging used to instrument agent runs so a stuck UI
/// (spinner that never stops, Cancel that appears dead) can be diagnosed AFTER
/// the fact rather than reproduced live.
///
/// Every event goes to BOTH the unified logging system (Console.app / `log show`)
/// and stdout (visible when the app is launched from a terminal). To read a run
/// back afterwards:
///
///   log show --predicate 'subsystem == "com.selfdrivingwiki.debug"' \
///            --style compact --info --debug --last 30m
///
/// or in Console.app, filter the subsystem to `com.selfdrivingwiki.debug`. Values
/// are logged `.public` (these are diagnostics — pids, exit codes, counts, flags —
/// not user secrets) so they aren't redacted as `<private>`.
enum DebugLog {
    static func agent(_ message: @autoclosure () -> String) { emit("agent", message()) }
    static func ingest(_ message: @autoclosure () -> String) { emit("ingest", message()) }
    static func extraction(_ message: @autoclosure () -> String) { emit("extraction", message()) }

    private static let subsystem = "com.selfdrivingwiki.debug"
    private static let loggers: [String: Logger] = [
        "agent": Logger(subsystem: subsystem, category: "agent"),
        "ingest": Logger(subsystem: subsystem, category: "ingest"),
        "extraction": Logger(subsystem: subsystem, category: "extraction"),
    ]

    private static func emit(_ category: String, _ message: String) {
        loggers[category]?.notice("\(message, privacy: .public)")
        print("[\(category)] \(message)")
    }
}
