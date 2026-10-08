#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

struct ChatCancellationDomainTests {
    @Test func attentionFailuresPermitRetryAndPreserveTurnIdentity() {
        let turnID = ChatTurnID(rawValue: "turn-cancel")
        #expect(ChatAttentionState.cancellationPersistenceFailed(turnID, message: "persist").permitsRetry)
        #expect(ChatAttentionState.runtimeCleanupFailed(turnID, message: "cleanup").permitsRetry)
        #expect(ChatAttentionState.cancellationPersistenceFailed(turnID, message: "persist").turnID == turnID)
        #expect(ChatAttentionState.runtimeCleanupFailed(turnID, message: "cleanup").turnID == turnID)
    }

    @Test func cancellationRequestIsIdempotentWhileCancelling() {
        let turn = ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-cancel"),
            commandID: ChatCommandID(rawValue: "command-cancel"),
            visibleText: "cancel",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 1),
            state: .cancelling
        )
        let snapshot = ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "chat-cancel"),
            generation: ChatSessionGenerationID(rawValue: "generation-cancel"),
            lifecycle: .ready,
            activeTurn: turn,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: .init(rawValue: 1)
        )
        let update = ChatSessionUpdate(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            sequence: .init(rawValue: 2),
            payload: .cancellationRequested(turnID: turn.turnID)
        )
        guard case .applied(let result) = ChatSessionMachine.apply(update, to: snapshot) else {
            Issue.record("Repeated cancellation request should be accepted")
            return
        }
        #expect(result.activeTurn == turn)
        #expect(result.lastIncludedSequence == update.sequence)
    }
}
#endif
