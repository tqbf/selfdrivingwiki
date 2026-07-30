import Foundation
import WikiFSCore

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
        diagnostics: ChatDiagnosticsState
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
            return try JSONDecoder().decode(ChatSyncSnapshotEnvelope.self, from: data).snapshot
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
        try JSONEncoder().encode(self)
    }

    public static func decodeData(_ data: Data) throws -> ChatSyncUpdate {
        do {
            try ChatSyncWire.validateVersion(in: data, malformed: ChatSyncWireError.malformedUpdate)
            return try JSONDecoder().decode(ChatSyncUpdateEnvelope.self, from: data).update
        } catch let error as ChatSyncWireError {
            throw error
        } catch {
            throw ChatSyncWireError.malformedUpdate(error.localizedDescription)
        }
    }
}
