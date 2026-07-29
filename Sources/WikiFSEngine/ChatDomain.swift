import Foundation
import WikiFSCore

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
    public let id: ChatConfigurationValueID
    public let label: String

    public init(id: ChatConfigurationValueID, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ChatConfigurationOption: Hashable, Sendable, Codable {
    public let id: ChatConfigurationOptionID
    public let label: String
    public let currentValueID: ChatConfigurationValueID?
    public let valueOptions: [ChatConfigurationValueOption]

    public init(
        id: ChatConfigurationOptionID,
        label: String,
        currentValueID: ChatConfigurationValueID?,
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
    public let availableModes: [ChatModeID]
    public let availableModels: [ModelID]
    public let configurationOptions: [ChatConfigurationOption]
    public let supportsReasoning: Bool
    public let supportsToolCalls: Bool
    public let supportsPermissions: Bool

    public init(
        supportsResume: Bool,
        supportsClose: Bool,
        availableModes: [ChatModeID] = [],
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

public enum ChatPermissionVisualIntent: Hashable, Sendable, Codable {
    case `default`
    case accent
    case destructive
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "default":
            self = .default
        case "accent":
            self = .accent
        case "destructive":
            self = .destructive
        default:
            self = .unknown(rawValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .default:
            try container.encode("default")
        case .accent:
            try container.encode("accent")
        case .destructive:
            try container.encode("destructive")
        case .unknown(let rawValue):
            try container.encode(rawValue)
        }
    }
}

public struct ChatPermissionOption: Hashable, Sendable, Codable {
    public let id: PermissionOptionID
    public let label: String
    public let behavior: ChatPermissionOptionBehavior
    public let isDefault: Bool
    public let visualIntent: ChatPermissionVisualIntent?

    public init(
        id: PermissionOptionID,
        label: String,
        behavior: ChatPermissionOptionBehavior,
        isDefault: Bool = false,
        visualIntent: ChatPermissionVisualIntent? = nil
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
        self.transientTranscriptOverlay = transientTranscriptOverlay
        self.lastIncludedSequence = lastIncludedSequence
    }
}

public extension ChatRuntimeSnapshot {
    var canSubmit: Bool {
        guard isSessionInteractive else { return false }
        guard let activeTurn else { return true }
        return activeTurn.state.isTerminal
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
    case setConfiguration(
        commandID: ChatCommandID,
        optionID: ChatConfigurationOptionID,
        valueID: ChatConfigurationValueID
    )
    case requestSnapshot(commandID: ChatCommandID)
    case closeSession(commandID: ChatCommandID)
}

public enum ChatSessionEventPayload: Hashable, Sendable, Codable {
    case queued(ChatQueuedTurn)
    case submitted(turnID: ChatTurnID)
    case started(turnID: ChatTurnID)
    case transcriptChanged([ChatTranscriptDelta])
    case permissionRequested(ChatPendingPermissionRequest)
    case permissionResolved(PermissionRequestID)
    case completed(turnID: ChatTurnID)
    case failed(turnID: ChatTurnID, category: ChatTurnFailureCategory, message: String, createdAt: Date)
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
    private(set) var highestSequence: ChatUpdateSequence?

    public init(
        capacity: Int,
        updates: [ChatSessionUpdate] = [],
        highestSequence: ChatUpdateSequence? = nil
    ) {
        self.capacity = max(1, capacity)
        self.updates = Array(updates.suffix(max(1, capacity)))
        self.highestSequence = highestSequence ?? updates.last?.sequence ?? .initial
    }

    public mutating func append(_ update: ChatSessionUpdate) {
        updates.append(update)
        if updates.count > capacity {
            updates.removeFirst(updates.count - capacity)
        }
        highestSequence = max(highestSequence ?? update.sequence, update.sequence)
    }

    public func replay(after watermark: ChatUpdateSequence) -> ChatReplayResult {
        let highestSequence = highestSequence ?? .initial
        guard watermark <= highestSequence else {
            return .unavailable
        }
        guard let oldestSequence = updates.first?.sequence else {
            return watermark == highestSequence ? .available([]) : .unavailable
        }

        let minimumCoveredWatermark = previousSequence(before: oldestSequence)
        guard watermark >= minimumCoveredWatermark else {
            return .unavailable
        }

        return .available(updates.filter { $0.sequence > watermark })
    }

    private func previousSequence(before sequence: ChatUpdateSequence) -> ChatUpdateSequence {
        guard sequence.rawValue > Int64.min else { return sequence }
        return ChatUpdateSequence(rawValue: sequence.rawValue - 1)
    }
}

public enum ChatSessionMachineRejection: Sendable, Codable, Equatable {
    case staleChat(expected: ChatID, received: ChatID)
    case staleGeneration(expected: ChatSessionGenerationID, received: ChatSessionGenerationID)
    case duplicateSequence(lastIncluded: ChatUpdateSequence, received: ChatUpdateSequence)
    case illegalTransition(payload: ChatSessionEventPayload)
}

public enum ChatSessionMachineApplyResult: Sendable, Codable, Equatable {
    case applied(ChatRuntimeSnapshot)
    case rejected(ChatSessionMachineRejection)
}

public enum ChatSessionMachine {
    public static func apply(
        _ update: ChatSessionUpdate,
        to snapshot: ChatRuntimeSnapshot
    ) -> ChatSessionMachineApplyResult {
        guard update.chatID == snapshot.chatID else {
            return .rejected(.staleChat(expected: snapshot.chatID, received: update.chatID))
        }
        guard update.generation == snapshot.generation else {
            return .rejected(.staleGeneration(expected: snapshot.generation, received: update.generation))
        }
        guard update.sequence > snapshot.lastIncludedSequence else {
            return .rejected(.duplicateSequence(lastIncluded: snapshot.lastIncludedSequence, received: update.sequence))
        }

        var next = snapshot

        switch update.payload {
        case .queued(let queuedTurn):
            if shouldAppendQueuedTurn(to: next) {
                next = replacing(
                    snapshot: next,
                    activeTurn: next.activeTurn,
                    queuedTurns: next.queuedTurns + [queuedTurn],
                    attention: next.attention,
                    sequence: update.sequence
                )
                return .applied(next)
            }

            next = replacing(
                snapshot: next,
                activeTurn: activeTurn(from: queuedTurn),
                queuedTurns: next.queuedTurns,
                attention: .none,
                sequence: update.sequence
            )
            return .applied(next)

        case .submitted(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state == .queued
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = replacing(
                snapshot: next,
                activeTurn: replacingState(of: activeTurn, with: .submitting),
                queuedTurns: next.queuedTurns,
                attention: .none,
                sequence: update.sequence
            )
            return .applied(next)

        case .started(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state == .submitting
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = replacing(
                snapshot: next,
                activeTurn: replacingState(of: activeTurn, with: .responding),
                queuedTurns: next.queuedTurns,
                attention: .none,
                sequence: update.sequence
            )
            return .applied(next)

        case .transcriptChanged(let deltas):
            next = replacing(
                snapshot: next,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                overlay: ChatTranscriptReducer.reducing(items: next.transientTranscriptOverlay, with: deltas),
                sequence: update.sequence
            )
            return .applied(next)

        case .permissionRequested(let request):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == request.turnID,
                  activeTurn.state == .responding
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = replacing(
                snapshot: next,
                activeTurn: replacingState(of: activeTurn, with: .awaitingPermission(request.requestID)),
                queuedTurns: next.queuedTurns,
                attention: .permissionRequired(request.requestID),
                sequence: update.sequence
            )
            return .applied(next)

        case .permissionResolved(let requestID):
            guard let activeTurn = next.activeTurn,
                  case .awaitingPermission(let activeRequestID) = activeTurn.state,
                  activeRequestID == requestID
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = replacing(
                snapshot: next,
                activeTurn: replacingState(of: activeTurn, with: .responding),
                queuedTurns: next.queuedTurns,
                attention: .none,
                sequence: update.sequence
            )
            return .applied(next)

        case .completed(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = promoteQueuedTurnIfAvailable(
                replacing(
                    snapshot: next,
                    activeTurn: replacingState(of: activeTurn, with: .terminal(.completed)),
                    queuedTurns: next.queuedTurns,
                    attention: .none,
                    sequence: update.sequence
                )
            )
            return .applied(next)

        case .failed(let turnID, let category, let message, let createdAt):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            let terminalOutcome: ChatTurnTerminalOutcome = if category == .interrupted {
                .interrupted(message: message)
            } else {
                .failed(category: category, message: message)
            }
            let attention: ChatAttentionState = if category == .interrupted {
                .interruptedTurn(turnID)
            } else {
                .turnFailed(turnID)
            }

            next = replacing(
                snapshot: next,
                activeTurn: replacingState(of: activeTurn, with: .terminal(terminalOutcome)),
                queuedTurns: next.queuedTurns,
                attention: attention,
                overlay: next.transientTranscriptOverlay + [
                    .turnFailure(
                        ChatTranscriptTurnFailureItem(
                            turnID: turnID,
                            category: category,
                            message: message,
                            createdAt: createdAt
                        )
                    )
                ],
                sequence: update.sequence
            )
            return .applied(next)

        case .cancelled(let turnID):
            guard let activeTurn = next.activeTurn,
                  activeTurn.turnID == turnID,
                  activeTurn.state.isTerminal == false
            else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = promoteQueuedTurnIfAvailable(
                replacing(
                    snapshot: next,
                    activeTurn: replacingState(of: activeTurn, with: .terminal(.cancelled)),
                    queuedTurns: next.queuedTurns,
                    attention: .none,
                    sequence: update.sequence
                )
            )
            return .applied(next)

        case .recovering:
            guard next.lifecycle == .ready || next.lifecycle == .starting else {
                return .rejected(.illegalTransition(payload: update.payload))
            }

            next = replacing(
                snapshot: next,
                lifecycle: .recovering,
                activeTurn: next.activeTurn,
                queuedTurns: next.queuedTurns,
                attention: next.attention,
                sequence: update.sequence
            )
            return .applied(next)

        case .sessionReady(let capabilities, let providerState):
            guard next.lifecycle == .starting
                || next.lifecycle == .recovering
                || next.lifecycle == .unavailable
                || next.lifecycle == .closed
            else {
                return .rejected(.illegalTransition(payload: update.payload))
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
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)

        case .sessionClosed:
            guard next.lifecycle != .closed else {
                return .rejected(.illegalTransition(payload: update.payload))
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
                transientTranscriptOverlay: next.transientTranscriptOverlay,
                lastIncludedSequence: update.sequence
            )
            return .applied(next)
        }
    }

    private static func replacing(
        snapshot: ChatRuntimeSnapshot,
        lifecycle: ChatSessionLifecycle? = nil,
        activeTurn: ChatTurnSnapshot?,
        queuedTurns: [ChatQueuedTurn],
        attention: ChatAttentionState,
        overlay: [ChatTranscriptItem]? = nil,
        sequence: ChatUpdateSequence
    ) -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: lifecycle ?? snapshot.lifecycle,
            activeTurn: activeTurn,
            queuedTurns: queuedTurns,
            attention: attention,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            transientTranscriptOverlay: overlay ?? snapshot.transientTranscriptOverlay,
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

    private static func activeTurn(from queuedTurn: ChatQueuedTurn) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: queuedTurn.submission.turnID,
            commandID: queuedTurn.submission.commandID,
            visibleText: queuedTurn.submission.userText,
            contextReferences: queuedTurn.submission.contextReferences,
            submittedAt: queuedTurn.submission.submittedAt,
            editedAt: queuedTurn.editedAt,
            state: .queued
        )
    }

    private static func shouldAppendQueuedTurn(to snapshot: ChatRuntimeSnapshot) -> Bool {
        if !snapshot.queuedTurns.isEmpty {
            return true
        }
        guard let activeTurn = snapshot.activeTurn else {
            return false
        }
        if !activeTurn.state.isTerminal {
            return true
        }
        switch snapshot.attention {
        case .turnFailed(activeTurn.turnID), .interruptedTurn(activeTurn.turnID):
            return true
        default:
            return false
        }
    }

    private static func promoteQueuedTurnIfAvailable(_ snapshot: ChatRuntimeSnapshot) -> ChatRuntimeSnapshot {
        guard let nextQueuedTurn = snapshot.queuedTurns.first else {
            return snapshot
        }

        return ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: snapshot.lifecycle,
            activeTurn: activeTurn(from: nextQueuedTurn),
            queuedTurns: Array(snapshot.queuedTurns.dropFirst()),
            attention: snapshot.attention,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
            lastIncludedSequence: snapshot.lastIncludedSequence
        )
    }
}
