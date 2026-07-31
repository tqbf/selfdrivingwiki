import Foundation
import WikiFSEngine
import WikiFSCore

/// Named limits make trace retention predictable and keep diagnostic exports
/// bounded even during a noisy streamed response.
enum ChatDiagnosticPolicy {
    static let maximumRecordsPerChat = 256
    static let maximumBytesPerChat = 256 * 1_024
    static let maximumJSONLRecordBytes = 8 * 1_024
    static let maximumJSONLFileBytes = 512 * 1_024
}

struct ChatDiagnosticMergedSnapshot: Codable, Sendable {
    let version: Int
    let sources: [ChatDiagnosticSource]
    let events: [ChatDiagnosticEventEnvelope]
    let mergeOrder: String
    let appSummary: [String: String]
    let daemonSummary: [String: String]
}

enum ChatDiagnosticSnapshotMerge {
    /// Event sequence is authoritative only inside one process. Source and
    /// sequence form the deterministic merge key; time merely breaks ties for
    /// human readability.
    static func merge(
        app: ChatDiagnosticSnapshotEnvelope,
        daemon: ChatDiagnosticSnapshotEnvelope?
    ) -> ChatDiagnosticMergedSnapshot {
        let snapshots = [app] + (daemon.map { [$0] } ?? [])
        let events = snapshots.flatMap(\.events).sorted { lhs, rhs in
            if lhs.process.source == rhs.process.source {
                return lhs.sequence < rhs.sequence
            }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.process.source.rawValue < rhs.process.source.rawValue
        }
        return ChatDiagnosticMergedSnapshot(
            version: ChatDiagnosticTypes.currentVersion,
            sources: snapshots.map(\.process.source),
            events: events,
            mergeOrder: "per-process-sequence; timestamp-approximate-across-sources",
            appSummary: app.summary,
            daemonSummary: daemon?.summary ?? [:]
        )
    }
}

/// App-owned serialized, redacted trace store. It intentionally has no app
/// display-type dependency; UI correlation is supplied as opaque diagnostic
/// values at the call site.
actor ChatDiagnosticTrace {
    private struct StoredRecord: Sendable {
        let event: ChatDiagnosticEventEnvelope
        let byteCount: Int
    }

    private let source: ChatDiagnosticSource
    private var identity: ChatDiagnosticProcessIdentity
    private var fingerprintKey = ChatDiagnosticFingerprintKey()
    private var nextSequence: UInt64 = 0
    private var recordsByChat: [ChatDiagnosticCorrelation.Value: [StoredRecord]] = [:]
    private var droppedRecordsByChat: [ChatDiagnosticCorrelation.Value: Int] = [:]
    private var droppedBytesByChat: [ChatDiagnosticCorrelation.Value: Int] = [:]

    init(source: ChatDiagnosticSource) {
        self.source = source
        self.identity = ChatDiagnosticProcessIdentity(source: source)
    }

    func fingerprint(_ text: String) -> ChatDiagnosticContentFingerprint {
        fingerprintKey.fingerprint(for: text)
    }

    @discardableResult
    func record(
        stage: ChatDiagnosticStage,
        outcome: ChatDiagnosticOutcome,
        payload: ChatDiagnosticPayload = .init()
    ) -> ChatDiagnosticEventEnvelope {
        nextSequence &+= 1
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: ChatDiagnosticSequence(nextSequence),
            stage: stage,
            payload: payload,
            outcome: outcome
        )
        let chat = payload.correlation.chat ?? .init(rawValue: "process")
        append(event, for: chat)
        emit(event)
        return event
    }

    func snapshot(chat: ChatDiagnosticCorrelation.Value? = nil, summary: [String: String] = [:]) -> ChatDiagnosticSnapshotEnvelope {
        let selected = chat.map { recordsByChat[$0] ?? [] } ?? recordsByChat.values.flatMap { $0 }
        let droppedRecords = chat.flatMap { droppedRecordsByChat[$0] } ?? droppedRecordsByChat.values.reduce(0, +)
        let droppedBytes = chat.flatMap { droppedBytesByChat[$0] } ?? droppedBytesByChat.values.reduce(0, +)
        return ChatDiagnosticSnapshotEnvelope(
            process: identity,
            events: selected.map(\.event),
            droppedRecordCount: droppedRecords,
            droppedByteCount: droppedBytes,
            summary: summary
        )
    }

    /// Successful export resets all local correlation material, including the
    /// ring. Callers must only invoke this after their output write succeeds.
    func resetAfterSuccessfulExport() {
        identity = ChatDiagnosticProcessIdentity(source: source)
        fingerprintKey = ChatDiagnosticFingerprintKey()
        nextSequence = 0
        recordsByChat.removeAll()
        droppedRecordsByChat.removeAll()
        droppedBytesByChat.removeAll()
    }

    private func append(_ event: ChatDiagnosticEventEnvelope, for chat: ChatDiagnosticCorrelation.Value) {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(event)
        } catch {
            DebugLog.store("chat diagnostics event encoding failed: \(error)")
            return
        }
        let record = StoredRecord(event: event, byteCount: encoded.count)
        var records = recordsByChat[chat, default: []]
        records.append(record)
        var bytes = records.reduce(0) { $0 + $1.byteCount }
        while records.count > ChatDiagnosticPolicy.maximumRecordsPerChat || bytes > ChatDiagnosticPolicy.maximumBytesPerChat {
            let removed = records.removeFirst()
            bytes -= removed.byteCount
            droppedRecordsByChat[chat, default: 0] += 1
            droppedBytesByChat[chat, default: 0] += removed.byteCount
        }
        recordsByChat[chat] = records
    }

    private func emit(_ event: ChatDiagnosticEventEnvelope) {
        let message = "chat diagnostic stage=\(event.stage.rawValue) outcome=\(event.outcome.rawValue) source=\(event.process.source.rawValue) sequence=\(event.sequence.rawValue)"
        switch event.outcome {
        case .failed, .timeout, .decodeFailure, .versionFailure:
            DebugLog.chatDiagnostics(message, verbose: false)
        default:
            DebugLog.chatDiagnostics(message, verbose: true)
        }
    }
}

/// The process-wide app trace. AppKit-facing callers are on the main actor,
/// while the actor keeps ring writes serial even when callbacks arrive from XPC.
enum ChatDiagnostics {
    static let appTrace = ChatDiagnosticTrace(source: .app)

    /// The UI bridges are synchronous callbacks. The record itself is isolated
    /// in the trace actor, so this short task only crosses that boundary and
    /// never mutates SwiftUI state during an update pass.
    static func observe(
        stage: ChatDiagnosticStage,
        outcome: ChatDiagnosticOutcome = .accepted,
        correlation: ChatDiagnosticCorrelation = .init(),
        detail: String? = nil
    ) {
        Task {
            _ = await appTrace.record(
                stage: stage,
                outcome: outcome,
                payload: .init(correlation: correlation, detail: detail)
            )
        }
    }
}

actor ChatDiagnosticJSONLWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func append(_ event: ChatDiagnosticEventEnvelope, to url: URL) throws -> URL {
        let encoded = try JSONEncoder().encode(event)
        guard encoded.count <= ChatDiagnosticPolicy.maximumJSONLRecordBytes else {
            throw ChatDiagnosticJSONLError.recordTooLarge(encoded.count)
        }
        let newline = Data("\n".utf8)
        let target = try rotatedURLIfNeeded(forAdditionalBytes: encoded.count + newline.count, url: url)
        if !fileManager.fileExists(atPath: target.path) { fileManager.createFile(atPath: target.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: target)
        defer {
            do { try handle.close() }
            catch { DebugLog.store("chat diagnostics JSONL close failed: \(error)") }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded)
        try handle.write(contentsOf: newline)
        return target
    }

    private func rotatedURLIfNeeded(forAdditionalBytes additional: Int, url: URL) throws -> URL {
        let current: Int
        do {
            current = (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            DebugLog.store("chat diagnostics JSONL size inspection failed: \(error)")
            throw error
        }
        guard current + additional > ChatDiagnosticPolicy.maximumJSONLFileBytes else { return url }
        let rotated = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
        if fileManager.fileExists(atPath: rotated.path) { try fileManager.removeItem(at: rotated) }
        if fileManager.fileExists(atPath: url.path) { try fileManager.moveItem(at: url, to: rotated) }
        return url
    }
}

enum ChatDiagnosticJSONLError: Error, Equatable {
    case recordTooLarge(Int)
}
