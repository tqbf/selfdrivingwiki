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
    /// Page/source markdown editor surface (drop-insert, dirty-buffer, agent-
    /// edit-guard events). Distinct from `tabs` (sidebar/tab/open) so editor
    /// events surface cleanly in Console.app.
    public static func editor(_ message: @autoclosure () -> String) { emit("editor", message()) }

    private static let subsystem = "com.selfdrivingwiki.debug"

    /// Shared signposter for low-overhead interval timing visible in Instruments
    /// (near-free when no recorder is attached). Prefer this over `.notice` text
    /// logs for per-call perf measurement — it costs nothing in production but
    /// lights up under the Points-of-Interest instrument when profiling.
    public static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    private static let loggers: [String: Logger] = [
        "agent": Logger(subsystem: subsystem, category: "agent"),
        "ingest": Logger(subsystem: subsystem, category: "ingest"),
        "extraction": Logger(subsystem: subsystem, category: "extraction"),
        "tabs": Logger(subsystem: subsystem, category: "tabs"),
        "store": Logger(subsystem: subsystem, category: "store"),
        "config": Logger(subsystem: subsystem, category: "config"),
        "fileprovider": Logger(subsystem: subsystem, category: "fileprovider"),
        "reader": Logger(subsystem: subsystem, category: "reader"),
        "editor": Logger(subsystem: subsystem, category: "editor"),
    ]

    // `.default` is the "notice" level (persisted by `log show`); `.debug` is
    // captured only with `--debug`. Existing category helpers default to
    // `.default` (= `.notice`), matching the prior `logger.notice` behavior.
    private static func emit(_ category: String, _ message: String, level: OSLogType = .default) {
        loggers[category]?.log(level: level, "\(message, privacy: .public)")
    }

    /// Chatty diagnostic that should NOT clutter the persisted production log.
    /// Emits at `.debug` — captured only with `log show --debug` (or Console's
    /// "Include Debug Messages"). Use for per-call / per-iteration traces (e.g.
    /// every `NLEmbedding` inference, cache hits, availability checks); reserve
    /// the category helpers above (`store`, `tabs`, …) — which emit at `.default`
    /// (notice) — for signal-worthy events that must survive in `log show`.
    public static func debug(_ message: @autoclosure () -> String) {
        emit("store", message(), level: .debug)
    }
}
