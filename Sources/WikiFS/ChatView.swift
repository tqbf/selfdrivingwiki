import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The unified chat surface (D2, pillar 2). One view replaces the split
/// between the live `ChatView` and the read-only
/// `ChatHistoryDetailView`. Whether you see streaming deltas or a persisted
/// transcript depends on the **source-of-truth rule**: if this chat is the
/// launcher's active live session (`activeChatID == chatID`), render
/// `launcher.events` (in-memory, streaming). Otherwise render the persisted
/// `store.chatMessages(chatID:)`.
///
/// The `.newChat` draft state also routes here (with `chatID == nil`),
/// showing the empty-composer state until the first send retargets the tab to
/// `.chat(id)` (the draft-state morph, handled by `AgentOperationRunner`).
/// Chats are always write-capable (the read-only Ask mode was removed).
struct ChatView: View {
    /// The persisted chat id, or `nil` for the draft state (.newChat). When
    /// non-nil AND equal to `launcher.activeChatID`, the view renders live.
    let chatID: PageID?

    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
    let fileProvider: FileProviderSpike

    @State private var draftMessage = ""
    @State private var showsInternals = false
    @State private var composerHeight: CGFloat = ComposerTextView.oneLineHeight(for: ChatMetrics.composerFont)
    @State private var persistedMessages: [ChatMessage] = []
    @AppStorage("chat.zoom") private var chatZoom = Double(ZoomScale.defaultScale)
    @AppStorage("isChatOutlineExpanded") private var chatOutlineExpanded = false
    /// Persisted toggle to hide tool-call rows from the chat transcript
    /// (issue #381). Independent of "Show internals" which gates the full
    /// raw activity feed.
    @AppStorage("chat.hideToolCalls") private var hideToolCalls = false
    @State private var outlineScroll: ChatScrollRequest? = nil
    @State private var quoteAnchor: ChatHighlightRequest? = nil
    /// The chat's always-ask/yolo mode (shared with the launcher, read at spawn).
    /// v1 app-wide, default off (yolo). Applies to the next conversation.
    @AppStorage(AgentLauncher.permissionModeKey) private var permissionModeRaw = PermissionPolicy.bypass.rawValue

    /// True when this surface is rendering the active live session (D2
    /// source-of-truth rule). The view sources from `launcher.events`; when
    /// false, it sources from the persisted `store.chatMessages(chatID:)`.
    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return launcher.activeChatID == chatID.rawValue
    }

    /// Pure source-of-truth selector (D2): the live session streams from
    /// `launcher.events`; everything else renders the persisted rows. Both are
    /// `transcriptVisible`-filtered. Extracted as a static func so the selection
    /// logic is unit-testable without a SwiftUI view tree.
    ///
    /// `nonisolated`: this is a pure array selector (no view/actor state), so it
    /// can be called from nonisolated test contexts without crossing the main actor.
    nonisolated static func displayMessages(
        isLiveChat: Bool,
        launcherEvents: [AgentEvent],
        persistedEvents: [AgentEvent]
    ) -> [AgentEvent] {
        (isLiveChat ? launcherEvents : persistedEvents).transcriptVisible
    }

    /// The transcript-visible events this surface renders — `launcher.events`
    /// when live, the persisted rows otherwise. Fed to the single
    /// `ChatTranscriptView` (replacing the old live/persisted dual render sites).
    private var displayMessages: [AgentEvent] {
        Self.displayMessages(
            isLiveChat: isLiveChat,
            launcherEvents: launcher.events,
            persistedEvents: persistedMessages.map(\.event))
    }

    /// Empty-state message for the transcript placeholder. The live streaming
    /// case overlays "Waiting for the Agent…" via `transcriptIsRunning`; the
    /// idle/persisted cases show their own message here.
    private var transcriptEmptyMessage: String {
        if chatID == nil {
            return "Ask a question, or ask the Agent to update the wiki…"
        }
        return isLiveChat ? "Ask a question to start a chat." : "No messages were persisted for this chat."
    }

    /// True only when THIS surface is the active live stream — so a persisted
    /// chat never shows the "Waiting for the Agent…" placeholder even while its
    /// launcher is generating a different chat.
    private var transcriptIsRunning: Bool {
        isLiveChat && launcher.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                if showsDebugControls {
                    controls
                        .padding(.top, ChatMetrics.debugTopInset)
                        .padding(.trailing, ChatMetrics.contentInset)
                }
            }
            .frame(minWidth: PageEditorMetrics.detailMinWidth)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .zoomShortcuts($chatZoom)
        .zoomScroll($chatZoom)
        .onChange(of: chatZoom) { _, _ in
            composerHeight = ComposerTextView.oneLineHeight(for: composerFont)
        }
        .onChange(of: launcher.isRunning) { _, isRunning in
            // Belt-and-suspenders: clear the internals toggle when a run ends so a
            // later ingest/lint run doesn't inherit it and strand the view on
            // `AgentActivityView`. (AC.1)
            if !isRunning { showsInternals = false }
        }
        .task(id: chatID) {
            // Reload persisted messages whenever the chatID changes (or the store
            // changes them). The live path doesn't use these, but a persisted chat
            // needs them, and a session-end flip from live→persisted must pick up
            // the committed transcript.
            if let chatID {
                persistedMessages = store.chatMessages(chatID: chatID)
            } else {
                persistedMessages = []
                // Omnibox "Ask" action (#288): if a pending question was set
                // (from the omnibox Ask action), pre-fill the composer and
                // auto-send it. This starts a new chat with the question.
                if let question = store.pendingChatQuestion {
                    store.pendingChatQuestion = nil
                    draftMessage = question
                }
            }
        }
        // D2: when the live session ends (activeChatID clears), re-read from the
        // store so the view flips source WITHOUT a visible change (the final
        // flush has already committed by the time activeChatID clears — see the
        // flip-timing gate in AgentLauncher.finish).
        .onChange(of: launcher.activeChatID) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
        }
        // Reload persisted messages when the store changes (e.g. a new message
        // appended to a persisted chat — D3 continues append here, and this keeps
        // the persisted view live for renames/count updates when not live).
        .onChange(of: store.chats) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
        }
        // Resolve a `[[chat:Title#"quote"]]` quote anchor (issue #281) to a
        // message highlight. Keyed on (chatID, anchorVersion, messageCount):
        // the anchorVersion dimension re-fires on a re-click to the same chat,
        // and the messageCount dimension re-fires once a persisted chat's
        // messages load — so the set-once anchor is consumed only when the
        // transcript is ready (it survives the 0→N load).
        .task(id: ChatAnchorTaskKey(
            chatID: chatID,
            anchorVersion: store.pendingScrollAnchorVersion,
            messageCount: displayMessages.count)) {
            guard let chatID, !displayMessages.isEmpty else { return }
            guard let fragment = store.consumePendingScrollAnchor(for: .chat(chatID)) else { return }
            let quote = ChatQuoteResolver.quoteText(fragment)
            guard !quote.isEmpty,
                  ChatQuoteResolver.messageIndex(of: fragment, in: displayMessages) != nil
            else { return }
            quoteAnchor = ChatHighlightRequest(
                version: (quoteAnchor?.version ?? 0) + 1,
                quote: quote)
        }
    }

    // MARK: - Controls (debug cluster + new chat)

    private var controls: some View {
        // Only the live chat gets the debug cluster + new chat button.
        // A persisted non-live chat is read-only — no controls.
        HStack(spacing: 8) {
            if showsDebugControls {
                if launcher.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show internals", isOn: $showsInternals)
                    Toggle("Hide tool calls", isOn: $hideToolCalls)
                    if let status = launcher.exitStatus {
                        Label(status == 0 ? "Ended" : "Exited \(status)", systemImage: status == 0 ? "checkmark.circle" : "xmark.circle")
                    }
                    if let logURL = launcher.logFileURL {
                        Button("Reveal Log", systemImage: "doc.text.magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([logURL])
                        }
                    }
                } label: {
                    Label("Activity", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("Show activity and transcript internals")
            }
        }
    }

    private var showsDebugControls: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    /// The pending permission to surface as an inline Approve/Reject affordance,
    /// or nil when nothing is awaiting approval. Only the LIVE chat renders it
    /// (a persisted chat can't resolve a request); the first pending request is
    /// shown — ACP agents gate one write at a time, so there is at most one.
    private var livePendingPermission: PendingPermission? {
        guard isLiveChat, let first = launcher.pendingPermissions.first else { return nil }
        return first
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if showsInternals && launcher.isRunning && launcher.runningKind == .query {
            AgentActivityView(launcher: launcher, showsResultEvents: false, showsInternals: true, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ChatMetrics.contentInset)
        } else if chatID != nil && !isLiveChat && chatSummary == nil {
            // Persisted chat that no longer exists in the store.
            ContentUnavailableView {
                Label("Chat Missing", systemImage: ResourceKind.chat.systemImageName)
            } description: {
                Text("This chat is no longer available.")
            }
        } else {
            // Live, persisted, or draft (.newChat) chat: one transcript + one
            // composer (the D2 source-of-truth rule selects launcher.events vs
            // persisted rows). The draft state shows the empty-transcript
            // placeholder + composer at the bottom (no centered "Ask X" page).
            chatSurface
        }
    }

    // MARK: - Content + outline

    /// Wraps `content` with the optional right-side chat outline. Placed BELOW
    /// the header so the title pane spans full width and the outline sits beside
    /// the transcript (matching the page detail's content+outline layout).
    @ViewBuilder
    private func withChatOutline<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if chatOutlineExpanded {
                ChatOutlineView(turns: chatTurns) { turnIndex in
                    outlineScroll = ChatScrollRequest(
                        version: (outlineScroll?.version ?? 0) + 1,
                        turnIndex: turnIndex)
                }
            }
        }
    }

    // MARK: - Unified chat surface (live + persisted)

    /// One transcript + one composer for both the live (streaming) and persisted
    /// (read-only) chat. The D2 source-of-truth rule picks the event source via
    /// `displayMessages`; only the empty-state message + the composer's caption
    /// differ (persisted shows "No messages…" / the "another chat is responding"
    /// caption; live shows the streaming placeholder).
    @ViewBuilder
    private var chatSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let chat = chatSummary {
                header(for: chat)
                Divider().opacity(PageEditorMetrics.dividerOpacity)
            }
            withChatOutline {
                VStack(spacing: 0) {
                    ChatTranscriptView(
                        events: displayMessages,
                        emptyStateMessage: transcriptEmptyMessage,
                        isRunning: transcriptIsRunning,
                        onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                        renderContext: { [weak store] in store?.renderContext() },
                        blobStore: store,
                        zoom: chatZoom,
                        scrollRequest: outlineScroll,
                        quoteAnchor: quoteAnchor,
                        hideToolCalls: hideToolCalls
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, PageEditorMetrics.contentInset)
                        .padding(.top, chatSummary != nil ? 0 : ChatMetrics.chatTopInset)
                    if let pending = livePendingPermission {
                        PermissionApprovalView(permission: pending) { optionId in
                            Task { await launcher.resolvePendingPermission(optionId: optionId) }
                        }
                        .padding(.horizontal, PageEditorMetrics.contentInset)
                        .padding(.bottom, ChatMetrics.sectionSpacing / 2)
                    }
                    chatComposer
                        .padding(.horizontal, PageEditorMetrics.contentInset)
                        .padding(.top, ChatMetrics.sectionSpacing)
                        .padding(.bottom, ChatMetrics.contentInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The composer, placed once as a VStack sibling below the transcript (the
    /// live placement). For a persisted (non-live) chat it also carries the
    /// "another chat is responding" caption when the kind's launcher is busy.
    private var chatComposer: some View {
        VStack(spacing: 4) {
            composer(enabled: isComposerEnabled)
            if let caption = composerCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The paseo-style toolbar row that sits INSIDE the composer box, along its
    /// bottom edge: the provider/model chip + the permission-mode chip on the
    /// leading side, then the send button on the trailing side. The selector
    /// chips are hidden when no wiki is active (no provider context); the send
    /// button is always present.
    @ViewBuilder
    private func composerToolbar(sendActive: Bool) -> some View {
        HStack(spacing: 10) {
            // Inside ContentView the session is always non-nil (a wiki is
            // open), so the provider/model chips are always shown.
            ProviderSelector(launcher: launcher)
            PermissionModeSelector(rawValue: $permissionModeRaw)
            Spacer(minLength: 0)
            if showsStopButton {
                stopButton
            } else if hasDraftText {
                // Paseo: the send button appears only once there's something to
                // send — an empty composer shows no action glyph at all.
                sendButton(active: sendActive)
            }
        }
        // Reserve the button's height so the box doesn't grow on the first
        // keystroke when the button appears.
        .frame(minHeight: ChatMetrics.sendButtonSize)
    }

    // MARK: - Persisted chat summary

    private var chatSummary: ChatSummary? {
        store.chats.first { $0.id == chatID }
    }

    /// User turns (questions) in display order — the chat outline entries. Sourced
    /// from `displayMessages` (the SAME transcript-visible events the web view
    /// renders), so outline index `i` matches the i-th `.chat-user` row.
    private var chatTurns: [String] {
        displayMessages.compactMap { event in
            if case .userText(let text) = event { return text }
            return nil
        }
    }

    @ViewBuilder
    private func header(for chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            Label {
                EditableTitle(
                    title: chat.title,
                    placeholder: "Untitled Chat",
                    lineLimit: 1,
                    isDisabled: false,
                    onCommit: { newTitle in
                        store.renameChat(id: chat.id, to: newTitle)
                    }
                )
            } icon: {
                Image(systemName: ResourceKind.chat.systemImageName)
                    .foregroundStyle(.secondary)
            }

            Text(chat.updatedAt, style: .date)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let chatID {
                    Button("Show in List", systemImage: "sidebar.left") {
                        store.requestSidebarReveal(.chat(chatID))
                    }
                    .help("Reveal this chat in the sidebar")
                }
                if fileProvider.path != nil, let chatID {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        Task {
                            guard let url = await fileProvider.resolveChatByNameURL(id: chatID) else { return }
                            let picker = NSSharingServicePicker(items: [url])
                            let mouseScreen = NSEvent.mouseLocation
                            guard let window = NSApplication.shared.keyWindow,
                                  let contentView = window.contentView else { return }
                            let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                            let viewPoint = contentView.convert(windowPoint, from: nil)
                            picker.show(
                                relativeTo: NSRect(origin: viewPoint,
                                                   size: NSSize(width: 1, height: 1)),
                                of: contentView, preferredEdge: .minY)
                        }
                    }
                    .help("Share this chat")
                    Button("Reveal in Finder", systemImage: "folder") {
                        Task { await fileProvider.revealChatInFinder(id: chatID) }
                    }
                    .help("Reveal this chat file in Finder")
                }
                Button {
                    chatOutlineExpanded.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Outline")
            }
        }
        .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.top, PageEditorMetrics.contentInset)
        .padding(.bottom, ChatMetrics.sectionSpacing)
    }

    // MARK: - Composer caption predicates

    /// Pure predicate for the composer caption. Returns the visible caption text
    /// shown under the composer, or nil when nothing is queued/busy. Kept static
    /// so tests can verify the full state matrix without a view tree.
    static func composerCaptionText(
        isAwaitingGenerationSlot: Bool,
        hasChatID: Bool,
        isLiveChat: Bool,
        isGenerating: Bool
    ) -> String? {
        if isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if isGenerating {
            // Live chat: agent is responding. Persisted chat: a different chat
            // is generating and the launcher is busy.
            return isLiveChat
                ? "Agent is responding…"
                : "Another chat is responding — wait or stop it."
        }
        return nil
    }

    // MARK: - Composer

    /// The composer's AppKit font, scaled by the persisted chat zoom so
    /// ⌘+/⌘− resize the input alongside the transcript (parity with the page
    /// editor's `editor.zoom`).
    private var composerFont: NSFont {
        let base = ChatMetrics.composerFont
        return base.withSize(base.pointSize * CGFloat(chatZoom))
    }

    private func composer(enabled: Bool) -> some View {
        let sendActive = canSend && enabled
        // Paseo-style: ONE rounded box wrapping the text (top) and a toolbar row
        // (bottom) — model chip · permission chip · send button. Replaces the old
        // capsule-with-inline-send + separate selector bar below.
        return VStack(alignment: .leading, spacing: ChatMetrics.composerRowSpacing) {
            ComposerTextView(
                text: $draftMessage,
                isEditable: enabled,
                font: composerFont,
                onSubmit: sendMessage,
                measuredHeight: $composerHeight,
                autoFocus: chatID == nil
            )
                .frame(height: composerHeight)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if draftMessage.isEmpty {
                        Text("Ask a question, or ask to update the wiki…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            // Zero leading padding: `lineFragmentPadding=0` +
                            // `textContainerInset.width=0` mean typed text starts
                            // at the text view's left edge, so the overlay must too.
                            .padding(.vertical, ComposerTextView.Metrics.verticalInsetPerSide)
                    }
                }

            composerToolbar(sendActive: sendActive)
        }
        .padding(.horizontal, ChatMetrics.composerHorizontalPadding)
        .padding(.top, ChatMetrics.composerTopPadding)
        .padding(.bottom, ChatMetrics.composerBottomPadding)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
        .frame(maxWidth: .infinity)
    }

    /// True while the agent is actively generating or queued for the generation
    /// slot — the stop button replaces the send button in the composer toolbar.
    private var showsStopButton: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    /// The stop button shown in the composer toolbar while the agent is
    /// responding. Sits in the same position as the send button (trailing edge
    /// of the composer's bottom toolbar row).
    private var stopButton: some View {
        Button(action: { launcher.stopAgent() }) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(Color.red.opacity(0.85), in: Circle())
        }
        .buttonStyle(.borderless)
        .help("Stop the current response")
    }

    /// The trailing send button in the composer's bottom toolbar — a green
    /// circle with a white up-arrow (paseo). Only shown when the composer has
    /// text (see `composerToolbar`).
    private func sendButton(active: Bool) -> some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(sendButtonBackground(active: active), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!active)
        .keyboardShortcut(.return, modifiers: .command)
        .help(sendButtonTitle)
    }

    // MARK: - Send logic

    /// True once the composer holds non-whitespace text — drives the send
    /// button's visibility (paseo shows no glyph until you type).
    private var hasDraftText: Bool {
        !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Green when the message can be sent, a muted grey while it can't (e.g. a
    /// response is still generating). The button is only visible with text, so
    /// green is the usual state.
    private func sendButtonBackground(active: Bool) -> Color {
        active ? Color.green : Color(nsColor: .quaternaryLabelColor).opacity(0.4)
    }

    private func sendMessage() {
        // Guard: don't clear the draft or attempt to send when the agent is
        // generating or waiting for a slot. The Send button is already gated
        // by `canSend`, but the Return key in ComposerTextView calls this
        // unconditionally — so the same guard here prevents the message from
        // being silently dropped (issue #380). The draft is preserved so the
        // user can send it once the agent finishes.
        guard canSend else { return }
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draftMessage = ""
        if launcher.isInteractiveSession {
            // Live chat mid-session: append a turn to the existing session.
            launcher.sendInteractiveMessage(message)
        } else if let chatID {
            // D3: a persisted (non-live) chat — start a fresh session that
            // continues this chat (seeded-fallback), streaming into the
            // SAME chat row. activeChatID = chat.id flips this view to live.
            Task {
                await AgentOperationRunner.continueChat(
                    chatID: chatID,
                    message: message,
                    store: store,
                    launcher: launcher,
                    wikiID: session.wikiID,
                    changeSignaler: fileProvider,
                    wikictlDirectory: HelpersLocation.wikictlDirectory
                )
            }
        } else {
            // Draft state (.newChat): start a NEW chat.
            Task {
                await AgentOperationRunner.startChat(
                    firstMessage: message,
                    launcher: launcher,
                    store: store,
                    wikiID: session.wikiID,
                    changeSignaler: fileProvider,
                    wikictlDirectory: HelpersLocation.wikictlDirectory
                )
            }
        }
    }

    /// Start a new chat: clear the launcher's live state and retarget
    /// the tab back to the draft state (.newChat). The old chat stays
    /// in history.
    private func startNewChat() {
        launcher.startNewChat()
        // D2 retarget-back: morph the active tab from .chat(id) back to the draft
        // state so the user sees a fresh composer.
        if let activeID = store.activeTabID {
            store.retargetTab(id: activeID, to: .newChat)
        }
    }

    // MARK: - Derived state

    /// Composer is enabled for the live chat AND for a persisted (non-live) chat
    /// whose kind's launcher is idle (D3: continue a persisted chat). A
    /// persisted chat whose launcher is mid-generation (a DIFFERENT chat
    /// is responding) disables the composer — the takeover rules refuse a
    /// mid-generation interrupt, so the composer reflects that.
    private var isComposerEnabled: Bool {
        // Draft state (.newChat with chatID == nil): always enabled (a wiki
        // is open inside ContentView; nothing is generating).
        guard chatID != nil else {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // The active live chat: enabled when a turn isn't in flight.
        if isLiveChat {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // D3: a persisted (non-live) chat is continuable when its kind's launcher
        // is idle (`!isGenerating && !isAwaitingGenerationSlot`). If that launcher
        // is mid-generation (a different chat), the composer stays
        // disabled — `continueChat`'s takeover guard would refuse anyway.
        // (A session is only alive when a wiki is open, so the activeWikiID
        // check the old code had is always true here.)
        return !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
    }

    /// Visible caption shown under the composer when the session is waiting or
    /// busy. Covers both the generation-gate queue (any session) and the
    /// persisted-chat "another chat is responding" case. Empty (no caption)
    /// when the composer is enabled and nothing is queued (issue #235).
    private var composerCaption: String? {
        Self.composerCaptionText(
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot,
            hasChatID: chatID != nil,
            isLiveChat: isLiveChat,
            isGenerating: launcher.isGenerating)
    }

    private var canType: Bool {
        // A session is always alive when ChatView is rendered inside
        // ContentView, so the old `activeWikiID != nil` check is
        // always true here.
        launcher.isInteractiveSession || !launcher.isRunning
    }

    private var canSend: Bool {
        fileProvider.path != nil
            && canType
            && !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButtonTitle: String {
        if launcher.isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if launcher.isGenerating {
            return "Wait for the response before sending the next message"
        }
        return launcher.isInteractiveSession ? "Send" : "Start Query"
    }
}

/// `Hashable` key for the `ChatView` quote-anchor consume task (issue #281).
/// Re-fires the task when the chat changes, a new anchor is pending, or the
/// transcript's message count changes (so the anchor is consumed only once the
/// persisted messages have loaded).
private struct ChatAnchorTaskKey: Hashable {
    let chatID: PageID?
    let anchorVersion: Int
    let messageCount: Int
}

// Shared metrics for the chat surface (mirrors the original
// QueryChatMetrics, now shared between draft and persisted states).
enum ChatMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    static let controlsBandHeight: CGFloat = 28
    static let chatTopInset: CGFloat = 56
    /// Horizontal inset of the composer box's contents (paseo-style). Also the
    /// effective left margin for the text, since `ComposerTextView` uses zero
    /// line-fragment padding.
    static let composerHorizontalPadding: CGFloat = 16
    /// Top inset above the text inside the composer box.
    static let composerTopPadding: CGFloat = 12
    /// Bottom inset below the toolbar row inside the composer box.
    static let composerBottomPadding: CGFloat = 10
    /// Vertical gap between the text and the toolbar row inside the box.
    static let composerRowSpacing: CGFloat = 8
    /// Corner radius of the unified composer box (paseo uses a soft rounded
    /// rectangle, not a full pill).
    static let composerCornerRadius: CGFloat = 16
    static let sendButtonSize: CGFloat = 30
    /// Font for `ComposerTextView` — matches the previous `TextField`'s
    /// `.font(.body)`, expressed as an `NSFont` since the composer is
    /// AppKit-backed.
    static var composerFont: NSFont { .preferredFont(forTextStyle: .body) }
}

/// Right-side outline for a chat: lists the user's turns (questions) in
/// order. Clicking a turn scrolls the transcript web view to that message via a
/// versioned `ChatScrollRequest`. Mirrors the page outline's shape (divider +
/// "Outline" header + scrollable list).
struct ChatOutlineView: View {
    let turns: [String]
    let onSelect: (Int) -> Void

    @AppStorage("chatOutlineWidth") private var outlineWidth: Double = 240
    @State private var dragStartWidth: Double? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Draggable divider on the outline's leading edge. A 1pt separator
            // line with a wider invisible hit area so it's easy to grab.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = outlineWidth
                            }
                            if let start = dragStartWidth {
                                let newWidth = start - Double(value.translation.width)
                                outlineWidth = max(60, min(600, newWidth))
                            }
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                        }
                )
                .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Outline")
                    .font(.headline)
                    .padding()

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                            Button {
                                onSelect(index)
                            } label: {
                                Text(turn.isEmpty ? "(empty)" : turn)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(width: outlineWidth)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
