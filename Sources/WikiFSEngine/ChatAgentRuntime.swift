import Foundation
import WikiFSCore

public struct ChatRuntimeHandle: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ChatRuntimeStartRequest: Hashable, Sendable, Codable {
    public let chatID: ChatID
    public let generation: ChatSessionGenerationID
    public let systemPrompt: String
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let existingProviderSessionID: AcpSessionID?

    public init(
        chatID: ChatID,
        generation: ChatSessionGenerationID,
        systemPrompt: String,
        providerID: ProviderID?,
        modelID: ModelID?,
        existingProviderSessionID: AcpSessionID?
    ) {
        self.chatID = chatID
        self.generation = generation
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.modelID = modelID
        self.existingProviderSessionID = existingProviderSessionID
    }
}

public struct ChatRuntimeConfigurationChange: Hashable, Sendable, Codable {
    public let optionID: ChatConfigurationOptionID
    public let valueID: ChatConfigurationValueID

    public init(optionID: ChatConfigurationOptionID, valueID: ChatConfigurationValueID) {
        self.optionID = optionID
        self.valueID = valueID
    }
}

public enum ChatAgentRuntimeEvent: Hashable, Sendable, Codable {
    case sessionReady(capabilities: ChatCapabilitySet, providerState: ChatProviderState)
    case transcript([ChatTranscriptDelta])
    case permissionRequested(ChatPendingPermissionRequest)
    case permissionResolved(ChatPermissionResolution)
    case turnCompleted(ChatTurnID)
    case turnFailed(turnID: ChatTurnID, category: ChatTurnFailureCategory, message: String)
    case turnCancelled(ChatTurnID)
    case transportClosed(status: Int32?)
    case resumed(providerSessionID: AcpSessionID?)
}

public struct ChatAgentRuntimeEventEnvelope: Hashable, Sendable, Codable {
    public let generation: ChatSessionGenerationID
    public let event: ChatAgentRuntimeEvent
    /// Live-only block state carried atomically with a transcript transition.
    public let activeContentBlock: ChatActiveContentBlock?

    public init(
        generation: ChatSessionGenerationID,
        event: ChatAgentRuntimeEvent,
        activeContentBlock: ChatActiveContentBlock? = nil
    ) {
        self.generation = generation
        self.event = event
        self.activeContentBlock = activeContentBlock
    }
}

public protocol ChatAgentRuntime: Sendable {
    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle
    func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope>
    func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws
    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws
    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws
    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws
    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot
    func close(_ handle: ChatRuntimeHandle) async
}

public struct ClosureBackedChatAgentRuntime: ChatAgentRuntime {
    public typealias StartOperation = @Sendable (ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle
    public typealias EventStreamOperation = @Sendable (ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope>
    public typealias SubmitOperation = @Sendable (ChatTurnSubmission, ChatRuntimeHandle) async throws -> Void
    public typealias CancelOperation = @Sendable (ChatTurnID?, ChatRuntimeHandle) async throws -> Void
    public typealias PermissionOperation = @Sendable (ChatPermissionResolution, ChatRuntimeHandle) async throws -> Void
    public typealias ConfigurationOperation = @Sendable (ChatRuntimeConfigurationChange, ChatRuntimeHandle) async throws -> Void
    public typealias SnapshotOperation = @Sendable (ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot
    public typealias CloseOperation = @Sendable (ChatRuntimeHandle) async -> Void

    private let startOperation: StartOperation
    private let eventStreamOperation: EventStreamOperation
    private let submitOperation: SubmitOperation
    private let cancelOperation: CancelOperation
    private let permissionOperation: PermissionOperation
    private let configurationOperation: ConfigurationOperation
    private let snapshotOperation: SnapshotOperation
    private let closeOperation: CloseOperation

    public init(
        start: @escaping StartOperation,
        eventStream: @escaping EventStreamOperation,
        submitTurn: @escaping SubmitOperation,
        cancelTurn: @escaping CancelOperation,
        resolvePermission: @escaping PermissionOperation,
        setConfiguration: @escaping ConfigurationOperation,
        snapshot: @escaping SnapshotOperation,
        close: @escaping CloseOperation
    ) {
        self.startOperation = start
        self.eventStreamOperation = eventStream
        self.submitOperation = submitTurn
        self.cancelOperation = cancelTurn
        self.permissionOperation = resolvePermission
        self.configurationOperation = setConfiguration
        self.snapshotOperation = snapshot
        self.closeOperation = close
    }

    public func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        try await startOperation(request)
    }

    public func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        try await eventStreamOperation(handle)
    }

    public func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
        try await submitOperation(submission, handle)
    }

    public func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {
        try await cancelOperation(turnID, handle)
    }

    public func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {
        try await permissionOperation(resolution, handle)
    }

    public func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {
        try await configurationOperation(change, handle)
    }

    public func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
        try await snapshotOperation(handle)
    }

    public func close(_ handle: ChatRuntimeHandle) async {
        await closeOperation(handle)
    }
}
