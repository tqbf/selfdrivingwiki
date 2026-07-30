#if os(macOS)
import ACPModel
import Foundation
import Observation
import WikiFSCore
import WikiFSEngine

/// Compatibility adapter over the Phase 4 reducer-owned chat client state.
/// Call sites still bind the legacy launcher-shaped surface, but authoritative
/// sync now flows through `ChatClientSyncReducer`.
@MainActor
@Observable
public final class RemoteChatSession {
    static let committedHistoryPageSize = 200
    private static let authoritativeSnapshotRetryDelays: [Duration] = [
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(250),
    ]

    public let chatID: ChatSessionKey
    public let instanceID = UUID()

    public private(set) var syncState: ChatClientSyncState?
    public private(set) var events: [AgentEvent] = []
    public private(set) var eventTimestamps: [Date?] = []
    public private(set) var runState: ChatRunState = .idle
    public var syncStatus: ChatClientSyncStatus? { syncState?.syncStatus }

    public var isRunning: Bool { runState.isLive }
    public var isGenerating: Bool { runState.isAnswering }
    public var isAwaitingGenerationSlot: Bool { runState == .queued }
    public var isInteractiveSession: Bool { runState.isLive }
    public var activeChatID: ChatID? { runState.isLive ? chatID.chatID : nil }

    public var exitStatus: Int32?
    public var runningKind: WikiOperation.Kind?
    public var runStartedAt: Date?
    public var preflightError: String?
    public var pendingPermissions: [PendingPermission] = []
    public var thinkingOption: ThinkingEffortOption?
    public var stderr: String = ""
    public var lastActivityAt: Date?
    public var currentProcessID: Int32?

    public var onSetChatConfigOption: (@Sendable (String, String) async -> Void)?
    public var onRequestAuthoritativeSnapshot: (@Sendable () async throws -> ChatSyncSnapshot)?
    public var onLoadCommittedHistoryPage: (@MainActor @Sendable (ChatTranscriptCursor?) throws -> ChatTranscriptPage)?

    public private(set) var runTotalUsage: SessionUsage?

    public var logFileURL: URL? { syncState?.projection?.runMetadata.logFileURL }
    public var debugFolderURL: URL? { syncState?.projection?.runMetadata.debugFolderURL }
    public var availableThinkingOptions: [ThinkingEffortOption.Choice] {
        thinkingOption?.choices ?? []
    }

    public var pendingModelOverride: (providerId: ProviderID, modelId: ModelID?)?

    @ObservationIgnored private var snapshotRequestTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotRetryTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotRetryAttempt = 0
    @ObservationIgnored private var historyLoadTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoadTarget: ChatTranscriptCursor = .zero

    public init(chatID: ChatSessionKey) {
        self.chatID = chatID
        self.syncState = chatID.chatID.map { ChatClientSyncState(chatID: $0) }
    }

    func markNotLive() {
        runState = .idle
    }

    func ingest(_ update: ChatSyncUpdate) {
        guard update.projection.chatID == chatID.chatID else { return }
        apply(.applyUpdate(update))
    }

    func ingest(_ envelope: QueueEventEnvelope) {
        guard envelope.chatID == chatID.chatID else { return }
        do {
            ingest(try envelope.decodedChatSyncUpdate())
        } catch {
            DebugLog.agent("RemoteChatSession.ingest rejected envelope for \(chatID): \(error)")
        }
    }

    func hydrate(from snapshot: ChatSyncSnapshot) {
        clearAuthoritativeSnapshotRetryBackoff()
        apply(.applySnapshot(snapshot))
    }

    func optimisticSubmit(_ submission: ChatTurnSubmission) {
        apply(.optimisticSubmit(submission))
    }

    func optimisticSubmitFailed(turnID: ChatTurnID) {
        apply(.optimisticSubmitFailed(turnID))
    }

    private func apply(_ action: ChatClientSyncAction) {
        guard let state = syncState else { return }
        let reduction = ChatClientSyncReducer.reduce(state, action)
        syncState = reduction.state
        if reduction.state.syncStatus == .synchronized {
            clearAuthoritativeSnapshotRetryBackoff()
        }
        projectCompatibilitySurface()
        runEffects(reduction.effects)
    }

    private func projectCompatibilitySurface() {
        guard let syncState else {
            events = []
            eventTimestamps = []
            runState = .idle
            exitStatus = nil
            runningKind = nil
            runStartedAt = nil
            preflightError = nil
            pendingPermissions = []
            thinkingOption = nil
            stderr = ""
            lastActivityAt = nil
            currentProcessID = nil
            runTotalUsage = nil
            return
        }

        events = syncState.displayEvents
        eventTimestamps = syncState.displayEventTimestamps

        guard let projection = syncState.projection else {
            runState = .idle
            exitStatus = nil
            runningKind = nil
            runStartedAt = nil
            preflightError = nil
            pendingPermissions = []
            thinkingOption = nil
            stderr = ""
            lastActivityAt = nil
            currentProcessID = nil
            runTotalUsage = nil
            return
        }

        runState = Self.runState(from: projection)
        exitStatus = nil
        runningKind = projection.runMetadata.runKindRaw.flatMap(WikiOperation.Kind.init(rawValue:))
        runStartedAt = projection.runMetadata.runStartedAt
        preflightError = projection.runMetadata.preflightError
        pendingPermissions = projection.pendingPermission.map { [Self.pendingPermission(from: $0)] } ?? []
        thinkingOption = projection.runMetadata.thinkingOption
        stderr = projection.diagnostics.stderr
        lastActivityAt = projection.diagnostics.lastActivityAt
        currentProcessID = projection.diagnostics.currentProcessID
        runTotalUsage = projection.usage
    }

    private func runEffects(_ effects: [ChatClientSyncEffect]) {
        for effect in effects {
            switch effect {
            case .requestAuthoritativeSnapshot:
                requestAuthoritativeSnapshotIfNeeded()
            case .loadCommittedHistory(let cursor):
                scheduleCommittedHistoryLoad(to: cursor)
            }
        }
    }

    private func requestAuthoritativeSnapshotIfNeeded() {
        guard snapshotRequestTask == nil else { return }
        guard let loader = onRequestAuthoritativeSnapshot else { return }
        snapshotRequestTask = Task { [weak self] in
            do {
                let snapshot = try await loader()
                await MainActor.run {
                    self?.snapshotRequestTask = nil
                    self?.clearAuthoritativeSnapshotRetryBackoff()
                    self?.hydrate(from: snapshot)
                }
            } catch {
                await MainActor.run {
                    self?.snapshotRequestTask = nil
                    let sessionKey = self.map { String(describing: $0.chatID) } ?? "unknown"
                    DebugLog.agent("RemoteChatSession snapshot request failed for \(sessionKey): \(error)")
                    self?.scheduleAuthoritativeSnapshotRetryIfNeeded()
                }
            }
        }
    }

    private func scheduleAuthoritativeSnapshotRetryIfNeeded() {
        guard syncState?.syncStatus != .synchronized else { return }
        guard snapshotRetryTask == nil else { return }
        guard snapshotRetryAttempt < Self.authoritativeSnapshotRetryDelays.count else { return }

        let delay = Self.authoritativeSnapshotRetryDelays[snapshotRetryAttempt]
        snapshotRetryAttempt += 1
        snapshotRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                await MainActor.run {
                    self?.snapshotRetryTask = nil
                }
                return
            }
            await MainActor.run {
                self?.snapshotRetryTask = nil
                self?.requestAuthoritativeSnapshotIfNeeded()
            }
        }
    }

    private func clearAuthoritativeSnapshotRetryBackoff() {
        snapshotRetryTask?.cancel()
        snapshotRetryTask = nil
        snapshotRetryAttempt = 0
    }

    private func scheduleCommittedHistoryLoad(to target: ChatTranscriptCursor) {
        historyLoadTarget = max(historyLoadTarget, target)
        guard historyLoadTask == nil else { return }
        historyLoadTask = Task { [weak self] in
            await self?.drainCommittedHistoryLoads()
        }
    }

    private func drainCommittedHistoryLoads() async {
        defer {
            historyLoadTask = nil
            historyLoadTarget = .zero
        }

        guard let loader = onLoadCommittedHistoryPage else { return }

        while Task.isCancelled == false,
              let syncState,
              syncState.loadedCommittedCursor < historyLoadTarget {
            let afterCursor: ChatTranscriptCursor? = syncState.loadedCommittedCursor == .zero
                ? nil
                : syncState.loadedCommittedCursor
            let page: ChatTranscriptPage
            do {
                page = try loader(afterCursor)
            } catch {
                DebugLog.store("RemoteChatSession.loadCommittedHistory failed for \(chatID): \(error)")
                return
            }
            guard Task.isCancelled == false else { return }

            let loadedCursor = page.nextCursor
                ?? page.items.last?.cursor
                ?? syncState.loadedCommittedCursor
            apply(.appendCommittedHistory(items: page.items, loadedCursor: loadedCursor))
            historyLoadTarget = max(historyLoadTarget, page.checkpoint)
            if loadedCursor >= historyLoadTarget || loadedCursor == syncState.loadedCommittedCursor {
                return
            }
        }
    }

    private static func runState(from projection: ChatSyncProjection) -> ChatRunState {
        guard projection.isLive else { return .idle }
        guard let activeTurn = projection.activeTurn else { return .warm }
        switch activeTurn.state {
        case .queued:
            return .queued
        case .submitting, .responding, .awaitingPermission, .cancelling:
            return .answering
        case .terminal:
            return .warm
        }
    }

    private static func pendingPermission(from request: ChatPendingPermissionRequest) -> PendingPermission {
        PendingPermission(
            toolCallId: request.toolCallID,
            title: request.title,
            toolName: nil,
            inputSummary: request.message,
            options: request.options.map { permissionOption(from: $0) }
        )
    }

    private static func permissionOption(from option: ChatPermissionOption) -> PermissionOption {
        let kind: String = switch option.behavior {
        case .allow:
            "allow_once"
        case .deny:
            "reject_once"
        case .cancel:
            "cancel"
        }
        return PermissionOption(kind: kind, name: option.label, optionId: option.id.rawValue)
    }

    // MARK: - Provider config surface

    public func resolveProvidersContainerDirectory() -> URL {
        DebugLog.trying("resolve providers container", operation: { try DatabaseLocation.appGroupContainerDirectory() })
            ?? FileManager.default.temporaryDirectory
    }

    public func providersConfig() -> AgentProvidersConfig {
        AgentProvidersConfig.loadOrSeed(from: resolveProvidersContainerDirectory())
    }

    public func resolveSelectedProvider() -> AgentProvider {
        providersConfig().selectedProvider()
    }

    public func selectedModelId(forProvider providerId: ProviderID) -> ModelID? {
        providersConfig().selectedModelId(forProvider: providerId)
    }

    @discardableResult
    public func toggleFavoriteModel(_ modelId: ModelID, forProvider providerId: ProviderID) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().togglingFavoriteModel(modelId, forProvider: providerId)
        do {
            try updated.save(to: dir)
        } catch {
            DebugLog.store("RemoteChatSession.toggleFavoriteModel save failed (provider=\(providerId.rawValue) model=\(modelId.rawValue)): \(error)")
        }
        return updated
    }

    // MARK: - Mid-session thinking effort

    public func setThinkingEffort(_ value: String) {
        guard let option = thinkingOption else { return }
        DebugLog.agent("RemoteChatSession.setThinkingEffort: value=\(value) configId=\(option.configId)")
        thinkingOption = option.withCurrentValue(value)
        let configId = option.configId
        let callback = onSetChatConfigOption
        Task { await callback?(configId, value) }
    }

    // MARK: - Per-chat debug/log URL resolution

    public func debugFolderURL(forChat id: String) -> URL? {
        AgentLauncher.debugFolderURLStatic(forChat: id)
    }

    public func logFileURL(forChat id: String) -> URL? {
        AgentLauncher.logFileURLStatic(forChat: id)
    }

    // MARK: - Wiring

    func installHistoryLoader(
        _ loader: @escaping @MainActor @Sendable (ChatTranscriptCursor?) throws -> ChatTranscriptPage
    ) {
        onLoadCommittedHistoryPage = loader
    }

    // MARK: - Reset

    func startNewChat() {
        reset()
    }

    func reset() {
        syncState = chatID.chatID.map { ChatClientSyncState(chatID: $0) }
        events = []
        eventTimestamps = []
        runState = .idle
        exitStatus = nil
        runningKind = nil
        runStartedAt = nil
        preflightError = nil
        pendingPermissions = []
        thinkingOption = nil
        runTotalUsage = nil
        stderr = ""
        lastActivityAt = nil
        currentProcessID = nil
        snapshotRequestTask?.cancel()
        snapshotRequestTask = nil
        snapshotRetryTask?.cancel()
        snapshotRetryTask = nil
        snapshotRetryAttempt = 0
        historyLoadTask?.cancel()
        historyLoadTask = nil
        historyLoadTarget = .zero
    }
}
#endif
