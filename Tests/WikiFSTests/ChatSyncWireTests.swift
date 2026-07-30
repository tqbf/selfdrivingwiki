#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

struct ChatSyncWireTests {
    @Test func snapshotEnvelopeRoundTripsProjectionAndMetadata() throws {
        let snapshot = makeSnapshot(
            sequence: 4,
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [
                makeMessage(role: .user, text: "hello"),
                makeMessage(role: .assistant, text: "world")
            ],
            committedCursor: ChatTranscriptCursor(rawValue: 8),
            diagnostics: ChatDiagnosticsState(
                stderr: "stderr",
                lastActivityAt: Date(timeIntervalSince1970: 90),
                currentProcessID: 321
            ),
            runMetadata: ChatRunMetadata(
                preflightError: "preflight",
                thinkingOption: ThinkingEffortOption(
                    configId: "thought_level",
                    currentValue: "high",
                    choices: [ThinkingEffortOption.Choice(value: "high", label: "High")]
                ),
                logFileURL: URL(string: "file:///tmp/log")!,
                debugFolderURL: URL(string: "file:///tmp/debug")!,
                runKindRaw: "query",
                runStartedAt: Date(timeIntervalSince1970: 50)
            )
        )

        let data = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        let decoded = try ChatSyncSnapshotEnvelope.decodeData(data)

        #expect(decoded == snapshot)
    }

    @Test func updateEnvelopeRoundTripsProjection() throws {
        let update = makeUpdate(
            sequence: 5,
            reason: .compatibilityRefreshed,
            overlay: [makeMessage(role: .assistant, text: "assistant")]
        )

        let data = try ChatSyncUpdateEnvelope(update: update).encodedData()
        let decoded = try ChatSyncUpdateEnvelope.decodeData(data)

        #expect(decoded == update)
    }

    @Test func transcriptUpdateEnvelopeCompactsAccumulatedOverlayPayload() throws {
        let chunk = String(repeating: "abcdefghij", count: 4)
        let streamedText = Array(repeating: chunk, count: 300).joined()
        let update = makeUpdate(
            sequence: 5,
            reason: .sessionEvent(.transcriptChanged([
                .messageReplacement(
                    messageID: ChatMessageID(rawValue: "assistant-stream"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    role: .assistant,
                    text: streamedText,
                    createdAt: Date(timeIntervalSince1970: 20)
                )
            ])),
            overlay: [
                makeMessage(
                    messageID: "assistant-stream",
                    role: .assistant,
                    text: streamedText
                )
            ]
        )

        let compact = try ChatSyncUpdateEnvelope(update: update).encodedData()
        let full = try JSONEncoder().encode(LegacyLikeUpdateEnvelope(wireVersion: 1, update: update))

        #expect(compact.count < full.count)
    }

    @Test func snapshotEnvelopeRejectsMissingWireVersion() throws {
        let snapshot = makeSnapshot(sequence: 1)
        let encoded = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mutated = object
        mutated.removeValue(forKey: "wireVersion")
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])

        do {
            _ = try ChatSyncSnapshotEnvelope.decodeData(data)
            Issue.record("Expected missing wire version rejection.")
        } catch let error as ChatSyncWireError {
            #expect(error == .missingWireVersion)
        }
    }

    @Test func snapshotEnvelopeRejectsUnsupportedWireVersion() throws {
        let snapshot = makeSnapshot(sequence: 1)
        let encoded = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mutated = object
        mutated["wireVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])

        do {
            _ = try ChatSyncSnapshotEnvelope.decodeData(data)
            Issue.record("Expected unsupported wire version rejection.")
        } catch let error as ChatSyncWireError {
            #expect(error == .unsupportedWireVersion(99))
        }
    }

    @Test func updateEnvelopeRejectsMalformedPayload() {
        let malformed = Data(#"{"wireVersion":1,"update":"nope"}"#.utf8)

        do {
            _ = try ChatSyncUpdateEnvelope.decodeData(malformed)
            Issue.record("Expected malformed update rejection.")
        } catch let error as ChatSyncWireError {
            switch error {
            case .malformedUpdate:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func queueEnvelopeRejectsLegacyChatKind() {
        let envelope = QueueEventEnvelope(
            kind: .chatState,
            chatID: ChatID(rawValue: "chat-1"),
            chatStateData: Data()
        )

        do {
            _ = try envelope.decodedChatSyncUpdate()
            Issue.record("Expected legacy chat kind rejection.")
        } catch let error as ChatSyncWireError {
            #expect(error == .legacyEnvelopeKind("chatState"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func queueEnvelopeRejectsUnsupportedWireVersion() throws {
        let update = makeUpdate(sequence: 2)
        let encoded = try ChatSyncUpdateEnvelope(update: update).encodedData()
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mutated = object
        mutated["wireVersion"] = 7
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
        let envelope = QueueEventEnvelope(
            kind: .chatSyncUpdate,
            chatID: ChatID(rawValue: "chat-1"),
            chatStateData: data
        )

        do {
            _ = try envelope.decodedChatSyncUpdate()
            Issue.record("Expected unsupported wire version rejection.")
        } catch let error as ChatSyncWireError {
            #expect(error == .unsupportedWireVersion(7))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func makeSnapshot(
        sequence: Int64,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero,
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: "generation-1"),
                lifecycle: activeTurn == nil ? .closed : .ready,
                activeTurn: activeTurn,
                queuedTurns: [],
                attention: .none,
                capabilities: .unavailable,
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider-1"),
                    modelID: ModelID(rawValue: "model-1"),
                    providerSessionID: nil
                ),
                usage: nil,
                diagnostics: diagnostics,
                transcriptOverlay: overlay,
                committedCursor: committedCursor,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: nil,
                runMetadata: runMetadata
            )
        )
    }

    private func makeUpdate(
        sequence: Int64,
        reason: ChatSyncUpdateReason = .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1"))),
        overlay: [ChatTranscriptItem] = []
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: reason,
            projection: makeSnapshot(
                sequence: sequence,
                activeTurn: nil,
                overlay: overlay
            ).projection
        )
    }

    private func makeActiveTurn(state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-1"),
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "visible",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeMessage(
        messageID: String? = nil,
        role: ChatTranscriptMessageRole,
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: messageID ?? "\(role.rawValue)-\(text)"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: role,
                text: text,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
    }

    private struct LegacyLikeUpdateEnvelope: Codable {
        let wireVersion: Int
        let update: ChatSyncUpdate
    }
}
#endif
