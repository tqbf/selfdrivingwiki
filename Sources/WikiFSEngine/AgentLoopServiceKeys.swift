import Cordis
import WikiFSCore

/// One user turn entering the agent loop.
public struct AgentTurnRequest: Equatable, Sendable {
    public let chatID: ChatID
    public let turnID: ChatTurnID
    public let userText: String

    public init(chatID: ChatID, turnID: ChatTurnID, userText: String) {
        self.chatID = chatID
        self.turnID = turnID
        self.userText = userText
    }
}

/// Mutable waterfall payload for pre-step gates and the agent request handler.
/// A pre-step listener can supply `events` without calling `next()` to bypass
/// downstream gates and the request handler.
public struct AgentStepRequest: Equatable, Sendable {
    public let turn: AgentTurnRequest
    public let stepIndex: Int
    public var prompt: String
    public var events: [AgentEvent]?

    public init(
        turn: AgentTurnRequest,
        stepIndex: Int = 0,
        prompt: String? = nil,
        events: [AgentEvent]? = nil
    ) {
        self.turn = turn
        self.stepIndex = stepIndex
        self.prompt = prompt ?? turn.userText
        self.events = events
    }
}

public struct AgentTurnStarted: Equatable, Sendable {
    public let request: AgentTurnRequest

    public init(request: AgentTurnRequest) {
        self.request = request
    }

    public var sessionEvents: [AgentEvent] { [.userText(request.userText)] }
}

public struct AgentStepCompleted: Equatable, Sendable {
    public let chatID: ChatID
    public let turnID: ChatTurnID
    public let stepIndex: Int
    public let events: [AgentEvent]

    public init(chatID: ChatID, turnID: ChatTurnID, stepIndex: Int, events: [AgentEvent]) {
        self.chatID = chatID
        self.turnID = turnID
        self.stepIndex = stepIndex
        self.events = events
    }
}

public struct AgentTurnCompleted: Equatable, Sendable {
    public let chatID: ChatID
    public let turnID: ChatTurnID

    public init(chatID: ChatID, turnID: ChatTurnID) {
        self.chatID = chatID
        self.turnID = turnID
    }

    public var sessionEvents: [AgentEvent] { [.messageStop] }
}

public enum AgentLoopError: Error, Equatable, Sendable {
    case missingStepResult(ChatTurnID)
}

/// Additive agent-loop seam. Provider adapters contribute request waterfall
/// handlers; policy plugins contribute pre-step gates.
public struct AgentLoopService: Sendable {
    public typealias Emit<Payload: Sendable> = @Sendable (
        EventKey<Payload, EmitMode>, Payload
    ) async -> Void
    public typealias Waterfall<Payload: Sendable> = @Sendable (
        EventKey<Payload, WaterfallMode>, Payload
    ) async throws -> Payload

    private let emitTurnStarted: Emit<AgentTurnStarted>
    private let emitStepCompleted: Emit<AgentStepCompleted>
    private let emitTurnCompleted: Emit<AgentTurnCompleted>
    private let runWaterfall: Waterfall<AgentStepRequest>

    public init(
        emitTurnStarted: @escaping Emit<AgentTurnStarted>,
        emitStepCompleted: @escaping Emit<AgentStepCompleted>,
        emitTurnCompleted: @escaping Emit<AgentTurnCompleted>,
        waterfall: @escaping Waterfall<AgentStepRequest>
    ) {
        self.emitTurnStarted = emitTurnStarted
        self.emitStepCompleted = emitStepCompleted
        self.emitTurnCompleted = emitTurnCompleted
        self.runWaterfall = waterfall
    }

    @discardableResult
    public func enqueue(_ request: AgentTurnRequest) async throws -> [AgentEvent] {
        await emitTurnStarted(AgentLoopEventKeys.turnStarted, AgentTurnStarted(request: request))
        var step = try await preStep(AgentStepRequest(turn: request))
        if step.events == nil {
            step = try await runWaterfall(AgentLoopEventKeys.request, step)
        }
        guard let events = step.events else {
            throw AgentLoopError.missingStepResult(request.turnID)
        }
        await emitStepCompleted(
            AgentLoopEventKeys.stepCompleted,
            AgentStepCompleted(
                chatID: request.chatID,
                turnID: request.turnID,
                stepIndex: step.stepIndex,
                events: events))
        await emitTurnCompleted(
            AgentLoopEventKeys.turnCompleted,
            AgentTurnCompleted(chatID: request.chatID, turnID: request.turnID))
        return events
    }

    public func preStep(_ request: AgentStepRequest) async throws -> AgentStepRequest {
        try await runWaterfall(AgentLoopEventKeys.preStep, request)
    }
}

public enum AgentLoopServiceKeys {
    public static let agentLoop = ServiceKey<AgentLoopService>(label: "wiki.agent-loop")
}

public enum AgentLoopEventKeys {
    public static let turnStarted = EventKey<AgentTurnStarted, EmitMode>(label: "turn/started")
    public static let stepCompleted = EventKey<AgentStepCompleted, EmitMode>(label: "step/completed")
    public static let turnCompleted = EventKey<AgentTurnCompleted, EmitMode>(label: "turn/completed")
    public static let preStep = EventKey<AgentStepRequest, WaterfallMode>(label: "agent/pre-step")
    public static let request = EventKey<AgentStepRequest, WaterfallMode>(label: "agent/request")
}
