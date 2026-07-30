import Foundation
import WikiFSCore

public enum ChatClientSyncStatus: Sendable, Equatable {
    case synchronized
    case awaitingAuthoritativeSnapshot
    case gapDetected(expected: ChatUpdateSequence, received: ChatUpdateSequence)
}

public struct ChatClientSyncState: Sendable, Equatable {
    public let chatID: ChatID
    public let projection: ChatSyncProjection?
    public let committedItems: [PersistedChatTranscriptItem]
    public let loadedCommittedCursor: ChatTranscriptCursor
    public let syncStatus: ChatClientSyncStatus
    let optimisticBaseLifecycles: [ChatTurnID: ChatSessionLifecycle]

    public init(
        chatID: ChatID,
        projection: ChatSyncProjection? = nil,
        committedItems: [PersistedChatTranscriptItem] = [],
        loadedCommittedCursor: ChatTranscriptCursor = .init(rawValue: 0),
        syncStatus: ChatClientSyncStatus = .awaitingAuthoritativeSnapshot,
        optimisticBaseLifecycles: [ChatTurnID: ChatSessionLifecycle] = [:]
    ) {
        self.chatID = chatID
        self.projection = projection
        self.committedItems = committedItems
        self.loadedCommittedCursor = loadedCommittedCursor
        self.syncStatus = syncStatus
        self.optimisticBaseLifecycles = optimisticBaseLifecycles
    }
}

public extension ChatClientSyncState {
    var displayTranscriptItems: [ChatTranscriptItem] {
        let base = committedItems.map(\.item)
        guard let projection else { return base }
        return ChatClientSyncReducer.mergingCommitted(base, with: projection.transcriptOverlay)
    }

    var displayEvents: [AgentEvent] {
        displayTranscriptItems.map(ChatTranscriptProjection.project)
    }

    var displayEventTimestamps: [Date?] {
        displayTranscriptItems.map(ChatClientSyncReducer.timestamp(for:))
    }
}

public enum ChatClientSyncEffect: Sendable, Equatable {
    case loadCommittedHistory(to: ChatTranscriptCursor)
    case requestAuthoritativeSnapshot
}

public enum ChatClientSyncAction: Sendable, Equatable {
    case applySnapshot(ChatSyncSnapshot)
    case applyUpdate(ChatSyncUpdate)
    case appendCommittedHistory(items: [PersistedChatTranscriptItem], loadedCursor: ChatTranscriptCursor)
    case optimisticSubmit(ChatTurnSubmission)
    case optimisticSubmitFailed(ChatTurnID)
}

public struct ChatClientSyncReduction: Sendable, Equatable {
    public let state: ChatClientSyncState
    public let effects: [ChatClientSyncEffect]

    public init(state: ChatClientSyncState, effects: [ChatClientSyncEffect] = []) {
        self.state = state
        self.effects = effects
    }
}

public enum ChatClientSyncReducer {
    public static func reduce(
        _ state: ChatClientSyncState,
        _ action: ChatClientSyncAction
    ) -> ChatClientSyncReduction {
        switch action {
        case .applySnapshot(let snapshot):
            return apply(snapshot: snapshot, to: state)

        case .applyUpdate(let update):
            return apply(update: update, to: state)

        case .appendCommittedHistory(let items, let loadedCursor):
            return appendCommittedHistory(items: items, loadedCursor: loadedCursor, to: state)

        case .optimisticSubmit(let submission):
            return optimisticSubmit(submission, to: state)

        case .optimisticSubmitFailed(let turnID):
            return optimisticSubmitFailed(turnID, to: state)
        }
    }

    private static func apply(
        snapshot: ChatSyncSnapshot,
        to state: ChatClientSyncState
    ) -> ChatClientSyncReduction {
        guard snapshot.projection.chatID == state.chatID else {
            return ChatClientSyncReduction(state: state)
        }

        let preservedProjection = preservingLoadedHistory(
            snapshot.projection,
            loadedCommittedCursor: state.loadedCommittedCursor
        )
        var next = ChatClientSyncState(
            chatID: state.chatID,
            projection: preservedProjection,
            committedItems: state.committedItems,
            loadedCommittedCursor: state.loadedCommittedCursor,
            syncStatus: .synchronized,
            optimisticBaseLifecycles: state.optimisticBaseLifecycles
        )
        next = pruningCommittedOverlay(in: next)
        next = retainingActiveOptimisticLifecycleBackups(in: next)

        let effects: [ChatClientSyncEffect] =
            preservedProjection.committedCursor > state.loadedCommittedCursor
            ? [.loadCommittedHistory(to: preservedProjection.committedCursor)]
            : []

        return ChatClientSyncReduction(state: next, effects: effects)
    }

    private static func apply(
        update: ChatSyncUpdate,
        to state: ChatClientSyncState
    ) -> ChatClientSyncReduction {
        guard update.projection.chatID == state.chatID else {
            return ChatClientSyncReduction(state: state)
        }

        guard state.syncStatus != .awaitingAuthoritativeSnapshot else {
            return ChatClientSyncReduction(
                state: state,
                effects: [.requestAuthoritativeSnapshot]
            )
        }

        guard let currentProjection = state.projection else {
            let next = ChatClientSyncState(
                chatID: state.chatID,
                projection: nil,
                committedItems: state.committedItems,
                loadedCommittedCursor: state.loadedCommittedCursor,
                syncStatus: .awaitingAuthoritativeSnapshot,
                optimisticBaseLifecycles: state.optimisticBaseLifecycles
            )
            return ChatClientSyncReduction(
                state: next,
                effects: [.requestAuthoritativeSnapshot]
            )
        }

        guard update.projection.generation == currentProjection.generation
                || shouldAcceptIncomingGenerationSwitch(from: currentProjection, to: update.projection) else {
            let next = ChatClientSyncState(
                chatID: state.chatID,
                projection: currentProjection,
                committedItems: state.committedItems,
                loadedCommittedCursor: state.loadedCommittedCursor,
                syncStatus: .awaitingAuthoritativeSnapshot,
                optimisticBaseLifecycles: state.optimisticBaseLifecycles
            )
            return ChatClientSyncReduction(
                state: next,
                effects: [.requestAuthoritativeSnapshot]
            )
        }

        let currentSequence = currentProjection.lastIncludedSequence
        let incomingSequence = update.projection.lastIncludedSequence
        if incomingSequence == currentSequence {
            switch update.reason {
            case .compatibilityRefreshed:
                var next = ChatClientSyncState(
                    chatID: state.chatID,
                    projection: preservingLoadedHistory(
                        update.projection,
                        loadedCommittedCursor: state.loadedCommittedCursor
                    ),
                    committedItems: state.committedItems,
                    loadedCommittedCursor: state.loadedCommittedCursor,
                    syncStatus: .synchronized,
                    optimisticBaseLifecycles: state.optimisticBaseLifecycles
                )
                next = pruningCommittedOverlay(in: next)
                next = retainingActiveOptimisticLifecycleBackups(in: next)
                let effects: [ChatClientSyncEffect] =
                    update.projection.committedCursor > state.loadedCommittedCursor
                    ? [.loadCommittedHistory(to: update.projection.committedCursor)]
                    : []
                return ChatClientSyncReduction(state: next, effects: effects)
            case .sessionEvent:
                return ChatClientSyncReduction(state: state)
            }
        }
        if incomingSequence <= currentSequence {
            return ChatClientSyncReduction(state: state)
        }

        if currentSequence.rawValue != Int64.max,
           incomingSequence.rawValue != currentSequence.rawValue + 1 {
            let next = ChatClientSyncState(
                chatID: state.chatID,
                projection: currentProjection,
                committedItems: state.committedItems,
                loadedCommittedCursor: state.loadedCommittedCursor,
                syncStatus: .gapDetected(
                    expected: ChatUpdateSequence(rawValue: currentSequence.rawValue + 1),
                    received: incomingSequence
                ),
                optimisticBaseLifecycles: state.optimisticBaseLifecycles
            )
            return ChatClientSyncReduction(
                state: next,
                effects: [.requestAuthoritativeSnapshot]
            )
        }

        var next = ChatClientSyncState(
            chatID: state.chatID,
            projection: preservingLoadedHistory(
                update.projection,
                loadedCommittedCursor: state.loadedCommittedCursor
            ),
            committedItems: state.committedItems,
            loadedCommittedCursor: state.loadedCommittedCursor,
            syncStatus: .synchronized,
            optimisticBaseLifecycles: state.optimisticBaseLifecycles
        )
        next = pruningCommittedOverlay(in: next)
        next = retainingActiveOptimisticLifecycleBackups(in: next)

        let effects: [ChatClientSyncEffect] =
            update.projection.committedCursor > state.loadedCommittedCursor
            ? [.loadCommittedHistory(to: update.projection.committedCursor)]
            : []
        return ChatClientSyncReduction(state: next, effects: effects)
    }

    private static func appendCommittedHistory(
        items: [PersistedChatTranscriptItem],
        loadedCursor: ChatTranscriptCursor,
        to state: ChatClientSyncState
    ) -> ChatClientSyncReduction {
        guard items.isEmpty == false || loadedCursor > state.loadedCommittedCursor else {
            return ChatClientSyncReduction(state: state)
        }

        var merged = Dictionary(uniqueKeysWithValues: state.committedItems.map { ($0.cursor, $0) })
        for item in items {
            merged[item.cursor] = item
        }
        let ordered = merged
            .sorted { $0.key < $1.key }
            .map(\.value)

        var next = ChatClientSyncState(
            chatID: state.chatID,
            projection: state.projection,
            committedItems: ordered,
            loadedCommittedCursor: max(state.loadedCommittedCursor, loadedCursor),
            syncStatus: state.syncStatus,
            optimisticBaseLifecycles: state.optimisticBaseLifecycles
        )
        next = pruningCommittedOverlay(in: next)
        next = retainingActiveOptimisticLifecycleBackups(in: next)
        return ChatClientSyncReduction(state: next)
    }

    private static func optimisticSubmit(
        _ submission: ChatTurnSubmission,
        to state: ChatClientSyncState
    ) -> ChatClientSyncReduction {
        guard let projection = state.projection else {
            return ChatClientSyncReduction(state: state)
        }
        guard containsOptimisticSubmission(submission, in: projection) == false else {
            return ChatClientSyncReduction(state: state)
        }

        let optimisticMessage = ChatTranscriptItem.message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "optimistic-\(submission.turnID.rawValue)"),
                turnID: submission.turnID,
                role: .user,
                text: submission.userText,
                createdAt: submission.submittedAt
            )
        )

        let queuedTurn = ChatQueuedTurn(
            ordinal: projection.queuedTurns.count + 1,
            submission: submission
        )
        var optimisticBaseLifecycles = state.optimisticBaseLifecycles
        optimisticBaseLifecycles[submission.turnID] = projection.lifecycle

        let nextProjection: ChatSyncProjection
        if let activeTurn = projection.activeTurn,
           activeTurn.state.isTerminal == false {
            if projection.queuedTurns.contains(where: { $0.submission.turnID == submission.turnID }) {
                return ChatClientSyncReduction(state: state)
            }
            nextProjection = ChatSyncProjection(
                chatID: projection.chatID,
                generation: projection.generation,
                lifecycle: projection.lifecycle,
                activeTurn: activeTurn,
                queuedTurns: projection.queuedTurns + [queuedTurn],
                attention: projection.attention,
                capabilities: projection.capabilities,
                providerState: projection.providerState,
                usage: projection.usage,
                diagnostics: projection.diagnostics,
                transcriptOverlay: projection.transcriptOverlay + [optimisticMessage],
                committedCursor: projection.committedCursor,
                lastIncludedSequence: projection.lastIncludedSequence,
                pendingPermission: projection.pendingPermission,
                runMetadata: projection.runMetadata
            )
        } else {
            nextProjection = ChatSyncProjection(
                chatID: projection.chatID,
                generation: projection.generation,
                lifecycle: projection.isLive ? projection.lifecycle : .starting,
                activeTurn: ChatTurnSnapshot(
                    turnID: submission.turnID,
                    commandID: submission.commandID,
                    visibleText: submission.userText,
                    contextReferences: submission.contextReferences,
                    submittedAt: submission.submittedAt,
                    state: .queued
                ),
                queuedTurns: projection.queuedTurns,
                attention: .none,
                capabilities: projection.capabilities,
                providerState: projection.providerState,
                usage: projection.usage,
                diagnostics: projection.diagnostics,
                transcriptOverlay: projection.transcriptOverlay + [optimisticMessage],
                committedCursor: projection.committedCursor,
                lastIncludedSequence: projection.lastIncludedSequence,
                pendingPermission: projection.pendingPermission,
                runMetadata: projection.runMetadata
            )
        }

        return ChatClientSyncReduction(
            state: ChatClientSyncState(
                chatID: state.chatID,
                projection: nextProjection,
                committedItems: state.committedItems,
                loadedCommittedCursor: state.loadedCommittedCursor,
                syncStatus: state.syncStatus,
                optimisticBaseLifecycles: optimisticBaseLifecycles
            )
        )
    }

    private static func optimisticSubmitFailed(
        _ turnID: ChatTurnID,
        to state: ChatClientSyncState
    ) -> ChatClientSyncReduction {
        guard let projection = state.projection else {
            return ChatClientSyncReduction(state: state)
        }

        let filteredOverlay = projection.transcriptOverlay.filter { item in
            guard case .message(let message) = item else { return true }
            return !(message.turnID == turnID && message.role == .user)
        }
        let filteredQueue = projection.queuedTurns.filter { $0.submission.turnID != turnID }

        let nextActiveTurn: ChatTurnSnapshot? =
            if projection.activeTurn?.turnID == turnID,
               projection.activeTurn?.state == .queued {
                nil
            } else {
                projection.activeTurn
            }
        var optimisticBaseLifecycles = state.optimisticBaseLifecycles
        let restoredLifecycle = optimisticBaseLifecycles.removeValue(forKey: turnID) ?? projection.lifecycle

        let nextProjection = ChatSyncProjection(
            chatID: projection.chatID,
            generation: projection.generation,
            lifecycle: nextActiveTurn == nil && filteredQueue.isEmpty ? restoredLifecycle : projection.lifecycle,
            activeTurn: nextActiveTurn,
            queuedTurns: filteredQueue,
            attention: projection.attention,
            capabilities: projection.capabilities,
            providerState: projection.providerState,
            usage: projection.usage,
            diagnostics: projection.diagnostics,
            transcriptOverlay: filteredOverlay,
            committedCursor: projection.committedCursor,
            lastIncludedSequence: projection.lastIncludedSequence,
            pendingPermission: projection.pendingPermission,
            runMetadata: projection.runMetadata
        )

        return ChatClientSyncReduction(
            state: ChatClientSyncState(
                chatID: state.chatID,
                projection: nextProjection,
                committedItems: state.committedItems,
                loadedCommittedCursor: state.loadedCommittedCursor,
                syncStatus: state.syncStatus,
                optimisticBaseLifecycles: optimisticBaseLifecycles
            )
        )
    }

    private static func containsOptimisticSubmission(
        _ submission: ChatTurnSubmission,
        in projection: ChatSyncProjection
    ) -> Bool {
        if projection.activeTurn?.turnID == submission.turnID
            || projection.activeTurn?.commandID == submission.commandID
        {
            return true
        }
        if projection.queuedTurns.contains(where: {
            $0.submission.turnID == submission.turnID || $0.submission.commandID == submission.commandID
        }) {
            return true
        }
        return projection.transcriptOverlay.contains { item in
            guard case .message(let message) = item, message.role == .user else {
                return false
            }
            return message.turnID == submission.turnID
        }
    }

    private static func preservingLoadedHistory(
        _ projection: ChatSyncProjection,
        loadedCommittedCursor: ChatTranscriptCursor
    ) -> ChatSyncProjection {
        guard projection.committedCursor < loadedCommittedCursor else {
            return projection
        }
        return ChatSyncProjection(
            chatID: projection.chatID,
            generation: projection.generation,
            lifecycle: projection.lifecycle,
            activeTurn: projection.activeTurn,
            queuedTurns: projection.queuedTurns,
            attention: projection.attention,
            capabilities: projection.capabilities,
            providerState: projection.providerState,
            usage: projection.usage,
            diagnostics: projection.diagnostics,
            transcriptOverlay: projection.transcriptOverlay,
            committedCursor: loadedCommittedCursor,
            lastIncludedSequence: projection.lastIncludedSequence,
            pendingPermission: projection.pendingPermission,
            runMetadata: projection.runMetadata
        )
    }

    private static func pruningCommittedOverlay(
        in state: ChatClientSyncState
    ) -> ChatClientSyncState {
        guard let projection = state.projection else { return state }
        let filteredOverlay = projection.transcriptOverlay.filter { overlayItem in
            guard let committedItem = state.committedItems.last(where: {
                transcriptIdentity(for: $0.item) == transcriptIdentity(for: overlayItem)
            })?.item else {
                return true
            }
            return !transcriptItemsMatchForDisplay(committedItem, overlayItem)
        }
        guard filteredOverlay != projection.transcriptOverlay else {
            return state
        }
        return ChatClientSyncState(
            chatID: state.chatID,
            projection: ChatSyncProjection(
                chatID: projection.chatID,
                generation: projection.generation,
                lifecycle: projection.lifecycle,
                activeTurn: projection.activeTurn,
                queuedTurns: projection.queuedTurns,
                attention: projection.attention,
                capabilities: projection.capabilities,
                providerState: projection.providerState,
                usage: projection.usage,
                diagnostics: projection.diagnostics,
                transcriptOverlay: filteredOverlay,
                committedCursor: projection.committedCursor,
                lastIncludedSequence: projection.lastIncludedSequence,
                pendingPermission: projection.pendingPermission,
                runMetadata: projection.runMetadata
            ),
            committedItems: state.committedItems,
            loadedCommittedCursor: state.loadedCommittedCursor,
            syncStatus: state.syncStatus,
            optimisticBaseLifecycles: state.optimisticBaseLifecycles
        )
    }

    private static func shouldAcceptIncomingGenerationSwitch(
        from currentProjection: ChatSyncProjection,
        to incomingProjection: ChatSyncProjection
    ) -> Bool {
        currentProjection.isLive == false
            && currentProjection.lastIncludedSequence == .initial
            && incomingProjection.lastIncludedSequence > currentProjection.lastIncludedSequence
    }

    private static func retainingActiveOptimisticLifecycleBackups(
        in state: ChatClientSyncState
    ) -> ChatClientSyncState {
        guard let projection = state.projection, state.optimisticBaseLifecycles.isEmpty == false else {
            return state
        }

        var liveTurnIDs = Set(projection.queuedTurns.map(\.submission.turnID))
        if let activeTurn = projection.activeTurn {
            liveTurnIDs.insert(activeTurn.turnID)
        }
        for item in projection.transcriptOverlay {
            guard case .message(let message) = item, message.role == .user else { continue }
            liveTurnIDs.insert(message.turnID)
        }

        let retained = state.optimisticBaseLifecycles.filter { liveTurnIDs.contains($0.key) }
        guard retained != state.optimisticBaseLifecycles else { return state }
        return ChatClientSyncState(
            chatID: state.chatID,
            projection: state.projection,
            committedItems: state.committedItems,
            loadedCommittedCursor: state.loadedCommittedCursor,
            syncStatus: state.syncStatus,
            optimisticBaseLifecycles: retained
        )
    }

    fileprivate static func mergingCommitted(
        _ committedItems: [ChatTranscriptItem],
        with overlay: [ChatTranscriptItem]
    ) -> [ChatTranscriptItem] {
        var merged = committedItems
        for item in overlay {
            let identity = transcriptIdentity(for: item)
            if let index = merged.lastIndex(where: { transcriptIdentity(for: $0) == identity }) {
                merged[index] = item
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private enum TranscriptIdentity: Hashable {
        case userTurn(ChatTurnID)
        case message(ChatMessageID)
        case toolCall(ToolCallID)
        case systemNotice(ChatTranscriptSystemNoticeItem)
        case turnFailure(ChatTranscriptTurnFailureItem)
    }

    private static func transcriptIdentity(for item: ChatTranscriptItem) -> TranscriptIdentity {
        switch item {
        case .message(let message):
            if message.role == .user {
                return .userTurn(message.turnID)
            }
            return .message(message.messageID)
        case .toolCall(let toolCall):
            return .toolCall(toolCall.toolCallID)
        case .systemNotice(let notice):
            return .systemNotice(notice)
        case .turnFailure(let failure):
            return .turnFailure(failure)
        }
    }

    private static func transcriptItemsMatchForDisplay(
        _ lhs: ChatTranscriptItem,
        _ rhs: ChatTranscriptItem
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.message(left), .message(right)):
            if left.role == .user, right.role == .user {
                return left.turnID == right.turnID && left.text == right.text
            }
            return left == right
        default:
            return lhs == rhs
        }
    }

    fileprivate static func timestamp(for item: ChatTranscriptItem) -> Date? {
        switch item {
        case .message(let message):
            return message.createdAt
        case .toolCall(let toolCall):
            return toolCall.updatedAt
        case .systemNotice(let notice):
            return notice.createdAt
        case .turnFailure(let failure):
            return failure.createdAt
        }
    }
}
