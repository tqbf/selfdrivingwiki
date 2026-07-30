// pattern: Imperative Shell

import AppKit
import Combine
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The unified chat surface (D2, pillar 2). Phase 5 reduces this file to a
/// composition root: it owns view-local state and side effects, while
/// `ChatDetailPresentation` and focused child views own rendering.
struct ChatDetailView: View {
    let chatID: ChatID?

    @Bindable var store: WikiStoreModel
    var remoteSession: RemoteChatSession
    var coordinator: ChatDaemonCoordinator
    var session: WikiSession
    let fileProvider: FileProviderFacade
    @Environment(WindowRightInspectorController.self) private var rightInspector

    @State private var showsInternals = false
    @State private var composerHeight: CGFloat = ComposerTextView.oneLineHeight(for: ChatMetrics.composerFont)
    @State private var persistedMessages: [ChatMessage] = []
    @State private var attachments: [ChatAttachment] = []
    @AppStorage("chat.zoom") private var chatZoom = Double(ZoomScale.defaultScale)
    @AppStorage("chatInspectorTab") private var inspectorTab: InspectorTab = .outline
    @AppStorage("chatOutlineWidth") private var outlineWidth: Double = 240
    @State private var isHeaderExpanded = false
    @AppStorage("chat.hideToolCalls") private var hideToolCalls = false
    @State private var outlineScroll: ChatScrollRequest? = nil
    @State private var quoteAnchor: ChatHighlightRequest? = nil
    @State private var queuedMessages: [PendingQueuedMessage] = []
    @AppStorage(AgentLauncher.PermissionModeKey.chat) private var permissionModeRaw = PermissionPolicy.bypass.rawValue

    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return remoteSession.activeChatID == chatID
    }

    private var chatSummary: ChatSummary? {
        store.chats.first { $0.id == chatID }
    }

    private var remotePresentationState: ChatDetailPresentation.RemoteState {
        .init(
            runState: remoteSession.runState,
            activeChatID: remoteSession.activeChatID,
            runningKind: remoteSession.runningKind,
            preflightError: remoteSession.preflightError,
            pendingPermissions: remoteSession.pendingPermissions,
            runStartedAt: remoteSession.runStartedAt,
            events: remoteSession.events,
            eventTimestamps: remoteSession.eventTimestamps,
            exitStatus: remoteSession.exitStatus
        )
    }

    private var presentation: ChatDetailPresentation {
        ChatDetailPresentation.make(
            chatID: chatID,
            chatSummary: chatSummary,
            showsInternals: showsInternals,
            remoteSession: remotePresentationState,
            persistedMessages: persistedMessages,
            queuedMessages: queuedMessages,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured
        )
    }

    private var isChatOperationConfigured: Bool {
        let config = remoteSession.providersConfig()
        let override: (providerId: ProviderID, modelId: ModelID?)?
        if let chatSummary, let providerID = chatSummary.modelProviderId {
            override = (providerID, chatSummary.modelId)
        } else {
            override = remoteSession.pendingModelOverride
        }
        return config.isChatOperationConfigured(
            chatOverrideProviderId: override?.providerId,
            chatOverrideModelId: override?.modelId
        )
    }

    private var liveDebugKey: String {
        let id = chatID?.rawValue ?? "draft"
        let active = remoteSession.activeChatID?.rawValue ?? "nil"
        let state = String(describing: remoteSession.runState)
        return "chat=\(id) live=\(isLiveChat) activeChatID=\(active) runState=\(state) "
            + "liveEvents=\(remoteSession.events.count) persisted=\(persistedMessages.count) display=\(presentation.transcript.events.count)"
    }

    private var displayMessages: [AgentEvent] {
        presentation.transcript.events
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                ChatDetailControlsView(
                    showsDebugControls: presentation.controls.showsDebugControls,
                    isGenerating: remoteSession.isGenerating,
                    showsInternals: $showsInternals,
                    hideToolCalls: $hideToolCalls,
                    exitStatus: remoteSession.exitStatus,
                    debugFolderURL: remoteSession.debugFolderURL
                )
                .padding(.top, ChatMetrics.debugTopInset)
                .padding(.trailing, ChatMetrics.contentInset)
            }
            .frame(minWidth: PageEditorMetrics.detailMinWidth)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .zoomShortcuts($chatZoom)
        .zoomScroll($chatZoom)
        .onChange(of: chatZoom) { _, _ in
            composerHeight = ComposerTextView.oneLineHeight(for: composerFont)
        }
        .onChange(of: remoteSession.isRunning) { _, isRunning in
            if !isRunning { showsInternals = false }
            if !isRunning, !queuedMessages.isEmpty {
                firePendingQueuedMessage()
            }
        }
        .onChange(of: remoteSession.isGenerating) { _, isGenerating in
            guard !isGenerating else { return }
            guard remoteSession.isRunning, !queuedMessages.isEmpty else { return }
            firePendingQueuedMessage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentProvidersConfigDidChange)) { notification in
            guard let changedDirectory = notification.object as? URL,
                  changedDirectory.standardizedFileURL
                    == remoteSession.resolveProvidersContainerDirectory().standardizedFileURL
            else { return }
            remoteSession.refreshProvidersConfig()
        }
        .task(id: ChatHydrationTaskKey(chatID: chatID, sessionID: remoteSession.instanceID)) {
            if let chatID {
                persistedMessages = store.chatMessages(chatID: chatID)
                remoteSession.installHistoryLoader { afterCursor in
                    store.readChatTranscriptPage(
                        chatID: chatID,
                        after: afterCursor,
                        limit: RemoteChatSession.committedHistoryPageSize
                    )
                }
                await coordinator.rehydrate(chatID: chatID)
            } else {
                persistedMessages = []
                if let question = store.pendingChatQuestion {
                    store.pendingChatQuestion = nil
                    store.draftChatMessage = question
                }
            }
        }
        .onAppear {
            updateRightSidebarRegistration()
        }
        .onChange(of: presentation.chatInspectorAvailable) { _, _ in
            updateRightSidebarRegistration()
        }
        .onChange(of: remoteSession.activeChatID) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
            updateRightSidebarRegistration()
        }
        .onChange(of: liveDebugKey, initial: true) { _, key in
            DebugLog.chatLive("7.detail \(key)")
        }
        .onChange(of: store.messageVersion) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
        }
        .task(id: ChatAnchorTaskKey(
            chatID: chatID,
            anchorVersion: store.pendingScrollAnchorVersion,
            messageCount: displayMessages.count
        )) {
            guard let chatID, !displayMessages.isEmpty else { return }
            guard let fragment = store.consumePendingScrollAnchor(for: .chat(chatID)) else { return }
            let quote = ChatQuoteResolver.quoteText(fragment)
            guard !quote.isEmpty,
                  ChatQuoteResolver.messageIndex(of: fragment, in: displayMessages) != nil
            else { return }
            quoteAnchor = ChatHighlightRequest(
                version: (quoteAnchor?.version ?? 0) + 1,
                quote: quote
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.contentState {
        case .internals:
            internalsContent

        case .missingChat:
            missingChatContent

        case .chatSurface:
            chatSurfaceContent
        }
    }

    private var internalsContent: some View {
        AgentQueueView(
            remoteSession: remoteSession,
            showsResultEvents: false,
            showsInternals: true,
            onWikiLink: WikiReaderView.onWikiLinkHandler(for: store)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ChatMetrics.contentInset)
    }

    private var missingChatContent: some View {
        ContentUnavailableView {
            Label("Chat Missing", systemImage: ResourceKind.chat.systemImageName)
        } description: {
            Text("This chat is no longer available.")
        }
    }

    private var chatSurfaceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerContent
            VStack(spacing: 0) {
                transcriptContent
                composerContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var headerContent: some View {
        if let chatSummary {
            ChatHeaderSectionView(
                chat: chatSummary,
                isHeaderExpanded: $isHeaderExpanded,
                fileProviderAvailable: fileProvider.path != nil,
                revealDebugFolderEnabled: currentDebugFolderURL != nil,
                revealDebugFolderHelp: Self.debugFolderButtonHelpText(debugURL: currentDebugFolderURL),
                onRename: { store.renameChat(id: chatSummary.id, to: $0) },
                onShowInList: showInList,
                onShare: shareChat,
                onRevealInFinder: revealChatInFinder,
                onRevealDebugFolder: revealDebugFolder
            )
            Divider().opacity(PageEditorMetrics.dividerOpacity)
        }
    }

    private var transcriptContent: some View {
        ChatTranscriptPaneView(
            chatID: chatID,
            transcript: presentation.transcript,
            preflightBannerMessage: presentation.preflightBannerMessage,
            livePendingPermission: presentation.livePendingPermission,
            showsThinkingIndicator: presentation.showsThinkingIndicator,
            runStartedAt: remoteSession.runStartedAt,
            store: store,
            chatZoom: chatZoom,
            outlineScroll: outlineScroll,
            quoteAnchor: quoteAnchor,
            hideToolCalls: hideToolCalls
        ) { optionID, approve in
            guard let chatID else { return }
            Task {
                await coordinator.resolvePermission(
                    chatID: chatID,
                    optionId: optionID,
                    approve: approve
                )
            }
        }
    }

    private var composerContent: some View {
        let props = makeComposerPaneProps()
        return AnyView(ChatComposerPaneView(props: props))
            .padding(
                EdgeInsets(
                    top: ChatMetrics.sectionSpacing,
                    leading: PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin,
                    bottom: ChatMetrics.contentInset,
                    trailing: PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin
                )
            )
    }

    private func makeComposerPaneProps() -> ChatComposerPaneProps {
        let onSubmit: () -> Void = { sendMessage() }
        let onQueue: () -> Void = { queueMessage() }
        let onStop: () -> Void = { stopActiveResponse() }
        let onRecallQueued: (() -> Void)? = queuedMessages.isEmpty ? nil : { recallQueuedMessage() }
        let onEditQueuedMessage: (Int) -> Void = { index in editQueuedMessage(index) }
        let onRemoveQueuedMessage: (Int) -> Void = { index in removeQueuedMessage(index) }
        let onAddAttachment: (ChatAttachment) -> Void = { attachment in addAttachment(attachment) }
        let onRemoveAttachment: (ChatAttachment) -> Void = { attachment in removeAttachment(attachment) }
        let composerHeightBinding = $composerHeight
        let permissionModeBinding = $permissionModeRaw
        return ChatComposerPaneProps(
            composer: presentation.composer,
            queuedMessages: queuedMessages,
            autoFocus: chatID == nil,
            attachments: attachments,
            remoteSession: remoteSession,
            store: store,
            composerHeight: composerHeightBinding,
            composerFont: composerFont,
            permissionModeRaw: permissionModeBinding,
            autocomplete: chatAutocompleteHooks,
            onSubmit: onSubmit,
            onQueue: onQueue,
            onStop: onStop,
            onRecallQueued: onRecallQueued,
            onEditQueuedMessage: onEditQueuedMessage,
            onRemoveQueuedMessage: onRemoveQueuedMessage,
            onAddAttachment: onAddAttachment,
            onRemoveAttachment: onRemoveAttachment
        )
    }

    private func updateRightSidebarRegistration() {
        guard presentation.chatInspectorAvailable else {
            rightInspector.updateRegistration(nil)
            return
        }
        rightInspector.updateRegistration(
            RightSidebarRegistration(
                inspectorTab: $inspectorTab,
                outlineWidth: $outlineWidth,
                showsOutlineTab: true,
                showsHistoryTab: false,
                origin: nil,
                history: [],
                store: nil,
                onCompareVersions: nil,
                outline: {
                    AnyView(
                        ChatInspectorOutlineView(entries: presentation.outlineEntries) { turnIndex in
                            outlineScroll = ChatScrollRequest(
                                version: (outlineScroll?.version ?? 0) + 1,
                                turnIndex: turnIndex
                            )
                        }
                    )
                }
            )
        )
    }

    private var composerFont: NSFont {
        let base = ChatMetrics.composerFont
        return base.withSize(base.pointSize * CGFloat(chatZoom))
    }

    private var chatAutocompleteHooks: ComposerTextView.AutocompleteHooks? {
        guard let search = store.tantivySearch else { return nil }
        return ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in
                let tantivyKind = Self.tantivyKind(for: kind)
                return await search.autocomplete(
                    partial: partial,
                    kinds: [tantivyKind],
                    distance: 2,
                    limit: 8
                )
            },
            format: { hit in
                let linkType = Self.linkType(for: hit.kind)
                return DroppedLinkFormatter.link(
                    for: linkType,
                    id: hit.ulid,
                    displayName: hit.title
                )
            }
        )
    }

    nonisolated static func tantivyKind(for kind: ParsedLink.LinkType) -> TantivyDocumentKind {
        switch kind {
        case .page: return .page
        case .source: return .source
        case .chat: return .chat
        }
    }

    nonisolated static func linkType(for kind: TantivyDocumentKind) -> ParsedLink.LinkType {
        switch kind {
        case .page: return .page
        case .source: return .source
        case .chat: return .chat
        }
    }

    private var currentDebugFolderURL: URL? {
        guard let chatID else { return nil }
        return remoteSession.debugFolderURL(forChat: chatID.rawValue)
            ?? (isLiveChat ? remoteSession.debugFolderURL : nil)
    }

    private func showInList() {
        guard let chatID else { return }
        DebugLog.tabs("ChatDetailView: Show in List tapped — id=\(chatID.rawValue)")
        store.requestSidebarReveal(.chat(chatID))
    }

    private func shareChat() {
        guard let chatID else { return }
        DebugLog.fileprovider("ChatDetailView: Share tapped — id=\(chatID.rawValue)")
        Task {
            guard let url = await fileProvider.resolveChatByNameURL(id: chatID, wikiID: session.wikiID) else {
                DebugLog.fileprovider("Share chat detail: resolveChatByNameURL returned nil — id=\(chatID.rawValue) wikiID=\(session.wikiID)")
                return
            }
            let picker = NSSharingServicePicker(items: [url])
            let mouseScreen = NSEvent.mouseLocation
            guard let window = NSApplication.shared.keyWindow,
                  let contentView = window.contentView else { return }
            let windowPoint = window.convertPoint(fromScreen: mouseScreen)
            let viewPoint = contentView.convert(windowPoint, from: nil)
            picker.show(
                relativeTo: NSRect(origin: viewPoint, size: NSSize(width: 1, height: 1)),
                of: contentView,
                preferredEdge: .minY
            )
        }
    }

    private func revealChatInFinder() {
        guard let chatID else { return }
        DebugLog.fileprovider("ChatDetailView: Reveal in Finder tapped — id=\(chatID.rawValue)")
        Task {
            await fileProvider.revealChatInFinder(id: chatID, wikiID: session.wikiID)
        }
    }

    private func revealDebugFolder() {
        guard let chatID else { return }
        DebugLog.agent("ChatDetailView: Reveal Debug Folder tapped — id=\(chatID.rawValue)")
        if let currentDebugFolderURL {
            NSWorkspace.shared.activateFileViewerSelecting([currentDebugFolderURL])
        } else {
            DebugLog.agent("ChatDetailView: no debug folder available for chat — id=\(chatID.rawValue) (no runs on disk)")
        }
    }

    private func addAttachment(_ attachment: ChatAttachment) {
        if !attachments.contains(attachment) {
            attachments.append(attachment)
        }
    }

    private func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private var hasDraftText: Bool {
        !store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func stopActiveResponse() {
        guard let chatID else { return }
        Task { await coordinator.stop(chatID: chatID) }
    }

    private func sendMessage() {
        guard isChatOperationConfigured else { return }
        if remoteSession.isGenerating {
            queueMessage()
            return
        }
        guard presentation.composer.canSend else { return }
        let message = store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let wireMessage = buildWireMessage(from: message)
        store.clearActiveChatDraft()
        attachments = []
        submitMessage(wireMessage)
    }

    private func queueMessage() {
        guard isChatOperationConfigured, remoteSession.isGenerating else { return }
        let message = store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        queuedMessages.append(
            PendingQueuedMessage(
                wireMessage: buildWireMessage(from: message),
                preview: message
            )
        )
        store.clearActiveChatDraft()
        attachments = []
    }

    private func recallQueuedMessage() {
        guard let pending = queuedMessages.popLast() else { return }
        store.draftChatMessage = pending.preview
    }

    private func editQueuedMessage(_ index: Int) {
        guard !hasDraftText, queuedMessages.indices.contains(index) else { return }
        let pending = queuedMessages.remove(at: index)
        store.draftChatMessage = pending.preview
    }

    private func removeQueuedMessage(_ index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    private func firePendingQueuedMessage() {
        // Retain the pending user message when Settings becomes invalid while
        // another turn is running; only a valid resolved provider/model may
        // consume it.
        guard isChatOperationConfigured, let pending = queuedMessages.first else { return }
        queuedMessages.removeFirst()
        submitMessage(pending.wireMessage)
    }

    private func buildWireMessage(from message: String) -> String {
        guard !attachments.isEmpty else { return message }
        let refs = attachments.map(\.referenceText).joined(separator: "\n")
        return "\(refs)\n\n\(message)"
    }

    private func submitMessage(_ wireMessage: String) {
        Task {
            guard isChatOperationConfigured else { return }
            let submission = ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: ULID.generate()),
                turnID: ChatTurnID(rawValue: ULID.generate()),
                userText: wireMessage,
                contextReferences: [],
                submittedAt: Date()
            )
            if chatID != nil {
                remoteSession.optimisticSubmit(submission)
            }
            do {
                let override = remoteSession.pendingModelOverride
                let resolvedChatID = try await coordinator.submitTurn(
                    ChatSubmitRequest(
                        wikiID: session.wikiID,
                        chatID: chatID,
                        submission: submission,
                        providerId: chatID == nil ? override?.providerId : nil,
                        modelId: chatID == nil ? override?.modelId : nil
                    )
                )
                if chatID == nil {
                    store.retargetActiveTabToChat(chatID: resolvedChatID)
                }
            } catch {
                if chatID != nil {
                    remoteSession.optimisticSubmitFailed(turnID: submission.turnID)
                }
                DebugLog.agent("ChatDetailView.submitMessage failed: \(error)")
                remoteSession.preflightError = error.localizedDescription
            }
        }
    }

    nonisolated static func displayMessages(
        isLiveChat: Bool,
        launcherEvents: [AgentEvent],
        persistedEvents: [AgentEvent]
    ) -> [AgentEvent] {
        ChatDetailPresentation.displayMessages(
            isLiveChat: isLiveChat,
            launcherEvents: launcherEvents,
            persistedEvents: persistedEvents
        )
    }

    nonisolated static func debugFolderButtonHelpText(debugURL: URL?) -> String {
        ChatDetailPresentation.debugFolderButtonHelpText(debugURL: debugURL)
    }

    nonisolated static func shouldShowPreflightBanner(
        preflightError: String?,
        chatID: ChatID?,
        isLiveChat: Bool
    ) -> Bool {
        ChatDetailPresentation.shouldShowPreflightBanner(
            preflightError: preflightError,
            chatID: chatID,
            isLiveChat: isLiveChat
        )
    }

    nonisolated static func preflightBannerMessage(
        preflightError: String?,
        chatID: ChatID?,
        isLiveChat: Bool
    ) -> String? {
        ChatDetailPresentation.preflightBannerMessage(
            preflightError: preflightError,
            chatID: chatID,
            isLiveChat: isLiveChat
        )
    }

    static func composerCaptionText(
        isAwaitingGenerationSlot: Bool,
        hasChatID: Bool,
        isLiveChat: Bool,
        isGenerating: Bool,
        isChatOperationConfigured: Bool
    ) -> String? {
        ChatDetailPresentation.composerCaptionText(
            isAwaitingGenerationSlot: isAwaitingGenerationSlot,
            hasChatID: hasChatID,
            isLiveChat: isLiveChat,
            isGenerating: isGenerating,
            isChatOperationConfigured: isChatOperationConfigured
        )
    }

    nonisolated static func canSendPredicate(
        hasMount: Bool,
        canType: Bool,
        isGenerating: Bool,
        isAwaitingSlot: Bool,
        hasDraftText: Bool,
        isChatOperationConfigured: Bool
    ) -> Bool {
        ChatDetailPresentation.canSendPredicate(
            hasMount: hasMount,
            canType: canType,
            isGenerating: isGenerating,
            isAwaitingSlot: isAwaitingSlot,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured
        )
    }
}

struct PendingQueuedMessage: Identifiable, Equatable {
    let id = UUID()
    let wireMessage: String
    let preview: String
}

struct ChatAttachment: Identifiable, Hashable {
    let kind: SidebarDragPayload.Kind
    let itemID: String
    let displayName: String

    var hashableID: String { "\(kind.rawValue):\(itemID)" }
    var id: String { hashableID }

    @MainActor
    init(payload: SidebarDragPayload, store: WikiStoreModel) {
        self.kind = payload.kind
        self.itemID = payload.id
        self.displayName = store.resolveAttachmentName(for: payload) ?? payload.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hashableID)
    }

    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.hashableID == rhs.hashableID
    }

    var systemImage: String {
        switch kind {
        case .page: return "doc.text"
        case .source: return "doc"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    var referenceText: String {
        switch kind {
        case .page: return "[[page:\(displayName)]]"
        case .source: return "[[source:\(displayName)]]"
        case .chat: return "[[chat:\(displayName)]]"
        }
    }
}

private struct ChatAnchorTaskKey: Hashable {
    let chatID: ChatID?
    let anchorVersion: Int
    let messageCount: Int
}

private struct ChatHydrationTaskKey: Hashable {
    let chatID: ChatID?
    let sessionID: UUID
}

enum ChatMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    static let chatTopInset: CGFloat = 56
    static let extraHorizontalMargin: CGFloat = 18
    static let composerHorizontalPadding: CGFloat = 18
    static let composerTopPadding: CGFloat = 14
    static let composerBottomPadding: CGFloat = 12
    static let composerRowSpacing: CGFloat = 10
    static let composerCornerRadius: CGFloat = 18
    static let sendButtonSize: CGFloat = 34
    static var composerFont: NSFont { .preferredFont(forTextStyle: .body) }
}

struct ChatOutlineEntry: Hashable {
    let question: String
    let response: String?
    let questionTimestamp: Date?
    let responseTimestamp: Date?
}

func humanizeAttachmentRefs(in text: String) -> String {
    let pattern = #"\[\[(page|source|chat):([^\]]+)\]\]"#
    let result = text.replacingOccurrences(
        of: pattern,
        with: "$2",
        options: .regularExpression
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
