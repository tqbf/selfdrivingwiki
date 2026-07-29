import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

func acceptsTypedChatDomainBoundaries(
    generation: ChatSessionGenerationID,
    commandID: ChatCommandID,
    turnID: ChatTurnID,
    messageID: ChatMessageID,
    requestID: PermissionRequestID,
    optionID: PermissionOptionID,
    toolCallID: ToolCallID,
    providerSessionID: AcpSessionID
) {
    let submission = ChatTurnSubmission(
        commandID: commandID,
        turnID: turnID,
        userText: "Hello",
        contextReferences: [.chat(ChatID(rawValue: "chat-1"))],
        submittedAt: Date(timeIntervalSince1970: 1)
    )
    let permission = ChatPendingPermissionRequest(
        requestID: requestID,
        turnID: turnID,
        toolCallID: toolCallID,
        title: "Need approval",
        message: "Allow tool access?",
        options: [
            ChatPermissionOption(
                id: optionID,
                label: "Allow",
                behavior: .allow,
                isDefault: true
            )
        ]
    )
    let resolution = ChatPermissionResolution(requestID: requestID, optionID: optionID)
    let update = ChatSessionUpdate(
        chatID: ChatID(rawValue: "chat-1"),
        generation: generation,
        sequence: ChatUpdateSequence(rawValue: 1),
        payload: .permissionResolved(requestID)
    )
    let startRequest = ChatRuntimeStartRequest(
        chatID: ChatID(rawValue: "chat-1"),
        generation: generation,
        systemPrompt: "system",
        providerID: ProviderID(rawValue: "provider"),
        modelID: ModelID(rawValue: "model"),
        existingProviderSessionID: providerSessionID
    )
    let transcript: [ChatTranscriptItem] = [
        .message(
            ChatTranscriptMessageItem(
                messageID: messageID,
                turnID: turnID,
                role: .assistant,
                text: "Hi",
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ),
        .toolCall(
            ChatTranscriptToolCallItem(
                toolCallID: toolCallID,
                turnID: turnID,
                toolName: "search",
                status: .running,
                detail: nil,
                permissionRequestID: requestID,
                updatedAt: Date(timeIntervalSince1970: 3)
            )
        ),
    ]

    _ = (submission, permission, resolution, update, startRequest, transcript)
}
