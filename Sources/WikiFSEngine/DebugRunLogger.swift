import Foundation
import ACPModel
import WikiFSCore

/// Best-effort per-run debug logger that captures the **complete** ACP
/// wire-level trace for a single agent run into `<scratch>/debug/`.
///
/// Every write is best-effort — failures are logged via `DebugLog` and never
/// thrown, so a logging failure can never break an agent run. The logger is
/// `@unchecked Sendable` with an internal lock (same pattern as
/// `SessionUsageState` / `NotificationFanout`) so it can be captured by the
/// off-actor drain/prompt tasks inside `ACPBackend.send`.
///
/// Folder layout (per the debug-logs task):
/// ```
/// <scratch>/debug/
/// ├── session-new.json          — session/new response (model, capabilities, configOptions)
/// ├── turns/
/// │   ├── turn-1-prompt.json    — session/prompt request (full content)
/// │   ├── turn-1-updates.jsonl  — every session/update notification (one JSON per line)
/// │   ├── turn-1-response.json  — session/prompt response (stopReason, usage)
/// │   └── turn-2-…
/// ├── permissions.jsonl         — every request_permission + the client's response
/// ├── stderr.log                — full agent stderr
/// └── summary.json              — run metadata (written by the launcher after the run)
/// ```
///
/// The existing lightweight `run.jsonl`/`run.stderr.log` are NOT touched —
/// this is the verbose, complete, machine-readable companion.
final class DebugRunLogger: @unchecked Sendable {

    private let lock = NSLock()
    private let folderURL: URL
    private let turnsURL: URL
    private var turnCounter = 0
    private var sessionCounter = 0

    /// Pretty-printed encoder for single-message `.json` files.
    private let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Compact encoder for `.jsonl` files (one JSON object per line).
    private let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Create the `debug/` + `debug/turns/` directories. Returns nil when
    /// `folderURL` is nil (debug logging disabled) or if the directories
    /// cannot be created — the caller proceeds without debug logging.
    init?(folderURL: URL?) {
        guard let folderURL else { return nil }
        let turns = folderURL.appendingPathComponent("turns", isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try manager.createDirectory(at: turns, withIntermediateDirectories: true)
        } catch {
            DebugLog.agent("DebugRunLogger: could not create debug folder at \(folderURL.path): \(error.localizedDescription)")
            return nil
        }
        self.folderURL = folderURL
        self.turnsURL = turns
    }

    // MARK: - Session-level

    /// Write the `session/new` response (model, capabilities, configOptions)
    /// to `session-new.json`. For the first session the file is
    /// `session-new.json`; for subsequent sessions (multi-phase ingest —
    /// planner/executors/finalizer) it is `session-new-2.json`,
    /// `session-new-3.json`, etc. so no session's data is lost.
    func logSessionNew(
        _ response: NewSessionResponse,
        sessionId: SessionId,
        workingDirectory: String?
    ) {
        let index = nextSessionIndex()
        let name = index == 1 ? "session-new" : "session-new-\(index)"
        let url = folderURL.appendingPathComponent("\(name).json", isDirectory: false)
        let payload: [String: Any?] = [
            "sessionId": sessionId.value,
            "workingDirectory": workingDirectory,
            "response": encodeToAny(response),
        ]
        writeJSON(payload, to: url, encoder: prettyEncoder)
    }

    // MARK: - Turns

    /// Increment and return the 1-based turn index. Called at the top of each
    /// `ACPBackend.send` before the prompt goes out. Turn numbers are
    /// per-run (continue across multi-phase sessions) since a run's turns
    /// are serialized by the generation gate.
    func nextTurn() -> Int {
        lock.lock()
        turnCounter += 1
        let n = turnCounter
        lock.unlock()
        return n
    }

    /// Write the `session/prompt` request for `turn` to
    /// `turn-N-prompt.json`. The content blocks are captured as their text
    /// representation (the primary content type sent today).
    func logPromptRequest(text: String, sessionId: SessionId, turn: Int) {
        let url = turnFile(turn, suffix: "prompt", ext: "json")
        let payload: [String: Any?] = [
            "turn": turn,
            "sessionId": sessionId.value,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "content": [
                ["type": "text", "text": text],
            ],
        ]
        writeJSON(payload, to: url, encoder: prettyEncoder)
    }

    /// Append a `session/update` notification to `turn-N-updates.jsonl` (one
    /// compact JSON object per line). Called from the per-turn drain task for
    /// every notification the agent sends.
    func logUpdate(_ notification: JSONRPCNotification, turn: Int) {
        let url = turnFile(turn, suffix: "updates", ext: "jsonl")
        let payload: [String: Any?] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "method": notification.method,
            "params": encodeToAny(notification.params),
        ]
        appendJSONLine(payload, to: url)
    }

    /// Write the `session/prompt` response for `turn` to
    /// `turn-N-response.json`. Captures stopReason, usage, and any _meta.
    func logPromptResponse(_ response: SessionPromptResponse, turn: Int) {
        let url = turnFile(turn, suffix: "response", ext: "json")
        let payload: [String: Any?] = [
            "turn": turn,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "response": encodeToAny(response),
        ]
        writeJSON(payload, to: url, encoder: prettyEncoder)
    }

    /// Write a prompt error for `turn` to `turn-N-response.json` (when
    /// `sendPrompt` throws, no `SessionPromptResponse` is available).
    func logPromptError(_ error: Error, turn: Int) {
        let url = turnFile(turn, suffix: "response", ext: "json")
        let payload: [String: Any?] = [
            "turn": turn,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "error": error.localizedDescription,
        ]
        writeJSON(payload, to: url, encoder: prettyEncoder)
    }

    // MARK: - Permissions

    /// Append a permission request + the client's response + the policy that
    /// drove the decision to `permissions.jsonl` (one compact JSON per line).
    func logPermission(
        request: RequestPermissionRequest,
        response: RequestPermissionResponse,
        policy: String
    ) {
        let url = folderURL.appendingPathComponent("permissions.jsonl", isDirectory: false)
        let payload: [String: Any?] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "policy": policy,
            "request": encodeToAny(request),
            "response": encodeToAny(response),
        ]
        appendJSONLine(payload, to: url)
    }

    // MARK: - Stderr

    /// Append a line of agent stderr to `debug/stderr.log`.
    func logStderr(_ line: String) {
        let url = folderURL.appendingPathComponent("stderr.log", isDirectory: false)
        guard let data = line.data(using: .utf8) else { return }
        append(data, to: url)
    }

    // MARK: - Summary (written by the launcher)

    /// Write run-level metadata to `summary.json`. Called by the launcher
    /// after the run completes (in `finish()`).
    func logSummary(_ summary: DebugRunSummary) {
        let url = folderURL.appendingPathComponent("summary.json", isDirectory: false)
        writeJSON(encodeToAny(summary), to: url, encoder: prettyEncoder)
    }

    /// The absolute path to the `debug/` folder (for the "Reveal Debug Folder"
    /// UI affordance).
    var folderPath: URL { folderURL }

    // MARK: - Private helpers

    private func nextSessionIndex() -> Int {
        lock.lock()
        sessionCounter += 1
        let n = sessionCounter
        lock.unlock()
        return n
    }

    private func turnFile(_ turn: Int, suffix: String, ext: String) -> URL {
        turnsURL.appendingPathComponent("turn-\(turn)-\(suffix)", isDirectory: false)
            .appendingPathExtension(ext)
    }

    /// Encode an `Encodable` to an `Any` suitable for nesting inside a
    /// `[String: Any]` that gets serialized by `JSONSerialization`. Returns
    /// nil on failure — the field is omitted rather than crashing.
    private func encodeToAny<T: Encodable>(_ value: T?) -> Any? {
        guard let value else { return nil }
        guard let data = try? prettyEncoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }

    /// Encode a `[String: Any?]` dictionary to pretty-printed JSON and write to
    /// `url`. Best-effort: failures are logged, never thrown.
    private func writeJSON(_ payload: Any?, to url: URL, encoder _: JSONEncoder) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload ?? [String: Any](),
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            try data.write(to: url, options: .atomic)
        } catch {
            DebugLog.agent("DebugRunLogger: writeJSON failed \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Encode a `[String: Any?]` dictionary to compact JSON and append as one
    /// line to `url` (`.jsonl`). Best-effort.
    private func appendJSONLine(_ payload: [String: Any?], to url: URL) {
        let unwrapped = payload.mapValues { $0 ?? NSNull() }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: unwrapped, options: [.sortedKeys, .fragmentsAllowed])
            var line = data
            line.append(0x0A) // \n
            append(line, to: url)
        } catch {
            DebugLog.agent("DebugRunLogger: appendJSONLine failed \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Append raw `Data` to `url`, creating the file if needed. Best-effort.
    private func append(_ data: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            DebugLog.agent("DebugRunLogger: append failed \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

// MARK: - Summary model

/// Run-level metadata written to `debug/summary.json` after a run completes.
/// Codable so it round-trips through `JSONEncoder` for a stable, sorted
/// JSON output.
struct DebugRunSummary: Codable, Sendable {
    struct PhaseBreakdown: Codable, Sendable {
        var name: String
        var durationSeconds: Double?
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var cost: Double?
    }

    var provider: String?
    var model: String?
    var kind: String?
    var startedAt: String?
    var finishedAt: String?
    var durationSeconds: Double?
    var usage: UsageSnapshot?
    var phases: [PhaseBreakdown]

    struct UsageSnapshot: Codable, Sendable {
        var inputTokens: Int
        var outputTokens: Int
        var totalTokens: Int
        var cachedReadTokens: Int?
        var thoughtTokens: Int?
        var cost: Double?
        var currency: String?
        var contextUsed: Int
        var contextSize: Int
    }

    static func from(
        provider: String?,
        model: String?,
        kind: String?,
        startedAt: Date?,
        finishedAt: Date?,
        usage: SessionUsage?,
        phases: [PhaseBreakdown]
    ) -> DebugRunSummary {
        let fmt = ISO8601DateFormatter()
        var duration: Double?
        if let s = startedAt, let f = finishedAt {
            duration = f.timeIntervalSince(s)
        }
        var snap: UsageSnapshot?
        if let u = usage {
            snap = UsageSnapshot(
                inputTokens: u.inputTokens,
                outputTokens: u.outputTokens,
                totalTokens: u.totalTokens,
                cachedReadTokens: u.cachedReadTokens,
                thoughtTokens: u.thoughtTokens,
                cost: u.cost,
                currency: u.currency,
                contextUsed: u.contextUsed,
                contextSize: u.contextSize)
        }
        return DebugRunSummary(
            provider: provider,
            model: model,
            kind: kind,
            startedAt: startedAt.map { fmt.string(from: $0) },
            finishedAt: finishedAt.map { fmt.string(from: $0) },
            durationSeconds: duration,
            usage: snap,
            phases: phases)
    }
}
