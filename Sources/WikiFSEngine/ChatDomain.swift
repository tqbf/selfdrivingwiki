import Foundation
import WikiFSCore

public struct ChatTimelineCursor: Hashable, Codable, RawRepresentable, Sendable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ChatTimelineCursor, rhs: ChatTimelineCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ChatSessionLifecycle: String, Sendable, Codable, CaseIterable {
    case unavailable
    case starting
    case ready
    case recovering
    case closing
    case closed
    case failed
}

public enum ChatTurnTerminalOutcome: Hashable, Sendable, Codable {
    case completed
    case failed(category: ChatTurnFailureCategory, message: String)
    case cancelled
    case interrupted(message: String)
}

public enum ChatTurnState: Hashable, Sendable, Codable {
    case queued
    case submitting
    case responding
    case awaitingPermission(PermissionRequestID)
    case cancelling
    case terminal(ChatTurnTerminalOutcome)

    public var isTerminal: Bool {
        if case .terminal = self {
            return true
        }
        return false
    }
}

public enum ChatAttentionState: Hashable, Sendable, Codable {
    case none
    case permissionRequired(PermissionRequestID)
    case turnFailed(ChatTurnID)
    case interruptedTurn(ChatTurnID)
}

public struct ChatConfigurationValueOption: Hashable, Sendable, Codable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ChatConfigurationOption: Hashable, Sendable, Codable {
    public let id: String
    public let label: String
    public let currentValueID: String?
    public let valueOptions: [ChatConfigurationValueOption]

    public init(
        id: String,
        label: String,
        currentValueID: String?,
        valueOptions: [ChatConfigurationValueOption]
    ) {
        self.id = id
        self.label = label
        self.currentValueID = currentValueID
        self.valueOptions = valueOptions
    }
}

public struct ChatCapabilitySet: Hashable, Sendable, Codable {
    public let supportsResume: Bool
    public let supportsClose: Bool
    public let availableModes: [String]
    public let availableModels: [ModelID]
    public let configurationOptions: [ChatConfigurationOption]
    public let supportsReasoning: Bool
    public let supportsToolCalls: Bool
    public let supportsPermissions: Bool

    public init(
        supportsResume: Bool,
        supportsClose: Bool,
        availableModes: [String] = [],
        availableModels: [ModelID] = [],
        configurationOptions: [ChatConfigurationOption] = [],
        supportsReasoning: Bool,
        supportsToolCalls: Bool,
        supportsPermissions: Bool
    ) {
        self.supportsResume = supportsResume
        self.supportsClose = supportsClose
        self.availableModes = availableModes
        self.availableModels = availableModels
        self.configurationOptions = configurationOptions
        self.supportsReasoning = supportsReasoning
        self.supportsToolCalls = supportsToolCalls
        self.supportsPermissions = supportsPermissions
    }

    public static let unavailable = ChatCapabilitySet(
        supportsResume: false,
        supportsClose: false,
        supportsReasoning: false,
        supportsToolCalls: false,
        supportsPermissions: false
    )
}

public enum ChatPermissionOptionBehavior: String, Sendable, Codable, CaseIterable {
    case allow
    case deny
    case cancel
}

public struct ChatPermissionOption: Hashable, Sendable, Codable {
    public let id: PermissionOptionID
    public let label: String
    public let behavior: ChatPermissionOptionBehavior
    public let isDefault: Bool
    public let visualIntent: String?

    public init(
        id: PermissionOptionID,
        label: String,
        behavior: ChatPermissionOptionBehavior,
        isDefault: Bool = false,
        visualIntent: String? = nil
    ) {
        self.id = id
        self.label = label
        self.behavior = behavior
        self.isDefault = isDefault
        self.visualIntent = visualIntent
    }
}

public struct ChatPendingPermissionRequest: Hashable, Sendable, Codable {
    public let requestID: PermissionRequestID
    public let turnID: ChatTurnID
    public let toolCallID: ToolCallID
    public let title: String
    public let message: String
    public let options: [ChatPermissionOption]

    public init(
        requestID: PermissionRequestID,
        turnID: ChatTurnID,
        toolCallID: ToolCallID,
        title: String,
        message: String,
        options: [ChatPermissionOption]
    ) {
        self.requestID = requestID
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.title = title
        self.message = message
        self.options = options
    }
}

public struct ChatPermissionResolution: Hashable, Sendable, Codable {
    public let requestID: PermissionRequestID
    public let optionID: PermissionOptionID?

    public init(requestID: PermissionRequestID, optionID: PermissionOptionID?) {
        self.requestID = requestID
        self.optionID = optionID
    }
}

public struct ChatQueuedTurn: Hashable, Sendable, Codable {
    public let ordinal: Int
    public let submission: ChatTurnSubmission
    public let editedAt: Date?

    public init(ordinal: Int, submission: ChatTurnSubmission, editedAt: Date? = nil) {
        self.ordinal = ordinal
        self.submission = submission
        self.editedAt = editedAt
    }
}

public struct ChatTurnSnapshot: Hashable, Sendable, Codable {
    public let turnID: ChatTurnID
    public let commandID: ChatCommandID
    public let visibleText: String
    public let contextReferences: [ChatContextReference]
    public let submittedAt: Date
    public let editedAt: Date?
    public let state: ChatTurnState

    public init(
        turnID: ChatTurnID,
        commandID: ChatCommandID,
        visibleText: String,
        contextReferences: [ChatContextReference],
        submittedAt: Date,
        editedAt: Date? = nil,
        state: ChatTurnState
    ) {
        self.turnID = turnID
        self.commandID = commandID
        self.visibleText = visibleText
        self.contextReferences = contextReferences
        self.submittedAt = submittedAt
        self.editedAt = editedAt
        self.state = state
    }
}

public struct ChatProviderState: Hashable, Sendable, Codable {
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let providerSessionID: AcpSessionID?

    public init(providerID: ProviderID?, modelID: ModelID?, providerSessionID: AcpSessionID?) {
        self.providerID = providerID
        self.modelID = modelID
        self.providerSessionID = providerSessionID
    }
}

public struct ChatDiagnosticsState: Hashable, Sendable, Codable {
    public let stderr: String
    public let lastActivityAt: Date?
    public let currentProcessID: Int32?

    public init(stderr: String = "", lastActivityAt: Date? = nil, currentProcessID: Int32? = nil) {
        self.stderr = stderr
        self.lastActivityAt = lastActivityAt
        self.currentProcessID = currentProcessID
    }
}

public struct ChatRuntimeSnapshot: Sendable, Codable, Equatable {
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
    public let committedTranscriptCursor: ChatTimelineCursor?
    public let transientTranscriptOverlay: [ChatTranscriptItem]
    public let lastIncludedSequence: ChatUpdateSequence

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
        committedTranscriptCursor: ChatTimelineCursor?,
        transientTranscriptOverlay: [ChatTranscriptItem],
        lastIncludedSequence: ChatUpdateSequence
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
        self.committedTranscriptCursor = committedTranscriptCursor
        self.transientTranscriptOverlay = transientTranscriptOverlay
        self.lastIncludedSequence = lastIncludedSequence
    }
}

public func == (lhs: ChatRuntimeSnapshot, rhs: ChatRuntimeSnapshot) -> Bool {
    lhs.chatID == rhs.chatID &&
        lhs.generation == rhs.generation &&
        lhs.lifecycle == rhs.lifecycle &&
        lhs.activeTurn == rhs.activeTurn &&
        lhs.queuedTurns == rhs.queuedTurns &&
        lhs.attention == rhs.attention &&
        lhs.capabilities == rhs.capabilities &&
        lhs.providerState == rhs.providerState &&
        sessionUsageEquals(lhs.usage, rhs.usage) &&
        lhs.diagnostics == rhs.diagnostics &&
        lhs.committedTranscriptCursor == rhs.committedTranscriptCursor &&
        lhs.transientTranscriptOverlay == rhs.transientTranscriptOverlay &&
        lhs.lastIncludedSequence == rhs.lastIncludedSequence
}

private func sessionUsageEquals(_ lhs: SessionUsage?, _ rhs: SessionUsage?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (.some(let lhs), .some(let rhs)):
        return lhs.inputTokens == rhs.inputTokens &&
            lhs.outputTokens == rhs.outputTokens &&
            lhs.totalTokens == rhs.totalTokens &&
            lhs.cachedReadTokens == rhs.cachedReadTokens &&
            lhs.thoughtTokens == rhs.thoughtTokens &&
            lhs.cost == rhs.cost &&
            lhs.currency == rhs.currency &&
            lhs.contextUsed == rhs.contextUsed &&
            lhs.contextSize == rhs.contextSize &&
            lhs.providerLabel == rhs.providerLabel &&
            lhs.modelId == rhs.modelId &&
            lhs.modelName == rhs.modelName &&
            lhs.thinkingLevel == rhs.thinkingLevel
    default:
        return false
    }
}

public extension ChatRuntimeSnapshot {
    var canSubmit: Bool {
        guard isSessionInteractive else { return false }
        return activeTurn == nil
    }

    var canQueue: Bool {
        guard isSessionInteractive else { return false }
        guard let activeTurn else { return false }
        return activeTurn.state.isTerminal == false
    }

    var canCancel: Bool {
        guard let activeTurn else { return false }
        switch activeTurn.state {
        case .queued, .submitting, .responding, .awaitingPermission, .cancelling:
            return true
        case .terminal:
            return false
        }
    }

    var canResolvePermission: Bool {
        if case .permissionRequired = attention {
            return true
        }
        return false
    }

    var showsResponding: Bool {
        guard let activeTurn else { return false }
        switch activeTurn.state {
        case .submitting, .responding, .awaitingPermission, .cancelling:
            return true
        case .queued, .terminal:
            return false
        }
    }

    private var isSessionInteractive: Bool {
        switch lifecycle {
        case .starting, .ready, .recovering:
            return true
        case .unavailable, .closing, .closed, .failed:
            return false
        }
    }
}

public enum ChatSessionCommand: Hashable, Sendable, Codable {
    case createChat(commandID: ChatCommandID)
    case submitTurn(ChatTurnSubmission)
    case cancelTurn(commandID: ChatCommandID, turnID: ChatTurnID?)
    case editQueuedTurn(turn: ChatQueuedTurn)
    case removeQueuedTurn(commandID: ChatCommandID, turnID: ChatTurnID)
    case retryInterruptedTurn(commandID: ChatCommandID, priorTurnID: ChatTurnID)
    case resolvePermission(ChatPermissionResolution)
    case setConfiguration(commandID: ChatCommandID, optionID: String, valueID: String)
    case requestSnapshot(commandID: ChatCommandID)
    case closeSession(commandID: ChatCommandID)
}

public enum ChatSessionEventPayload: Hashable, Sendable, Codable {
    case queued(ChatQueuedTurn)
    case submitted(turnID: ChatTurnID)
    case started(turnID: ChatTurnID)
    case transcriptChanged([ChatTranscriptItem])
    case permissionRequested(ChatPendingPermissionRequest)
    case permissionResolved(PermissionRequestID)
    case completed(turnID: ChatTurnID)
    case failed(turnID: ChatTurnID, category: ChatTurnFailureCategory, message: String)
    case cancelled(turnID: ChatTurnID)
    case recovering
    case sessionReady(capabilities: ChatCapabilitySet, providerState: ChatProviderState)
    case sessionClosed
}

public struct ChatSessionUpdate: Hashable, Sendable, Codable {
    public let chatID: ChatID
    public let generation: ChatSessionGenerationID
    public let sequence: ChatUpdateSequence
    public let payload: ChatSessionEventPayload

    public init(
        chatID: ChatID,
        generation: ChatSessionGenerationID,
        sequence: ChatUpdateSequence,
        payload: ChatSessionEventPayload
    ) {
        self.chatID = chatID
        self.generation = generation
        self.sequence = sequence
        self.payload = payload
    }
}

public enum ChatReplayResult: Hashable, Sendable, Codable {
    case available([ChatSessionUpdate])
    case unavailable
}

public struct ChatUpdateReplayBuffer: Hashable, Sendable, Codable {
    public let capacity: Int
    private(set) var updates: [ChatSessionUpdate]

    public init(capacity: Int, updates: [ChatSessionUpdate] = []) {
        self.capacity = max(1, capacity)
        self.updates = Array(updates.suffix(max(1, capacity)))
    }

    public mutating func append(_ update: ChatSessionUpdate) {
        updates.append(update)
        if updates.count > capacity {
            updates.removeFirst(updates.count - capacity)
        }
    }

    public func replay(after watermark: ChatUpdateSequence) -> ChatReplayResult {
        guard let oldest = updates.first?.sequence else {
            return .available([])
        }
        if watermark < oldest && oldest.rawValue > watermark.rawValue + 1 {
            return .unavailable
        }
        return .available(updates.filter { $0.sequence > watermark })
    }
}

public enum ChatSessionMachineApplyResult: Sendable, Codable, Equatable {
    case applied(ChatRuntimeSnapshot)
    case ignored
}

public enum ChatSessionMachine {
    public static func apply(
        _ update: ChatSessionUpdate,
        to snapshot: ChatRuntimeSnapshot
    ) -> ChatSessionMachineApplyResult {
        guard update.chatID == snapshot.chatID else { return .ignored }
        guard update.generation == snapshot.generation else { return .ignored }
        guard update.sequence > snapshot.lastIncludedSequence else { return .ignored }

        var next = snapshot

        switch update.payload {
        case .queued(let queuedTurn):
            guard next.activeTurn == nil else { return .ignored }
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: next.lifecycle,
                activeTurn: ChatTurnSnapshot(
                    turnID: queuedTurn.submission.turnID,
                    commandID: queuedTurn.submission.commandID,
                    visibleText: queuedTurn.submission.userText,
                    contextReferences: queuedTurn.submission.contextReferences,
                    submittedAt: queuedTurn.submission.submittedAt,
                    editedAt: queuedTurn.editedAt,
                    state: .queued
                ),
                queuedTurns: next.queuedTurns,
                attention: .none,
                capabilities: next.capabilities,
                providerState: next.providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .submitted(let turnID):
            guard var activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state == .queued
            else { return .ignored }
            activeTurn = ChatTurnSnapshot(
                turnID: activeTurn.turnID,
                commandID: activeTurn.commandID,
                visibleText: activeTurn.visibleText,
                contextReferences: activeTurn.contextReferences,
                submittedAt: activeTurn.submittedAt,
                editedAt: activeTurn.editedAt,
                state: .submitting
            )
            next = replacing(snapshot: next, activeTurn: activeTurn, attention: .none, sequence: update.sequence)
            return .applied(next)

        case .started(let turnID):
            guard var activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state == .submitting
            else { return .ignored }
            activeTurn = replacingState(of: activeTurn, with: .responding)
            next = replacing(snapshot: next, activeTurn: activeTurn, attention: .none, sequence: update.sequence)
            return .applied(next)

        case .transcriptChanged(let items):
            var overlay = next.transientTranscriptOverlay
            overlay.append(contentsOf: items)
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: next.lifecycle,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                capabilities: next.capabilities,
                providerState: next.providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: overlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .permissionRequested(let request):
            guard var activeTurn = next.activeTurn,
                  activeTurn.turnID == request.turnID,
                  activeTurn.state == .responding
            else { return .ignored }
            activeTurn = replacingState(of: activeTurn, with: .awaitingPermission(request.requestID))
            next = replacing(snapshot: next, activeTurn: activeTurn, attention: .permissionRequired(request.requestID), sequence: update.sequence)
            return .applied(next)

        case .permissionResolved(let requestID):
            guard var activeTurn = next.activeTurn,
                  case .awaitingPermission(let activeRequestID) = activeTurn.state,
                  activeRequestID == requestID
            else { return .ignored }
            activeTurn = replacingState(of: activeTurn, with: .responding)
            next = replacing(snapshot: next, activeTurn: activeTurn, attention: .none, sequence: update.sequence)
            return .applied(next)

        case .completed(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else { return .ignored }
            next = replacing(snapshot: next, activeTurn: nil, attention: .none, sequence: update.sequence)
            return .applied(next)

        case .failed(let turnID, let category, let message):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else { return .ignored }
            next = replacing(
                snapshot: next,
                activeTurn: nil,
                attention: category == .interrupted ? .interruptedTurn(turnID) : .turnFailed(turnID),
                sequence: update.sequence
            )
            var overlay = next.transientTranscriptOverlay
            overlay.append(.turnFailure(ChatTranscriptTurnFailureItem(
                turnID: turnID,
                category: category,
                message: message,
                createdAt: Date()
            )))
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: next.lifecycle == .ready ? .failed : next.lifecycle,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                capabilities: next.capabilities,
                providerState: next.providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: overlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .cancelled(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else { return .ignored }
            next = replacing(snapshot: next, activeTurn: nil, attention: .none, sequence: update.sequence)
            return .applied(next)

        case .recovering:
            guard next.lifecycle == .ready || next.lifecycle == .starting else { return .ignored }
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: .recovering,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                capabilities: next.capabilities,
                providerState: next.providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .sessionReady(let capabilities, let providerState):
            guard next.lifecycle == .starting || next.lifecycle == .recovering || next.lifecycle == .unavailable else {
                return .ignored
            }
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: .ready,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                capabilities: capabilities,
                providerState: providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .sessionClosed:
            guard next.lifecycle == .ready || next.lifecycle == .recovering || next.lifecycle == .failed || next.lifecycle == .closing else {
                return .ignored
            }
            next = ChatRuntimeSnapshot(
                chatID: next.chatID,
                generation: next.generation,
                lifecycle: .closed,
                activeTurn: nil,
                queuedTurns: next.queuedTurns,
                attention: .none,
                capabilities: next.capabilities,
                providerState: next.providerState,
                usage: next.usage,
                diagnostics: next.diagnostics,
                committedTranscriptCursor: next.committedTranscriptCursor,
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)
        }
    }

    private static func replacing(
        snapshot: ChatRuntimeSnapshot,
        activeTurn: ChatTurnSnapshot?,
        attention: ChatAttentionState,
        sequence: ChatUpdateSequence
    ) -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: snapshot.lifecycle,
            activeTurn: activeTurn,
            queuedTurns: snapshot.queuedTurns,
            attention: attention,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            committedTranscriptCursor: snapshot.committedTranscriptCursor,
            transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
            lastIncludedSequence: sequence
        )
    }

    private static func replacingState(of turn: ChatTurnSnapshot, with state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: turn.turnID,
            commandID: turn.commandID,
            visibleText: turn.visibleText,
            contextReferences: turn.contextReferences,
            submittedAt: turn.submittedAt,
            editedAt: turn.editedAt,
            state: state
        )
    }
}
