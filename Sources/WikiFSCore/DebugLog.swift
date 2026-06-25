import Foundation
import os

/// Lightweight structured logging routed to the **unified logging system**
/// (Console.app / `log show`), visible everywhere the core is linked — both the
/// app (`WikiFS`) and the core (`WikiFSCore`) use it.
///
/// To read it back:
///
///   log show --predicate 'subsystem == "com.selfdrivingwiki.debug"' \
///            --style compact --info --debug --last 30m
///
/// or in Console.app, filter the subsystem to `com.selfdrivingwiki.debug`.
/// Values are logged `.public` (diagnostics — pids, exit codes, counts, flags —
/// not user secrets) so they aren't redacted as `<private>`.
public enum DebugLog {
    public static func agent(_ message: @autoclosure () -> String) { emit("agent", message()) }
    public static func ingest(_ message: @autoclosure () -> String) { emit("ingest", message()) }
    public static func extraction(_ message: @autoclosure () -> String) { emit("extraction", message()) }
    public static func tabs(_ message: @autoclosure () -> String) { emit("tabs", message()) }
    public static func store(_ message: @autoclosure () -> String) { emit("store", message()) }
    public static func config(_ message: @autoclosure () -> String) { emit("config", message()) }
    public static func fileprovider(_ message: @autoclosure () -> String) { emit("fileprovider", message()) }
    public static func reader(_ message: @autoclosure () -> String) { emit("reader", message()) }

    private static let subsystem = "com.selfdrivingwiki.debug"
    private static let loggers: [String: Logger] = [
        "agent": Logger(subsystem: subsystem, category: "agent"),
        "ingest": Logger(subsystem: subsystem, category: "ingest"),
        "extraction": Logger(subsystem: subsystem, category: "extraction"),
        "tabs": Logger(subsystem: subsystem, category: "tabs"),
        "store": Logger(subsystem: subsystem, category: "store"),
        "config": Logger(subsystem: subsystem, category: "config"),
        "fileprovider": Logger(subsystem: subsystem, category: "fileprovider"),
        "reader": Logger(subsystem: subsystem, category: "reader"),
    ]

    private static func emit(_ category: String, _ message: String) {
        loggers[category]?.notice("\(message, privacy: .public)")
    }
}
