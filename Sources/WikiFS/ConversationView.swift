import AppKit
import SwiftUI
import WikiFSCore

/// Whether the session can write to the wiki. Ask = read-only; Edit = can write.
/// This is a property of the mounted session, not a runtime toggle.
enum QueryMode {
    case ask, edit

    var allowsEdits: Bool { self == .edit }
}

/// The unified conversation surface (D2, pillar 2). One view replaces the split
/// between the live `QueryConversationView` and the read-only
/// `ChatHistoryDetailView`. Whether you see streaming deltas or a persisted
/// transcript depends on the **source-of-truth rule**: if this chat is the
/// launcher's active live session (`activeChatID == chatID`), render
/// `launcher.events` (in-memory, streaming). Otherwise render the persisted
/// `store.chatMessages(chatID:)`.
///
/// The `.ask` / `.edit` draft states also route here (with `chatID == nil`),
/// showing the empty-composer state until the first send retargets the tab to
/// `.chat(id)` (the draft-state morph, handled by `AgentOperationRunner`).
struct ConversationView: View {
    /// `.ask` / `.edit` for draft states; `.chat(id)`'s kind is resolved from
    /// the chat summary. Determines which launcher owns this surface.
    let mode: QueryMode
    /// The persisted chat id, or `nil` for the draft state (.ask/.edit). When
    /// non-nil AND equal to `launcher.activeChatID`, the view renders live.
    let chatID: PageID?

    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike

    @State private var draftMessage = ""
    @State private var showsInternals = false
    @State private var composerHeight: CGFloat = ComposerTextView.oneLineHeight(for: ConversationMetrics.composerFont)
    @State private var persistedMessages: [ChatMessage] = []
    @AppStorage("conversation.zoom") private var conversationZoom = Double(ZoomScale.defaultScale)
    @AppStorage("isChatOutlineExpanded") private var chatOutlineExpanded = false
    @State private var outlineScroll: ChatScrollRequest? = nil

    /// True when this surface is rendering the active live session (D2
    /// source-of-truth rule). The view sources from `launcher.events`; when
    /// false, it sources from the persisted `store.chatMessages(chatID:)`.
    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return launcher.activeChatID == chatID.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                if showsDebugControls {
                    controls
                        .padding(.top, ConversationMetrics.debugTopInset)
                        .padding(.trailing, ConversationMetrics.contentInset)
                }
            }
            .frame(minWidth: PageEditorMetrics.detailMinWidth)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .zoomShortcuts($conversationZoom)
        .zoomScroll($conversationZoom)
        .onChange(of: conversationZoom) { _, _ in
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
    }

    // MARK: - Controls (debug cluster + new conversation)

    private var controls: some View {
        // Only the live chat gets the debug cluster + new conversation button.
        // A persisted non-live chat is read-only — no controls.
        HStack(spacing: 8) {
            if showsDebugControls {
                if launcher.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show internals", isOn: $showsInternals)
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
                // Stop button: visible while generating OR awaiting the generation slot.
                Button(action: { launcher.stopAgent() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop the current response")
            }
        }
    }

    private var showsDebugControls: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if showsInternals && launcher.isRunning && launcher.runningKind == .query {
            AgentActivityView(launcher: launcher, showsResultEvents: false, showsInternals: true, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ConversationMetrics.contentInset)
        } else if isLiveChat || chatID == nil {
            // Live session or draft state: same path as QueryConversationView.
            if hasVisibleConversation {
                liveConversation
            } else {
                emptyState
            }
        } else {
            // Persisted non-live chat: read-only header + transcript.
            persistedConversation
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

    // MARK: - Live conversation (streaming)

    @ViewBuilder
    private var liveConversation: some View {
        VStack(spacing: 0) {
            if let chat = chatSummary {
                header(for: chat)
                Divider().opacity(PageEditorMetrics.dividerOpacity)
            }
            withChatOutline {
                VStack(spacing: 0) {
                    if showsEditingEnabledBanner {
                        editingEnabledBanner
                            .padding(.top, bannerTopReservation)
                            .padding(.bottom, ConversationMetrics.sectionSpacing)
                    }
                    QueryTranscriptView(
                        launcher: launcher,
                        onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                        renderContext: { [weak store] in store?.renderContext() },
                        blobStore: store,
                        zoom: conversationZoom,
                        scrollRequest: outlineScroll
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, PageEditorMetrics.contentInset)
                        .padding(.top, showsEditingEnabledBanner || chatSummary != nil ? 0 : ConversationMetrics.conversationTopInset)
                    liveComposer
                        .padding(.horizontal, PageEditorMetrics.contentInset)
                        .padding(.top, ConversationMetrics.sectionSpacing)
                        .padding(.bottom, ConversationMetrics.contentInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: ConversationMetrics.emptyStateSpacing) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
                    .padding(.top, bannerTopReservation)
            }
            Spacer(minLength: 0)
            Text("Ask \(activeWikiName)")
                .font(.largeTitle)
                .fontWeight(.regular)
                .multilineTextAlignment(.center)
            liveComposer
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConversationMetrics.emptyStateHorizontalInset)
        .padding(.bottom, ConversationMetrics.emptyStateBottomBias)
    }

    private var liveComposer: some View {
        composer(enabled: isComposerEnabled)
    }

    // MARK: - Persisted conversation (read-only)

    @ViewBuilder
    private var persistedConversation: some View {
        if let chat = chatSummary {
            VStack(alignment: .leading, spacing: 0) {
                header(for: chat)
                Divider().opacity(PageEditorMetrics.dividerOpacity)
                withChatOutline {
                    persistedTranscript
                }
            }
        } else {
            ContentUnavailableView {
                Label("Conversation Missing", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("This conversation is no longer available.")
            }
        }
    }

    private var chatSummary: ChatSummary? {
        store.chats.first { $0.id == chatID }
    }

    /// User turns (questions) in display order — the chat outline entries. Sourced
    /// from the SAME transcript-visible events the web view renders, so outline
    /// index `i` matches the i-th `.chat-user` row.
    private var chatTurns: [String] {
        let events = isLiveChat
            ? launcher.events.transcriptVisible
            : persistedMessages.map(\.event).transcriptVisible
        return events.compactMap { event in
            if case .userText(let text) = event { return text }
            return nil
        }
    }

    @ViewBuilder
    private func header(for chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            Label {
                Text(chat.title)
                    .font(.largeTitle)
                    .bold()
                    .lineLimit(1)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: chat.kind == .ask ? "bubble.left.and.bubble.right" : "square.and.pencil")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")")
                Text("·")
                Text(chat.updatedAt, format: .dateTime)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let chatID {
                    Button("Show in List", systemImage: "sidebar.left") {
                        store.requestSidebarReveal(.chat(chatID))
                    }
                    .help("Reveal this conversation in the sidebar")
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
                    .help("Share this conversation")
                    Button("Reveal in Finder", systemImage: "folder") {
                        Task { await fileProvider.revealChatInFinder(id: chatID) }
                    }
                    .help("Reveal this conversation file in Finder")
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
        .padding(.bottom, ConversationMetrics.sectionSpacing)
    }

    @ViewBuilder
    private var persistedTranscript: some View {
        let visible = persistedMessages.map(\.event).transcriptVisible
        if visible.isEmpty {
            VStack(spacing: 7) {
                Text("No messages were persisted for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ChatWebView(
                events: visible,
                style: .chat,
                onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                renderContext: { [weak store] in store?.renderContext() },
                blobStore: store,
                zoom: conversationZoom,
                scrollRequest: outlineScroll
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, PageEditorMetrics.contentInset)
            // D3: the persisted chat's composer continues the conversation
            // (seeded-fallback). Enabled when the kind's launcher is idle; disabled
            // with a slot-style caption when a different conversation is responding.
            .safeAreaInset(edge: .bottom) {
                persistedComposerFooter
            }
        }
    }

    private var persistedComposerFooter: some View {
        VStack(spacing: 4) {
            composer(enabled: isComposerEnabled)
            if let caption = persistedComposerCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.bottom, ConversationMetrics.contentInset)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Editing banner

    @ViewBuilder
    private var editingEnabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 13, weight: .semibold))
            Text("Editing enabled — ingestion is paused while the agent is responding.")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
    }

    private var showsEditingEnabledBanner: Bool {
        Self.showsEditingBanner(allowsEdits: mode.allowsEdits, isGenerating: launcher.isGenerating)
    }

    /// Pure predicate: true only when an Edit-mode session is actively generating.
    /// Kept static so tests can verify the full (mode × isGenerating) matrix without
    /// constructing a view. `mode.allowsEdits` is the sole input from the mode.
    static func showsEditingBanner(allowsEdits: Bool, isGenerating: Bool) -> Bool {
        allowsEdits && isGenerating
    }

    private var bannerTopReservation: CGFloat {
        showsDebugControls
            ? ConversationMetrics.debugTopInset + ConversationMetrics.controlsBandHeight
            : 0
    }

    // MARK: - Composer

    /// The composer's AppKit font, scaled by the persisted conversation zoom so
    /// ⌘+/⌘− resize the input alongside the transcript (parity with the page
    /// editor's `editor.zoom`).
    private var composerFont: NSFont {
        let base = ConversationMetrics.composerFont
        return base.withSize(base.pointSize * CGFloat(conversationZoom))
    }

    private func composer(enabled: Bool) -> some View {
        let sendActive = canSend && enabled
        return HStack(alignment: .bottom, spacing: 10) {
            ComposerTextView(
                text: $draftMessage,
                isEditable: enabled,
                font: composerFont,
                onSubmit: sendMessage,
                measuredHeight: $composerHeight
            )
                .frame(height: composerHeight)
                .padding(.leading, ConversationMetrics.composerHorizontalPadding)
                .padding(.vertical, ConversationMetrics.composerVerticalPadding)
                .overlay(alignment: .topLeading) {
                    if draftMessage.isEmpty {
                        Text("Ask a question, or ask to update the wiki…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .padding(.leading, ConversationMetrics.composerHorizontalPadding)
                            .padding(.vertical, ConversationMetrics.composerVerticalPadding + ComposerTextView.Metrics.verticalInsetPerSide)
                    }
                }

            Button(action: sendMessage) {
                Image(systemName: sendButtonIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(sendActive ? Color.white : Color.secondary)
                    .frame(width: ConversationMetrics.sendButtonSize, height: ConversationMetrics.sendButtonSize)
                    .background(sendButtonBackground(active: sendActive), in: Circle())
            }
                .buttonStyle(.borderless)
                .disabled(!sendActive)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendButtonTitle)
                .padding(.bottom, ConversationMetrics.sendButtonBottomInset)
        }
        .padding(.trailing, ConversationMetrics.composerButtonInset)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Send logic

    private func sendButtonBackground(active: Bool) -> Color {
        active ? .accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.25)
    }

    private func sendMessage() {
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draftMessage = ""
        if launcher.isInteractiveSession {
            // Live chat mid-session: append a turn to the existing session.
            launcher.sendInteractiveMessage(message)
        } else if let chatID {
            // D3: a persisted (non-live) chat — start a fresh session that
            // continues this conversation (seeded-fallback), streaming into the
            // SAME chat row. activeChatID = chat.id flips this view to live.
            Task {
                await AgentOperationRunner.continueConversation(
                    chatID: chatID,
                    message: message,
                    mode: mode,
                    store: store,
                    launcher: launcher,
                    manager: manager,
                    fileProvider: fileProvider,
                    allowWikiEdits: mode.allowsEdits
                )
            }
        } else {
            // Draft state (.ask/.edit): start a NEW conversation.
            Task {
                await AgentOperationRunner.startQueryConversation(
                    firstMessage: message,
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider,
                    allowWikiEdits: mode.allowsEdits
                )
            }
        }
    }

    /// Start a new conversation: clear the launcher's live state and retarget
    /// the tab back to the draft state (.ask/.edit per mode). The old chat stays
    /// in history.
    private func startNewConversation() {
        launcher.startNewConversation()
        // D2 retarget-back: morph the active tab from .chat(id) back to the draft
        // state so the user sees a fresh composer.
        if let activeID = store.activeTabID {
            store.retargetTab(id: activeID, to: mode == .edit ? .edit : .ask)
        }
    }

    // MARK: - Derived state

    private var hasVisibleConversation: Bool {
        if isLiveChat {
            return launcher.events.contains { event in
                switch event {
                case .userText:
                    return true
                case .assistantText(let text), .result(_, let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .systemInit, .toolUse, .toolResult, .subagent, .messageStop, .raw, .assistantTextDelta:
                    return false
                }
            }
        }
        // Persisted chat or draft: check if there are any visible persisted rows.
        return persistedMessages.map(\.event).transcriptVisible.contains { event in
            switch event {
            case .userText: return true
            case .assistantText(let text), .result(_, let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
    }

    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let descriptor = manager.wikis.first(where: { $0.id == id })
        else { return "this wiki" }
        return descriptor.displayName
    }

    /// Composer is enabled for the live chat AND for a persisted (non-live) chat
    /// whose kind's launcher is idle (D3: continue a persisted conversation). A
    /// persisted chat whose launcher is mid-generation (a DIFFERENT conversation
    /// is responding) disables the composer — the takeover rules refuse a
    /// mid-generation interrupt, so the composer reflects that.
    private var isComposerEnabled: Bool {
        // Draft state (.ask/.edit with chatID == nil): always enabled (when a
        // wiki is open and nothing is generating).
        guard chatID != nil else {
            return manager.activeWikiID != nil && (launcher.isInteractiveSession || !launcher.isRunning)
        }
        // The active live chat: enabled when a turn isn't in flight.
        if isLiveChat {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // D3: a persisted (non-live) chat is continuable when its kind's launcher
        // is idle (`!isGenerating && !isAwaitingGenerationSlot`). If that launcher
        // is mid-generation (a different conversation), the composer stays
        // disabled — `continueConversation`'s takeover guard would refuse anyway.
        return manager.activeWikiID != nil
            && !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
    }

    /// The caption shown under a persisted chat's composer when it is disabled
    /// because the kind's launcher is responding to a DIFFERENT conversation.
    /// Mirrors the slot-style hint used elsewhere. Empty (no caption) when the
    /// composer is enabled.
    private var persistedComposerCaption: String? {
        guard chatID != nil, !isLiveChat else { return nil }
        if launcher.isGenerating || launcher.isAwaitingGenerationSlot {
            let label = mode == .edit ? "Edit" : "Ask"
            return "Another \(label) conversation is responding — wait or stop it."
        }
        return nil
    }

    private var canType: Bool {
        manager.activeWikiID != nil && (launcher.isInteractiveSession || !launcher.isRunning)
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

    private var sendButtonIcon: String {
        launcher.isInteractiveSession ? "arrow.up.circle.fill" : "play.circle.fill"
    }
}

// Shared metrics for the conversation surface (mirrors the original
// QueryConversationMetrics, now shared between draft and persisted states).
enum ConversationMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    static let controlsBandHeight: CGFloat = 28
    static let conversationTopInset: CGFloat = 56
    static let emptyStateHorizontalInset: CGFloat = 72
    static let emptyStateSpacing: CGFloat = 28
    static let emptyStateBottomBias: CGFloat = 96
    static let composerHorizontalPadding: CGFloat = 22
    static let composerVerticalPadding: CGFloat = 16
    static let composerButtonInset: CGFloat = 8
    static let sendButtonSize: CGFloat = 42
    /// Font for `ComposerTextView` — matches the previous `TextField`'s
    /// `.font(.body)`, expressed as an `NSFont` since the composer is
    /// AppKit-backed.
    static var composerFont: NSFont { .preferredFont(forTextStyle: .body) }
    /// Bottom inset that vertically centers the send button in a ONE-line
    /// capsule. Derived, not hardcoded, so a font or padding change can't
    /// silently un-center the button.
    static var sendButtonBottomInset: CGFloat {
        (ComposerTextView.oneLineHeight(for: composerFont)
            + composerVerticalPadding * 2 - sendButtonSize) / 2
    }
}

/// Right-side outline for a conversation: lists the user's turns (questions) in
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
