import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct ChatDiagnosticsTests {
    @Test func traceEvictsOldestRecordsAndRotatesFingerprintKey() async {
        let trace = ChatDiagnosticTrace(source: .app)
        let fingerprint = await trace.fingerprint("same content")
        for index in 0...(ChatDiagnosticPolicy.maximumRecordsPerChat) {
            _ = await trace.record(
                stage: .syncAcceptance,
                outcome: .accepted,
                payload: .init(correlation: .init(chat: .init(rawValue: "chat")), detail: "event-\(index)")
            )
        }
        let before = await trace.snapshot(chat: .init(rawValue: "chat"))
        #expect(before.events.count == ChatDiagnosticPolicy.maximumRecordsPerChat)
        #expect(before.droppedRecordCount == 1)
        await trace.resetAfterSuccessfulExport()
        let after = await trace.snapshot(chat: .init(rawValue: "chat"))
        #expect(after.events.isEmpty)
        #expect(after.process.instanceID != before.process.instanceID)
        let rotatedFingerprint = await trace.fingerprint("same content")
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
}
