import Foundation
import WikiFSCore

/// Daemon-only trace ownership. The daemon never imports app display types;
/// it receives only diagnostic correlation values through the shared DTO.
actor DaemonChatDiagnostics {
    private let identity = ChatDiagnosticProcessIdentity(source: .daemon)
    private var sequence: UInt64 = 0
    private var events: [ChatDiagnosticEventEnvelope] = []

    func record(
        stage: ChatDiagnosticStage,
        outcome: ChatDiagnosticOutcome,
        payload: ChatDiagnosticPayload = .init()
    ) {
        sequence &+= 1
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: ChatDiagnosticSequence(sequence),
            stage: stage,
            payload: payload,
            outcome: outcome
        )
        events.append(event)
        while events.count > ChatDiagnosticPolicyDaemon.maximumRecords { events.removeFirst() }
        switch outcome {
        case .failed, .timeout, .decodeFailure, .versionFailure:
            DebugLog.chatDiagnostics("chat diagnostic stage=\(stage.rawValue) outcome=\(outcome.rawValue)", verbose: false)
        default:
            DebugLog.chatDiagnostics("chat diagnostic stage=\(stage.rawValue) outcome=\(outcome.rawValue)", verbose: true)
        }
    }

    func snapshot(chat: ChatDiagnosticCorrelation.Value?) -> ChatDiagnosticSnapshotEnvelope {
        let filtered = events.filter { event in
            guard let chat else { return true }
            return event.payload.correlation.chat == chat
        }
        return ChatDiagnosticSnapshotEnvelope(
            process: identity,
            events: filtered,
            summary: ["retention": "daemon-run-log-jsonl"]
        )
    }

    func versionFailureSnapshot() -> ChatDiagnosticSnapshotEnvelope {
        sequence &+= 1
        let event = ChatDiagnosticEventEnvelope(
            process: identity,
            sequence: ChatDiagnosticSequence(sequence),
            stage: .syncAcceptance,
            payload: .init(detail: "diagnostic-request-version"),
            outcome: .versionFailure
        )
        return ChatDiagnosticSnapshotEnvelope(process: identity, events: [event])
    }
}

private enum ChatDiagnosticPolicyDaemon {
    static let maximumRecords = 256
}
