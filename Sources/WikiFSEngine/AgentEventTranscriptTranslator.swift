// pattern: Functional Core

import Foundation
import WikiFSCore

/// Translates one provider event stream into typed chat transcript deltas.
///
/// Keep one value per turn or queue attempt. The value owns only translation
/// state and has no synchronization, persistence, or presentation concerns.
public struct AgentEventTranscriptTranslator: Sendable {
    private struct OpenContentBlock: Sendable {
        let messageID: ChatMessageID
        let turnID: ChatTurnID
        let role: ChatTranscriptMessageRole
        let createdAt: Date
        var text: String
    }

    private struct RunningToolCallState: Sendable {
        let toolCallID: ToolCallID
        let toolName: String
        let inputSummary: String
    }

    private enum ContentBlockState: Sendable {
        case none
        case open(OpenContentBlock)
    }

    private var contentBlock: ContentBlockState = .none
    private var nextContentBlockOrdinal = 0
    private var nextToolCallOrdinal = 0
    private var runningToolCalls: [RunningToolCallState] = []

    public init() {}

    public var activeContentBlock: ChatActiveContentBlock? {
        guard case .open(let block) = contentBlock else { return nil }
        return ChatActiveContentBlock(
            messageID: block.messageID,
            turnID: block.turnID,
            role: block.role
        )
    }

    public mutating func translate(
        _ events: [AgentEvent],
        turnID: ChatTurnID
    ) -> [ChatTranscriptDelta] {
        events.compactMap { event in
            switch event {
            case .userText(let text):
                closeContentBlock()
                return .append(.message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: ULID.generate()),
                    turnID: turnID,
                    role: .user,
                    text: text,
                    createdAt: Date()
                )))
            case .assistantText(let text):
                let delta = replacement(text, role: .assistant, turnID: turnID)
                closeContentBlock()
                return delta
            case .thinking(let text):
                let delta = replacement(text, role: .reasoning, turnID: turnID)
                closeContentBlock()
                return delta
            case .assistantTextDelta(let delta):
                return appending(delta, role: .assistant, turnID: turnID)
            case .thinkingDelta(let delta):
                return appending(delta, role: .reasoning, turnID: turnID)
            case .toolUse(let name, let inputSummary):
                closeContentBlock()
                let toolCallID = ToolCallID(rawValue: "\(turnID.rawValue)-tool-\(nextToolCallOrdinal)")
                nextToolCallOrdinal += 1
                runningToolCalls.append(.init(
                    toolCallID: toolCallID,
                    toolName: name,
                    inputSummary: inputSummary
                ))
                return .toolCallUpsert(ChatTranscriptToolCallItem(
                    toolCallID: toolCallID,
                    turnID: turnID,
                    toolName: name,
                    status: .running,
                    detail: inputSummary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                ))
            case .toolResult(let isError, let summary):
                closeContentBlock()
                // Compatibility fallback: provider events do not expose the
                // result-to-use call ID, so pair unmatched results FIFO.
                let toolCall = runningToolCalls.isEmpty
                    ? RunningToolCallState(
                        toolCallID: ToolCallID(rawValue: "\(turnID.rawValue)-tool-\(nextToolCallOrdinal)"),
                        toolName: "Tool",
                        inputSummary: ""
                    )
                    : runningToolCalls.removeFirst()
                return .toolCallUpsert(ChatTranscriptToolCallItem(
                    toolCallID: toolCall.toolCallID,
                    turnID: turnID,
                    toolName: toolCall.toolName,
                    status: isError ? .failed : .completed,
                    detail: toolCall.inputSummary,
                    output: summary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                ))
            case .turnFailed(let reason):
                closeContentBlock()
                return .append(.turnFailure(ChatTranscriptTurnFailureItem(
                    failureID: ChatTranscriptFailureID(rawValue: ULID.generate()),
                    turnID: turnID,
                    category: Self.failureCategory(for: reason),
                    message: reason.description,
                    createdAt: Date()
                )))
            case .systemInit, .subagent, .result, .messageStop, .raw:
                closeContentBlock()
                return nil
            }
        }
    }

    public static func failureCategory(for reason: TurnFailureReason) -> ChatTurnFailureCategory {
        switch reason {
        case .stalled, .ceilingExceeded:
            .interrupted
        case .agentError:
            .runtimeError
        case .quotaExhausted:
            .transportError
        }
    }

    private mutating func appending(
        _ delta: String,
        role: ChatTranscriptMessageRole,
        turnID: ChatTurnID
    ) -> ChatTranscriptDelta {
        var block = compatibleOpenBlock(role: role, turnID: turnID)
        block.text += delta
        contentBlock = .open(block)
        return .messageReplacement(
            messageID: block.messageID,
            turnID: turnID,
            role: role,
            text: block.text,
            createdAt: block.createdAt
        )
    }

    private mutating func replacement(
        _ text: String,
        role: ChatTranscriptMessageRole,
        turnID: ChatTurnID
    ) -> ChatTranscriptDelta {
        var block = compatibleOpenBlock(role: role, turnID: turnID)
        block.text = text
        contentBlock = .open(block)
        return .messageReplacement(
            messageID: block.messageID,
            turnID: turnID,
            role: role,
            text: text,
            createdAt: block.createdAt
        )
    }

    private mutating func compatibleOpenBlock(
        role: ChatTranscriptMessageRole,
        turnID: ChatTurnID
    ) -> OpenContentBlock {
        if case .open(let block) = contentBlock, block.role == role {
            return block
        }
        closeContentBlock()
        // Compatibility fallback: provider events do not expose a durable
        // content-block identity, so derive one from role, turn, and ordinal.
        let block = OpenContentBlock(
            messageID: ChatMessageID(
                rawValue: "\(role.rawValue)-\(turnID.rawValue)-block-\(nextContentBlockOrdinal)"
            ),
            turnID: turnID,
            role: role,
            createdAt: Date(),
            text: ""
        )
        nextContentBlockOrdinal += 1
        contentBlock = .open(block)
        return block
    }

    private mutating func closeContentBlock() {
        contentBlock = .none
    }
}
