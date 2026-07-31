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
    let retention: [ChatDiagnosticMergedRetention]
}

/// Exported retention accounting. Keeping it adjacent to the merged event list
/// prevents a bounded ring from being mistaken for a complete history.
struct ChatDiagnosticMergedRetention: Codable, Sendable, Hashable {
    let source: ChatDiagnosticSource
    let instanceID: UUID
    let droppedRecordCount: Int
    let droppedByteCount: Int
    let summary: [String: String]
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
            // This is deliberately a single lexicographic key. Mixing a
            // per-source sequence comparison with a cross-source timestamp
            // comparison is non-transitive and makes Swift's sort unspecified.
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.process.source != rhs.process.source { return lhs.process.source.rawValue < rhs.process.source.rawValue }
            if lhs.process.instanceID != rhs.process.instanceID { return lhs.process.instanceID.uuidString < rhs.process.instanceID.uuidString }
            return lhs.sequence < rhs.sequence
        }
        return ChatDiagnosticMergedSnapshot(
            version: ChatDiagnosticTypes.currentVersion,
            sources: snapshots.map(\.process.source),
            events: events,
            mergeOrder: "per-process-sequence; timestamp-approximate-across-sources",
            appSummary: app.summary,
            daemonSummary: daemon?.summary ?? [:],
            retention: snapshots.map {
                ChatDiagnosticMergedRetention(
                    source: $0.process.source,
                    instanceID: $0.process.instanceID,
                    droppedRecordCount: $0.droppedRecordCount,
                    droppedByteCount: $0.droppedByteCount,
                    summary: $0.summary
                )
            }
        )
    }
}

/// App-owned serialized, redacted trace store. It intentionally has no app
/// display-type dependency; UI correlation is supplied as opaque diagnostic
/// values at the call site.
@MainActor
final class ChatDiagnosticTrace {
    private struct StoredRecord: Sendable {
        let event: ChatDiagnosticEventEnvelope
        let byteCount: Int
    }

    private let source: ChatDiagnosticSource
    private var identity: ChatDiagnosticProcessIdentity
    private var fingerprintKey = ChatDiagnosticFingerprintKey()
    private var nextSequence: UInt64 = 0
    private enum Bucket: Hashable {
        case chat(ChatDiagnosticCorrelation.Value)
        case process
    }

    private var recordsByBucket: [Bucket: [StoredRecord]] = [:]
    private var droppedRecordsByBucket: [Bucket: Int] = [:]
    private var droppedBytesByBucket: [Bucket: Int] = [:]

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
        let bucket = payload.correlation.chat.map(Bucket.chat) ?? .process
        let didCoalesce = shouldCoalesce(stage: stage, correlation: payload.correlation)
            && recordsByBucket[bucket]?.last.map { coalescingKey(for: $0.event) == coalescingKey(stage: stage, correlation: payload.correlation) } == true
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: ChatDiagnosticSequence(nextSequence),
            stage: stage,
            payload: payload,
            outcome: didCoalesce ? .coalesced : outcome
        )
        append(event, for: bucket)
        emit(event)
        return event
    }

    func snapshot(chat: ChatDiagnosticCorrelation.Value? = nil, summary: [String: String] = [:]) -> ChatDiagnosticSnapshotEnvelope {
        let selected = chat.map { recordsByBucket[.chat($0)] ?? [] } ?? recordsByBucket.values.flatMap { $0 }
        let droppedRecords = chat.map { droppedRecordsByBucket[.chat($0)] ?? 0 } ?? droppedRecordsByBucket.values.reduce(0, +)
        let droppedBytes = chat.map { droppedBytesByBucket[.chat($0)] ?? 0 } ?? droppedBytesByBucket.values.reduce(0, +)
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
        recordsByBucket.removeAll()
        droppedRecordsByBucket.removeAll()
        droppedBytesByBucket.removeAll()
    }

    private func append(_ event: ChatDiagnosticEventEnvelope, for bucket: Bucket) {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(event)
        } catch {
            DebugLog.store("chat diagnostics event encoding failed: \(error)")
            return
        }
        let record = StoredRecord(event: event, byteCount: encoded.count)
        var records = recordsByBucket[bucket, default: []]
        if shouldCoalesce(event), let last = records.last, coalescingKey(for: last.event) == coalescingKey(for: event) {
            records.removeLast()
        }
        records.append(record)
        var bytes = records.reduce(0) { $0 + $1.byteCount }
        while records.count > ChatDiagnosticPolicy.maximumRecordsPerChat || bytes > ChatDiagnosticPolicy.maximumBytesPerChat {
            let removed = records.removeFirst()
            bytes -= removed.byteCount
            droppedRecordsByBucket[bucket, default: 0] += 1
            droppedBytesByBucket[bucket, default: 0] += removed.byteCount
        }
        recordsByBucket[bucket] = records
    }

    private func shouldCoalesce(_ event: ChatDiagnosticEventEnvelope) -> Bool {
        shouldCoalesce(stage: event.stage, correlation: event.payload.correlation)
    }

    private func shouldCoalesce(stage: ChatDiagnosticStage, correlation: ChatDiagnosticCorrelation) -> Bool {
        switch stage {
        case .syncReconciliation, .renderPlanning, .displayProjection:
            return correlation.updateSequence != nil || correlation.rendererRevision != nil || correlation.displayRow != nil
        default:
            return false
        }
    }

    private func coalescingKey(for event: ChatDiagnosticEventEnvelope) -> String? {
        coalescingKey(stage: event.stage, correlation: event.payload.correlation)
    }

    private func coalescingKey(stage: ChatDiagnosticStage, correlation: ChatDiagnosticCorrelation) -> String? {
        guard shouldCoalesce(stage: stage, correlation: correlation) else { return nil }
        let subject = correlation.durableItem?.rawValue ?? correlation.displayRow?.rawValue
        // A display row or durable item identifies the streamed message. Keep
        // its newest revision rather than only collapsing duplicate callbacks
        // for one revision. When no item is known, a revision is the narrowest
        // safe coalescing boundary.
        let revision = subject == nil
            ? correlation.rendererRevision.map { String($0.rawValue) } ?? correlation.updateSequence.map { String($0.rawValue) } ?? ""
            : "message"
        return [
            stage.rawValue,
            correlation.chat?.rawValue ?? "",
            subject ?? "",
            revision
        ].joined(separator: "|")
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

/// The process-wide app trace. AppKit-facing callers serialize observation on
/// the main actor, preserving the order in which UI and XPC callbacks arrive.
@MainActor
enum ChatDiagnostics {
    static let appTrace = ChatDiagnosticTrace(source: .app)

    static func fingerprint(_ text: String) -> ChatDiagnosticContentFingerprint {
        appTrace.fingerprint(text)
    }

    /// AppKit and SwiftUI callbacks run on the main actor. Recording directly
    /// here preserves producer order instead of scheduling independent tasks
    /// that can arrive at the trace actor out of order.
    static func observe(
        stage: ChatDiagnosticStage,
        outcome: ChatDiagnosticOutcome = .accepted,
        correlation: ChatDiagnosticCorrelation = .init(),
        detail: String? = nil
    ) {
        _ = appTrace.record(
            stage: stage,
            outcome: outcome,
            payload: .init(correlation: correlation, detail: detail)
        )
    }

}

/// App-side export boundary for the redacted diagnostic artifact. The caller
/// supplies the destination so AppKit pasteboard access stays at the UI edge
/// and tests can exercise real coordinator snapshots without a hosted view.
@MainActor
struct ChatDiagnosticExporter {
    private let trace: ChatDiagnosticTrace
    private let jsonlWriter: ChatDiagnosticJSONLWriter

    init(
        trace: ChatDiagnosticTrace = ChatDiagnostics.appTrace,
        jsonlWriter: ChatDiagnosticJSONLWriter = ChatDiagnosticJSONLWriter()
    ) {
        self.trace = trace
        self.jsonlWriter = jsonlWriter
    }

    /// Copies one complete redacted merged snapshot.
    ///
    /// The coordinator commits ring rotation after both the destination and
    /// the daemon reset acknowledge success.
    func copy(
        _ snapshot: ChatDiagnosticMergedSnapshot,
        write: (Data) throws -> Void
    ) async throws {
        let data = try JSONEncoder().encode(snapshot)
        try write(data)
    }

    /// Appends the merged trace records to a redacted JSONL artifact. This is
    /// deliberately separate from the full-content debug-folder workflow.
    func writeJSONL(
        _ snapshot: ChatDiagnosticMergedSnapshot,
        to url: URL
    ) async throws {
        try await jsonlWriter.appendSnapshotAtomically(snapshot, to: url)
    }

    /// Commit a completed app/daemon diagnostic export.
    func resetAfterSuccessfulExport() {
        trace.resetAfterSuccessfulExport()
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
        if !fileManager.fileExists(atPath: target.path) {
            try Data().write(to: target, options: .withoutOverwriting)
        }
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

    /// A whole exported snapshot is one JSONL record. The file is replaced
    /// atomically only after the complete next contents are durable, so retrying
    /// a failed export cannot duplicate a partial prefix.
    func appendSnapshotAtomically(_ snapshot: ChatDiagnosticMergedSnapshot, to url: URL) throws {
        let encoded = try JSONEncoder().encode(snapshot)
        let newline = Data("\n".utf8)
        let target = try rotatedURLIfNeeded(forAdditionalBytes: encoded.count + newline.count, url: url)
        let existing: Data
        if fileManager.fileExists(atPath: target.path) {
            existing = try Data(contentsOf: target)
        } else {
            existing = Data()
        }
        var next = existing
        next.append(encoded)
        next.append(newline)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try next.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            if fileManager.fileExists(atPath: temporary.path) {
                do { try fileManager.removeItem(at: temporary) }
                catch { DebugLog.store("chat diagnostics JSONL rollback cleanup failed: \(error)") }
            }
            throw error
        }
    }

    private func rotatedURLIfNeeded(forAdditionalBytes additional: Int, url: URL) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
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

enum ChatDiagnosticExportError: Error, Equatable {
    case invalidUTF8
    case pasteboardWriteFailed
}
