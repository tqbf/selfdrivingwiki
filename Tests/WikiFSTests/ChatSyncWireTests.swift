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

    @Test func activeContentBlockRoundTripsSnapshotAndCompactUpdate() throws {
        let block = ChatActiveContentBlock(
            messageID: ChatMessageID(rawValue: "assistant-stream"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant
        )
        let snapshot = makeSnapshot(
            sequence: 1,
            overlay: [makeMessage(messageID: "assistant-stream", role: .assistant, text: "Hello")],
            activeContentBlock: block
        )
        #expect(try ChatSyncSnapshotEnvelope.decodeData(
            ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        ) == snapshot)

        let update = makeUpdate(
            sequence: 2,
            reason: .sessionEvent(.transcriptChanged([
                .messageReplacement(
                    messageID: block.messageID,
                    turnID: block.turnID,
                    role: block.role,
                    text: "Hello world",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ])),
            overlay: [makeMessage(messageID: "assistant-stream", role: .assistant, text: "Hello world")],
            activeContentBlock: block
        )
        let decodedUpdate = try ChatSyncUpdateEnvelope.decodeData(
            ChatSyncUpdateEnvelope(update: update).encodedData()
        )
        #expect(decodedUpdate.reason == update.reason)
        #expect(decodedUpdate.projection.activeContentBlock == block)
        #expect(decodedUpdate.projection.transcriptOverlay.isEmpty)
    }

    @Test func oldProjectionPayloadDecodesWithoutActiveContentBlock() throws {
        let snapshot = makeSnapshot(sequence: 1)
        let encoded = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var snapshotObject = try #require(object["snapshot"] as? [String: Any])
        var projection = try #require(snapshotObject["projection"] as? [String: Any])
        projection.removeValue(forKey: "activeContentBlock")
        snapshotObject["projection"] = projection
        object["snapshot"] = snapshotObject
        let oldPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(try ChatSyncSnapshotEnvelope.decodeData(oldPayload).projection.activeContentBlock == nil)
    }

    @Test func legacyProjectionDecodeIsRepeatable() throws {
        let notice = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "new-notice"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let snapshot = makeSnapshot(sequence: 9, overlay: [notice])
        let encoded = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var envelope = try #require(root["snapshot"] as? [String: Any])
        var projection = try #require(envelope["projection"] as? [String: Any])
        var overlay = try #require(projection["transcriptOverlay"] as? [[String: Any]])
        var associated = try #require(overlay[0]["systemNotice"] as? [String: Any])
        var payload = try #require(associated["_0"] as? [String: Any])
        payload.removeValue(forKey: "noticeID")
        associated["_0"] = payload
        overlay[0]["systemNotice"] = associated
        projection["transcriptOverlay"] = overlay
        envelope["projection"] = projection
        root["snapshot"] = envelope
        let legacyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        let first = try ChatSyncSnapshotEnvelope.decodeData(legacyData)
        let second = try ChatSyncSnapshotEnvelope.decodeData(legacyData)
        #expect(first == second)
        guard case .systemNotice(let repaired) = first.projection.transcriptOverlay[0] else {
            Issue.record("Expected a repaired system notice.")
            return
        }
        #expect(repaired.noticeID.rawValue == "chat-wire-v1:systemNotice:chat-1:generation-1:9:0")
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
        runMetadata: ChatRunMetadata = .empty,
        activeContentBlock: ChatActiveContentBlock? = nil
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
                activeContentBlock: activeContentBlock,
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
        overlay: [ChatTranscriptItem] = [],
        activeContentBlock: ChatActiveContentBlock? = nil
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: reason,
            projection: makeSnapshot(
                sequence: sequence,
                activeTurn: nil,
                overlay: overlay,
                activeContentBlock: activeContentBlock
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
