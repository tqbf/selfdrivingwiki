import Foundation
import WikiFSCore

/// Daemon-only, per-chat redacted ring. The actor serializes observations from
/// controller lifecycles and the XPC boundary, preserving their causal order.
actor DaemonChatDiagnostics {
    private struct StoredRecord: Sendable {
        let event: ChatDiagnosticEventEnvelope
        let byteCount: Int
    }

    private enum Bucket: Hashable {
        case chat(ChatDiagnosticCorrelation.Value)
        case process
    }

    private var identity = ChatDiagnosticProcessIdentity(source: .daemon)
    private var fingerprintKey = ChatDiagnosticFingerprintKey()
    private var sequence: UInt64 = 0
    private var recordsByBucket: [Bucket: [StoredRecord]] = [:]
    private var droppedRecordsByBucket: [Bucket: Int] = [:]
    private var droppedBytesByBucket: [Bucket: Int] = [:]

    func record(
        stage: ChatDiagnosticStage,
        outcome: ChatDiagnosticOutcome,
        correlation: ChatDiagnosticCorrelation = .init(),
        detail: String? = nil,
        content: String? = nil
    ) {
        sequence &+= 1
        let populated = correlationWithFingerprint(correlation, content: content)
        let bucket = populated.chat.map(Bucket.chat) ?? .process
        let didCoalesce = shouldCoalesce(stage: stage, correlation: populated)
            && recordsByBucket[bucket]?.last.map { coalescingKey(for: $0.event) == coalescingKey(stage: stage, correlation: populated) } == true
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: .init(sequence),
            stage: stage,
            payload: .init(correlation: populated, detail: detail),
            outcome: didCoalesce ? .coalesced : outcome
        )
        append(event, bucket: bucket)
        emit(event)
    }

    func snapshot(chat: ChatDiagnosticCorrelation.Value?) -> ChatDiagnosticSnapshotEnvelope {
        let bucket = chat.map(Bucket.chat)
        let records = bucket.map { recordsByBucket[$0] ?? [] } ?? recordsByBucket.values.flatMap { $0 }
        let droppedRecords = bucket.map { droppedRecordsByBucket[$0] ?? 0 } ?? droppedRecordsByBucket.values.reduce(0, +)
        let droppedBytes = bucket.map { droppedBytesByBucket[$0] ?? 0 } ?? droppedBytesByBucket.values.reduce(0, +)
        return ChatDiagnosticSnapshotEnvelope(
            process: identity,
            events: records.map(\.event),
            droppedRecordCount: droppedRecords,
            droppedByteCount: droppedBytes,
            summary: ["retention": "daemon-redacted-ring"]
        )
    }

    func resetAfterSuccessfulExport() {
        identity = ChatDiagnosticProcessIdentity(source: .daemon)
        fingerprintKey = ChatDiagnosticFingerprintKey()
        sequence = 0
        recordsByBucket.removeAll()
        droppedRecordsByBucket.removeAll()
        droppedBytesByBucket.removeAll()
    }

    func versionFailureSnapshot() -> ChatDiagnosticSnapshotEnvelope {
        sequence &+= 1
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: .init(sequence),
            stage: .syncAcceptance,
            payload: .init(detail: "diagnostic-request-version"),
            outcome: .versionFailure
        )
        return ChatDiagnosticSnapshotEnvelope(process: identity, events: [event])
    }

    private func correlationWithFingerprint(_ correlation: ChatDiagnosticCorrelation, content: String?) -> ChatDiagnosticCorrelation {
        ChatDiagnosticCorrelation(
            chat: correlation.chat,
            generation: correlation.generation,
            updateSequence: correlation.updateSequence,
            turn: correlation.turn,
            durableItem: correlation.durableItem,
            displayRow: correlation.displayRow,
            tool: correlation.tool,
            cursor: correlation.cursor,
            rendererRevision: correlation.rendererRevision,
            eventKind: correlation.eventKind,
            content: content.map { fingerprintKey.fingerprint(for: $0) } ?? correlation.content
        )
    }

    private func append(_ event: ChatDiagnosticEventEnvelope, bucket: Bucket) {
        let encoded: Data
        do { encoded = try JSONEncoder().encode(event) }
        catch {
            DebugLog.store("daemon chat diagnostic event encoding failed: \(error)")
            return
        }
        var records = recordsByBucket[bucket, default: []]
        if shouldCoalesce(event), let last = records.last, coalescingKey(for: last.event) == coalescingKey(for: event) {
            records.removeLast()
        }
        records.append(.init(event: event, byteCount: encoded.count))
        var bytes = records.reduce(0) { $0 + $1.byteCount }
        while records.count > ChatDiagnosticPolicyDaemon.maximumRecordsPerChat || bytes > ChatDiagnosticPolicyDaemon.maximumBytesPerChat {
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
        case .providerReceipt, .providerTranslation, .reduction:
            return correlation.updateSequence != nil || correlation.durableItem != nil
        default:
            return false
        }
    }

    private func coalescingKey(for event: ChatDiagnosticEventEnvelope) -> String? {
        coalescingKey(stage: event.stage, correlation: event.payload.correlation)
    }

    private func coalescingKey(stage: ChatDiagnosticStage, correlation: ChatDiagnosticCorrelation) -> String? {
        guard shouldCoalesce(stage: stage, correlation: correlation) else { return nil }
        let subject = correlation.durableItem?.rawValue ?? correlation.turn?.rawValue
        // An item or turn identifies the high-frequency provider stream; keep
        // only its newest update. Without that identity, retain the revision
        // boundary so unrelated daemon observations cannot collapse together.
        let revision = subject == nil ? correlation.updateSequence.map { String($0.rawValue) } ?? "" : "item"
        return [stage.rawValue, correlation.chat?.rawValue ?? "", subject ?? "", revision].joined(separator: "|")
    }

    private func emit(_ event: ChatDiagnosticEventEnvelope) {
        DebugLog.chatDiagnostics(
            "daemon chat diagnostic stage=\(event.stage.rawValue) outcome=\(event.outcome.rawValue) sequence=\(event.sequence.rawValue)",
            verbose: event.outcome != .failed
        )
    }
}

private enum ChatDiagnosticPolicyDaemon {
    static let maximumRecordsPerChat = 256
    static let maximumBytesPerChat = 256 * 1_024
}
