import Foundation
import WikiFSCore

public struct ChatRuntimeHandle: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ResolvedThinkingConfiguration: Hashable, Sendable, Codable {
    public enum Mechanism: String, Hashable, Sendable, Codable {
        case sessionConfig
        case modelVariants
    }

    public let mechanism: Mechanism
    public let optionID: ChatConfigurationOptionID?
    public let desiredValueID: ChatConfigurationValueID
    public let priorEffectiveValueID: ChatConfigurationValueID?
    public let modelID: ModelID?

    public init(
        optionID: ChatConfigurationOptionID,
        desiredValueID: ChatConfigurationValueID,
        priorEffectiveValueID: ChatConfigurationValueID? = nil
    ) {
        mechanism = .sessionConfig
        self.optionID = optionID
        self.desiredValueID = desiredValueID
        self.priorEffectiveValueID = priorEffectiveValueID
        modelID = nil
    }

    public init(
        modelID: ModelID,
        desiredValueID: ChatConfigurationValueID,
        priorEffectiveValueID: ChatConfigurationValueID? = nil
    ) {
        mechanism = .modelVariants
        optionID = nil
        self.desiredValueID = desiredValueID
        self.priorEffectiveValueID = priorEffectiveValueID
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case mechanism, optionID, desiredValueID, priorEffectiveValueID, modelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let desired = try container.decodeIfPresent(
            ChatConfigurationValueID.self, forKey: .desiredValueID)
        let option = try container.decodeIfPresent(
            ChatConfigurationOptionID.self, forKey: .optionID)
        let model = try container.decodeIfPresent(ModelID.self, forKey: .modelID)
        let prior = try container.decodeIfPresent(
            ChatConfigurationValueID.self, forKey: .priorEffectiveValueID)
        guard let desired else {
            throw DecodingError.dataCorruptedError(
                forKey: .desiredValueID, in: container,
                debugDescription: "Thinking configuration requires desiredValueID.")
        }
        if !container.contains(.mechanism) {
            guard let option, model == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mechanism, in: container,
                    debugDescription: "Legacy thinking configuration must contain only optionID and desiredValueID.")
            }
            mechanism = .sessionConfig
            optionID = option
            modelID = nil
        } else {
            let decodedMechanism = try container.decode(Mechanism.self, forKey: .mechanism)
            switch decodedMechanism {
            case .sessionConfig:
                guard let option, model == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .mechanism, in: container,
                        debugDescription: "sessionConfig requires optionID and forbids modelID.")
                }
                mechanism = decodedMechanism
                optionID = option
                modelID = nil
            case .modelVariants:
                guard option == nil, let model else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .mechanism, in: container,
                        debugDescription: "modelVariants requires modelID and forbids optionID.")
                }
                mechanism = decodedMechanism
                optionID = nil
                modelID = model
            }
        }
        desiredValueID = desired
        priorEffectiveValueID = prior
    }

    public init?(
        resolution: ThinkingSelectionResolution,
        priorEffectiveValueID: ChatConfigurationValueID?
    ) {
        guard let effective = resolution.effectiveValueID,
              let mechanism = resolution.mechanism else { return nil }
        switch mechanism {
        case .sessionConfig(let optionID):
            self.init(
                optionID: optionID,
                desiredValueID: effective,
                priorEffectiveValueID: priorEffectiveValueID)
        case .modelVariants(let mapping):
            guard let modelID = mapping[effective] else { return nil }
            self.init(
                modelID: modelID,
                desiredValueID: effective,
                priorEffectiveValueID: priorEffectiveValueID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mechanism, forKey: .mechanism)
        try container.encode(desiredValueID, forKey: .desiredValueID)
        try container.encodeIfPresent(priorEffectiveValueID, forKey: .priorEffectiveValueID)
        switch mechanism {
        case .sessionConfig:
            guard let optionID, modelID == nil else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid sessionConfig thinking payload."))
            }
            try container.encode(optionID, forKey: .optionID)
        case .modelVariants:
            guard optionID == nil, let modelID else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid modelVariants thinking payload."))
            }
            try container.encode(modelID, forKey: .modelID)
        }
    }
}

public struct ChatRuntimeStartRequest: Hashable, Sendable, Codable {
    public let chatID: ChatID
    public let generation: ChatSessionGenerationID
    public let systemPrompt: String
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let existingProviderSessionID: AcpSessionID?
    public let thinkingConfiguration: ResolvedThinkingConfiguration?

    public init(
        chatID: ChatID,
        generation: ChatSessionGenerationID,
        systemPrompt: String,
        providerID: ProviderID?,
        modelID: ModelID?,
        existingProviderSessionID: AcpSessionID?,
        thinkingConfiguration: ResolvedThinkingConfiguration? = nil
    ) {
        self.chatID = chatID
        self.generation = generation
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.modelID = modelID
        self.existingProviderSessionID = existingProviderSessionID
        self.thinkingConfiguration = thinkingConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case chatID, generation, systemPrompt, providerID, modelID
        case existingProviderSessionID, thinkingConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decode(ChatID.self, forKey: .chatID)
        generation = try container.decode(ChatSessionGenerationID.self, forKey: .generation)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        providerID = try container.decodeIfPresent(ProviderID.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(ModelID.self, forKey: .modelID)
        existingProviderSessionID = try container.decodeIfPresent(
            AcpSessionID.self, forKey: .existingProviderSessionID)
        thinkingConfiguration = try container.decodeIfPresent(
            ResolvedThinkingConfiguration.self, forKey: .thinkingConfiguration)
    }
}

/// Process-local inputs for authoritative cold-start preparation. Provider and
/// model fields in `request` are persisted overrides until preparation resolves them.
public struct ChatRuntimeStartInput: Sendable {
    public let request: ChatRuntimeStartRequest
    public let configuredThinkingOptionID: ChatConfigurationValueID?
    public let priorEffectiveThinkingOptionID: ChatConfigurationValueID?

    public init(
        request: ChatRuntimeStartRequest,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        priorEffectiveThinkingOptionID: ChatConfigurationValueID?
    ) {
        self.request = request
        self.configuredThinkingOptionID = configuredThinkingOptionID
        self.priorEffectiveThinkingOptionID = priorEffectiveThinkingOptionID
    }
}

/// Process-local cold-start state. The durable request remains Codable, but the
/// opaque provider preparation must never cross JSON, XPC, or persistence.
public struct ChatRuntimePreparedStart: Sendable {
    public let request: ChatRuntimeStartRequest
    public let providerPreparation: AgentInteractivePreparation?

    public init(
        request: ChatRuntimeStartRequest,
        providerPreparation: AgentInteractivePreparation? = nil
    ) {
        self.request = request
        self.providerPreparation = providerPreparation
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
    /// A cumulative provider-session snapshot attributed by the runtime to its
    /// active turn. The controller remains the only lifecycle persistence
    /// writer and rejects snapshots for a non-current durable claim.
    case usage(turnID: ChatTurnID, usage: SessionUsage)
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
    func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart
    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle
    func start(_ preparation: ChatRuntimePreparedStart) async throws -> ChatRuntimeHandle
    func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async
    func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope>
    func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws
    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws
    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws
    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws
    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot
    func close(_ handle: ChatRuntimeHandle) async
}

public extension ChatAgentRuntime {
    func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart {
        ChatRuntimePreparedStart(request: input.request)
    }

    func start(_ preparation: ChatRuntimePreparedStart) async throws -> ChatRuntimeHandle {
        try await start(preparation.request)
    }

    func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async {}
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
