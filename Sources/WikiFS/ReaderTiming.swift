import Foundation
import os

/// Timing for the markdown reader render path, so the preprocessing / parse /
/// layout split on a large source can be measured instead of guessed (see the
/// "Reader freezes on large source documents" note).
///
/// Mirrors `DebugLog`: each event goes to BOTH the unified logging system at
/// `.notice` (the lowest level macOS *persists*, so it survives for `log show`
/// after the fact) and stdout (visible when the app is launched from a terminal).
/// Note: `.debug`/`.info` are NOT persisted by default — that's why this uses
/// `.notice`, matching `DebugLog`.
///
/// To read a run back:
///
///   log show --predicate 'subsystem == "com.selfdrivingwiki.debug"' \
///            --style compact --info --last 30m | grep -E 'render|webview'
///
/// Signposts (near-free when nothing records) are also emitted for Instruments.
///
/// Use `ReaderTiming.measure("reader.preprocess") { … }` around synchronous work,
/// and `ReaderTiming.point("webview.appear-to-painted", ms: …)` for a phase timed
/// across async hops.
enum ReaderTiming {
    private static let osLog = OSLog(subsystem: DebugSubsystem.value, category: "render")
    private static let logger = Logger(subsystem: DebugSubsystem.value, category: "render")

    /// `OSSignposter` for interval timing. Signposts are near-free when no
    /// recorder is attached, so this is safe to leave in production builds.
    static let signposter = OSSignposter(logHandle: osLog)

    /// Time a synchronous block: emits a signpost interval + a persisted `.notice`
    /// ms line (+ stdout). Returns the block's result unchanged.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now()
        defer {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            emit(name, ms: Double(elapsedNs) / 1_000_000)
            signposter.endInterval(name, state)
        }
        return try body()
    }

    /// Emit a single point measurement (ms) — for phases timed across async hops
    /// where a `measure` interval won't span the work, e.g. WKWebView appear →
    /// content painted.
    static func point(_ name: StaticString, ms: Double) {
        emit(name, ms: ms)
    }

    private static func emit(_ name: StaticString, ms: Double) {
        let label = "\(name)"
        logger.notice("\(label, privacy: .public) \(String(format: "%.1f", ms)) ms")
        // Write via a raw write() (FileHandle.write) instead of `print()`: when
        // stdout is redirected to a file it's fully buffered, so `print` lines
        // never flush for sparse events. This makes timings appear immediately.
        let line = "[render] \(label) \(String(format: "%.1f", ms)) ms\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

/// Single source of truth for the debug subsystem string (shared with DebugLog).
enum DebugSubsystem {
    static let value = "com.selfdrivingwiki.debug"
}
