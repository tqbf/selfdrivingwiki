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
    var session: any WikiSessionProtocol
    let fileProvider: FileProviderFacade
    @Environment(WindowRightInspectorController.self) private var rightInspector

    @State private var showsInternals = false
    @State private var composerHeight: CGFloat = ComposerTextView.oneLineHeight(for: ChatMetrics.composerFont)
    @State private var persistedTranscriptItems: [PersistedChatTranscriptItem] = []
    @State private var attachments: [ChatAttachment] = []
    @AppStorage("chat.zoom") private var chatZoom = Double(ZoomScale.defaultScale)
    @AppStorage("chatInspectorTab") private var inspectorTab: InspectorTab = .metadata
    @AppStorage("chatOutlineWidth") private var outlineWidth: Double = 240
    @State private var isHeaderExpanded = false
    @AppStorage(ChatToolCallDisplayPreference.storageKey) private var toolCallDisplayModeRaw =
        ChatToolCallDisplayMode.summary.rawValue
    @State private var outlineScroll: ChatScrollRequest? = nil
    @State private var quoteAnchor: ChatHighlightRequest? = nil
    @State private var queuedMessages: [PendingQueuedMessage] = []
    @State private var outgoing = ChatOutgoingMessagesController()
    /// Previous `runState.isAnswering`, so the answer→idle transition (one
    /// turn finished) can be detected exactly once.
    @State private var sessionWasAnswering = false
    @State private var diagnosticExportError: String?
    @State private var metadataState: MetadataHydrationState = .idle
    @State private var chatResolution: ChatResolution?
    @State private var chatResolutionRetryVersion = 0
    /// Durable data is refreshed by the keyed read task. Daemon snapshots only
    /// re-project this cache; they never cause a SQLite read from the inspector.
    @State private var durableChatMetadata: ChatMetadataInput?
    @AppStorage(AgentLauncher.PermissionModeKey.chat) private var permissionModeRaw = PermissionPolicy.bypass.rawValue

    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return remoteSession.chatID.chatID == chatID && remoteSession.runState.isLive
    }

    private var chatSummary: ChatSummary? {
        if case .available(let summary) = chatResolution {
            return summary
        }
        return nil
    }

    private var remotePresentationState: ChatDetailPresentation.RemoteState {
        .init(
            runState: remoteSession.runState,
            sessionChatID: remoteSession.chatID.chatID,
            runningKind: remoteSession.runningKind,
            preflightError: remoteSession.preflightError,
            pendingPermissions: remoteSession.pendingPermissions,
            runStartedAt: remoteSession.runStartedAt,
            projectionInput: remoteSession.displayProjectionInput,
            exitStatus: remoteSession.exitStatus
        )
    }

    /// Turn identities already rendered by authoritative data: the session's
    /// committed rows, overlay, active and queued turns, plus the persisted
    /// transcript. An outgoing echo retires the moment its turn appears here.
    private var authoritativeTurnIDs: Set<ChatTurnID> {
        remoteSession.knownTurnIDs.union(
            persistedTranscriptItems.compactMap { $0.item.turnID }
        )
    }

    /// Compatibility draft surface only (`.newChat` navigation intent): a
    /// draft submit must fully resolve (or fail) before another one starts.
    /// Durable chats send through the normal persisted-chat path instead.
    private var isDraftSubmitPending: Bool {
        chatID == nil && outgoing.pendingOutgoing.contains { $0.isSubmitting }
    }

    private var toolCallDisplayMode: ChatToolCallDisplayMode {
        ChatToolCallDisplayMode.resolving(raw: toolCallDisplayModeRaw)
    }

    private var presentation: ChatDetailPresentation {
        ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: chatResolution,
            showsInternals: showsInternals,
            remoteSession: remotePresentationState,
            persistedTranscriptItems: persistedTranscriptItems,
            pendingOutgoing: outgoing.pendingOutgoing,
            authoritativeTurnIDs: authoritativeTurnIDs,
            queuedMessages: queuedMessages,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured,
            toolCallDisplayMode: toolCallDisplayMode
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
        let sessionChatID = remoteSession.chatID.chatID?.rawValue ?? "draft"
        let state = String(describing: remoteSession.runState)
        return "chat=\(id) live=\(isLiveChat) sessionChatID=\(sessionChatID) runState=\(state) "
            + "liveRows=\(remoteSession.displayTranscript.rows.count) persisted=\(persistedTranscriptItems.count) display=\(presentation.transcript.displayTranscript.rows.count)"
    }

    private var displayRows: [ChatDisplayRow] {
        presentation.transcript.displayTranscript.rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                ChatDetailControlsView(
                    showsDebugControls: presentation.controls.showsDebugControls,
                    isAnswering: remoteSession.runState.isAnswering,
                    showsInternals: $showsInternals,
                    exitStatus: remoteSession.exitStatus,
                    debugFolderURL: remoteSession.debugFolderURL,
                    copyDiagnostics: copyDiagnostics,
                    writeDiagnosticsJSONL: writeDiagnosticsJSONL
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
        .onChange(of: remoteSession.runState) { _, runState in
            if !runState.isLive { showsInternals = false }
            // A turn just finished: the daemon may have titled the chat or
            // written summaries during the turn, and those writes cross to
            // this process through the chat-sync stream — the one channel an
            // open chat is guaranteed to receive. Re-read the row so the
            // header, sidebar row, and tab title reflect it now instead of
            // waiting on the cross-process Darwin bridge.
            let turnEnded = sessionWasAnswering && !runState.isAnswering
            sessionWasAnswering = runState.isAnswering
            if turnEnded, let chatID {
                chatResolution = store.resolveChat(id: chatID)
                store.reloadChats()
            }
            if !runState.isLive, !queuedMessages.isEmpty {
                firePendingQueuedMessage()
            }
            guard !runState.isAnswering, runState.isLive, !queuedMessages.isEmpty else { return }
            firePendingQueuedMessage()
        }
        .task(id: ChatResolutionTaskKey(
            chatID: chatID,
            messageVersion: store.messageVersion,
            retryVersion: chatResolutionRetryVersion,
            isLive: isLiveChat
        )) {
            // Resolve in EVERY state, live included: the durable row carries
            // the title/date the header card renders, and a brand-new chat is
            // on screen precisely while its first session is live. The task
            // re-runs on messageVersion and liveness flips, so the card keeps
            // up with daemon-side writes.
            guard let chatID else {
                chatResolution = nil
                return
            }
            chatResolution = store.resolveChat(id: chatID)
        }
        .task(id: ChatHydrationTaskKey(chatID: chatID, sessionID: remoteSession.instanceID)) {
            if let chatID {
                loadPersistedTranscript(chatID: chatID)
                remoteSession.installHistoryLoader { afterCursor in
                    store.readChatTranscriptPage(
                        chatID: chatID,
                        after: afterCursor,
                        limit: RemoteChatSession.committedHistoryPageSize
                    )
                }
                await coordinator.rehydrate(wikiID: session.wikiID, chatID: chatID)
            } else {
                persistedTranscriptItems = []
            }
            // The omnibox "Ask" pre-fill (#288) is consumed on the FIRST frame
            // of either surface: a durable new chat opens straight to
            // `.chat(id)`, so the question can no longer wait for a draft tab.
            if let question = store.pendingChatQuestion {
                store.pendingChatQuestion = nil
                store.draftChatMessage = question
            }
        }
        .task(id: chatID.map { MetadataHydrationKey.chat($0, store.messageVersion) }) {
            guard let chatID else {
                metadataState = .idle
                return
            }
            await hydrateMetadata(chatID: chatID)
        }
        .task(id: chatID) {
            guard chatID != nil else { return }
            let normalized = InspectorTab.normalize(selection: inspectorTab, availableTabs: InspectorTab.persistedChatAvailableTabs)
            if normalized != inspectorTab {
                inspectorTab = normalized
            }
            updateRightSidebarRegistration()
        }
        .onAppear {
            installOutgoingEnvironment()
            updateRightSidebarRegistration()
        }
        .onChange(of: presentation.outlineEntries) { _, _ in
            updateRightSidebarRegistration()
        }
        .onChange(of: remoteSession.runState) { _, _ in
            if let chatID, !isLiveChat {
                loadPersistedTranscript(chatID: chatID)
            }
            updateRightSidebarRegistration()
        }
        .onChange(of: liveMetadataSnapshot) { _, _ in
            applyLiveMetadataOverlay()
        }
        .onChange(of: liveDebugKey, initial: true) { _, key in
            ChatDiagnostics.observe(
                stage: .displayProjection,
                correlation: .init(
                    chat: chatID.map { .init(rawValue: $0.rawValue) },
                    eventKind: .init(rawValue: "chat-detail")
                ),
                detail: "presentation-change"
            )
        }
        .alert("Diagnostics Export Failed", isPresented: Binding(
            get: { diagnosticExportError != nil },
            set: { if !$0 { diagnosticExportError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnosticExportError = nil }
        } message: {
            Text(diagnosticExportError ?? "Unknown diagnostic export failure.")
        }
        .onChange(of: store.messageVersion) { _, _ in
            if let chatID, !isLiveChat {
                loadPersistedTranscript(chatID: chatID)
            }
        }
        .task(id: ChatAnchorTaskKey(
            chatID: chatID,
            anchorVersion: store.pendingScrollAnchorVersion,
            messageCount: displayRows.count
        )) {
            guard let chatID, !displayRows.isEmpty else { return }
            guard let fragment = store.consumePendingScrollAnchor(for: .chat(chatID)) else { return }
            let quote = ChatQuoteResolver.quoteText(fragment)
            guard !quote.isEmpty,
                  displayRows.contains(where: { $0.textForSearch.wikiNormalized.lowercased().contains(quote.wikiNormalized.lowercased()) })
            else { return }
            quoteAnchor = ChatHighlightRequest(
                version: (quoteAnchor?.version ?? 0) + 1,
                quote: quote
            )
        }
    }

    private func copyDiagnostics() {
        Task { @MainActor in
            do {
                try await coordinator.copyDiagnostics(for: chatID) { data in
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw ChatDiagnosticExportError.invalidUTF8
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else {
                        throw ChatDiagnosticExportError.pasteboardWriteFailed
                    }
                }
            } catch {
                DebugLog.store("chat diagnostic copy failed: \(error)")
                diagnosticExportError = error.localizedDescription
            }
        }
    }

    private func writeDiagnosticsJSONL(to url: URL) {
        Task { @MainActor in
            do {
                try await coordinator.writeDiagnosticsJSONL(for: chatID, to: url)
            } catch {
                DebugLog.store("chat diagnostic JSONL export failed: \(error)")
                diagnosticExportError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.contentState {
        case .internals:
            internalsContent

        case .loadingChat:
            loadingChatContent

        case .deletedChat:
            deletedChatContent

        case .failedToLoadChat(let message):
            failedToLoadChatContent(message: message)

        case .chatSurface:
            chatSurfaceContent
        }
    }

    private var internalsContent: some View {
        AgentQueueView(
            remoteSession: remoteSession,
            showsInternals: true,
            onWikiLink: WikiReaderView.onWikiLinkHandler(for: store)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ChatMetrics.contentInset)
    }

    private var loadingChatContent: some View {
        ContentUnavailableView {
            Label("Loading Chat", systemImage: ResourceKind.chat.systemImageName)
        } description: {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading chat")
        }
    }

    private var deletedChatContent: some View {
        ContentUnavailableView {
            Label("Chat Deleted", systemImage: ResourceKind.chat.systemImageName)
        } description: {
            Text("This chat no longer exists in this wiki.")
        }
    }

    private func failedToLoadChatContent(message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Chat", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                chatResolution = nil
                chatResolutionRetryVersion &+= 1
            }
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
            presentation: ChatTranscriptPanePresentation(
                chatID: chatID,
                transcript: presentation.transcript,
                preflightBannerMessage: presentation.preflightBannerMessage,
                livePendingPermission: presentation.livePendingPermission,
                showsThinkingIndicator: presentation.showsThinkingIndicator,
                runStartedAt: remoteSession.runStartedAt,
                chatZoom: chatZoom,
                outlineScroll: outlineScroll,
                quoteAnchor: quoteAnchor
            ),
            renderer: ChatTranscriptRendererEnvironment(
                renderContext: { [weak store] in store?.renderContext() },
                blobStore: store
            ),
            onIntent: handleTranscriptIntent
        )
    }

    private func handleTranscriptIntent(_ intent: ChatTranscriptIntent) {
        switch intent {
        case .openWikiLink(let url, let inNewTab):
            WikiReaderView.onWikiLinkHandler(for: store)(url, inNewTab)
        case .resolvePermission(let resolution):
            guard let chatID else { return }
            Task {
                await coordinator.resolvePermission(
                    wikiID: session.wikiID, chatID: chatID, intent: resolution)
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
            // Legacy draft surface focuses unconditionally. A durable chat
            // focuses only when it was JUST created (`beginNewChat` set the
            // one-shot request) — otherwise every remount of this tab would
            // steal keyboard focus back into the composer.
            autoFocus: chatID == nil || chatID == store.pendingComposerFocusChatID,
            onAutoFocused: chatID == nil ? nil : { [weak store] in
                store?.consumeComposerFocusRequest(for: chatID)
            },
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
        guard chatID != nil else {
            rightInspector.updateRegistration(nil)
            return
        }
        rightInspector.updateRegistration(
            RightSidebarRegistration(
                inspectorTab: $inspectorTab,
                outlineWidth: $outlineWidth,
                availableTabs: InspectorTab.persistedChatAvailableTabs,
                metadataState: metadataState,
                origin: nil,
                history: [],
                onOpenChat: { id in store.openTab(.chat(id)) },
                onCompareVersions: nil,
                metadataRouter: MetadataActionRouter(
                    openPage: { id in store.openTab(.page(id)); return true },
                    openSource: { id in store.openTab(.source(id)); return true },
                    openChat: { id in store.openTab(.chat(id)); return true },
                    selectActivity: { _ in false },
                    comparePageVersions: { _ in false },
                    compareSourceExtractions: { _ in false },
                    copy: MetadataActionRouter.systemClipboardCopy,
                    openURL: { NSWorkspace.shared.open($0) }),
                outline: {
                    AnyView(
                        ChatInspectorOutlineView(entries: presentation.outlineEntries) { target in
                            outlineScroll = ChatScrollRequest(
                                version: (outlineScroll?.version ?? 0) + 1,
                                target: target
                            )
                        }
                    )
                }
            )
        )
    }

    private func hydrateMetadata(chatID: ChatID) async {
        guard !Task.isCancelled else { return }
        metadataState = .loading(subject: .chat(chatID))
        do {
            let durable: ChatMetadataInput
            if MetadataHydrationReadPath.resolve(readServiceAvailable: store.readService != nil) == .readService,
               let readService = store.readService {
                durable = try await readService.asyncRead { database in
                    try Self.chatMetadataInput(chatID: chatID, store: database)
                }
            } else {
                durable = try Self.chatMetadataInput(chatID: chatID, store: store.internalStore)
            }
            guard !Task.isCancelled else { return }
            durableChatMetadata = durable
            metadataState = .loaded(ChatMetadataProjection.make(input: .init(
                chat: durable.chat,
                usageSummary: durable.usageSummary,
                live: liveMetadataSnapshot)))
            updateRightSidebarRegistration()
        } catch {
            guard !Task.isCancelled else { return }
            metadataState = .failed(subject: .chat(chatID), message: error.localizedDescription)
            updateRightSidebarRegistration()
        }
    }

    private var liveMetadataSnapshot: ChatMetadataLiveSnapshot? {
        ChatMetadataLiveSnapshot.from(remoteSession.syncState?.projection)
    }

    private func applyLiveMetadataOverlay() {
        guard let durable = durableChatMetadata, !Task.isCancelled else { return }
        metadataState = .loaded(ChatMetadataProjection.make(input: .init(
            chat: durable.chat,
            usageSummary: durable.usageSummary,
            live: liveMetadataSnapshot)))
        updateRightSidebarRegistration()
    }

    nonisolated private static func chatMetadataInput(
        chatID: ChatID,
        store: borrowing WikiReadAccess
    ) throws -> ChatMetadataInput {
        .init(chat: try store.getChat(id: chatID), usageSummary: try store.chatUsageSummary(chatID: chatID))
    }

    nonisolated private static func chatMetadataInput(chatID: ChatID, store: WikiStore) throws -> ChatMetadataInput {
        .init(chat: try store.getChat(id: chatID), usageSummary: try store.chatUsageSummary(chatID: chatID))
    }


    private var composerFont: NSFont {
        let base = ChatMetrics.composerFont
        return base.withSize(base.pointSize * CGFloat(chatZoom))
    }

    private var chatAutocompleteHooks: ComposerTextView.AutocompleteHooks? {
        let search = store.searchServices
        return ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in
                let tantivyKind = Self.tantivyKind(for: kind)
                do {
                    return try await search.autocomplete(
                        partial: partial,
                        kinds: [tantivyKind],
                        distance: 2,
                        limit: 8)
                } catch {
                    DebugLog.store("Chat autocomplete unavailable: \(error)")
                    return []
                }
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
        Task { await coordinator.stop(wikiID: session.wikiID, chatID: chatID) }
    }

    private func sendMessage() {
        guard isChatOperationConfigured else { return }
        if remoteSession.runState.isAnswering {
            queueMessage()
            return
        }
        guard presentation.composer.canSend else { return }
        // Belt-and-braces with the canSend guard (compat draft surface only):
        // a draft submit must fully resolve or fail before another one starts.
        guard !isDraftSubmitPending else { return }
        let message = store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let payload = ChatOutgoingMessagesController.OutgoingPayload(
            wireMessage: buildWireMessage(from: message),
            draftText: message,
            attachments: attachments
        )
        store.clearActiveChatDraft()
        attachments = []
        // The durable row's provisional title appears the moment the user
        // sends — no cross-process round trip.
        if let chatID {
            store.applyProvisionalChatTitle(chatID: chatID, userText: message)
        }
        outgoing.send(chatID: chatID, payload: payload, makeRequest: makeSubmitRequest)
    }

    private func queueMessage() {
        guard isChatOperationConfigured, remoteSession.runState.isAnswering else { return }
        let message = store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        queuedMessages.append(
            ChatOutgoingMessagesController.makePendingQueuedMessage(
                draftText: message,
                wireMessage: buildWireMessage(from: message),
                attachments: attachments
            )
        )
        store.clearActiveChatDraft()
        attachments = []
    }

    private func recallQueuedMessage() {
        // Read without mutating first: a touched composer rejects the restore,
        // and the queued message stays queued rather than being dropped.
        guard let pending = queuedMessages.last,
              let restore = ChatOutgoingMessagesController.restoreQueuedMessage(
                  pending, composer: currentComposerSnapshot()
              )
        else { return }
        queuedMessages.removeLast()
        store.draftChatMessage = restore.draftText
        attachments = restore.attachments
    }

    private func editQueuedMessage(_ index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        let pending = queuedMessages[index]
        // Restore (and remove) only from an untouched composer; otherwise the
        // queued message stays queued rather than being dropped.
        guard let restore = ChatOutgoingMessagesController.restoreQueuedMessage(
            pending, composer: currentComposerSnapshot()
        ) else { return }
        queuedMessages.remove(at: index)
        store.draftChatMessage = restore.draftText
        attachments = restore.attachments
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
        if let chatID {
            store.applyProvisionalChatTitle(chatID: chatID, userText: pending.draftText)
        }
        outgoing.send(
            chatID: chatID,
            payload: ChatOutgoingMessagesController.outgoingPayload(from: pending),
            makeRequest: makeSubmitRequest
        )
    }

    private func buildWireMessage(from message: String) -> String {
        guard !attachments.isEmpty else { return message }
        let refs = attachments.map(\.referenceText).joined(separator: "\n")
        return "\(refs)\n\n\(message)"
    }

    private func makeSubmitRequest(_ submission: ChatTurnSubmission) -> ChatSubmitRequest {
        let override = chatID == nil ? remoteSession.pendingModelOverride : nil
        return ChatSubmitRequest(
            wikiID: session.wikiID,
            chatID: chatID,
            submission: submission,
            providerId: override?.providerId,
            modelId: override?.modelId,
            configuredThinkingOptionID: chatID == nil
                ? remoteSession.pendingConfiguredThinkingOptionID
                : nil
        )
    }

    private func currentComposerSnapshot() -> ChatOutgoingMessagesController.ComposerSnapshot {
        ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentIDs: attachments.map(\.id)
        )
    }

    /// Real effect wiring for the send lifecycle controller. Idempotent; the
    /// `.id(chatID)` remount re-runs `onAppear` and re-installs onto the fresh
    /// controller instance. Durable chats need no transition effect: their
    /// `ChatID` is fixed at creation and the authoritative turn replaces the
    /// echo through the turnID filter. The compatibility `.newChat` surface
    /// (nil chatID) still follows the daemon-created chat on success.
    private func installOutgoingEnvironment() {
        let chatCreated: (@MainActor (ChatID) -> Void)? = chatID == nil
            ? { @MainActor [store] resolvedChatID in
                store.retargetActiveTabToChat(chatID: resolvedChatID)
            }
            : nil
        outgoing.installEnvironment(.init(
            submit: { [coordinator] request in
                try await coordinator.submitTurn(request)
            },
            optimisticSubmit: { [remoteSession] submission in
                remoteSession.optimisticSubmit(submission)
            },
            optimisticSubmitFailed: { [remoteSession] turnID in
                remoteSession.optimisticSubmitFailed(turnID: turnID)
            },
            chatCreated: chatCreated,
            readComposer: { [store] in
                ChatOutgoingMessagesController.ComposerSnapshot(
                    trimmedText: store.draftChatMessage
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    attachmentIDs: self.attachments.map(\.id)
                )
            },
            restoreDraft: { [store] draftText, restoredAttachments in
                store.draftChatMessage = draftText
                self.attachments = restoredAttachments
            },
            setPreflightError: { [remoteSession] message in
                remoteSession.preflightError = message
            }
        ))
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
        runState: ChatRunState,
        hasChatID: Bool,
        isLiveChat: Bool,
        isChatOperationConfigured: Bool,
        isDraftSubmitPending: Bool = false
    ) -> String? {
        ChatDetailPresentation.composerCaptionText(
            runState: runState,
            hasChatID: hasChatID,
            isLiveChat: isLiveChat,
            isChatOperationConfigured: isChatOperationConfigured,
            isDraftSubmitPending: isDraftSubmitPending
        )
    }

    nonisolated static func canSendPredicate(
        hasMount: Bool,
        runState: ChatRunState,
        hasDraftText: Bool,
        isChatOperationConfigured: Bool,
        isDraftSubmitPending: Bool = false
    ) -> Bool {
        ChatDetailPresentation.canSendPredicate(
            hasMount: hasMount,
            runState: runState,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured,
            isDraftSubmitPending: isDraftSubmitPending
        )
    }

    private func loadPersistedTranscript(chatID: ChatID) {
        var items: [PersistedChatTranscriptItem] = []
        var cursor: ChatTranscriptCursor?
        while true {
            let page = store.readChatTranscriptPage(
                chatID: chatID,
                after: cursor,
                limit: RemoteChatSession.committedHistoryPageSize
            )
            items += page.items
            guard let nextCursor = page.nextCursor,
                  nextCursor != cursor else { break }
            cursor = nextCursor
        }
        persistedTranscriptItems = items
        updateRightSidebarRegistration()
    }
}

/// One locally echoed outgoing send owned by `ChatOutgoingMessagesController`.
/// The finite status machine replaces flag pairs: a send is `submitting` from
/// the frame it is accepted until the XPC reply lands, and on failure it
/// becomes `failed(message:)` while staying visible in the transcript. The
/// entry is removed only when authoritative data takes over its turn or the
/// view remounts — never by a later send.
struct PendingOutgoingMessage: Identifiable, Equatable {
    enum Status: Equatable {
        case submitting
        case failed(message: String)
    }

    let id: ChatTurnID
    var status: Status
    /// The composer text as typed, before attachment references were prefixed.
    let draftText: String
    /// The message actually submitted on the wire (attachments inlined).
    let wireMessage: String
    /// The structured attachments captured at send time, for failure restore.
    let attachments: [ChatAttachment]
    let submittedAt: Date

    var isSubmitting: Bool {
        if case .submitting = status { return true }
        return false
    }
}

struct PendingQueuedMessage: Identifiable, Equatable {
    let id = UUID()
    let wireMessage: String
    let preview: String
    /// The composer text as typed, preserved so a failed queued send can
    /// restore the composer without exposing wire reference syntax.
    let draftText: String
    /// The structured attachments captured when the message was queued.
    let attachments: [ChatAttachment]
}

struct ChatAttachment: Identifiable, Hashable {
    let kind: SidebarDragPayload.Kind
    let itemID: String
    let displayName: String

    var hashableID: String { "\(kind.rawValue):\(itemID)" }
    var id: String { hashableID }

    init(kind: SidebarDragPayload.Kind, itemID: String, displayName: String) {
        self.kind = kind
        self.itemID = itemID
        self.displayName = displayName
    }

    @MainActor
    init(payload: SidebarDragPayload, store: WikiStoreModel) {
        self.init(
            kind: payload.kind,
            itemID: payload.id,
            displayName: store.resolveAttachmentName(for: payload) ?? payload.id
        )
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

private struct ChatResolutionTaskKey: Hashable {
    let chatID: ChatID?
    let messageVersion: Int
    let retryVersion: Int
    /// Whether the session is live. A live→cold flip (idle eviction, daemon
    /// restart, app relaunch) must re-resolve: the header renders the cached
    /// resolution once the live overlay is gone, and the daemon may have
    /// titled or summarized the row during the session.
    let isLive: Bool
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
    enum ID: Hashable {
        case turn(turnID: ChatTurnID, promptRowID: ChatDisplayRowID)
    }

    let id: ID
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
