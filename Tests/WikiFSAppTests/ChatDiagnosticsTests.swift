import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

@MainActor
struct ChatDiagnosticsTests {
    @Test func traceEvictsOldestRecordsAndRotatesFingerprintKey() async {
        let trace = ChatDiagnosticTrace(source: .app)
        let fingerprint = trace.fingerprint("same content")
        for index in 0...(ChatDiagnosticPolicy.maximumRecordsPerChat) {
            _ = trace.record(
                stage: .syncAcceptance,
                outcome: .accepted,
                payload: .init(correlation: .init(chat: .init(rawValue: "chat")), detail: "event-\(index)")
            )
        }
        let before = trace.snapshot(chat: .init(rawValue: "chat"))
        #expect(before.events.count == ChatDiagnosticPolicy.maximumRecordsPerChat)
        #expect(before.droppedRecordCount == 1)
        trace.resetAfterSuccessfulExport()
        let after = trace.snapshot(chat: .init(rawValue: "chat"))
        #expect(after.events.isEmpty)
        #expect(after.process.instanceID != before.process.instanceID)
        let rotatedFingerprint = trace.fingerprint("same content")
        #expect(rotatedFingerprint != fingerprint)
    }

    @Test func mergeUsesSequenceWithinSourceAndTimestampAcrossSources() {
        let app = ChatDiagnosticSnapshotEnvelope(
            process: .init(source: .app, instanceID: UUID()),
            events: [
                .init(process: .init(source: .app, instanceID: UUID()), sequence: .init(2), timestamp: Date(timeIntervalSince1970: 2), stage: .displayProjection, outcome: .accepted),
                .init(process: .init(source: .app, instanceID: UUID()), sequence: .init(1), timestamp: Date(timeIntervalSince1970: 1), stage: .syncAcceptance, outcome: .accepted),
            ]
        )
        let daemon = ChatDiagnosticSnapshotEnvelope(
            process: .init(source: .daemon, instanceID: UUID()),
            events: [.init(process: .init(source: .daemon, instanceID: UUID()), sequence: .init(1), timestamp: Date(timeIntervalSince1970: 1.5), stage: .providerReceipt, outcome: .accepted)]
        )
        let merged = ChatDiagnosticSnapshotMerge.merge(app: app, daemon: daemon)
        #expect(merged.events.filter { $0.process.source == .app }.map(\.sequence.rawValue) == [1, 2])
        #expect(merged.mergeOrder.contains("per-process-sequence"))
    }

    @Test func selectedChatWithoutDropsDoesNotReportAnotherChatsEvictions() async {
        let trace = ChatDiagnosticTrace(source: .app)
        let evictedChat = ChatDiagnosticCorrelation.Value(rawValue: "evicted-chat")
        let retainedChat = ChatDiagnosticCorrelation.Value(rawValue: "retained-chat")

        for index in 0...ChatDiagnosticPolicy.maximumRecordsPerChat {
            _ = trace.record(
                stage: .syncAcceptance,
                outcome: .accepted,
                payload: .init(correlation: .init(chat: evictedChat), detail: "event-\(index)")
            )
        }
        _ = trace.record(
            stage: .displayProjection,
            outcome: .accepted,
            payload: .init(correlation: .init(chat: retainedChat), detail: "retained")
        )

        let snapshot = trace.snapshot(chat: retainedChat)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.droppedRecordCount == 0)
        #expect(snapshot.droppedByteCount == 0)
    }

    @Test func traceCoalescesRepeatedRevisionWithoutChangingChatScope() {
        let trace = ChatDiagnosticTrace(source: .app)
        let chat = ChatDiagnosticCorrelation.Value(rawValue: "coalesced-chat")
        for revision in 4...6 {
            _ = trace.record(
                stage: .renderPlanning,
                outcome: .accepted,
                payload: .init(correlation: .init(
                    chat: chat,
                    displayRow: .init(rawValue: "row-1"),
                    rendererRevision: .init(UInt64(revision))
                ), detail: "renderer")
            )
        }
        let snapshot = trace.snapshot(chat: chat)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.events[0].outcome == .coalesced)
        #expect(snapshot.events[0].payload.correlation.rendererRevision == .init(6))
    }

    @Test func jsonlWriterRotatesBoundedRedactedRecords() async throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("tmp/chat-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                DebugLog.store("chat diagnostics test cleanup failed: \(error)")
            }
        }

        let url = directory.appendingPathComponent("chat-diagnostics.jsonl")
        let writer = ChatDiagnosticJSONLWriter()
        let identity = ChatDiagnosticProcessIdentity(source: .app)
        let detail = String(repeating: "x", count: 7_000)
        for sequence in 1...75 {
            _ = try await writer.append(
                .init(
                    process: identity,
                    sequence: .init(UInt64(sequence)),
                    stage: .displayProjection,
                    payload: .init(detail: detail),
                    outcome: .accepted
                ),
                to: url
            )
        }

        let rotated = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
        #expect(fileManager.fileExists(atPath: url.path))
        #expect(fileManager.fileExists(atPath: rotated.path))
        #expect(try Data(contentsOf: url).isEmpty == false)
        #expect(try Data(contentsOf: rotated).isEmpty == false)
    }
}
