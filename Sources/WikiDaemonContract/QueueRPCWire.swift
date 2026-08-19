#if os(macOS)
import Foundation

public struct QueueOwnershipEpoch: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public func next() -> QueueOwnershipEpoch {
        QueueOwnershipEpoch(rawValue: rawValue + 1)
    }
}

public enum QueueDaemonHostState: String, Codable, Sendable {
    case serving
    case relinquishing
    case relinquished
    case shutdownBlocked
}

public struct QueueOwnershipTransitionError: Error, Equatable, Codable, Sendable {
    public let epoch: QueueOwnershipEpoch
    public let hostState: QueueDaemonHostState
    public let activeItemIDs: [String]

    public init(
        epoch: QueueOwnershipEpoch,
        hostState: QueueDaemonHostState,
        activeItemIDs: [String] = []
    ) {
        self.epoch = epoch
        self.hostState = hostState
        self.activeItemIDs = activeItemIDs
    }
}

public enum QueueRPCErrorCode: String, Codable, Sendable {
    case ownershipTransition
    case invalidRequest
    case unavailable
    case operationFailed
    case unsupportedVersion
    case invalidEnvelope
}

public struct QueueRPCError: Error, Equatable, Codable, Sendable {
    public let code: QueueRPCErrorCode
    public let message: String
    public let ownership: QueueOwnershipTransitionError?

    public init(
        code: QueueRPCErrorCode,
        message: String,
        ownership: QueueOwnershipTransitionError? = nil
    ) {
        self.code = code
        self.message = message
        self.ownership = ownership
    }
}

public struct QueueRPCEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public static var currentVersion: UInt16 { 1 }

    public let version: UInt16
    public let ownershipEpoch: QueueOwnershipEpoch
    public let hostState: QueueDaemonHostState
    public let payload: Payload?
    public let error: QueueRPCError?

    public init(
        version: UInt16 = Self.currentVersion,
        ownershipEpoch: QueueOwnershipEpoch,
        hostState: QueueDaemonHostState,
        payload: Payload? = nil,
        error: QueueRPCError? = nil
    ) {
        self.version = version
        self.ownershipEpoch = ownershipEpoch
        self.hostState = hostState
        self.payload = payload
        self.error = error
    }

    public static func success(
        _ payload: Payload,
        epoch: QueueOwnershipEpoch,
        hostState: QueueDaemonHostState
    ) -> Self {
        Self(
            ownershipEpoch: epoch,
            hostState: hostState,
            payload: payload)
    }

    public static func failure(
        _ error: QueueRPCError,
        epoch: QueueOwnershipEpoch,
        hostState: QueueDaemonHostState
    ) -> Self {
        Self(
            ownershipEpoch: epoch,
            hostState: hostState,
            error: error)
    }

    public func requirePayload() throws -> Payload {
        guard version == Self.currentVersion else {
            throw QueueRPCError(
                code: .unsupportedVersion,
                message: "Unsupported queue RPC version: \(version)")
        }
        if let error { throw error }
        guard let payload else {
            throw QueueRPCError(
                code: .invalidEnvelope,
                message: "Queue RPC envelope has no payload")
        }
        return payload
    }
}

public enum QueueRPCWire {
    public static func encode<Payload: Codable & Sendable>(
        _ envelope: QueueRPCEnvelope<Payload>
    ) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode<Payload: Codable & Sendable>(
        _ payloadType: Payload.Type,
        from data: Data
    ) throws -> QueueRPCEnvelope<Payload> {
        let envelope: QueueRPCEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(QueueRPCEnvelope<Payload>.self, from: data)
        } catch {
            throw QueueRPCError(
                code: .invalidEnvelope,
                message: "Queue RPC envelope could not be decoded")
        }
        guard envelope.version == QueueRPCEnvelope<Payload>.currentVersion else {
            throw QueueRPCError(
                code: .unsupportedVersion,
                message: "Unsupported queue RPC version: \(envelope.version)")
        }
        return envelope
    }
}

public struct QueueVoidPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct QueueItemIDPayload: Codable, Equatable, Sendable {
    public let itemID: String

    public init(itemID: String) {
        self.itemID = itemID
    }
}

public struct QueueCountPayload: Codable, Equatable, Sendable {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }
}

public struct QueueBoolPayload: Codable, Equatable, Sendable {
    public let value: Bool

    public init(value: Bool) {
        self.value = value
    }
}

public struct QueueDataPayload: Codable, Equatable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct QueueCompletionPayload: Codable, Equatable, Sendable {
    public let completed: Bool
    public let errorMessage: String?

    public init(completed: Bool, errorMessage: String? = nil) {
        self.completed = completed
        self.errorMessage = errorMessage
    }
}

public struct QueueOwnershipStatusPayload: Codable, Equatable, Sendable {
    public let epoch: QueueOwnershipEpoch
    public let hostState: QueueDaemonHostState

    public init(epoch: QueueOwnershipEpoch, hostState: QueueDaemonHostState) {
        self.epoch = epoch
        self.hostState = hostState
    }
}

public struct QueueRelinquishmentRequest: Codable, Equatable, Sendable {
    public let expectedEpoch: QueueOwnershipEpoch

    public init(expectedEpoch: QueueOwnershipEpoch) {
        self.expectedEpoch = expectedEpoch
    }
}

public struct QueueRelinquishmentSuccess: Codable, Equatable, Sendable {
    public let completedEpoch: QueueOwnershipEpoch
    public let dispatchStopped: Bool
    public let workersSettledOrRequeued: Bool
    public let forwardingStopped: Bool
    public let storeClosed: Bool

    public init(
        completedEpoch: QueueOwnershipEpoch,
        dispatchStopped: Bool,
        workersSettledOrRequeued: Bool,
        forwardingStopped: Bool,
        storeClosed: Bool
    ) {
        self.completedEpoch = completedEpoch
        self.dispatchStopped = dispatchStopped
        self.workersSettledOrRequeued = workersSettledOrRequeued
        self.forwardingStopped = forwardingStopped
        self.storeClosed = storeClosed
    }

    public var isComplete: Bool {
        dispatchStopped && workersSettledOrRequeued && forwardingStopped && storeClosed
    }
}
#endif
