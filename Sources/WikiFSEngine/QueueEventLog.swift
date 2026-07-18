import Foundation
import WikiFSCore

// MARK: - QueueEventType

/// The event-type discriminant for `QueueLogRecord`. Each case maps 1:1 to
/// a `QueueEvent` case (modulo associated values). Replaces the former
/// `eventType: String` field — a typo like `"strted"` would silently be
/// written and never caught; with a String-backed enum, the compiler
/// enforces the set of valid values (issue #508).
enum QueueEventType: String, Codable, Sendable {
    case enqueued
    case started
    case completed
    case failed
    case cancelled
    case progress
    case transcript
    case usage
    case runStateChanged
    case reordered
}

// MARK: - QueueLogRecord

/// One JSONL line in the queue event log. Every `QueueEvent` emitted by the
/// `QueueEngine` is encoded as a `QueueLogRecord` and appended to the daily
/// log file. Encoded with `.sortedKeys` for greppable JSON.
struct QueueLogRecord: Codable, Sendable {
    /// Epoch milliseconds — when the event was logged (not the item's own
    /// state-transition timestamp; that's `startedAt`/`finishedAt`).
    let timestamp: Int64

    /// The typed event discriminant — `"enqueued"` | `"started"` | etc.
    /// Typed as `QueueEventType` so a typo cannot be silently written
    /// (issue #508).
    let eventType: QueueEventType

    /// The item's ULID. `nil` for `runStateChanged`.
    let itemID: String?

    /// The `QueueKind` raw value (`"extraction"` / `"ingestion"`).
    let queue: String?

    /// The wiki this item belongs to. `nil` for `runStateChanged`.
    let wikiID: String?

    /// The provider that claimed the item. `nil` until `markRunning`.
    let providerID: String?

    /// The item's `QueueItemState`. `nil` for `runStateChanged` (use
    /// `runState` instead). Typed as `QueueItemState` (not `String`) so
    /// type system tracks which enum a `"running"` value belongs to
    /// — no ambiguity even though `QueueItemState.running` and
    /// `QueueRunState.running` share a common string form (issue #508).
    let itemState: QueueItemState?

    /// The `QueueRunState`. Only populated for `runStateChanged`;
    /// `nil` for all item-carrying events. Typed as `QueueRunState`
    /// (not `String`) so the type system disambiguates from `itemState`
    /// (issue #508).
    let runState: QueueRunState?

    /// The item's `orderingKey` (gap-based position). `nil` for `runStateChanged`.
    let orderingKey: Int64?

    /// The item's retry attempt count. `nil` for `runStateChanged`.
    let attempt: Int?

    /// The error message for `.failed` events (truncated to 4096 chars).
    /// `nil` for all other events.
    let error: String?

    /// The item's authoritative `startedAt` (epoch ms). `nil` for
    /// `runStateChanged` and `.enqueued`.
    let startedAt: Int64?

    /// The item's authoritative `finishedAt` (epoch ms). `nil` for
    /// `runStateChanged`, `.enqueued`, and `.started`.
    let finishedAt: Int64?

    /// `finishedAt - startedAt` for `.completed` / `.failed`; `nil` otherwise.
    let durationMs: Int64?

    /// Reserved for Phase 4: the worker's run-log path (`run.jsonl`). `nil` in
    /// Phase 3 (no real workers). The field exists so Phase 4 can populate it
    /// without a migration.
    let runLogPath: String?

    /// Build a record from a `QueueEvent` at a given log time.
    init(event: QueueEvent, logTime: Date) {
        self.timestamp = Int64(logTime.timeIntervalSince1970 * 1000)

        switch event {
        case .enqueued(let i):
            self.eventType = .enqueued
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = nil
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = nil

        case .started(let i):
            self.eventType = .started
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = nil
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = nil

        case .completed(let i):
            self.eventType = .completed
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = nil
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = Self.computeDuration(startedAt: i.startedAt, finishedAt: i.finishedAt)

        case .failed(let i, let error):
            self.eventType = .failed
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = Self.truncate(error, maxLength: 4096)
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = Self.computeDuration(startedAt: i.startedAt, finishedAt: i.finishedAt)

        case .cancelled(let i):
            self.eventType = .cancelled
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = nil
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = nil

        case .progress:
            // Progress events are high-volume (extraction log lines). They are
            // consumed live by the UI via the event stream, but NOT individually
            // logged to the JSONL audit trail (which records state transitions
            // only). The write() method skips this case.
            self.eventType = .progress
            self.itemID = nil
            self.queue = nil
            self.wikiID = nil
            self.providerID = nil
            self.itemState = nil
            self.runState = nil
            self.orderingKey = nil
            self.attempt = nil
            self.error = nil
            self.startedAt = nil
            self.finishedAt = nil
            self.durationMs = nil

        case .transcript:
            // Transcript events are high-volume (per-agent-event forwarding).
            // Consumed live by the Activity window, NOT logged to JSONL.
            self.eventType = .transcript
            self.itemID = nil
            self.queue = nil
            self.wikiID = nil
            self.providerID = nil
            self.itemState = nil
            self.runState = nil
            self.orderingKey = nil
            self.attempt = nil
            self.error = nil
            self.startedAt = nil
            self.finishedAt = nil
            self.durationMs = nil

        case .usage:
            // Usage events carry cumulative token/cost data per run (#528
            // spike). Consumed live by the Activity window, NOT logged to
            // JSONL. The write() method skips this case (high-volume-ish +
            // SessionUsage is not Codable here).
            self.eventType = .usage
            self.itemID = nil
            self.queue = nil
            self.wikiID = nil
            self.providerID = nil
            self.itemState = nil
            self.runState = nil
            self.orderingKey = nil
            self.attempt = nil
            self.error = nil
            self.startedAt = nil
            self.finishedAt = nil
            self.durationMs = nil

        case .runStateChanged(let queue, let state):
            self.eventType = .runStateChanged
            self.itemID = nil
            self.queue = queue.rawValue
            self.wikiID = nil
            self.providerID = nil
            self.itemState = nil
            self.runState = state
            self.orderingKey = nil
            self.attempt = nil
            self.error = nil
            self.startedAt = nil
            self.finishedAt = nil
            self.durationMs = nil

        case .reordered(let i):
            self.eventType = .reordered
            self.itemID = i.id
            self.queue = i.queue.rawValue
            self.wikiID = i.wikiID
            self.providerID = i.providerID
            self.itemState = i.state
            self.runState = nil
            self.orderingKey = i.orderingKey
            self.attempt = i.attempt
            self.error = nil
            self.startedAt = i.startedAt
            self.finishedAt = i.finishedAt
            self.durationMs = nil
        }

        self.runLogPath = nil
    }

    /// Compute `finishedAt - startedAt`, returning `nil` if either is nil.
    private static func computeDuration(startedAt: Int64?, finishedAt: Int64?) -> Int64? {
        guard let started = startedAt, let finished = finishedAt else { return nil }
        return finished - started
    }

    /// Truncate `str` to `maxLength`, appending "(truncated)" if cut.
    private static func truncate(_ str: String, maxLength: Int) -> String {
        guard str.count > maxLength else { return str }
        let truncated = String(str.prefix(maxLength))
        return truncated + "...(truncated)"
    }
}

// MARK: - QueueEventLog

/// Appends every `QueueEvent` as a JSONL line to a daily-rotated log file
/// under `Logs/queue/` in the App Group container, with bounded retention.
///
/// Designed as an `actor` because the write path is already async (it
/// consumes an `AsyncStream<QueueEvent>`). This eliminates `@unchecked
/// Sendable`, raw locks, and the stop()/write() race — the actor serializes
/// both.
///
/// **Rotation:** the log file is `queue-YYYY-MM-DD.jsonl`. On each write,
/// `ensureOpenForToday()` checks if the date has changed; if so, it closes
/// the old file, opens the new one, and prunes old files. No timer needed.
///
/// **Retention:** files older than `retentionDays` (default 30) are deleted
/// on each rotation (once per day at most).
///
/// **File lifecycle:** the file is created with `createFile` ONLY if it does
/// not already exist (avoids truncating prior-session log data on relaunch).
/// `FileHandle(forWritingTo:)` is opened and seeked to end for appending.
///
/// **ERROR handling:** all file I/O is best-effort (`try?`). The log is
/// observability, not correctness — the engine functions normally even if
/// the log directory is unwritable. Errors are routed through `DebugLog`.
public actor QueueEventLog {

    private let logDirectory: URL
    private let retentionDays: Int
    private let dateProvider: @Sendable () -> Date

    private var fileHandle: FileHandle?
    private var currentDate: String?
    private var streamTask: Task<Void, Never>?
    private var stopped = false

    /// - Parameters:
    ///   - logDirectory: The directory for daily `queue-YYYY-MM-DD.jsonl`
    ///     files (typically `…/Logs/queue/` in the App Group container).
    ///   - retentionDays: Files older than this are pruned on rotation.
    ///   - dateProvider: Injected for testable rotation (default `Date()`).
    public init(
        logDirectory: URL,
        retentionDays: Int = 30,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logDirectory = logDirectory
        self.retentionDays = retentionDays
        self.dateProvider = dateProvider
    }

    // MARK: - Lifecycle

    /// Start consuming `events`. Spawns an unstructured `Task` that iterates
    /// the stream and writes each event as a JSONL line. Idempotent —
    /// subsequent calls are no-ops.
    public func start(events: AsyncStream<QueueEvent>) {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.write(event)
            }
        }
    }

    /// Stop consuming. Cancels the stream task, awaits its completion, sets
    /// the `stopped` flag, and closes the file handle. After this, `write()`
    /// is a no-op.
    public func stop() async {
        stopped = true
        if let task = streamTask {
            task.cancel()
            await task.value
        }
        streamTask = nil
        closeHandle()
    }

    /// Write one event as a JSONL line. Guarded by `stopped`.
    /// Accessible to tests via `writeEventForTest`.
    func write(_ event: QueueEvent) {
        guard !stopped else { return }

        // Progress and transcript events are high-volume. Skip them
        // in the JSONL audit trail — it records state transitions only. The
        // UI consumes them live via the event stream.
        if case .progress = event { return }
        if case .transcript = event { return }
        if case .usage = event { return }

        ensureOpenForToday()
        guard let handle = fileHandle else { return }

        let record = QueueLogRecord(event: event, logTime: dateProvider())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(record),
              let newline = "\n".data(using: .utf8) else { return }

        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: newline)
        } catch {
            DebugLog.store("QueueEventLog.write: failed to write line: \(error)")
        }
    }

    // MARK: - File management

    /// Ensure the correct file is open for the current date. If the date has
    /// changed since the last write, close the old handle, open the new file,
    /// and prune old files.
    private func ensureOpenForToday() {
        let today = Self.dateString(for: dateProvider())
        if today == currentDate, fileHandle != nil { return }

        // Date changed (or first write): close old handle, open new file.
        closeHandle()

        do {
            try FileManager.default.createDirectory(
                at: logDirectory, withIntermediateDirectories: true)
        } catch {
            DebugLog.store("QueueEventLog: failed to create log directory: \(error)")
            return
        }

        let fileURL = logDirectory.appendingPathComponent(
            "\(Self.filenamePrefix)\(today).jsonl", isDirectory: false)

        // Create the file if it does not exist — do NOT use createFile
        // unconditionally (it truncates existing files, destroying prior
        // session log data on relaunch).
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            fileHandle = handle
            currentDate = today
            pruneOldFiles()
        } catch {
            DebugLog.store("QueueEventLog: failed to open \(fileURL.lastPathComponent): \(error)")
            fileHandle = nil
            currentDate = nil
        }
    }

    /// Close the current file handle (if any) and reset state.
    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        // Don't reset currentDate — it's only reset on open failure.
    }

    /// Delete log files older than `retentionDays` in the log directory.
    /// Parses the date from the filename (`queue-YYYY-MM-DD.jsonl`).
    private func pruneOldFiles() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let now = dateProvider()
        let cutoff = now.addingTimeInterval(-Double(retentionDays * 86400))

        for entry in entries {
            // Only match our log files.
            guard entry.lastPathComponent.hasPrefix(Self.filenamePrefix),
                  entry.pathExtension == "jsonl" else { continue }

            // Parse the date from the filename.
            let name = entry.deletingPathExtension().lastPathComponent
            // Strip the prefix to get "YYYY-MM-DD".
            let datePart = String(name.dropFirst(Self.filenamePrefix.count))
            guard let fileDate = Self.parseDate(datePart) else { continue }

            // If the file's date is older than the cutoff, delete it.
            if fileDate < cutoff {
                try? fm.removeItem(at: entry)
                DebugLog.store("QueueEventLog.pruneOldFiles: deleted \(entry.lastPathComponent)")
            }
        }
    }

    // MARK: - Date helpers

    /// The filename prefix for all daily log files: `"queue-"`.
    private static let filenamePrefix = "queue-"

    /// Format a `Date` as `"YYYY-MM-DD"` using the Gregorian calendar, UTC.
    static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Parse a `"YYYY-MM-DD"` string into a `Date`. Returns `nil` on failure.
    static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
