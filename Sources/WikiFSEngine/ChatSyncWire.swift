import Foundation
import WikiFSCore

// pattern: Functional Core

/// The only lifecycle state a live content block can carry on the sync wire.
/// A finalized block is represented by the absence of this value.
public enum ChatActiveContentBlockPhase: String, Sendable, Codable, Equatable, Hashable {
    case streaming
}

/// Non-persisted metadata for the transcript content block that is open now.
public struct ChatActiveContentBlock: Sendable, Codable, Equatable, Hashable {
    public let messageID: ChatMessageID
    public let turnID: ChatTurnID
    public let role: ChatTranscriptMessageRole
    public let phase: ChatActiveContentBlockPhase

    public init(
        messageID: ChatMessageID,
        turnID: ChatTurnID,
        role: ChatTranscriptMessageRole,
        phase: ChatActiveContentBlockPhase = .streaming
    ) {
        self.messageID = messageID
        self.turnID = turnID
        self.role = role
        self.phase = phase
    }
}

/// Provenance for a legacy transcript value repaired at a sync-envelope edge.
/// `sourceOrdinal` identifies the source occurrence. It is never a display
/// position or a durable transcript cursor.
public struct LegacyTranscriptOccurrence: Sendable, Codable, Equatable, Hashable {
    public enum ItemKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
        case systemNotice
        case turnFailure
    }

    public let chatID: ChatID
    public let generation: ChatSessionGenerationID
    public let sequence: ChatUpdateSequence
    public let sourceOrdinal: Int
    public let itemKind: ItemKind

    public init(
        chatID: ChatID,
        generation: ChatSessionGenerationID,
        sequence: ChatUpdateSequence,
        sourceOrdinal: Int,
        itemKind: ItemKind
    ) {
        self.chatID = chatID
        self.generation = generation
        self.sequence = sequence
        self.sourceOrdinal = sourceOrdinal
        self.itemKind = itemKind
    }

    public var durableIDRawValue: String {
        "chat-wire-v1:\(itemKind.rawValue):\(chatID.rawValue):\(generation.rawValue):\(sequence.rawValue):\(sourceOrdinal)"
    }
}

public struct ChatRunMetadata: Sendable, Codable, Equatable {
    public let preflightError: String?
    public let thinkingOption: ThinkingEffortOption?
    public let logFileURL: URL?
    public let debugFolderURL: URL?
    public let runKindRaw: String?
    public let runStartedAt: Date?

    public init(
        preflightError: String? = nil,
        thinkingOption: ThinkingEffortOption? = nil,
        logFileURL: URL? = nil,
        debugFolderURL: URL? = nil,
        runKindRaw: String? = nil,
        runStartedAt: Date? = nil
    ) {
        self.preflightError = preflightError
        self.thinkingOption = thinkingOption
        self.logFileURL = logFileURL
        self.debugFolderURL = debugFolderURL
        self.runKindRaw = runKindRaw
        self.runStartedAt = runStartedAt
    }
}

public extension ChatRunMetadata {
    static let empty = ChatRunMetadata()
}

public struct ChatSyncProjection: Sendable, Codable, Equatable {
    public let chatID: ChatID
    public let generation: ChatSessionGenerationID
    public let lifecycle: ChatSessionLifecycle
    public let activeTurn: ChatTurnSnapshot?
    public let queuedTurns: [ChatQueuedTurn]
    public let attention: ChatAttentionState
    public let capabilities: ChatCapabilitySet
    public let providerState: ChatProviderState
    public let usage: SessionUsage?
    public let diagnostics: ChatDiagnosticsState
    public let activeContentBlock: ChatActiveContentBlock?
    public let transcriptOverlay: [ChatTranscriptItem]
    public let committedCursor: ChatTranscriptCursor
    public let lastIncludedSequence: ChatUpdateSequence
    public let pendingPermission: ChatPendingPermissionRequest?
    public let runMetadata: ChatRunMetadata

    public init(
        chatID: ChatID,
        generation: ChatSessionGenerationID,
        lifecycle: ChatSessionLifecycle,
        activeTurn: ChatTurnSnapshot?,
        queuedTurns: [ChatQueuedTurn],
        attention: ChatAttentionState,
        capabilities: ChatCapabilitySet,
        providerState: ChatProviderState,
        usage: SessionUsage?,
        diagnostics: ChatDiagnosticsState,
        activeContentBlock: ChatActiveContentBlock? = nil,
        transcriptOverlay: [ChatTranscriptItem],
        committedCursor: ChatTranscriptCursor,
        lastIncludedSequence: ChatUpdateSequence,
        pendingPermission: ChatPendingPermissionRequest?,
        runMetadata: ChatRunMetadata
    ) {
        self.chatID = chatID
        self.generation = generation
        self.lifecycle = lifecycle
        self.activeTurn = activeTurn
        self.queuedTurns = queuedTurns
        self.attention = attention
        self.capabilities = capabilities
        self.providerState = providerState
        self.usage = usage
        self.diagnostics = diagnostics
        self.activeContentBlock = activeContentBlock
        self.transcriptOverlay = transcriptOverlay
        self.committedCursor = committedCursor
        self.lastIncludedSequence = lastIncludedSequence
        self.pendingPermission = pendingPermission
        self.runMetadata = runMetadata
    }
}

public extension ChatSyncProjection {
    static func from(
        snapshot: ChatRuntimeSnapshot,
        committedCursor: ChatTranscriptCursor,
        pendingPermission: ChatPendingPermissionRequest?,
        runMetadata: ChatRunMetadata,
        usage: SessionUsage?,
        diagnostics: ChatDiagnosticsState,
        activeContentBlock: ChatActiveContentBlock? = nil
    ) -> ChatSyncProjection {
        ChatSyncProjection(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: snapshot.lifecycle,
            activeTurn: snapshot.activeTurn,
            queuedTurns: snapshot.queuedTurns,
            attention: snapshot.attention,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: usage,
            diagnostics: diagnostics,
            activeContentBlock: activeContentBlock,
            transcriptOverlay: snapshot.transientTranscriptOverlay,
            committedCursor: committedCursor,
            lastIncludedSequence: snapshot.lastIncludedSequence,
            pendingPermission: pendingPermission,
            runMetadata: runMetadata
        )
    }

    var isLive: Bool {
        switch lifecycle {
        case .starting, .ready, .recovering, .closing:
            return true
        case .unavailable, .closed, .failed:
            return false
        }
    }

    var isAnswering: Bool {
        guard let activeTurn else { return false }
        switch activeTurn.state {
        case .submitting, .responding, .awaitingPermission, .cancelling:
            return true
        case .queued, .terminal:
            return false
        }
    }
}

public struct ChatSyncSnapshot: Sendable, Codable, Equatable {
    public let projection: ChatSyncProjection

    public init(projection: ChatSyncProjection) {
        self.projection = projection
    }
}

public enum ChatSyncUpdateReason: Sendable, Codable, Equatable {
    case sessionEvent(ChatSessionEventPayload)
    case compatibilityRefreshed
}

public struct ChatSyncUpdate: Sendable, Codable, Equatable {
    public let reason: ChatSyncUpdateReason
    public let projection: ChatSyncProjection

    public init(reason: ChatSyncUpdateReason, projection: ChatSyncProjection) {
        self.reason = reason
        self.projection = projection
    }
}

public enum ChatSyncWireError: Error, Sendable, Equatable {
    case missingWireVersion
    case unsupportedWireVersion(Int)
    case malformedSnapshot(String)
    case malformedUpdate(String)
    case legacyEnvelopeKind(String)
}

extension ChatSyncWireError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingWireVersion:
            return "Missing chat sync wire version."
        case .unsupportedWireVersion(let version):
            return "Unsupported chat sync wire version: \(version)."
        case .malformedSnapshot(let message):
            return "Malformed chat sync snapshot: \(message)"
        case .malformedUpdate(let message):
            return "Malformed chat sync update: \(message)"
        case .legacyEnvelopeKind(let kind):
            return "Unsupported legacy chat envelope kind: \(kind)."
        }
    }
}

private enum ChatSyncWire {
    static let currentWireVersion = 1

    private struct VersionProbe: Decodable {
        let wireVersion: Int?
    }

    static func validateVersion(
        in data: Data,
        malformed: @autoclosure () -> (String) -> ChatSyncWireError
    ) throws {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw malformed()(error.localizedDescription)
        }

        guard let wireVersion = probe.wireVersion else {
            throw ChatSyncWireError.missingWireVersion
        }
        guard wireVersion == currentWireVersion else {
            throw ChatSyncWireError.unsupportedWireVersion(wireVersion)
        }
    }

    /// Repair pre-v47 notice/failure items only while decoding a versioned
    /// envelope. Leaf transcript decoding remains intentionally strict.
    static func repairingLegacyTranscriptIDs(in data: Data) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let envelopeKey = root["snapshot"] == nil ? "update" : "snapshot"
        guard var envelope = root[envelopeKey] as? [String: Any],
              var projection = envelope["projection"] as? [String: Any],
              let chatRaw = projection["chatID"] as? String,
              let generationRaw = projection["generation"] as? String,
              let sequenceNumber = projection["lastIncludedSequence"] as? NSNumber,
              var overlay = projection["transcriptOverlay"] as? [[String: Any]]
        else {
            return data
        }

        let chatID = ChatID(rawValue: chatRaw)
        let generation = ChatSessionGenerationID(rawValue: generationRaw)
        let sequence = ChatUpdateSequence(rawValue: sequenceNumber.int64Value)
        var changed = false
        for sourceOrdinal in overlay.indices {
            for itemKind in LegacyTranscriptOccurrence.ItemKind.allCases {
                guard var associated = overlay[sourceOrdinal][itemKind.rawValue] as? [String: Any],
                      var payload = associated["_0"] as? [String: Any]
                else { continue }
                let identityKey = itemKind == .systemNotice ? "noticeID" : "failureID"
                guard payload[identityKey] == nil else { continue }
                let occurrence = LegacyTranscriptOccurrence(
                    chatID: chatID,
                    generation: generation,
                    sequence: sequence,
                    sourceOrdinal: sourceOrdinal,
                    itemKind: itemKind
                )
                payload[identityKey] = occurrence.durableIDRawValue
                associated["_0"] = payload
                overlay[sourceOrdinal][itemKind.rawValue] = associated
                changed = true
            }
        }
        guard changed else { return data }
        projection["transcriptOverlay"] = overlay
        envelope["projection"] = projection
        root[envelopeKey] = envelope
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

public struct ChatSyncSnapshotEnvelope: Sendable, Codable, Equatable {
    public let wireVersion: Int
    public let snapshot: ChatSyncSnapshot

    public init(
        wireVersion: Int = 1,
        snapshot: ChatSyncSnapshot
    ) {
        self.wireVersion = wireVersion
        self.snapshot = snapshot
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decodeData(_ data: Data) throws -> ChatSyncSnapshot {
        try ChatSyncWire.validateVersion(in: data, malformed: ChatSyncWireError.malformedSnapshot)
        do {
            let repairedData = try ChatSyncWire.repairingLegacyTranscriptIDs(in: data)
            return try JSONDecoder().decode(ChatSyncSnapshotEnvelope.self, from: repairedData).snapshot
        } catch {
            throw ChatSyncWireError.malformedSnapshot(error.localizedDescription)
        }
    }
}

public struct ChatSyncUpdateEnvelope: Sendable, Codable, Equatable {
    public let wireVersion: Int
    public let update: ChatSyncUpdate

    public init(
        wireVersion: Int = 1,
        update: ChatSyncUpdate
    ) {
        self.wireVersion = wireVersion
        self.update = update
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(WireEnvelope(update: update, wireVersion: wireVersion))
    }

    public static func decodeData(_ data: Data) throws -> ChatSyncUpdate {
        do {
            try ChatSyncWire.validateVersion(in: data, malformed: ChatSyncWireError.malformedUpdate)
            let repairedData = try ChatSyncWire.repairingLegacyTranscriptIDs(in: data)
            return try JSONDecoder().decode(WireEnvelope.self, from: repairedData).decodedUpdate
        } catch let error as ChatSyncWireError {
            throw error
        } catch {
            throw ChatSyncWireError.malformedUpdate(error.localizedDescription)
        }
    }

    private enum TranscriptOverlayMode: String, Codable {
        case rebuildFromReasonDeltas
    }

    private struct WireEnvelope: Codable, Equatable {
        let wireVersion: Int
        let update: WireUpdate

        init(update: ChatSyncUpdate, wireVersion: Int) {
            self.wireVersion = wireVersion
            self.update = WireUpdate(update: update)
        }

        var decodedUpdate: ChatSyncUpdate { update.decodedUpdate }
    }

    private struct WireUpdate: Codable, Equatable {
        let reason: ChatSyncUpdateReason
        let projection: ChatSyncProjection
        let transcriptOverlayMode: TranscriptOverlayMode?

        init(update: ChatSyncUpdate) {
            self.reason = update.reason
            if case .sessionEvent(.transcriptChanged(let deltas)) = update.reason,
               deltas.isEmpty == false {
                self.projection = ChatSyncProjection(
                    chatID: update.projection.chatID,
                    generation: update.projection.generation,
                    lifecycle: update.projection.lifecycle,
                    activeTurn: update.projection.activeTurn,
                    queuedTurns: update.projection.queuedTurns,
                    attention: update.projection.attention,
                    capabilities: update.projection.capabilities,
                    providerState: update.projection.providerState,
                    usage: update.projection.usage,
                    diagnostics: update.projection.diagnostics,
                    activeContentBlock: update.projection.activeContentBlock,
                    transcriptOverlay: [],
                    committedCursor: update.projection.committedCursor,
                    lastIncludedSequence: update.projection.lastIncludedSequence,
                    pendingPermission: update.projection.pendingPermission,
                    runMetadata: update.projection.runMetadata
                )
                self.transcriptOverlayMode = .rebuildFromReasonDeltas
            } else {
                self.projection = update.projection
                self.transcriptOverlayMode = nil
            }
        }

        var decodedUpdate: ChatSyncUpdate {
            ChatSyncUpdate(reason: reason, projection: projection)
        }
    }
}
