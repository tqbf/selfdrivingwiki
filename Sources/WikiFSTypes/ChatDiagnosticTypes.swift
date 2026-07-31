import Foundation

/// Foundation-only, versioned diagnostic data shared by the app and `wikid`.
///
/// These values deliberately use diagnostic-specific identifiers rather than
/// importing presentation or runtime types. They are transport and log values,
/// never persistence identity or user-visible copy.
public enum ChatDiagnosticTypes {
    public static let currentVersion = 1
}

public enum ChatDiagnosticSource: String, Codable, Sendable, CaseIterable {
    case app
    case daemon
}

public struct ChatDiagnosticProcessIdentity: Codable, Hashable, Sendable {
    public let source: ChatDiagnosticSource
    public let instanceID: UUID

    public init(source: ChatDiagnosticSource, instanceID: UUID = UUID()) {
        self.source = source
        self.instanceID = instanceID
    }
}

public struct ChatDiagnosticSequence: Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Opaque, namespaced correlation values. Raw values are stable identifiers or
/// numeric values already present at a boundary; they must never contain text.
public struct ChatDiagnosticCorrelation: Codable, Hashable, Sendable {
    public struct Value: Codable, Hashable, Sendable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public let chat: Value?
    public let generation: Value?
    public let updateSequence: ChatDiagnosticSequence?
    public let turn: Value?
    public let durableItem: Value?
    public let displayRow: Value?
    public let tool: Value?
    public let cursor: Value?
    public let rendererRevision: ChatDiagnosticSequence?
    public let eventKind: Value?
    public let content: ChatDiagnosticContentFingerprint?

    public init(
        chat: Value? = nil,
        generation: Value? = nil,
        updateSequence: ChatDiagnosticSequence? = nil,
        turn: Value? = nil,
        durableItem: Value? = nil,
        displayRow: Value? = nil,
        tool: Value? = nil,
        cursor: Value? = nil,
        rendererRevision: ChatDiagnosticSequence? = nil,
        eventKind: Value? = nil,
        content: ChatDiagnosticContentFingerprint? = nil
    ) {
        self.chat = chat
        self.generation = generation
        self.updateSequence = updateSequence
        self.turn = turn
        self.durableItem = durableItem
        self.displayRow = displayRow
        self.tool = tool
        self.cursor = cursor
        self.rendererRevision = rendererRevision
        self.eventKind = eventKind
        self.content = content
    }
}

public struct ChatDiagnosticContentFingerprint: Codable, Hashable, Sendable {
    public static let currentAlgorithm = "keyed-fnv1a64-v1"

    public let algorithm: String
    public let digest: String
    public let length: Int

    public init(algorithm: String = Self.currentAlgorithm, digest: String, length: Int) {
        self.algorithm = algorithm
        self.digest = digest
        self.length = length
    }
}

/// A local random key used only to produce non-reusable content fingerprints.
/// It is intentionally not Codable, so it can never be exported with a trace.
public struct ChatDiagnosticFingerprintKey: Hashable, Sendable {
    private let bytes: [UInt8]

    public init() {
        let parts = [UUID().uuid, UUID().uuid]
        self.bytes = parts.flatMap { tuple in
            withUnsafeBytes(of: tuple) { Array($0) }
        }
    }

    public func fingerprint(for text: String) -> ChatDiagnosticContentFingerprint {
        // FNV-1a is a compact keyed *fingerprint*, not a password hash or a
        // secrecy primitive. The random local key prevents correlating text
        // across a trace or deriving a reusable plaintext token from exports.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes + Array(text.utf8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return ChatDiagnosticContentFingerprint(
            digest: String(hash, radix: 16, uppercase: false),
            length: text.utf8.count
        )
    }
}

public enum ChatDiagnosticRedaction: String, Codable, Sendable {
    case identifiersAndKeyedFingerprintOnly
}

public enum ChatDiagnosticStage: String, Codable, Sendable, CaseIterable {
    case providerReceipt
    case providerTranslation
    case reduction
    case persistence
    case syncAcceptance
    case syncReconciliation
    case displayProjection
    case renderPlanning
    case domAcknowledgement
    case domFailure
    case recoveryReload
}

public enum ChatDiagnosticOutcome: String, Codable, Sendable {
    case accepted
    case coalesced
    case ignored
    case recovered
    case failed
    case timeout
    case decodeFailure
    case versionFailure
}

/// A compact typed payload: the stage gives meaning to correlation values;
/// details contain only fixed diagnostic labels, never user content.
public struct ChatDiagnosticPayload: Codable, Hashable, Sendable {
    public let correlation: ChatDiagnosticCorrelation
    public let detail: String?

    public init(correlation: ChatDiagnosticCorrelation = .init(), detail: String? = nil) {
        self.correlation = correlation
        self.detail = detail
    }
}

public struct ChatDiagnosticEventEnvelope: Codable, Hashable, Sendable {
    public let version: Int
    public let process: ChatDiagnosticProcessIdentity
    public let sequence: ChatDiagnosticSequence
    public let timestamp: Date
    public let redaction: ChatDiagnosticRedaction
    public let stage: ChatDiagnosticStage
    public let payload: ChatDiagnosticPayload
    public let outcome: ChatDiagnosticOutcome

    public init(
        version: Int = ChatDiagnosticTypes.currentVersion,
        process: ChatDiagnosticProcessIdentity,
        sequence: ChatDiagnosticSequence,
        timestamp: Date = Date(),
        redaction: ChatDiagnosticRedaction = .identifiersAndKeyedFingerprintOnly,
        stage: ChatDiagnosticStage,
        payload: ChatDiagnosticPayload = .init(),
        outcome: ChatDiagnosticOutcome
    ) {
        self.version = version
        self.process = process
        self.sequence = sequence
        self.timestamp = timestamp
        self.redaction = redaction
        self.stage = stage
        self.payload = payload
        self.outcome = outcome
    }

    public func validatingVersion() throws {
        guard version == ChatDiagnosticTypes.currentVersion else {
            throw ChatDiagnosticVersionError.unsupported(version)
        }
    }
}

public struct ChatDiagnosticSnapshotEnvelope: Codable, Hashable, Sendable {
    public let version: Int
    public let process: ChatDiagnosticProcessIdentity
    public let generatedAt: Date
    public let events: [ChatDiagnosticEventEnvelope]
    public let droppedRecordCount: Int
    public let droppedByteCount: Int
    public let summary: [String: String]

    public init(
        version: Int = ChatDiagnosticTypes.currentVersion,
        process: ChatDiagnosticProcessIdentity,
        generatedAt: Date = Date(),
        events: [ChatDiagnosticEventEnvelope],
        droppedRecordCount: Int = 0,
        droppedByteCount: Int = 0,
        summary: [String: String] = [:]
    ) {
        self.version = version
        self.process = process
        self.generatedAt = generatedAt
        self.events = events
        self.droppedRecordCount = droppedRecordCount
        self.droppedByteCount = droppedByteCount
        self.summary = summary
    }

    public func validatingVersion() throws {
        guard version == ChatDiagnosticTypes.currentVersion else {
            throw ChatDiagnosticVersionError.unsupported(version)
        }
        try events.forEach { try $0.validatingVersion() }
    }
}

public enum ChatDiagnosticVersionError: Error, Equatable, Sendable {
    case unsupported(Int)
}

/// The explicit XPC request boundary. `chat` is optional so a daemon can
/// provide process-wide diagnostics when no individual session is selected.
public struct ChatDiagnosticSnapshotRequest: Codable, Hashable, Sendable {
    public let version: Int
    public let chat: ChatDiagnosticCorrelation.Value?

    public init(version: Int = ChatDiagnosticTypes.currentVersion, chat: ChatDiagnosticCorrelation.Value? = nil) {
        self.version = version
        self.chat = chat
    }

    public func validatingVersion() throws {
        guard version == ChatDiagnosticTypes.currentVersion else {
            throw ChatDiagnosticVersionError.unsupported(version)
        }
    }
}
